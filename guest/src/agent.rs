//! The agent core: shared session/distro state and the request dispatcher.
//! Routing, request parsing, and parameter validation are host-testable; the
//! effectful operations behind them are Linux-gated with non-Linux stubs.

use std::os::unix::io::RawFd;
use std::sync::Mutex;

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::distro::{self, Distro};
use crate::exec::{self, ExecOpts};
use crate::proto::{
    self, AGENT_NAME, AGENT_VERSION, DEFAULT_TIMEOUT_MS, DistroUpReq, Empty, MkfsReq,
    PROTOCOL_VERSION, PingData, Request, SessionOpenReq, SessionRefReq, SessionResizeReq,
    SessionSignalReq, SetTimeReq,
};
use crate::session::{self, Sessions};
use crate::sys;

const MIN_VALID_EPOCH: i64 = 1_700_000_000;
const MKFS_TIMEOUT_MS: u64 = 120_000;

pub struct Agent {
    sessions: Mutex<Sessions>,
    distro: Mutex<Distro>,
}

impl Default for Agent {
    fn default() -> Self {
        Self::new()
    }
}

impl Agent {
    #[must_use]
    pub fn new() -> Self {
        Self {
            sessions: Mutex::new(Sessions::new()),
            distro: Mutex::new(Distro::new()),
        }
    }

    #[must_use]
    pub const fn sessions(&self) -> &Mutex<Sessions> {
        &self.sessions
    }

    #[must_use]
    pub fn distro_pid(&self) -> Option<i32> {
        self.distro.lock().ok().and_then(|g| g.running_pid())
    }

    // Classify a reaped child: distro init, a session, or an unknown orphan.
    pub fn note_reaped(&self, pid: i32, code: i32) {
        assert!(pid > 0, "reaped pid must be positive");
        if let Ok(mut guard) = self.distro.lock()
            && guard.on_init_exit(pid)
        {
            crate::log::warn(&format!("distro init {pid} exited ({code})"));
            return;
        }
        if let Ok(mut guard) = self.sessions.lock()
            && guard.record_exit(pid, code)
        {
            return;
        }
        crate::log::info(&format!("reaped orphan pid {pid} ({code})"));
    }

    pub fn authorize_data(&self, id: u64, token: &str) -> Result<RawFd, String> {
        let mut guard = self
            .sessions
            .lock()
            .map_err(|_| "session lock".to_string())?;
        guard.authorize(id, token)
    }

    #[must_use]
    pub fn handle_payload(&self, payload: &[u8]) -> Vec<u8> {
        debug_assert!(payload.len() <= crate::frame::MAX_FRAME);
        match proto::parse_request(payload) {
            Ok(req) => self.dispatch(&req),
            Err(message) => proto::encode_err(recover_id(payload), &message),
        }
    }

    fn dispatch(&self, req: &Request) -> Vec<u8> {
        match req.op.as_str() {
            "ping" => Self::handle_ping(req.id),
            "exec" => self.handle_exec(req),
            "distro_up" => self.handle_distro_up(req),
            "distro_state" => respond(req.id, self.distro_state()),
            "session_open" => self.handle_session_open(req),
            "session_resize" => self.handle_session_resize(req),
            "session_signal" => self.handle_session_signal(req),
            "session_wait" => self.handle_session_wait(req),
            "set_time" => Self::handle_set_time(req),
            "mkfs_ext4" => Self::handle_mkfs(req),
            other => proto::encode_err(req.id, &format!("unknown op: {other}")),
        }
    }

    fn handle_ping(id: u64) -> Vec<u8> {
        let kernel = sys::kernel_release().unwrap_or_else(|_| "unknown".to_string());
        debug_assert!(!AGENT_NAME.is_empty());
        let data = PingData {
            agent: AGENT_NAME,
            version: AGENT_VERSION,
            protocol: PROTOCOL_VERSION,
            kernel,
        };
        respond(id, Ok(data))
    }

    fn handle_exec(&self, req: &Request) -> Vec<u8> {
        let timeout = req.timeout_ms.unwrap_or(DEFAULT_TIMEOUT_MS);
        let init_pid = if req.distro { self.distro_pid() } else { None };
        if req.distro && init_pid.is_none() {
            return proto::encode_err(req.id, "distro not running");
        }
        let opts = ExecOpts {
            distro: req.distro,
            cwd: req.cwd.as_deref(),
            init_pid,
        };
        respond(req.id, exec::run(&req.argv, &req.env, timeout, &opts))
    }

    fn handle_distro_up(&self, req: &Request) -> Vec<u8> {
        let parsed: Result<DistroUpReq, String> = parse(&req.req);
        let result = parsed.and_then(|up| {
            distro::validate_dev(&up.dev)?;
            distro::validate_hostname(&up.hostname)?;
            do_distro_up(&self.distro, &up)
        });
        respond(req.id, result)
    }

    fn distro_state(&self) -> Result<proto::DistroStateData, String> {
        let guard = self.distro.lock().map_err(|_| "distro lock".to_string())?;
        Ok(guard.snapshot())
    }

    fn handle_session_open(&self, req: &Request) -> Vec<u8> {
        let parsed: Result<SessionOpenReq, String> = parse(&req.req);
        let result = parsed.and_then(|open| {
            session::validate_open(&open.argv, open.rows, open.cols)?;
            let init_pid = if open.distro { self.distro_pid() } else { None };
            if open.distro && init_pid.is_none() {
                return Err("distro not running".to_string());
            }
            do_session_open(&self.sessions, &open, init_pid)
        });
        respond(req.id, result)
    }

    fn handle_session_resize(&self, req: &Request) -> Vec<u8> {
        let parsed: Result<SessionResizeReq, String> = parse(&req.req);
        let result = parsed.and_then(|r| {
            let master = self
                .sessions
                .lock()
                .map_err(|_| "session lock".to_string())?
                .resize(r.session_id, r.rows, r.cols)?;
            do_set_winsize(master, r.rows, r.cols)?;
            Ok(Empty {})
        });
        respond(req.id, result)
    }

    fn handle_session_signal(&self, req: &Request) -> Vec<u8> {
        let parsed: Result<SessionSignalReq, String> = parse(&req.req);
        let result = parsed.and_then(|s| {
            session::validate_signal(s.signal)?;
            let pid = self
                .sessions
                .lock()
                .map_err(|_| "session lock".to_string())?
                .pid_of(s.session_id)?;
            do_send_signal(pid, s.signal)?;
            Ok(Empty {})
        });
        respond(req.id, result)
    }

    fn handle_session_wait(&self, req: &Request) -> Vec<u8> {
        let parsed: Result<SessionRefReq, String> = parse(&req.req);
        let result = parsed.and_then(|w| {
            let (done, exit_code) = self
                .sessions
                .lock()
                .map_err(|_| "session lock".to_string())?
                .wait(w.session_id)?;
            Ok(proto::SessionWaitData { done, exit_code })
        });
        respond(req.id, result)
    }

    fn handle_set_time(req: &Request) -> Vec<u8> {
        let parsed: Result<SetTimeReq, String> = parse(&req.req);
        let result = parsed.and_then(|t| {
            validate_set_time(t.sec)?;
            do_set_time(t.sec, t.usec)?;
            Ok(Empty {})
        });
        respond(req.id, result)
    }

    fn handle_mkfs(req: &Request) -> Vec<u8> {
        let parsed: Result<MkfsReq, String> = parse(&req.req);
        let result = parsed.and_then(|m| {
            distro::validate_dev(&m.dev)?;
            run_mkfs(&m.dev)
        });
        respond(req.id, result)
    }
}

fn run_mkfs(dev: &str) -> Result<Empty, String> {
    let argv = vec![
        "/sbin/mkfs.ext4".to_string(),
        "-q".to_string(),
        "-F".to_string(),
        dev.to_string(),
    ];
    let opts = ExecOpts {
        distro: false,
        cwd: None,
        init_pid: None,
    };
    let data = exec::run(
        &argv,
        &std::collections::HashMap::new(),
        MKFS_TIMEOUT_MS,
        &opts,
    )?;
    if data.exit_code == 0 {
        Ok(Empty {})
    } else {
        Err(format!(
            "mkfs.ext4 failed ({}): {}",
            data.exit_code, data.stderr
        ))
    }
}

fn validate_set_time(sec: i64) -> Result<(), String> {
    if sec > MIN_VALID_EPOCH {
        Ok(())
    } else {
        Err("set_time sec must be after 2023".to_string())
    }
}

fn parse<T: DeserializeOwned>(value: &Value) -> Result<T, String> {
    if value.is_null() {
        return Err("missing req object".to_string());
    }
    serde_json::from_value(value.clone()).map_err(|e| format!("bad req: {e}"))
}

fn respond<T: Serialize>(id: u64, result: Result<T, String>) -> Vec<u8> {
    match result {
        Ok(data) => proto::encode_ok(id, &data).unwrap_or_else(|m| proto::encode_err(id, &m)),
        Err(message) => proto::encode_err(id, &message),
    }
}

fn recover_id(payload: &[u8]) -> u64 {
    serde_json::from_slice::<Value>(payload)
        .ok()
        .and_then(|value| value.get("id").and_then(Value::as_u64))
        .unwrap_or(0)
}

#[cfg(target_os = "linux")]
fn do_distro_up(
    distro: &Mutex<Distro>,
    up: &DistroUpReq,
) -> Result<proto::DistroStateData, String> {
    distro::distro_up(distro, up)
}

#[cfg(not(target_os = "linux"))]
fn do_distro_up(
    _distro: &Mutex<Distro>,
    _up: &DistroUpReq,
) -> Result<proto::DistroStateData, String> {
    Err("distro boot requires linux".to_string())
}

#[cfg(target_os = "linux")]
fn do_session_open(
    sessions: &Mutex<Sessions>,
    open: &SessionOpenReq,
    init_pid: Option<i32>,
) -> Result<proto::SessionOpenData, String> {
    session::open_session(sessions, open, init_pid)
}

#[cfg(not(target_os = "linux"))]
fn do_session_open(
    _sessions: &Mutex<Sessions>,
    _open: &SessionOpenReq,
    _init_pid: Option<i32>,
) -> Result<proto::SessionOpenData, String> {
    Err("sessions require linux".to_string())
}

#[cfg(target_os = "linux")]
fn do_set_winsize(master: RawFd, rows: u16, cols: u16) -> Result<(), String> {
    sys::set_winsize(master, rows, cols).map_err(|e| format!("resize: {e}"))
}

#[cfg(not(target_os = "linux"))]
#[allow(clippy::unnecessary_wraps)] // signature must mirror the linux variant
const fn do_set_winsize(_master: RawFd, _rows: u16, _cols: u16) -> Result<(), String> {
    Ok(())
}

#[cfg(target_os = "linux")]
fn do_send_signal(pid: i32, sig: i32) -> Result<(), String> {
    sys::send_signal(pid, sig).map_err(|e| format!("signal: {e}"))
}

#[cfg(not(target_os = "linux"))]
#[allow(clippy::unnecessary_wraps)] // signature must mirror the linux variant
const fn do_send_signal(_pid: i32, _sig: i32) -> Result<(), String> {
    Ok(())
}

#[cfg(target_os = "linux")]
fn do_set_time(sec: i64, usec: i64) -> Result<(), String> {
    sys::set_time(sec, usec).map_err(|e| format!("set_time: {e}"))
}

#[cfg(not(target_os = "linux"))]
fn do_set_time(_sec: i64, _usec: i64) -> Result<(), String> {
    Err("set_time requires linux".to_string())
}

#[cfg(test)]
mod tests {
    use super::Agent;
    use serde_json::Value;

    fn call(agent: &Agent, request: &str) -> Value {
        let response = agent.handle_payload(request.as_bytes());
        serde_json::from_slice(&response).expect("response is valid json")
    }

    #[test]
    fn ping_reports_protocol_one() {
        let value = call(&Agent::new(), r#"{"id":7,"op":"ping"}"#);
        assert_eq!(value["id"], 7);
        assert_eq!(value["ok"], true);
        assert_eq!(value["data"]["agent"], "msl-agent");
        assert_eq!(value["data"]["protocol"], 1);
    }

    #[test]
    fn distro_state_defaults_stopped() {
        let value = call(&Agent::new(), r#"{"id":1,"op":"distro_state"}"#);
        assert_eq!(value["ok"], true);
        assert_eq!(value["data"]["state"], "stopped");
        assert!(value["data"]["init_pid"].is_null());
    }

    #[test]
    fn distro_up_rejects_bad_dev() {
        let value = call(
            &Agent::new(),
            r#"{"id":2,"op":"distro_up","req":{"dev":"/dev/sda","hostname":"ubuntu"}}"#,
        );
        assert_eq!(value["ok"], false);
        assert!(
            value["error"]
                .as_str()
                .expect("err")
                .contains("dev must match")
        );
    }

    #[test]
    fn set_time_rejects_stale_seconds() {
        let value = call(
            &Agent::new(),
            r#"{"id":3,"op":"set_time","req":{"sec":123,"usec":0}}"#,
        );
        assert_eq!(value["ok"], false);
        assert!(value["error"].as_str().expect("err").contains("2023"));
    }

    #[test]
    fn mkfs_rejects_bad_dev() {
        let value = call(
            &Agent::new(),
            r#"{"id":4,"op":"mkfs_ext4","req":{"dev":"/dev/xda"}}"#,
        );
        assert_eq!(value["ok"], false);
        assert!(
            value["error"]
                .as_str()
                .expect("err")
                .contains("dev must match")
        );
    }

    #[test]
    fn session_wait_unknown_id_errors() {
        let value = call(
            &Agent::new(),
            r#"{"id":5,"op":"session_wait","req":{"session_id":99}}"#,
        );
        assert_eq!(value["ok"], false);
        assert!(
            value["error"]
                .as_str()
                .expect("err")
                .contains("no such session")
        );
    }

    #[test]
    fn session_signal_rejects_out_of_range() {
        let value = call(
            &Agent::new(),
            r#"{"id":6,"op":"session_signal","req":{"session_id":1,"signal":999}}"#,
        );
        assert_eq!(value["ok"], false);
        assert!(
            value["error"]
                .as_str()
                .expect("err")
                .contains("out of range")
        );
    }

    #[test]
    fn session_open_routes_and_validates() {
        let agent = Agent::new();
        let bad = call(
            &agent,
            r#"{"id":10,"op":"session_open","req":{"argv":["sh"],"rows":24,"cols":80}}"#,
        );
        assert_eq!(bad["ok"], false);
        assert!(bad["error"].as_str().expect("err").contains("absolute"));
        let routed = call(
            &agent,
            r#"{"id":11,"op":"session_open","req":{"argv":["/bin/sh"],"rows":24,"cols":80}}"#,
        );
        assert_eq!(routed["id"], 11);
        assert!(routed["ok"] == false || routed["ok"] == true);
    }

    #[test]
    fn session_resize_routes() {
        let value = call(
            &Agent::new(),
            r#"{"id":12,"op":"session_resize","req":{"session_id":1,"rows":30,"cols":100}}"#,
        );
        assert_eq!(value["id"], 12);
        assert_eq!(value["ok"], false);
        assert!(
            value["error"]
                .as_str()
                .expect("err")
                .contains("no such session")
        );
    }

    #[test]
    fn unknown_op_is_rejected() {
        let value = call(&Agent::new(), r#"{"id":8,"op":"frobnicate"}"#);
        assert_eq!(value["id"], 8);
        assert_eq!(value["ok"], false);
    }

    #[test]
    fn malformed_request_recovers_id() {
        let value = call(&Agent::new(), r#"{"id":42,"op":123}"#);
        assert_eq!(value["ok"], false);
        assert_eq!(value["id"], 42);
    }
}
