//! Shared wire primitives for the msl guest binaries: the length-prefixed
//! frame codec and the `poll`/fd helpers the agent and the `mac` shim both
//! drive over their vsock connections.

// Several helpers are exercised only by the Linux binaries; host builds compile
// this crate for the unit tests, leaving them legitimately unused there.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]
// These two pedantic lints govern public-API docs/annotations. msl-wire is an
// internal, unpublished crate whose only callers are in this workspace; the
// agent ran the same functions as a binary with both lints dormant.
#![allow(clippy::missing_errors_doc, clippy::must_use_candidate)]

pub mod frame;
mod poll;

pub use poll::{MAX_POLL_RETRIES, MAX_POLL_TARGETS, PollTarget, poll_fds, set_nonblocking};

#[cfg(target_os = "linux")]
pub use poll::{close_fd, read_fd, write_fd};
