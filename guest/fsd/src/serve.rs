//! The request dispatcher: decode one `fs` request, drive the backend through
//! the node table, and encode the reply. Read-only — no mutation entrypoint
//! exists, so the guest never opens the root writable. Generic over `Backend`
//! so the whole dispatch is host-tested against an in-memory mock.

use std::collections::HashMap;

use crate::backend::Backend;
use crate::names::is_valid_component;
use crate::nodes::{NodeTable, ROOT_ID};
use crate::stat;
use msl_wire::fs::{DirEntry, ReplyBody, ReplyFrame, Request, RequestFrame};

/// Serves file operations for one mounted volume over one backend.
pub struct Server<B: Backend> {
    backend: B,
    nodes: NodeTable,
    next_handle: u64,
    open_reads: HashMap<u64, i32>,
}

impl<B: Backend> Server<B> {
    /// Open the root authority and seed the node table. `fd_cap` bounds cached
    /// node handles.
    pub fn new(mut backend: B, fd_cap: usize) -> Result<Self, i32> {
        let root = backend.root()?;
        Ok(Self {
            backend,
            nodes: NodeTable::new(root, fd_cap),
            next_handle: 1,
            open_reads: HashMap::new(),
        })
    }

    /// Dispatch one decoded request to its reply. `close` returns `None`, which
    /// the caller treats as the end of the session.
    pub fn dispatch(&mut self, frame: &RequestFrame) -> Option<ReplyFrame> {
        let id = frame.id;
        let op = frame.request.op();
        if matches!(frame.request, Request::Close) {
            return None;
        }
        Some(match self.run(&frame.request) {
            Ok(body) => ReplyFrame::ok(id, op, body),
            Err(errno) => ReplyFrame::err(id, op, errno, errno_message(errno)),
        })
    }

    fn run(&mut self, request: &Request) -> Result<ReplyBody, i32> {
        match request {
            Request::Statfs => self.statfs(),
            Request::Lookup { parent, name } => self.lookup(*parent, name),
            Request::Getattr { node, .. } => self.getattr(*node),
            Request::Readdirplus { node, .. } => self.readdirplus(*node),
            Request::Open { node, .. } => self.open(*node),
            Request::Read {
                handle,
                offset,
                length,
            } => self.read(*handle, *offset, *length),
            Request::CloseFile { handle } => Ok(self.close_file(*handle)),
            Request::Readlink { node } => self.readlink(*node),
            Request::Reclaim { node } => Ok(self.reclaim(*node)),
            Request::Sync | Request::Close => Ok(ReplyBody::Empty),
        }
    }

    fn statfs(&mut self) -> Result<ReplyBody, i32> {
        let root = self.nodes.resolve(ROOT_ID, &mut self.backend)?;
        Ok(ReplyBody::Statfs(self.backend.statfs(root)?))
    }

    fn lookup(&mut self, parent: u64, name: &str) -> Result<ReplyBody, i32> {
        if !is_valid_component(name) {
            return Err(libc::EINVAL);
        }
        let parent_handle = self.nodes.resolve(parent, &mut self.backend)?;
        let (_child, child_stat) = self.backend.lookup(parent_handle, name)?;
        let node_id = self.nodes.intern(parent, name, child_stat.item_type());
        Ok(ReplyBody::Attr(stat::to_attr(node_id, parent, &child_stat)))
    }

    fn getattr(&mut self, node: u64) -> Result<ReplyBody, i32> {
        let handle = self.nodes.resolve(node, &mut self.backend)?;
        let value = self.backend.getattr(handle)?;
        let parent = self.nodes.parent_of(node).unwrap_or(0);
        Ok(ReplyBody::Attr(stat::to_attr(node, parent, &value)))
    }

    fn readdirplus(&mut self, node: u64) -> Result<ReplyBody, i32> {
        let handle = self.nodes.resolve(node, &mut self.backend)?;
        let items = self.backend.readdir(handle)?;
        let mut entries = Vec::new();
        for item in items {
            // bounded: directory entry count
            if !is_valid_component(&item.name) {
                continue;
            }
            let child_id = self.nodes.intern(node, &item.name, item.stat.item_type());
            entries.push(DirEntry {
                name: item.name,
                attr: stat::to_attr(child_id, node, &item.stat),
            });
        }
        Ok(ReplyBody::Readdirplus {
            eof: true,
            next_cookie: 0,
            entries,
        })
    }

    fn readlink(&mut self, node: u64) -> Result<ReplyBody, i32> {
        let handle = self.nodes.resolve(node, &mut self.backend)?;
        Ok(ReplyBody::Readlink {
            target: self.backend.readlink(handle)?,
        })
    }

    fn open(&mut self, node: u64) -> Result<ReplyBody, i32> {
        let read_fd = self.nodes.open_read(node, &mut self.backend)?;
        let handle = self.next_handle;
        self.next_handle += 1;
        self.open_reads.insert(handle, read_fd);
        Ok(ReplyBody::Open { handle })
    }

    fn read(&mut self, handle: u64, offset: u64, length: u32) -> Result<ReplyBody, i32> {
        let Some(&fd) = self.open_reads.get(&handle) else {
            return Err(libc::ESTALE);
        };
        let (data, eof) = self.backend.read_at(fd, offset, length as usize)?;
        Ok(ReplyBody::Read { data, eof })
    }

    fn close_file(&mut self, handle: u64) -> ReplyBody {
        if let Some(fd) = self.open_reads.remove(&handle) {
            self.backend.close(fd);
        }
        ReplyBody::Empty
    }

    fn reclaim(&mut self, node: u64) -> ReplyBody {
        self.nodes.reclaim(node, &mut self.backend);
        ReplyBody::Empty
    }
}

fn errno_message(errno: i32) -> String {
    format!("errno {errno}")
}

#[cfg(test)]
#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::cast_possible_wrap,
    clippy::manual_let_else
)]
mod tests {
    use super::Server;
    use crate::backend::{Backend, DirItem, Handle};
    use crate::stat::Stat;
    use msl_wire::fs::{ReplyBody, Request, RequestFrame, Statfs};

    enum Kind {
        Dir(Vec<usize>),
        File(Vec<u8>),
        Link(String),
    }

    struct Entry {
        name: String,
        stat: Stat,
        kind: Kind,
    }

    /// In-memory tree. A backend `Handle` is an index into `entries`; `budget`
    /// caps concurrently open handles so eviction can be exercised.
    struct MockFs {
        entries: Vec<Entry>,
        open: usize,
        budget: usize,
    }

    fn dir_stat(ino: u64) -> Stat {
        Stat {
            ino,
            mode: 0o040_755,
            uid: 0,
            gid: 0,
            nlink: 2,
            size: 4096,
            blocks: 8,
            atime: (1, 0),
            mtime: (2, 0),
            ctime: (3, 0),
        }
    }
    fn file_stat(ino: u64, size: u64) -> Stat {
        Stat {
            ino,
            mode: 0o100_644,
            uid: 0,
            gid: 0,
            nlink: 1,
            size,
            blocks: size.div_ceil(512),
            atime: (1, 0),
            mtime: (2, 0),
            ctime: (3, 0),
        }
    }
    fn link_stat(ino: u64) -> Stat {
        Stat {
            ino,
            mode: 0o120_777,
            uid: 0,
            gid: 0,
            nlink: 1,
            size: 7,
            blocks: 0,
            atime: (1, 0),
            mtime: (2, 0),
            ctime: (3, 0),
        }
    }

    // Tree: / (0) contains etc (1, dir), os (2, file "hi\n"), link (3 -> "os").
    // etc contains os-release (4, file "NAME=msl\n").
    fn sample() -> MockFs {
        let entries = vec![
            Entry {
                name: "/".into(),
                stat: dir_stat(1),
                kind: Kind::Dir(vec![1, 2, 3]),
            },
            Entry {
                name: "etc".into(),
                stat: dir_stat(10),
                kind: Kind::Dir(vec![4]),
            },
            Entry {
                name: "os".into(),
                stat: file_stat(11, 3),
                kind: Kind::File(b"hi\n".to_vec()),
            },
            Entry {
                name: "link".into(),
                stat: link_stat(12),
                kind: Kind::Link("os".into()),
            },
            Entry {
                name: "os-release".into(),
                stat: file_stat(13, 9),
                kind: Kind::File(b"NAME=msl\n".to_vec()),
            },
        ];
        MockFs {
            entries,
            open: 0,
            budget: 1024,
        }
    }

    impl MockFs {
        fn acquire(&mut self) -> Result<(), i32> {
            if self.open >= self.budget {
                return Err(libc::EMFILE);
            }
            self.open += 1;
            Ok(())
        }
    }

    impl Backend for MockFs {
        fn root(&mut self) -> Result<Handle, i32> {
            self.acquire()?;
            Ok(0)
        }
        fn lookup(&mut self, parent: Handle, name: &str) -> Result<(Handle, Stat), i32> {
            let Kind::Dir(children) = &self.entries[parent as usize].kind else {
                return Err(libc::ENOTDIR);
            };
            let found = children
                .iter()
                .find(|&&idx| self.entries[idx].name == name)
                .copied();
            let idx = found.ok_or(libc::ENOENT)?;
            self.acquire()?;
            Ok((idx as Handle, self.entries[idx].stat))
        }
        fn getattr(&mut self, node: Handle) -> Result<Stat, i32> {
            Ok(self.entries[node as usize].stat)
        }
        fn readdir(&mut self, node: Handle) -> Result<Vec<DirItem>, i32> {
            let Kind::Dir(children) = &self.entries[node as usize].kind else {
                return Err(libc::ENOTDIR);
            };
            Ok(children
                .iter()
                .map(|&idx| DirItem {
                    name: self.entries[idx].name.clone(),
                    stat: self.entries[idx].stat,
                })
                .collect())
        }
        fn readlink(&mut self, node: Handle) -> Result<String, i32> {
            match &self.entries[node as usize].kind {
                Kind::Link(target) => Ok(target.clone()),
                _ => Err(libc::EINVAL),
            }
        }
        fn open_read(&mut self, node: Handle) -> Result<Handle, i32> {
            match self.entries[node as usize].kind {
                Kind::File(_) => {
                    self.acquire()?;
                    Ok(node)
                }
                _ => Err(libc::EISDIR),
            }
        }
        fn read_at(
            &mut self,
            handle: Handle,
            offset: u64,
            len: usize,
        ) -> Result<(Vec<u8>, bool), i32> {
            let Kind::File(data) = &self.entries[handle as usize].kind else {
                return Err(libc::EIO);
            };
            let start = usize::try_from(offset)
                .unwrap_or(data.len())
                .min(data.len());
            let end = start.saturating_add(len).min(data.len());
            Ok((data[start..end].to_vec(), end >= data.len()))
        }
        fn statfs(&mut self, _node: Handle) -> Result<Statfs, i32> {
            Ok(Statfs {
                blocks: 1000,
                bfree: 500,
                bavail: 400,
                files: 100,
                ffree: 50,
                bsize: 4096,
                namemax: 255,
            })
        }
        fn close(&mut self, _handle: Handle) {
            self.open = self.open.saturating_sub(1);
        }
    }

    fn server(fs: MockFs) -> Server<MockFs> {
        Server::new(fs, 64).expect("root")
    }

    fn call(server: &mut Server<MockFs>, request: Request) -> ReplyBody {
        let frame = RequestFrame { id: 1, request };
        let reply = server.dispatch(&frame).expect("reply");
        match reply.result {
            Ok(body) => body,
            Err(error) => panic!("unexpected errno {}", error.errno),
        }
    }

    fn call_err(server: &mut Server<MockFs>, request: Request) -> i32 {
        let frame = RequestFrame { id: 1, request };
        match server.dispatch(&frame).expect("reply").result {
            Ok(_) => panic!("expected an error"),
            Err(error) => error.errno,
        }
    }

    #[test]
    fn statfs_reports_backing() {
        let mut srv = server(sample());
        match call(&mut srv, Request::Statfs) {
            ReplyBody::Statfs(statfs) => assert_eq!(statfs.namemax, 255),
            _ => panic!("wrong body"),
        }
    }

    #[test]
    fn lookup_then_read_os_release() {
        let mut srv = server(sample());
        let etc = match call(
            &mut srv,
            Request::Lookup {
                parent: 1,
                name: "etc".into(),
            },
        ) {
            ReplyBody::Attr(attr) => attr.node_id,
            _ => panic!("wrong body"),
        };
        let file = match call(
            &mut srv,
            Request::Lookup {
                parent: etc,
                name: "os-release".into(),
            },
        ) {
            ReplyBody::Attr(attr) => attr.node_id,
            _ => panic!("wrong body"),
        };
        let handle = match call(
            &mut srv,
            Request::Open {
                node: file,
                mode: 0,
            },
        ) {
            ReplyBody::Open { handle } => handle,
            _ => panic!("wrong body"),
        };
        match call(
            &mut srv,
            Request::Read {
                handle,
                offset: 0,
                length: 64,
            },
        ) {
            ReplyBody::Read { data, eof } => {
                assert_eq!(data, b"NAME=msl\n");
                assert!(eof);
            }
            _ => panic!("wrong body"),
        }
    }

    #[test]
    fn sequential_reads_through_one_handle() {
        let mut srv = server(sample());
        let os = match call(
            &mut srv,
            Request::Lookup {
                parent: 1,
                name: "os".into(),
            },
        ) {
            ReplyBody::Attr(attr) => attr.node_id,
            _ => panic!("wrong body"),
        };
        let handle = match call(&mut srv, Request::Open { node: os, mode: 0 }) {
            ReplyBody::Open { handle } => handle,
            _ => panic!("wrong body"),
        };
        let first = call(
            &mut srv,
            Request::Read {
                handle,
                offset: 0,
                length: 2,
            },
        );
        let second = call(
            &mut srv,
            Request::Read {
                handle,
                offset: 2,
                length: 2,
            },
        );
        match (first, second) {
            (ReplyBody::Read { data: a, eof: e0 }, ReplyBody::Read { data: b, eof: e1 }) => {
                assert_eq!(a, b"hi");
                assert!(!e0);
                assert_eq!(b, b"\n");
                assert!(e1);
            }
            _ => panic!("wrong body"),
        }
    }

    #[test]
    fn readdirplus_returns_entries_with_attrs() {
        let mut srv = server(sample());
        match call(
            &mut srv,
            Request::Readdirplus {
                node: 1,
                cookie: 0,
                max_entries: 64,
                wanted: 0,
            },
        ) {
            ReplyBody::Readdirplus { eof, entries, .. } => {
                assert!(eof);
                let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();
                assert!(names.contains(&"etc"));
                assert!(names.contains(&"os"));
                let etc = entries.iter().find(|e| e.name == "etc").unwrap();
                assert_eq!(etc.attr.item_type, msl_wire::fs::ItemType::Dir);
            }
            _ => panic!("wrong body"),
        }
    }

    #[test]
    fn readlink_returns_target() {
        let mut srv = server(sample());
        let link = match call(
            &mut srv,
            Request::Lookup {
                parent: 1,
                name: "link".into(),
            },
        ) {
            ReplyBody::Attr(attr) => attr.node_id,
            _ => panic!("wrong body"),
        };
        match call(&mut srv, Request::Readlink { node: link }) {
            ReplyBody::Readlink { target } => assert_eq!(target, "os"),
            _ => panic!("wrong body"),
        }
    }

    #[test]
    fn rejects_traversal_name() {
        let mut srv = server(sample());
        assert_eq!(
            call_err(
                &mut srv,
                Request::Lookup {
                    parent: 1,
                    name: "..".into()
                }
            ),
            libc::EINVAL
        );
        assert_eq!(
            call_err(
                &mut srv,
                Request::Lookup {
                    parent: 1,
                    name: "a/b".into()
                }
            ),
            libc::EINVAL
        );
    }

    #[test]
    fn missing_entry_is_enoent() {
        let mut srv = server(sample());
        assert_eq!(
            call_err(
                &mut srv,
                Request::Lookup {
                    parent: 1,
                    name: "nope".into()
                }
            ),
            libc::ENOENT
        );
    }

    #[test]
    fn read_after_close_is_stale() {
        let mut srv = server(sample());
        let os = match call(
            &mut srv,
            Request::Lookup {
                parent: 1,
                name: "os".into(),
            },
        ) {
            ReplyBody::Attr(attr) => attr.node_id,
            _ => panic!("wrong body"),
        };
        let handle = match call(&mut srv, Request::Open { node: os, mode: 0 }) {
            ReplyBody::Open { handle } => handle,
            _ => panic!("wrong body"),
        };
        call(&mut srv, Request::CloseFile { handle });
        assert_eq!(
            call_err(
                &mut srv,
                Request::Read {
                    handle,
                    offset: 0,
                    length: 4
                }
            ),
            libc::ESTALE
        );
    }

    // Root holds `count` sibling files, exceeding the fd cache so a full browse
    // forces LRU eviction of visited siblings (never an in-use ancestor).
    fn wide(count: usize) -> MockFs {
        let mut entries = vec![Entry {
            name: "/".into(),
            stat: dir_stat(1),
            kind: Kind::Dir((1..=count).collect()),
        }];
        for index in 1..=count {
            // bounded: count
            entries.push(Entry {
                name: format!("file{index}"),
                stat: file_stat(100 + index as u64, 4),
                kind: Kind::File(b"data".to_vec()),
            });
        }
        MockFs {
            entries,
            open: 0,
            budget: 32,
        }
    }

    #[test]
    fn fd_pressure_evicts_and_still_browses() {
        // fd cap of 4 with 20 siblings: eviction must keep browse succeeding.
        let mut srv = Server::new(wide(20), 4).expect("root");
        for index in 1..=20 {
            // bounded: 20 siblings
            let name = format!("file{index}");
            let node = match call(
                &mut srv,
                Request::Lookup {
                    parent: 1,
                    name: name.clone(),
                },
            ) {
                ReplyBody::Attr(attr) => attr.node_id,
                _ => panic!("wrong body"),
            };
            match call(&mut srv, Request::Getattr { node, wanted: 0 }) {
                ReplyBody::Attr(attr) => assert_eq!(attr.item_type, msl_wire::fs::ItemType::File),
                _ => panic!("lookup/getattr under fd pressure must succeed for {name}"),
            }
        }
    }

    #[test]
    fn close_ends_the_session() {
        let mut srv = server(sample());
        let frame = RequestFrame {
            id: 9,
            request: Request::Close,
        };
        assert!(srv.dispatch(&frame).is_none());
    }
}
