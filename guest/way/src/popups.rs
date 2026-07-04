//! Popup remoting: the grab stack policy and the xdg-popup handler bodies.
//!
//! The [`GrabStack`] and [`DismissedSet`] policies are pure and host-testable;
//! the Smithay-touching handlers (new/grab/reposition/destroy and the dismissal
//! cascade) are guest-only.

use std::collections::HashSet;

/// Live-popup ceiling per compositor. Bounds the grab stack and every
/// dismissal cascade; `new_popup` past it falls back to immediate dismissal.
pub const POPUP_CAP: usize = 16;

/// Popup wins that have already been sent `popup_done` and not yet destroyed.
///
/// The guest (outside-press) and the host (`popup_dismiss`) can name the same
/// popup; a second `popup_done` on a live surface would put a duplicate
/// `xdg_popup.done` on the wire, which Smithay does not guard. This makes the
/// second delivery a no-op, as the wire contract requires. Bounded by the live
/// popup count (≤ [`POPUP_CAP`]): entries are dropped when the client's destroy
/// lands.
#[derive(Debug, Default)]
pub struct DismissedSet {
    wins: HashSet<u32>,
}

impl DismissedSet {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Record a dismissal; return `true` only the first time (the caller sends
    /// `popup_done` then), `false` if already dismissed (no-op).
    pub fn mark(&mut self, win: u32) -> bool {
        debug_assert!(win != 0, "dismiss reserved window id 0");
        if win == 0 {
            return false;
        }
        self.wins.insert(win)
    }

    /// Forget a popup once its destroy lands, keeping the set bounded.
    pub fn forget(&mut self, win: u32) {
        debug_assert!(win != 0, "forget reserved window id 0");
        let _ = self.wins.remove(&win);
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.wins.len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.wins.is_empty()
    }

    #[must_use]
    pub fn contains(&self, win: u32) -> bool {
        self.wins.contains(&win)
    }
}

/// The chain of grabbing popups, bottom (root-most) first, topmost (deepest
/// nested) last.
///
/// Grabs form a parent chain by xdg-shell rule, so the entry below a dismissed
/// popup is the one that inherits keyboard focus.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct GrabStack {
    stack: Vec<u32>,
}

impl GrabStack {
    #[must_use]
    pub const fn new() -> Self {
        Self { stack: Vec::new() }
    }

    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.stack.is_empty()
    }

    #[must_use]
    pub const fn len(&self) -> usize {
        self.stack.len()
    }

    #[must_use]
    pub fn topmost(&self) -> Option<u32> {
        self.stack.last().copied()
    }

    #[must_use]
    pub fn bottom(&self) -> Option<u32> {
        self.stack.first().copied()
    }

    #[must_use]
    pub fn contains(&self, win: u32) -> bool {
        self.stack.contains(&win)
    }

    /// Push a grab; reject a reserved id, a full stack, or a duplicate.
    pub fn push(&mut self, win: u32) -> bool {
        debug_assert!(win != 0, "grab for reserved window id 0");
        debug_assert!(self.stack.len() <= POPUP_CAP, "grab stack over cap");
        if win == 0 || self.stack.len() >= POPUP_CAP || self.stack.contains(&win) {
            return false;
        }
        self.stack.push(win);
        true
    }

    /// Remove `win` and every grab above it; return them topmost-first, ending
    /// with `win`. Empty when `win` is not on the stack.
    pub fn cascade_from(&mut self, win: u32) -> Vec<u32> {
        debug_assert!(self.stack.len() <= POPUP_CAP, "grab stack over cap");
        let Some(idx) = self.stack.iter().position(|&w| w == win) else {
            return Vec::new();
        };
        let mut removed = self.stack.split_off(idx);
        debug_assert_eq!(removed.first().copied(), Some(win), "split starts at win");
        removed.reverse();
        debug_assert_eq!(
            removed.last().copied(),
            Some(win),
            "win is deepest dismissed"
        );
        removed
    }

    /// Remove a single grab (a client-destroyed popup); report whether present.
    pub fn remove(&mut self, win: u32) -> bool {
        debug_assert!(self.stack.len() <= POPUP_CAP, "grab stack over cap");
        let Some(idx) = self.stack.iter().position(|&w| w == win) else {
            return false;
        };
        let _ = self.stack.remove(idx);
        debug_assert!(!self.stack.contains(&win), "duplicate grab entry");
        true
    }

    pub fn clear(&mut self) {
        debug_assert!(self.stack.len() <= POPUP_CAP, "grab stack over cap");
        self.stack.clear();
        debug_assert!(self.stack.is_empty(), "stack not cleared");
    }
}

#[cfg(target_os = "linux")]
mod linux {
    use smithay::input::keyboard::KeyboardHandle;
    use smithay::reexports::wayland_server::Resource;
    use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
    use smithay::utils::SERIAL_COUNTER;
    use smithay::wayland::shell::xdg::{PopupSurface, PositionerState};

    use super::POPUP_CAP;
    use crate::comp::{State, Win};
    use crate::remote::{PopupMoved, T_POPUP_MOVED, T_WIN_DESTROY, WinRef};

    /// Count of live popups; caps `new_popup` and bounds every cascade loop.
    fn count_popups(state: &State) -> usize {
        let mut n = 0usize;
        for w in state.windows.values() {
            if w.is_popup() {
                n = n.saturating_add(1);
            }
        }
        debug_assert!(n <= state.windows.len(), "popup count exceeds window count");
        n
    }

    /// Complete the xdg handshake and dismiss immediately (the fallback policy
    /// when a popup cannot be remoted), so no client ever wedges.
    fn fallback_dismiss(surface: &PopupSurface, positioner: PositionerState) {
        debug_assert!(surface.wl_surface().is_alive(), "fallback on dead popup");
        surface.with_pending_state(|s| {
            s.geometry = positioner.get_geometry();
            s.positioner = positioner;
        });
        match surface.send_configure() {
            Ok(_) => surface.send_popup_done(),
            Err(e) => eprintln!("msl-way: popup configure failed: {e}"),
        }
    }

    pub fn on_new_popup(state: &mut State, surface: PopupSurface, positioner: PositionerState) {
        debug_assert!(surface.wl_surface().is_alive(), "popup on dead surface");
        if !surface.wl_surface().is_alive() {
            return;
        }
        let parent = surface
            .get_parent_surface()
            .and_then(|s| state.win_id_of(&s));
        let Some(parent) = parent else {
            fallback_dismiss(&surface, positioner);
            return;
        };
        if count_popups(state) >= POPUP_CAP {
            fallback_dismiss(&surface, positioner);
            return;
        }
        debug_assert!(parent != 0, "popup parent is reserved id 0");
        let win = state.next_win;
        state.next_win = state.next_win.wrapping_add(1);
        debug_assert!(win != 0 || state.next_win != 0, "window id space exhausted");
        let geo = positioner.get_geometry();
        let pos = (geo.loc.x, geo.loc.y);
        surface.with_pending_state(|s| {
            s.geometry = geo;
            s.positioner = positioner;
        });
        if let Err(e) = surface.send_configure() {
            eprintln!("msl-way: popup configure failed: {e}");
            return;
        }
        let wl = surface.wl_surface().clone();
        state.surface_win.insert(wl.clone(), win);
        state
            .windows
            .insert(win, crate::comp::Win::new_popup(surface, wl, parent, pos));
        debug_assert!(state.windows.contains_key(&win), "popup insert failed");
    }

    pub fn on_grab(state: &mut State, surface: &PopupSurface) {
        debug_assert!(surface.wl_surface().is_alive(), "grab on dead popup");
        let Some(win) = state.win_id_of(surface.wl_surface()) else {
            return;
        };
        if !state.windows.get(&win).is_some_and(Win::is_popup) {
            return;
        }
        if !state.grabs.push(win) {
            return;
        }
        let wl = surface.wl_surface().clone();
        set_keyboard_focus(state, Some(wl));
    }

    pub fn on_reposition(
        state: &mut State,
        surface: &PopupSurface,
        positioner: PositionerState,
        token: u32,
    ) {
        debug_assert!(surface.wl_surface().is_alive(), "reposition on dead popup");
        let Some(win) = state.win_id_of(surface.wl_surface()) else {
            return;
        };
        if !state.windows.get(&win).is_some_and(Win::is_popup) {
            return;
        }
        let geo = positioner.get_geometry();
        let pos = (geo.loc.x, geo.loc.y);
        surface.with_pending_state(|s| {
            s.geometry = geo;
            s.positioner = positioner;
        });
        // send_repositioned emits the repositioned event and the configure in
        // one shot; a separate send_configure would double-configure.
        let _ = surface.send_repositioned(token);
        let announced = state.windows.get(&win).is_some_and(|w| w.announced);
        if let Some(w) = state.windows.get_mut(&win) {
            w.set_popup_pos(pos);
        }
        if announced {
            let msg = PopupMoved {
                win,
                x: pos.0,
                y: pos.1,
            };
            state.enqueue(T_POPUP_MOVED, serde_json::to_vec(&msg).unwrap_or_default());
        }
    }

    pub fn on_popup_destroyed(state: &mut State, surface: &PopupSurface) {
        let Some(win) = state.surface_win.remove(surface.wl_surface()) else {
            return;
        };
        let parent = state.windows.get(&win).and_then(Win::parent);
        let held_focus = state.focus == Some(win);
        let _ = state.grabs.remove(win);
        state.dismissed.forget(win);
        let _ = state.windows.remove(&win);
        if state.focus == Some(win) {
            state.focus = None;
        }
        let payload = serde_json::to_vec(&WinRef { win }).unwrap_or_default();
        state.enqueue(T_WIN_DESTROY, payload);
        if held_focus {
            restore_focus_after(state, parent);
        }
        debug_assert!(!state.windows.contains_key(&win), "popup not removed");
    }

    /// Send `popup_done` to a live popup at most once between its creation and
    /// destroy, so the two dismiss authorities cannot double-deliver.
    fn send_done_once(state: &mut State, win: u32) {
        debug_assert!(win != 0, "dismiss reserved window id 0");
        if !state.windows.get(&win).is_some_and(Win::is_popup) {
            return;
        }
        if !state.dismissed.mark(win) {
            return;
        }
        if let Some(p) = state.windows.get(&win).and_then(|e| e.popup()) {
            p.send_popup_done();
        }
        debug_assert!(
            state.dismissed.len() <= POPUP_CAP,
            "dismissed set over bound"
        );
    }

    /// Dismiss `win` and every grab above it: `popup_done` topmost-first.
    ///
    /// Keyboard focus is restored to the deepest survivor or the parent toplevel
    /// only when a dismissed popup actually held it. A grab-less tooltip
    /// dismissed by the host never had focus, and stealing it back would fight
    /// the deactivation that triggered the dismissal.
    pub fn dismiss_cascade(state: &mut State, win: u32) {
        debug_assert!(win != 0, "dismiss reserved window id 0");
        debug_assert!(state.grabs.len() <= POPUP_CAP, "grab stack over cap");
        if !state.windows.get(&win).is_some_and(Win::is_popup) {
            return;
        }
        let parent = state.windows.get(&win).and_then(Win::parent);
        let mut targets = state.grabs.cascade_from(win);
        if targets.is_empty() {
            targets.push(win);
        }
        debug_assert!(targets.len() <= POPUP_CAP + 1, "dismiss set over bound");
        let focus_dismissed = state.focus.is_some_and(|f| targets.contains(&f));
        for &w in &targets {
            send_done_once(state, w);
        }
        if focus_dismissed {
            restore_focus_after(state, parent);
        }
    }

    /// Dismiss every grabbed popup (outside-press). No-op when none are grabbed.
    pub fn dismiss_all_grabs(state: &mut State) {
        let Some(bottom) = state.grabs.bottom() else {
            return;
        };
        dismiss_cascade(state, bottom);
    }

    /// Dismiss every live popup regardless of grab (host reconnect); the grab
    /// stack is cleared for the fresh presenter, which replays toplevels only.
    pub fn dismiss_all_popups(state: &mut State) {
        debug_assert!(state.grabs.len() <= POPUP_CAP, "grab stack over cap");
        let popups: Vec<u32> = state
            .windows
            .iter()
            .filter(|(_, w)| w.is_popup())
            .map(|(k, _)| *k)
            .collect();
        for &win in &popups {
            send_done_once(state, win);
        }
        state.grabs.clear();
        debug_assert!(state.grabs.is_empty(), "grabs not cleared on reconnect");
    }

    /// Focus the deepest surviving grab, else the parent toplevel reached by
    /// walking `start` up the popup parent chain.
    fn restore_focus_after(state: &mut State, start: Option<u32>) {
        let target = match state.grabs.topmost() {
            Some(sv) => {
                debug_assert!(state.windows.contains_key(&sv), "survivor missing");
                state.windows.get(&sv).map(|w| w.surface.clone())
            }
            None => root_toplevel_surface(state, start),
        };
        set_keyboard_focus(state, target);
    }

    fn root_toplevel_surface(state: &State, start: Option<u32>) -> Option<WlSurface> {
        debug_assert!(
            state.windows.len() >= start.map_or(0, |_| 1),
            "empty registry"
        );
        let mut cur = start;
        for _ in 0..=POPUP_CAP {
            let p = cur?;
            let w = state.windows.get(&p)?;
            if w.is_toplevel() {
                return Some(w.surface.clone());
            }
            cur = w.parent();
        }
        None
    }

    fn set_keyboard_focus(state: &mut State, surface: Option<WlSurface>) {
        let kbd: KeyboardHandle<State> = state.keyboard.clone();
        let serial = SERIAL_COUNTER.next_serial();
        kbd.set_focus(state, surface, serial);
    }
}

#[cfg(target_os = "linux")]
pub use linux::{
    dismiss_all_grabs, dismiss_all_popups, dismiss_cascade, on_grab, on_new_popup,
    on_popup_destroyed, on_reposition,
};

#[cfg(test)]
mod tests {
    use super::{DismissedSet, GrabStack, POPUP_CAP};

    #[test]
    fn mark_is_true_once_then_false() {
        let mut d = DismissedSet::new();
        assert!(d.mark(7), "first dismissal sends popup_done");
        assert!(!d.mark(7), "second dismissal for the same win no-ops");
        assert!(d.contains(7));
        assert_eq!(d.len(), 1);
    }

    #[test]
    fn distinct_wins_are_independent() {
        let mut d = DismissedSet::new();
        assert!(d.mark(1));
        assert!(d.mark(2));
        assert!(!d.mark(1), "win 1 already dismissed");
        assert_eq!(d.len(), 2);
    }

    #[test]
    fn forget_unbounds_the_set_and_allows_remark() {
        let mut d = DismissedSet::new();
        assert!(d.mark(4));
        d.forget(4);
        assert!(d.is_empty(), "forget drops the entry when destroy lands");
        assert!(d.mark(4), "a freshly-live win can be dismissed again");
    }

    #[test]
    fn push_rejects_dup_and_reports_topmost() {
        let mut g = GrabStack::new();
        assert!(g.push(3));
        assert!(g.push(4));
        assert!(!g.push(4), "duplicate grab rejected");
        assert_eq!(g.topmost(), Some(4));
        assert_eq!(g.bottom(), Some(3));
        assert!(g.contains(3) && g.contains(4));
    }

    #[test]
    fn push_enforces_cap() {
        let mut g = GrabStack::new();
        for i in 1..=u32::try_from(POPUP_CAP).expect("cap fits u32") {
            assert!(g.push(i), "grab {i} within cap");
        }
        assert_eq!(g.len(), POPUP_CAP);
        assert!(!g.push(999), "cap blocks further grabs");
    }

    #[test]
    fn cascade_from_dismisses_win_and_above_topmost_first() {
        let mut g = GrabStack::new();
        for i in 1..=4 {
            assert!(g.push(i));
        }
        // stack bottom→top: [1, 2, 3, 4]; dismiss from 2 → 4,3,2 topmost-first.
        let dismissed = g.cascade_from(2);
        assert_eq!(dismissed, vec![4, 3, 2]);
        assert_eq!(g.topmost(), Some(1), "survivor is the entry below 2");
        assert_eq!(g.len(), 1);
    }

    #[test]
    fn cascade_from_unknown_is_empty_and_leaves_stack() {
        let mut g = GrabStack::new();
        assert!(g.push(1));
        assert!(g.push(2));
        assert!(
            g.cascade_from(9).is_empty(),
            "unknown win dismisses nothing"
        );
        assert_eq!(g.len(), 2, "stack untouched");
    }

    #[test]
    fn cascade_set_always_contains_former_topmost() {
        // dismiss_cascade restores focus only when a dismissed target held it;
        // under a grab, focus sits on the topmost grab, which every cascade set
        // includes — so the grabbed path always restores. (The full State-level
        // gate — focus not in the target set for a grab-less tooltip — needs a
        // live seat and is exercised by construction, not here.)
        for target in 1..=4u32 {
            let mut g = GrabStack::new();
            for i in 1..=4 {
                assert!(g.push(i));
            }
            let topmost = g.topmost().expect("non-empty stack");
            let dismissed = g.cascade_from(target);
            assert!(
                dismissed.contains(&topmost),
                "cascade from {target} must include former topmost {topmost}"
            );
        }
    }

    #[test]
    fn cascade_from_bottom_clears_and_leaves_no_survivor() {
        let mut g = GrabStack::new();
        for i in 1..=3 {
            assert!(g.push(i));
        }
        let dismissed = g.cascade_from(1);
        assert_eq!(dismissed, vec![3, 2, 1], "whole stack, topmost first");
        assert!(g.is_empty());
        assert_eq!(g.topmost(), None, "no survivor -> focus falls to toplevel");
    }

    #[test]
    fn remove_single_is_order_tolerant() {
        let mut g = GrabStack::new();
        for i in 1..=3 {
            assert!(g.push(i));
        }
        assert!(g.remove(2), "present entry removed");
        assert!(!g.contains(2));
        assert_eq!(g.len(), 2);
        assert!(!g.remove(2), "second remove is a no-op");
        assert_eq!(g.topmost(), Some(3), "topmost survives an interior removal");
    }
}
