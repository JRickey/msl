//! msl-fsd: the guest file-service worker. The agent forks and execs it inside
//! a distro's mount namespace, handing the accepted vsock fd on fd 3.
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
    let Some(read_only) = parse_mode() else {
        eprintln!("usage: msl-fsd (--read-only|--read-write)");
        std::process::exit(2);
    };
    std::process::exit(backend_linux::run(read_only));
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("msl-fsd runs only on linux");
    std::process::exit(1);
}

#[cfg(target_os = "linux")]
fn parse_mode() -> Option<bool> {
    let mut args = std::env::args();
    let _program = args.next()?;
    let mode = args.next()?;
    if args.next().is_some() {
        return None;
    }
    match mode.as_str() {
        "--read-only" => Some(true),
        "--read-write" => Some(false),
        _ => None,
    }
}
