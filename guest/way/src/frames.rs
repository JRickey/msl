//! Commit pipeline and the load-bearing frame-pacing rule (ADR 0011, protocol v0).
//!
//! The pure pieces here — the [`Pacing`] state machine and [`pack_damage`] — are
//! host-testable; the Smithay buffer plumbing that feeds them is guest-only.

use crate::remote::{MAX_COMMIT_RECTS, Rect};

pub const FRAME_STARVATION_NS: u64 = 50_000_000;

/// A committed shm frame copied out of the client's pool.
///
/// The full buffer region plus its geometry, kept so a coalesced or reconnect
/// commit can re-pack any damage rect after the `wl_buffer` has been released.
#[derive(Debug, Clone)]
pub struct FullBuffer {
    pub w: u32,
    pub h: u32,
    pub stride: u32,
    pub format: u32,
    pub bytes: Vec<u8>,
}

/// Accumulated damage across coalesced commits. Collapses to a whole-surface
/// repaint once the unioned rects would exceed the protocol ceiling or any
/// contributing commit was itself full.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Damageset {
    pub full: bool,
    pub rects: Vec<Rect>,
}

impl Damageset {
    #[must_use]
    pub const fn full() -> Self {
        Self {
            full: true,
            rects: Vec::new(),
        }
    }

    pub fn union(&mut self, full: bool, rects: &[Rect]) {
        debug_assert!(
            self.rects.len() <= MAX_COMMIT_RECTS as usize,
            "damage set already over ceiling"
        );
        let ceiling = MAX_COMMIT_RECTS as usize;
        if self.full || full || self.rects.len().saturating_add(rects.len()) > ceiling {
            self.full = true;
            self.rects.clear();
            return;
        }
        self.rects.extend_from_slice(rects);
    }
}

/// The outcome of an ack or starvation poll for a window's pacing.
#[derive(Debug, PartialEq, Eq)]
pub enum Release {
    /// Stale/duplicate ack or deadline not reached — nothing to do.
    None,
    /// The in-flight present released with no commit queued behind it.
    Idle,
    /// Released; the caller must emit exactly one coalesced commit with this
    /// accumulated damage.
    Flush(Damageset),
}

/// Per-window frame pacing.
///
/// Holds `wl_surface.frame` callbacks and defers commits while a present is
/// un-acked, so at most one present is in flight; a matching `present_ack` (or a
/// 50 ms starvation deadline) releases and flushes one coalesced commit.
#[derive(Debug)]
pub struct Pacing {
    in_flight: Option<u32>,
    deadline_ns: u64,
    fallback_ns: u64,
    pending: bool,
    pending_damage: Damageset,
}

impl Pacing {
    #[must_use]
    pub fn new(fallback_ns: u64) -> Self {
        debug_assert!(fallback_ns > 0, "starvation fallback must be positive");
        Self {
            in_flight: None,
            deadline_ns: 0,
            fallback_ns,
            pending: false,
            pending_damage: Damageset::default(),
        }
    }

    #[must_use]
    pub const fn wants_emit(&self) -> bool {
        self.in_flight.is_none()
    }

    #[must_use]
    pub const fn in_flight(&self) -> bool {
        self.in_flight.is_some()
    }

    /// Record that present `seq` was just emitted; arm the starvation deadline.
    pub fn present_now(&mut self, seq: u32, now_ns: u64) {
        debug_assert!(self.in_flight.is_none(), "present while one is in flight");
        debug_assert!(self.fallback_ns > 0, "fallback window not initialized");
        self.in_flight = Some(seq);
        self.deadline_ns = now_ns.saturating_add(self.fallback_ns);
    }

    /// A commit arrived while a present is in flight: coalesce its damage.
    pub fn defer(&mut self, full: bool, rects: &[Rect]) {
        debug_assert!(
            self.in_flight.is_some(),
            "defer without an in-flight present"
        );
        self.pending = true;
        self.pending_damage.union(full, rects);
    }

    /// A `present_ack`: release only when it matches the in-flight present.
    #[must_use]
    pub fn on_ack(&mut self, seq: u32) -> Release {
        match self.in_flight {
            Some(f) if f == seq => {
                self.in_flight = None;
                self.take_release()
            }
            _ => Release::None,
        }
    }

    /// Timer poll: release once the starvation deadline passes with no ack.
    #[must_use]
    pub fn poll_deadline(&mut self, now_ns: u64) -> Release {
        debug_assert!(self.fallback_ns > 0, "fallback window not initialized");
        match self.in_flight {
            Some(_) if now_ns >= self.deadline_ns => {
                self.in_flight = None;
                self.take_release()
            }
            _ => Release::None,
        }
    }

    /// Drop all pacing state on host disconnect; a fresh host re-drives paces.
    pub fn reset(&mut self) {
        debug_assert!(self.fallback_ns > 0, "fallback window not initialized");
        self.in_flight = None;
        self.pending = false;
        self.pending_damage = Damageset::default();
    }

    fn take_release(&mut self) -> Release {
        debug_assert!(self.in_flight.is_none(), "release left a present in flight");
        if self.pending {
            self.pending = false;
            Release::Flush(std::mem::take(&mut self.pending_damage))
        } else {
            Release::Idle
        }
    }
}

/// Row-pack each damage rect from an shm buffer into rect-order bytes. Returns
/// `None` when any rect leaves the buffer so the caller can fall back to a
/// full-surface copy rather than read out of bounds.
#[must_use]
pub fn pack_damage(
    data: &[u8],
    stride: usize,
    bpp: usize,
    buf_w: u32,
    buf_h: u32,
    rects: &[Rect],
) -> Option<Vec<u8>> {
    debug_assert!(bpp > 0, "bytes-per-pixel must be positive");
    debug_assert!(
        stride >= (buf_w as usize).saturating_mul(bpp),
        "stride under row width"
    );
    let mut total: usize = 0;
    for r in rects {
        if r.x.checked_add(r.w)? > buf_w || r.y.checked_add(r.h)? > buf_h {
            return None;
        }
        let row = (r.w as usize).checked_mul(bpp)?;
        total = total.checked_add(row.checked_mul(r.h as usize)?)?;
    }
    if stride.checked_mul(buf_h as usize)? > data.len() {
        return None;
    }
    let mut out = Vec::with_capacity(total);
    for r in rects {
        let row_bytes = (r.w as usize) * bpp;
        for y in r.y..r.y.checked_add(r.h)? {
            let start = (y as usize) * stride + (r.x as usize) * bpp;
            out.extend_from_slice(&data[start..start + row_bytes]);
        }
    }
    debug_assert_eq!(out.len(), total, "packed length diverged from plan");
    Some(out)
}

#[cfg(target_os = "linux")]
mod linux {
    use smithay::reexports::wayland_server::protocol::wl_buffer::WlBuffer;
    use smithay::reexports::wayland_server::protocol::wl_callback::WlCallback;
    use smithay::reexports::wayland_server::protocol::wl_shm;
    use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
    use smithay::utils::SERIAL_COUNTER;
    use smithay::wayland::compositor::{BufferAssignment, Damage, SurfaceAttributes, with_states};
    use smithay::wayland::shm::with_buffer_contents;

    use super::{Damageset, FullBuffer, Rect, Release, pack_damage};
    use crate::comp::{State, read_toplevel_app_id, read_toplevel_title};
    use crate::remote::{
        CommitMeta, FMT_ARGB8888, FMT_XRGB8888, MAX_COMMIT_RECTS, T_COMMIT, T_WIN_MAP, T_WIN_NEW,
        T_WIN_TITLE, T_WIN_UNMAP, WinNew, WinRef, WinTitle, encode_commit,
    };

    const BPP: usize = 4;
    const BPP_U32: u32 = 4;

    struct Extracted {
        buffer: Option<BufferAssignment>,
        damage: Vec<Damage>,
        callbacks: Vec<WlCallback>,
    }

    fn extract(surface: &WlSurface) -> Extracted {
        with_states(surface, |states| {
            let mut cached = states.cached_state.get::<SurfaceAttributes>();
            let attrs = cached.current();
            let callbacks: Vec<WlCallback> = attrs.frame_callbacks.drain(..).collect();
            let buffer = attrs.buffer.take();
            let damage = std::mem::take(&mut attrs.damage);
            drop(cached);
            Extracted {
                buffer,
                damage,
                callbacks,
            }
        })
    }

    fn fire(state: &State, callbacks: Vec<WlCallback>) {
        let t = state.now_ms();
        for cb in callbacks {
            cb.done(t);
        }
    }

    const fn format_code(fmt: wl_shm::Format) -> Option<u32> {
        match fmt {
            wl_shm::Format::Xrgb8888 => Some(FMT_XRGB8888),
            wl_shm::Format::Argb8888 => Some(FMT_ARGB8888),
            _ => None,
        }
    }

    fn clamp_rect(
        rect: smithay::utils::Rectangle<i32, smithay::utils::Buffer>,
        bw: u32,
        bh: u32,
    ) -> Rect {
        let x = u32::try_from(rect.loc.x.max(0)).unwrap_or(0).min(bw);
        let y = u32::try_from(rect.loc.y.max(0)).unwrap_or(0).min(bh);
        let w = u32::try_from(rect.size.w.max(0)).unwrap_or(0).min(bw - x);
        let h = u32::try_from(rect.size.h.max(0)).unwrap_or(0).min(bh - y);
        Rect { x, y, w, h }
    }

    fn damage_rects(damage: &[Damage], w: u32, h: u32) -> Option<Vec<Rect>> {
        debug_assert!(w > 0 && h > 0, "buffer dimensions must be positive");
        if damage.is_empty() {
            return None;
        }
        let mut out = Vec::with_capacity(damage.len());
        for d in damage {
            match d {
                Damage::Buffer(r) => out.push(clamp_rect(*r, w, h)),
                Damage::Surface(_) => return None,
            }
        }
        Some(out)
    }

    #[allow(unsafe_code)]
    fn read_full_buffer(buf: &WlBuffer) -> Option<FullBuffer> {
        with_buffer_contents(buf, |ptr, len, data| {
            let w = u32::try_from(data.width).ok()?;
            let h = u32::try_from(data.height).ok()?;
            let stride = u32::try_from(data.stride).ok()?;
            let offset = usize::try_from(data.offset).ok()?;
            let format = format_code(data.format)?;
            if w == 0 || h == 0 || stride < w.checked_mul(BPP_U32)? {
                return None;
            }
            let end = offset.checked_add((stride as usize).checked_mul(h as usize)?)?;
            if end > len {
                return None;
            }
            // SAFETY: `ptr`/`len` describe a client shm pool mapping Smithay handed
            // us for the duration of this closure — the exempt C-ABI boundary. We
            // copy the bounds-checked [offset, end) window out immediately; no
            // reference escapes and we never write it.
            let pool = unsafe { std::slice::from_raw_parts(ptr, len) };
            Some(FullBuffer {
                w,
                h,
                stride,
                format,
                bytes: pool[offset..end].to_vec(),
            })
        })
        .ok()
        .flatten()
    }

    fn damage_set(damage: &[Damage], w: u32, h: u32, full: bool) -> Damageset {
        debug_assert!(w > 0 && h > 0, "buffer dimensions must be positive");
        if full {
            return Damageset::full();
        }
        match damage_rects(damage, w, h) {
            Some(r) if r.len() <= MAX_COMMIT_RECTS as usize => Damageset {
                full: false,
                rects: r,
            },
            _ => Damageset::full(),
        }
    }

    fn announce_and_map(state: &mut State, win: u32, surface: &WlSurface, w: u32, h: u32) {
        debug_assert!(win != 0, "window id 0 is reserved");
        debug_assert!(w > 0 && h > 0, "announcing a zero-sized window");
        let announced = state.windows.get(&win).is_some_and(|x| x.announced);
        if !announced {
            let app_id = read_toplevel_app_id(surface);
            let title = read_toplevel_title(surface);
            if let Some(x) = state.windows.get_mut(&win) {
                x.app_id.clone_from(&app_id);
                x.title.clone_from(&title);
                x.size = (w, h);
                x.announced = true;
            }
            let msg = WinNew {
                win,
                app_id,
                title,
                w,
                h,
                scale: state.scale,
            };
            let payload = serde_json::to_vec(&msg).unwrap_or_default();
            state.enqueue(T_WIN_NEW, payload);
        }
        let mapped = state.windows.get(&win).is_some_and(|x| x.mapped);
        if !mapped {
            if let Some(x) = state.windows.get_mut(&win) {
                x.mapped = true;
            }
            let payload = serde_json::to_vec(&WinRef { win }).unwrap_or_default();
            state.enqueue(T_WIN_MAP, payload);
            let serial = SERIAL_COUNTER.next_serial();
            let kbd = state.keyboard.clone();
            kbd.set_focus(state, Some(surface.clone()), serial);
        }
    }

    fn unmap(state: &mut State, win: u32) {
        let was = state.windows.get(&win).is_some_and(|x| x.mapped);
        if was {
            if let Some(x) = state.windows.get_mut(&win) {
                x.mapped = false;
            }
            let payload = serde_json::to_vec(&WinRef { win }).unwrap_or_default();
            state.enqueue(T_WIN_UNMAP, payload);
        }
    }

    fn scale_e12(scale: f64) -> u32 {
        if !scale.is_finite() || scale <= 0.0 {
            return 4096;
        }
        let v = (scale.clamp(0.0, 16.0) * 4096.0).round();
        // v is bounded to [0, 65536] by the clamp above, so the cast is exact.
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        let e = v as u32;
        e
    }

    fn commit_rects(dmg: &Damageset, w: u32, h: u32) -> Vec<Rect> {
        if dmg.full || dmg.rects.is_empty() {
            vec![Rect { x: 0, y: 0, w, h }]
        } else {
            dmg.rects.clone()
        }
    }

    fn emit_snapshot(
        state: &mut State,
        win: u32,
        surface: &WlSurface,
        fb: &FullBuffer,
        dmg: &Damageset,
        t_commit: u64,
    ) -> bool {
        debug_assert!(win != 0, "window id 0 is reserved");
        debug_assert!(fb.w > 0 && fb.h > 0, "emitting a zero-sized frame");
        announce_and_map(state, win, surface, fb.w, fb.h);
        let rects = commit_rects(dmg, fb.w, fb.h);
        let Some(packed) = pack_damage(&fb.bytes, fb.stride as usize, BPP, fb.w, fb.h, &rects)
        else {
            return false;
        };
        let seq = state.next_seq();
        let t_send = state.now_ns();
        let meta = CommitMeta {
            win,
            seq,
            w: fb.w,
            h: fb.h,
            stride: fb.stride,
            format: fb.format,
            scale_e12: scale_e12(state.scale),
            t_client_commit_ns: t_commit,
            t_send_ns: t_send,
        };
        let Ok(payload) = encode_commit(&meta, &rects, &packed) else {
            return false;
        };
        state.enqueue(T_COMMIT, payload);
        state.ledger.record(win, seq, t_commit, t_send);
        if let Some(x) = state.windows.get_mut(&win) {
            x.prev_buffer_size = (fb.w, fb.h);
            x.pacing.present_now(seq, t_send);
        }
        true
    }

    fn ingest_commit(
        state: &mut State,
        win: u32,
        surface: &WlSurface,
        fb: FullBuffer,
        damage: &[Damage],
        callbacks: Vec<WlCallback>,
        t_commit: u64,
    ) {
        debug_assert!(win != 0, "window id 0 is reserved");
        debug_assert!(
            state.windows.contains_key(&win),
            "commit for unknown window"
        );
        let announced = state.windows.get(&win).is_some_and(|x| x.announced);
        let prev = state
            .windows
            .get(&win)
            .map_or((0, 0), |x| x.prev_buffer_size);
        let full = !announced || prev != (fb.w, fb.h);
        let dmg = damage_set(damage, fb.w, fb.h, full);
        let wants = state
            .windows
            .get(&win)
            .is_some_and(|x| x.pacing.wants_emit());
        if wants {
            let emitted = emit_snapshot(state, win, surface, &fb, &dmg, t_commit);
            if emitted {
                if let Some(x) = state.windows.get_mut(&win) {
                    x.last_frame = Some(fb);
                    x.held_callbacks.extend(callbacks);
                }
            } else {
                fire(state, callbacks);
            }
        } else if let Some(x) = state.windows.get_mut(&win) {
            x.pacing.defer(dmg.full, &dmg.rects);
            x.pending = Some(fb);
            x.pending_t_commit = t_commit;
            x.held_callbacks.extend(callbacks);
        }
    }

    pub fn on_commit(state: &mut State, surface: &WlSurface) {
        let t_commit = state.now_ns();
        let Some(win) = state.win_id_of(surface) else {
            return;
        };
        let ex = extract(surface);
        match ex.buffer {
            Some(BufferAssignment::Removed) => {
                unmap(state, win);
                fire(state, ex.callbacks);
            }
            None => fire(state, ex.callbacks),
            Some(BufferAssignment::NewBuffer(buf)) => {
                let snap = read_full_buffer(&buf);
                buf.release();
                match snap {
                    Some(fb) => {
                        ingest_commit(state, win, surface, fb, &ex.damage, ex.callbacks, t_commit);
                    }
                    None => fire(state, ex.callbacks),
                }
            }
        }
    }

    fn do_release(state: &mut State, win: u32, rel: Release) {
        debug_assert!(win != 0, "release for reserved window id 0");
        match rel {
            Release::None => {}
            Release::Idle => release_callbacks(state, win),
            Release::Flush(dmg) => {
                release_callbacks(state, win);
                flush_pending(state, win, &dmg);
            }
        }
    }

    fn flush_pending(state: &mut State, win: u32, dmg: &Damageset) {
        debug_assert!(win != 0, "flush for reserved window id 0");
        let surface = state.windows.get(&win).map(|x| x.surface.clone());
        let taken = state
            .windows
            .get_mut(&win)
            .and_then(|x| x.pending.take().map(|fb| (fb, x.pending_t_commit)));
        let (Some(surface), Some((fb, t_commit))) = (surface, taken) else {
            return;
        };
        if emit_snapshot(state, win, &surface, &fb, dmg, t_commit)
            && let Some(x) = state.windows.get_mut(&win)
        {
            x.last_frame = Some(fb);
        }
    }

    pub fn on_present_ack(state: &mut State, win: u32, seq: u32, t_recv: u64, t_present: u64) {
        debug_assert!(win != 0, "present_ack for reserved window id 0");
        debug_assert!(t_present >= t_recv, "present precedes host recv");
        let _ = state.ledger.merge_present_ack(win, seq, t_recv, t_present);
        let rel = state
            .windows
            .get_mut(&win)
            .map_or(Release::None, |x| x.pacing.on_ack(seq));
        do_release(state, win, rel);
    }

    pub fn poll_pacing(state: &mut State, now_ns: u64) {
        let wins: Vec<u32> = state.windows.keys().copied().collect();
        for win in wins {
            let rel = state
                .windows
                .get_mut(&win)
                .map_or(Release::None, |x| x.pacing.poll_deadline(now_ns));
            do_release(state, win, rel);
        }
    }

    fn release_callbacks(state: &mut State, win: u32) {
        let cbs = state
            .windows
            .get_mut(&win)
            .map(|x| std::mem::take(&mut x.held_callbacks))
            .unwrap_or_default();
        fire(state, cbs);
    }

    /// Re-drive every live mapped toplevel to a freshly-connected host.
    ///
    /// Fires held callbacks, resets pacing/announce state, replays
    /// `win_new`/`win_map`/`win_title`, and pushes a full-damage commit of the
    /// last frame so the new presenter has pixels.
    pub fn replay_all(state: &mut State) {
        let wins: Vec<u32> = state.windows.keys().copied().collect();
        for win in wins {
            replay_window(state, win);
        }
    }

    fn replay_window(state: &mut State, win: u32) {
        debug_assert!(win != 0, "reserved window id 0 in registry");
        let info = state.windows.get(&win).map(|x| {
            (
                x.mapped,
                x.app_id.clone(),
                x.title.clone(),
                x.size,
                x.surface.clone(),
            )
        });
        let Some((mapped, app_id, title, size, surface)) = info else {
            return;
        };
        let held = state
            .windows
            .get_mut(&win)
            .map(|x| std::mem::take(&mut x.held_callbacks))
            .unwrap_or_default();
        fire(state, held);
        if let Some(x) = state.windows.get_mut(&win) {
            x.pacing.reset();
            x.pending = None;
            x.pending_t_commit = 0;
            x.announced = false;
            x.mapped = false;
            x.prev_buffer_size = (0, 0);
        }
        if mapped {
            replay_mapped(state, win, &surface, &app_id, &title, size);
        }
    }

    fn replay_mapped(
        state: &mut State,
        win: u32,
        surface: &WlSurface,
        app_id: &str,
        title: &str,
        size: (u32, u32),
    ) {
        debug_assert!(win != 0, "reserved window id 0 in replay");
        let msg = WinNew {
            win,
            app_id: app_id.to_owned(),
            title: title.to_owned(),
            w: size.0,
            h: size.1,
            scale: state.scale,
        };
        state.enqueue(T_WIN_NEW, serde_json::to_vec(&msg).unwrap_or_default());
        state.enqueue(
            T_WIN_MAP,
            serde_json::to_vec(&WinRef { win }).unwrap_or_default(),
        );
        if !title.is_empty() {
            let t = WinTitle {
                win,
                title: title.to_owned(),
            };
            state.enqueue(T_WIN_TITLE, serde_json::to_vec(&t).unwrap_or_default());
        }
        if let Some(x) = state.windows.get_mut(&win) {
            x.announced = true;
            x.mapped = true;
        }
        let last = state.windows.get(&win).and_then(|x| x.last_frame.clone());
        if let Some(fb) = last {
            let t = state.now_ns();
            let _ = emit_snapshot(state, win, surface, &fb, &Damageset::full(), t);
        }
    }
}

#[cfg(target_os = "linux")]
pub use linux::{on_commit, on_present_ack, poll_pacing, replay_all};

#[cfg(test)]
mod tests {
    use super::*;

    fn rect(x: u32, y: u32, w: u32, h: u32) -> Rect {
        Rect { x, y, w, h }
    }

    #[test]
    fn emit_then_matching_ack_releases_idle_once() {
        let mut p = Pacing::new(FRAME_STARVATION_NS);
        assert!(p.wants_emit());
        p.present_now(5, 1_000);
        assert!(!p.wants_emit(), "one present in flight blocks emit");
        assert_eq!(p.on_ack(5), Release::Idle);
        assert!(p.wants_emit());
        assert_eq!(p.on_ack(5), Release::None, "duplicate ack ignored");
    }

    #[test]
    fn wrong_seq_ack_holds() {
        let mut p = Pacing::new(FRAME_STARVATION_NS);
        p.present_now(5, 0);
        assert_eq!(p.on_ack(4), Release::None);
        assert!(p.in_flight(), "stale ack must not release");
    }

    #[test]
    fn commit_while_awaiting_defers_and_ack_flushes_one_coalesced_frame() {
        let mut p = Pacing::new(FRAME_STARVATION_NS);
        p.present_now(1, 0);
        p.defer(false, &[rect(0, 0, 2, 2)]);
        p.defer(false, &[rect(2, 0, 2, 2)]);
        let rel = p.on_ack(1);
        match rel {
            Release::Flush(d) => {
                assert!(!d.full, "small damage should stay rect-listed");
                assert_eq!(
                    d.rects,
                    vec![rect(0, 0, 2, 2), rect(2, 0, 2, 2)],
                    "damage unions"
                );
            }
            other => panic!("expected one coalesced flush, got {other:?}"),
        }
        assert_eq!(
            p.on_ack(1),
            Release::None,
            "only one flush per in-flight present"
        );
    }

    #[test]
    fn deferred_full_damage_collapses_to_full() {
        let mut p = Pacing::new(FRAME_STARVATION_NS);
        p.present_now(1, 0);
        p.defer(false, &[rect(0, 0, 1, 1)]);
        p.defer(true, &[]);
        match p.on_ack(1) {
            Release::Flush(d) => {
                assert!(d.full);
                assert!(d.rects.is_empty());
            }
            other => panic!("expected full flush, got {other:?}"),
        }
    }

    #[test]
    fn starvation_flushes_pending_then_idles() {
        let mut p = Pacing::new(FRAME_STARVATION_NS);
        p.present_now(1, 0);
        p.defer(false, &[rect(0, 0, 4, 4)]);
        assert_eq!(p.poll_deadline(FRAME_STARVATION_NS - 1), Release::None);
        assert!(matches!(
            p.poll_deadline(FRAME_STARVATION_NS),
            Release::Flush(_)
        ));
        p.present_now(2, 0);
        assert_eq!(
            p.poll_deadline(FRAME_STARVATION_NS),
            Release::Idle,
            "no pending -> idle"
        );
    }

    #[test]
    fn ack_before_deadline_suppresses_fallback() {
        let mut p = Pacing::new(FRAME_STARVATION_NS);
        p.present_now(7, 0);
        assert_eq!(p.on_ack(7), Release::Idle);
        assert_eq!(p.poll_deadline(FRAME_STARVATION_NS + 1), Release::None);
    }

    #[test]
    fn reset_clears_inflight_and_pending() {
        let mut p = Pacing::new(FRAME_STARVATION_NS);
        p.present_now(1, 0);
        p.defer(false, &[rect(0, 0, 1, 1)]);
        p.reset();
        assert!(p.wants_emit(), "reset frees the pipeline for a new host");
        assert_eq!(p.poll_deadline(u64::MAX), Release::None);
    }

    #[test]
    fn damageset_unions_past_ceiling_to_full() {
        let mut d = Damageset::default();
        let many = vec![rect(0, 0, 1, 1); MAX_COMMIT_RECTS as usize];
        d.union(false, &many);
        assert!(!d.full);
        d.union(false, &[rect(0, 0, 1, 1)]);
        assert!(d.full, "exceeding the rect ceiling collapses to full");
        assert!(d.rects.is_empty());
    }

    #[test]
    fn pack_full_buffer_single_rect() {
        let data = vec![0x11u8; 4 * 2 * 4];
        let rects = [Rect {
            x: 0,
            y: 0,
            w: 4,
            h: 2,
        }];
        let packed = pack_damage(&data, 16, 4, 4, 2, &rects).expect("in bounds");
        assert_eq!(packed.len(), 4 * 2 * 4);
    }

    #[test]
    fn pack_subrect_copies_correct_rows() {
        let mut data = vec![0u8; 4 * 2 * 4];
        for (i, b) in data.iter_mut().enumerate() {
            *b = u8::try_from(i % 256).expect("mod 256");
        }
        let rects = [Rect {
            x: 1,
            y: 0,
            w: 2,
            h: 2,
        }];
        let packed = pack_damage(&data, 16, 4, 4, 2, &rects).expect("in bounds");
        assert_eq!(packed.len(), 2 * 2 * 4);
        assert_eq!(&packed[0..8], &data[4..12]);
        assert_eq!(&packed[8..16], &data[20..28]);
    }

    #[test]
    fn pack_out_of_bounds_rect_returns_none() {
        let data = vec![0u8; 4 * 2 * 4];
        let rects = [Rect {
            x: 3,
            y: 0,
            w: 2,
            h: 1,
        }];
        assert!(pack_damage(&data, 16, 4, 4, 2, &rects).is_none());
    }
}
