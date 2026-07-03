//! msl-way: a headless Smithay compositor that terminates Wayland inside a
//! distro and remotes toplevels to the macOS host over vsock (ADR 0011, surface
//! protocol v0). The pure codec/ledger/pacing modules build on every host; the
//! Smithay-backed compositor and vsock transport are guest-only.

// Internal binary crate: the io::Error values these codecs return are
// self-describing, so per-function `# Errors` prose is noise.
#![allow(clippy::missing_errors_doc)]

pub mod frames;
pub mod ledger;
pub mod remote;

#[cfg(target_os = "linux")]
pub mod comp;
#[cfg(target_os = "linux")]
pub mod input;
