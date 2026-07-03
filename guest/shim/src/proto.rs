//! Pure `mac_exec` v1 wire helpers (ADR 0008 / docs/specs/m3a-protocol.md):
//! the hello object, the tagged-frame constants, and the small parsers. No I/O
//! lives here so the host build can unit-test the wire shapes directly.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

pub const PROTO_V: u32 = 1;
pub const MAX_ARGV: usize = 1024;
pub const DATA_MAX: usize = 64 * 1024;

pub const TAG_STDIN: u8 = 0;
pub const TAG_STDOUT: u8 = 1;
pub const TAG_STDERR: u8 = 2;
pub const TAG_EXIT: u8 = 3;
pub const TAG_WINCH: u8 = 4;
pub const TAG_STDIN_EOF: u8 = 5;

#[derive(Serialize)]
pub struct Hello {
    pub v: u32,
    pub op: &'static str,
    pub argv: Vec<String>,
    pub cwd: String,
    pub env: BTreeMap<String, String>,
    pub tty: bool,
    pub rows: u16,
    pub cols: u16,
}

#[derive(Deserialize)]
pub struct Reply {
    pub ok: bool,
    #[serde(default)]
    pub error: Option<String>,
}

#[derive(Deserialize)]
struct ExitMsg {
    code: i32,
}

#[derive(Serialize)]
struct WinchMsg {
    rows: u16,
    cols: u16,
}

// argv is the command plus its arguments: non-empty, at most MAX_ARGV entries.
pub fn validate_argv(argv: &[String]) -> Result<(), &'static str> {
    if argv.is_empty() {
        return Err("empty command");
    }
    if argv.len() > MAX_ARGV {
        return Err("too many arguments");
    }
    debug_assert!(!argv.is_empty() && argv.len() <= MAX_ARGV);
    Ok(())
}

pub fn build_hello(
    argv: Vec<String>,
    cwd: String,
    term: Option<String>,
    tty: bool,
    rows: u16,
    cols: u16,
) -> Hello {
    assert!(!argv.is_empty(), "hello needs a command");
    assert!(
        tty || (rows == 0 && cols == 0),
        "non-tty must send zero size"
    );
    let mut env = BTreeMap::new();
    if let Some(value) = term {
        env.insert("TERM".to_string(), value);
    }
    Hello {
        v: PROTO_V,
        op: "mac_exec",
        argv,
        cwd,
        env,
        tty,
        rows,
        cols,
    }
}

pub fn hello_bytes(hello: &Hello) -> Result<Vec<u8>, serde_json::Error> {
    assert_eq!(hello.v, PROTO_V, "hello version must be v1");
    assert!(!hello.argv.is_empty(), "hello argv must be non-empty");
    serde_json::to_vec(hello)
}

pub fn parse_reply(payload: &[u8]) -> Result<Reply, serde_json::Error> {
    debug_assert!(!payload.is_empty(), "reply frame should carry JSON");
    serde_json::from_slice::<Reply>(payload)
}

// Decode a tag-3 exit frame's `{"code":N}` body; None on malformed JSON.
#[must_use]
pub fn parse_exit_code(data: &[u8]) -> Option<i32> {
    let msg = serde_json::from_slice::<ExitMsg>(data).ok()?;
    debug_assert!((-1..=255).contains(&msg.code) || msg.code >= 128);
    Some(msg.code)
}

// Prefix a data payload with its channel tag byte (the on-wire frame body).
#[must_use]
pub fn frame_with_tag(tag: u8, data: &[u8]) -> Vec<u8> {
    assert!(data.len() <= DATA_MAX, "data frame exceeds 64 KiB");
    let mut framed = Vec::with_capacity(data.len() + 1);
    framed.push(tag);
    framed.extend_from_slice(data);
    debug_assert_eq!(framed.len(), data.len() + 1);
    framed
}

#[must_use]
pub fn winch_json(rows: u16, cols: u16) -> Vec<u8> {
    let msg = WinchMsg { rows, cols };
    let bytes = serde_json::to_vec(&msg).unwrap_or_default();
    debug_assert!(!bytes.is_empty(), "winch JSON should serialize");
    bytes
}

#[cfg(test)]
mod tests {
    use super::{
        DATA_MAX, MAX_ARGV, PROTO_V, TAG_EXIT, TAG_STDERR, TAG_STDIN, TAG_STDIN_EOF, TAG_STDOUT,
        TAG_WINCH, build_hello, frame_with_tag, hello_bytes, parse_exit_code, validate_argv,
    };
    use serde_json::Value;

    fn args(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| (*s).to_string()).collect()
    }

    #[test]
    fn tag_constants_match_protocol() {
        assert_eq!(
            [
                TAG_STDIN,
                TAG_STDOUT,
                TAG_STDERR,
                TAG_EXIT,
                TAG_WINCH,
                TAG_STDIN_EOF
            ],
            [0, 1, 2, 3, 4, 5]
        );
    }

    #[test]
    fn hello_carries_mac_exec_shape() {
        let hello = build_hello(
            args(&["open", "."]),
            "/mnt/mac/Dev".to_string(),
            Some("xterm-256color".to_string()),
            true,
            40,
            120,
        );
        let bytes = hello_bytes(&hello).expect("serialize");
        let value: Value = serde_json::from_slice(&bytes).expect("json");
        assert_eq!(value["v"], PROTO_V);
        assert_eq!(value["op"], "mac_exec");
        assert_eq!(value["argv"][0], "open");
        assert_eq!(value["cwd"], "/mnt/mac/Dev");
        assert_eq!(value["env"]["TERM"], "xterm-256color");
        assert_eq!(value["tty"], true);
        assert_eq!(value["rows"], 40);
        assert_eq!(value["cols"], 120);
    }

    #[test]
    fn non_tty_hello_omits_term_when_unset() {
        let hello = build_hello(args(&["ls"]), "/".to_string(), None, false, 0, 0);
        let bytes = hello_bytes(&hello).expect("serialize");
        let value: Value = serde_json::from_slice(&bytes).expect("json");
        assert_eq!(value["tty"], false);
        assert!(value["env"].as_object().expect("env object").is_empty());
    }

    #[test]
    fn exit_code_round_trips() {
        assert_eq!(parse_exit_code(br#"{"code":0}"#), Some(0));
        assert_eq!(parse_exit_code(br#"{"code":137}"#), Some(137));
        assert_eq!(parse_exit_code(b"not json"), None);
        assert_eq!(parse_exit_code(b"{}"), None);
    }

    #[test]
    fn argv_bounds_enforced() {
        assert!(validate_argv(&args(&["ls"])).is_ok());
        assert!(validate_argv(&[]).is_err());
        let many: Vec<String> = (0..=MAX_ARGV).map(|i| i.to_string()).collect();
        assert!(validate_argv(&many).is_err());
    }

    #[test]
    fn frame_prefixes_tag_byte() {
        let framed = frame_with_tag(TAG_STDIN, b"hi");
        assert_eq!(framed, vec![0, b'h', b'i']);
        assert_eq!(frame_with_tag(TAG_STDIN_EOF, b""), vec![5]);
        let big = vec![0u8; DATA_MAX];
        assert_eq!(frame_with_tag(TAG_STDOUT, &big).len(), DATA_MAX + 1);
    }
}
