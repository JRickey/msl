//! The only module permitted to use `unsafe`; it wraps the required `libc`
//! calls (mounts, `uname`, zombie reaping, `poll`, non-blocking pipes).
#![allow(unsafe_code)]

use std::io;
use std::os::unix::io::RawFd;

const MAX_POLL_TARGETS: usize = 8;
const MAX_POLL_RETRIES: usize = 64;
const MAX_REAP: usize = 4096;

pub struct PollTarget {
    fd: RawFd,
    want: bool,
    pub ready: bool,
    pub hup: bool,
}

impl PollTarget {
    pub const fn read(fd: RawFd, done: bool) -> Self {
        Self {
            fd,
            want: !done,
            ready: false,
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
            events: if t.want { libc::POLLIN } else { 0 },
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
        target.hup = pfd.revents & (libc::POLLHUP | libc::POLLERR) != 0;
    }
    Ok(())
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

pub fn reap_zombies() -> usize {
    let mut reaped: usize = 0;
    // bounded reap pass: at most MAX_REAP zombies per call
    for _ in 0..MAX_REAP {
        let mut status: libc::c_int = 0;
        let pid = unsafe { libc::waitpid(-1, &raw mut status, libc::WNOHANG) };
        if pid <= 0 {
            break;
        }
        reaped = reaped.saturating_add(1);
    }
    reaped
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
    mount_one("tmpfs", "/tmp", "tmpfs", Some("mode=0777"))?;
    Ok(())
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
