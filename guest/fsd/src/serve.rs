//! The request dispatcher: decode one `fs` request, drive the backend through
//! the node table, and encode the reply. Generic over `Backend` so the whole
//! dispatch is host-tested against an in-memory mock.

use std::collections::HashMap;

use crate::backend::Backend;
use crate::names::is_valid_component;
use crate::nodes::{NodeTable, ROOT_ID};
use crate::stat;
use msl_wire::fs::{DirEntry, ItemType, ReplyBody, ReplyFrame, Request, RequestFrame, SetAttr};

/// Serves file operations for one mounted volume over one backend.
pub struct Server<B: Backend> {
    backend: B,
    nodes: NodeTable,
    next_handle: u64,
    open_reads: HashMap<u64, i32>,
    read_only: bool,
}

impl<B: Backend> Server<B> {
    /// Open the root authority and seed the node table. `fd_cap` bounds cached
    /// node handles.
    pub fn new(mut backend: B, fd_cap: usize, read_only: bool) -> Result<Self, i32> {
        let root = backend.root()?;
        Ok(Self {
            backend,
            nodes: NodeTable::new(root, fd_cap),
            next_handle: 1,
            open_reads: HashMap::new(),
            read_only,
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
            Request::Sync => self.sync(),
            Request::Close => Ok(ReplyBody::Empty),
            Request::Write { node, offset, data } => self.write(*node, *offset, data),
            Request::Setattr { node, setattr } => self.setattr(*node, *setattr),
            Request::Create {
                parent,
                name,
                item_type,
                mode,
                uid,
                gid,
            } => self.create(*parent, name, *item_type, *mode, *uid, *gid),
            Request::Symlink {
                parent,
                name,
                target,
                uid,
                gid,
            } => self.symlink(*parent, name, target, *uid, *gid),
            Request::Link {
                node,
                new_parent,
                new_name,
            } => self.link(*node, *new_parent, new_name),
            Request::Remove {
                parent,
                name,
                item_type,
            } => self.remove(*parent, name, *item_type),
            Request::Rename {
                node,
                src_parent,
                src_name,
                dst_parent,
                dst_name,
                flags,
            } => self.rename(*node, *src_parent, src_name, *dst_parent, dst_name, *flags),
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
        let node_id = self
            .nodes
            .observe_child(parent, name, child_stat.item_type());
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
            let child_id = self
                .nodes
                .observe_child(node, &item.name, item.stat.item_type());
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

    fn sync(&mut self) -> Result<ReplyBody, i32> {
        let root = self.nodes.resolve(ROOT_ID, &mut self.backend)?;
        self.backend.sync(root)?;
        Ok(ReplyBody::Empty)
    }

    fn write(&mut self, node: u64, offset: u64, data: &[u8]) -> Result<ReplyBody, i32> {
        self.ensure_writable()?;
        let handle = self.nodes.resolve(node, &mut self.backend)?;
        let (count, value) = self.backend.write_at(handle, offset, data)?;
        let parent = self.nodes.parent_of(node).unwrap_or(0);
        Ok(ReplyBody::Write {
            count: u32::try_from(count).map_err(|_| libc::EOVERFLOW)?,
            attr: stat::to_attr(node, parent, &value),
        })
    }

    fn setattr(&mut self, node: u64, setattr: SetAttr) -> Result<ReplyBody, i32> {
        self.ensure_writable()?;
        let handle = self.nodes.resolve(node, &mut self.backend)?;
        let value = self.backend.setattr(handle, setattr)?;
        let parent = self.nodes.parent_of(node).unwrap_or(0);
        Ok(ReplyBody::Attr(stat::to_attr(node, parent, &value)))
    }

    fn create(
        &mut self,
        parent: u64,
        name: &str,
        item_type: ItemType,
        mode: u32,
        uid: u32,
        gid: u32,
    ) -> Result<ReplyBody, i32> {
        self.ensure_name_writable(name)?;
        let parent_handle = self.nodes.resolve(parent, &mut self.backend)?;
        let (handle, value) =
            self.backend
                .create(parent_handle, name, item_type, mode, uid, gid)?;
        let node =
            self.nodes
                .attach_child(parent, name, value.item_type(), handle, &mut self.backend);
        Ok(ReplyBody::Attr(stat::to_attr(node, parent, &value)))
    }

    fn symlink(
        &mut self,
        parent: u64,
        name: &str,
        target: &str,
        uid: u32,
        gid: u32,
    ) -> Result<ReplyBody, i32> {
        self.ensure_name_writable(name)?;
        let parent_handle = self.nodes.resolve(parent, &mut self.backend)?;
        let (handle, value) = self
            .backend
            .symlink(parent_handle, name, target, uid, gid)?;
        let node =
            self.nodes
                .attach_child(parent, name, value.item_type(), handle, &mut self.backend);
        Ok(ReplyBody::Attr(stat::to_attr(node, parent, &value)))
    }

    fn link(&mut self, node: u64, new_parent: u64, new_name: &str) -> Result<ReplyBody, i32> {
        self.ensure_name_writable(new_name)?;
        let handle = self.nodes.resolve(node, &mut self.backend)?;
        let parent_handle = self.nodes.resolve(new_parent, &mut self.backend)?;
        let (linked_handle, value) = self.backend.link(handle, parent_handle, new_name)?;
        let linked = self.nodes.attach_child(
            new_parent,
            new_name,
            value.item_type(),
            linked_handle,
            &mut self.backend,
        );
        Ok(ReplyBody::Attr(stat::to_attr(linked, new_parent, &value)))
    }

    fn remove(&mut self, parent: u64, name: &str, item_type: ItemType) -> Result<ReplyBody, i32> {
        self.ensure_name_writable(name)?;
        let parent_handle = self.nodes.resolve(parent, &mut self.backend)?;
        self.backend.remove(parent_handle, name, item_type)?;
        self.nodes.remove_child(parent, name, &mut self.backend);
        Ok(ReplyBody::Empty)
    }

    fn rename(
        &mut self,
        node: u64,
        src_parent: u64,
        src_name: &str,
        dst_parent: u64,
        dst_name: &str,
        flags: u8,
    ) -> Result<ReplyBody, i32> {
        self.ensure_name_writable(src_name)?;
        validate_component(dst_name)?;
        if flags & !1 != 0 {
            return Err(libc::EINVAL);
        }
        self.nodes.expect_child(node, src_parent, src_name)?;
        let handle = self.nodes.resolve(node, &mut self.backend)?;
        let src_handle = self.nodes.resolve(src_parent, &mut self.backend)?;
        let dst_handle = self.nodes.resolve(dst_parent, &mut self.backend)?;
        let result = self.backend.rename(
            handle,
            src_handle,
            src_name,
            dst_handle,
            dst_name,
            flags & 1 != 0,
        )?;
        if result.moved {
            self.nodes.rename_child(
                node,
                src_parent,
                src_name,
                dst_parent,
                dst_name,
                &mut self.backend,
            )?;
        }
        let parent = if result.moved { dst_parent } else { src_parent };
        Ok(ReplyBody::Attr(stat::to_attr(node, parent, &result.stat)))
    }

    fn ensure_name_writable(&self, name: &str) -> Result<(), i32> {
        self.ensure_writable()?;
        validate_component(name)
    }

    const fn ensure_writable(&self) -> Result<(), i32> {
        if self.read_only {
            return Err(libc::EROFS);
        }
        Ok(())
    }
}

fn errno_message(errno: i32) -> String {
    format!("errno {errno}")
}

fn validate_component(name: &str) -> Result<(), i32> {
    if is_valid_component(name) {
        Ok(())
    } else {
        Err(libc::EINVAL)
    }
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
    use crate::backend::{Backend, DirItem, Handle, RenameResult};
    use crate::names::is_valid_component;
    use crate::stat::Stat;
    use msl_wire::fs::{
        ItemType, ReplyBody, Request, RequestFrame, SETATTR_ATIME, SETATTR_GID, SETATTR_MODE,
        SETATTR_MTIME, SETATTR_SIZE, SETATTR_UID, SetAttr, Statfs,
    };

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
    fn symlink_stat(ino: u64, size: u64, uid: u32, gid: u32) -> Stat {
        Stat {
            ino,
            mode: 0o120_777,
            uid,
            gid,
            nlink: 1,
            size,
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
                stat: symlink_stat(12, 2, 0, 0),
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

        fn child_pos(&self, parent: Handle, name: &str) -> Result<(usize, usize), i32> {
            if !is_valid_component(name) {
                return Err(libc::EINVAL);
            }
            let Kind::Dir(children) = &self.entries[parent as usize].kind else {
                return Err(libc::ENOTDIR);
            };
            children
                .iter()
                .position(|&idx| self.entries[idx].name == name)
                .map_or(Err(libc::ENOENT), |pos| Ok((pos, children[pos])))
        }

        fn find_child(&self, parent: Handle, name: &str) -> Result<usize, i32> {
            self.child_pos(parent, name).map(|(_, idx)| idx)
        }

        fn ensure_absent(&self, parent: Handle, name: &str) -> Result<(), i32> {
            match self.find_child(parent, name) {
                Ok(_) => Err(libc::EEXIST),
                Err(libc::ENOENT) => Ok(()),
                Err(err) => Err(err),
            }
        }

        fn add_child(&mut self, parent: Handle, entry: Entry) -> Result<usize, i32> {
            let idx = self.entries.len();
            let Kind::Dir(children) = &mut self.entries[parent as usize].kind else {
                return Err(libc::ENOTDIR);
            };
            children.push(idx);
            self.entries.push(entry);
            Ok(idx)
        }

        fn remove_child_at(&mut self, parent: Handle, pos: usize) -> Result<usize, i32> {
            let Kind::Dir(children) = &mut self.entries[parent as usize].kind else {
                return Err(libc::ENOTDIR);
            };
            if pos >= children.len() {
                return Err(libc::ENOENT);
            }
            Ok(children.remove(pos))
        }

        fn ino(&self) -> u64 {
            1_000 + self.entries.len() as u64
        }

        fn prepare_rename_dst(
            &mut self,
            src_idx: usize,
            dst_parent: Handle,
            dst_name: &str,
            replace: bool,
        ) -> Result<(), i32> {
            match self.child_pos(dst_parent, dst_name) {
                Ok((_, dst_idx)) if dst_idx == src_idx && replace => Ok(()),
                Ok((_, dst_idx)) if dst_idx == src_idx => Err(libc::EEXIST),
                Ok((pos, dst_idx)) if replace => {
                    self.ensure_replace_ok(src_idx, dst_idx)?;
                    self.remove_child_at(dst_parent, pos)?;
                    Ok(())
                }
                Ok(_) => Err(libc::EEXIST),
                Err(libc::ENOENT) => Ok(()),
                Err(err) => Err(err),
            }
        }

        fn destination_is_same_file(
            &self,
            src_idx: usize,
            dst_parent: Handle,
            dst_name: &str,
        ) -> Result<bool, i32> {
            match self.child_pos(dst_parent, dst_name) {
                Ok((_, dst_idx)) => {
                    Ok(self.entries[src_idx].stat.ino == self.entries[dst_idx].stat.ino)
                }
                Err(libc::ENOENT) => Ok(false),
                Err(err) => Err(err),
            }
        }

        fn ensure_replace_ok(&self, src_idx: usize, dst_idx: usize) -> Result<(), i32> {
            match (&self.entries[src_idx].kind, &self.entries[dst_idx].kind) {
                (Kind::Dir(_), Kind::Dir(children)) if !children.is_empty() => Err(libc::ENOTEMPTY),
                (Kind::Dir(_), Kind::Dir(_)) => Ok(()),
                (Kind::Dir(_), _) => Err(libc::ENOTDIR),
                (_, Kind::Dir(_)) => Err(libc::EISDIR),
                _ => Ok(()),
            }
        }

        fn add_renamed_child(&mut self, parent: Handle, idx: usize) -> Result<(), i32> {
            let Kind::Dir(children) = &mut self.entries[parent as usize].kind else {
                return Err(libc::ENOTDIR);
            };
            children.push(idx);
            Ok(())
        }
    }

    impl Backend for MockFs {
        fn root(&mut self) -> Result<Handle, i32> {
            self.acquire()?;
            Ok(0)
        }
        fn lookup(&mut self, parent: Handle, name: &str) -> Result<(Handle, Stat), i32> {
            let idx = self.find_child(parent, name)?;
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
        fn sync(&mut self, _root: Handle) -> Result<(), i32> {
            Ok(())
        }
        fn write_at(
            &mut self,
            node: Handle,
            offset: u64,
            data: &[u8],
        ) -> Result<(usize, Stat), i32> {
            let idx = node as usize;
            let Kind::File(contents) = &mut self.entries[idx].kind else {
                return Err(libc::EINVAL);
            };
            let start = usize::try_from(offset).map_err(|_| libc::EINVAL)?;
            let end = start.checked_add(data.len()).ok_or(libc::EFBIG)?;
            if start > contents.len() {
                contents.resize(start, 0);
            }
            if end > contents.len() {
                contents.resize(end, 0);
            }
            contents[start..end].copy_from_slice(data);
            self.entries[idx].stat.size = contents.len() as u64;
            self.entries[idx].stat.blocks = self.entries[idx].stat.size.div_ceil(512);
            Ok((data.len(), self.entries[idx].stat))
        }
        fn setattr(&mut self, node: Handle, setattr: SetAttr) -> Result<Stat, i32> {
            if setattr.mask
                & !(SETATTR_MODE
                    | SETATTR_UID
                    | SETATTR_GID
                    | SETATTR_SIZE
                    | SETATTR_ATIME
                    | SETATTR_MTIME)
                != 0
            {
                return Err(libc::EINVAL);
            }
            apply_mock_attr(&mut self.entries[node as usize], setattr)?;
            Ok(self.entries[node as usize].stat)
        }
        fn create(
            &mut self,
            parent: Handle,
            name: &str,
            item_type: ItemType,
            mode: u32,
            uid: u32,
            gid: u32,
        ) -> Result<(Handle, Stat), i32> {
            self.ensure_absent(parent, name)?;
            let entry = new_mock_entry(self.ino(), name, item_type, mode, uid, gid)?;
            let idx = self.add_child(parent, entry)?;
            Ok((idx as Handle, self.entries[idx].stat))
        }
        fn symlink(
            &mut self,
            parent: Handle,
            name: &str,
            target: &str,
            uid: u32,
            gid: u32,
        ) -> Result<(Handle, Stat), i32> {
            self.ensure_absent(parent, name)?;
            let stat = symlink_stat(self.ino(), target.len() as u64, uid, gid);
            let entry = Entry {
                name: name.into(),
                stat,
                kind: Kind::Link(target.into()),
            };
            let idx = self.add_child(parent, entry)?;
            Ok((idx as Handle, stat))
        }
        fn link(
            &mut self,
            node: Handle,
            new_parent: Handle,
            new_name: &str,
        ) -> Result<(Handle, Stat), i32> {
            self.ensure_absent(new_parent, new_name)?;
            if matches!(self.entries[node as usize].kind, Kind::Dir(_)) {
                return Err(libc::EPERM);
            }
            self.entries[node as usize].stat.nlink += 1;
            let mut entry = clone_link_entry(&self.entries[node as usize], new_name);
            entry.stat = self.entries[node as usize].stat;
            let idx = self.add_child(new_parent, entry)?;
            Ok((idx as Handle, self.entries[idx].stat))
        }
        fn remove(&mut self, parent: Handle, name: &str, item_type: ItemType) -> Result<(), i32> {
            let (pos, idx) = self.child_pos(parent, name)?;
            if item_type == ItemType::Dir {
                match &self.entries[idx].kind {
                    Kind::Dir(children) if children.is_empty() => {}
                    Kind::Dir(_) => return Err(libc::ENOTEMPTY),
                    _ => return Err(libc::ENOTDIR),
                }
            } else if matches!(self.entries[idx].kind, Kind::Dir(_)) {
                return Err(libc::EISDIR);
            }
            self.remove_child_at(parent, pos)?;
            Ok(())
        }
        fn rename(
            &mut self,
            node: Handle,
            src_parent: Handle,
            src_name: &str,
            dst_parent: Handle,
            dst_name: &str,
            replace: bool,
        ) -> Result<RenameResult, i32> {
            let (_, src_idx) = self.child_pos(src_parent, src_name)?;
            if src_idx != node as usize {
                return Err(libc::ESTALE);
            }
            if replace && self.destination_is_same_file(src_idx, dst_parent, dst_name)? {
                return Ok(RenameResult {
                    stat: self.entries[src_idx].stat,
                    moved: false,
                });
            }
            self.prepare_rename_dst(src_idx, dst_parent, dst_name, replace)?;
            let (src_pos, _) = self.child_pos(src_parent, src_name)?;
            self.remove_child_at(src_parent, src_pos)?;
            self.entries[src_idx].name = dst_name.into();
            self.add_renamed_child(dst_parent, src_idx)?;
            Ok(RenameResult {
                stat: self.entries[src_idx].stat,
                moved: true,
            })
        }
        fn close(&mut self, _handle: Handle) {
            self.open = self.open.saturating_sub(1);
        }
    }

    fn new_mock_entry(
        ino: u64,
        name: &str,
        item_type: ItemType,
        mode: u32,
        uid: u32,
        gid: u32,
    ) -> Result<Entry, i32> {
        if !is_valid_component(name) {
            return Err(libc::EINVAL);
        }
        match item_type {
            ItemType::File => Ok(Entry {
                name: name.into(),
                stat: typed_stat(ino, 0o100_000, mode, uid, gid, 0),
                kind: Kind::File(Vec::new()),
            }),
            ItemType::Dir => Ok(Entry {
                name: name.into(),
                stat: typed_stat(ino, 0o040_000, mode, uid, gid, 4096),
                kind: Kind::Dir(Vec::new()),
            }),
            _ => Err(libc::EOPNOTSUPP),
        }
    }

    fn typed_stat(ino: u64, kind: u32, mode: u32, uid: u32, gid: u32, size: u64) -> Stat {
        Stat {
            ino,
            mode: kind | (mode & 0o7777),
            uid,
            gid,
            nlink: if kind == 0o040_000 { 2 } else { 1 },
            size,
            blocks: size.div_ceil(512),
            atime: (1, 0),
            mtime: (2, 0),
            ctime: (3, 0),
        }
    }

    fn clone_link_entry(entry: &Entry, name: &str) -> Entry {
        let kind = match &entry.kind {
            Kind::File(data) => Kind::File(data.clone()),
            Kind::Link(target) => Kind::Link(target.clone()),
            Kind::Dir(children) => Kind::Dir(children.clone()),
        };
        Entry {
            name: name.into(),
            stat: entry.stat,
            kind,
        }
    }

    fn apply_mock_attr(entry: &mut Entry, setattr: SetAttr) -> Result<(), i32> {
        if setattr.mask & SETATTR_SIZE != 0 {
            resize_mock_file(entry, setattr.size)?;
        }
        if setattr.mask & SETATTR_MODE != 0 {
            entry.stat.mode = (entry.stat.mode & !0o7777) | (setattr.mode & 0o7777);
        }
        if setattr.mask & SETATTR_UID != 0 {
            entry.stat.uid = setattr.uid;
        }
        if setattr.mask & SETATTR_GID != 0 {
            entry.stat.gid = setattr.gid;
        }
        apply_mock_times(entry, setattr);
        Ok(())
    }

    fn resize_mock_file(entry: &mut Entry, size: u64) -> Result<(), i32> {
        let Kind::File(data) = &mut entry.kind else {
            return Err(libc::EINVAL);
        };
        let len = usize::try_from(size).map_err(|_| libc::EFBIG)?;
        data.resize(len, 0);
        entry.stat.size = size;
        entry.stat.blocks = size.div_ceil(512);
        Ok(())
    }

    fn apply_mock_times(entry: &mut Entry, setattr: SetAttr) {
        if setattr.mask & SETATTR_ATIME != 0 {
            entry.stat.atime = (setattr.atime.sec, setattr.atime.nsec);
        }
        if setattr.mask & SETATTR_MTIME != 0 {
            entry.stat.mtime = (setattr.mtime.sec, setattr.mtime.nsec);
        }
    }

    fn server(fs: MockFs) -> Server<MockFs> {
        Server::new(fs, 64, false).expect("root")
    }

    fn read_only_server(fs: MockFs) -> Server<MockFs> {
        Server::new(fs, 64, true).expect("root")
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

    fn lookup_node(server: &mut Server<MockFs>, parent: u64, name: &str) -> u64 {
        match call(
            server,
            Request::Lookup {
                parent,
                name: name.into(),
            },
        ) {
            ReplyBody::Attr(attr) => attr.node_id,
            _ => panic!("wrong body"),
        }
    }

    fn open_node(server: &mut Server<MockFs>, node: u64) -> u64 {
        match call(server, Request::Open { node, mode: 0 }) {
            ReplyBody::Open { handle } => handle,
            _ => panic!("wrong body"),
        }
    }

    fn read_bytes(server: &mut Server<MockFs>, node: u64, length: u32) -> Vec<u8> {
        let handle = open_node(server, node);
        match call(
            server,
            Request::Read {
                handle,
                offset: 0,
                length,
            },
        ) {
            ReplyBody::Read { data, .. } => data,
            _ => panic!("wrong body"),
        }
    }

    fn create_node(
        server: &mut Server<MockFs>,
        parent: u64,
        name: &str,
        item_type: ItemType,
    ) -> u64 {
        match call(
            server,
            Request::Create {
                parent,
                name: name.into(),
                item_type,
                mode: 0o755,
                uid: 1000,
                gid: 1000,
            },
        ) {
            ReplyBody::Attr(attr) => attr.node_id,
            _ => panic!("wrong body"),
        }
    }

    fn write_ok(server: &mut Server<MockFs>, node: u64, offset: u64, data: &[u8]) {
        match call(
            server,
            Request::Write {
                node,
                offset,
                data: data.to_vec(),
            },
        ) {
            ReplyBody::Write { count, attr } => {
                assert_eq!(usize::try_from(count).unwrap(), data.len());
                assert!(attr.size >= u64::try_from(data.len()).unwrap());
            }
            _ => panic!("wrong body"),
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

    #[test]
    fn write_readback_and_offset_write() {
        let mut srv = server(sample());
        let os = lookup_node(&mut srv, 1, "os");
        write_ok(&mut srv, os, 0, b"bye");
        assert_eq!(read_bytes(&mut srv, os, 8), b"bye");
        write_ok(&mut srv, os, 1, b"I");
        assert_eq!(read_bytes(&mut srv, os, 8), b"bIe");
    }

    #[test]
    fn truncate_with_setattr() {
        let mut srv = server(sample());
        let os = lookup_node(&mut srv, 1, "os");
        let shrink = SetAttr {
            mask: SETATTR_SIZE,
            size: 1,
            ..SetAttr::default()
        };
        match call(
            &mut srv,
            Request::Setattr {
                node: os,
                setattr: shrink,
            },
        ) {
            ReplyBody::Attr(attr) => assert_eq!(attr.size, 1),
            _ => panic!("wrong body"),
        }
        assert_eq!(read_bytes(&mut srv, os, 8), b"h");
    }

    #[test]
    fn create_file_and_directory() {
        let mut srv = server(sample());
        let file = create_node(&mut srv, 1, "new", ItemType::File);
        write_ok(&mut srv, file, 0, b"created");
        assert_eq!(read_bytes(&mut srv, file, 16), b"created");
        let dir = create_node(&mut srv, 1, "dir", ItemType::Dir);
        match call(
            &mut srv,
            Request::Getattr {
                node: dir,
                wanted: 0,
            },
        ) {
            ReplyBody::Attr(attr) => assert_eq!(attr.item_type, ItemType::Dir),
            _ => panic!("wrong body"),
        }
    }

    #[test]
    fn symlink_returns_payload() {
        let mut srv = server(sample());
        let link = match call(
            &mut srv,
            Request::Symlink {
                parent: 1,
                name: "sym".into(),
                target: "../target".into(),
                uid: 1000,
                gid: 1000,
            },
        ) {
            ReplyBody::Attr(attr) => attr.node_id,
            _ => panic!("wrong body"),
        };
        match call(&mut srv, Request::Readlink { node: link }) {
            ReplyBody::Readlink { target } => assert_eq!(target, "../target"),
            _ => panic!("wrong body"),
        }
    }

    #[test]
    fn hard_link_reads_existing_file() {
        let mut srv = server(sample());
        let os = lookup_node(&mut srv, 1, "os");
        let hard = match call(
            &mut srv,
            Request::Link {
                node: os,
                new_parent: 1,
                new_name: "hard".into(),
            },
        ) {
            ReplyBody::Attr(attr) => {
                assert_eq!(attr.nlink, 2);
                attr.node_id
            }
            _ => panic!("wrong body"),
        };
        assert_eq!(read_bytes(&mut srv, hard, 8), b"hi\n");
    }

    #[test]
    fn rename_over_hard_link_alias_preserves_both_names() {
        let mut srv = server(sample());
        let os = lookup_node(&mut srv, 1, "os");
        let hard = match call(
            &mut srv,
            Request::Link {
                node: os,
                new_parent: 1,
                new_name: "hard".into(),
            },
        ) {
            ReplyBody::Attr(attr) => attr.node_id,
            _ => panic!("wrong body"),
        };
        let alias_rename = Request::Rename {
            node: os,
            src_parent: 1,
            src_name: "os".into(),
            dst_parent: 1,
            dst_name: "hard".into(),
            flags: 0,
        };
        assert_eq!(call_err(&mut srv, alias_rename), libc::EEXIST);
        match call(
            &mut srv,
            Request::Rename {
                node: os,
                src_parent: 1,
                src_name: "os".into(),
                dst_parent: 1,
                dst_name: "hard".into(),
                flags: 1,
            },
        ) {
            ReplyBody::Attr(attr) => assert_eq!(attr.node_id, os),
            _ => panic!("wrong body"),
        }
        assert_eq!(lookup_node(&mut srv, 1, "os"), os);
        assert_eq!(lookup_node(&mut srv, 1, "hard"), hard);
    }

    #[test]
    fn same_dir_and_cross_dir_rename() {
        let mut srv = server(sample());
        let os = lookup_node(&mut srv, 1, "os");
        call(
            &mut srv,
            Request::Rename {
                node: os,
                src_parent: 1,
                src_name: "os".into(),
                dst_parent: 1,
                dst_name: "renamed".into(),
                flags: 1,
            },
        );
        assert_eq!(
            call_err(
                &mut srv,
                Request::Lookup {
                    parent: 1,
                    name: "os".into()
                }
            ),
            libc::ENOENT
        );
        let renamed = lookup_node(&mut srv, 1, "renamed");
        assert_eq!(renamed, os);
        let etc = lookup_node(&mut srv, 1, "etc");
        call(
            &mut srv,
            Request::Rename {
                node: os,
                src_parent: 1,
                src_name: "renamed".into(),
                dst_parent: etc,
                dst_name: "moved".into(),
                flags: 1,
            },
        );
        assert_eq!(lookup_node(&mut srv, etc, "moved"), os);
    }

    #[test]
    fn rename_overwrite_and_no_overwrite() {
        let mut srv = server(sample());
        let a = create_node(&mut srv, 1, "a", ItemType::File);
        let b = create_node(&mut srv, 1, "b", ItemType::File);
        write_ok(&mut srv, a, 0, b"aaa");
        assert_eq!(
            call_err(
                &mut srv,
                Request::Rename {
                    node: a,
                    src_parent: 1,
                    src_name: "a".into(),
                    dst_parent: 1,
                    dst_name: "b".into(),
                    flags: 0,
                }
            ),
            libc::EEXIST
        );
        call(
            &mut srv,
            Request::Rename {
                node: a,
                src_parent: 1,
                src_name: "a".into(),
                dst_parent: 1,
                dst_name: "b".into(),
                flags: 1,
            },
        );
        assert_eq!(read_bytes(&mut srv, a, 8), b"aaa");
        assert_eq!(
            call_err(&mut srv, Request::Getattr { node: b, wanted: 0 }),
            libc::ESTALE
        );
    }

    #[test]
    fn remove_file_and_empty_directory() {
        let mut srv = server(sample());
        create_node(&mut srv, 1, "gone", ItemType::File);
        call(
            &mut srv,
            Request::Remove {
                parent: 1,
                name: "gone".into(),
                item_type: ItemType::File,
            },
        );
        assert_eq!(
            call_err(
                &mut srv,
                Request::Lookup {
                    parent: 1,
                    name: "gone".into()
                }
            ),
            libc::ENOENT
        );
        create_node(&mut srv, 1, "empty", ItemType::Dir);
        call(
            &mut srv,
            Request::Remove {
                parent: 1,
                name: "empty".into(),
                item_type: ItemType::Dir,
            },
        );
        assert_eq!(
            call_err(
                &mut srv,
                Request::Lookup {
                    parent: 1,
                    name: "empty".into()
                }
            ),
            libc::ENOENT
        );
    }

    #[test]
    fn reject_non_empty_directory_remove() {
        let mut srv = server(sample());
        let dir = create_node(&mut srv, 1, "dir", ItemType::Dir);
        create_node(&mut srv, dir, "child", ItemType::File);
        assert_eq!(
            call_err(
                &mut srv,
                Request::Remove {
                    parent: 1,
                    name: "dir".into(),
                    item_type: ItemType::Dir,
                }
            ),
            libc::ENOTEMPTY
        );
    }

    #[test]
    fn mutation_rejects_invalid_names() {
        let mut srv = server(sample());
        let os = lookup_node(&mut srv, 1, "os");
        assert_eq!(
            call_err(
                &mut srv,
                Request::Create {
                    parent: 1,
                    name: "a/b".into(),
                    item_type: ItemType::File,
                    mode: 0o644,
                    uid: 0,
                    gid: 0,
                }
            ),
            libc::EINVAL
        );
        assert_eq!(
            call_err(
                &mut srv,
                Request::Link {
                    node: os,
                    new_parent: 1,
                    new_name: "..".into(),
                }
            ),
            libc::EINVAL
        );
        assert_eq!(
            call_err(
                &mut srv,
                Request::Rename {
                    node: os,
                    src_parent: 1,
                    src_name: "os".into(),
                    dst_parent: 1,
                    dst_name: "bad/name".into(),
                    flags: 1,
                }
            ),
            libc::EINVAL
        );
    }

    #[test]
    fn removed_node_is_stale() {
        let mut srv = server(sample());
        let os = lookup_node(&mut srv, 1, "os");
        call(
            &mut srv,
            Request::Remove {
                parent: 1,
                name: "os".into(),
                item_type: ItemType::File,
            },
        );
        assert_eq!(
            call_err(
                &mut srv,
                Request::Getattr {
                    node: os,
                    wanted: 0
                }
            ),
            libc::ESTALE
        );
    }

    #[test]
    fn read_only_mutation_ops_return_erofs() {
        let mut srv = read_only_server(sample());
        let requests = vec![
            Request::Write {
                node: 2,
                offset: 0,
                data: b"x".to_vec(),
            },
            Request::Setattr {
                node: 2,
                setattr: SetAttr::default(),
            },
            Request::Create {
                parent: 1,
                name: "new".into(),
                item_type: ItemType::File,
                mode: 0o100_644,
                uid: 0,
                gid: 0,
            },
            Request::Symlink {
                parent: 1,
                name: "sym".into(),
                target: "os".into(),
                uid: 0,
                gid: 0,
            },
            Request::Link {
                node: 2,
                new_parent: 1,
                new_name: "hard".into(),
            },
            Request::Remove {
                parent: 1,
                name: "os".into(),
                item_type: ItemType::File,
            },
            Request::Rename {
                node: 2,
                src_parent: 1,
                src_name: "os".into(),
                dst_parent: 1,
                dst_name: "renamed".into(),
                flags: 0,
            },
        ];
        for request in requests {
            assert_eq!(call_err(&mut srv, request), libc::EROFS);
        }
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
        let mut srv = Server::new(wide(20), 4, false).expect("root");
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
