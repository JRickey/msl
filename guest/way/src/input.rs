//! Host input events → Smithay seat injection (guest-only).
//!
//! Events are routed to the toplevel named by the protocol `win` field: focus
//! follows there, then the event is replayed with fresh serials. An event for an
//! unknown window is counted and dropped. Keycodes arrive in Linux evdev space
//! and take the conventional +8 offset into xkb space.

pub const XKB_EVDEV_OFFSET: u32 = 8;

#[cfg(target_os = "linux")]
mod linux {
    use smithay::backend::input::{Axis, ButtonState, KeyState};
    use smithay::input::keyboard::{FilterResult, Keycode};
    use smithay::input::pointer::{AxisFrame, ButtonEvent, MotionEvent};
    use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
    use smithay::utils::{Point, SERIAL_COUNTER};

    use super::XKB_EVDEV_OFFSET;
    use crate::comp::State;
    use crate::remote::{Key, Pointer};

    /// Resolve the protocol `win` to its surface, optionally forcing keyboard
    /// focus to it, counting and rejecting events addressed to an unknown
    /// window. Under a grab, pointer routing must not move keyboard focus.
    fn target(state: &mut State, win: u32, set_kbd_focus: bool) -> Option<WlSurface> {
        let Some(surface) = state.windows.get(&win).map(|w| w.surface.clone()) else {
            state.dropped_input = state.dropped_input.saturating_add(1);
            return None;
        };
        if set_kbd_focus && state.focus != Some(win) {
            let kbd = state.keyboard.clone();
            let serial = SERIAL_COUNTER.next_serial();
            kbd.set_focus(state, Some(surface.clone()), serial);
        }
        Some(surface)
    }

    pub fn inject_pointer(state: &mut State, ev: &Pointer) {
        debug_assert!(
            ev.x.is_finite() && ev.y.is_finite(),
            "non-finite pointer coords"
        );
        debug_assert!(ev.win != 0, "pointer for reserved window id 0");
        // A press outside every grabbed popup dismisses the whole stack and
        // activates nothing (GTK/macOS menu behavior).
        let outside_press = ev.kind == "button"
            && ev.state != 0
            && !state.grabs.is_empty()
            && !state.grabs.contains(ev.win);
        if outside_press {
            crate::popups::dismiss_all_grabs(state);
            return;
        }
        let set_kbd = state.grabs.is_empty();
        let Some(surface) = target(state, ev.win, set_kbd) else {
            return;
        };
        let ptr = state.pointer.clone();
        let time = state.now_ms();
        // Host coordinates are window-geometry-relative; the surface origin sits
        // a CSD shadow margin above/left of it (protocol window-geometry ruling).
        let (gx, gy) = crate::frames::geometry_offset_logical(&surface);
        match ev.kind.as_str() {
            "motion" | "enter" => {
                let loc = Point::<f64, smithay::utils::Logical>::from((ev.x + gx, ev.y + gy));
                let pair = Some((surface, Point::from((0.0, 0.0))));
                ptr.motion(
                    state,
                    pair,
                    &MotionEvent {
                        location: loc,
                        serial: SERIAL_COUNTER.next_serial(),
                        time,
                    },
                );
                ptr.frame(state);
            }
            "leave" => {
                ptr.motion(
                    state,
                    None,
                    &MotionEvent {
                        location: Point::from((ev.x, ev.y)),
                        serial: SERIAL_COUNTER.next_serial(),
                        time,
                    },
                );
                ptr.frame(state);
            }
            "button" => {
                let bstate = if ev.state == 0 {
                    ButtonState::Released
                } else {
                    ButtonState::Pressed
                };
                ptr.button(
                    state,
                    &ButtonEvent {
                        serial: SERIAL_COUNTER.next_serial(),
                        time,
                        button: ev.button,
                        state: bstate,
                    },
                );
                ptr.frame(state);
            }
            "axis" => {
                let frame = AxisFrame::new(time)
                    .value(Axis::Vertical, ev.dy)
                    .value(Axis::Horizontal, ev.dx);
                ptr.axis(state, frame);
                ptr.frame(state);
            }
            _ => {}
        }
    }

    pub fn inject_key(state: &mut State, ev: &Key) {
        debug_assert!(ev.state <= 1, "key state must be 0 or 1");
        debug_assert!(ev.win != 0, "key for reserved window id 0");
        // Under a grab the popup owns the keyboard: route every key to the
        // topmost popup, ignoring the host's key-window tag (the parent).
        let win = state.grabs.topmost().unwrap_or(ev.win);
        if target(state, win, true).is_none() {
            return;
        }
        let kbd = state.keyboard.clone();
        let time = state.now_ms();
        let kstate = if ev.state == 0 {
            KeyState::Released
        } else {
            KeyState::Pressed
        };
        let code = Keycode::new(ev.keycode.saturating_add(XKB_EVDEV_OFFSET));
        let _ = kbd.input::<(), _>(
            state,
            code,
            kstate,
            SERIAL_COUNTER.next_serial(),
            time,
            |_, _, _| FilterResult::Forward,
        );
    }
}

#[cfg(target_os = "linux")]
pub use linux::{inject_key, inject_pointer};
