//! Commit pipeline and the load-bearing frame-pacing rule (ADR 0011, protocol v0).
//!
//! The pure pieces here — the [`Pacing`] state machine and [`pack_damage`] — are
//! host-testable; the Smithay buffer plumbing that feeds them is guest-only.

use std::collections::VecDeque;
use std::time::Duration;

use crate::remote::{MAX_COMMIT_RECTS, Rect};

pub const FRAME_STARVATION_NS: u64 = 50_000_000;

/// Bound on a window's outstanding xdg→host configure-serial map.
///
/// Overflow drops the oldest entry: a lost mapping can only stamp a later commit
/// with an older host serial, never a newer one — the conservative direction.
pub const CONFIGURE_RING_CAP: usize = 64;

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
    pub scale: f64,
    pub bytes: Vec<u8>,
}

/// Buffer pixels per logical point for a surface.
///
/// `buffer_w / viewport_dst_w` when a viewport sizes the surface (fractional
/// scaling), else the integer `wl_surface.set_buffer_scale` value. This is the
/// surface's own scale, not the output's — the two diverge during transitions.
#[must_use]
pub fn effective_scale(buffer_w: u32, viewport_dst_w: Option<u32>, buffer_scale: i32) -> f64 {
    debug_assert!(buffer_scale >= 0, "negative buffer scale");
    if let Some(dst) = viewport_dst_w
        && dst > 0
        && buffer_w > 0
    {
        return f64::from(buffer_w) / f64::from(dst);
    }
    f64::from(buffer_scale.max(1))
}

/// Fixed-point (×4096) encoding of a surface scale for the commit header.
#[must_use]
pub fn scale_to_e12(scale: f64) -> u32 {
    if !scale.is_finite() || scale <= 0.0 {
        return 4096;
    }
    let v = (scale.clamp(0.0, 16.0) * 4096.0).round();
    // v is bounded to [0, 65536] by the clamp, so the cast is exact.
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let e = v as u32;
    e
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

    #[must_use]
    pub fn remaining_timeout(&self, now_ns: u64) -> Option<Duration> {
        self.in_flight
            .map(|_| Duration::from_nanos(self.deadline_ns.saturating_sub(now_ns)))
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

/// Wayland-style wrapping serial comparison: `a` is strictly newer than `b`
/// when their forward distance falls in the near half of the u32 ring. Keeps
/// [`ConfigureRing`] free of smithay types while surviving counter wraparound.
#[must_use]
const fn serial_newer(a: u32, b: u32) -> bool {
    a != b && a.wrapping_sub(b) < 0x8000_0000
}

/// Per-window configure-serial tracking.
///
/// A bounded ring mapping each xdg configure serial to the host serial it
/// carried, plus the newest host serial the client has acked. Commits stamp
/// [`acked`](Self::acked); the host keys its size-authority machine on it.
#[derive(Debug, Default)]
pub struct ConfigureRing {
    entries: VecDeque<(u32, u32)>,
    acked_host_serial: u32,
}

impl ConfigureRing {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub const fn acked(&self) -> u32 {
        self.acked_host_serial
    }

    /// Map an xdg configure serial to the host serial it delivered; drop the
    /// oldest when full, and reject a serial not strictly newer than the back.
    pub fn record(&mut self, xdg_serial: u32, host_serial: u32) {
        debug_assert!(self.entries.len() <= CONFIGURE_RING_CAP, "ring over cap");
        if self
            .entries
            .back()
            .is_some_and(|&(back, _)| !serial_newer(xdg_serial, back))
        {
            return;
        }
        if self.entries.len() >= CONFIGURE_RING_CAP {
            let _ = self.entries.pop_front();
        }
        self.entries.push_back((xdg_serial, host_serial));
        debug_assert!(
            self.entries.len() <= CONFIGURE_RING_CAP,
            "ring exceeded cap"
        );
    }

    /// Resolve an ordered ack: drain every entry at or before `acked_xdg_serial`
    /// (wrapping-aware) and advance the acked host serial monotonically.
    pub fn resolve(&mut self, acked_xdg_serial: u32) {
        debug_assert!(self.entries.len() <= CONFIGURE_RING_CAP, "ring over cap");
        let mut newest = self.acked_host_serial;
        for _ in 0..CONFIGURE_RING_CAP {
            match self.entries.front() {
                Some(&(xs, hs)) if !serial_newer(xs, acked_xdg_serial) => {
                    newest = newest.max(hs);
                    let _ = self.entries.pop_front();
                }
                _ => break,
            }
        }
        self.acked_host_serial = newest.max(self.acked_host_serial);
        debug_assert!(self.entries.len() <= CONFIGURE_RING_CAP, "ring over cap");
    }

    /// Drop all serial state for a fresh host connection.
    pub fn reset(&mut self) {
        debug_assert!(self.entries.len() <= CONFIGURE_RING_CAP, "ring over cap");
        self.entries.clear();
        self.acked_host_serial = 0;
        debug_assert!(self.entries.is_empty(), "ring not cleared");
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

/// Bytes per pixel for the two supported shm formats.
const CROP_BPP: usize = 4;

/// Map a window-geometry rectangle (logical) into a buffer-pixel crop rect.
///
/// The rect is intersected with the buffer; `None` = remote the whole buffer
/// (geometry covers it, is empty/degenerate, or the scale is unusable).
#[must_use]
pub fn crop_rect_px(geo: (i32, i32, i32, i32), scale: f64, buf_w: u32, buf_h: u32) -> Option<Rect> {
    debug_assert!(buf_w > 0 && buf_h > 0, "crop against an empty buffer");
    if !scale.is_finite() || scale <= 0.0 || buf_w == 0 || buf_h == 0 {
        return None;
    }
    let x0 = scale_px(geo.0, scale, buf_w);
    let y0 = scale_px(geo.1, scale, buf_h);
    let x1 = scale_px(geo.0.saturating_add(geo.2), scale, buf_w);
    let y1 = scale_px(geo.1.saturating_add(geo.3), scale, buf_h);
    if x1 <= x0 || y1 <= y0 {
        return None;
    }
    let rect = Rect {
        x: x0,
        y: y0,
        w: x1 - x0,
        h: y1 - y0,
    };
    debug_assert!(
        rect.x + rect.w <= buf_w && rect.y + rect.h <= buf_h,
        "crop in buffer"
    );
    if rect.x == 0 && rect.y == 0 && rect.w == buf_w && rect.h == buf_h {
        return None;
    }
    Some(rect)
}

/// Logical coordinate × scale → buffer pixels, clamped to `[0, max]`.
fn scale_px(v: i32, scale: f64, max: u32) -> u32 {
    debug_assert!(scale.is_finite() && scale > 0.0, "scale must be usable");
    let f = (f64::from(v) * scale).round();
    if !f.is_finite() || f <= 0.0 {
        return 0;
    }
    let cap = f64::from(max);
    // f is clamped to [0, max], so the cast is exact.
    #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
    let out = if f >= cap { max } else { f as u32 };
    out
}

/// Crop a frame to `rect` with a tight stride. The caller filters identity
/// rects; a packing failure means the caller keeps the uncropped frame.
#[must_use]
pub fn crop_frame(fb: &FullBuffer, rect: Rect) -> Option<FullBuffer> {
    debug_assert!(rect.w > 0 && rect.h > 0, "empty crop rect");
    debug_assert!(
        rect.x + rect.w <= fb.w && rect.y + rect.h <= fb.h,
        "crop rect outside the buffer"
    );
    let bytes = pack_damage(
        &fb.bytes,
        fb.stride as usize,
        CROP_BPP,
        fb.w,
        fb.h,
        std::slice::from_ref(&rect),
    )?;
    let stride = rect.w.checked_mul(4)?;
    Some(FullBuffer {
        w: rect.w,
        h: rect.h,
        stride,
        format: fb.format,
        scale: fb.scale,
        bytes,
    })
}

/// Intersect a buffer-space damage rect with the crop and translate it into
/// crop-relative coordinates; `None` when nothing survives.
#[must_use]
pub fn translate_damage(r: Rect, crop: Rect) -> Option<Rect> {
    debug_assert!(crop.w > 0 && crop.h > 0, "empty crop rect");
    let x0 = r.x.max(crop.x);
    let y0 = r.y.max(crop.y);
    let x1 = r.x.saturating_add(r.w).min(crop.x.saturating_add(crop.w));
    let y1 = r.y.saturating_add(r.h).min(crop.y.saturating_add(crop.h));
    if x1 <= x0 || y1 <= y0 {
        return None;
    }
    Some(Rect {
        x: x0 - crop.x,
        y: y0 - crop.y,
        w: x1 - x0,
        h: y1 - y0,
    })
}

/// Parent-relative origin of an override-redirect X11 popup.
///
/// Computed from the absolute X11 screen coordinates of the child and its
/// transient parent. Signed, so a popup anchored above or left of its parent
/// keeps a negative offset.
#[must_use]
pub const fn x11_popup_offset(parent: (i32, i32), child: (i32, i32)) -> (i32, i32) {
    (
        child.0.saturating_sub(parent.0),
        child.1.saturating_sub(parent.1),
    )
}

/// Modality stand-in for X11: a dialog with a transient parent. smithay 0.7
/// does not surface `_NET_WM_STATE_MODAL`, so this is the closest faithful cue.
#[must_use]
pub const fn x11_modal(is_dialog: bool, has_transient_parent: bool) -> bool {
    is_dialog && has_transient_parent
}

#[cfg(target_os = "linux")]
mod linux {
    use smithay::reexports::wayland_server::protocol::wl_buffer::WlBuffer;
    use smithay::reexports::wayland_server::protocol::wl_callback::WlCallback;
    use smithay::reexports::wayland_server::protocol::wl_shm;
    use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
    use smithay::utils::SERIAL_COUNTER;
    use smithay::wayland::compositor::{BufferAssignment, Damage, SurfaceAttributes, with_states};
    use smithay::wayland::fractional_scale::with_fractional_scale;
    use smithay::wayland::shell::xdg::SurfaceCachedState as XdgSurfaceCachedState;
    use smithay::wayland::shm::with_buffer_contents;
    use smithay::wayland::viewporter::ViewportCachedState;

    use super::{Damageset, FullBuffer, Rect, Release, effective_scale, pack_damage, scale_to_e12};
    use crate::comp::{State, Win, WinRole, read_toplevel_app_id, read_toplevel_title};
    use crate::remote::{
        CommitMeta, FMT_ARGB8888, FMT_XRGB8888, MAX_COMMIT_RECTS, PopupNew, T_COMMIT, T_POPUP_NEW,
        T_WIN_LIMITS, T_WIN_MAP, T_WIN_NEW, T_WIN_TITLE, T_WIN_UNMAP, WinLimits, WinNew, WinRef,
        WinTitle, encode_commit,
    };

    const BPP: usize = 4;
    const BPP_U32: u32 = 4;

    struct Extracted {
        buffer: Option<BufferAssignment>,
        damage: Vec<Damage>,
        callbacks: Vec<WlCallback>,
        buffer_scale: i32,
        viewport_dst_w: Option<u32>,
    }

    fn extract(surface: &WlSurface) -> Extracted {
        with_states(surface, |states| {
            let mut cached = states.cached_state.get::<SurfaceAttributes>();
            let attrs = cached.current();
            let callbacks: Vec<WlCallback> = attrs.frame_callbacks.drain(..).collect();
            let buffer = attrs.buffer.take();
            let damage = std::mem::take(&mut attrs.damage);
            let buffer_scale = attrs.buffer_scale;
            drop(cached);
            let viewport_dst_w = {
                let mut vp = states.cached_state.get::<ViewportCachedState>();
                vp.current().dst.and_then(|d| u32::try_from(d.w).ok())
            };
            Extracted {
                buffer,
                damage,
                callbacks,
                buffer_scale,
                viewport_dst_w,
            }
        })
    }

    /// The xdg window geometry (logical) the client last committed, if any.
    fn window_geometry(surface: &WlSurface) -> Option<(i32, i32, i32, i32)> {
        with_states(surface, |states| {
            let mut cached = states.cached_state.get::<XdgSurfaceCachedState>();
            cached
                .current()
                .geometry
                .map(|g| (g.loc.x, g.loc.y, g.size.w, g.size.h))
        })
    }

    /// The client's min/max size hints (logical points; 0 = unconstrained).
    fn surface_limits(surface: &WlSurface) -> (u32, u32, u32, u32) {
        let cur = with_states(surface, |states| {
            let mut cached = states.cached_state.get::<XdgSurfaceCachedState>();
            *cached.current()
        });
        let cvt = |v: i32| u32::try_from(v).unwrap_or(0);
        (
            cvt(cur.min_size.w),
            cvt(cur.min_size.h),
            cvt(cur.max_size.w),
            cvt(cur.max_size.h),
        )
    }

    /// Forward min/max hint changes to the host (protocol `win_limits`); the
    /// hints commit atomically with the rest of the surface state.
    fn sync_limits(state: &mut State, win: u32, surface: &WlSurface) {
        debug_assert!(win != 0, "limits for reserved window id 0");
        let limits = surface_limits(surface);
        let changed = state.windows.get(&win).is_some_and(|x| x.limits != limits);
        if !changed {
            return;
        }
        if let Some(x) = state.windows.get_mut(&win) {
            x.limits = limits;
        }
        enqueue_limits(state, win, limits);
    }

    fn enqueue_limits(state: &mut State, win: u32, limits: (u32, u32, u32, u32)) {
        debug_assert!(win != 0, "limits for reserved window id 0");
        let msg = WinLimits {
            win,
            min_w: limits.0,
            min_h: limits.1,
            max_w: limits.2,
            max_h: limits.3,
        };
        state.enqueue(T_WIN_LIMITS, serde_json::to_vec(&msg).unwrap_or_default());
    }

    /// Logical offset of the window geometry inside the surface, for mapping
    /// host pointer coordinates (geometry-relative) into surface space.
    #[must_use]
    pub fn geometry_offset_logical(surface: &WlSurface) -> (f64, f64) {
        window_geometry(surface).map_or((0.0, 0.0), |g| (f64::from(g.0), f64::from(g.1)))
    }

    /// Intersect buffer-space damage with the crop and translate it into crop
    /// space; surface-space damage passes through (downstream full fallback).
    fn crop_damage(damage: Vec<Damage>, crop: Rect, buf_w: u32, buf_h: u32) -> Vec<Damage> {
        debug_assert!(crop.w > 0 && crop.h > 0, "empty crop rect");
        let mut out = Vec::with_capacity(damage.len());
        for d in damage {
            match d {
                Damage::Buffer(rect) => {
                    let clamped = clamp_rect(rect, buf_w, buf_h);
                    if let Some(moved) = super::translate_damage(clamped, crop) {
                        let (Ok(mx), Ok(my)) = (i32::try_from(moved.x), i32::try_from(moved.y))
                        else {
                            continue;
                        };
                        let (Ok(mw), Ok(mh)) = (i32::try_from(moved.w), i32::try_from(moved.h))
                        else {
                            continue;
                        };
                        out.push(Damage::Buffer(smithay::utils::Rectangle::new(
                            (mx, my).into(),
                            (mw, mh).into(),
                        )));
                    }
                }
                Damage::Surface(rect) => out.push(Damage::Surface(rect)),
            }
        }
        out
    }

    fn set_preferred_fractional(surface: &WlSurface, scale: f64) {
        debug_assert!(scale > 0.0, "preferred scale must be positive");
        debug_assert!(scale.is_finite(), "preferred scale must be finite");
        with_states(surface, |states| {
            with_fractional_scale(states, |fs| fs.set_preferred_scale(scale));
        });
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
                scale: 1.0,
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
        let is_popup = state.windows.get(&win).is_some_and(Win::is_popup);
        let is_x11 = state.windows.get(&win).is_some_and(Win::is_x11);
        let x11_or = state
            .windows
            .get(&win)
            .and_then(Win::x11)
            .is_some_and(smithay::xwayland::X11Surface::is_override_redirect);
        let announced = state.windows.get(&win).is_some_and(|x| x.announced);
        if !announced {
            if is_popup {
                announce_popup(state, win, w, h);
            } else if is_x11 {
                crate::xwm::announce_x11(state, win, w, h);
            } else {
                announce_toplevel(state, win, surface, w, h);
            }
        }
        let mapped = state.windows.get(&win).is_some_and(|x| x.mapped);
        if !mapped {
            if let Some(x) = state.windows.get_mut(&win) {
                x.mapped = true;
            }
            let payload = serde_json::to_vec(&WinRef { win }).unwrap_or_default();
            state.enqueue(T_WIN_MAP, payload);
            // Keyboard focus goes to xdg toplevels and managed (non-OR) X11
            // windows; popups are grab-driven and override-redirect menus must
            // never steal focus, which may belong to another app or to nothing.
            if !is_popup && !x11_or {
                let serial = SERIAL_COUNTER.next_serial();
                let kbd = state.keyboard.clone();
                kbd.set_focus(state, Some(surface.clone()), serial);
            }
            // Associate the surface with the output so the client receives
            // wl_surface.enter and renders at the output/fractional scale.
            state.output.enter(surface);
            set_preferred_fractional(surface, state.scale);
        }
    }

    fn announce_toplevel(state: &mut State, win: u32, surface: &WlSurface, w: u32, h: u32) {
        debug_assert!(win != 0, "window id 0 is reserved");
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
        state.enqueue(T_WIN_NEW, serde_json::to_vec(&msg).unwrap_or_default());
    }

    fn announce_popup(state: &mut State, win: u32, w: u32, h: u32) {
        debug_assert!(win != 0, "window id 0 is reserved");
        let info = state.windows.get(&win).and_then(|x| match &x.role {
            WinRole::Popup { parent, pos, .. } => Some((*parent, *pos)),
            WinRole::Toplevel(_) | WinRole::X11(_) => None,
        });
        let Some((parent, pos)) = info else {
            return;
        };
        if let Some(x) = state.windows.get_mut(&win) {
            x.size = (w, h);
            x.announced = true;
        }
        let msg = PopupNew {
            win,
            parent,
            x: pos.0,
            y: pos.1,
            w,
            h,
            scale: state.scale,
        };
        state.enqueue(T_POPUP_NEW, serde_json::to_vec(&msg).unwrap_or_default());
    }

    fn unmap(state: &mut State, win: u32) {
        let was = state.windows.get(&win).is_some_and(|x| x.mapped);
        if was {
            let surface = state.windows.get(&win).map(|x| x.surface.clone());
            if let Some(x) = state.windows.get_mut(&win) {
                x.mapped = false;
            }
            let payload = serde_json::to_vec(&WinRef { win }).unwrap_or_default();
            state.enqueue(T_WIN_UNMAP, payload);
            if let Some(surface) = surface {
                state.output.leave(&surface);
            }
        }
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
        serial: u32,
    ) -> bool {
        debug_assert!(win != 0, "window id 0 is reserved");
        debug_assert!(fb.w > 0 && fb.h > 0, "emitting a zero-sized frame");
        let first_frame = !state.windows.get(&win).is_some_and(|x| x.announced);
        announce_and_map(state, win, surface, fb.w, fb.h);
        let rects = commit_rects(dmg, fb.w, fb.h);
        // A tightly-packed full-frame commit already IS the payload; repacking
        // it would be a redundant whole-buffer copy on every resize frame.
        let tight = dmg.full && fb.stride == fb.w * BPP_U32;
        let repacked = if tight {
            None
        } else {
            match pack_damage(&fb.bytes, fb.stride as usize, BPP, fb.w, fb.h, &rects) {
                Some(p) => Some(p),
                None => return false,
            }
        };
        let packed: &[u8] = repacked.as_deref().unwrap_or(&fb.bytes);
        let seq = state.next_seq();
        let t_send = state.now_ns();
        let meta = CommitMeta {
            win,
            seq,
            w: fb.w,
            h: fb.h,
            stride: fb.stride,
            format: fb.format,
            scale_e12: scale_to_e12(fb.scale),
            serial,
            t_client_commit_ns: t_commit,
            t_send_ns: t_send,
        };
        let Ok(payload) = encode_commit(&meta, &rects, packed) else {
            return false;
        };
        state.enqueue(T_COMMIT, payload);
        if first_frame {
            eprintln!(
                "msl-way: first frame queued win={win} seq={seq} {}x{}",
                fb.w, fb.h
            );
        }
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
        let serial = state.windows.get(&win).map_or(0, |x| x.serials.acked());
        let wants = state
            .windows
            .get(&win)
            .is_some_and(|x| x.pacing.wants_emit());
        if wants {
            let emitted = emit_snapshot(state, win, surface, &fb, &dmg, t_commit, serial);
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
            x.pending_serial = serial;
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
                    Some(mut fb) => {
                        fb.scale = effective_scale(fb.w, ex.viewport_dst_w, ex.buffer_scale);
                        let mut damage = ex.damage;
                        // Window-geometry ruling: CSD shadow margins never
                        // cross the seam.
                        if let Some(crop) = window_geometry(surface)
                            .and_then(|g| super::crop_rect_px(g, fb.scale, fb.w, fb.h))
                            && let Some(cropped) = super::crop_frame(&fb, crop)
                        {
                            damage = crop_damage(damage, crop, fb.w, fb.h);
                            fb = cropped;
                        }
                        ingest_commit(state, win, surface, fb, &damage, ex.callbacks, t_commit);
                    }
                    None => fire(state, ex.callbacks),
                }
            }
        }
        let announced = state.windows.get(&win).is_some_and(|x| x.announced);
        let is_toplevel = state.windows.get(&win).is_some_and(Win::is_toplevel);
        if announced && is_toplevel {
            sync_limits(state, win, surface);
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
        let taken = state.windows.get_mut(&win).and_then(|x| {
            x.pending
                .take()
                .map(|fb| (fb, x.pending_t_commit, x.pending_serial))
        });
        let (Some(surface), Some((fb, t_commit, serial))) = (surface, taken) else {
            return;
        };
        if emit_snapshot(state, win, &surface, &fb, dmg, t_commit, serial)
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
    /// Popups are transient: they are dismissed (`popup_done` cascade) rather than
    /// replayed. Toplevels fire held callbacks, reset pacing/announce state,
    /// replay `win_new`/`win_map`/`win_title`, and push a full-damage commit of
    /// the last frame so the new presenter has pixels.
    pub fn replay_all(state: &mut State) {
        crate::popups::dismiss_all_popups(state);
        let wins: Vec<u32> = state.windows.keys().copied().collect();
        for win in wins {
            replay_window(state, win);
        }
    }

    fn replay_window(state: &mut State, win: u32) {
        debug_assert!(win != 0, "reserved window id 0 in registry");
        if state.windows.get(&win).is_some_and(Win::is_popup) {
            return;
        }
        // Override-redirect X11 menus/tooltips are transient like popups: the
        // fresh presenter never replays them, it re-derives them on the next map.
        let x11_or = state
            .windows
            .get(&win)
            .and_then(Win::x11)
            .is_some_and(smithay::xwayland::X11Surface::is_override_redirect);
        if x11_or {
            return;
        }
        let is_x11 = state.windows.get(&win).is_some_and(Win::is_x11);
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
            x.serials.reset();
            x.pending = None;
            x.pending_t_commit = 0;
            x.pending_serial = 0;
            x.announced = false;
            x.mapped = false;
            x.prev_buffer_size = (0, 0);
        }
        if mapped {
            if is_x11 {
                replay_x11_mapped(state, win, &surface, size);
            } else {
                replay_mapped(state, win, &surface, &app_id, &title, size);
            }
        }
    }

    /// Re-announce a managed X11 toplevel to a fresh presenter: identity, map,
    /// then a full-damage replay of its last frame. Override-redirect windows are
    /// filtered out before this point.
    fn replay_x11_mapped(state: &mut State, win: u32, surface: &WlSurface, size: (u32, u32)) {
        debug_assert!(win != 0, "reserved window id 0 in x11 replay");
        debug_assert!(state.windows.get(&win).is_some_and(Win::is_x11), "not x11");
        crate::xwm::announce_x11(state, win, size.0, size.1);
        state.enqueue(
            T_WIN_MAP,
            serde_json::to_vec(&WinRef { win }).unwrap_or_default(),
        );
        if let Some(x) = state.windows.get_mut(&win) {
            x.announced = true;
            x.mapped = true;
        }
        let last = state.windows.get(&win).and_then(|x| x.last_frame.clone());
        if let Some(fb) = last {
            let t = state.now_ns();
            let _ = emit_snapshot(state, win, surface, &fb, &Damageset::full(), t, 0);
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
        let limits = state.windows.get(&win).map_or((0, 0, 0, 0), |x| x.limits);
        if limits != (0, 0, 0, 0) {
            enqueue_limits(state, win, limits);
        }
        if let Some(x) = state.windows.get_mut(&win) {
            x.announced = true;
            x.mapped = true;
        }
        let last = state.windows.get(&win).and_then(|x| x.last_frame.clone());
        if let Some(fb) = last {
            let t = state.now_ns();
            let _ = emit_snapshot(state, win, surface, &fb, &Damageset::full(), t, 0);
        }
    }
}

#[cfg(target_os = "linux")]
pub use linux::{geometry_offset_logical, on_commit, on_present_ack, poll_pacing, replay_all};

#[cfg(test)]
mod tests {
    use super::*;

    fn rect(x: u32, y: u32, w: u32, h: u32) -> Rect {
        Rect { x, y, w, h }
    }

    #[test]
    fn x11_popup_offset_is_signed_child_minus_parent() {
        assert_eq!(x11_popup_offset((100, 200), (140, 260)), (40, 60));
        assert_eq!(
            x11_popup_offset((100, 200), (60, 180)),
            (-40, -20),
            "a popup above-left of its parent keeps negative offsets"
        );
        assert_eq!(x11_popup_offset((0, 0), (0, 0)), (0, 0));
    }

    #[test]
    fn x11_modal_requires_dialog_and_transient_parent() {
        assert!(
            x11_modal(true, true),
            "a transient dialog stands in for modal"
        );
        assert!(!x11_modal(true, false), "a parentless dialog is not modal");
        assert!(!x11_modal(false, true), "a non-dialog is never modal");
        assert!(!x11_modal(false, false));
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
    fn pacing_timeout_is_none_without_in_flight_present() {
        let p = Pacing::new(10);
        assert_eq!(p.remaining_timeout(0), None);
        assert!(p.wants_emit());
    }

    #[test]
    fn pacing_timeout_reports_time_before_deadline() {
        let mut p = Pacing::new(10);
        p.present_now(1, 20);
        assert_eq!(p.remaining_timeout(26), Some(Duration::from_nanos(4)));
        assert!(p.in_flight());
    }

    #[test]
    fn pacing_timeout_is_zero_at_deadline() {
        let mut p = Pacing::new(10);
        p.present_now(1, 20);
        assert_eq!(p.remaining_timeout(30), Some(Duration::ZERO));
        assert!(p.in_flight());
    }

    #[test]
    fn pacing_timeout_uses_saturated_deadline() {
        let mut p = Pacing::new(10);
        p.present_now(1, u64::MAX - 5);
        assert_eq!(
            p.remaining_timeout(u64::MAX - 2),
            Some(Duration::from_nanos(2))
        );
        assert_eq!(p.remaining_timeout(u64::MAX), Some(Duration::ZERO));
        assert!(p.in_flight());
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
    fn scale_to_e12_maps_common_scales() {
        assert_eq!(scale_to_e12(1.0), 4096);
        assert_eq!(scale_to_e12(2.0), 8192);
        assert_eq!(scale_to_e12(1.5), 6144);
        assert_eq!(scale_to_e12(0.0), 4096, "non-positive falls back to 1x");
        assert_eq!(scale_to_e12(f64::NAN), 4096, "NaN falls back to 1x");
    }

    #[test]
    fn effective_scale_prefers_viewport_then_buffer_scale() {
        assert!(
            (effective_scale(200, Some(100), 1) - 2.0).abs() < 1e-9,
            "fractional via viewport"
        );
        assert!((effective_scale(150, Some(100), 1) - 1.5).abs() < 1e-9);
        assert!(
            (effective_scale(200, None, 2) - 2.0).abs() < 1e-9,
            "integer buffer scale"
        );
        assert!(
            (effective_scale(100, Some(0), 3) - 3.0).abs() < 1e-9,
            "zero dst -> buffer scale"
        );
        assert!(
            (effective_scale(100, None, 0) - 1.0).abs() < 1e-9,
            "zero scale floors to 1"
        );
    }

    #[test]
    fn hello_ack_scale_change_reaches_commit_header() {
        // Plumbing pin (no VM): a 2x buffer for a 100pt window must encode 2x,
        // so the host presents at the correct logical size instead of upscaling.
        let scale = effective_scale(200, Some(100), 1);
        assert_eq!(scale_to_e12(scale), 8192);
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

    #[test]
    fn fresh_ring_stamps_zero_before_any_ack() {
        let r = ConfigureRing::new();
        assert_eq!(r.acked(), 0, "commits stamp 0 until the first ack resolves");
    }

    #[test]
    fn ring_overflow_drops_oldest_entry() {
        let mut r = ConfigureRing::new();
        let cap = u32::try_from(CONFIGURE_RING_CAP).expect("cap fits u32");
        for i in 1..=cap + 1 {
            r.record(i, i * 10);
        }
        r.resolve(1);
        assert_eq!(r.acked(), 0, "dropped oldest xdg serial 1 cannot resolve");
        r.resolve(2);
        assert_eq!(r.acked(), 20, "the surviving second entry still resolves");
    }

    #[test]
    fn ordered_ack_drains_every_entry_at_or_before_it() {
        let mut r = ConfigureRing::new();
        r.record(10, 100);
        r.record(20, 200);
        r.record(30, 300);
        r.resolve(20);
        assert_eq!(r.acked(), 200, "acking xdg 20 resolves 10 and 20");
        r.resolve(30);
        assert_eq!(r.acked(), 300, "the remaining entry resolves next");
    }

    #[test]
    fn acked_host_serial_never_decreases() {
        let mut r = ConfigureRing::new();
        r.record(10, 100);
        r.resolve(10);
        assert_eq!(r.acked(), 100);
        r.record(20, 50);
        r.resolve(20);
        assert_eq!(r.acked(), 100, "a lower host serial cannot roll acked back");
    }

    #[test]
    fn crop_rect_identity_and_empty_are_none() {
        assert_eq!(
            crop_rect_px((0, 0, 100, 80), 1.0, 100, 80),
            None,
            "covers buffer"
        );
        assert_eq!(
            crop_rect_px((5, 5, 0, 10), 1.0, 100, 80),
            None,
            "empty geometry"
        );
        assert_eq!(
            crop_rect_px((5, 5, 10, 10), 0.0, 100, 80),
            None,
            "unusable scale"
        );
        assert_eq!(
            crop_rect_px((200, 200, 10, 10), 1.0, 100, 80),
            None,
            "outside buffer"
        );
    }

    #[test]
    fn crop_rect_scales_margins_to_pixels() {
        let r = crop_rect_px((14, 12, 1689, 852), 2.0, 3434, 1762).expect("crop");
        assert_eq!(
            (r.x, r.y, r.w, r.h),
            (28, 24, 3378, 1704),
            "gtk shadow margins at 2x"
        );
    }

    #[test]
    fn crop_rect_clamps_overhang_and_rounds_fractional_scale() {
        let r = crop_rect_px((-4, 10, 200, 60), 1.0, 100, 80).expect("crop");
        assert_eq!(
            (r.x, r.y, r.w, r.h),
            (0, 10, 100, 60),
            "overhang clamps to buffer"
        );
        let f = crop_rect_px((10, 10, 20, 20), 1.5, 100, 100).expect("crop");
        assert_eq!(
            (f.x, f.y, f.w, f.h),
            (15, 15, 30, 30),
            "1.5x scaling rounds exactly"
        );
    }

    #[test]
    fn crop_frame_extracts_geometry_pixels() {
        let mut bytes = vec![0u8; 4 * 4 * 4];
        for (i, b) in bytes.iter_mut().enumerate() {
            *b = u8::try_from(i % 251).expect("fits");
        }
        let fb = FullBuffer {
            w: 4,
            h: 4,
            stride: 16,
            format: 0,
            scale: 1.0,
            bytes,
        };
        let rect = Rect {
            x: 1,
            y: 1,
            w: 2,
            h: 2,
        };
        let cropped = crop_frame(&fb, rect).expect("crop");
        assert_eq!((cropped.w, cropped.h, cropped.stride), (2, 2, 8));
        assert_eq!(cropped.bytes.len(), 2 * 2 * 4);
        assert_eq!(
            cropped.bytes[0],
            fb.bytes[16 + 4],
            "row 1, px 1 leads the crop"
        );
    }

    #[test]
    fn translate_damage_intersects_and_offsets() {
        let crop = Rect {
            x: 28,
            y: 24,
            w: 100,
            h: 100,
        };
        let inside = Rect {
            x: 30,
            y: 30,
            w: 10,
            h: 10,
        };
        assert_eq!(
            translate_damage(inside, crop),
            Some(Rect {
                x: 2,
                y: 6,
                w: 10,
                h: 10
            })
        );
        let straddle = Rect {
            x: 0,
            y: 0,
            w: 40,
            h: 40,
        };
        assert_eq!(
            translate_damage(straddle, crop),
            Some(Rect {
                x: 0,
                y: 0,
                w: 12,
                h: 16
            }),
            "shadow-side damage clips to the geometry"
        );
        let outside = Rect {
            x: 0,
            y: 0,
            w: 20,
            h: 20,
        };
        assert_eq!(
            translate_damage(outside, crop),
            None,
            "pure shadow damage drops"
        );
    }

    #[test]
    fn reset_zeroes_serial_state_for_reconnect() {
        let mut r = ConfigureRing::new();
        r.record(10, 100);
        r.resolve(10);
        assert_eq!(r.acked(), 100);
        r.reset();
        assert_eq!(r.acked(), 0, "reconnect zeroes the acked serial");
        r.resolve(10);
        assert_eq!(r.acked(), 0, "the ring is empty after reset");
    }

    #[test]
    fn ordered_drain_is_wraparound_aware() {
        let mut r = ConfigureRing::new();
        r.record(u32::MAX - 1, 100);
        r.record(u32::MAX, 200);
        r.record(0, 300);
        r.record(1, 400);
        r.resolve(0);
        assert_eq!(
            r.acked(),
            300,
            "serials straddling the u32 wrap drain in order"
        );
        r.resolve(1);
        assert_eq!(r.acked(), 400, "the post-wrap entry resolves next");
    }

    #[test]
    fn record_drops_stale_out_of_order_serial() {
        let mut r = ConfigureRing::new();
        r.record(10, 100);
        r.record(5, 200);
        r.resolve(10);
        assert_eq!(
            r.acked(),
            100,
            "a serial older than the back is dropped, not stored"
        );
    }
}
