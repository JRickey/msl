//! Linux fd-backed filesystem access: the root and every node are `O_PATH`
//! authorities resolved by `openat` one component at a time, so a name can
//! never escape the volume. The only module permitted `unsafe`; it wraps the
//! required `libc` calls.
#![allow(unsafe_code)]

use std::ffi::CString;
use std::os::unix::io::RawFd;

use crate::backend::{Backend, DirItem, Handle, RenameResult};
use crate::names::is_valid_component;
use crate::stat::Stat;
use msl_wire::fs::{
    ItemType, SETATTR_ATIME, SETATTR_GID, SETATTR_MODE, SETATTR_MTIME, SETATTR_SIZE, SETATTR_UID,
    SetAttr, Statfs,
};

const OPEN_FLAGS: i32 = libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC;
const SUPPORTED_SETATTR: u32 =
    SETATTR_MODE | SETATTR_UID | SETATTR_GID | SETATTR_SIZE | SETATTR_ATIME | SETATTR_MTIME;
const RENAME_NOREPLACE: libc::c_uint = 1;

/// Cached-node-handle budget; a live mount pins root plus LRU dirs.
const FD_CAP: usize = 512;

/// The guest backend rooted at the distro's `/`.
pub struct LinuxBackend;

impl LinuxBackend {
    pub const fn new() -> Self {
        Self
    }
}

/// Serve file operations on the agent-supplied channel (fd 3) until the peer
/// closes or sends `close`. Returns the process exit code.
pub fn run(read_only: bool) -> i32 {
    use std::os::unix::io::FromRawFd;
    let mut channel = unsafe { std::fs::File::from_raw_fd(3) };
    let mut server = match crate::serve::Server::new(LinuxBackend::new(), FD_CAP, read_only) {
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
        let cname = component_cstring(name)?;
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

    fn sync(&mut self, root: Handle) -> Result<(), i32> {
        let fd = reopen(root, libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC)?;
        let result = sync_fd(fd);
        close_fd(fd);
        result
    }

    fn write_at(&mut self, node: Handle, offset: u64, data: &[u8]) -> Result<(usize, Stat), i32> {
        require_file(node)?;
        let fd = reopen(node, libc::O_WRONLY | libc::O_CLOEXEC)?;
        let result = pwrite_fd(fd, offset, data);
        close_fd(fd);
        let count = result?;
        Ok((count, fstat(node)?))
    }

    fn setattr(&mut self, node: Handle, setattr: SetAttr) -> Result<Stat, i32> {
        apply_setattr(node, setattr)?;
        fstat(node)
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
        let cname = component_cstring(name)?;
        match item_type {
            ItemType::File => create_file(parent, &cname, mode, uid, gid),
            ItemType::Dir => create_dir(parent, &cname, mode, uid, gid),
            _ => Err(libc::EOPNOTSUPP),
        }?;
        self.lookup(parent, name)
    }

    fn symlink(
        &mut self,
        parent: Handle,
        name: &str,
        target: &str,
        uid: u32,
        gid: u32,
    ) -> Result<(Handle, Stat), i32> {
        let cname = component_cstring(name)?;
        let ctarget = CString::new(target).map_err(|_| libc::EINVAL)?;
        let rc = unsafe { libc::symlinkat(ctarget.as_ptr(), parent, cname.as_ptr()) };
        if rc < 0 {
            return Err(errno());
        }
        chown_child(parent, &cname, uid, gid)?;
        self.lookup(parent, name)
    }

    fn link(
        &mut self,
        node: Handle,
        new_parent: Handle,
        new_name: &str,
    ) -> Result<(Handle, Stat), i32> {
        if fstat(node)?.item_type() == ItemType::Dir {
            return Err(libc::EPERM);
        }
        let cname = component_cstring(new_name)?;
        let rc = unsafe {
            libc::linkat(
                node,
                c"".as_ptr(),
                new_parent,
                cname.as_ptr(),
                libc::AT_EMPTY_PATH,
            )
        };
        if rc < 0 {
            return Err(errno());
        }
        self.lookup(new_parent, new_name)
    }

    fn remove(&mut self, parent: Handle, name: &str, item_type: ItemType) -> Result<(), i32> {
        let cname = component_cstring(name)?;
        let flags = if item_type == ItemType::Dir {
            libc::AT_REMOVEDIR
        } else {
            0
        };
        let rc = unsafe { libc::unlinkat(parent, cname.as_ptr(), flags) };
        if rc < 0 { Err(errno()) } else { Ok(()) }
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
        let csrc = component_cstring(src_name)?;
        let cdst = component_cstring(dst_name)?;
        ensure_named_node(node, src_parent, &csrc)?;
        if replace && destination_is_same_file(node, dst_parent, &cdst)? {
            return Ok(RenameResult {
                stat: fstat(node)?,
                moved: false,
            });
        }
        rename_child(src_parent, &csrc, dst_parent, &cdst, replace)?;
        Ok(RenameResult {
            stat: fstat(node)?,
            moved: true,
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

fn component_cstring(name: &str) -> Result<CString, i32> {
    if !is_valid_component(name) {
        return Err(libc::EINVAL);
    }
    CString::new(name).map_err(|_| libc::EINVAL)
}

const fn mode_perms(mode: u32) -> libc::mode_t {
    mode & 0o7777
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
    Ok(stat_from_raw(&raw_fstat(fd)?))
}

fn raw_fstat(fd: RawFd) -> Result<libc::stat, i32> {
    let mut raw: libc::stat = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::fstat(fd, &raw mut raw) };
    if rc < 0 {
        return Err(errno());
    }
    Ok(raw)
}

fn ensure_named_node(node: Handle, parent: Handle, name: &CString) -> Result<(), i32> {
    let node_stat = raw_fstat(node)?;
    let named_stat = raw_fstatat_cname(parent, name).map_err(stale_missing)?;
    if same_file(&node_stat, &named_stat) {
        Ok(())
    } else {
        Err(libc::ESTALE)
    }
}

fn destination_is_same_file(node: Handle, parent: Handle, name: &CString) -> Result<bool, i32> {
    let node_stat = raw_fstat(node)?;
    match raw_fstatat_cname(parent, name) {
        Ok(named_stat) => Ok(same_file(&node_stat, &named_stat)),
        Err(libc::ENOENT) => Ok(false),
        Err(errno) => Err(errno),
    }
}

const fn stale_missing(errno: i32) -> i32 {
    if errno == libc::ENOENT {
        libc::ESTALE
    } else {
        errno
    }
}

const fn same_file(left: &libc::stat, right: &libc::stat) -> bool {
    left.st_dev == right.st_dev && left.st_ino == right.st_ino
}

fn require_file(node: Handle) -> Result<(), i32> {
    if fstat(node)?.item_type() == ItemType::File {
        Ok(())
    } else {
        Err(libc::EINVAL)
    }
}

fn pwrite_fd(fd: RawFd, offset: u64, data: &[u8]) -> Result<usize, i32> {
    let off = offset.try_into().map_err(|_| libc::EINVAL)?;
    let wrote = unsafe { libc::pwrite(fd, data.as_ptr().cast::<libc::c_void>(), data.len(), off) };
    if wrote < 0 {
        return Err(errno());
    }
    usize::try_from(wrote).map_err(|_| libc::EOVERFLOW)
}

fn sync_fd(fd: RawFd) -> Result<(), i32> {
    let rc = unsafe { libc::syncfs(fd) };
    if rc == 0 {
        return Ok(());
    }
    let err = errno();
    if err != libc::ENOSYS {
        return Err(err);
    }
    let fsync_rc = unsafe { libc::fsync(fd) };
    if fsync_rc < 0 { Err(errno()) } else { Ok(()) }
}

fn apply_setattr(node: Handle, setattr: SetAttr) -> Result<(), i32> {
    if setattr.mask & !SUPPORTED_SETATTR != 0 {
        return Err(libc::EINVAL);
    }
    apply_size(node, setattr)?;
    apply_owner(node, setattr)?;
    apply_mode(node, setattr)?;
    apply_times(node, setattr)
}

fn apply_size(node: Handle, setattr: SetAttr) -> Result<(), i32> {
    if setattr.mask & SETATTR_SIZE == 0 {
        return Ok(());
    }
    require_file(node)?;
    let fd = reopen(node, libc::O_WRONLY | libc::O_CLOEXEC)?;
    let size = setattr.size.try_into().map_err(|_| libc::EINVAL)?;
    let rc = unsafe { libc::ftruncate(fd, size) };
    close_fd(fd);
    if rc < 0 { Err(errno()) } else { Ok(()) }
}

fn apply_owner(node: Handle, setattr: SetAttr) -> Result<(), i32> {
    if setattr.mask & (SETATTR_UID | SETATTR_GID) == 0 {
        return Ok(());
    }
    let uid = if setattr.mask & SETATTR_UID != 0 {
        setattr.uid
    } else {
        libc::uid_t::MAX
    };
    let gid = if setattr.mask & SETATTR_GID != 0 {
        setattr.gid
    } else {
        libc::gid_t::MAX
    };
    let rc = unsafe {
        libc::fchownat(
            node,
            c"".as_ptr(),
            uid,
            gid,
            libc::AT_EMPTY_PATH | libc::AT_SYMLINK_NOFOLLOW,
        )
    };
    if rc < 0 { Err(errno()) } else { Ok(()) }
}

fn apply_mode(node: Handle, setattr: SetAttr) -> Result<(), i32> {
    if setattr.mask & SETATTR_MODE == 0 {
        return Ok(());
    }
    let fd = reopen_for_chmod(node)?;
    let rc = unsafe { libc::fchmod(fd, mode_perms(setattr.mode)) };
    close_fd(fd);
    if rc < 0 { Err(errno()) } else { Ok(()) }
}

fn reopen_for_chmod(node: Handle) -> Result<RawFd, i32> {
    let stat = fstat(node)?;
    match stat.item_type() {
        ItemType::Dir => reopen(node, libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC),
        ItemType::File => reopen(node, libc::O_RDONLY | libc::O_CLOEXEC),
        _ => Err(libc::EOPNOTSUPP),
    }
}

fn apply_times(node: Handle, setattr: SetAttr) -> Result<(), i32> {
    if setattr.mask & (SETATTR_ATIME | SETATTR_MTIME) == 0 {
        return Ok(());
    }
    validate_masked_nsec(setattr.mask, SETATTR_ATIME, setattr.atime.nsec)?;
    validate_masked_nsec(setattr.mask, SETATTR_MTIME, setattr.mtime.nsec)?;
    let times = [
        timespec(
            setattr.mask,
            SETATTR_ATIME,
            setattr.atime.sec,
            setattr.atime.nsec,
        ),
        timespec(
            setattr.mask,
            SETATTR_MTIME,
            setattr.mtime.sec,
            setattr.mtime.nsec,
        ),
    ];
    let rc = unsafe {
        libc::utimensat(
            node,
            c"".as_ptr(),
            times.as_ptr(),
            libc::AT_EMPTY_PATH | libc::AT_SYMLINK_NOFOLLOW,
        )
    };
    if rc < 0 { Err(errno()) } else { Ok(()) }
}

fn timespec(mask: u32, bit: u32, sec: i64, nsec: u32) -> libc::timespec {
    if mask & bit == 0 {
        return libc::timespec {
            tv_sec: 0,
            tv_nsec: libc::UTIME_OMIT,
        };
    }
    libc::timespec {
        tv_sec: sec,
        tv_nsec: nsec.into(),
    }
}

const fn validate_masked_nsec(mask: u32, bit: u32, nsec: u32) -> Result<(), i32> {
    if mask & bit == 0 || nsec < 1_000_000_000 {
        Ok(())
    } else {
        Err(libc::EINVAL)
    }
}

fn create_file(parent: Handle, name: &CString, mode: u32, uid: u32, gid: u32) -> Result<(), i32> {
    let flags = libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_CLOEXEC | libc::O_NOFOLLOW;
    let fd = unsafe { libc::openat(parent, name.as_ptr(), flags, mode_perms(mode)) };
    if fd < 0 {
        return Err(errno());
    }
    let result = chown_fd(fd, uid, gid);
    close_fd(fd);
    result
}

fn create_dir(parent: Handle, name: &CString, mode: u32, uid: u32, gid: u32) -> Result<(), i32> {
    let rc = unsafe { libc::mkdirat(parent, name.as_ptr(), mode_perms(mode)) };
    if rc < 0 {
        return Err(errno());
    }
    chown_child(parent, name, uid, gid)
}

fn chown_fd(fd: RawFd, uid: u32, gid: u32) -> Result<(), i32> {
    let rc = unsafe { libc::fchown(fd, uid, gid) };
    if rc < 0 { Err(errno()) } else { Ok(()) }
}

fn chown_child(parent: Handle, name: &CString, uid: u32, gid: u32) -> Result<(), i32> {
    let rc = unsafe { libc::fchownat(parent, name.as_ptr(), uid, gid, libc::AT_SYMLINK_NOFOLLOW) };
    if rc < 0 { Err(errno()) } else { Ok(()) }
}

fn rename_child(
    src_parent: Handle,
    src_name: &CString,
    dst_parent: Handle,
    dst_name: &CString,
    replace: bool,
) -> Result<(), i32> {
    if replace {
        return rename_plain(src_parent, src_name, dst_parent, dst_name);
    }
    rename_noreplace(src_parent, src_name, dst_parent, dst_name)
}

fn rename_plain(
    src_parent: Handle,
    src_name: &CString,
    dst_parent: Handle,
    dst_name: &CString,
) -> Result<(), i32> {
    let rc =
        unsafe { libc::renameat(src_parent, src_name.as_ptr(), dst_parent, dst_name.as_ptr()) };
    if rc < 0 { Err(errno()) } else { Ok(()) }
}

fn rename_noreplace(
    src_parent: Handle,
    src_name: &CString,
    dst_parent: Handle,
    dst_name: &CString,
) -> Result<(), i32> {
    let rc = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            src_parent,
            src_name.as_ptr(),
            dst_parent,
            dst_name.as_ptr(),
            RENAME_NOREPLACE,
        )
    };
    if rc == 0 {
        return Ok(());
    }
    match errno() {
        libc::ENOSYS | libc::EINVAL => Err(libc::EOPNOTSUPP),
        err => Err(err),
    }
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
    let cname = component_cstring(name)?;
    fstatat_cname(node, &cname)
}

fn fstatat_cname(node: Handle, name: &CString) -> Result<Stat, i32> {
    Ok(stat_from_raw(&raw_fstatat_cname(node, name)?))
}

fn raw_fstatat_cname(node: Handle, name: &CString) -> Result<libc::stat, i32> {
    let mut raw: libc::stat = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::fstatat(node, name.as_ptr(), &raw mut raw, libc::AT_SYMLINK_NOFOLLOW) };
    if rc < 0 {
        return Err(errno());
    }
    Ok(raw)
}
