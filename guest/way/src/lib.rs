//! msl-way: a headless Smithay compositor that terminates Wayland inside a
//! distro and remotes toplevels to the macOS host over vsock (ADR 0011, surface
//! protocol v0). The pure codec/ledger/pacing modules build on every host; the
//! Smithay-backed compositor and vsock transport are guest-only.

// Internal binary crate: the io::Error values these codecs return are
// self-describing, so per-function `# Errors` prose is noise.
#![allow(clippy::missing_errors_doc)]

pub mod frames;
pub mod ledger;
pub mod popups;
pub mod remote;

#[cfg(target_os = "linux")]
pub mod comp;
#[cfg(target_os = "linux")]
pub mod input;
#[cfg(target_os = "linux")]
pub mod xwm;

/// Wayland globals the compositor must advertise from startup for the supported
/// toolkits (GTK ≥4.12) to accept the display. `build_state` registers exactly
/// this set; `--list-globals` prints it.
pub const REQUIRED_GLOBALS: [&str; 9] = [
    "wl_compositor",
    "wl_subcompositor",
    "wl_shm",
    "wl_output",
    "wl_seat",
    "wl_data_device_manager",
    "wp_viewporter",
    "wp_fractional_scale_manager_v1",
    "xdg_wm_base",
];

#[cfg(test)]
mod tests {
    use super::REQUIRED_GLOBALS;

    #[test]
    fn required_globals_cover_gtk_prerequisites() {
        for want in [
            "wl_compositor",
            "wl_subcompositor",
            "wl_shm",
            "wl_output",
            "wl_seat",
            "wl_data_device_manager",
            "wp_viewporter",
            "wp_fractional_scale_manager_v1",
            "xdg_wm_base",
        ] {
            assert!(REQUIRED_GLOBALS.contains(&want), "missing global {want}");
        }
    }
}
