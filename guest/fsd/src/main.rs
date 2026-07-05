//! msl-fsd: the guest read-only file-service worker. The agent forks and execs
//! it inside a distro's mount namespace, handing the accepted vsock fd on fd 3.
//! It serves the `msl-wire::fs` protocol against the live ext4 root, resolving
//! every node from a pinned `O_PATH` root so names cannot escape the volume.

// The Linux fd backend and serve loop compile only for the guest; the host
// build runs the portable node-table/dispatch tests against the mock backend.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

mod backend;
mod names;
mod nodes;
mod serve;
mod stat;

#[cfg(target_os = "linux")]
mod backend_linux;

#[cfg(target_os = "linux")]
fn main() {
    std::process::exit(backend_linux::run());
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("msl-fsd runs only on linux");
    std::process::exit(1);
}
