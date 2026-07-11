//! Rootless `XWayland` window management (guest-only).
//!
//! X11 apps reach the compositor through an in-process Xwayland whose windows
//! carry the `xwayland_shell` role, not xdg-shell. This module owns the two
//! handler traits that route them: [`XWaylandShellHandler::surface_associated`]
//! registers an X11 window into the shared `windows`/`surface_win` tables the
//! moment its `wl_surface` is matched (without which `frames::on_commit` would
//! drop every X11 frame), and [`XwmHandler`] fields the X11 protocol requests.
//! There is no `delegate_xwm!` macro — `X11Wm::start_wm` inserts the calloop
//! source that drives `XwmHandler`; only the shell side is delegated here.

use smithay::reexports::wayland_server::Resource;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::utils::{Logical, Rectangle};
use smithay::wayland::xwayland_shell::{XWaylandShellHandler, XWaylandShellState};
use smithay::xwayland::xwm::{Reorder, ResizeEdge, WmWindowType, X11Window, XwmId};
use smithay::xwayland::{X11Surface, X11Wm, XwmHandler};

use crate::comp::{State, Win};
use crate::remote::{
    PopupMoved, PopupNew, T_POPUP_MOVED, T_POPUP_NEW, T_WIN_DESTROY, T_WIN_NEW, WinNewFull, WinRef,
};

impl XWaylandShellHandler for State {
    fn xwayland_shell_state(&mut self) -> &mut XWaylandShellState {
        &mut self.xwayland_shell
    }

    /// An X11 window has been paired with a `wl_surface` (serial match + commit).
    /// Registering it here is what lets `frames::on_commit` find a win id and
    /// stop discarding the surface's frames.
    fn surface_associated(&mut self, _xwm: XwmId, wl_surface: WlSurface, surface: X11Surface) {
        debug_assert!(wl_surface.is_alive(), "associated a dead wl_surface");
        debug_assert!(surface.alive(), "associated a dead x11 window");
        if let Some(existing_win) = self.win_id_of(&wl_surface) {
            let xid = surface.window_id();
            let registered_xid = self
                .windows
                .get(&existing_win)
                .and_then(Win::x11)
                .map(X11Surface::window_id);
            debug_assert_eq!(registered_xid, Some(xid), "x11 surface re-associated");
            debug_assert_eq!(
                self.x11_windows.get(&xid).copied(),
                Some(existing_win),
                "x11 reverse map missing existing association"
            );
            return;
        }
        let win = self.next_win;
        self.next_win = self.next_win.wrapping_add(1);
        debug_assert!(win != 0 || self.next_win != 0, "window id space exhausted");
        eprintln!(
            "msl-way: x11 associated xid={:#x} win={win}",
            surface.window_id()
        );
        register_x11_window(self, win, wl_surface, surface);
    }
}

impl XwmHandler for State {
    // The X11Source that drives this trait exists only while a WM is running, so
    // `xwm` is always `Some` here; the foreign `&mut` return admits no fallback.
    fn xwm_state(&mut self, _xwm: XwmId) -> &mut X11Wm {
        self.xwm
            .as_mut()
            .expect("XwmHandler dispatched without a live X11Wm")
    }

    fn new_window(&mut self, _xwm: XwmId, window: X11Surface) {
        debug_assert!(window.alive(), "new_window on a dead x11 window");
        debug_assert!(
            window.wl_surface().is_none(),
            "unmapped window already paired"
        );
    }

    fn new_override_redirect_window(&mut self, _xwm: XwmId, window: X11Surface) {
        debug_assert!(window.alive(), "new OR window is dead");
        debug_assert!(window.is_override_redirect(), "non-OR routed as OR");
    }

    fn map_window_request(&mut self, _xwm: XwmId, window: X11Surface) {
        debug_assert!(window.alive(), "map request on a dead x11 window");
        debug_assert!(
            !window.is_override_redirect(),
            "OR window cannot be map-requested"
        );
        if let Err(e) = window.set_mapped(true) {
            eprintln!("msl-way: x11 map grant failed: {e}");
        }
    }

    fn mapped_override_redirect_window(&mut self, _xwm: XwmId, window: X11Surface) {
        debug_assert!(window.is_override_redirect(), "non-OR reported as OR map");
        debug_assert!(window.alive(), "mapped OR window is dead");
    }

    fn unmapped_window(&mut self, _xwm: XwmId, window: X11Surface) {
        debug_assert!(
            window.alive() || window.mapped_window_id().is_none(),
            "stale unmap"
        );
        forget_x11_window(self, window.window_id());
    }

    fn destroyed_window(&mut self, _xwm: XwmId, window: X11Surface) {
        debug_assert!(window.window_id() != 0, "destroyed reserved x11 id 0");
        forget_x11_window(self, window.window_id());
    }

    fn configure_request(
        &mut self,
        _xwm: XwmId,
        window: X11Surface,
        x: Option<i32>,
        y: Option<i32>,
        w: Option<u32>,
        h: Option<u32>,
        _reorder: Option<Reorder>,
    ) {
        debug_assert!(window.alive(), "configure request on a dead window");
        // `configure` is the only place the WM may size/position an X11 window,
        // and it rejects override-redirect windows outright.
        if window.is_override_redirect() {
            return;
        }
        let mut geo = window.geometry();
        apply_configure_geometry(&mut geo, x, y, w, h);
        if let Err(e) = window.configure(geo) {
            eprintln!("msl-way: x11 configure failed: {e}");
        }
    }

    fn configure_notify(
        &mut self,
        _xwm: XwmId,
        window: X11Surface,
        geometry: Rectangle<i32, Logical>,
        _above: Option<X11Window>,
    ) {
        debug_assert!(window.window_id() != 0, "configure_notify reserved id 0");
        debug_assert!(
            geometry.size.w >= 0 && geometry.size.h >= 0,
            "negative geometry"
        );
        // Only a live override-redirect popup can move after mapping; mirror the
        // new parent-relative origin so a repositioned menu tracks its anchor.
        reposition_x11_popup(self, &window);
    }

    fn resize_request(
        &mut self,
        _xwm: XwmId,
        window: X11Surface,
        _button: u32,
        _edges: ResizeEdge,
    ) {
        debug_assert!(window.alive(), "resize request on a dead window");
        debug_assert!(
            window.wl_surface().is_some() || !window.is_mapped(),
            "resize before map"
        );
    }

    fn move_request(&mut self, _xwm: XwmId, window: X11Surface, _button: u32) {
        debug_assert!(window.alive(), "move request on a dead window");
        debug_assert!(window.window_id() != 0, "move request reserved id 0");
    }
}

/// Clamp the requested overrides onto the current geometry, leaving unset axes
/// untouched. A width/height that overflows `i32` keeps the prior extent.
fn apply_configure_geometry(
    geo: &mut Rectangle<i32, Logical>,
    x: Option<i32>,
    y: Option<i32>,
    w: Option<u32>,
    h: Option<u32>,
) {
    debug_assert!(
        geo.size.w >= 0 && geo.size.h >= 0,
        "negative starting geometry"
    );
    if let Some(x) = x {
        geo.loc.x = x;
    }
    if let Some(y) = y {
        geo.loc.y = y;
    }
    if let Some(w) = w {
        geo.size.w = i32::try_from(w).unwrap_or(geo.size.w);
    }
    if let Some(h) = h {
        geo.size.h = i32::try_from(h).unwrap_or(geo.size.h);
    }
    debug_assert!(
        geo.size.w >= 0 && geo.size.h >= 0,
        "configure produced negative size"
    );
}

/// Drop the host window backing an X11 window and tell the presenter, keyed by
/// the X11 window id so an unmap and a later destroy are idempotent.
fn forget_x11_window(state: &mut State, xid: X11Window) {
    let Some(win) = state.x11_windows.remove(&xid) else {
        return;
    };
    debug_assert!(win != 0, "reserved window id 0 in registry");
    let entry = state.windows.remove(&win);
    debug_assert!(
        entry
            .as_ref()
            .and_then(Win::x11)
            .is_some_and(|x11| x11.window_id() == xid),
        "x11 reverse map diverged from window registry"
    );
    let surface = entry.map(|w| w.surface);
    if let Some(surface) = surface {
        let removed = state.surface_win.remove(&surface);
        debug_assert_eq!(removed, Some(win), "x11 surface registry diverged");
    }
    if state.focus == Some(win) {
        state.focus = None;
    }
    let payload = serde_json::to_vec(&WinRef { win }).unwrap_or_default();
    state.enqueue(T_WIN_DESTROY, payload);
    debug_assert!(!state.windows.contains_key(&win), "x11 window not removed");
}

fn register_x11_window(state: &mut State, win: u32, surface: WlSurface, x11: X11Surface) {
    let xid = x11.window_id();
    let vacant = !state.windows.contains_key(&win)
        && !state.surface_win.contains_key(&surface)
        && !state.x11_windows.contains_key(&xid);
    debug_assert!(vacant, "duplicate x11 window registration");
    if !vacant {
        return;
    }
    let old_surface = state.surface_win.insert(surface.clone(), win);
    let old_window = state.windows.insert(win, Win::new_x11(x11, surface));
    let old_xid = state.x11_windows.insert(xid, win);
    debug_assert!(old_surface.is_none(), "x11 surface replaced an existing id");
    debug_assert!(old_window.is_none(), "x11 window replaced an existing id");
    debug_assert!(old_xid.is_none(), "x11 id replaced an existing window");
}

/// Announce a mapped X11 window to the presenter.
///
/// An override-redirect window with a resolvable transient parent becomes a host
/// popup at its own X11 geometry; everything else becomes a toplevel carrying its
/// X11 identity.
pub fn announce_x11(state: &mut State, win: u32, w: u32, h: u32) {
    debug_assert!(win != 0, "announcing reserved window id 0");
    debug_assert!(w > 0 && h > 0, "announcing a zero-sized x11 window");
    let Some(x11) = state.windows.get(&win).and_then(|x| x.x11().cloned()) else {
        return;
    };
    let title = x11.title();
    let class = x11.class();
    if let Some(x) = state.windows.get_mut(&win) {
        x.app_id.clone_from(&class);
        x.title.clone_from(&title);
        x.size = (w, h);
        x.announced = true;
    }
    if x11.is_override_redirect()
        && let Some((parent, pos)) = x11_popup_target(state, &x11)
    {
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
        return;
    }
    let msg = x11_identity(state, &x11, win, (w, h));
    state.enqueue(T_WIN_NEW, serde_json::to_vec(&msg).unwrap_or_default());
}

/// Emit a `popup_moved` when a live, announced override-redirect popup's origin
/// changes relative to its parent; toplevel-presented windows are ignored.
fn reposition_x11_popup(state: &mut State, window: &X11Surface) {
    if !window.is_override_redirect() {
        return;
    }
    let Some(win) = host_win_of_x11(state, window.window_id()) else {
        return;
    };
    let announced = state
        .windows
        .get(&win)
        .is_some_and(|x| x.announced && x.mapped);
    if !announced {
        return;
    }
    let Some((_, pos)) = x11_popup_target(state, window) else {
        return;
    };
    let msg = PopupMoved {
        win,
        x: pos.0,
        y: pos.1,
    };
    state.enqueue(T_POPUP_MOVED, serde_json::to_vec(&msg).unwrap_or_default());
}

/// Build the identity-bearing `win_new` for an X11 toplevel. `modal` is a
/// heuristic — smithay 0.7 does not surface `_NET_WM_STATE_MODAL`, so a
/// transient dialog stands in for it.
fn x11_identity(state: &State, x11: &X11Surface, win: u32, size: (u32, u32)) -> WinNewFull {
    debug_assert!(win != 0, "identity for reserved window id 0");
    debug_assert!(x11.alive(), "identity for a dead x11 window");
    let class = x11.class();
    let instance = x11.instance();
    let transient_for = x11
        .is_transient_for()
        .and_then(|xid| host_win_of_x11(state, xid));
    let is_dialog = matches!(x11.window_type(), Some(WmWindowType::Dialog));
    let modal = crate::frames::x11_modal(is_dialog, transient_for.is_some());
    WinNewFull {
        win,
        app_id: class.clone(),
        title: x11.title(),
        w: size.0,
        h: size.1,
        scale: state.scale,
        x11: Some(true),
        pid: x11.pid(),
        class: Some(class),
        instance: Some(instance),
        transient_for,
        modal: Some(modal),
    }
}

/// Resolve an override-redirect window's parent host id and its origin relative
/// to that parent, both from X11's absolute-screen geometry. `None` when the
/// window names no transient parent we currently track.
fn x11_popup_target(state: &State, x11: &X11Surface) -> Option<(u32, (i32, i32))> {
    let parent_xid = x11.is_transient_for()?;
    let parent_win = host_win_of_x11(state, parent_xid)?;
    let parent_geo = state
        .windows
        .get(&parent_win)
        .and_then(|w| w.x11())
        .map(X11Surface::geometry)?;
    let child_geo = x11.geometry();
    debug_assert!(parent_win != 0, "resolved reserved parent id 0");
    let offset = crate::frames::x11_popup_offset(
        (parent_geo.loc.x, parent_geo.loc.y),
        (child_geo.loc.x, child_geo.loc.y),
    );
    Some((parent_win, offset))
}

fn host_win_of_x11(state: &State, xid: X11Window) -> Option<u32> {
    debug_assert!(xid != 0, "lookup of reserved x11 window id 0");
    state.x11_windows.get(&xid).copied()
}

smithay::delegate_xwayland_shell!(State);
