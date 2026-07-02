//! Wire types for the M0 protocol: the request read from the host and the
//! response envelopes written back, plus their JSON (de)serialization.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

pub const AGENT_NAME: &str = "msl-agent";
pub const AGENT_VERSION: &str = "0.0.1";
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
}

#[derive(Debug, Serialize)]
pub struct PingData {
    pub agent: &'static str,
    pub version: &'static str,
    pub kernel: String,
}

#[derive(Debug, Serialize)]
pub struct ExecData {
    pub exit_code: i32,
    pub stdout: String,
    pub stderr: String,
    pub truncated: bool,
}

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
