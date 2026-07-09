//! Wire types for the agent control protocol: the request read from the host and the
//! response envelopes written back, plus their JSON (de)serialization.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const AGENT_NAME: &str = "msl-agent";
pub const AGENT_VERSION: &str = "0.0.1";
pub const PROTOCOL_VERSION: u32 = 5;
pub const DEFAULT_TIMEOUT_MS: u64 = 30_000;

#[derive(Debug, Deserialize)]
pub struct Request {
    pub id: u64,
    pub op: String,
    #[serde(default)]
    pub argv: Vec<String>,
    #[serde(default)]
    pub env: HashMap<String, String>,
    pub timeout_ms: Option<u64>,
    // v1.2: `distro` is the target distro name (absent/null = agent context).
    #[serde(default)]
    pub distro: Option<String>,
    pub cwd: Option<String>,
    #[serde(default)]
    pub req: Value,
}

#[derive(Debug, Deserialize)]
pub struct DistroUpReq {
    pub name: String,
    pub dev: String,
    pub hostname: String,
    #[serde(default)]
    pub mac_share: bool,
    #[serde(default)]
    pub rosetta: bool,
}

#[derive(Debug, Default, Deserialize)]
pub struct DistroStateReq {
    #[serde(default)]
    pub name: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct SessionOpenReq {
    pub argv: Vec<String>,
    pub cwd: Option<String>,
    #[serde(default)]
    pub env: HashMap<String, String>,
    pub rows: u16,
    pub cols: u16,
    // v1.2: target distro name (absent/null = agent context).
    #[serde(default)]
    pub distro: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct SessionRefReq {
    pub session_id: u64,
}

#[derive(Debug, Deserialize)]
pub struct SessionResizeReq {
    pub session_id: u64,
    pub rows: u16,
    pub cols: u16,
}

#[derive(Debug, Deserialize)]
pub struct SessionSignalReq {
    pub session_id: u64,
    pub signal: i32,
}

#[derive(Debug, Deserialize)]
pub struct SetTimeReq {
    pub sec: i64,
    pub usec: i64,
}

#[derive(Debug, Deserialize)]
pub struct MkfsReq {
    pub dev: String,
}

#[derive(Debug, Deserialize)]
pub struct DistroDownReq {
    pub name: String,
    pub timeout_ms: Option<u64>,
}

#[derive(Debug, Deserialize)]
pub struct GuiRuntimeReq {
    pub distro: String,
    #[serde(default)]
    pub user: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct GuiLaunchReq {
    pub distro: String,
    #[serde(default)]
    pub user: Option<String>,
    pub argv: Vec<String>,
    #[serde(default)]
    pub env: HashMap<String, String>,
    #[serde(default)]
    pub cwd: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct DataHello {
    pub session_id: u64,
    pub token: String,
}

#[derive(Debug, Deserialize)]
pub struct ForwardHello {
    pub port: u16,
}

// Daemon's first frame on the fs-service port (5030): names the distro whose
// mount namespace the msl-fsd worker serves. Routing only, never a secret — the
// daemon already authenticated the appex and consumed the mount nonce.
#[derive(Debug, Deserialize)]
pub struct FsOpenHello {
    #[serde(default)]
    pub v: u32,
    pub op: String,
    pub distro: String,
    #[serde(default = "default_true")]
    pub readonly: bool,
}

const fn default_true() -> bool {
    true
}

#[derive(Debug, Serialize)]
pub struct PingData {
    pub agent: &'static str,
    pub version: &'static str,
    pub protocol: u32,
    pub kernel: String,
}

#[derive(Debug, Serialize)]
pub struct ExecData {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
    pub truncated: bool,
}

#[derive(Debug, Serialize)]
pub struct DistroStateData {
    pub state: &'static str,
    pub init_pid: Option<u32>,
}

#[derive(Debug, Serialize)]
pub struct DistroListEntry {
    pub name: String,
    pub state: &'static str,
    pub init_pid: Option<u32>,
}

#[derive(Debug, Serialize)]
pub struct DistroListData {
    pub distros: Vec<DistroListEntry>,
}

#[derive(Debug, Serialize)]
pub struct DistroDownData {
    pub state: &'static str,
}

#[derive(Debug, Serialize)]
pub struct SessionOpenData {
    pub session_id: u64,
    pub token: String,
}

#[derive(Debug, Serialize)]
pub struct SessionWaitData {
    pub done: bool,
    pub exit_code: Option<i32>,
}

#[derive(Debug, Serialize)]
pub struct MemStatsData {
    pub mem_total_kib: u64,
    pub mem_available_kib: u64,
    pub swap_total_kib: u64,
    pub swap_free_kib: u64,
    pub psi_some_avg10: f64,
    pub psi_full_avg10: f64,
}

#[derive(Debug, Serialize)]
pub struct NetListenersData {
    pub ports: Vec<u16>,
}

#[derive(Debug, Serialize)]
pub struct Empty {}

#[derive(Serialize)]
struct OkEnvelope<'a, T> {
    id: u64,
    ok: bool,
    data: &'a T,
}

#[derive(Serialize)]
struct ErrEnvelope<'a> {
    id: u64,
    ok: bool,
    error: &'a str,
}

pub fn parse_request(payload: &[u8]) -> Result<Request, String> {
    if payload.is_empty() {
        return Err("empty request payload".to_string());
    }
    debug_assert!(payload.len() <= crate::frame::MAX_FRAME);
    serde_json::from_slice::<Request>(payload).map_err(|e| format!("bad request: {e}"))
}

pub fn encode_ok<T: Serialize>(id: u64, data: &T) -> Result<Vec<u8>, String> {
    let envelope = OkEnvelope { id, ok: true, data };
    serde_json::to_vec(&envelope).map_err(|e| format!("encode failed: {e}"))
}

pub fn encode_err(id: u64, message: &str) -> Vec<u8> {
    debug_assert!(!message.is_empty());
    let envelope = ErrEnvelope {
        id,
        ok: false,
        error: message,
    };
    serde_json::to_vec(&envelope)
        .unwrap_or_else(|_| br#"{"id":0,"ok":false,"error":"encode failed"}"#.to_vec())
}

#[cfg(test)]
mod tests {
    use super::FsOpenHello;

    #[test]
    fn fs_open_hello_parses_daemon_frame() {
        let hello: FsOpenHello =
            serde_json::from_slice(br#"{"v":2,"op":"fs_open","distro":"ubuntu","readonly":true}"#)
                .expect("valid fs_open frame");
        assert_eq!(hello.v, 2);
        assert_eq!(hello.op, "fs_open");
        assert_eq!(hello.distro, "ubuntu");
        assert!(hello.readonly);
    }

    #[test]
    fn fs_open_hello_defaults_missing_version_to_zero() {
        // A frame without `v` parses (default 0) so the handler can reject it as a
        // version mismatch rather than a malformed frame.
        let hello: FsOpenHello =
            serde_json::from_slice(br#"{"op":"fs_open","distro":"ubuntu"}"#).expect("parses");
        assert_eq!(hello.v, 0);
        assert!(hello.readonly);
    }

    #[test]
    fn fs_open_hello_requires_distro() {
        let err = serde_json::from_slice::<FsOpenHello>(br#"{"v":2,"op":"fs_open"}"#);
        assert!(err.is_err(), "missing distro must fail to parse");
    }
}
