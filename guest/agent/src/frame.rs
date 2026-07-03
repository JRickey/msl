//! Re-export of the shared frame codec (moved to the `msl-wire` crate) so the
//! agent's `crate::frame::…` call sites keep resolving unchanged.

pub use msl_wire::frame::*;
