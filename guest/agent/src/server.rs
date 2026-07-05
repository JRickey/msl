//! Linux vsock server: the control plane (5000, thread-per-connection, capped),
//! the PTY data plane (5001, token handshake then pump), the log reader (5002),
//! and the blocking single-owner reaper thread that owns `waitpid`.

use std::io;
use std::os::unix::io::{AsRawFd, IntoRawFd};
use std::sync::Arc;
use std::sync::atomic::AtomicUsize;
use std::thread;
use std::time::Duration;

use serde::Serialize;
use vsock::{VMADDR_CID_ANY, VsockAddr, VsockListener, VsockStream};

use crate::agent::Agent;
use crate::proto::{DataHello, ForwardHello, FsOpenHello};
use crate::{conn, distro, frame, log, net, proto, session, sys, wait};

const CONTROL_PORT: u32 = 5000;
const DATA_PORT: u32 = 5001;
const LOG_PORT: u32 = 5002;
const FORWARD_PORT: u32 = 5003;
const FS_PORT: u32 = 5030;
const MAX_CONTROL_CONNS: usize = 16;
const MAX_FORWARD_CONNS: usize = 64;
// Sessions cap at 64; the extra headroom absorbs handshake churn.
const MAX_DATA_CONNS: usize = 80;
// One live volume per distro (<=26); the cap bounds in-flight fs handshakes.
const MAX_FS_CONNS: usize = 32;
const HELLO_TIMEOUT_SECS: u32 = 10;
// fs-service protocol version (FSProto.version on the host), independent of the
// control PROTOCOL_VERSION.
const FS_PROTOCOL_VERSION: u32 = 1;
// msl-fsd inside a distro: the initramfs /tools bind mount (same as mac-binfmt).
const FSD_GUEST_PATH: &str = "/run/msl/tools/msl-fsd";
const IDLE_POLL: Duration = Duration::from_millis(100);
const REBIND_PAUSE: Duration = Duration::from_secs(1);

static CONTROL_ACTIVE: AtomicUsize = AtomicUsize::new(0);
static DATA_ACTIVE: AtomicUsize = AtomicUsize::new(0);
static FORWARD_ACTIVE: AtomicUsize = AtomicUsize::new(0);
static FS_ACTIVE: AtomicUsize = AtomicUsize::new(0);

#[derive(Serialize)]
struct HelloReply<'a> {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<&'a str>,
}

pub fn spawn_background(agent: &Arc<Agent>) {
    let reaper = Arc::clone(agent);
    let _ = thread::Builder::new()
        .name("reaper".to_string())
        .spawn(move || reaper_loop(&reaper));
    let data = Arc::clone(agent);
    let _ = thread::Builder::new()
        .name("data".to_string())
        .spawn(move || data_listener_loop(&data));
    let _ = thread::Builder::new()
        .name("forward".to_string())
        .spawn(forward_listener_loop);
    let fs = Arc::clone(agent);
    let _ = thread::Builder::new()
        .name("fs".to_string())
        .spawn(move || fs_listener_loop(&fs));
    let _ = thread::Builder::new()
        .name("logs".to_string())
        .spawn(log_listener_loop);
}

fn reaper_loop(agent: &Arc<Agent>) -> ! {
    // sanctioned infinite reap loop: PID 1 single-owner reaper (blocking waitpid)
    loop {
        match sys::reap_blocking() {
            Some((pid, code)) => classify(agent, pid, code),
            None => thread::sleep(IDLE_POLL),
        }
    }
}

// Deliver to an exec waiter, else attribute to a session or the distro init.
// Held under the spawn lock so a just-forked pid is always already registered.
fn classify(agent: &Arc<Agent>, pid: i32, code: i32) {
    let _spawn = wait::spawn_lock();
    if wait::deliver(pid, code) {
        return;
    }
    agent.note_reaped(pid, code);
}

fn bind(port: u32) -> io::Result<VsockListener> {
    let listener = VsockListener::bind(&VsockAddr::new(VMADDR_CID_ANY, port))?;
    let _ = sys::set_cloexec(listener.as_raw_fd());
    Ok(listener)
}

pub fn serve_control(agent: &Arc<Agent>) -> io::Result<()> {
    let listener = bind(CONTROL_PORT)?;
    log::info("control plane listening on vsock:5000");
    // sanctioned infinite accept loop: control plane, one thread per connection
    loop {
        let (stream, _addr) = listener.accept()?;
        let _ = sys::set_cloexec(stream.as_raw_fd());
        let Some(slot) = conn::try_reserve(&CONTROL_ACTIVE, MAX_CONTROL_CONNS) else {
            reject_control(stream);
            continue;
        };
        let agent = Arc::clone(agent);
        let _ = thread::Builder::new()
            .name("control".to_string())
            .spawn(move || {
                // slot releases the reservation when this thread ends (or if the
                // spawn itself fails and drops the closure).
                let _slot = slot;
                serve_control_conn(&agent, stream);
            });
    }
}

fn reject_control(mut stream: VsockStream) {
    let _ = sys::set_send_timeout(stream.as_raw_fd(), HELLO_TIMEOUT_SECS);
    let body = proto::encode_err(0, "too many control connections");
    let _ = frame::write_frame(&mut stream, &body);
}

fn serve_control_conn(agent: &Arc<Agent>, mut stream: VsockStream) {
    // sanctioned per-connection serve loop: requests sequential within a connection
    loop {
        let Ok(payload) = frame::read_frame(&mut stream) else {
            return;
        };
        let response = agent.handle_payload(&payload);
        if frame::write_frame(&mut stream, &response).is_err() {
            return;
        }
    }
}

fn data_listener_loop(agent: &Arc<Agent>) -> ! {
    // sanctioned infinite rebind loop: the data listener must always recover
    loop {
        match bind(DATA_PORT) {
            Ok(listener) => data_accept_loop(agent, &listener),
            Err(e) => {
                log::error(&format!("data bind failed: {e}"));
                thread::sleep(REBIND_PAUSE);
            }
        }
    }
}

fn data_accept_loop(agent: &Arc<Agent>, listener: &VsockListener) {
    // sanctioned infinite accept loop: PTY data connections, one thread each
    loop {
        let Ok((stream, _addr)) = listener.accept() else {
            return;
        };
        let _ = sys::set_cloexec(stream.as_raw_fd());
        let Some(slot) = conn::try_reserve(&DATA_ACTIVE, MAX_DATA_CONNS) else {
            reject_data(stream);
            continue;
        };
        let _ = sys::set_recv_timeout(stream.as_raw_fd(), HELLO_TIMEOUT_SECS);
        let agent = Arc::clone(agent);
        let _ = thread::Builder::new()
            .name("pty".to_string())
            .spawn(move || {
                let _slot = slot;
                handle_data(&agent, stream);
            });
    }
}

fn reject_data(mut stream: VsockStream) {
    let _ = sys::set_send_timeout(stream.as_raw_fd(), HELLO_TIMEOUT_SECS);
    write_hello(&mut stream, Some("too many data connections"));
}

fn handle_data(agent: &Arc<Agent>, mut stream: VsockStream) {
    let Ok(payload) = frame::read_frame(&mut stream) else {
        return;
    };
    let Ok(hello) = serde_json::from_slice::<DataHello>(&payload) else {
        write_hello(&mut stream, Some("bad handshake"));
        return;
    };
    match agent.authorize_data(hello.session_id, &hello.token) {
        Ok(master) => {
            write_hello(&mut stream, None);
            session::pump(agent.sessions(), hello.session_id, master, stream);
        }
        Err(message) => write_hello(&mut stream, Some(&message)),
    }
}

fn write_hello(stream: &mut VsockStream, error: Option<&str>) {
    let reply = HelloReply {
        ok: error.is_none(),
        error,
    };
    if let Ok(body) = serde_json::to_vec(&reply) {
        let _ = frame::write_frame(stream, &body);
    }
}

fn forward_listener_loop() -> ! {
    // sanctioned infinite rebind loop: the forward listener must always recover
    loop {
        match bind(FORWARD_PORT) {
            Ok(listener) => forward_accept_loop(&listener),
            Err(e) => {
                log::error(&format!("forward bind failed: {e}"));
                thread::sleep(REBIND_PAUSE);
            }
        }
    }
}

fn forward_accept_loop(listener: &VsockListener) {
    // sanctioned infinite accept loop: forward connections, one thread each
    loop {
        let Ok((stream, _addr)) = listener.accept() else {
            return;
        };
        let _ = sys::set_cloexec(stream.as_raw_fd());
        let Some(slot) = conn::try_reserve(&FORWARD_ACTIVE, MAX_FORWARD_CONNS) else {
            reject_forward(stream);
            continue;
        };
        let _ = sys::set_recv_timeout(stream.as_raw_fd(), HELLO_TIMEOUT_SECS);
        let _ = thread::Builder::new()
            .name("fwd".to_string())
            .spawn(move || {
                let _slot = slot;
                handle_forward(stream);
            });
    }
}

fn reject_forward(mut stream: VsockStream) {
    let _ = sys::set_send_timeout(stream.as_raw_fd(), HELLO_TIMEOUT_SECS);
    write_hello(&mut stream, Some("too many forwarded connections"));
}

// One guest TCP connection proxied per vsock connection: framed {"port"} hello,
// dial loopback, then relay raw bytes until either side closes.
fn handle_forward(mut stream: VsockStream) {
    let Ok(payload) = frame::read_frame(&mut stream) else {
        return;
    };
    let Ok(hello) = serde_json::from_slice::<ForwardHello>(&payload) else {
        write_hello(&mut stream, Some("bad forward handshake"));
        return;
    };
    match net::forward_connect(hello.port) {
        Ok(tcp) => {
            write_hello(&mut stream, None);
            net::pump_streams(tcp.into_raw_fd(), stream.into_raw_fd());
        }
        Err(message) => write_hello(&mut stream, Some(&message)),
    }
}

fn fs_listener_loop(agent: &Arc<Agent>) -> ! {
    // sanctioned infinite rebind loop: the fs listener must always recover
    loop {
        match bind(FS_PORT) {
            Ok(listener) => fs_accept_loop(agent, &listener),
            Err(e) => {
                log::error(&format!("fs bind failed: {e}"));
                thread::sleep(REBIND_PAUSE);
            }
        }
    }
}

fn fs_accept_loop(agent: &Arc<Agent>, listener: &VsockListener) {
    // sanctioned infinite accept loop: fs connections, one handshake thread each
    loop {
        let Ok((stream, _addr)) = listener.accept() else {
            return;
        };
        let _ = sys::set_cloexec(stream.as_raw_fd());
        let Some(slot) = conn::try_reserve(&FS_ACTIVE, MAX_FS_CONNS) else {
            reject_fs(stream);
            continue;
        };
        let _ = sys::set_recv_timeout(stream.as_raw_fd(), HELLO_TIMEOUT_SECS);
        let agent = Arc::clone(agent);
        let _ = thread::Builder::new()
            .name("fs".to_string())
            .spawn(move || {
                let _slot = slot;
                handle_fs(&agent, stream);
            });
    }
}

fn reject_fs(mut stream: VsockStream) {
    let _ = sys::set_send_timeout(stream.as_raw_fd(), HELLO_TIMEOUT_SECS);
    write_hello(&mut stream, Some("too many fs connections"));
}

// After the ack the worker owns the stream on its fd 3; the agent's copy drops
// when this thread returns.
fn handle_fs(agent: &Arc<Agent>, mut stream: VsockStream) {
    let Ok(payload) = frame::read_frame(&mut stream) else {
        return;
    };
    let Ok(hello) = serde_json::from_slice::<FsOpenHello>(&payload) else {
        write_hello(&mut stream, Some("bad fs handshake"));
        return;
    };
    match spawn_fs_worker(agent, &hello, &stream) {
        Ok(()) => write_hello(&mut stream, None),
        Err(message) => write_hello(&mut stream, Some(&message)),
    }
}

// The spawn lock keeps {fork, note_fsd_spawn} atomic against the reaper's
// classify step, so a just-forked leader is always already attributable.
fn spawn_fs_worker(
    agent: &Arc<Agent>,
    hello: &FsOpenHello,
    stream: &VsockStream,
) -> Result<(), String> {
    if hello.op != "fs_open" {
        return Err(format!("unexpected fs op: {}", hello.op));
    }
    if hello.v != FS_PROTOCOL_VERSION {
        return Err(format!("fs protocol {} != {FS_PROTOCOL_VERSION}", hello.v));
    }
    distro::validate_name(&hello.distro)?;
    let init_pid = agent
        .distro_pid(&hello.distro)
        .ok_or_else(|| "distro not running".to_string())?;
    assert!(init_pid > 0, "resolved init pid must be positive");
    // The handshake read timeout is shared with the worker's inherited fd 3;
    // clear it so idle Finder gaps don't expire the worker's blocking reads.
    sys::clear_recv_timeout(stream.as_raw_fd()).map_err(|e| format!("fs clear timeout: {e}"))?;
    let ns_fds = sys::open_ns_fds(init_pid).map_err(|e| format!("fs ns open: {e}"))?;
    let spec = sys::FsdSpec::new(ns_fds, stream.as_raw_fd(), FSD_GUEST_PATH)
        .map_err(|e| format!("fs spec: {e}"))?;
    let leader = {
        let _spawn = wait::spawn_lock();
        let spawned = sys::spawn_fsd(&spec);
        sys::close_all(&spec.ns_fds);
        let leader = spawned.map_err(|e| format!("spawn fsd: {e}"))?;
        agent.note_fsd_spawn(leader, &hello.distro);
        leader
    };
    assert!(leader > 0, "fsd leader pid must be positive");
    log::info(&format!("fs worker up for '{}' pid {leader}", hello.distro));
    Ok(())
}

fn log_listener_loop() -> ! {
    // sanctioned infinite rebind loop: the log listener must always recover
    loop {
        match bind(LOG_PORT) {
            Ok(listener) => log_accept_loop(&listener),
            Err(_) => thread::sleep(REBIND_PAUSE),
        }
    }
}

fn log_accept_loop(listener: &VsockListener) {
    // sanctioned infinite accept loop: at most one active log reader at a time
    loop {
        let Ok((stream, _addr)) = listener.accept() else {
            return;
        };
        let _ = sys::set_cloexec(stream.as_raw_fd());
        let _ = stream.set_nonblocking(true);
        log::attach_reader(Box::new(stream));
    }
}
