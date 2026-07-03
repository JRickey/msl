//! The `poll(2)` multiplexer and the raw fd read/write/close primitives shared
//! by the agent's session pumps and the shim's stdin/socket pump. This module
//! wraps the required `libc` calls, so it opts into `unsafe`.
#![allow(unsafe_code)]

use std::io;
use std::os::unix::io::RawFd;

pub const MAX_POLL_TARGETS: usize = 8;
pub const MAX_POLL_RETRIES: usize = 64;

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

#[cfg(target_os = "linux")]
fn invalid(msg: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, msg)
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
