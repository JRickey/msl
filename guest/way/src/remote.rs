//! Surface protocol v0 wire codecs (docs/specs/m4-gui-protocol.md).
//!
//! Little-endian `type|flags|len|payload` framing, JSON control payloads, and
//! the binary `commit` layout. Transport-agnostic: a `Read`/`Write` pair is all
//! the codec needs, so the whole module is unit-testable off-VM.

use std::io::{self, Read, Write};

use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u32 = 4;
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

pub const T_HELLO_ACK: u32 = 2;
pub const T_CONFIGURE: u32 = 4;
pub const T_CLOSE: u32 = 6;
pub const T_POINTER: u32 = 8;
pub const T_KEY: u32 = 10;
pub const T_PRESENT_ACK: u32 = 12;
pub const T_STATS_REQ: u32 = 14;
pub const T_POPUP_DISMISS: u32 = 16;

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
    pub refresh_hz: u32,
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
        T_HELLO_ACK => HostMsg::HelloAck(from_json(&frame.payload)?),
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
