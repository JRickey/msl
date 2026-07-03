//! Smithay compositor state and Wayland handler wiring (guest-only).
//!
//! Terminates xdg-shell toplevels, tracks their lifecycle, and turns commits
//! into surface-protocol messages queued on [`State::out`] for the event loop.

use std::collections::HashMap;
use std::time::Instant;

use smithay::input::keyboard::KeyboardHandle;
use smithay::input::pointer::{CursorImageStatus, PointerHandle};
use smithay::input::{Seat, SeatHandler, SeatState};
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
use smithay::wayland::shell::xdg::{
    PopupSurface, PositionerState, ToplevelSurface, XdgShellHandler, XdgShellState,
    XdgToplevelSurfaceData,
};
use smithay::wayland::shm::{ShmHandler, ShmState};

use crate::frames;
use crate::ledger::Ledger;
use crate::remote::{OutFrame, PROTOCOL_VERSION};

const MAX_OUT_QUEUE: usize = 4096;

/// One remoted toplevel: its Wayland handles, current attributes mirrored to the
/// host, held frame callbacks (released on `present_ack`), and pacing state.
pub struct Win {
    pub toplevel: ToplevelSurface,
    pub surface: WlSurface,
    pub app_id: String,
    pub title: String,
    pub size: (u32, u32),
    pub mapped: bool,
    pub announced: bool,
    pub prev_buffer_size: (u32, u32),
    pub held_callbacks: Vec<WlCallback>,
    pub pacing: frames::Pacing,
    pub pending: Option<frames::FullBuffer>,
    pub pending_t_commit: u64,
    pub last_frame: Option<frames::FullBuffer>,
}

impl Win {
    fn new(toplevel: ToplevelSurface, surface: WlSurface) -> Self {
        Self {
            toplevel,
            surface,
            app_id: String::new(),
            title: String::new(),
            size: (0, 0),
            mapped: false,
            announced: false,
            prev_buffer_size: (0, 0),
            held_callbacks: Vec::new(),
            pacing: frames::Pacing::new(frames::FRAME_STARVATION_NS),
            pending: None,
            pending_t_commit: 0,
            last_frame: None,
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
    pub windows: HashMap<u32, Win>,
    pub surface_win: HashMap<WlSurface, u32>,
    pub focus: Option<u32>,
    pub next_win: u32,
    pub seq: u32,
    pub scale: f64,
    pub refresh_hz: u32,
    pub epoch: Instant,
    pub ledger: Ledger,
    pub out: Vec<OutFrame>,
    pub dropped_input: u64,
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

    fn client_compositor_state<'a>(&self, client: &'a Client) -> &'a CompositorClientState {
        &client
            .get_data::<ClientState>()
            .expect("client missing ClientState")
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

    fn new_popup(&mut self, _surface: PopupSurface, _positioner: PositionerState) {}
    fn grab(&mut self, _surface: PopupSurface, _seat: WlSeat, _serial: Serial) {}
    fn reposition_request(
        &mut self,
        _surface: PopupSurface,
        _positioner: PositionerState,
        _token: u32,
    ) {
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
        self.focus = focused.and_then(|s| self.win_id_of(s));
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

smithay::delegate_compositor!(State);
smithay::delegate_shm!(State);
smithay::delegate_xdg_shell!(State);
smithay::delegate_seat!(State);
