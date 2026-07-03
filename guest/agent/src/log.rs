//! Agent event log: a bounded in-memory ring plus an optional connected reader
//! on vsock port 5002. `log` also mirrors to /dev/console and never blocks the
//! caller — a laggy or full reader is dropped rather than waited on.

use std::collections::VecDeque;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;

pub const RING_CAP: usize = 256;
const MAX_MSG: usize = 8 * 1024;

#[derive(Clone, Copy)]
pub enum Level {
    Info,
    Warn,
    Error,
}

impl Level {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Info => "info",
            Self::Warn => "warn",
            Self::Error => "error",
        }
    }
}

#[derive(Serialize)]
struct Event<'a> {
    ts_ms: u64,
    level: &'static str,
    msg: &'a str,
}

static RING: Mutex<VecDeque<Vec<u8>>> = Mutex::new(VecDeque::new());
static READER: Mutex<Option<Box<dyn std::io::Write + Send>>> = Mutex::new(None);

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}

// Keep a single log event far below the 4 MiB frame bound by capping the
// message on a UTF-8 boundary before serialization.
fn cap_msg(msg: &str) -> &str {
    if msg.len() <= MAX_MSG {
        return msg;
    }
    let mut end = MAX_MSG;
    // bounded: at most 3 steps back to the nearest char boundary
    while end > 0 && !msg.is_char_boundary(end) {
        end -= 1;
    }
    &msg[..end]
}

fn encode(level: Level, msg: &str) -> Vec<u8> {
    let event = Event {
        ts_ms: now_ms(),
        level: level.as_str(),
        msg: cap_msg(msg),
    };
    serde_json::to_vec(&event)
        .unwrap_or_else(|_| b"{\"level\":\"error\",\"msg\":\"encode\"}".to_vec())
}

pub fn log(level: Level, msg: &str) {
    debug_assert!(!msg.is_empty());
    let frame = encode(level, msg);
    debug_assert!(!frame.is_empty());
    console(msg);
    push_ring(&frame);
    push_reader(&frame);
}

pub fn info(msg: &str) {
    log(Level::Info, msg);
}

pub fn warn(msg: &str) {
    log(Level::Warn, msg);
}

pub fn error(msg: &str) {
    log(Level::Error, msg);
}

fn push_ring(frame: &[u8]) {
    debug_assert!(
        frame.len() < crate::frame::MAX_FRAME,
        "log event must fit a frame"
    );
    let Ok(mut ring) = RING.lock() else {
        return;
    };
    debug_assert!(ring.len() <= RING_CAP);
    // bounded eviction: keep at most RING_CAP events
    while ring.len() >= RING_CAP {
        let _ = ring.pop_front();
    }
    ring.push_back(frame.to_vec());
}

fn push_reader(frame: &[u8]) {
    let Ok(mut guard) = READER.lock() else {
        return;
    };
    let Some(writer) = guard.as_mut() else {
        return;
    };
    if crate::frame::write_frame(writer, frame).is_err() {
        *guard = None;
    }
}

pub fn attach_reader(mut writer: Box<dyn std::io::Write + Send>) {
    let backlog: Vec<Vec<u8>> = RING
        .lock()
        .map(|r| r.iter().cloned().collect())
        .unwrap_or_default();
    // bounded replay: the ring holds at most RING_CAP events
    for frame in &backlog {
        if crate::frame::write_frame(&mut writer, frame).is_err() {
            return;
        }
    }
    if let Ok(mut guard) = READER.lock() {
        *guard = Some(writer);
    }
}

#[cfg(target_os = "linux")]
fn console(msg: &str) {
    use std::io::Write;
    if let Ok(mut file) = std::fs::OpenOptions::new().write(true).open("/dev/console") {
        let _ = writeln!(file, "msl-agent: {msg}");
    }
}

#[cfg(not(target_os = "linux"))]
const fn console(_msg: &str) {}

#[cfg(test)]
mod tests {
    use super::{Level, RING, RING_CAP, encode, log};

    #[test]
    fn encode_is_valid_json_event() {
        let bytes = encode(Level::Warn, "hello");
        let value: serde_json::Value = serde_json::from_slice(&bytes).expect("json");
        assert_eq!(value["level"], "warn");
        assert_eq!(value["msg"], "hello");
        assert!(value["ts_ms"].is_u64());
    }

    #[test]
    fn ring_is_bounded() {
        for i in 0..(RING_CAP + 50) {
            log(Level::Info, &format!("event {i}"));
        }
        let len = RING.lock().expect("ring lock").len();
        assert!(len <= RING_CAP, "ring must stay bounded: {len}");
    }
}
