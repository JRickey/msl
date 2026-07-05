//! Linux fd-backed filesystem access: the root and every node are `O_PATH`
//! authorities resolved by `openat` one component at a time, so a name can
//! never escape the volume. The only module permitted `unsafe`; it wraps the
//! required `libc` calls.
#![allow(unsafe_code)]

use std::ffi::CString;
use std::os::unix::io::RawFd;

use crate::backend::{Backend, DirItem, Handle};
use crate::stat::Stat;
use msl_wire::fs::Statfs;

const OPEN_FLAGS: i32 = libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC;

/// Cached-node-handle budget; a live mount pins root plus recently-used dirs.
const FD_CAP: usize = 512;

/// The guest read-only backend rooted at the distro's `/`.
pub struct LinuxBackend;

impl LinuxBackend {
    pub const fn new() -> Self {
        Self
    }
}

/// Serve file operations on the agent-supplied channel (fd 3) until the peer
/// closes or sends `close`. Returns the process exit code.
pub fn run() -> i32 {
    use std::os::unix::io::FromRawFd;
    let mut channel = unsafe { std::fs::File::from_raw_fd(3) };
    let mut server = match crate::serve::Server::new(LinuxBackend::new(), FD_CAP) {
        Ok(server) => server,
        Err(errno) => {
            eprintln!("msl-fsd: root open failed errno={errno}");
            return 1;
        }
    };
    loop {
        // sanctioned serve loop: one request per iteration until peer close
        let Ok(payload) = msl_wire::frame::read_frame(&mut channel) else {
            return 0;
        };
        let Ok(request) = msl_wire::fs::RequestFrame::decode(&payload) else {
            return 0;
        };
        let Some(reply) = server.dispatch(&request) else {
            return 0;
        };
        let Ok(bytes) = reply.encode() else {
            return 0;
        };
        if msl_wire::frame::write_frame(&mut channel, &bytes).is_err() {
            return 0;
        }
    }
}

impl Backend for LinuxBackend {
    fn root(&mut self) -> Result<Handle, i32> {
        let path = CString::new("/").map_err(|_| libc::EINVAL)?;
        let fd = unsafe {
            libc::open(
                path.as_ptr(),
                libc::O_PATH | libc::O_DIRECTORY | libc::O_CLOEXEC,
            )
        };
        if fd < 0 { Err(errno()) } else { Ok(fd) }
    }

    fn lookup(&mut self, parent: Handle, name: &str) -> Result<(Handle, Stat), i32> {
        let cname = CString::new(name).map_err(|_| libc::EINVAL)?;
        let fd = unsafe { libc::openat(parent, cname.as_ptr(), OPEN_FLAGS) };
        if fd < 0 {
            return Err(errno());
        }
        match fstat(fd) {
            Ok(stat) => Ok((fd, stat)),
            Err(err) => {
                close_fd(fd);
                Err(err)
            }
        }
    }

    fn getattr(&mut self, node: Handle) -> Result<Stat, i32> {
        fstat(node)
    }

    fn readdir(&mut self, node: Handle) -> Result<Vec<DirItem>, i32> {
        let dir = reopen(node, libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC)?;
        let result = read_entries(node, dir);
        close_fd(dir);
        result
    }

    fn readlink(&mut self, node: Handle) -> Result<String, i32> {
        let empty = CString::new("").map_err(|_| libc::EINVAL)?;
        let mut buf = vec![0u8; libc::PATH_MAX as usize];
        let len = unsafe {
            libc::readlinkat(
                node,
                empty.as_ptr(),
                buf.as_mut_ptr().cast::<libc::c_char>(),
                buf.len(),
            )
        };
        if len < 0 {
            return Err(errno());
        }
        buf.truncate(usize::try_from(len).unwrap_or(0));
        String::from_utf8(buf).map_err(|_| libc::EILSEQ)
    }

    fn open_read(&mut self, node: Handle) -> Result<Handle, i32> {
        reopen(node, libc::O_RDONLY | libc::O_CLOEXEC)
    }

    fn read_at(&mut self, handle: Handle, offset: u64, len: usize) -> Result<(Vec<u8>, bool), i32> {
        let cap = len.min(msl_wire::fs::MAX_READ_REPLY);
        let mut buf = vec![0u8; cap];
        let want = offset.try_into().unwrap_or(libc::off_t::MAX);
        let got = unsafe {
            libc::pread(
                handle,
                buf.as_mut_ptr().cast::<libc::c_void>(),
                buf.len(),
                want,
            )
        };
        if got < 0 {
            return Err(errno());
        }
        let read = usize::try_from(got).unwrap_or(0);
        buf.truncate(read);
        Ok((buf, read < cap))
    }

    fn statfs(&mut self, node: Handle) -> Result<Statfs, i32> {
        let mut raw: libc::statfs = unsafe { std::mem::zeroed() };
        let rc = unsafe { libc::fstatfs(node, &raw mut raw) };
        if rc < 0 {
            return Err(errno());
        }
        Ok(Statfs {
            blocks: raw.f_blocks,
            bfree: raw.f_bfree,
            bavail: raw.f_bavail,
            files: raw.f_files,
            ffree: raw.f_ffree,
            bsize: u32::try_from(raw.f_bsize).unwrap_or(4096),
            namemax: u32::try_from(raw.f_namelen).unwrap_or(255),
        })
    }

    fn close(&mut self, handle: Handle) {
        close_fd(handle);
    }
}

fn errno() -> i32 {
    unsafe { *libc::__errno_location() }
}

fn close_fd(fd: RawFd) {
    unsafe {
        libc::close(fd);
    }
}

/// Reopen an `O_PATH` fd with real access via `/proc/self/fd/<n>`.
fn reopen(node: Handle, flags: i32) -> Result<Handle, i32> {
    let path = CString::new(format!("/proc/self/fd/{node}")).map_err(|_| libc::EINVAL)?;
    let fd = unsafe { libc::open(path.as_ptr(), flags) };
    if fd < 0 { Err(errno()) } else { Ok(fd) }
}

// A generic `TryInto` bound stays correct where a source field is u32 on one
// musl arch and u64 on another (st_nlink); a concrete cast would be a lint on one.
fn narrow_u32<T: TryInto<u32>>(value: T, default: u32) -> u32 {
    value.try_into().unwrap_or(default)
}

// Translate an OS `stat` into the portable `Stat`; the sole conversion point so
// both fstat paths agree on width narrowing.
fn stat_from_raw(raw: &libc::stat) -> Stat {
    Stat {
        ino: raw.st_ino,
        mode: raw.st_mode,
        uid: raw.st_uid,
        gid: raw.st_gid,
        nlink: narrow_u32(raw.st_nlink, 1),
        size: u64::try_from(raw.st_size).unwrap_or(0),
        blocks: u64::try_from(raw.st_blocks).unwrap_or(0),
        atime: (raw.st_atime, narrow_u32(raw.st_atime_nsec, 0)),
        mtime: (raw.st_mtime, narrow_u32(raw.st_mtime_nsec, 0)),
        ctime: (raw.st_ctime, narrow_u32(raw.st_ctime_nsec, 0)),
    }
}

fn fstat(fd: RawFd) -> Result<Stat, i32> {
    let mut raw: libc::stat = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::fstat(fd, &raw mut raw) };
    if rc < 0 {
        return Err(errno());
    }
    Ok(stat_from_raw(&raw))
}

/// Parse `getdents64` records from a readable directory fd, fstatting each child
/// by name relative to the `O_PATH` directory node (no per-child fd is kept).
fn read_entries(node: Handle, dir: RawFd) -> Result<Vec<DirItem>, i32> {
    let mut buf = vec![0u8; 32 * 1024];
    let mut out = Vec::new();
    for _ in 0..1_048_576 {
        // bounded: at most one pass per 32 KiB block of entries
        let nread = unsafe {
            libc::syscall(
                libc::SYS_getdents64,
                dir,
                buf.as_mut_ptr().cast::<libc::c_void>(),
                buf.len(),
            )
        };
        if nread < 0 {
            return Err(errno());
        }
        if nread == 0 {
            return Ok(out);
        }
        parse_dents(node, &buf[..usize::try_from(nread).unwrap_or(0)], &mut out);
    }
    Ok(out)
}

fn parse_dents(node: Handle, block: &[u8], out: &mut Vec<DirItem>) {
    let mut offset = 0usize;
    while offset + 19 <= block.len() {
        // bounded: offset advances by d_reclen each step
        let reclen = u16::from_le_bytes([block[offset + 16], block[offset + 17]]) as usize;
        if reclen == 0 || offset + reclen > block.len() {
            return;
        }
        let name_bytes = &block[offset + 19..offset + reclen];
        let end = name_bytes
            .iter()
            .position(|&byte| byte == 0)
            .unwrap_or(name_bytes.len());
        if let Ok(name) = std::str::from_utf8(&name_bytes[..end])
            && name != "."
            && name != ".."
            && let Ok(stat) = fstatat_name(node, name)
        {
            out.push(DirItem {
                name: name.to_string(),
                stat,
            });
        }
        offset += reclen;
    }
}

fn fstatat_name(node: Handle, name: &str) -> Result<Stat, i32> {
    let cname = CString::new(name).map_err(|_| libc::EINVAL)?;
    let mut raw: libc::stat = unsafe { std::mem::zeroed() };
    let rc = unsafe {
        libc::fstatat(
            node,
            cname.as_ptr(),
            &raw mut raw,
            libc::AT_SYMLINK_NOFOLLOW,
        )
    };
    if rc < 0 {
        return Err(errno());
    }
    Ok(stat_from_raw(&raw))
}
