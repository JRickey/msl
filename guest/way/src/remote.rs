//! Surface protocol v5 wire codecs (docs/specs/m4-gui-protocol.md).
//!
//! Little-endian `type|flags|len|payload` framing, JSON control payloads, and
//! the binary `commit` layout. Transport-agnostic: a `Read`/`Write` pair is all
//! the codec needs, so the whole module is unit-testable off-VM.

use std::io::{self, Read, Write};

use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u32 = 5;
pub const MAX_FRAME: usize = 64 * 1024 * 1024;

pub const T_HELLO: u32 = 1;
pub const T_WIN_NEW: u32 = 3;
pub const T_WIN_MAP: u32 = 5;
pub const T_WIN_UNMAP: u32 = 7;
pub const T_WIN_DESTROY: u32 = 9;
pub const T_WIN_TITLE: u32 = 11;
pub const T_COMMIT: u32 = 13;
pub const T_CURSOR_NAMED: u32 = 15;
pub const T_WIN_LIMITS: u32 = 19;
pub const T_STATS: u32 = 17;
pub const T_POPUP_NEW: u32 = 21;
pub const T_POPUP_MOVED: u32 = 23;
pub const T_SEL_OFFER: u32 = 25;
pub const T_TEXT_INPUT_STATE: u32 = 27;
pub const T_CURSOR_IMAGE: u32 = 29;
pub const T_ERROR_G2H: u32 = 31;
pub const T_SEL_DATA_G2H: u32 = 33;
pub const T_SEL_READ_G2H: u32 = 35;

pub const T_HELLO_ACK: u32 = 2;
pub const T_CONFIGURE: u32 = 4;
pub const T_CLOSE: u32 = 6;
pub const T_POINTER: u32 = 8;
pub const T_KEY: u32 = 10;
pub const T_PRESENT_ACK: u32 = 12;
pub const T_STATS_REQ: u32 = 14;
pub const T_POPUP_DISMISS: u32 = 16;
pub const T_HOST_SEL: u32 = 26;
pub const T_TEXT_INPUT_APPLY: u32 = 28;
pub const T_SET_LAYOUT: u32 = 30;
pub const T_ERROR_H2G: u32 = 32;
pub const T_SEL_READ_H2G: u32 = 34;
pub const T_SEL_DATA_H2G: u32 = 36;

/// Clipboard MIME allowlist shared by both selection-offer decoders; a MIME
/// outside this set is rejected before any allocation.
pub const SEL_MIME_ALLOWLIST: [&str; 5] = [
    "text/plain;charset=utf-8",
    "text/plain",
    "UTF8_STRING",
    "text/uri-list",
    "image/png",
];

/// Selection-offer bounds (`docs/specs/gui-phase2.md`, protocol v5).
pub const SEL_MAX_ENTRIES: u32 = 8;
pub const SEL_MAX_MIME_LEN: u32 = 128;
pub const SEL_INLINE_MAX: u64 = 65_536;
pub const SEL_STREAM_MAX: u64 = 33_554_432;
pub const SEL_FLAG_INLINE: u32 = 1;
const SEL_PREFIX_LEN: usize = 24;
const SEL_DESC_LEN: usize = 8;

/// Selection-chunk bounds; `flags` bit 0 marks the final chunk.
pub const SEL_CHUNK_MAX: u32 = 262_144;
pub const SEL_FLAG_FINAL: u32 = 1;
const SEL_CHUNK_PREFIX_LEN: usize = 16;

/// Cursor-image bounds; pixels are ARGB8888-premultiplied like [`FMT_ARGB8888`].
pub const CURSOR_MIN_DIM: u32 = 1;
pub const CURSOR_MAX_DIM: u32 = 512;
const CURSOR_PREFIX_LEN: usize = 24;

/// Decoder ceilings for untrusted guest strings and sanitized error reasons.
pub const WIN_STR_MAX: usize = 512;
pub const ERR_REASON_MAX: usize = 256;
pub const TEXT_FIELD_MAX: usize = 4096;
pub const HELLO_OUTPUT_MAX: u32 = 16_384;
const LAYOUT_NAME_MAX: usize = 64;

/// `cursor_rect` bounds the codec can enforce without window dimensions:
/// coordinates in `[-COORD_MAX, COORD_MAX]`, dimensions in `[1, DIM_MAX]`.
const TEXT_RECT_COORD_MAX: i32 = 16_384;
const TEXT_RECT_DIM_MAX: u32 = 16_384;

pub const FMT_XRGB8888: u32 = 0;
pub const FMT_ARGB8888: u32 = 1;

/// Host-enforced ceiling on a commit's damage-rect count (surface protocol v0);
/// the guest coalesces to a single full-surface rect rather than exceed it.
pub const MAX_COMMIT_RECTS: u32 = 4096;

const HDR_LEN: usize = 16;
const COMMIT_FIXED_LEN: usize = 8 * 4 + 2 * 4 + 2 * 8;
const RECT_LEN: usize = 4 * 4;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub msg_type: u32,
    pub flags: u32,
    pub payload: Vec<u8>,
}

/// A guest→host message queued by a Wayland handler for the event loop to flush
/// once the current dispatch settles.
#[derive(Debug, Clone)]
pub struct OutFrame {
    pub msg_type: u32,
    pub payload: Vec<u8>,
}

pub fn read_frame<R: Read>(reader: &mut R) -> io::Result<Frame> {
    let mut hdr = [0u8; HDR_LEN];
    reader.read_exact(&mut hdr)?;
    let msg_type = u32::from_le_bytes([hdr[0], hdr[1], hdr[2], hdr[3]]);
    let flags = u32::from_le_bytes([hdr[4], hdr[5], hdr[6], hdr[7]]);
    let len = u64::from_le_bytes([
        hdr[8], hdr[9], hdr[10], hdr[11], hdr[12], hdr[13], hdr[14], hdr[15],
    ]);
    let len = usize::try_from(len)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "frame length overflow"))?;
    if len > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame exceeds 64 MiB bound",
        ));
    }
    let mut payload = Vec::new();
    payload
        .try_reserve_exact(len)
        .map_err(|_| io::Error::new(io::ErrorKind::OutOfMemory, "frame allocation failed"))?;
    payload.resize(len, 0);
    reader.read_exact(&mut payload)?;
    debug_assert_eq!(payload.len(), len);
    Ok(Frame {
        msg_type,
        flags,
        payload,
    })
}

pub fn write_frame<W: Write>(writer: &mut W, msg_type: u32, payload: &[u8]) -> io::Result<()> {
    debug_assert!(msg_type != 0, "message type 0 is reserved");
    if payload.len() > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame exceeds 64 MiB bound",
        ));
    }
    let len = u64::try_from(payload.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "length overflow"))?;
    let mut hdr = [0u8; HDR_LEN];
    hdr[0..4].copy_from_slice(&msg_type.to_le_bytes());
    hdr[8..16].copy_from_slice(&len.to_le_bytes());
    writer.write_all(&hdr)?;
    writer.write_all(payload)?;
    Ok(())
}

pub fn write_json<W: Write, T: Serialize>(
    writer: &mut W,
    msg_type: u32,
    value: &T,
) -> io::Result<()> {
    let bytes = serde_json::to_vec(value)?;
    debug_assert!(!bytes.is_empty(), "serialized control payload is empty");
    write_frame(writer, msg_type, &bytes)
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Hello {
    pub version: u32,
    pub distro: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WinNew {
    pub win: u32,
    pub app_id: String,
    pub title: String,
    pub w: u32,
    pub h: u32,
    pub scale: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WinRef {
    pub win: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WinLimits {
    pub win: u32,
    pub min_w: u32,
    pub min_h: u32,
    pub max_w: u32,
    pub max_h: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct WinTitle {
    pub win: u32,
    pub title: String,
}

/// A popup mapped as a host child panel.
///
/// `parent` is an existing win id (a toplevel or another popup); `x`/`y` are the
/// popup window-geometry origin in logical points relative to the parent's
/// geometry origin (y-down).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PopupNew {
    pub win: u32,
    pub parent: u32,
    pub x: i32,
    pub y: i32,
    pub w: u32,
    pub h: u32,
    pub scale: f64,
}

/// A live popup's parent-relative position changed (`xdg_popup.reposition`).
/// Units match [`PopupNew`].
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PopupMoved {
    pub win: u32,
    pub x: i32,
    pub y: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CursorNamed {
    pub win: u32,
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HelloAck {
    pub version: u32,
    pub scale: f64,
    /// Refresh in Hz; carried as a float so a fractional host rate (e.g. 59.94)
    /// survives the JSON round-trip that an integer field would reject.
    pub refresh_hz: f64,
    /// Adopted output size in logical pixels; absent from a within-version peer
    /// that does not propose one. Validated to `1..=16384` by [`decode_hello_ack`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_w: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_h: Option<u32>,
}

impl HelloAck {
    /// Adopted refresh as whole Hz for the integer output-mode field; the wire
    /// value keeps sub-Hz precision.
    #[must_use]
    pub fn refresh_hz_rounded(&self) -> u32 {
        let hz = self.refresh_hz.max(1.0).round().min(f64::from(u32::MAX));
        debug_assert!(hz >= 1.0, "refresh clamped to at least 1 Hz");
        // `hz` is clamped to `[1, u32::MAX]`, so this cast cannot truncate or wrap.
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        let rounded = hz as u32;
        debug_assert!(rounded >= 1, "rounded refresh stays positive");
        rounded
    }
}

/// Decode `hello_ack`, enforcing the logical-output bound when a size is present.
pub fn decode_hello_ack(bytes: &[u8]) -> io::Result<HelloAck> {
    debug_assert!(!bytes.is_empty(), "hello_ack payload cannot be empty");
    let ack: HelloAck = from_json(bytes)?;
    check_output_dim(ack.output_w)?;
    check_output_dim(ack.output_h)?;
    Ok(ack)
}

const HELLO_OUTPUT_MIN: u32 = 1;

fn check_output_dim(dim: Option<u32>) -> io::Result<()> {
    let Some(value) = dim else { return Ok(()) };
    if !(HELLO_OUTPUT_MIN..=HELLO_OUTPUT_MAX).contains(&value) {
        return Err(bad("hello_ack output dimension out of range"));
    }
    debug_assert!(value >= HELLO_OUTPUT_MIN, "value within validated range");
    Ok(())
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Configure {
    pub win: u32,
    pub w: u32,
    pub h: u32,
    pub serial: u32,
    #[serde(default)]
    pub states: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Pointer {
    pub win: u32,
    pub kind: String,
    #[serde(default)]
    pub x: f64,
    #[serde(default)]
    pub y: f64,
    #[serde(default)]
    pub button: u32,
    #[serde(default)]
    pub state: u32,
    #[serde(default)]
    pub dx: f64,
    #[serde(default)]
    pub dy: f64,
    #[serde(default)]
    pub t_host_ns: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Key {
    pub win: u32,
    pub keycode: u32,
    pub state: u32,
    #[serde(default)]
    pub t_host_ns: u64,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub struct PresentAck {
    pub win: u32,
    pub seq: u32,
    pub t_recv_ns: u64,
    pub t_present_ns: u64,
}

#[derive(Debug, Clone, PartialEq)]
pub enum HostMsg {
    HelloAck(HelloAck),
    Configure(Configure),
    Close(WinRef),
    Pointer(Pointer),
    Key(Key),
    PresentAck(PresentAck),
    StatsReq,
    PopupDismiss(WinRef),
    Unknown(u32),
}

pub fn parse_host(frame: &Frame) -> io::Result<HostMsg> {
    debug_assert!(frame.msg_type != 0, "message type 0 is reserved");
    let msg = match frame.msg_type {
        T_HELLO_ACK => HostMsg::HelloAck(decode_hello_ack(&frame.payload)?),
        T_CONFIGURE => HostMsg::Configure(from_json(&frame.payload)?),
        T_CLOSE => HostMsg::Close(from_json(&frame.payload)?),
        T_POINTER => HostMsg::Pointer(from_json(&frame.payload)?),
        T_KEY => HostMsg::Key(from_json(&frame.payload)?),
        T_PRESENT_ACK => HostMsg::PresentAck(from_json(&frame.payload)?),
        T_STATS_REQ => HostMsg::StatsReq,
        T_POPUP_DISMISS => HostMsg::PopupDismiss(from_json(&frame.payload)?),
        other => HostMsg::Unknown(other),
    };
    Ok(msg)
}

/// Deserialize a control payload, mapping serde failures to `InvalidData`.
pub fn from_json_frame<T: for<'de> Deserialize<'de>>(bytes: &[u8]) -> io::Result<T> {
    from_json(bytes)
}

fn from_json<T: for<'de> Deserialize<'de>>(bytes: &[u8]) -> io::Result<T> {
    debug_assert!(!bytes.is_empty(), "control payload cannot be empty");
    serde_json::from_slice(bytes)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("bad control json: {e}")))
}

/// Build an `InvalidData` error from a static reason string.
fn bad(reason: &'static str) -> io::Error {
    debug_assert!(!reason.is_empty(), "error reason cannot be empty");
    io::Error::new(io::ErrorKind::InvalidData, reason)
}

/// Read a little-endian `u32` at `off`, rejecting an out-of-range slice.
fn rd_u32(buf: &[u8], off: usize) -> io::Result<u32> {
    let end = off
        .checked_add(4)
        .ok_or_else(|| bad("u32 offset overflow"))?;
    if end > buf.len() {
        return Err(bad("u32 read past end of frame"));
    }
    debug_assert!(off < end, "u32 span must be non-empty");
    Ok(u32::from_le_bytes([
        buf[off],
        buf[off + 1],
        buf[off + 2],
        buf[off + 3],
    ]))
}

/// Read a little-endian `u64` at `off`, rejecting an out-of-range slice.
fn rd_u64(buf: &[u8], off: usize) -> io::Result<u64> {
    let end = off
        .checked_add(8)
        .ok_or_else(|| bad("u64 offset overflow"))?;
    if end > buf.len() {
        return Err(bad("u64 read past end of frame"));
    }
    debug_assert!(end - off == 8, "u64 span must be eight bytes");
    let mut b = [0u8; 8];
    b.copy_from_slice(&buf[off..end]);
    Ok(u64::from_le_bytes(b))
}

/// Strip control characters and truncate to `max_bytes` on a char boundary.
///
/// Guest-supplied strings are untrusted (`gui-production-contract.md`): the
/// decoder sanitizes rather than rejects so a hostile title cannot fail an
/// otherwise well-formed frame.
fn sanitize_text(input: &str, max_bytes: usize) -> String {
    debug_assert!(max_bytes > 0, "sanitize cap must be positive");
    let mut out = String::with_capacity(input.len().min(max_bytes));
    for ch in input.chars() {
        if ch.is_control() {
            continue;
        }
        if out.len() + ch.len_utf8() > max_bytes {
            break;
        }
        out.push(ch);
    }
    debug_assert!(out.len() <= max_bytes, "sanitized text within cap");
    out
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CommitMeta {
    pub win: u32,
    pub seq: u32,
    pub w: u32,
    pub h: u32,
    pub stride: u32,
    pub format: u32,
    pub scale_e12: u32,
    /// Newest host configure serial the client had acked at commit-dispatch time
    /// (0 = none). The host size-authority machine keys geometry decisions on it.
    pub serial: u32,
    pub t_client_commit_ns: u64,
    pub t_send_ns: u64,
}

/// Encode a `commit` payload.
///
/// Layout: a 56-byte fixed prefix — the eight `u32` header fields, the acked
/// host configure `serial`, a reserved `u32` (written 0), then the two guest
/// `CLOCK_MONOTONIC` `u64` timestamps at offsets 40/48 — then the `n_rects`
/// rect table, then tight row-packed pixel bytes in rect order.
pub fn encode_commit(meta: &CommitMeta, rects: &[Rect], packed: &[u8]) -> io::Result<Vec<u8>> {
    let n = u32::try_from(rects.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "too many damage rects"))?;
    debug_assert!(meta.format <= FMT_ARGB8888, "unknown pixel format");
    if n > MAX_COMMIT_RECTS {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "commit rect count exceeds protocol ceiling",
        ));
    }
    let total = COMMIT_FIXED_LEN
        .checked_add(rects.len().saturating_mul(RECT_LEN))
        .and_then(|v| v.checked_add(packed.len()))
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "commit size overflow"))?;
    if total > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "commit exceeds frame bound",
        ));
    }
    let mut out = Vec::with_capacity(total);
    for v in [
        meta.win,
        meta.seq,
        meta.w,
        meta.h,
        meta.stride,
        meta.format,
        meta.scale_e12,
        n,
    ] {
        out.extend_from_slice(&v.to_le_bytes());
    }
    out.extend_from_slice(&meta.serial.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&meta.t_client_commit_ns.to_le_bytes());
    out.extend_from_slice(&meta.t_send_ns.to_le_bytes());
    for r in rects {
        for v in [r.x, r.y, r.w, r.h] {
            out.extend_from_slice(&v.to_le_bytes());
        }
    }
    out.extend_from_slice(packed);
    debug_assert_eq!(out.len(), total);
    Ok(out)
}

/// Inverse of [`encode_commit`].
///
/// Returns the metadata, the damage rects, and the offset at which pixel bytes
/// begin. Used by the round-trip tests and any in-guest consumer.
pub fn decode_commit(payload: &[u8]) -> io::Result<(CommitMeta, Vec<Rect>, usize)> {
    if payload.len() < COMMIT_FIXED_LEN {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "commit truncated",
        ));
    }
    let g32 = |off: usize| -> u32 {
        u32::from_le_bytes([
            payload[off],
            payload[off + 1],
            payload[off + 2],
            payload[off + 3],
        ])
    };
    let g64 = |off: usize| -> u64 {
        let mut b = [0u8; 8];
        b.copy_from_slice(&payload[off..off + 8]);
        u64::from_le_bytes(b)
    };
    let n = g32(28) as usize;
    let meta = CommitMeta {
        win: g32(0),
        seq: g32(4),
        w: g32(8),
        h: g32(12),
        stride: g32(16),
        format: g32(20),
        scale_e12: g32(24),
        serial: g32(32),
        t_client_commit_ns: g64(40),
        t_send_ns: g64(48),
    };
    let rects_end = COMMIT_FIXED_LEN
        .checked_add(n.saturating_mul(RECT_LEN))
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "rect count overflow"))?;
    if payload.len() < rects_end {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "commit rects truncated",
        ));
    }
    let mut rects = Vec::with_capacity(n);
    let mut off = COMMIT_FIXED_LEN;
    for _ in 0..n {
        rects.push(Rect {
            x: g32(off),
            y: g32(off + 4),
            w: g32(off + 8),
            h: g32(off + 12),
        });
        off += RECT_LEN;
    }
    debug_assert_eq!(off, rects_end);
    Ok((meta, rects, rects_end))
}

const SEL_MAX_ENTRIES_USZ: usize = 8;

/// The `win_new` payload carrying optional application-identity fields.
///
/// The base [`WinNew`] is the identity-free form emitted without `XWayland`; a
/// within-version peer that omits the extra fields still decodes here.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct WinNewFull {
    pub win: u32,
    pub app_id: String,
    pub title: String,
    pub w: u32,
    pub h: u32,
    pub scale: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub x11: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub class: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub instance: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transient_for: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub modal: Option<bool>,
}

/// Decode `win_new`, sanitizing every untrusted guest string in place.
pub fn decode_win_new(bytes: &[u8]) -> io::Result<WinNewFull> {
    debug_assert!(!bytes.is_empty(), "win_new payload cannot be empty");
    let mut msg: WinNewFull = from_json(bytes)?;
    msg.title = sanitize_text(&msg.title, WIN_STR_MAX);
    msg.app_id = sanitize_text(&msg.app_id, WIN_STR_MAX);
    msg.class = msg.class.take().map(|s| sanitize_text(&s, WIN_STR_MAX));
    msg.instance = msg.instance.take().map(|s| sanitize_text(&s, WIN_STR_MAX));
    debug_assert!(msg.title.len() <= WIN_STR_MAX, "title within cap");
    debug_assert!(msg.app_id.len() <= WIN_STR_MAX, "app_id within cap");
    Ok(msg)
}

/// One entry in a selection offer: a MIME name, its byte length, and (inline
/// only) its payload bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SelEntry {
    pub mime: String,
    pub data_len: u32,
    pub data: Vec<u8>,
}

/// A clipboard selection offer (`sel_offer`/`host_sel`). `n_entries == 0` with
/// `total_len == 0` is a cleared selection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SelOffer {
    pub serial: u32,
    pub origin: u32,
    pub flags: u32,
    pub total_len: u64,
    pub entries: Vec<SelEntry>,
}

impl SelOffer {
    #[must_use]
    pub const fn inline(&self) -> bool {
        self.flags & SEL_FLAG_INLINE != 0
    }
}

pub fn encode_sel_offer(offer: &SelOffer) -> io::Result<Vec<u8>> {
    let n =
        u32::try_from(offer.entries.len()).map_err(|_| bad("selection entry count overflow"))?;
    if n > SEL_MAX_ENTRIES {
        return Err(bad("selection entries exceed 8"));
    }
    let inline = offer.inline();
    let mut sum: u64 = 0;
    let mut descs: Vec<(u32, u32)> = Vec::with_capacity(offer.entries.len());
    for e in &offer.entries {
        let ml = u32::try_from(e.mime.len()).map_err(|_| bad("mime length overflow"))?;
        if ml > SEL_MAX_MIME_LEN {
            return Err(bad("mime length exceeds 128"));
        }
        if inline && u64::try_from(e.data.len()).unwrap_or(u64::MAX) != u64::from(e.data_len) {
            return Err(bad("inline payload length mismatch"));
        }
        sum = sum
            .checked_add(u64::from(e.data_len))
            .ok_or_else(|| bad("data_len sum overflow"))?;
        descs.push((ml, e.data_len));
    }
    if sum != offer.total_len {
        return Err(bad("total_len != sum(data_len)"));
    }
    if inline {
        if offer.total_len > SEL_INLINE_MAX {
            return Err(bad("inline selection exceeds 64 KiB"));
        }
    } else if offer.total_len > SEL_STREAM_MAX {
        return Err(bad("streamed selection exceeds 32 MiB"));
    }
    debug_assert!(
        descs.len() == offer.entries.len(),
        "one descriptor per entry"
    );
    let mut out = Vec::new();
    out.extend_from_slice(&offer.serial.to_le_bytes());
    out.extend_from_slice(&offer.origin.to_le_bytes());
    out.extend_from_slice(&n.to_le_bytes());
    out.extend_from_slice(&offer.flags.to_le_bytes());
    out.extend_from_slice(&offer.total_len.to_le_bytes());
    for (ml, dl) in &descs {
        out.extend_from_slice(&ml.to_le_bytes());
        out.extend_from_slice(&dl.to_le_bytes());
    }
    for e in &offer.entries {
        out.extend_from_slice(e.mime.as_bytes());
    }
    if inline {
        for e in &offer.entries {
            out.extend_from_slice(&e.data);
        }
    }
    debug_assert!(
        out.len() >= SEL_PREFIX_LEN,
        "offer carries the fixed prefix"
    );
    Ok(out)
}

struct SelHead {
    serial: u32,
    origin: u32,
    n: usize,
    flags: u32,
    total_len: u64,
    inline: bool,
}

struct SelLayout {
    mime_lens: [u32; SEL_MAX_ENTRIES_USZ],
    data_lens: [u32; SEL_MAX_ENTRIES_USZ],
    mime_off: [usize; SEL_MAX_ENTRIES_USZ],
    mime_end: usize,
    inline: bool,
}

pub fn decode_sel_offer(payload: &[u8]) -> io::Result<SelOffer> {
    let head = read_sel_prefix(payload)?;
    let layout = validate_sel_layout(payload, &head)?;
    let offer = build_sel_offer(payload, &head, &layout)?;
    debug_assert!(
        offer.entries.len() <= SEL_MAX_ENTRIES_USZ,
        "entries bounded"
    );
    debug_assert!(offer.total_len <= SEL_STREAM_MAX, "total_len bounded");
    Ok(offer)
}

fn read_sel_prefix(payload: &[u8]) -> io::Result<SelHead> {
    if payload.len() < SEL_PREFIX_LEN {
        return Err(bad("selection offer shorter than 24-byte prefix"));
    }
    let serial = rd_u32(payload, 0)?;
    let origin = rd_u32(payload, 4)?;
    let n_entries = rd_u32(payload, 8)?;
    let flags = rd_u32(payload, 12)?;
    let total_len = rd_u64(payload, 16)?;
    if n_entries > SEL_MAX_ENTRIES {
        return Err(bad("selection entries exceed 8"));
    }
    let n = usize::try_from(n_entries).map_err(|_| bad("entry count overflow"))?;
    debug_assert!(n_entries <= SEL_MAX_ENTRIES, "entry count bounded");
    debug_assert!(payload.len() >= SEL_PREFIX_LEN, "prefix present");
    Ok(SelHead {
        serial,
        origin,
        n,
        flags,
        total_len,
        inline: flags & SEL_FLAG_INLINE != 0,
    })
}

fn read_sel_descriptors(
    payload: &[u8],
    head: &SelHead,
) -> io::Result<(
    [u32; SEL_MAX_ENTRIES_USZ],
    [u32; SEL_MAX_ENTRIES_USZ],
    usize,
    usize,
)> {
    let span = head
        .n
        .checked_mul(SEL_DESC_LEN)
        .ok_or_else(|| bad("descriptor span overflow"))?;
    let desc_end = SEL_PREFIX_LEN
        .checked_add(span)
        .ok_or_else(|| bad("descriptor region overflow"))?;
    if payload.len() < desc_end {
        return Err(bad("selection offer truncated in descriptors"));
    }
    let mut mime_lens = [0u32; SEL_MAX_ENTRIES_USZ];
    let mut data_lens = [0u32; SEL_MAX_ENTRIES_USZ];
    let mut sum_data: u64 = 0;
    let mut sum_mime: usize = 0;
    for i in 0..head.n {
        let base = SEL_PREFIX_LEN + i * SEL_DESC_LEN;
        let ml = rd_u32(payload, base)?;
        let dl = rd_u32(payload, base + 4)?;
        if ml > SEL_MAX_MIME_LEN {
            return Err(bad("mime length exceeds 128"));
        }
        mime_lens[i] = ml;
        data_lens[i] = dl;
        sum_data = sum_data
            .checked_add(u64::from(dl))
            .ok_or_else(|| bad("data_len sum overflow"))?;
        let ml_usz = usize::try_from(ml).map_err(|_| bad("mime length overflow"))?;
        sum_mime = sum_mime
            .checked_add(ml_usz)
            .ok_or_else(|| bad("mime bytes overflow"))?;
    }
    if sum_data != head.total_len {
        return Err(bad("total_len != sum(data_len)"));
    }
    debug_assert!(head.n <= SEL_MAX_ENTRIES_USZ, "descriptor count bounded");
    Ok((mime_lens, data_lens, desc_end, sum_mime))
}

fn validate_sel_layout(payload: &[u8], head: &SelHead) -> io::Result<SelLayout> {
    let (mime_lens, data_lens, desc_end, sum_mime) = read_sel_descriptors(payload, head)?;
    let mime_end = desc_end
        .checked_add(sum_mime)
        .ok_or_else(|| bad("mime region overflow"))?;
    let mut mime_off = [0usize; SEL_MAX_ENTRIES_USZ];
    let mut off = desc_end;
    for i in 0..head.n {
        mime_off[i] = off;
        let ml_usz = usize::try_from(mime_lens[i]).map_err(|_| bad("mime length overflow"))?;
        off = off
            .checked_add(ml_usz)
            .ok_or_else(|| bad("mime offset overflow"))?;
    }
    debug_assert!(off == mime_end, "mime offsets consume the region");
    if payload.len() < mime_end {
        return Err(bad("selection offer truncated in mime region"));
    }
    validate_sel_mimes(payload, head, &mime_lens, &mime_off)?;
    validate_sel_sizes(payload, head, mime_end)?;
    Ok(SelLayout {
        mime_lens,
        data_lens,
        mime_off,
        mime_end,
        inline: head.inline,
    })
}

fn validate_sel_mimes(
    payload: &[u8],
    head: &SelHead,
    mime_lens: &[u32; SEL_MAX_ENTRIES_USZ],
    mime_off: &[usize; SEL_MAX_ENTRIES_USZ],
) -> io::Result<()> {
    let mut seen: [&str; SEL_MAX_ENTRIES_USZ] = [""; SEL_MAX_ENTRIES_USZ];
    for i in 0..head.n {
        let start = mime_off[i];
        let end = start + mime_lens[i] as usize;
        let slice = payload
            .get(start..end)
            .ok_or_else(|| bad("mime slice out of range"))?;
        let mime = std::str::from_utf8(slice).map_err(|_| bad("mime is not valid utf-8"))?;
        if !SEL_MIME_ALLOWLIST.contains(&mime) {
            return Err(bad("mime outside allowlist"));
        }
        if seen[..i].contains(&mime) {
            return Err(bad("duplicate mime in selection offer"));
        }
        seen[i] = mime;
    }
    debug_assert!(
        head.n <= SEL_MAX_ENTRIES_USZ,
        "seen array covers all entries"
    );
    Ok(())
}

fn validate_sel_sizes(payload: &[u8], head: &SelHead, mime_end: usize) -> io::Result<()> {
    debug_assert!(head.n <= SEL_MAX_ENTRIES_USZ, "entry count bounded");
    if head.n == 0 && head.total_len != 0 {
        return Err(bad("empty selection must carry zero total_len"));
    }
    debug_assert!(mime_end <= payload.len(), "mime region within frame");
    if head.inline {
        if head.total_len > SEL_INLINE_MAX {
            return Err(bad("inline selection exceeds 64 KiB"));
        }
        let bytes = usize::try_from(head.total_len).map_err(|_| bad("total_len overflow"))?;
        let expected = mime_end
            .checked_add(bytes)
            .ok_or_else(|| bad("inline frame size overflow"))?;
        if payload.len() != expected {
            return Err(bad("inline selection frame size mismatch"));
        }
    } else {
        if head.total_len > SEL_STREAM_MAX {
            return Err(bad("streamed selection exceeds 32 MiB"));
        }
        if payload.len() != mime_end {
            return Err(bad("streamed selection carries payload bytes"));
        }
    }
    Ok(())
}

fn build_sel_offer(payload: &[u8], head: &SelHead, layout: &SelLayout) -> io::Result<SelOffer> {
    let mut entries = Vec::new();
    entries
        .try_reserve_exact(head.n)
        .map_err(|_| io::Error::new(io::ErrorKind::OutOfMemory, "selection entries alloc"))?;
    let mut pay_off = layout.mime_end;
    for i in 0..head.n {
        let mend = layout.mime_off[i] + layout.mime_lens[i] as usize;
        let slice = &payload[layout.mime_off[i]..mend];
        let mime = std::str::from_utf8(slice)
            .map_err(|_| bad("mime is not valid utf-8"))?
            .to_owned();
        let dl = layout.data_lens[i];
        let data = if layout.inline {
            let dend = pay_off
                .checked_add(dl as usize)
                .ok_or_else(|| bad("payload span overflow"))?;
            let bytes = payload
                .get(pay_off..dend)
                .ok_or_else(|| bad("payload slice out of range"))?
                .to_vec();
            pay_off = dend;
            bytes
        } else {
            Vec::new()
        };
        entries.push(SelEntry {
            mime,
            data_len: dl,
            data,
        });
    }
    debug_assert!(entries.len() == head.n, "entry count matches header");
    debug_assert!(
        !layout.inline || pay_off == payload.len(),
        "inline payload fully consumed"
    );
    Ok(SelOffer {
        serial: head.serial,
        origin: head.origin,
        flags: head.flags,
        total_len: head.total_len,
        entries,
    })
}

/// A streamed selection payload chunk (`sel_data`); `flags` bit 0 marks the
/// final chunk of a read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SelChunk {
    pub serial: u32,
    pub mime_idx: u32,
    pub flags: u32,
    pub data: Vec<u8>,
}

impl SelChunk {
    #[must_use]
    pub const fn is_final(&self) -> bool {
        self.flags & SEL_FLAG_FINAL != 0
    }
}

pub fn encode_sel_chunk(chunk: &SelChunk) -> io::Result<Vec<u8>> {
    let len = u32::try_from(chunk.data.len()).map_err(|_| bad("chunk length overflow"))?;
    if len > SEL_CHUNK_MAX {
        return Err(bad("chunk exceeds 256 KiB"));
    }
    debug_assert!(
        chunk.data.len() == len as usize,
        "declared length matches data"
    );
    let mut out = Vec::with_capacity(SEL_CHUNK_PREFIX_LEN + chunk.data.len());
    out.extend_from_slice(&chunk.serial.to_le_bytes());
    out.extend_from_slice(&chunk.mime_idx.to_le_bytes());
    out.extend_from_slice(&chunk.flags.to_le_bytes());
    out.extend_from_slice(&len.to_le_bytes());
    out.extend_from_slice(&chunk.data);
    debug_assert!(
        out.len() == SEL_CHUNK_PREFIX_LEN + chunk.data.len(),
        "chunk frame exact"
    );
    Ok(out)
}

pub fn decode_sel_chunk(payload: &[u8]) -> io::Result<SelChunk> {
    if payload.len() < SEL_CHUNK_PREFIX_LEN {
        return Err(bad("selection chunk shorter than 16-byte prefix"));
    }
    let serial = rd_u32(payload, 0)?;
    let mime_idx = rd_u32(payload, 4)?;
    let flags = rd_u32(payload, 8)?;
    let len = rd_u32(payload, 12)?;
    if len > SEL_CHUNK_MAX {
        return Err(bad("chunk length exceeds 256 KiB"));
    }
    let expected = SEL_CHUNK_PREFIX_LEN
        .checked_add(len as usize)
        .ok_or_else(|| bad("chunk size overflow"))?;
    if payload.len() != expected {
        return Err(bad("selection chunk frame size mismatch"));
    }
    let data = payload[SEL_CHUNK_PREFIX_LEN..expected].to_vec();
    debug_assert!(data.len() == len as usize, "chunk data length exact");
    Ok(SelChunk {
        serial,
        mime_idx,
        flags,
        data,
    })
}

/// A demand `sel_read {serial, mime, cancel}` for a streamed selection.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SelRead {
    pub serial: u32,
    pub mime: String,
    pub cancel: bool,
}

pub fn decode_sel_read(bytes: &[u8]) -> io::Result<SelRead> {
    debug_assert!(!bytes.is_empty(), "sel_read payload cannot be empty");
    let msg: SelRead = from_json(bytes)?;
    if msg.mime.len() > SEL_MAX_MIME_LEN as usize {
        return Err(bad("sel_read mime exceeds 128 bytes"));
    }
    debug_assert!(msg.mime.len() <= SEL_MAX_MIME_LEN as usize, "mime bounded");
    Ok(msg)
}

/// A cursor image (`cursor_image`): tightly packed ARGB8888-premultiplied
/// pixels matching [`FMT_ARGB8888`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CursorImage {
    pub win: u32,
    pub w: u32,
    pub h: u32,
    pub hotspot_x: u32,
    pub hotspot_y: u32,
    pub scale_e12: u32,
    pub pixels: Vec<u8>,
}

fn check_cursor_dims(w: u32, h: u32, hx: u32, hy: u32) -> io::Result<()> {
    if !(CURSOR_MIN_DIM..=CURSOR_MAX_DIM).contains(&w) {
        return Err(bad("cursor width out of range"));
    }
    if !(CURSOR_MIN_DIM..=CURSOR_MAX_DIM).contains(&h) {
        return Err(bad("cursor height out of range"));
    }
    if hx >= w {
        return Err(bad("cursor hotspot_x outside image"));
    }
    if hy >= h {
        return Err(bad("cursor hotspot_y outside image"));
    }
    debug_assert!(
        w >= CURSOR_MIN_DIM && h >= CURSOR_MIN_DIM,
        "cursor dims positive"
    );
    debug_assert!(hx < w && hy < h, "hotspot inside image");
    Ok(())
}

fn cursor_pixel_bytes(w: u32, h: u32) -> io::Result<u64> {
    debug_assert!(w <= CURSOR_MAX_DIM && h <= CURSOR_MAX_DIM, "dims bounded");
    let area = u64::from(w)
        .checked_mul(u64::from(h))
        .ok_or_else(|| bad("cursor area overflow"))?;
    let bytes = area
        .checked_mul(4)
        .ok_or_else(|| bad("cursor byte count overflow"))?;
    debug_assert!(bytes <= u64::from(CURSOR_MAX_DIM) * u64::from(CURSOR_MAX_DIM) * 4);
    Ok(bytes)
}

pub fn encode_cursor_image(cur: &CursorImage) -> io::Result<Vec<u8>> {
    check_cursor_dims(cur.w, cur.h, cur.hotspot_x, cur.hotspot_y)?;
    let need = cursor_pixel_bytes(cur.w, cur.h)?;
    let pixlen =
        u64::try_from(cur.pixels.len()).map_err(|_| bad("cursor pixel length overflow"))?;
    if pixlen != need {
        return Err(bad("cursor pixel length mismatch"));
    }
    let mut out = Vec::with_capacity(CURSOR_PREFIX_LEN + cur.pixels.len());
    for v in [
        cur.win,
        cur.w,
        cur.h,
        cur.hotspot_x,
        cur.hotspot_y,
        cur.scale_e12,
    ] {
        out.extend_from_slice(&v.to_le_bytes());
    }
    out.extend_from_slice(&cur.pixels);
    debug_assert!(
        out.len() == CURSOR_PREFIX_LEN + cur.pixels.len(),
        "cursor frame exact"
    );
    Ok(out)
}

pub fn decode_cursor_image(payload: &[u8]) -> io::Result<CursorImage> {
    if payload.len() < CURSOR_PREFIX_LEN {
        return Err(bad("cursor image shorter than 24-byte prefix"));
    }
    let win = rd_u32(payload, 0)?;
    let w = rd_u32(payload, 4)?;
    let h = rd_u32(payload, 8)?;
    let hotspot_x = rd_u32(payload, 12)?;
    let hotspot_y = rd_u32(payload, 16)?;
    let scale_e12 = rd_u32(payload, 20)?;
    check_cursor_dims(w, h, hotspot_x, hotspot_y)?;
    let need = usize::try_from(cursor_pixel_bytes(w, h)?)
        .map_err(|_| bad("cursor byte count overflow"))?;
    let expected = CURSOR_PREFIX_LEN
        .checked_add(need)
        .ok_or_else(|| bad("cursor frame overflow"))?;
    if payload.len() != expected {
        return Err(bad("cursor image frame size mismatch"));
    }
    let pixels = payload[CURSOR_PREFIX_LEN..expected].to_vec();
    debug_assert!(pixels.len() == need, "cursor pixel length exact");
    Ok(CursorImage {
        win,
        w,
        h,
        hotspot_x,
        hotspot_y,
        scale_e12,
        pixels,
    })
}

/// A keymap request `set_layout {layout, variant}`; both tokens are capped at
/// 64 bytes and restricted to `[A-Za-z0-9_-]`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SetLayout {
    pub layout: String,
    pub variant: String,
}

fn check_layout_token(token: &str) -> io::Result<()> {
    if token.len() > LAYOUT_NAME_MAX {
        return Err(bad("layout token exceeds 64 bytes"));
    }
    if !token
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        return Err(bad("layout token has an illegal character"));
    }
    debug_assert!(token.len() <= LAYOUT_NAME_MAX, "layout token within cap");
    Ok(())
}

pub fn decode_set_layout(bytes: &[u8]) -> io::Result<SetLayout> {
    debug_assert!(!bytes.is_empty(), "set_layout payload cannot be empty");
    let msg: SetLayout = from_json(bytes)?;
    check_layout_token(&msg.layout)?;
    check_layout_token(&msg.variant)?;
    Ok(msg)
}

/// The protocol-error taxonomy carried by `error` frames. An unknown code fails
/// deserialization, so a peer cannot invent one.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    ProtocolVersion,
    MalformedFrame,
    OversizeFrame,
    InvalidDimensions,
    InvalidWindow,
    Policy,
}

/// An `error {code, reason}` frame; `reason` is sanitized and capped on decode.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ErrorMsg {
    pub code: ErrorCode,
    pub reason: String,
}

pub fn decode_error(bytes: &[u8]) -> io::Result<ErrorMsg> {
    debug_assert!(!bytes.is_empty(), "error payload cannot be empty");
    let mut msg: ErrorMsg = from_json(bytes)?;
    msg.reason = sanitize_text(&msg.reason, ERR_REASON_MAX);
    debug_assert!(msg.reason.len() <= ERR_REASON_MAX, "reason within cap");
    Ok(msg)
}

/// The surrounding-text snapshot inside a `text_input_state`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Surrounding {
    pub text: String,
    pub cursor: u32,
    pub anchor: u32,
}

/// A cursor rectangle in window-local logical pixels. The codec bounds only its
/// magnitude; window-relative containment is the consumer's responsibility.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub struct CursorRect {
    pub x: i32,
    pub y: i32,
    pub w: u32,
    pub h: u32,
}

fn check_cursor_rect(rect: &CursorRect) -> io::Result<()> {
    if rect.w < 1 || rect.w > TEXT_RECT_DIM_MAX {
        return Err(bad("cursor_rect width out of range"));
    }
    if rect.h < 1 || rect.h > TEXT_RECT_DIM_MAX {
        return Err(bad("cursor_rect height out of range"));
    }
    if rect.x < -TEXT_RECT_COORD_MAX || rect.x > TEXT_RECT_COORD_MAX {
        return Err(bad("cursor_rect x out of range"));
    }
    if rect.y < -TEXT_RECT_COORD_MAX || rect.y > TEXT_RECT_COORD_MAX {
        return Err(bad("cursor_rect y out of range"));
    }
    debug_assert!(rect.w >= 1 && rect.h >= 1, "cursor_rect dims positive");
    debug_assert!(rect.x.abs() <= TEXT_RECT_COORD_MAX, "cursor_rect x bounded");
    Ok(())
}

/// `text_input_state`: the atomic `zwp_text_input_v3` state made current by the
/// client's commit.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TextInputState {
    pub win: u32,
    pub serial: u32,
    pub enabled: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub surrounding: Option<Surrounding>,
    pub change_cause: u32,
    pub content_hint: u32,
    pub content_purpose: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor_rect: Option<CursorRect>,
}

pub fn decode_text_input_state(bytes: &[u8]) -> io::Result<TextInputState> {
    debug_assert!(
        !bytes.is_empty(),
        "text_input_state payload cannot be empty"
    );
    let msg: TextInputState = from_json(bytes)?;
    if let Some(s) = msg.surrounding.as_ref() {
        if s.text.len() > TEXT_FIELD_MAX {
            return Err(bad("surrounding text exceeds 4 KiB"));
        }
        let len = u32::try_from(s.text.len()).map_err(|_| bad("surrounding length overflow"))?;
        if s.cursor > len || s.anchor > len {
            return Err(bad("surrounding cursor past end of text"));
        }
        debug_assert!(
            s.text.len() <= TEXT_FIELD_MAX,
            "surrounding text within cap"
        );
    }
    if let Some(rect) = msg.cursor_rect.as_ref() {
        check_cursor_rect(rect)?;
    }
    Ok(msg)
}

/// The preedit span inside a `text_input_apply`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Preedit {
    pub text: String,
    pub cursor_begin: i32,
    pub cursor_end: i32,
}

/// `text_input_apply`: one atomic input-method edit group.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TextInputApply {
    pub win: u32,
    pub serial: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preedit: Option<Preedit>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit_text: Option<String>,
    pub delete_before: u32,
    pub delete_after: u32,
}

pub fn decode_text_input_apply(bytes: &[u8]) -> io::Result<TextInputApply> {
    debug_assert!(
        !bytes.is_empty(),
        "text_input_apply payload cannot be empty"
    );
    let msg: TextInputApply = from_json(bytes)?;
    if let Some(t) = msg.commit_text.as_ref()
        && t.len() > TEXT_FIELD_MAX
    {
        return Err(bad("commit_text exceeds 4 KiB"));
    }
    if let Some(p) = msg.preedit.as_ref() {
        if p.text.len() > TEXT_FIELD_MAX {
            return Err(bad("preedit text exceeds 4 KiB"));
        }
        let len = i32::try_from(p.text.len()).map_err(|_| bad("preedit length overflow"))?;
        if p.cursor_begin < 0 || p.cursor_end < 0 || p.cursor_begin > len || p.cursor_end > len {
            return Err(bad("preedit cursor past end of text"));
        }
        debug_assert!(p.text.len() <= TEXT_FIELD_MAX, "preedit text within cap");
    }
    debug_assert!(!bytes.is_empty(), "apply payload was non-empty");
    Ok(msg)
}

#[cfg(target_os = "linux")]
mod transport {
    use std::io;

    use vsock::{VMADDR_CID_ANY, VsockListener, VsockStream};

    /// Bind the guest-side surface-protocol listener (host connects in).
    pub fn bind_vsock(port: u32) -> io::Result<VsockListener> {
        debug_assert!(port != 0, "vsock port 0 is reserved");
        let listener = VsockListener::bind_with_cid_port(VMADDR_CID_ANY, port)?;
        listener.set_nonblocking(true)?;
        Ok(listener)
    }

    /// Non-blocking accept: `Ok(None)` when no host is waiting so the caller can
    /// keep compositing and poll again.
    pub fn accept_host(listener: &VsockListener) -> io::Result<Option<VsockStream>> {
        debug_assert!(listener.local_addr().is_ok(), "listener not bound");
        match listener.accept() {
            Ok((stream, _addr)) => {
                stream.set_nonblocking(false)?;
                Ok(Some(stream))
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => Ok(None),
            Err(e) => Err(e),
        }
    }
}

#[cfg(target_os = "linux")]
pub use transport::{accept_host, bind_vsock};

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn frame_round_trip() {
        let mut buf = Vec::new();
        write_frame(&mut buf, T_HELLO, br#"{"version":1}"#).expect("write");
        let mut cur = Cursor::new(buf);
        let f = read_frame(&mut cur).expect("read");
        assert_eq!(f.msg_type, T_HELLO);
        assert_eq!(f.flags, 0);
        assert_eq!(f.payload, br#"{"version":1}"#);
    }

    #[test]
    fn frame_rejects_oversize_len_without_allocating() {
        let mut buf = Vec::new();
        buf.extend_from_slice(&T_COMMIT.to_le_bytes());
        buf.extend_from_slice(&0u32.to_le_bytes());
        buf.extend_from_slice(&((MAX_FRAME as u64) + 1).to_le_bytes());
        let mut cur = Cursor::new(buf);
        let err = read_frame(&mut cur).expect_err("must reject");
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn hello_json_round_trip() {
        let hello = Hello {
            version: PROTOCOL_VERSION,
            distro: "ubuntu".into(),
        };
        let mut buf = Vec::new();
        write_json(&mut buf, T_HELLO, &hello).expect("write");
        let mut cur = Cursor::new(buf);
        let f = read_frame(&mut cur).expect("read");
        let got: Hello = serde_json::from_slice(&f.payload).expect("de");
        assert_eq!(got, hello);
    }

    #[test]
    fn parse_host_dispatches_present_ack() {
        let ack = PresentAck {
            win: 7,
            seq: 42,
            t_recv_ns: 100,
            t_present_ns: 200,
        };
        let mut buf = Vec::new();
        write_json(&mut buf, T_PRESENT_ACK, &ack).expect("write");
        let mut cur = Cursor::new(buf);
        let f = read_frame(&mut cur).expect("read");
        match parse_host(&f).expect("parse") {
            HostMsg::PresentAck(got) => assert_eq!(got, ack),
            other => panic!("wrong variant: {other:?}"),
        }
    }

    #[test]
    fn popup_new_json_round_trip() {
        let msg = PopupNew {
            win: 12,
            parent: 3,
            x: -8,
            y: 40,
            w: 220,
            h: 160,
            scale: 2.0,
        };
        let mut buf = Vec::new();
        write_json(&mut buf, T_POPUP_NEW, &msg).expect("write");
        let mut cur = Cursor::new(buf);
        let f = read_frame(&mut cur).expect("read");
        assert_eq!(f.msg_type, T_POPUP_NEW);
        let got: PopupNew = serde_json::from_slice(&f.payload).expect("de");
        assert_eq!(got, msg);
    }

    #[test]
    fn popup_moved_json_round_trip() {
        let msg = PopupMoved {
            win: 12,
            x: 17,
            y: -3,
        };
        let mut buf = Vec::new();
        write_json(&mut buf, T_POPUP_MOVED, &msg).expect("write");
        let mut cur = Cursor::new(buf);
        let f = read_frame(&mut cur).expect("read");
        assert_eq!(f.msg_type, T_POPUP_MOVED);
        let got: PopupMoved = serde_json::from_slice(&f.payload).expect("de");
        assert_eq!(got, msg);
    }

    #[test]
    fn parse_host_dispatches_popup_dismiss() {
        let r = WinRef { win: 9 };
        let mut buf = Vec::new();
        write_json(&mut buf, T_POPUP_DISMISS, &r).expect("write");
        let mut cur = Cursor::new(buf);
        let f = read_frame(&mut cur).expect("read");
        match parse_host(&f).expect("parse") {
            HostMsg::PopupDismiss(got) => assert_eq!(got, r),
            other => panic!("wrong variant: {other:?}"),
        }
    }

    #[test]
    fn parse_host_unknown_type_is_tolerated() {
        let f = Frame {
            msg_type: 999,
            flags: 0,
            payload: Vec::new(),
        };
        assert_eq!(parse_host(&f).expect("parse"), HostMsg::Unknown(999));
    }

    #[test]
    fn commit_round_trip() {
        let meta = CommitMeta {
            win: 3,
            seq: 9,
            w: 4,
            h: 2,
            stride: 16,
            format: FMT_XRGB8888,
            scale_e12: 4096,
            serial: 7,
            t_client_commit_ns: 111,
            t_send_ns: 222,
        };
        let rects = [
            Rect {
                x: 0,
                y: 0,
                w: 2,
                h: 2,
            },
            Rect {
                x: 2,
                y: 0,
                w: 2,
                h: 1,
            },
        ];
        let packed = vec![0xABu8; 48];
        let payload = encode_commit(&meta, &rects, &packed).expect("encode");
        let (got_meta, got_rects, off) = decode_commit(&payload).expect("decode");
        assert_eq!(got_meta, meta);
        assert_eq!(got_rects, rects);
        assert_eq!(&payload[off..], &packed[..]);
    }

    #[test]
    fn decode_rejects_truncated_rects() {
        let meta = CommitMeta {
            win: 1,
            seq: 1,
            w: 1,
            h: 1,
            stride: 4,
            format: FMT_ARGB8888,
            scale_e12: 4096,
            serial: 0,
            t_client_commit_ns: 0,
            t_send_ns: 0,
        };
        let rects = [Rect {
            x: 0,
            y: 0,
            w: 1,
            h: 1,
        }];
        let mut payload = encode_commit(&meta, &rects, &[0u8; 4]).expect("encode");
        payload.truncate(COMMIT_FIXED_LEN + 4);
        let err = decode_commit(&payload).expect_err("must reject");
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn encode_rejects_over_rect_ceiling() {
        let meta = CommitMeta {
            win: 1,
            seq: 1,
            w: 1,
            h: 1,
            stride: 4,
            format: FMT_XRGB8888,
            scale_e12: 4096,
            serial: 0,
            t_client_commit_ns: 0,
            t_send_ns: 0,
        };
        let one = Rect {
            x: 0,
            y: 0,
            w: 0,
            h: 0,
        };
        let rects = vec![one; MAX_COMMIT_RECTS as usize + 1];
        let err = encode_commit(&meta, &rects, &[]).expect_err("over ceiling must reject");
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn commit_fixed_prefix_is_56_bytes() {
        assert_eq!(COMMIT_FIXED_LEN, 56);
    }

    #[test]
    fn commit_serial_placement_round_trips() {
        let meta = CommitMeta {
            win: 2,
            seq: 5,
            w: 1,
            h: 1,
            stride: 4,
            format: FMT_ARGB8888,
            scale_e12: 8192,
            serial: 0xAABB_CCDD,
            t_client_commit_ns: 0x0102_0304_0506_0708,
            t_send_ns: 0x1112_1314_1516_1718,
        };
        let payload = encode_commit(&meta, &[], &[]).expect("encode");
        assert_eq!(payload.len(), COMMIT_FIXED_LEN, "no rects, no pixels");
        assert_eq!(&payload[32..36], &meta.serial.to_le_bytes(), "serial at 32");
        assert_eq!(&payload[36..40], &[0u8; 4], "reserved word is zero");
        assert_eq!(
            &payload[40..48],
            &meta.t_client_commit_ns.to_le_bytes(),
            "t_client stays 8-aligned at 40"
        );
        assert_eq!(
            &payload[48..56],
            &meta.t_send_ns.to_le_bytes(),
            "t_send at 48"
        );
        let (got, rects, off) = decode_commit(&payload).expect("decode");
        assert_eq!(got.serial, meta.serial, "serial survives round-trip");
        assert_eq!(got, meta);
        assert!(rects.is_empty());
        assert_eq!(off, COMMIT_FIXED_LEN);
    }
}
