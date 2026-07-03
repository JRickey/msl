//! The shim's Linux runtime: dial the host on vsock 5010, exchange the
//! `mac_exec` hello, then single-threaded pump stdin/SIGWINCH up and the
//! tagged stdout/stderr/exit stream down until the host reports an exit.

use std::io;
use std::os::unix::io::{AsRawFd, RawFd};

use vsock::{VsockAddr, VsockStream};

use msl_wire::frame::{read_frame, write_frame};
use msl_wire::{PollTarget, poll_fds, read_fd, write_fd};

use crate::proto::{
    self, DATA_MAX, TAG_EXIT, TAG_STDERR, TAG_STDIN, TAG_STDIN_EOF, TAG_STDOUT, TAG_WINCH,
};
use crate::tty;

const STDIN_FD: RawFd = 0;
const STDOUT_FD: RawFd = 1;
const STDERR_FD: RawFd = 2;

const HOST_PORT: u32 = 5010;
const EXIT_USAGE: i32 = 255;
const EXIT_CHANNEL: i32 = 254;
const HELLO_TIMEOUT_SECS: u32 = 10;
// Bounded pump wake so a pending SIGWINCH is serviced even with no I/O.
const WINCH_POLL_MS: i32 = 200;

enum Sock {
    Continue,
    Stop(i32),
}

pub fn run() -> i32 {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    if let Err(msg) = proto::validate_argv(&argv) {
        eprintln!("mac: {msg}\nusage: mac <command> [args...]");
        return EXIT_USAGE;
    }
    let tty_on = tty::is_tty();
    let (rows, cols) = if tty_on { tty::winsize() } else { (0, 0) };
    let cwd = std::env::current_dir()
        .map_or_else(|_| "/".to_string(), |p| p.to_string_lossy().into_owned());
    let hello = proto::build_hello(argv, cwd, std::env::var("TERM").ok(), tty_on, rows, cols);
    let bytes = match proto::hello_bytes(&hello) {
        Ok(bytes) => bytes,
        Err(e) => return fail_local(&format!("hello encode: {e}")),
    };
    let mut stream = match connect_host() {
        Ok(stream) => stream,
        Err(e) => return fail_local(&format!("connect: {e}")),
    };
    if let Err(e) = exchange_hello(&mut stream, &bytes) {
        return fail_local(&e);
    }
    run_session(&mut stream, tty_on)
}

fn fail_local(msg: &str) -> i32 {
    assert!(!msg.is_empty(), "error message must be non-empty");
    eprintln!("mac: {msg}");
    EXIT_USAGE
}

fn connect_host() -> io::Result<VsockStream> {
    let addr = VsockAddr::new(libc::VMADDR_CID_HOST, HOST_PORT);
    let stream = VsockStream::connect(&addr)?;
    assert!(stream.as_raw_fd() >= 0, "connected socket must be valid");
    Ok(stream)
}

// The timeout bounds only the handshake (mirroring the host's 10s hello
// timeout); it is cleared before the pump, whose reads may idle indefinitely.
fn exchange_hello(stream: &mut VsockStream, hello: &[u8]) -> Result<(), String> {
    assert!(!hello.is_empty(), "hello frame must carry bytes");
    set_recv_timeout(stream.as_raw_fd(), HELLO_TIMEOUT_SECS);
    write_frame(stream, hello).map_err(|e| format!("hello send: {e}"))?;
    let reply = read_frame(stream).map_err(|e| format!("hello reply: {e}"))?;
    set_recv_timeout(stream.as_raw_fd(), 0);
    let parsed = proto::parse_reply(&reply).map_err(|e| format!("bad reply: {e}"))?;
    if parsed.ok {
        Ok(())
    } else {
        Err(parsed.error.unwrap_or_else(|| "exec rejected".to_string()))
    }
}

#[allow(unsafe_code)] // C ABI: setsockopt(2) with a borrowed timeval (0 = no timeout).
fn set_recv_timeout(fd: RawFd, secs: u32) {
    assert!(fd >= 0, "timeout target must be a valid fd");
    let tv = libc::timeval {
        tv_sec: i64::from(secs),
        tv_usec: 0,
    };
    let len = libc::socklen_t::try_from(std::mem::size_of::<libc::timeval>()).unwrap_or(0);
    let rc = unsafe {
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            libc::SO_RCVTIMEO,
            (&raw const tv).cast::<libc::c_void>(),
            len,
        )
    };
    debug_assert!(rc == 0 || rc == -1, "setsockopt returns 0 or -1");
}

fn run_session(stream: &mut VsockStream, tty_on: bool) -> i32 {
    let guard = if tty_on {
        tty::install_winch();
        tty::enable_raw()
    } else {
        None
    };
    let code = run_pump(stream, tty_on);
    drop(guard);
    code
}

fn run_pump(stream: &mut VsockStream, tty_on: bool) -> i32 {
    let sock_fd = stream.as_raw_fd();
    assert!(sock_fd >= 0, "pump needs a valid socket fd");
    let mut stdin_done = false;
    let mut buf = vec![0u8; DATA_MAX].into_boxed_slice();
    // sanctioned infinite pump loop: returns on the tag-3 exit frame or on any
    // framing error/close; the bounded poll wake also services SIGWINCH.
    loop {
        if tty_on && tty::take_winch() && send_winch(stream).is_err() {
            return EXIT_CHANNEL;
        }
        let mut targets = [
            PollTarget::read(STDIN_FD, stdin_done),
            PollTarget::read(sock_fd, false),
        ];
        if poll_fds(&mut targets, WINCH_POLL_MS).is_err() {
            return EXIT_CHANNEL;
        }
        if (targets[1].ready || targets[1].hup)
            && let Sock::Stop(code) = service_socket(stream)
        {
            return code;
        }
        if !stdin_done && (targets[0].ready || targets[0].hup) {
            match service_stdin(stream, &mut buf) {
                Ok(eof) => stdin_done = eof,
                Err(()) => return EXIT_CHANNEL,
            }
        }
    }
}

fn send_winch(stream: &mut VsockStream) -> Result<(), ()> {
    let (rows, cols) = tty::winsize();
    let frame = proto::frame_with_tag(TAG_WINCH, &proto::winch_json(rows, cols));
    write_frame(stream, &frame).map_err(|_| ())
}

fn service_socket(stream: &mut VsockStream) -> Sock {
    let Ok(payload) = read_frame(stream) else {
        return Sock::Stop(EXIT_CHANNEL);
    };
    let Some((&tag, data)) = payload.split_first() else {
        return Sock::Stop(EXIT_CHANNEL);
    };
    match tag {
        TAG_STDOUT => drain_or_stop(STDOUT_FD, data),
        TAG_STDERR => drain_or_stop(STDERR_FD, data),
        TAG_EXIT => proto::parse_exit_code(data).map_or(Sock::Stop(EXIT_CHANNEL), Sock::Stop),
        _ => Sock::Stop(EXIT_CHANNEL),
    }
}

fn drain_or_stop(fd: RawFd, data: &[u8]) -> Sock {
    if write_all_fd(fd, data).is_ok() {
        Sock::Continue
    } else {
        Sock::Stop(EXIT_CHANNEL)
    }
}

// Ok(true) on stdin EOF (tag-5 sent, stop polling stdin); Ok(false) to keep
// forwarding; Err on a socket write failure that ends the session.
fn service_stdin(stream: &mut VsockStream, buf: &mut [u8]) -> Result<bool, ()> {
    assert!(!buf.is_empty(), "stdin buffer must be sized");
    let n = read_fd(STDIN_FD, buf).map_err(|_| ())?;
    if n == 0 {
        return write_frame(stream, &[TAG_STDIN_EOF])
            .map(|()| true)
            .map_err(|_| ());
    }
    let frame = proto::frame_with_tag(TAG_STDIN, &buf[..n]);
    write_frame(stream, &frame).map(|()| false).map_err(|_| ())
}

fn write_all_fd(fd: RawFd, data: &[u8]) -> io::Result<()> {
    assert!(fd >= 0, "write target must be a valid fd");
    let mut off = 0usize;
    // bounded: a blocking fd drains at least one byte per iteration
    for _ in 0..=data.len() {
        if off >= data.len() {
            return Ok(());
        }
        let n = write_fd(fd, &data[off..])?;
        if n == 0 {
            return Err(io::Error::other("short write to terminal"));
        }
        off += n;
    }
    debug_assert!(off <= data.len());
    Err(io::Error::other("write did not complete"))
}
