//! `mac`: the msl guest interop shim. It dials the host daemon on vsock port
//! 5010, forwards `mac <command> [args...]`, and proxies the command's
//! stdin/stdout/stderr/exit back to the caller (ADR 0008). Ships in the
//! initramfs, projected into every distro as /usr/local/bin/mac.

// The pure wire helpers in `proto` are exercised by the host unit tests; the
// host bin build itself only reaches the non-linux stub, leaving them unused.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

mod proto;

#[cfg(target_os = "linux")]
mod session;
#[cfg(target_os = "linux")]
mod tty;

#[cfg(target_os = "linux")]
fn main() {
    std::process::exit(session::run());
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("mac shim requires linux");
    std::process::exit(255);
}
