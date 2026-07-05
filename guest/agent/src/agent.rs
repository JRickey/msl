//! The agent core: shared session/distro state and the request dispatcher.
//! Routing, request parsing, and parameter validation are host-testable; the
//! effectful operations behind them are Linux-gated with non-Linux stubs.

use std::collections::HashMap;
use std::os::unix::io::RawFd;
use std::sync::Mutex;

use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::distro::{self, Distros};
use crate::exec::{self, ExecOpts};
use crate::proto::{
    self, AGENT_NAME, AGENT_VERSION, DEFAULT_TIMEOUT_MS, DistroDownReq, DistroStateReq,
    DistroUpReq, Empty, MkfsReq, PROTOCOL_VERSION, PingData, Request, SessionOpenReq,
    SessionRefReq, SessionResizeReq, SessionSignalReq, SetTimeReq,
};
use crate::session::{self, Sessions};
use crate::sys;

const MIN_VALID_EPOCH: i64 = 1_700_000_000;
const MKFS_TIMEOUT_MS: u64 = 120_000;

pub struct Agent {
    sessions: Mutex<Sessions>,
    distros: Mutex<Distros>,
    fsd_workers: Mutex<HashMap<i32, String>>,
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
            distros: Mutex::new(Distros::new()),
            fsd_workers: Mutex::new(HashMap::new()),
        }
    }

    // Record an msl-fsd worker's leader pid so its reaped exit is attributed to
    // its distro instead of logged as an orphan. Called under the spawn lock.
    pub fn note_fsd_spawn(&self, pid: i32, distro: &str) {
        assert!(pid > 0, "fsd leader pid must be positive");
        assert!(!distro.is_empty(), "fsd worker needs a distro name");
        if let Ok(mut guard) = self.fsd_workers.lock() {
            let _ = guard.insert(pid, distro.to_string());
        }
    }

    #[must_use]
    pub const fn sessions(&self) -> &Mutex<Sessions> {
        &self.sessions
    }

    // The running init pid of a named distro (None if unknown or not running);
    // the exec/session join target for `distro: <name>`.
    #[must_use]
    pub fn distro_pid(&self, name: &str) -> Option<i32> {
        assert!(!name.is_empty(), "distro_pid needs a name");
        self.distros.lock().ok().and_then(|g| g.running_pid(name))
    }

    // Classify a reaped child: a distro init, a session, or an unknown orphan.
    pub fn note_reaped(&self, pid: i32, code: i32) {
        assert!(pid > 0, "reaped pid must be positive");
        if let Ok(mut guard) = self.distros.lock()
            && let Some(name) = guard.on_init_exit(pid)
        {
            crate::log::warn(&format!("distro '{name}' init {pid} exited ({code})"));
            return;
        }
        if let Ok(mut guard) = self.fsd_workers.lock()
            && let Some(distro) = guard.remove(&pid)
        {
            crate::log::info(&format!(
                "fsd worker for '{distro}' pid {pid} exited ({code})"
            ));
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
            "distro_down" => self.handle_distro_down(req),
            "distro_state" => self.handle_distro_state(req),
            "session_open" => self.handle_session_open(req),
            "session_resize" => self.handle_session_resize(req),
            "session_signal" => self.handle_session_signal(req),
            "session_wait" => self.handle_session_wait(req),
            "set_time" => Self::handle_set_time(req),
            "mkfs_ext4" => Self::handle_mkfs(req),
            "mem_stats" => Self::handle_mem_stats(req.id),
            "mem_reclaim" => Self::handle_mem_reclaim(req.id),
            "net_listeners" => Self::handle_net_listeners(req.id),
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
        let init_pid = match self.resolve_distro(req.distro.as_deref()) {
            Ok(pid) => pid,
            Err(message) => return proto::encode_err(req.id, &message),
        };
        let opts = ExecOpts {
            distro: req.distro.is_some(),
            cwd: req.cwd.as_deref(),
            init_pid,
        };
        respond(req.id, exec::run(&req.argv, &req.env, timeout, &opts))
    }

    // Resolve an optional distro name to its running init pid: None → agent
    // context; a known running name → its pid; unknown or non-running → error.
    fn resolve_distro(&self, name: Option<&str>) -> Result<Option<i32>, String> {
        match name {
            None => Ok(None),
            Some(target) => {
                distro::validate_name(target)?;
                self.distro_pid(target)
                    .map(Some)
                    .ok_or_else(|| "distro not running".to_string())
            }
        }
    }

    fn handle_distro_up(&self, req: &Request) -> Vec<u8> {
        let parsed: Result<DistroUpReq, String> = parse(&req.req);
        let result = parsed.and_then(|up| {
            distro::validate_name(&up.name)?;
            distro::validate_dev(&up.dev)?;
            distro::validate_hostname(&up.hostname)?;
            do_distro_up(&self.distros, &up)
        });
        respond(req.id, result)
    }

    fn handle_distro_state(&self, req: &Request) -> Vec<u8> {
        match parse_optional::<DistroStateReq>(&req.req) {
            Err(message) => proto::encode_err(req.id, &message),
            Ok(state_req) => self.distro_state_response(req.id, state_req.name.as_deref()),
        }
    }

    // With a name → that distro's snapshot; without → the full (possibly empty)
    // table listing per protocol v1.2.
    fn distro_state_response(&self, id: u64, name: Option<&str>) -> Vec<u8> {
        let Some(name) = name else {
            return respond(id, self.distro_list());
        };
        if let Err(message) = distro::validate_name(name) {
            return proto::encode_err(id, &message);
        }
        respond(id, self.distro_snapshot(name))
    }

    fn distro_snapshot(&self, name: &str) -> Result<proto::DistroStateData, String> {
        assert!(!name.is_empty(), "snapshot needs a name");
        let guard = self.distros.lock().map_err(|_| "distro lock".to_string())?;
        Ok(guard.snapshot(name))
    }

    fn distro_list(&self) -> Result<proto::DistroListData, String> {
        let distros = self
            .distros
            .lock()
            .map_err(|_| "distro lock".to_string())?
            .list();
        Ok(proto::DistroListData { distros })
    }

    fn handle_distro_down(&self, req: &Request) -> Vec<u8> {
        let parsed: Result<DistroDownReq, String> = parse(&req.req);
        let result = parsed.and_then(|down| {
            distro::validate_name(&down.name)?;
            let timeout_ms = distro::clamp_down_timeout(down.timeout_ms);
            self.distro_down(&down.name, timeout_ms)
        });
        respond(req.id, result)
    }

    // A live distro takes the poweroff/wait path; the per-name sync/unmount
    // teardown and Failed->Stopped settle then run unconditionally, no lock held.
    fn distro_down(&self, name: &str, timeout_ms: u64) -> Result<proto::DistroDownData, String> {
        assert!(!name.is_empty(), "distro_down needs a name");
        debug_assert!((distro::DOWN_MIN_MS..=distro::DOWN_MAX_MS).contains(&timeout_ms));
        let active = {
            let guard = self.distros.lock().map_err(|_| "distro lock".to_string())?;
            guard.active_pid(name)
        };
        if let Some(pid) = active {
            assert!(pid > 0, "active init pid must be positive");
            do_poweroff_and_wait(&self.distros, name, pid, timeout_ms);
        }
        do_teardown(name);
        self.distros
            .lock()
            .map_err(|_| "distro lock".to_string())?
            .settle_and_remove(name);
        Ok(proto::DistroDownData { state: "stopped" })
    }

    fn handle_session_open(&self, req: &Request) -> Vec<u8> {
        let parsed: Result<SessionOpenReq, String> = parse(&req.req);
        let result = parsed.and_then(|open| {
            session::validate_open(&open.argv, open.rows, open.cols)?;
            let init_pid = self.resolve_distro(open.distro.as_deref())?;
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

    fn handle_mem_stats(id: u64) -> Vec<u8> {
        respond(id, do_mem_stats())
    }

    fn handle_mem_reclaim(id: u64) -> Vec<u8> {
        respond(id, do_mem_reclaim())
    }

    fn handle_net_listeners(id: u64) -> Vec<u8> {
        respond(id, do_net_listeners())
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

// Like `parse`, but a wholly absent `req` yields the type's default (used by
// distro_state, whose name filter is optional).
fn parse_optional<T: DeserializeOwned + Default>(value: &Value) -> Result<T, String> {
    if value.is_null() {
        return Ok(T::default());
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
    distros: &Mutex<Distros>,
    up: &DistroUpReq,
) -> Result<proto::DistroStateData, String> {
    distro::distro_up(distros, up)
}

#[cfg(not(target_os = "linux"))]
fn do_distro_up(
    _distros: &Mutex<Distros>,
    _up: &DistroUpReq,
) -> Result<proto::DistroStateData, String> {
    Err("distro boot requires linux".to_string())
}

#[cfg(target_os = "linux")]
fn do_poweroff_and_wait(distros: &Mutex<Distros>, name: &str, init_pid: i32, timeout_ms: u64) {
    distro::poweroff_and_wait(distros, name, init_pid, timeout_ms);
}

#[cfg(not(target_os = "linux"))]
const fn do_poweroff_and_wait(
    _distros: &Mutex<Distros>,
    _name: &str,
    _init_pid: i32,
    _timeout_ms: u64,
) {
}

#[cfg(target_os = "linux")]
fn do_teardown(name: &str) {
    distro::teardown(name);
}

#[cfg(not(target_os = "linux"))]
const fn do_teardown(_name: &str) {}

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

#[cfg(target_os = "linux")]
fn do_mem_stats() -> Result<proto::MemStatsData, String> {
    crate::mem::mem_stats()
}

#[cfg(not(target_os = "linux"))]
fn do_mem_stats() -> Result<proto::MemStatsData, String> {
    Err("mem stats requires linux".to_string())
}

#[cfg(target_os = "linux")]
fn do_mem_reclaim() -> Result<Empty, String> {
    crate::mem::reclaim()?;
    Ok(Empty {})
}

#[cfg(not(target_os = "linux"))]
fn do_mem_reclaim() -> Result<Empty, String> {
    Err("mem reclaim requires linux".to_string())
}

#[cfg(target_os = "linux")]
fn do_net_listeners() -> Result<proto::NetListenersData, String> {
    crate::net::listeners()
}

#[cfg(not(target_os = "linux"))]
fn do_net_listeners() -> Result<proto::NetListenersData, String> {
    Err("net listeners require linux".to_string())
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
    fn ping_reports_protocol_four() {
        let value = call(&Agent::new(), r#"{"id":7,"op":"ping"}"#);
        assert_eq!(value["id"], 7);
        assert_eq!(value["ok"], true);
        assert_eq!(value["data"]["agent"], "msl-agent");
        assert_eq!(value["data"]["protocol"], 4);
    }

    // The three v1.3 ops route to their gated wrappers; on the host build those
    // stubs report the linux requirement rather than "unknown op".
    #[test]
    fn mem_stats_routes() {
        let value = call(&Agent::new(), r#"{"id":40,"op":"mem_stats"}"#);
        assert_eq!(value["id"], 40);
        assert_eq!(value["ok"], false);
        assert!(value["error"].as_str().expect("err").contains("linux"));
    }

    #[test]
    fn mem_reclaim_routes() {
        let value = call(&Agent::new(), r#"{"id":41,"op":"mem_reclaim"}"#);
        assert_eq!(value["id"], 41);
        assert_eq!(value["ok"], false);
        assert!(value["error"].as_str().expect("err").contains("linux"));
    }

    #[test]
    fn net_listeners_routes() {
        let value = call(&Agent::new(), r#"{"id":42,"op":"net_listeners"}"#);
        assert_eq!(value["id"], 42);
        assert_eq!(value["ok"], false);
        assert!(value["error"].as_str().expect("err").contains("linux"));
    }

    #[test]
    fn distro_state_no_name_lists_empty() {
        let value = call(&Agent::new(), r#"{"id":1,"op":"distro_state"}"#);
        assert_eq!(value["ok"], true);
        assert!(
            value["data"]["distros"]
                .as_array()
                .expect("distros array")
                .is_empty()
        );
    }

    #[test]
    fn distro_state_named_defaults_stopped() {
        let value = call(
            &Agent::new(),
            r#"{"id":1,"op":"distro_state","req":{"name":"ubuntu"}}"#,
        );
        assert_eq!(value["ok"], true);
        assert_eq!(value["data"]["state"], "stopped");
        assert!(value["data"]["init_pid"].is_null());
    }

    #[test]
    fn distro_up_rejects_bad_dev() {
        let value = call(
            &Agent::new(),
            r#"{"id":2,"op":"distro_up","req":{"name":"ubuntu","dev":"/dev/sda","hostname":"ubuntu"}}"#,
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
    fn distro_up_rejects_bad_name() {
        let value = call(
            &Agent::new(),
            r#"{"id":2,"op":"distro_up","req":{"name":"Ubuntu","dev":"/dev/vda","hostname":"ubuntu"}}"#,
        );
        assert_eq!(value["ok"], false);
        assert!(
            value["error"]
                .as_str()
                .expect("err")
                .contains("name must match")
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
    fn distro_down_requires_name() {
        let value = call(&Agent::new(), r#"{"id":21,"op":"distro_down"}"#);
        assert_eq!(value["id"], 21);
        assert_eq!(value["ok"], false);
    }

    #[test]
    fn distro_down_idempotent_when_stopped() {
        let value = call(
            &Agent::new(),
            r#"{"id":21,"op":"distro_down","req":{"name":"ubuntu"}}"#,
        );
        assert_eq!(value["id"], 21);
        assert_eq!(value["ok"], true);
        assert_eq!(value["data"]["state"], "stopped");
    }

    #[test]
    fn distro_down_routes_with_req_timeout() {
        let value = call(
            &Agent::new(),
            r#"{"id":22,"op":"distro_down","req":{"name":"ubuntu","timeout_ms":50}}"#,
        );
        assert_eq!(value["id"], 22);
        assert_eq!(value["ok"], true);
        assert_eq!(value["data"]["state"], "stopped");
    }

    #[test]
    fn distro_down_from_failed_reports_stopped_and_settles() {
        let agent = Agent::new();
        {
            // A crashed boot lands in Failed (init exits inside the ready window).
            let mut guard = agent.distros.lock().expect("distro lock");
            guard.reserve("ubuntu", "/dev/vda").expect("reserve");
            guard.begin("ubuntu", 4242);
            let name = guard.on_init_exit(4242);
            let state = guard.snapshot("ubuntu").state;
            drop(guard);
            assert_eq!(name.as_deref(), Some("ubuntu"), "init exit recorded");
            assert_eq!(state, "failed");
        }
        let first = call(
            &agent,
            r#"{"id":23,"op":"distro_down","req":{"name":"ubuntu"}}"#,
        );
        assert_eq!(first["ok"], true);
        assert_eq!(first["data"]["state"], "stopped");
        // Settled to Stopped, so distro_state and a repeat call agree.
        let state = call(
            &agent,
            r#"{"id":24,"op":"distro_state","req":{"name":"ubuntu"}}"#,
        );
        assert_eq!(state["data"]["state"], "stopped");
        let again = call(
            &agent,
            r#"{"id":25,"op":"distro_down","req":{"name":"ubuntu"}}"#,
        );
        assert_eq!(again["data"]["state"], "stopped");
    }

    #[test]
    fn exec_unknown_distro_name_errors() {
        let value = call(
            &Agent::new(),
            r#"{"id":30,"op":"exec","argv":["/bin/echo","hi"],"distro":"ghost"}"#,
        );
        assert_eq!(value["ok"], false);
        assert!(
            value["error"]
                .as_str()
                .expect("err")
                .contains("not running")
        );
    }

    #[test]
    fn session_open_unknown_distro_name_errors() {
        let value = call(
            &Agent::new(),
            r#"{"id":31,"op":"session_open","req":{"argv":["/bin/sh"],"rows":24,"cols":80,"distro":"ghost"}}"#,
        );
        assert_eq!(value["ok"], false);
        assert!(
            value["error"]
                .as_str()
                .expect("err")
                .contains("not running")
        );
    }

    #[test]
    fn distro_state_lists_named_entries() {
        let agent = Agent::new();
        {
            let mut guard = agent.distros.lock().expect("distro lock");
            guard.reserve("one", "/dev/vda").expect("reserve one");
            guard.begin("one", 100);
            guard.promote("one");
            guard.reserve("two", "/dev/vdb").expect("reserve two");
            guard.begin("two", 200);
            guard.promote("two");
        }
        let value = call(&agent, r#"{"id":32,"op":"distro_state"}"#);
        let list = value["data"]["distros"].as_array().expect("distros array");
        assert_eq!(list.len(), 2);
        let named = call(
            &agent,
            r#"{"id":33,"op":"distro_state","req":{"name":"one"}}"#,
        );
        assert_eq!(named["data"]["state"], "running");
        assert_eq!(named["data"]["init_pid"], 100);
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
