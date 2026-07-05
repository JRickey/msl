//! The node table: stable node ids over the guest tree, each re-resolvable from
//! the pinned root by parent + name. Cached `O_PATH` handles are the scarce
//! resource, so they are evicted LRU under fd pressure while the (cheap)
//! metadata is retained; an unknown node id surfaces as `ESTALE` so the appex
//! re-looks-up. No recursion: re-resolution walks the parent chain iteratively.

use std::collections::HashMap;

use crate::backend::{Backend, Handle};
use crate::stat::Stat;
use msl_wire::fs::ItemType;

/// Root is always node 1 and never evicted.
pub const ROOT_ID: u64 = 1;
const MAX_DEPTH: usize = 256;
const RETRY_EVICTIONS: usize = 64;

struct Node {
    parent_id: u64,
    name: String,
    item_type: ItemType,
    handle: Option<Handle>,
    last_used: u64,
}

/// Stable-id table with lazy `O_PATH` resolution and LRU fd eviction.
pub struct NodeTable {
    nodes: HashMap<u64, Node>,
    index: HashMap<(u64, String), u64>,
    next_id: u64,
    tick: u64,
    fd_cap: usize,
}

impl NodeTable {
    /// Seed the table with the pinned root authority. `fd_cap` bounds cached
    /// handles (root excluded); exceeding it evicts the least-recently-used.
    pub fn new(root_handle: Handle, fd_cap: usize) -> Self {
        assert!(root_handle >= 0, "root handle must be valid");
        assert!(fd_cap >= 1, "fd cap must be positive");
        let mut nodes = HashMap::new();
        nodes.insert(
            ROOT_ID,
            Node {
                parent_id: 0,
                name: String::new(),
                item_type: ItemType::Dir,
                handle: Some(root_handle),
                last_used: 0,
            },
        );
        Self {
            nodes,
            index: HashMap::new(),
            next_id: ROOT_ID + 1,
            tick: 1,
            fd_cap,
        }
    }

    /// Intern a child of `parent_id`, returning a stable node id. The same
    /// (parent, name) always maps to the same id; the type is refreshed.
    pub fn intern(&mut self, parent_id: u64, name: &str, item_type: ItemType) -> u64 {
        assert!(!name.is_empty(), "interned name must not be empty");
        let key = (parent_id, name.to_string());
        if let Some(&id) = self.index.get(&key) {
            if let Some(node) = self.nodes.get_mut(&id) {
                node.item_type = item_type;
                return id;
            }
            self.index.remove(&key);
        }
        let id = self.next_id;
        self.next_id += 1;
        self.nodes.insert(
            id,
            Node {
                parent_id,
                name: name.to_string(),
                item_type,
                handle: None,
                last_used: 0,
            },
        );
        self.index.insert(key, id);
        id
    }

    #[must_use]
    pub fn parent_of(&self, node_id: u64) -> Option<u64> {
        self.nodes.get(&node_id).map(|node| node.parent_id)
    }

    /// Resolve a node id to a live handle, opening `O_PATH` fds along the parent
    /// chain and caching them. Returns `ESTALE` for an unknown id, `ELOOP` for a
    /// pathologically deep chain, or the backend errno from the walk.
    pub fn resolve<B: Backend>(&mut self, node_id: u64, backend: &mut B) -> Result<Handle, i32> {
        self.tick += 1;
        if let Some(handle) = self.cached(node_id) {
            return Ok(handle);
        }
        let chain = self.chain_from_root(node_id)?;
        let mut handle = self.root_handle();
        for id in chain {
            // bounded: MAX_DEPTH
            handle = self.resolve_step(id, handle, backend)?;
        }
        Ok(handle)
    }

    fn resolve_step<B: Backend>(
        &mut self,
        id: u64,
        parent_handle: Handle,
        backend: &mut B,
    ) -> Result<Handle, i32> {
        if let Some(handle) = self.cached(id) {
            return Ok(handle);
        }
        let name = self.name_of(id)?;
        let (child, _stat) = self.lookup_with_retry(backend, parent_handle, &name)?;
        self.store_handle(id, child, backend);
        Ok(child)
    }

    /// Open a bounded read fd for a regular file node, evicting and retrying once
    /// on fd exhaustion so normal browse never hard-fails.
    pub fn open_read<B: Backend>(&mut self, node_id: u64, backend: &mut B) -> Result<Handle, i32> {
        let node = self.resolve(node_id, backend)?;
        match backend.open_read(node) {
            Err(err) if is_fd_pressure(err) => {
                self.evict_until_room(backend);
                let retry = self.resolve(node_id, backend)?;
                backend.open_read(retry)
            }
            other => other,
        }
    }

    /// Drop a node the appex reclaimed: close its handle and forget it.
    pub fn reclaim<B: Backend>(&mut self, node_id: u64, backend: &mut B) {
        if node_id == ROOT_ID {
            return;
        }
        if let Some(node) = self.nodes.remove(&node_id) {
            if let Some(handle) = node.handle {
                backend.close(handle);
            }
            self.index.remove(&(node.parent_id, node.name));
        }
    }

    fn cached(&mut self, node_id: u64) -> Option<Handle> {
        let tick = self.tick;
        let node = self.nodes.get_mut(&node_id)?;
        node.last_used = tick;
        node.handle
    }

    fn root_handle(&self) -> Handle {
        self.nodes[&ROOT_ID].handle.expect("root handle is pinned")
    }

    fn name_of(&self, node_id: u64) -> Result<String, i32> {
        self.nodes
            .get(&node_id)
            .map_or(Err(libc_estale()), |node| Ok(node.name.clone()))
    }

    fn chain_from_root(&self, node_id: u64) -> Result<Vec<u64>, i32> {
        let mut chain = Vec::new();
        let mut cursor = node_id;
        for _ in 0..MAX_DEPTH {
            // bounded: MAX_DEPTH
            if cursor == ROOT_ID {
                chain.reverse();
                return Ok(chain);
            }
            let node = self.nodes.get(&cursor).ok_or_else(libc_estale)?;
            chain.push(cursor);
            cursor = node.parent_id;
        }
        Err(libc_eloop())
    }

    fn lookup_with_retry<B: Backend>(
        &mut self,
        backend: &mut B,
        parent: Handle,
        name: &str,
    ) -> Result<(Handle, Stat), i32> {
        match backend.lookup(parent, name) {
            Err(err) if is_fd_pressure(err) => {
                self.evict_until_room(backend);
                backend.lookup(parent, name)
            }
            other => other,
        }
    }

    fn store_handle<B: Backend>(&mut self, node_id: u64, handle: Handle, backend: &mut B) {
        while self.cached_count() >= self.fd_cap {
            // bounded: evicts >=1 each pass or breaks
            if !self.evict_one(backend) {
                break;
            }
        }
        let tick = self.tick;
        if let Some(node) = self.nodes.get_mut(&node_id) {
            node.handle = Some(handle);
            node.last_used = tick;
        } else {
            backend.close(handle);
        }
    }

    fn evict_until_room<B: Backend>(&mut self, backend: &mut B) {
        for _ in 0..RETRY_EVICTIONS {
            // bounded
            if !self.evict_one(backend) {
                return;
            }
        }
    }

    fn evict_one<B: Backend>(&mut self, backend: &mut B) -> bool {
        let victim = self
            .nodes
            .iter()
            .filter(|(id, node)| **id != ROOT_ID && node.handle.is_some())
            .min_by_key(|(_, node)| node.last_used)
            .map(|(id, _)| *id);
        let Some(id) = victim else { return false };
        if let Some(handle) = self.nodes.get_mut(&id).and_then(|node| node.handle.take()) {
            backend.close(handle);
            return true;
        }
        false
    }

    fn cached_count(&self) -> usize {
        // Root is pinned and always counted; exclude it from the cap.
        self.nodes
            .values()
            .filter(|node| node.handle.is_some())
            .count()
            .saturating_sub(1)
    }
}

const fn is_fd_pressure(errno: i32) -> bool {
    errno == libc::EMFILE || errno == libc::ENFILE
}

const fn libc_estale() -> i32 {
    libc::ESTALE
}

const fn libc_eloop() -> i32 {
    libc::ELOOP
}
