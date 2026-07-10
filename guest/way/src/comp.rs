//! Smithay compositor state and Wayland handler wiring (guest-only).
//!
//! Terminates xdg-shell toplevels, tracks their lifecycle, and turns commits
//! into surface-protocol messages queued on [`State::out`] for the event loop.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use smithay::input::keyboard::KeyboardHandle;
use smithay::input::pointer::{CursorImageStatus, PointerHandle};
use smithay::input::{Seat, SeatHandler, SeatState};
use smithay::output::{Mode as OutputMode, Output, Scale};
use smithay::reexports::wayland_server::backend::{ClientData, ClientId, DisconnectReason};
use smithay::reexports::wayland_server::protocol::wl_buffer::WlBuffer;
use smithay::reexports::wayland_server::protocol::wl_callback::WlCallback;
use smithay::reexports::wayland_server::protocol::wl_seat::WlSeat;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::reexports::wayland_server::{Client, DisplayHandle, Resource};
use smithay::utils::Serial;
use smithay::wayland::buffer::BufferHandler;
use smithay::wayland::compositor::{
    CompositorClientState, CompositorHandler, CompositorState, with_states,
};
use smithay::wayland::fractional_scale::{
    FractionalScaleHandler, FractionalScaleManagerState, with_fractional_scale,
};
use smithay::wayland::output::OutputHandler;
use smithay::wayland::selection::SelectionHandler;
use smithay::wayland::selection::data_device::{
    ClientDndGrabHandler, DataDeviceHandler, DataDeviceState, ServerDndGrabHandler,
};
use smithay::wayland::shell::xdg::{
    Configure as XdgConfigure, PopupSurface, PositionerState, ToplevelSurface, XdgShellHandler,
    XdgShellState, XdgToplevelSurfaceData,
};
use smithay::wayland::shm::{ShmHandler, ShmState};
use smithay::wayland::viewporter::ViewporterState;
use smithay::wayland::xwayland_shell::XWaylandShellState;
use smithay::xwayland::xwm::X11Window;
use smithay::xwayland::{X11Surface, X11Wm};

use crate::frames;
use crate::ledger::Ledger;
use crate::remote::{OutFrame, PROTOCOL_VERSION};

const MAX_OUT_QUEUE: usize = 4096;

/// Virtual output geometry advertised from startup; the host presents each
/// toplevel in its own native window, so the resolution is nominal.
pub const OUTPUT_W: i32 = 1920;
pub const OUTPUT_H: i32 = 1080;
pub const DEFAULT_REFRESH_HZ: u32 = 60;

/// A window's shell role.
///
/// Toplevels carry the host size-authority machine; popups are client-sized and
/// anchored to `parent` (a win id) at `pos` (parent-geometry-relative logical
/// points). `X11` wraps an `XWayland` surface, whose presentation (toplevel vs.
/// override-redirect popup) is derived from the X11 window at announce time
/// rather than from a second shell object.
pub enum WinRole {
    Toplevel(ToplevelSurface),
    Popup {
        popup: PopupSurface,
        parent: u32,
        pos: (i32, i32),
    },
    X11(X11Surface),
}

/// One remoted window: its Wayland role and handles, current attributes mirrored
/// to the host, held frame callbacks (released on `present_ack`), and pacing
/// state.
///
/// The serial ring and limits stay inert for popups.
pub struct Win {
    pub role: WinRole,
    pub surface: WlSurface,
    pub app_id: String,
    pub title: String,
    pub size: (u32, u32),
    pub mapped: bool,
    pub announced: bool,
    pub prev_buffer_size: (u32, u32),
    pub held_callbacks: Vec<WlCallback>,
    pub pacing: frames::Pacing,
    pub serials: frames::ConfigureRing,
    pub limits: (u32, u32, u32, u32),
    pub pending: Option<frames::FullBuffer>,
    pub pending_t_commit: u64,
    pub pending_serial: u32,
    pub last_frame: Option<frames::FullBuffer>,
}

impl Win {
    fn with_role(role: WinRole, surface: WlSurface) -> Self {
        Self {
            role,
            surface,
            app_id: String::new(),
            title: String::new(),
            size: (0, 0),
            mapped: false,
            announced: false,
            prev_buffer_size: (0, 0),
            held_callbacks: Vec::new(),
            pacing: frames::Pacing::new(frames::FRAME_STARVATION_NS),
            serials: frames::ConfigureRing::new(),
            limits: (0, 0, 0, 0),
            pending: None,
            pending_t_commit: 0,
            pending_serial: 0,
            last_frame: None,
        }
    }

    fn new(toplevel: ToplevelSurface, surface: WlSurface) -> Self {
        Self::with_role(WinRole::Toplevel(toplevel), surface)
    }

    #[must_use]
    pub fn new_x11(x11: X11Surface, surface: WlSurface) -> Self {
        debug_assert!(surface.is_alive(), "x11 window on dead surface");
        debug_assert!(x11.alive(), "x11 window backing is dead");
        Self::with_role(WinRole::X11(x11), surface)
    }

    #[must_use]
    pub fn new_popup(
        popup: PopupSurface,
        surface: WlSurface,
        parent: u32,
        pos: (i32, i32),
    ) -> Self {
        debug_assert!(parent != 0, "popup parent is reserved id 0");
        Self::with_role(WinRole::Popup { popup, parent, pos }, surface)
    }

    #[must_use]
    pub const fn toplevel(&self) -> Option<&ToplevelSurface> {
        match &self.role {
            WinRole::Toplevel(t) => Some(t),
            WinRole::Popup { .. } | WinRole::X11(_) => None,
        }
    }

    #[must_use]
    pub const fn popup(&self) -> Option<&PopupSurface> {
        match &self.role {
            WinRole::Popup { popup, .. } => Some(popup),
            WinRole::Toplevel(_) | WinRole::X11(_) => None,
        }
    }

    #[must_use]
    pub const fn x11(&self) -> Option<&X11Surface> {
        match &self.role {
            WinRole::X11(x11) => Some(x11),
            WinRole::Toplevel(_) | WinRole::Popup { .. } => None,
        }
    }

    #[must_use]
    pub const fn is_popup(&self) -> bool {
        matches!(self.role, WinRole::Popup { .. })
    }

    #[must_use]
    pub const fn is_toplevel(&self) -> bool {
        matches!(self.role, WinRole::Toplevel(_))
    }

    #[must_use]
    pub const fn is_x11(&self) -> bool {
        matches!(self.role, WinRole::X11(_))
    }

    #[must_use]
    pub const fn parent(&self) -> Option<u32> {
        match self.role {
            WinRole::Popup { parent, .. } => Some(parent),
            WinRole::Toplevel(_) | WinRole::X11(_) => None,
        }
    }

    pub fn set_popup_pos(&mut self, pos: (i32, i32)) {
        debug_assert!(self.is_popup(), "popup position set on a toplevel");
        if let WinRole::Popup { pos: p, .. } = &mut self.role {
            *p = pos;
        }
    }
}

pub struct State {
    pub dh: DisplayHandle,
    pub compositor: CompositorState,
    pub shm: ShmState,
    pub xdg: XdgShellState,
    pub seats: SeatState<Self>,
    pub seat: Seat<Self>,
    pub keyboard: KeyboardHandle<Self>,
    pub pointer: PointerHandle<Self>,
    pub output: Output,
    pub data_device: DataDeviceState,
    pub viewporter: ViewporterState,
    pub fractional: FractionalScaleManagerState,
    pub windows: HashMap<u32, Win>,
    pub surface_win: HashMap<WlSurface, u32>,
    pub x11_windows: HashMap<X11Window, u32>,
    pub focus: Option<u32>,
    pub next_win: u32,
    pub seq: u32,
    pub scale: f64,
    pub refresh_hz: u32,
    pub epoch: Instant,
    pub ledger: Ledger,
    pub out: Vec<OutFrame>,
    pub dropped_input: u64,
    pub grabs: crate::popups::GrabStack,
    pub dismissed: crate::popups::DismissedSet,
    pub warned_popup_configure: bool,
    pub xwayland_shell: XWaylandShellState,
    pub xwm: Option<X11Wm>,
    /// Set by the SIGTERM/SIGINT handler; the run loop returns on the next wake
    /// so `State` drops and the `XWayland` `X11Lock` unlinks its `/tmp/.X11-unix`
    /// socket instead of leaking on an abrupt kill.
    pub shutdown: bool,
}

impl State {
    #[must_use]
    pub fn now_ns(&self) -> u64 {
        let ns = self.epoch.elapsed().as_nanos();
        debug_assert!(
            ns <= u128::from(u64::MAX),
            "monotonic clock exceeded u64 ns"
        );
        u64::try_from(ns).unwrap_or(u64::MAX)
    }

    #[must_use]
    pub fn now_ms(&self) -> u32 {
        let ms = self.epoch.elapsed().as_millis();
        u32::try_from(ms & u128::from(u32::MAX)).unwrap_or(0)
    }

    /// Queue a guest→host frame, dropping the oldest when the host is absent or
    /// slow so a stalled link cannot grow memory without bound.
    pub fn enqueue(&mut self, msg_type: u32, payload: Vec<u8>) {
        debug_assert!(msg_type != 0, "message type 0 is reserved");
        debug_assert!(self.out.len() <= MAX_OUT_QUEUE, "queue exceeded cap");
        if self.out.len() >= MAX_OUT_QUEUE {
            self.out.remove(0);
        }
        self.out.push(OutFrame { msg_type, payload });
    }

    #[must_use]
    pub const fn next_seq(&mut self) -> u32 {
        self.seq = self.seq.wrapping_add(1);
        self.seq
    }

    #[must_use]
    pub fn win_id_of(&self, surface: &WlSurface) -> Option<u32> {
        self.surface_win.get(surface).copied()
    }

    #[must_use]
    pub fn next_pacing_timeout(&self, now_ns: u64) -> Option<Duration> {
        self.windows
            .values()
            .filter_map(|win| win.pacing.remaining_timeout(now_ns))
            .min()
    }

    /// Push the current scale/refresh onto the `wl_output` global; Smithay emits
    /// the updated mode/scale and a `done` to bound clients.
    pub fn sync_output(&self) {
        debug_assert!(self.refresh_hz > 0, "refresh must be positive");
        debug_assert!(self.scale > 0.0, "scale must be positive");
        let refresh = i32::try_from(self.refresh_hz.saturating_mul(1000)).unwrap_or(60_000);
        let mode = OutputMode {
            size: (OUTPUT_W, OUTPUT_H).into(),
            refresh,
        };
        self.output.change_current_state(
            Some(mode),
            None,
            Some(Scale::Integer(output_scale(self.scale))),
            None,
        );
        for win in self.windows.values() {
            if win.mapped {
                push_preferred_scale(&win.surface, self.scale);
            }
        }
    }
}

fn push_preferred_scale(surface: &WlSurface, scale: f64) {
    debug_assert!(scale > 0.0, "preferred scale must be positive");
    debug_assert!(scale.is_finite(), "preferred scale must be finite");
    with_states(surface, |states| {
        with_fractional_scale(states, |fs| fs.set_preferred_scale(scale));
    });
}

fn output_scale(scale: f64) -> i32 {
    let s = scale.round();
    if s.is_finite() && (1.0..=16.0).contains(&s) {
        // s is bounded to [1, 16] by the guard, so the cast is exact.
        #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
        let v = s as i32;
        v
    } else {
        1
    }
}

#[derive(Default)]
pub struct ClientState {
    pub compositor: CompositorClientState,
}

impl ClientData for ClientState {
    fn initialized(&self, _client_id: ClientId) {}
    fn disconnected(&self, _client_id: ClientId, _reason: DisconnectReason) {}
}

impl CompositorHandler for State {
    fn compositor_state(&mut self) -> &mut CompositorState {
        &mut self.compositor
    }

    // XWayland's connection carries `XWaylandClientData`, not our `ClientState`;
    // the foreign lifetime admits no fallback, and exactly one type is present.
    fn client_compositor_state<'a>(&self, client: &'a Client) -> &'a CompositorClientState {
        if let Some(xwl) = client.get_data::<smithay::xwayland::XWaylandClientData>() {
            return &xwl.compositor_state;
        }
        &client
            .get_data::<ClientState>()
            .expect("wayland client carries neither ClientState nor XWaylandClientData")
            .compositor
    }

    fn commit(&mut self, surface: &WlSurface) {
        debug_assert!(surface.is_alive(), "commit on dead surface");
        frames::on_commit(self, surface);
    }
}

impl BufferHandler for State {
    fn buffer_destroyed(&mut self, _buffer: &WlBuffer) {}
}

impl ShmHandler for State {
    fn shm_state(&self) -> &ShmState {
        &self.shm
    }
}

impl XdgShellHandler for State {
    fn xdg_shell_state(&mut self) -> &mut XdgShellState {
        &mut self.xdg
    }

    fn new_toplevel(&mut self, surface: ToplevelSurface) {
        let win = self.next_win;
        self.next_win = self.next_win.wrapping_add(1);
        debug_assert!(win != 0 || self.next_win != 0, "window id space exhausted");
        let wl = surface.wl_surface().clone();
        surface.with_pending_state(|s| {
            s.states.set(smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel::State::Activated);
        });
        surface.send_configure();
        self.surface_win.insert(wl.clone(), win);
        self.windows.insert(win, Win::new(surface, wl));
        assert!(self.windows.contains_key(&win), "window insert failed");
    }

    fn new_popup(&mut self, surface: PopupSurface, positioner: PositionerState) {
        crate::popups::on_new_popup(self, surface, positioner);
    }

    fn grab(&mut self, surface: PopupSurface, _seat: WlSeat, _serial: Serial) {
        crate::popups::on_grab(self, &surface);
    }

    fn reposition_request(
        &mut self,
        surface: PopupSurface,
        positioner: PositionerState,
        token: u32,
    ) {
        crate::popups::on_reposition(self, &surface, positioner, token);
    }

    fn popup_destroyed(&mut self, surface: PopupSurface) {
        crate::popups::on_popup_destroyed(self, &surface);
    }

    fn toplevel_destroyed(&mut self, surface: ToplevelSurface) {
        let wl = surface.wl_surface();
        if let Some(win) = self.surface_win.remove(wl) {
            self.windows.remove(&win);
            if self.focus == Some(win) {
                self.focus = None;
            }
            let payload = serde_json::to_vec(&crate::remote::WinRef { win }).unwrap_or_default();
            self.enqueue(crate::remote::T_WIN_DESTROY, payload);
        }
    }

    fn title_changed(&mut self, surface: ToplevelSurface) {
        let title = read_toplevel_title(surface.wl_surface());
        if let Some(win) = self.win_id_of(surface.wl_surface()) {
            let changed = self.windows.get(&win).is_some_and(|w| w.title != title);
            if changed {
                if let Some(w) = self.windows.get_mut(&win) {
                    w.title.clone_from(&title);
                }
                let msg = crate::remote::WinTitle { win, title };
                let payload = serde_json::to_vec(&msg).unwrap_or_default();
                self.enqueue(crate::remote::T_WIN_TITLE, payload);
            }
        }
    }

    fn ack_configure(&mut self, surface: WlSurface, configure: XdgConfigure) {
        debug_assert!(surface.is_alive(), "ack_configure on dead surface");
        let top = match configure {
            XdgConfigure::Toplevel(top) => top,
            // Popups have no host serial mapping; their acks carry nothing.
            XdgConfigure::Popup(_) => return,
        };
        let xdg_serial = u32::from(top.serial);
        let Some(win) = self.win_id_of(&surface) else {
            return;
        };
        debug_assert!(win != 0, "reserved window id 0 in registry");
        if let Some(w) = self.windows.get_mut(&win) {
            w.serials.resolve(xdg_serial);
        }
    }
}

impl SeatHandler for State {
    type KeyboardFocus = WlSurface;
    type PointerFocus = WlSurface;
    type TouchFocus = WlSurface;

    fn seat_state(&mut self) -> &mut SeatState<Self> {
        &mut self.seats
    }

    fn cursor_image(&mut self, _seat: &Seat<Self>, image: CursorImageStatus) {
        let (win, name) = match &image {
            CursorImageStatus::Named(icon) => (self.focus.unwrap_or(0), icon.name().to_string()),
            _ => (self.focus.unwrap_or(0), "default".to_string()),
        };
        let msg = crate::remote::CursorNamed { win, name };
        let payload = serde_json::to_vec(&msg).unwrap_or_default();
        self.enqueue(crate::remote::T_CURSOR_NAMED, payload);
    }

    fn focus_changed(&mut self, _seat: &Seat<Self>, focused: Option<&WlSurface>) {
        let next = focused.and_then(|s| self.win_id_of(s));
        let prev = self.focus;
        if prev != next {
            self.set_x11_activation(prev, false);
            self.set_x11_activation(next, true);
        }
        self.focus = next;
    }
}

impl State {
    /// Mirror keyboard focus onto an X11 window's activation/stacking; a no-op
    /// for missing or non-X11 windows so xdg focus is unaffected.
    fn set_x11_activation(&mut self, win: Option<u32>, activated: bool) {
        let Some(win) = win else { return };
        debug_assert!(win != 0, "reserved window id 0 in focus change");
        let Some(x11) = self.windows.get(&win).and_then(|w| w.x11().cloned()) else {
            return;
        };
        let _ = x11.set_activated(activated);
        if activated && let Some(xwm) = self.xwm.as_mut() {
            let _ = xwm.raise_window(&x11);
        }
    }
}

#[must_use]
pub fn read_toplevel_title(surface: &WlSurface) -> String {
    with_states(surface, |states| {
        states
            .data_map
            .get::<XdgToplevelSurfaceData>()
            .and_then(|d| d.lock().ok().and_then(|g| g.title.clone()))
            .unwrap_or_default()
    })
}

#[must_use]
pub fn read_toplevel_app_id(surface: &WlSurface) -> String {
    with_states(surface, |states| {
        states
            .data_map
            .get::<XdgToplevelSurfaceData>()
            .and_then(|d| d.lock().ok().and_then(|g| g.app_id.clone()))
            .unwrap_or_default()
    })
}

/// The protocol version this compositor speaks; sent in `hello`.
#[must_use]
pub const fn protocol_version() -> u32 {
    PROTOCOL_VERSION
}

impl OutputHandler for State {}

impl FractionalScaleHandler for State {
    fn new_fractional_scale(&mut self, surface: WlSurface) {
        push_preferred_scale(&surface, self.scale);
    }
}

impl SelectionHandler for State {
    type SelectionUserData = ();
}

impl ClientDndGrabHandler for State {}
impl ServerDndGrabHandler for State {}

impl DataDeviceHandler for State {
    fn data_device_state(&self) -> &DataDeviceState {
        &self.data_device
    }
}

smithay::delegate_compositor!(State);
smithay::delegate_shm!(State);
smithay::delegate_xdg_shell!(State);
smithay::delegate_seat!(State);
smithay::delegate_output!(State);
smithay::delegate_data_device!(State);
smithay::delegate_viewporter!(State);
smithay::delegate_fractional_scale!(State);
