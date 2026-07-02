//! msl-agent: runs as PID 1 in the initramfs. It mounts the pseudo
//! filesystems, then serves the M0 vsock protocol one request at a time.

// The vsock server path is linux-only; the host build compiles the portable
// modules for tests, leaving the server helpers legitimately unused there.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

mod exec;
mod frame;
mod proto;
mod sys;

use proto::{PingData, Request, AGENT_NAME, AGENT_VERSION, DEFAULT_TIMEOUT_MS};
use serde_json::Value;

#[cfg(target_os = "linux")]
use std::time::Duration;
#[cfg(target_os = "linux")]
use vsock::{VsockAddr, VsockListener, VsockStream, VMADDR_CID_ANY};

#[cfg(target_os = "linux")]
const VSOCK_PORT: u32 = 5000;
#[cfg(target_os = "linux")]
const FATAL_PAUSE_TICKS: u32 = 5;

#[cfg(target_os = "linux")]
fn main() {
    run_forever();
}

#[cfg(not(target_os = "linux"))]
fn main() {
    // The host build exists only to run the unit tests; exercise the handler
    // so it is not dead code, then exit.
    let _ = handle_payload(br#"{"id":0,"op":"ping"}"#);
    eprintln!("msl-agent: host build is for tests only; PID-1 server needs linux");
}

fn handle_payload(payload: &[u8]) -> Vec<u8> {
    debug_assert!(payload.len() <= frame::MAX_FRAME);
    match proto::parse_request(payload) {
        Ok(req) => dispatch(&req),
        Err(message) => proto::encode_err(recover_id(payload), &message),
    }
}

fn recover_id(payload: &[u8]) -> u64 {
    serde_json::from_slice::<Value>(payload)
        .ok()
        .and_then(|value| value.get("id").and_then(Value::as_u64))
        .unwrap_or(0)
}

fn dispatch(req: &Request) -> Vec<u8> {
    match req.op.as_str() {
        "ping" => handle_ping(req.id),
        "exec" => handle_exec(req),
        other => proto::encode_err(req.id, &format!("unknown op: {other}")),
    }
}

fn handle_ping(id: u64) -> Vec<u8> {
    let kernel = sys::kernel_release().unwrap_or_else(|_| "unknown".to_string());
    debug_assert!(!AGENT_NAME.is_empty());
    let data = PingData {
        agent: AGENT_NAME,
        version: AGENT_VERSION,
        kernel,
    };
    proto::encode_ok(id, &data).unwrap_or_else(|message| proto::encode_err(id, &message))
}

fn handle_exec(req: &Request) -> Vec<u8> {
    let timeout_ms = req.timeout_ms.unwrap_or(DEFAULT_TIMEOUT_MS);
    match exec::run(&req.argv, &req.env, timeout_ms) {
        Ok(data) => proto::encode_ok(req.id, &data)
            .unwrap_or_else(|message| proto::encode_err(req.id, &message)),
        Err(message) => proto::encode_err(req.id, &message),
    }
}

#[cfg(target_os = "linux")]
fn run_forever() -> ! {
    // outer loop is intentional: PID 1 must never return
    loop {
        if let Err(e) = sys::mount_early() {
            log_console(&format!("mount failed, not serving: {e}"));
            fatal_pause();
        } else if let Err(e) = serve() {
            log_console(&format!("listener failed: {e}"));
            fatal_pause();
        }
    }
}

#[cfg(target_os = "linux")]
fn serve() -> std::io::Result<()> {
    let listener = VsockListener::bind(&VsockAddr::new(VMADDR_CID_ANY, VSOCK_PORT))?;
    accept_loop(&listener);
    Ok(())
}

#[cfg(target_os = "linux")]
fn accept_loop(listener: &VsockListener) {
    // sanctioned infinite accept loop: sequential M0 server, one connection at a time
    loop {
        match listener.accept() {
            Ok((stream, _addr)) => serve_connection(stream),
            Err(e) => {
                log_console(&format!("accept failed: {e}"));
                return;
            }
        }
        let _ = sys::reap_zombies();
    }
}

#[cfg(target_os = "linux")]
fn serve_connection(mut stream: VsockStream) {
    // sanctioned per-connection serve loop: one request in flight at a time
    loop {
        let Ok(payload) = frame::read_frame(&mut stream) else {
            return;
        };
        let response = handle_payload(&payload);
        if frame::write_frame(&mut stream, &response).is_err() {
            return;
        }
        let _ = sys::reap_zombies();
    }
}

#[cfg(target_os = "linux")]
fn fatal_pause() {
    // bounded pause pass; the caller's intentional outer loop retries the bind
    for _ in 0..FATAL_PAUSE_TICKS {
        std::thread::sleep(Duration::from_secs(1));
    }
}

#[cfg(target_os = "linux")]
fn log_console(msg: &str) {
    use std::io::Write;
    if let Ok(mut file) = std::fs::OpenOptions::new().write(true).open("/dev/console") {
        let _ = writeln!(file, "msl-agent: {msg}");
    }
}

#[cfg(test)]
mod tests {
    use super::handle_payload;
    use serde_json::Value;

    fn call(request: &str) -> Value {
        let response = handle_payload(request.as_bytes());
        serde_json::from_slice(&response).expect("response is valid json")
    }

    #[test]
    fn ping_reports_agent_identity() {
        let value = call(r#"{"id":7,"op":"ping"}"#);
        assert_eq!(value["id"], 7);
        assert_eq!(value["ok"], true);
        assert_eq!(value["data"]["agent"], "msl-agent");
        assert_eq!(value["data"]["version"], "0.0.1");
    }

    #[test]
    fn exec_echo_captures_stdout() {
        let value = call(r#"{"id":9,"op":"exec","argv":["/bin/echo","m0-ok"]}"#);
        assert_eq!(value["id"], 9);
        assert_eq!(value["ok"], true);
        assert_eq!(value["data"]["exit_code"], 0);
        assert_eq!(value["data"]["stdout"], "m0-ok\n");
        assert_eq!(value["data"]["truncated"], false);
    }

    #[test]
    fn exec_rejects_relative_path() {
        let value = call(r#"{"id":3,"op":"exec","argv":["echo","hi"]}"#);
        assert_eq!(value["id"], 3);
        assert_eq!(value["ok"], false);
        assert!(value["error"]
            .as_str()
            .expect("error string")
            .contains("absolute"));
    }

    #[test]
    fn unknown_op_is_rejected() {
        let value = call(r#"{"id":4,"op":"frobnicate"}"#);
        assert_eq!(value["id"], 4);
        assert_eq!(value["ok"], false);
    }

    #[test]
    fn malformed_request_is_rejected() {
        let value = call("not json");
        assert_eq!(value["ok"], false);
        assert_eq!(value["id"], 0);
    }

    #[test]
    fn parse_failure_recovers_request_id() {
        let value = call(r#"{"id":42,"op":123}"#);
        assert_eq!(value["ok"], false);
        assert_eq!(value["id"], 42);
    }
}
