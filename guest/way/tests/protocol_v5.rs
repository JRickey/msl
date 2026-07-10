//! Protocol v5 codec round-trip and rejection tests (docs/specs/gui-phase2.md).

use msl_way::remote::{
    CursorImage, CursorRect, ERR_REASON_MAX, ErrorCode, ErrorMsg, Frame, HelloAck, HostMsg,
    Preedit, SEL_CHUNK_MAX, SEL_FLAG_FINAL, SEL_FLAG_INLINE, SEL_INLINE_MAX, SEL_MAX_ENTRIES,
    SEL_MAX_MIME_LEN, SEL_STREAM_MAX, SelChunk, SelEntry, SelOffer, SelRead, SetLayout,
    Surrounding, T_HELLO_ACK, T_HOST_SEL, TEXT_FIELD_MAX, TextInputApply, TextInputState,
    WIN_STR_MAX, WinNewFull, decode_cursor_image, decode_error, decode_hello_ack, decode_sel_chunk,
    decode_sel_offer, decode_sel_read, decode_set_layout, decode_text_input_apply,
    decode_text_input_state, decode_win_new, encode_cursor_image, encode_sel_chunk,
    encode_sel_offer, parse_host,
};

const SEL_PREFIX_LEN: usize = 24;

#[derive(Default)]
struct SelWire<'a> {
    serial: u32,
    origin: u32,
    n: u32,
    flags: u32,
    total_len: u64,
    descs: &'a [(u32, u32)],
    mimes: &'a [&'a [u8]],
    payloads: &'a [&'a [u8]],
}

fn raw_sel(wire: &SelWire) -> Vec<u8> {
    let mut v = Vec::new();
    v.extend_from_slice(&wire.serial.to_le_bytes());
    v.extend_from_slice(&wire.origin.to_le_bytes());
    v.extend_from_slice(&wire.n.to_le_bytes());
    v.extend_from_slice(&wire.flags.to_le_bytes());
    v.extend_from_slice(&wire.total_len.to_le_bytes());
    for (ml, dl) in wire.descs {
        v.extend_from_slice(&ml.to_le_bytes());
        v.extend_from_slice(&dl.to_le_bytes());
    }
    for m in wire.mimes {
        v.extend_from_slice(m);
    }
    for p in wire.payloads {
        v.extend_from_slice(p);
    }
    v
}

struct CursorWire<'a> {
    win: u32,
    w: u32,
    h: u32,
    hx: u32,
    hy: u32,
    scale: u32,
    pixels: &'a [u8],
}

impl Default for CursorWire<'_> {
    fn default() -> Self {
        Self {
            win: 1,
            w: 1,
            h: 1,
            hx: 0,
            hy: 0,
            scale: 4096,
            pixels: &[],
        }
    }
}

fn raw_cursor(wire: &CursorWire) -> Vec<u8> {
    let mut v = Vec::new();
    for field in [wire.win, wire.w, wire.h, wire.hx, wire.hy, wire.scale] {
        v.extend_from_slice(&field.to_le_bytes());
    }
    v.extend_from_slice(wire.pixels);
    v
}

fn win_with_strings(title: &str, class: Option<&str>) -> Vec<u8> {
    let msg = WinNewFull {
        win: 1,
        app_id: "a".into(),
        title: title.to_owned(),
        w: 1,
        h: 1,
        scale: 1.0,
        x11: None,
        pid: None,
        class: class.map(str::to_owned),
        instance: None,
        transient_for: None,
        modal: None,
    };
    serde_json::to_vec(&msg).expect("encode")
}

#[test]
fn version_is_five() {
    assert_eq!(msl_way::remote::PROTOCOL_VERSION, 5);
}

#[test]
fn win_new_full_round_trip() {
    let msg = WinNewFull {
        win: 3,
        app_id: "org.gnome.app".into(),
        title: "Files".into(),
        w: 800,
        h: 600,
        scale: 2.0,
        x11: Some(true),
        pid: Some(4242),
        class: Some("Gimp".into()),
        instance: Some("gimp".into()),
        transient_for: Some(7),
        modal: Some(false),
    };
    let bytes = serde_json::to_vec(&msg).expect("encode");
    assert_eq!(decode_win_new(&bytes).expect("decode"), msg);
}

#[test]
fn win_new_control_chars_in_title_are_stripped() {
    let bytes = win_with_strings("AB\u{a}C", None);
    let got = decode_win_new(&bytes).expect("decode");
    assert_eq!(got.title, "ABC");
}

#[test]
fn win_new_control_chars_in_class_are_stripped() {
    let bytes = win_with_strings("t", Some("X\u{1}Y"));
    let got = decode_win_new(&bytes).expect("decode");
    assert_eq!(got.class.as_deref(), Some("XY"));
}

#[test]
fn win_new_string_is_capped() {
    let long = "a".repeat(WIN_STR_MAX + 50);
    let msg = WinNewFull {
        win: 1,
        app_id: "a".into(),
        title: long,
        w: 1,
        h: 1,
        scale: 1.0,
        x11: None,
        pid: None,
        class: None,
        instance: None,
        transient_for: None,
        modal: None,
    };
    let bytes = serde_json::to_vec(&msg).expect("encode");
    assert_eq!(
        decode_win_new(&bytes).expect("decode").title.len(),
        WIN_STR_MAX
    );
}

#[test]
fn hello_ack_output_round_trip() {
    let ack = HelloAck {
        version: 5,
        scale: 2.0,
        refresh_hz: 60.0,
        output_w: Some(1920),
        output_h: Some(1080),
    };
    let bytes = serde_json::to_vec(&ack).expect("encode");
    assert_eq!(decode_hello_ack(&bytes).expect("decode"), ack);
}

#[test]
fn hello_ack_fractional_refresh_round_trips() {
    let ack = HelloAck {
        version: 5,
        scale: 1.0,
        refresh_hz: 59.94,
        output_w: None,
        output_h: None,
    };
    let bytes = serde_json::to_vec(&ack).expect("encode");
    let back = decode_hello_ack(&bytes).expect("decode");
    assert!((back.refresh_hz - 59.94).abs() < f64::EPSILON);
    assert_eq!(back.refresh_hz_rounded(), 60);
}

#[test]
fn hello_ack_zero_output_rejected_through_parse_host() {
    let frame = Frame {
        msg_type: T_HELLO_ACK,
        flags: 0,
        payload: br#"{"version":5,"scale":1.0,"refresh_hz":60,"output_w":0}"#.to_vec(),
    };
    assert!(parse_host(&frame).is_err());
}

#[test]
fn hello_ack_absent_output_decodes() {
    let json = br#"{"version":5,"scale":1.0,"refresh_hz":60}"#;
    let ack = decode_hello_ack(json).expect("decode");
    assert_eq!(ack.output_w, None);
}

#[test]
fn hello_ack_rejects_zero_output() {
    let json = br#"{"version":5,"scale":1.0,"refresh_hz":60,"output_w":0}"#;
    assert!(decode_hello_ack(json).is_err());
}

#[test]
fn hello_ack_rejects_over_max_output() {
    let json = br#"{"version":5,"scale":1.0,"refresh_hz":60,"output_h":16385}"#;
    assert!(decode_hello_ack(json).is_err());
}

#[test]
fn sel_offer_inline_round_trip() {
    let offer = SelOffer {
        serial: 1,
        origin: 2,
        flags: SEL_FLAG_INLINE,
        total_len: 5,
        entries: vec![SelEntry {
            mime: "text/plain".into(),
            data_len: 5,
            data: b"hello".to_vec(),
        }],
    };
    let bytes = encode_sel_offer(&offer).expect("encode");
    assert_eq!(decode_sel_offer(&bytes).expect("decode"), offer);
}

#[test]
fn sel_offer_streamed_round_trip() {
    let offer = SelOffer {
        serial: 9,
        origin: 4,
        flags: 0,
        total_len: 100,
        entries: vec![SelEntry {
            mime: "image/png".into(),
            data_len: 100,
            data: Vec::new(),
        }],
    };
    let bytes = encode_sel_offer(&offer).expect("encode");
    assert_eq!(decode_sel_offer(&bytes).expect("decode"), offer);
}

#[test]
fn sel_offer_cleared_round_trip() {
    let offer = SelOffer {
        serial: 3,
        origin: 1,
        flags: SEL_FLAG_INLINE,
        total_len: 0,
        entries: Vec::new(),
    };
    let bytes = encode_sel_offer(&offer).expect("encode");
    assert_eq!(bytes.len(), SEL_PREFIX_LEN);
    assert_eq!(decode_sel_offer(&bytes).expect("decode"), offer);
}

#[test]
fn sel_offer_rejects_oversize_total_len() {
    let bytes = raw_sel(&SelWire {
        n: 1,
        total_len: SEL_STREAM_MAX + 1,
        descs: &[(10, u32::try_from(SEL_STREAM_MAX + 1).unwrap())],
        mimes: &[b"text/plain"],
        ..Default::default()
    });
    assert!(decode_sel_offer(&bytes).is_err());
}

#[test]
fn sel_offer_rejects_too_many_entries() {
    let bytes = raw_sel(&SelWire {
        n: SEL_MAX_ENTRIES + 1,
        ..Default::default()
    });
    assert!(decode_sel_offer(&bytes).is_err());
}

#[test]
fn sel_offer_rejects_total_len_mismatch() {
    let bytes = raw_sel(&SelWire {
        n: 1,
        total_len: 6,
        descs: &[(10, 5)],
        mimes: &[b"text/plain"],
        ..Default::default()
    });
    assert!(decode_sel_offer(&bytes).is_err());
}

#[test]
fn sel_offer_rejects_inline_over_64k() {
    let bytes = raw_sel(&SelWire {
        n: 1,
        flags: SEL_FLAG_INLINE,
        total_len: SEL_INLINE_MAX + 1,
        descs: &[(10, u32::try_from(SEL_INLINE_MAX + 1).unwrap())],
        mimes: &[b"text/plain"],
        ..Default::default()
    });
    assert!(decode_sel_offer(&bytes).is_err());
}

#[test]
fn sel_offer_rejects_trailing_bytes() {
    let offer = SelOffer {
        serial: 1,
        origin: 1,
        flags: SEL_FLAG_INLINE,
        total_len: 2,
        entries: vec![SelEntry {
            mime: "text/plain".into(),
            data_len: 2,
            data: b"hi".to_vec(),
        }],
    };
    let mut bytes = encode_sel_offer(&offer).expect("encode");
    bytes.push(0);
    assert!(decode_sel_offer(&bytes).is_err());
}

#[test]
fn sel_offer_rejects_short_buffer() {
    let offer = SelOffer {
        serial: 1,
        origin: 1,
        flags: SEL_FLAG_INLINE,
        total_len: 2,
        entries: vec![SelEntry {
            mime: "text/plain".into(),
            data_len: 2,
            data: b"hi".to_vec(),
        }],
    };
    let mut bytes = encode_sel_offer(&offer).expect("encode");
    bytes.pop();
    assert!(decode_sel_offer(&bytes).is_err());
}

#[test]
fn sel_offer_rejects_non_utf8_mime() {
    let bytes = raw_sel(&SelWire {
        n: 1,
        descs: &[(2, 0)],
        mimes: &[&[0xFF, 0xFE]],
        ..Default::default()
    });
    assert!(decode_sel_offer(&bytes).is_err());
}

#[test]
fn sel_offer_rejects_duplicate_mime() {
    let bytes = raw_sel(&SelWire {
        n: 2,
        descs: &[(10, 0), (10, 0)],
        mimes: &[b"text/plain", b"text/plain"],
        ..Default::default()
    });
    assert!(decode_sel_offer(&bytes).is_err());
}

#[test]
fn sel_offer_rejects_mime_outside_allowlist() {
    let bytes = raw_sel(&SelWire {
        n: 1,
        descs: &[(9, 0)],
        mimes: &[b"text/html"],
        ..Default::default()
    });
    assert!(decode_sel_offer(&bytes).is_err());
}

#[test]
fn sel_offer_rejects_empty_with_nonzero_total() {
    let bytes = raw_sel(&SelWire {
        n: 0,
        total_len: 5,
        ..Default::default()
    });
    assert!(decode_sel_offer(&bytes).is_err());
}

#[test]
fn sel_chunk_round_trip() {
    let chunk = SelChunk {
        serial: 7,
        mime_idx: 1,
        flags: SEL_FLAG_FINAL,
        data: b"payload".to_vec(),
    };
    let bytes = encode_sel_chunk(&chunk).expect("encode");
    let got = decode_sel_chunk(&bytes).expect("decode");
    assert_eq!(got, chunk);
    assert!(got.is_final());
}

#[test]
fn sel_chunk_rejects_oversize_len() {
    let mut bytes = Vec::new();
    for field in [0u32, 0, 0, SEL_CHUNK_MAX + 1] {
        bytes.extend_from_slice(&field.to_le_bytes());
    }
    assert!(decode_sel_chunk(&bytes).is_err());
}

#[test]
fn sel_read_round_trip() {
    let msg = SelRead {
        serial: 5,
        mime: "text/plain".into(),
        cancel: false,
    };
    let bytes = serde_json::to_vec(&msg).expect("encode");
    assert_eq!(decode_sel_read(&bytes).expect("decode"), msg);
}

#[test]
fn cursor_round_trip() {
    let cur = CursorImage {
        win: 1,
        w: 2,
        h: 2,
        hotspot_x: 1,
        hotspot_y: 1,
        scale_e12: 4096,
        pixels: vec![0xAB; 16],
    };
    let bytes = encode_cursor_image(&cur).expect("encode");
    assert_eq!(decode_cursor_image(&bytes).expect("decode"), cur);
}

#[test]
fn cursor_rejects_zero_width() {
    let bytes = raw_cursor(&CursorWire {
        w: 0,
        h: 2,
        ..Default::default()
    });
    assert!(decode_cursor_image(&bytes).is_err());
}

#[test]
fn cursor_rejects_over_max_dim() {
    let bytes = raw_cursor(&CursorWire {
        w: 513,
        h: 2,
        ..Default::default()
    });
    assert!(decode_cursor_image(&bytes).is_err());
}

#[test]
fn cursor_rejects_hotspot_beyond_bounds() {
    let bytes = raw_cursor(&CursorWire {
        w: 2,
        h: 2,
        hx: 2,
        pixels: &[0; 16],
        ..Default::default()
    });
    assert!(decode_cursor_image(&bytes).is_err());
}

#[test]
fn cursor_rejects_pixel_length_mismatch() {
    let bytes = raw_cursor(&CursorWire {
        w: 2,
        h: 2,
        pixels: &[0; 8],
        ..Default::default()
    });
    assert!(decode_cursor_image(&bytes).is_err());
}

#[test]
fn set_layout_round_trip() {
    let msg = SetLayout {
        layout: "us".into(),
        variant: "intl".into(),
    };
    let bytes = serde_json::to_vec(&msg).expect("encode");
    assert_eq!(decode_set_layout(&bytes).expect("decode"), msg);
}

#[test]
fn set_layout_rejects_slash() {
    let json = br#"{"layout":"us/intl","variant":""}"#;
    assert!(decode_set_layout(json).is_err());
}

#[test]
fn error_round_trip() {
    let msg = ErrorMsg {
        code: ErrorCode::OversizeFrame,
        reason: "frame too large".into(),
    };
    let bytes = serde_json::to_vec(&msg).expect("encode");
    assert_eq!(decode_error(&bytes).expect("decode"), msg);
}

#[test]
fn error_reason_control_chars_are_stripped() {
    let msg = ErrorMsg {
        code: ErrorCode::Policy,
        reason: "denied\u{a}".into(),
    };
    let bytes = serde_json::to_vec(&msg).expect("encode");
    let got = decode_error(&bytes).expect("decode");
    assert_eq!(got.reason, "denied");
}

#[test]
fn error_rejects_unknown_code() {
    let json = br#"{"code":"nope","reason":"x"}"#;
    assert!(decode_error(json).is_err());
}

#[test]
fn text_input_state_round_trip() {
    let msg = TextInputState {
        win: 1,
        serial: 4,
        enabled: true,
        surrounding: Some(Surrounding {
            text: "hello".into(),
            cursor: 5,
            anchor: 5,
        }),
        change_cause: 0,
        content_hint: 1,
        content_purpose: 2,
        cursor_rect: Some(msl_way::remote::CursorRect {
            x: 1,
            y: 2,
            w: 3,
            h: 4,
        }),
    };
    let bytes = serde_json::to_vec(&msg).expect("encode");
    assert_eq!(decode_text_input_state(&bytes).expect("decode"), msg);
}

#[test]
fn text_input_state_rejects_oversize_text() {
    let msg = TextInputState {
        win: 1,
        serial: 1,
        enabled: true,
        surrounding: Some(Surrounding {
            text: "a".repeat(TEXT_FIELD_MAX + 1),
            cursor: 0,
            anchor: 0,
        }),
        change_cause: 0,
        content_hint: 0,
        content_purpose: 0,
        cursor_rect: None,
    };
    let bytes = serde_json::to_vec(&msg).expect("encode");
    assert!(decode_text_input_state(&bytes).is_err());
}

#[test]
fn text_input_state_rejects_cursor_past_end() {
    let json = concat!(
        r#"{"win":1,"serial":1,"enabled":true,"change_cause":0,"content_hint":0,"#,
        r#""content_purpose":0,"surrounding":{"text":"hi","cursor":3,"anchor":0}}"#
    );
    assert!(decode_text_input_state(json.as_bytes()).is_err());
}

#[test]
fn text_input_apply_round_trip() {
    let msg = TextInputApply {
        win: 2,
        serial: 9,
        preedit: Some(Preedit {
            text: "abc".into(),
            cursor_begin: 0,
            cursor_end: 3,
        }),
        commit_text: Some("done".into()),
        delete_before: 1,
        delete_after: 0,
    };
    let bytes = serde_json::to_vec(&msg).expect("encode");
    assert_eq!(decode_text_input_apply(&bytes).expect("decode"), msg);
}

#[test]
fn text_input_apply_rejects_oversize_commit() {
    let msg = TextInputApply {
        win: 1,
        serial: 1,
        preedit: None,
        commit_text: Some("a".repeat(TEXT_FIELD_MAX + 1)),
        delete_before: 0,
        delete_after: 0,
    };
    let bytes = serde_json::to_vec(&msg).expect("encode");
    assert!(decode_text_input_apply(&bytes).is_err());
}

#[test]
fn parse_host_still_tolerates_v5_host_opcodes() {
    let f = Frame {
        msg_type: T_HOST_SEL,
        flags: 0,
        payload: Vec::new(),
    };
    assert_eq!(parse_host(&f).expect("parse"), HostMsg::Unknown(T_HOST_SEL));
}

#[test]
fn sel_offer_rejects_mime_len_over_128() {
    let bytes = raw_sel(&SelWire {
        n: 1,
        descs: &[(SEL_MAX_MIME_LEN + 1, 0)],
        ..Default::default()
    });
    assert!(decode_sel_offer(&bytes).is_err());
}

#[test]
fn sel_offer_rejects_streamed_trailing_payload() {
    let bytes = raw_sel(&SelWire {
        n: 1,
        flags: 0,
        total_len: 5,
        descs: &[(10, 5)],
        mimes: &[b"text/plain"],
        payloads: &[b"hello"],
        ..Default::default()
    });
    assert!(decode_sel_offer(&bytes).is_err());
}

#[test]
fn sel_offer_rejects_short_prefix() {
    assert!(decode_sel_offer(&[0u8; 10]).is_err());
}

#[test]
fn sel_offer_rejects_short_descriptor() {
    let bytes = raw_sel(&SelWire {
        n: 2,
        descs: &[(10, 0)],
        ..Default::default()
    });
    assert!(decode_sel_offer(&bytes).is_err());
}

#[test]
fn sel_chunk_rejects_trailing_bytes() {
    let chunk = SelChunk {
        serial: 1,
        mime_idx: 0,
        flags: 0,
        data: b"hi".to_vec(),
    };
    let mut bytes = encode_sel_chunk(&chunk).expect("encode");
    bytes.push(0);
    assert!(decode_sel_chunk(&bytes).is_err());
}

#[test]
fn set_layout_rejects_long_token() {
    let long = "a".repeat(65);
    let json = format!(r#"{{"layout":"{long}","variant":""}}"#);
    assert!(decode_set_layout(json.as_bytes()).is_err());
}

#[test]
fn error_reason_capped_at_256() {
    let msg = ErrorMsg {
        code: ErrorCode::Policy,
        reason: "a".repeat(ERR_REASON_MAX + 100),
    };
    let bytes = serde_json::to_vec(&msg).expect("encode");
    let got = decode_error(&bytes).expect("decode");
    assert_eq!(got.reason.len(), ERR_REASON_MAX);
}

#[test]
fn win_new_control_chars_in_app_id_stripped() {
    let msg = WinNewFull {
        win: 1,
        app_id: "a\u{1}b".into(),
        title: "t".into(),
        w: 1,
        h: 1,
        scale: 1.0,
        x11: None,
        pid: None,
        class: None,
        instance: None,
        transient_for: None,
        modal: None,
    };
    let bytes = serde_json::to_vec(&msg).expect("encode");
    assert_eq!(decode_win_new(&bytes).expect("decode").app_id, "ab");
}

#[test]
fn win_new_control_chars_in_instance_stripped() {
    let msg = WinNewFull {
        win: 1,
        app_id: "a".into(),
        title: "t".into(),
        w: 1,
        h: 1,
        scale: 1.0,
        x11: None,
        pid: None,
        class: None,
        instance: Some("x\u{2}y".into()),
        transient_for: None,
        modal: None,
    };
    let bytes = serde_json::to_vec(&msg).expect("encode");
    assert_eq!(
        decode_win_new(&bytes).expect("decode").instance.as_deref(),
        Some("xy")
    );
}

#[test]
fn text_input_apply_rejects_oversize_preedit() {
    let msg = TextInputApply {
        win: 1,
        serial: 1,
        preedit: Some(Preedit {
            text: "a".repeat(TEXT_FIELD_MAX + 1),
            cursor_begin: 0,
            cursor_end: 0,
        }),
        commit_text: None,
        delete_before: 0,
        delete_after: 0,
    };
    let bytes = serde_json::to_vec(&msg).expect("encode");
    assert!(decode_text_input_apply(&bytes).is_err());
}

#[test]
fn text_input_apply_rejects_preedit_cursor_outside() {
    let msg = TextInputApply {
        win: 1,
        serial: 1,
        preedit: Some(Preedit {
            text: "ab".into(),
            cursor_begin: 0,
            cursor_end: 5,
        }),
        commit_text: None,
        delete_before: 0,
        delete_after: 0,
    };
    let bytes = serde_json::to_vec(&msg).expect("encode");
    assert!(decode_text_input_apply(&bytes).is_err());
}

#[test]
fn text_input_state_rejects_zero_rect_dim() {
    let json = concat!(
        r#"{"win":1,"serial":1,"enabled":true,"change_cause":0,"content_hint":0,"#,
        r#""content_purpose":0,"cursor_rect":{"x":0,"y":0,"w":0,"h":4}}"#
    );
    assert!(decode_text_input_state(json.as_bytes()).is_err());
}

#[test]
fn text_input_state_rejects_rect_out_of_range() {
    let json = concat!(
        r#"{"win":1,"serial":1,"enabled":true,"change_cause":0,"content_hint":0,"#,
        r#""content_purpose":0,"cursor_rect":{"x":20000,"y":0,"w":3,"h":4}}"#
    );
    assert!(decode_text_input_state(json.as_bytes()).is_err());
}

#[test]
fn text_input_state_accepts_valid_rect() {
    let msg = TextInputState {
        win: 1,
        serial: 1,
        enabled: true,
        surrounding: None,
        change_cause: 0,
        content_hint: 0,
        content_purpose: 0,
        cursor_rect: Some(CursorRect {
            x: -100,
            y: 200,
            w: 2,
            h: 18,
        }),
    };
    let bytes = serde_json::to_vec(&msg).expect("encode");
    assert_eq!(decode_text_input_state(&bytes).expect("decode"), msg);
}

#[test]
fn cursor_rejects_zero_height() {
    let bytes = raw_cursor(&CursorWire {
        w: 2,
        h: 0,
        ..Default::default()
    });
    assert!(decode_cursor_image(&bytes).is_err());
}

#[test]
fn cursor_rejects_height_over_max() {
    let bytes = raw_cursor(&CursorWire {
        w: 2,
        h: 513,
        ..Default::default()
    });
    assert!(decode_cursor_image(&bytes).is_err());
}

#[test]
fn cursor_rejects_hotspot_y_beyond_bounds() {
    let bytes = raw_cursor(&CursorWire {
        w: 2,
        h: 2,
        hy: 2,
        pixels: &[0; 16],
        ..Default::default()
    });
    assert!(decode_cursor_image(&bytes).is_err());
}

#[test]
fn sel_offer_encode_rejects_inline_over_64k() {
    let offer = SelOffer {
        serial: 1,
        origin: 1,
        flags: SEL_FLAG_INLINE,
        total_len: SEL_INLINE_MAX + 1,
        entries: vec![SelEntry {
            mime: "text/plain".into(),
            data_len: u32::try_from(SEL_INLINE_MAX + 1).unwrap(),
            data: vec![0u8; usize::try_from(SEL_INLINE_MAX + 1).unwrap()],
        }],
    };
    assert!(encode_sel_offer(&offer).is_err());
}

#[test]
fn sel_offer_encode_rejects_streamed_over_32m() {
    let offer = SelOffer {
        serial: 1,
        origin: 1,
        flags: 0,
        total_len: SEL_STREAM_MAX + 1,
        entries: vec![SelEntry {
            mime: "image/png".into(),
            data_len: u32::try_from(SEL_STREAM_MAX + 1).unwrap(),
            data: Vec::new(),
        }],
    };
    assert!(encode_sel_offer(&offer).is_err());
}
