//! Local-terminal control for the shim's tty mode: raw-mode entry with a Drop
//! guard that always restores the saved termios, winsize reads, and a SIGWINCH
//! flag. Every `libc` terminal call is wrapped one-per-fn behind `#[allow]`.

use std::sync::atomic::{AtomicBool, Ordering};

const STDIN_FD: i32 = 0;
const STDOUT_FD: i32 = 1;

static WINCH_PENDING: AtomicBool = AtomicBool::new(false);

#[must_use]
pub fn is_tty() -> bool {
    isatty(STDIN_FD) && isatty(STDOUT_FD)
}

#[allow(unsafe_code)] // C ABI: isatty(3) on a single borrowed fd number.
fn isatty(fd: i32) -> bool {
    assert!(fd >= 0, "isatty needs a valid fd");
    unsafe { libc::isatty(fd) == 1 }
}

// Restores the terminal to the saved attributes when the session ends; the
// shim exits via process::exit, so run() must hold this until after the pump.
pub struct RawGuard {
    saved: libc::termios,
}

impl Drop for RawGuard {
    fn drop(&mut self) {
        let _ = tcsetattr(STDIN_FD, &self.saved);
    }
}

#[must_use]
pub fn enable_raw() -> Option<RawGuard> {
    let saved = tcgetattr(STDIN_FD)?;
    let mut raw = saved;
    cfmakeraw(&mut raw);
    if tcsetattr(STDIN_FD, &raw).is_err() {
        return None;
    }
    Some(RawGuard { saved })
}

#[allow(unsafe_code)] // C ABI: tcgetattr(3) fills a borrowed termios out-param.
fn tcgetattr(fd: i32) -> Option<libc::termios> {
    assert!(fd >= 0, "tcgetattr needs a valid fd");
    let mut term = std::mem::MaybeUninit::<libc::termios>::zeroed();
    let rc = unsafe { libc::tcgetattr(fd, term.as_mut_ptr()) };
    if rc == 0 {
        Some(unsafe { term.assume_init() })
    } else {
        None
    }
}

#[allow(unsafe_code)] // C ABI: cfmakeraw(3) rewrites a borrowed termios in place.
fn cfmakeraw(term: &mut libc::termios) {
    unsafe { libc::cfmakeraw(term) };
}

#[allow(unsafe_code)] // C ABI: tcsetattr(3) applies a borrowed termios.
fn tcsetattr(fd: i32, term: &libc::termios) -> Result<(), ()> {
    assert!(fd >= 0, "tcsetattr needs a valid fd");
    let rc = unsafe { libc::tcsetattr(fd, libc::TCSANOW, term) };
    if rc == 0 { Ok(()) } else { Err(()) }
}

// Current window size from stdin; (0, 0) if the ioctl fails.
#[must_use]
pub fn winsize() -> (u16, u16) {
    read_winsize(STDIN_FD).unwrap_or((0, 0))
}

#[allow(unsafe_code)] // C ABI: TIOCGWINSZ ioctl fills a borrowed winsize.
fn read_winsize(fd: i32) -> Option<(u16, u16)> {
    assert!(fd >= 0, "winsize needs a valid fd");
    let mut ws = std::mem::MaybeUninit::<libc::winsize>::zeroed();
    let rc = unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, ws.as_mut_ptr()) };
    if rc != 0 {
        return None;
    }
    let ws = unsafe { ws.assume_init() };
    Some((ws.ws_row, ws.ws_col))
}

// The signal-handler rule's sanctioned exception: a SIG_ATOMIC-style flag set
// is the only async-signal-safe action, so the handler just stores a bool.
extern "C" fn on_winch(_sig: libc::c_int) {
    WINCH_PENDING.store(true, Ordering::Relaxed);
}

pub fn install_winch() {
    let _ = set_winch_handler();
}

#[allow(unsafe_code)] // C ABI: signal(2) installs the sole sanctioned fn pointer.
fn set_winch_handler() -> bool {
    let handler = on_winch as extern "C" fn(libc::c_int) as libc::sighandler_t;
    debug_assert!(handler != 0, "handler address must be non-null");
    let rc = unsafe { libc::signal(libc::SIGWINCH, handler) };
    rc != libc::SIG_ERR
}

#[must_use]
pub fn take_winch() -> bool {
    WINCH_PENDING.swap(false, Ordering::Relaxed)
}
