// Assertions guard internal invariants; they are not part of any function's
// documented contract, so a `# Panics` section would misdescribe the API.
#![allow(clippy::missing_panics_doc)]

pub mod bootstrap;
pub mod proto;
pub mod secrets;
pub mod ssh;

#[cfg(target_os = "linux")]
pub mod linux;
