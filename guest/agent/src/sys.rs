//! The only module permitted to use `unsafe`; it wraps the required `libc`
//! calls (mounts, `uname`, zombie reaping, `poll`, non-blocking pipes).
#![allow(unsafe_code)]

use std::io;
#[cfg(target_os = "linux")]
use std::os::unix::io::RawFd;

pub use msl_wire::{PollTarget, poll_fds, set_nonblocking};

#[cfg(target_os = "linux")]
use msl_wire::MAX_POLL_RETRIES;

#[cfg(target_os = "linux")]
pub use msl_wire::{close_fd, read_fd, write_fd};

// Decode the 4-byte native-endian pid the session intermediate reports.
#[must_use]
pub const fn decode_pid(buf: [u8; 4]) -> i32 {
    i32::from_ne_bytes(buf)
}

pub fn kernel_release() -> io::Result<String> {
    let mut uts: libc::utsname = unsafe { std::mem::zeroed() };
    let rc = unsafe { libc::uname(&raw mut uts) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(cstr_field(&uts.release))
}

fn cstr_field(field: &[libc::c_char]) -> String {
    let len = field.len();
    let bytes: &[u8] = unsafe { std::slice::from_raw_parts(field.as_ptr().cast::<u8>(), len) };
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(len);
    debug_assert!(end <= len);
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

#[cfg(target_os = "linux")]
pub fn mount_early() -> io::Result<()> {
    mount_one("proc", "/proc", "proc", None)?;
    mount_one("sysfs", "/sys", "sysfs", None)?;
    mount_one("devtmpfs", "/dev", "devtmpfs", None)?;
    mount_one(
        "devpts",
        "/dev/pts",
        "devpts",
        Some("mode=0620,ptmxmode=0666"),
    )?;
    mount_one("tmpfs", "/tmp", "tmpfs", Some("mode=0777"))?;
    Ok(())
}

// Best-effort virtiofs share mount; a missing tag is not an error to the caller.
#[cfg(target_os = "linux")]
pub fn mount_share(tag: &str, target: &str) -> io::Result<()> {
    debug_assert!(!tag.is_empty());
    debug_assert!(target.starts_with('/'));
    mount_one(tag, target, "virtiofs", None)
}

#[cfg(target_os = "linux")]
fn mount_one(src: &str, target: &str, fstype: &str, data: Option<&str>) -> io::Result<()> {
    use std::ffi::CString;
    ensure_dir(target)?;
    let c_src = CString::new(src).map_err(|_| invalid("nul in source"))?;
    let c_tgt = CString::new(target).map_err(|_| invalid("nul in target"))?;
    let c_fs = CString::new(fstype).map_err(|_| invalid("nul in fstype"))?;
    let c_data = data
        .map(CString::new)
        .transpose()
        .map_err(|_| invalid("nul in data"))?;
    let data_ptr: *const libc::c_void = c_data
        .as_ref()
        .map_or(std::ptr::null(), |c| c.as_ptr().cast::<libc::c_void>());
    let rc = unsafe { libc::mount(c_src.as_ptr(), c_tgt.as_ptr(), c_fs.as_ptr(), 0, data_ptr) };
    if rc != 0 {
        let err = io::Error::last_os_error();
        if err.raw_os_error() == Some(libc::EBUSY) {
            return Ok(());
        }
        return Err(err);
    }
    Ok(())
}

// Flush the page cache to the block device, then detach the distro root. The
// ext4 lives in init's (now dead) mount ns, so "not mounted here" is expected.
#[cfg(target_os = "linux")]
pub fn sync_and_unmount(newroot: &str) -> io::Result<()> {
    if newroot.is_empty() {
        return Err(invalid("empty newroot"));
    }
    debug_assert!(newroot.starts_with('/'));
    unsafe { libc::sync() };
    let c_newroot = CString::new(newroot).map_err(|_| invalid("nul in newroot"))?;
    let rc = unsafe { libc::umount2(c_newroot.as_ptr(), libc::MNT_DETACH) };
    if rc != 0 {
        let err = io::Error::last_os_error();
        if matches!(err.raw_os_error(), Some(libc::EINVAL | libc::ENOENT)) {
            return Ok(());
        }
        return Err(err);
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn ensure_dir(path: &str) -> io::Result<()> {
    match std::fs::create_dir(path) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => Ok(()),
        Err(e) => Err(e),
    }
}

#[cfg(target_os = "linux")]
fn invalid(msg: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, msg)
}

// ---------------------------------------------------------------------------
// Linux syscall wrappers: wall-clock, signals, reaping, PTY allocation,
// namespace join, distro `clone`+boot, and PTY session `fork`+exec. Every
// child path between fork/clone and execve calls only async-signal-safe libc.
// ---------------------------------------------------------------------------

#[cfg(target_os = "linux")]
use libc::{c_char, c_int, c_ulong};
#[cfg(target_os = "linux")]
use std::ffi::CString;

#[cfg(target_os = "linux")]
pub const MIN_VALID_EPOCH: i64 = 1_700_000_000;

#[cfg(target_os = "linux")]
pub fn set_time(sec: i64, usec: i64) -> io::Result<()> {
    if sec < MIN_VALID_EPOCH || !(0..1_000_000).contains(&usec) {
        return Err(invalid("set_time out of range"));
    }
    let tv = libc::timeval {
        tv_sec: sec,
        tv_usec: usec,
    };
    let rc = unsafe { libc::settimeofday(&raw const tv, std::ptr::null()) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(target_os = "linux")]
pub fn send_signal(pid: libc::pid_t, sig: c_int) -> io::Result<()> {
    if pid <= 0 {
        return Err(invalid("bad pid"));
    }
    let rc = unsafe { libc::kill(pid, sig) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

// Blocking single-owner reap: next exited child, or None on ECHILD (no children).
#[cfg(target_os = "linux")]
pub fn reap_blocking() -> Option<(libc::pid_t, i32)> {
    let mut status: c_int = 0;
    // bounded EINTR retry: a delivered signal can interrupt the blocking wait
    for _ in 0..MAX_POLL_RETRIES {
        let pid = unsafe { libc::waitpid(-1, &raw mut status, 0) };
        if pid > 0 {
            return Some((pid, decode_status(status)));
        }
        if pid == 0 {
            return None;
        }
        let err = io::Error::last_os_error();
        match err.raw_os_error() {
            Some(libc::EINTR) => {}
            _ => return None,
        }
    }
    None
}

#[cfg(target_os = "linux")]
pub fn set_cloexec(fd: RawFd) -> io::Result<()> {
    if fd < 0 {
        return Err(invalid("bad cloexec fd"));
    }
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    let rc = unsafe { libc::fcntl(fd, libc::F_SETFD, flags | libc::FD_CLOEXEC) };
    if rc < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

// Bound a blocking recv so a stalled peer cannot pin the handler thread; the
// pump switches to nonblocking after the handshake, so this only times the hello.
#[cfg(target_os = "linux")]
pub fn set_recv_timeout(fd: RawFd, secs: u32) -> io::Result<()> {
    set_sock_timeout(fd, secs, libc::SO_RCVTIMEO)
}

// Bound a blocking send so a rejection write on the accept thread cannot stall.
#[cfg(target_os = "linux")]
pub fn set_send_timeout(fd: RawFd, secs: u32) -> io::Result<()> {
    set_sock_timeout(fd, secs, libc::SO_SNDTIMEO)
}

#[cfg(target_os = "linux")]
fn set_sock_timeout(fd: RawFd, secs: u32, opt: libc::c_int) -> io::Result<()> {
    if fd < 0 {
        return Err(invalid("bad socket-timeout fd"));
    }
    if secs == 0 {
        return Err(invalid("zero socket timeout"));
    }
    let tv = libc::timeval {
        tv_sec: i64::from(secs),
        tv_usec: 0,
    };
    debug_assert!(tv.tv_sec > 0);
    let len = libc::socklen_t::try_from(std::mem::size_of::<libc::timeval>())
        .map_err(|_| invalid("timeval size overflow"))?;
    let rc = unsafe {
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            opt,
            (&raw const tv).cast::<libc::c_void>(),
            len,
        )
    };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(target_os = "linux")]
const fn decode_status(status: c_int) -> i32 {
    if libc::WIFEXITED(status) {
        libc::WEXITSTATUS(status)
    } else if libc::WIFSIGNALED(status) {
        128_i32.saturating_add(libc::WTERMSIG(status))
    } else {
        -1
    }
}

#[cfg(target_os = "linux")]
const fn winsize(rows: u16, cols: u16) -> libc::winsize {
    libc::winsize {
        ws_row: rows,
        ws_col: cols,
        ws_xpixel: 0,
        ws_ypixel: 0,
    }
}

#[cfg(target_os = "linux")]
pub fn set_winsize(master: RawFd, rows: u16, cols: u16) -> io::Result<()> {
    if master < 0 {
        return Err(invalid("bad master fd"));
    }
    let ws = winsize(rows, cols);
    let rc = unsafe { libc::ioctl(master, libc::TIOCSWINSZ, &raw const ws) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(target_os = "linux")]
pub fn open_pty(rows: u16, cols: u16) -> io::Result<(RawFd, RawFd)> {
    let mut master: RawFd = -1;
    let mut slave: RawFd = -1;
    let ws = winsize(rows, cols);
    let rc = unsafe {
        libc::openpty(
            &raw mut master,
            &raw mut slave,
            std::ptr::null_mut(),
            std::ptr::null(),
            &raw const ws,
        )
    };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    debug_assert!(master >= 0 && slave >= 0);
    // Master stays in the agent; keep it from leaking into forked children.
    let _ = set_cloexec(master);
    let _ = set_cloexec(slave);
    Ok((master, slave))
}

#[cfg(target_os = "linux")]
pub fn open_distro_pty(
    init_pid: libc::pid_t,
    rows: u16,
    cols: u16,
) -> io::Result<(RawFd, CString)> {
    if init_pid <= 0 {
        return Err(invalid("bad init pid"));
    }
    let ptmx = CString::new(format!("/proc/{init_pid}/root/dev/pts/ptmx"))
        .map_err(|_| invalid("nul in ptmx path"))?;
    let fd = unsafe {
        libc::open(
            ptmx.as_ptr(),
            libc::O_RDWR | libc::O_NOCTTY | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let index = unlock_pt(fd).inspect_err(|_| close_all(&[fd]))?;
    let _ = set_winsize(fd, rows, cols);
    let slave =
        CString::new(format!("/dev/pts/{index}")).map_err(|_| invalid("nul in pts path"))?;
    Ok((fd, slave))
}

#[cfg(target_os = "linux")]
fn unlock_pt(fd: RawFd) -> io::Result<c_int> {
    debug_assert!(fd >= 0);
    let lock: c_int = 0;
    let mut index: c_int = -1;
    let rc_lock = unsafe { libc::ioctl(fd, libc::TIOCSPTLCK, &raw const lock) };
    if rc_lock != 0 {
        return Err(io::Error::last_os_error());
    }
    let rc_num = unsafe { libc::ioctl(fd, libc::TIOCGPTN, &raw mut index) };
    if rc_num != 0 {
        return Err(io::Error::last_os_error());
    }
    if index < 0 {
        return Err(invalid("bad pts index"));
    }
    Ok(index)
}

#[cfg(target_os = "linux")]
pub fn open_ns_fds(init_pid: libc::pid_t) -> io::Result<Vec<RawFd>> {
    if init_pid <= 0 {
        return Err(invalid("bad init pid"));
    }
    let kinds = ["pid", "ipc", "uts", "mnt"];
    let mut fds: Vec<RawFd> = Vec::with_capacity(kinds.len());
    // bounded: exactly four namespace kinds
    for kind in kinds {
        let path = CString::new(format!("/proc/{init_pid}/ns/{kind}"))
            .map_err(|_| invalid("nul in ns path"))?;
        let fd = unsafe { libc::open(path.as_ptr(), libc::O_RDONLY | libc::O_CLOEXEC) };
        if fd < 0 {
            let err = io::Error::last_os_error();
            close_all(&fds);
            return Err(err);
        }
        fds.push(fd);
    }
    debug_assert_eq!(fds.len(), kinds.len());
    Ok(fds)
}

#[cfg(target_os = "linux")]
pub fn close_all(fds: &[RawFd]) {
    // bounded: caller-owned small fd set (namespace fds or a single fd)
    for &fd in fds {
        if fd >= 0 {
            unsafe {
                libc::close(fd);
            }
        }
    }
}

#[cfg(target_os = "linux")]
pub struct MountOp {
    pub source: CString,
    pub target: CString,
    pub fstype: CString,
    pub flags: c_ulong,
    pub data: Option<CString>,
}

// Projection of the initramfs /tools dir into a distro: a read-only bind at
// `target` (parent mkdir'd first) plus a fixed /usr/local/bin/mac symlink.
#[cfg(target_os = "linux")]
pub struct ToolsBind {
    pub src: CString,
    pub parent: CString,
    pub target: CString,
    pub link: CString,
    pub binfmt_dir: CString,
    pub binfmt_conf: CString,
}

// systemd binfmt.d drop-in: the distro's own systemd-binfmt owns its
// binfmt_misc set, so registration must live in the distro, not the agent's
// namespace. F pins /run/msl/tools/mac-binfmt (present before init) at boot.
#[cfg(target_os = "linux")]
pub const BINFMT_CONF: &[u8] = b":msl-macho:M::\\xcf\\xfa\\xed\\xfe::/run/msl/tools/mac-binfmt:F\n\
:msl-macho-fat:M::\\xca\\xfe\\xba\\xbe::/run/msl/tools/mac-binfmt:F\n";

// Read-only bind of the VM's Rosetta virtiofs share into a distro plus the
// binfmt.d drop-in that registers x86-64 ELF against the pinned interpreter.
#[cfg(target_os = "linux")]
pub struct RosettaBind {
    pub src: CString,
    pub parent: CString,
    pub target: CString,
    pub binfmt_dir: CString,
    pub binfmt_conf: CString,
}

// binfmt.d drop-in registering 64-bit LE x86-64 ELF (EM_X86_64 == 0x3e,
// exec-or-dyn) against Rosetta. F pins /run/msl/rosetta/rosetta at boot.
#[cfg(target_os = "linux")]
pub const ROSETTA_CONF: &[u8] = b":rosetta:M::\\x7fELF\\x02\\x01\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x00\\x02\\x00\\x3e\\x00:\\xff\\xff\\xff\\xff\\xff\\xfe\\xfe\\x00\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xff\\xfe\\xff\\xff\\xff:/run/msl/rosetta/rosetta:F\n";

#[cfg(target_os = "linux")]
pub struct BootSpec {
    pub dev: CString,
    pub newroot: CString,
    pub mounts: Vec<MountOp>,
    pub mac: Option<(CString, CString)>,
    pub tools: Option<ToolsBind>,
    pub rosetta: Option<RosettaBind>,
    pub hostname: CString,
    pub argv: Vec<CString>,
    pub envp: Vec<CString>,
}

#[cfg(target_os = "linux")]
pub fn spawn_distro_init(spec: &BootSpec) -> io::Result<libc::pid_t> {
    assert!(!spec.argv.is_empty(), "distro argv must be non-empty");
    assert!(!spec.newroot.is_empty(), "newroot must be set");
    let argv_ptrs = null_terminated(&spec.argv);
    let envp_ptrs = null_terminated(&spec.envp);
    let bits: c_int = libc::CLONE_NEWPID
        | libc::CLONE_NEWNS
        | libc::CLONE_NEWUTS
        | libc::CLONE_NEWIPC
        | libc::SIGCHLD;
    let flags = libc::c_long::from(bits);
    let pid = unsafe { libc::syscall(libc::SYS_clone, flags, 0, 0, 0, 0) };
    if pid < 0 {
        return Err(io::Error::last_os_error());
    }
    if pid == 0 {
        child_boot(spec, &argv_ptrs, &envp_ptrs);
    }
    libc::pid_t::try_from(pid).map_err(|_| invalid("pid overflow"))
}

#[cfg(target_os = "linux")]
fn child_boot(spec: &BootSpec, argv: &[*const c_char], envp: &[*const c_char]) -> ! {
    unsafe {
        if libc::mount(
            c"none".as_ptr(),
            c"/".as_ptr(),
            std::ptr::null(),
            libc::MS_REC | libc::MS_PRIVATE,
            std::ptr::null(),
        ) != 0
            || libc::mount(
                spec.dev.as_ptr(),
                spec.newroot.as_ptr(),
                c"ext4".as_ptr(),
                0,
                std::ptr::null(),
            ) != 0
        {
            libc::_exit(127);
        }
        child_mounts(spec);
        if libc::sethostname(spec.hostname.as_ptr(), spec.hostname.as_bytes().len()) != 0
            || pivot_into(spec.newroot.as_ptr()) != 0
        {
            libc::_exit(127);
        }
        libc::execve(argv[0], argv.as_ptr(), envp.as_ptr());
        libc::_exit(127);
    }
}

#[cfg(target_os = "linux")]
unsafe fn child_mounts(spec: &BootSpec) {
    unsafe {
        // bounded: fixed pseudo-filesystem list built before clone
        for m in &spec.mounts {
            libc::mkdir(m.target.as_ptr(), 0o755);
            let data = m
                .data
                .as_ref()
                .map_or(std::ptr::null(), |d| d.as_ptr().cast());
            if libc::mount(
                m.source.as_ptr(),
                m.target.as_ptr(),
                m.fstype.as_ptr(),
                m.flags,
                data,
            ) != 0
            {
                libc::_exit(127);
            }
        }
        if let Some((src, tgt)) = &spec.mac {
            libc::mkdir(tgt.as_ptr(), 0o755);
            let _ = libc::mount(
                src.as_ptr(),
                tgt.as_ptr(),
                std::ptr::null(),
                libc::MS_BIND | libc::MS_REC,
                std::ptr::null(),
            );
        }
        if let Some(tools) = &spec.tools {
            bind_tools(tools);
        }
        if let Some(rosetta) = &spec.rosetta {
            bind_rosetta(rosetta);
        }
    }
}

// Read-only tools bind + mac symlink. A failed ro-remount unwinds the bind:
// a writable bind would let one distro rewrite the shim shared by all.
#[cfg(target_os = "linux")]
unsafe fn bind_tools(tools: &ToolsBind) {
    unsafe {
        libc::mkdir(tools.parent.as_ptr(), 0o755);
        libc::mkdir(tools.target.as_ptr(), 0o755);
        if libc::mount(
            tools.src.as_ptr(),
            tools.target.as_ptr(),
            std::ptr::null(),
            libc::MS_BIND,
            std::ptr::null(),
        ) != 0
        {
            return;
        }
        if libc::mount(
            std::ptr::null(),
            tools.target.as_ptr(),
            std::ptr::null(),
            libc::MS_REMOUNT | libc::MS_BIND | libc::MS_RDONLY,
            std::ptr::null(),
        ) != 0
        {
            libc::umount(tools.target.as_ptr());
            return;
        }
        libc::symlink(c"/run/msl/tools/mac".as_ptr(), tools.link.as_ptr());
        seed_binfmt(tools);
    }
}

// Drop the systemd binfmt.d config so the distro registers the Mach-O handlers
// itself at boot. Best-effort: a write failure just leaves transparent exec off.
#[cfg(target_os = "linux")]
unsafe fn seed_binfmt(tools: &ToolsBind) {
    unsafe {
        libc::mkdir(tools.binfmt_dir.as_ptr(), 0o755);
        let fd = libc::open(
            tools.binfmt_conf.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_TRUNC,
            0o644,
        );
        if fd < 0 {
            return;
        }
        let rc = libc::write(fd, BINFMT_CONF.as_ptr().cast(), BINFMT_CONF.len());
        debug_assert!(rc <= BINFMT_CONF.len().cast_signed(), "write within bounds");
        libc::close(fd);
    }
}

// Read-only bind of the Rosetta share into the distro, then its binfmt.d
// drop-in. A writable bind would let a distro tamper with the shared interp.
#[cfg(target_os = "linux")]
unsafe fn bind_rosetta(rosetta: &RosettaBind) {
    unsafe {
        libc::mkdir(rosetta.parent.as_ptr(), 0o755);
        libc::mkdir(rosetta.target.as_ptr(), 0o755);
        if libc::mount(
            rosetta.src.as_ptr(),
            rosetta.target.as_ptr(),
            std::ptr::null(),
            libc::MS_BIND,
            std::ptr::null(),
        ) != 0
        {
            return;
        }
        if libc::mount(
            std::ptr::null(),
            rosetta.target.as_ptr(),
            std::ptr::null(),
            libc::MS_REMOUNT | libc::MS_BIND | libc::MS_RDONLY,
            std::ptr::null(),
        ) != 0
        {
            libc::umount(rosetta.target.as_ptr());
            return;
        }
        seed_rosetta(rosetta);
    }
}

// Drop the systemd binfmt.d config so the distro registers x86-64 ELF against
// Rosetta at boot. Best-effort: a write failure just leaves x86 translation off.
#[cfg(target_os = "linux")]
unsafe fn seed_rosetta(rosetta: &RosettaBind) {
    unsafe {
        libc::mkdir(rosetta.binfmt_dir.as_ptr(), 0o755);
        let fd = libc::open(
            rosetta.binfmt_conf.as_ptr(),
            libc::O_WRONLY | libc::O_CREAT | libc::O_TRUNC,
            0o644,
        );
        if fd < 0 {
            return;
        }
        let rc = libc::write(fd, ROSETTA_CONF.as_ptr().cast(), ROSETTA_CONF.len());
        debug_assert!(
            rc <= ROSETTA_CONF.len().cast_signed(),
            "write within bounds"
        );
        libc::close(fd);
    }
}

// switch_root sequence, not pivot_root(2): the agent's root is the initramfs
// (rootfs), which pivot_root rejects with EINVAL unconditionally.
#[cfg(target_os = "linux")]
unsafe fn pivot_into(newroot: *const c_char) -> c_int {
    unsafe {
        if libc::chdir(newroot) != 0 {
            return -1;
        }
        if libc::mount(
            c".".as_ptr(),
            c"/".as_ptr(),
            std::ptr::null(),
            libc::MS_MOVE,
            std::ptr::null(),
        ) != 0
        {
            return -1;
        }
        if libc::chroot(c".".as_ptr()) != 0 {
            return -1;
        }
        if libc::chdir(c"/".as_ptr()) != 0 {
            return -1;
        }
        0
    }
}

#[cfg(target_os = "linux")]
pub enum SlaveSource {
    Fd(RawFd),
    Path(CString),
}

#[cfg(target_os = "linux")]
pub struct SessionSpec {
    pub ns_fds: Vec<RawFd>,
    pub master_fd: RawFd,
    pub slave: SlaveSource,
    pub cwd: Option<CString>,
    pub argv: Vec<CString>,
    pub envp: Vec<CString>,
}

// A session's two pids: `leader` is the agent's direct child (its reaped exit
// is the session exit); `target` is the process the shell actually runs as and
// that `session_signal` must target. They coincide for builder sessions.
#[cfg(target_os = "linux")]
pub struct SessionSpawn {
    pub leader: libc::pid_t,
    pub target: libc::pid_t,
}

#[cfg(target_os = "linux")]
const HANDSHAKE_TIMEOUT_MS: i32 = 500;

#[cfg(target_os = "linux")]
pub fn spawn_session(spec: &SessionSpec) -> io::Result<SessionSpawn> {
    assert!(!spec.argv.is_empty(), "session argv must be non-empty");
    assert!(spec.master_fd >= 0, "session master fd must be valid");
    let argv_ptrs = null_terminated(&spec.argv);
    let envp_ptrs = null_terminated(&spec.envp);
    if spec.ns_fds.is_empty() {
        return spawn_session_direct(spec, &argv_ptrs, &envp_ptrs);
    }
    spawn_session_nsenter(spec, &argv_ptrs, &envp_ptrs)
}

#[cfg(target_os = "linux")]
fn spawn_session_direct(
    spec: &SessionSpec,
    argv: &[*const c_char],
    envp: &[*const c_char],
) -> io::Result<SessionSpawn> {
    let pid = unsafe { libc::fork() };
    if pid < 0 {
        return Err(io::Error::last_os_error());
    }
    if pid == 0 {
        // Orphan insurance first (no intermediate on the builder path).
        unsafe {
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL, 0, 0, 0);
        }
        child_session_body(spec, argv, envp);
    }
    Ok(SessionSpawn {
        leader: pid,
        target: pid,
    })
}

// Double-fork so the shell is a grandchild born inside the joined PID namespace.
#[cfg(target_os = "linux")]
fn spawn_session_nsenter(
    spec: &SessionSpec,
    argv: &[*const c_char],
    envp: &[*const c_char],
) -> io::Result<SessionSpawn> {
    let pipe = make_pipe()?;
    let pid = unsafe { libc::fork() };
    if pid < 0 {
        let err = io::Error::last_os_error();
        close_all(&pipe);
        return Err(err);
    }
    if pid == 0 {
        child_intermediate(spec, pipe[1], argv, envp);
    }
    close_fd(pipe[1]);
    let target = read_pid_blocking(pipe[0]);
    close_fd(pipe[0]);
    let target = target.inspect_err(|_| {
        let _ = send_signal(pid, libc::SIGKILL);
    })?;
    Ok(SessionSpawn {
        leader: pid,
        target,
    })
}

#[cfg(target_os = "linux")]
fn child_intermediate(
    spec: &SessionSpec,
    pipe_w: RawFd,
    argv: &[*const c_char],
    envp: &[*const c_char],
) -> ! {
    unsafe {
        // bounded: caller-owned namespace fd set
        for &fd in &spec.ns_fds {
            if libc::setns(fd, 0) != 0 {
                libc::_exit(127);
            }
        }
        let grandchild = libc::fork();
        if grandchild < 0 {
            libc::_exit(127);
        }
        if grandchild == 0 {
            // Orphan insurance first, before any close, then run the session body.
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL, 0, 0, 0);
            libc::close(pipe_w);
            child_session_body(spec, argv, envp);
        }
        report_and_wait(pipe_w, grandchild);
    }
}

// Publish the grandchild's outer pid, then mirror its lifetime and exit status.
#[cfg(target_os = "linux")]
unsafe fn report_and_wait(pipe_w: RawFd, grandchild: libc::pid_t) -> ! {
    unsafe {
        let bytes = grandchild.to_ne_bytes();
        let _ = libc::write(pipe_w, bytes.as_ptr().cast(), bytes.len());
        libc::close(pipe_w);
        let mut status: c_int = 0;
        libc::waitpid(grandchild, &raw mut status, 0);
        libc::_exit(exit_code_from_status(status));
    }
}

#[cfg(target_os = "linux")]
const fn exit_code_from_status(status: c_int) -> c_int {
    if libc::WIFEXITED(status) {
        libc::WEXITSTATUS(status)
    } else if libc::WIFSIGNALED(status) {
        128_i32.saturating_add(libc::WTERMSIG(status))
    } else {
        0
    }
}

#[cfg(target_os = "linux")]
fn read_pid_blocking(fd: RawFd) -> io::Result<libc::pid_t> {
    let mut targets = [PollTarget::read(fd, false)];
    poll_fds(&mut targets, HANDSHAKE_TIMEOUT_MS)?;
    if !targets[0].ready && !targets[0].hup {
        return Err(invalid("session pid handshake timeout"));
    }
    let mut buf = [0u8; 4];
    let n = read_fd(fd, &mut buf)?;
    if n != buf.len() {
        return Err(invalid("short session pid handshake"));
    }
    Ok(decode_pid(buf))
}

#[cfg(target_os = "linux")]
fn child_session_body(spec: &SessionSpec, argv: &[*const c_char], envp: &[*const c_char]) -> ! {
    unsafe {
        if libc::setsid() < 0 {
            libc::_exit(127);
        }
        let slave = match &spec.slave {
            SlaveSource::Fd(fd) => *fd,
            SlaveSource::Path(path) => libc::open(path.as_ptr(), libc::O_RDWR),
        };
        if slave < 0 || libc::ioctl(slave, libc::TIOCSCTTY, 0) != 0 {
            libc::_exit(127);
        }
        if libc::dup2(slave, 0) < 0 || libc::dup2(slave, 1) < 0 || libc::dup2(slave, 2) < 0 {
            libc::_exit(127);
        }
        child_session_exec(spec, slave, argv, envp);
    }
}

#[cfg(target_os = "linux")]
unsafe fn child_session_exec(
    spec: &SessionSpec,
    slave: RawFd,
    argv: &[*const c_char],
    envp: &[*const c_char],
) -> ! {
    unsafe {
        if slave > 2 {
            libc::close(slave);
        }
        if spec.master_fd >= 0 {
            libc::close(spec.master_fd);
        }
        for &fd in &spec.ns_fds {
            libc::close(fd);
        }
        if let Some(cwd) = &spec.cwd
            && libc::chdir(cwd.as_ptr()) != 0
        {
            libc::_exit(127);
        }
        libc::execve(argv[0], argv.as_ptr(), envp.as_ptr());
        libc::_exit(127);
    }
}

#[cfg(target_os = "linux")]
pub struct CaptureSpec {
    pub ns_fds: Vec<RawFd>,
    pub cwd: Option<CString>,
    pub argv: Vec<CString>,
    pub envp: Vec<CString>,
}

// A captured distro command: the reaper/exec waits `leader` (the direct child,
// carrying the forwarded exit status) and kills `target` (the actual command,
// inside the distro PID namespace) on timeout. `out`/`err` are stdout/stderr.
#[cfg(target_os = "linux")]
pub struct CapturedChild {
    pub leader: libc::pid_t,
    pub target: libc::pid_t,
    pub out: RawFd,
    pub err: RawFd,
}

#[cfg(target_os = "linux")]
pub fn spawn_captured(spec: &CaptureSpec) -> io::Result<CapturedChild> {
    assert!(!spec.argv.is_empty(), "captured argv must be non-empty");
    assert!(!spec.ns_fds.is_empty(), "captured exec is distro-only");
    let out = make_pipe()?;
    let err = make_pipe().inspect_err(|_| close_all(&out))?;
    let pidp = make_pipe().inspect_err(|_| {
        close_all(&out);
        close_all(&err);
    })?;
    let argv_ptrs = null_terminated(&spec.argv);
    let envp_ptrs = null_terminated(&spec.envp);
    let pid = unsafe { libc::fork() };
    if pid < 0 {
        let e = io::Error::last_os_error();
        close_all(&out);
        close_all(&err);
        close_all(&pidp);
        return Err(e);
    }
    if pid == 0 {
        child_captured_intermediate(spec, out, err, pidp, &argv_ptrs, &envp_ptrs);
    }
    finish_captured(pid, out, err, pidp)
}

#[cfg(target_os = "linux")]
fn finish_captured(
    leader: libc::pid_t,
    out: [RawFd; 2],
    err: [RawFd; 2],
    pidp: [RawFd; 2],
) -> io::Result<CapturedChild> {
    close_fd(out[1]);
    close_fd(err[1]);
    close_fd(pidp[1]);
    let target = read_pid_blocking(pidp[0]);
    close_fd(pidp[0]);
    match target {
        Ok(target) => Ok(CapturedChild {
            leader,
            target,
            out: out[0],
            err: err[0],
        }),
        Err(e) => {
            close_fd(out[0]);
            close_fd(err[0]);
            let _ = send_signal(leader, libc::SIGKILL);
            Err(e)
        }
    }
}

#[cfg(target_os = "linux")]
fn make_pipe() -> io::Result<[RawFd; 2]> {
    let mut fds: [c_int; 2] = [-1, -1];
    let rc = unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    debug_assert!(fds[0] >= 0 && fds[1] >= 0);
    Ok(fds)
}

#[cfg(target_os = "linux")]
fn child_captured_intermediate(
    spec: &CaptureSpec,
    out: [RawFd; 2],
    err: [RawFd; 2],
    pidp: [RawFd; 2],
    argv: &[*const c_char],
    envp: &[*const c_char],
) -> ! {
    unsafe {
        // bounded: caller-owned namespace fd set
        for &fd in &spec.ns_fds {
            if libc::setns(fd, 0) != 0 {
                libc::_exit(127);
            }
        }
        let grandchild = libc::fork();
        if grandchild < 0 {
            libc::_exit(127);
        }
        if grandchild == 0 {
            // Orphan insurance first, before any close, then run the captured body.
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL, 0, 0, 0);
            libc::close(pidp[0]);
            libc::close(pidp[1]);
            child_captured_body(spec, out, err, argv, envp);
        }
        libc::close(pidp[0]);
        libc::close(out[0]);
        libc::close(out[1]);
        libc::close(err[0]);
        libc::close(err[1]);
        report_and_wait(pidp[1], grandchild);
    }
}

#[cfg(target_os = "linux")]
fn child_captured_body(
    spec: &CaptureSpec,
    out: [RawFd; 2],
    err: [RawFd; 2],
    argv: &[*const c_char],
    envp: &[*const c_char],
) -> ! {
    unsafe {
        let devnull = libc::open(c"/dev/null".as_ptr(), libc::O_RDONLY);
        if devnull < 0
            || libc::dup2(devnull, 0) < 0
            || libc::dup2(out[1], 1) < 0
            || libc::dup2(err[1], 2) < 0
        {
            libc::_exit(127);
        }
        if let Some(cwd) = &spec.cwd
            && libc::chdir(cwd.as_ptr()) != 0
        {
            libc::_exit(127);
        }
        libc::execve(argv[0], argv.as_ptr(), envp.as_ptr());
        libc::_exit(127);
    }
}

#[cfg(target_os = "linux")]
fn null_terminated(items: &[CString]) -> Vec<*const c_char> {
    let mut ptrs: Vec<*const c_char> = Vec::with_capacity(items.len() + 1);
    // bounded: argv/envp length fixed before clone/fork
    for item in items {
        ptrs.push(item.as_ptr());
    }
    ptrs.push(std::ptr::null());
    ptrs
}

#[cfg(test)]
mod tests {
    use super::decode_pid;

    #[test]
    fn decode_pid_round_trips_native_endian() {
        for pid in [1_i32, 4242, 65_535, i32::MAX] {
            assert_eq!(decode_pid(pid.to_ne_bytes()), pid);
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn binfmt_conf_registers_both_machos_against_the_pinned_interp() {
        let text = std::str::from_utf8(super::BINFMT_CONF).expect("utf8 drop-in");
        assert!(text.contains(r"\xcf\xfa\xed\xfe") && text.contains(r"\xca\xfe\xba\xbe"));
        for line in text.lines() {
            assert!(
                line.ends_with("/run/msl/tools/mac-binfmt:F"),
                "F-pinned interp"
            );
        }
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn rosetta_conf_registers_x86_64_elf_against_the_pinned_interp() {
        let text = std::str::from_utf8(super::ROSETTA_CONF).expect("utf8 drop-in");
        assert!(
            text.contains(r"\x3e\x00"),
            "carries the x86-64 machine bytes"
        );
        for line in text.lines() {
            assert!(
                line.ends_with("/run/msl/rosetta/rosetta:F"),
                "F-pinned interp"
            );
        }
    }
}
