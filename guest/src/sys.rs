//! The only module permitted to use `unsafe`; it wraps the required `libc`
//! calls (mounts, `uname`, zombie reaping, `poll`, non-blocking pipes).
#![allow(unsafe_code)]

use std::io;
use std::os::unix::io::RawFd;

const MAX_POLL_TARGETS: usize = 8;
const MAX_POLL_RETRIES: usize = 64;

#[allow(clippy::struct_excessive_bools)] // poll descriptor: intent + result flags
pub struct PollTarget {
    fd: RawFd,
    want: bool,
    want_write: bool,
    pub ready: bool,
    pub writable: bool,
    pub hup: bool,
}

impl PollTarget {
    pub const fn read(fd: RawFd, done: bool) -> Self {
        Self {
            fd,
            want: !done,
            want_write: false,
            ready: false,
            writable: false,
            hup: false,
        }
    }

    pub const fn read_write(fd: RawFd, want_read: bool, want_write: bool) -> Self {
        Self {
            fd,
            want: want_read,
            want_write,
            ready: false,
            writable: false,
            hup: false,
        }
    }
}

pub fn poll_fds(targets: &mut [PollTarget], timeout_ms: i32) -> io::Result<()> {
    if targets.is_empty() || targets.len() > MAX_POLL_TARGETS {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "bad poll target count",
        ));
    }
    let mut pfds: Vec<libc::pollfd> = targets
        .iter()
        .map(|t| libc::pollfd {
            fd: t.fd,
            events: poll_events(t),
            revents: 0,
        })
        .collect();
    let count = libc::nfds_t::try_from(pfds.len()).unwrap_or(0);
    let mut rc: libc::c_int = -1;
    let mut last_err: Option<io::Error> = None;
    // bounded EINTR retry: poll can be interrupted by any delivered signal
    for _ in 0..MAX_POLL_RETRIES {
        let ret = unsafe { libc::poll(pfds.as_mut_ptr(), count, timeout_ms) };
        if ret >= 0 {
            rc = ret;
            break;
        }
        let err = io::Error::last_os_error();
        let interrupted = err.raw_os_error() == Some(libc::EINTR);
        last_err = Some(err);
        if !interrupted {
            break;
        }
    }
    if rc < 0 {
        return Err(last_err.unwrap_or_else(|| io::Error::other("poll failed")));
    }
    for (target, pfd) in targets.iter_mut().zip(pfds.iter()) {
        target.ready = pfd.revents & libc::POLLIN != 0;
        target.writable = pfd.revents & libc::POLLOUT != 0;
        target.hup = pfd.revents & (libc::POLLHUP | libc::POLLERR) != 0;
    }
    Ok(())
}

const fn poll_events(t: &PollTarget) -> libc::c_short {
    let mut events: libc::c_short = 0;
    if t.want {
        events |= libc::POLLIN;
    }
    if t.want_write {
        events |= libc::POLLOUT;
    }
    events
}

pub fn set_nonblocking(fd: RawFd) -> io::Result<()> {
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 {
        return Err(io::Error::last_os_error());
    }
    let rc = unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) };
    if rc < 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

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
// M1 additions (Linux only): wall-clock, signals, reaping, PTY allocation,
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

#[cfg(target_os = "linux")]
pub struct BootSpec {
    pub dev: CString,
    pub newroot: CString,
    pub mounts: Vec<MountOp>,
    pub mac: Option<(CString, CString)>,
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
    }
}

#[cfg(target_os = "linux")]
unsafe fn pivot_into(newroot: *const c_char) -> c_int {
    unsafe {
        if libc::chdir(newroot) != 0 {
            return -1;
        }
        if libc::syscall(libc::SYS_pivot_root, c".".as_ptr(), c".".as_ptr()) != 0 {
            return -1;
        }
        if libc::umount2(c".".as_ptr(), libc::MNT_DETACH) != 0 {
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
pub fn read_fd(fd: RawFd, buf: &mut [u8]) -> io::Result<usize> {
    if fd < 0 {
        return Err(invalid("bad read fd"));
    }
    let rc = unsafe { libc::read(fd, buf.as_mut_ptr().cast(), buf.len()) };
    if rc < 0 {
        return Err(io::Error::last_os_error());
    }
    usize::try_from(rc).map_err(|_| invalid("read size overflow"))
}

#[cfg(target_os = "linux")]
pub fn write_fd(fd: RawFd, buf: &[u8]) -> io::Result<usize> {
    if fd < 0 {
        return Err(invalid("bad write fd"));
    }
    let rc = unsafe { libc::write(fd, buf.as_ptr().cast(), buf.len()) };
    if rc < 0 {
        return Err(io::Error::last_os_error());
    }
    usize::try_from(rc).map_err(|_| invalid("write size overflow"))
}

#[cfg(target_os = "linux")]
pub fn close_fd(fd: RawFd) {
    if fd >= 0 {
        unsafe {
            libc::close(fd);
        }
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
}
