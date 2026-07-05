//! Portable attribute mapping: the subset of `stat(2)` fields the protocol
//! carries, the Linux `st_mode` -> `ItemType` mapping, and construction of the
//! wire `Attr`. Kept free of `libc` so the host tests exercise it directly; the
//! Linux backend fills `Stat` from a real `libc::stat`.

use msl_wire::fs::{Attr, ItemType, Timespec};

// POSIX `S_IFMT` file-type bits (identical on Linux and macOS).
const S_IFMT: u32 = 0o170_000;
const S_IFSOCK: u32 = 0o140_000;
const S_IFLNK: u32 = 0o120_000;
const S_IFREG: u32 = 0o100_000;
const S_IFBLK: u32 = 0o060_000;
const S_IFDIR: u32 = 0o040_000;
const S_IFCHR: u32 = 0o020_000;
const S_IFIFO: u32 = 0o010_000;

/// The stat fields the file service reports, decoupled from `libc::stat`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Stat {
    pub ino: u64,
    pub mode: u32,
    pub uid: u32,
    pub gid: u32,
    pub nlink: u32,
    pub size: u64,
    pub blocks: u64,
    pub atime: (i64, u32),
    pub mtime: (i64, u32),
    pub ctime: (i64, u32),
}

impl Stat {
    #[must_use]
    pub const fn item_type(&self) -> ItemType {
        item_type_from_mode(self.mode)
    }
}

/// Map a Linux `st_mode` to the wire item type.
#[must_use]
pub const fn item_type_from_mode(mode: u32) -> ItemType {
    match mode & S_IFMT {
        S_IFREG => ItemType::File,
        S_IFDIR => ItemType::Dir,
        S_IFLNK => ItemType::Symlink,
        S_IFIFO => ItemType::Fifo,
        S_IFCHR => ItemType::Char,
        S_IFBLK => ItemType::Block,
        S_IFSOCK => ItemType::Socket,
        _ => ItemType::Unknown,
    }
}

/// Build a wire `Attr` for `node_id` (parent `parent_id`, 0 when unknown).
#[must_use]
pub const fn to_attr(node_id: u64, parent_id: u64, stat: &Stat) -> Attr {
    Attr {
        node_id,
        file_id: stat.ino,
        parent_id,
        item_type: stat.item_type(),
        mode: stat.mode,
        uid: stat.uid,
        gid: stat.gid,
        nlink: stat.nlink,
        size: stat.size,
        alloc_size: stat.blocks.saturating_mul(512),
        atime: Timespec {
            sec: stat.atime.0,
            nsec: stat.atime.1,
        },
        mtime: Timespec {
            sec: stat.mtime.0,
            nsec: stat.mtime.1,
        },
        ctime: Timespec {
            sec: stat.ctime.0,
            nsec: stat.ctime.1,
        },
        flags: 0,
    }
}

#[cfg(test)]
mod tests {
    use super::{Stat, item_type_from_mode, to_attr};
    use msl_wire::fs::ItemType;

    fn stat(mode: u32) -> Stat {
        Stat {
            ino: 42,
            mode,
            uid: 1000,
            gid: 1000,
            nlink: 1,
            size: 100,
            blocks: 8,
            atime: (1, 0),
            mtime: (2, 0),
            ctime: (3, 0),
        }
    }

    #[test]
    fn maps_every_file_type() {
        assert_eq!(item_type_from_mode(0o100_644), ItemType::File);
        assert_eq!(item_type_from_mode(0o040_755), ItemType::Dir);
        assert_eq!(item_type_from_mode(0o120_777), ItemType::Symlink);
        assert_eq!(item_type_from_mode(0o010_644), ItemType::Fifo);
        assert_eq!(item_type_from_mode(0o020_666), ItemType::Char);
        assert_eq!(item_type_from_mode(0o060_660), ItemType::Block);
        assert_eq!(item_type_from_mode(0o140_755), ItemType::Socket);
        assert_eq!(item_type_from_mode(0), ItemType::Unknown);
    }

    #[test]
    fn attr_carries_ids_and_alloc_size() {
        let attr = to_attr(5, 1, &stat(0o100_644));
        assert_eq!(attr.node_id, 5);
        assert_eq!(attr.parent_id, 1);
        assert_eq!(attr.file_id, 42);
        assert_eq!(attr.item_type, ItemType::File);
        assert_eq!(attr.alloc_size, 8 * 512);
    }
}
