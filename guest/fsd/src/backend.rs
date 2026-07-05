//! The filesystem operations the server drives, behind a trait so the node
//! table and dispatch are host-tested against an in-memory mock while the guest
//! runs the Linux fd-backed implementation. Errors are POSIX errnos so they map
//! straight onto the wire.

use crate::stat::Stat;
use msl_wire::fs::Statfs;

/// Opaque backend handle: a Linux `O_PATH`/read fd in the real backend, an
/// index in the mock. `-1` is never a valid handle.
pub type Handle = i32;

/// One directory entry: name plus its stat (no per-child fd is opened).
#[derive(Debug, Clone)]
pub struct DirItem {
    pub name: String,
    pub stat: Stat,
}

/// Read-only filesystem access rooted at one directory. All methods report
/// POSIX errnos; `EMFILE`/`ENFILE` trigger a cache eviction and one retry.
pub trait Backend {
    /// The pinned root authority (fd-backed). Called once at startup.
    fn root(&mut self) -> Result<Handle, i32>;
    /// Resolve one component under `parent`, returning an `O_PATH` child handle.
    fn lookup(&mut self, parent: Handle, name: &str) -> Result<(Handle, Stat), i32>;
    fn getattr(&mut self, node: Handle) -> Result<Stat, i32>;
    fn readdir(&mut self, node: Handle) -> Result<Vec<DirItem>, i32>;
    fn readlink(&mut self, node: Handle) -> Result<String, i32>;
    /// Open a bounded readable fd for sequential reads of a regular file.
    fn open_read(&mut self, node: Handle) -> Result<Handle, i32>;
    fn read_at(&mut self, handle: Handle, offset: u64, len: usize) -> Result<(Vec<u8>, bool), i32>;
    fn statfs(&mut self, node: Handle) -> Result<Statfs, i32>;
    /// Release a handle (an evicted node fd or a closed read fd).
    fn close(&mut self, handle: Handle);
}
