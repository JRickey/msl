//! msl-agent: runs as PID 1 in the initramfs. It mounts the pseudo
//! filesystems, then serves the M1 vsock protocol: a threaded control plane on
//! 5000, PTY sessions on 5001, and a log stream on 5002.

// Many portable helpers are exercised only by the Linux server; the host build
// compiles them for the unit tests, leaving them legitimately unused there.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

mod agent;
mod conn;
mod distro;
mod exec;
mod frame;
mod log;
mod mem;
mod net;
mod proto;
mod session;
mod sys;
mod wait;

#[cfg(target_os = "linux")]
mod server;

use agent::Agent;

#[cfg(target_os = "linux")]
use std::sync::Arc;
#[cfg(target_os = "linux")]
use std::time::Duration;

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
    let _ = Agent::new().handle_payload(br#"{"id":0,"op":"ping"}"#);
    eprintln!("msl-agent: host build is for tests only; PID-1 server needs linux");
}

#[cfg(target_os = "linux")]
fn run_forever() -> ! {
    if let Err(e) = sys::mount_early() {
        log::error(&format!("early mount failed: {e}"));
    }
    mount_shares();
    mem::boot_tuning();
    let agent = Arc::new(Agent::new());
    server::spawn_background(&agent);
    // outer loop is intentional: PID 1 must never return; rebind on failure
    loop {
        if let Err(e) = server::serve_control(&agent) {
            log::error(&format!("control listener failed: {e}"));
            fatal_pause();
        }
    }
}

#[cfg(target_os = "linux")]
fn mount_shares() {
    let _ = std::fs::create_dir_all("/run/msl/mac");
    let _ = std::fs::create_dir_all("/run/msl/staging");
    let _ = std::fs::create_dir_all("/run/msl/rosetta");
    if sys::mount_share("mac", "/run/msl/mac").is_ok() {
        log::info("mounted virtiofs share 'mac' at /run/msl/mac");
    }
    let _ = sys::mount_share("staging", "/run/msl/staging");
    if sys::mount_share("rosetta", "/run/msl/rosetta").is_ok() {
        log::info("mounted virtiofs share 'rosetta' at /run/msl/rosetta");
    }
}

#[cfg(target_os = "linux")]
fn fatal_pause() {
    // bounded pause pass; the caller's intentional outer loop retries the bind
    for _ in 0..FATAL_PAUSE_TICKS {
        std::thread::sleep(Duration::from_secs(1));
    }
}

#[cfg(test)]
mod tests {
    use crate::agent::Agent;
    use serde_json::Value;

    fn call(request: &str) -> Value {
        let response = Agent::new().handle_payload(request.as_bytes());
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
        assert!(
            value["error"]
                .as_str()
                .expect("error string")
                .contains("absolute")
        );
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
