//! `binfmt_misc` registration for Mach-O interpreters (docs/specs/m3b-protocol).
//! Best-effort at PID-1 startup: mount `binfmt_misc`, then register the thin and
//! fat magics against the `/tools/mac-binfmt` interpreter. Failure degrades to
//! explicit `mac` only, so every step logs and returns rather than aborting.

pub const INTERP_PATH: &str = "/tools/mac-binfmt";

// The kernel parser interprets the ASCII `\xNN` escapes; these are literal
// backslash-x text, not raw magic bytes. F pins the interpreter at register
// time so no distro needs it present in its own mount namespace.
pub const REGISTER_MACHO: &str = ":msl-macho:M::\\xcf\\xfa\\xed\\xfe::/tools/mac-binfmt:F";
pub const REGISTER_MACHO_FAT: &str = ":msl-macho-fat:M::\\xca\\xfe\\xba\\xbe::/tools/mac-binfmt:F";

#[cfg(target_os = "linux")]
const BINFMT_DIR: &str = "/proc/sys/fs/binfmt_misc";
#[cfg(target_os = "linux")]
const REGISTER_PATH: &str = "/proc/sys/fs/binfmt_misc/register";

#[cfg(target_os = "linux")]
pub fn register() {
    assert!(
        REGISTER_MACHO.contains(INTERP_PATH),
        "macho interp mismatch"
    );
    assert!(
        REGISTER_MACHO_FAT.contains(INTERP_PATH),
        "fat interp mismatch"
    );
    if let Err(e) = ensure_mounted() {
        crate::log::warn(&format!("binfmt: mount failed, mac-only: {e}"));
        return;
    }
    register_one("msl-macho", REGISTER_MACHO);
    register_one("msl-macho-fat", REGISTER_MACHO_FAT);
}

#[cfg(target_os = "linux")]
fn ensure_mounted() -> Result<(), String> {
    debug_assert!(REGISTER_PATH.starts_with('/'), "register path absolute");
    debug_assert!(BINFMT_DIR.starts_with('/'), "binfmt dir absolute");
    if std::path::Path::new(REGISTER_PATH).exists() {
        return Ok(());
    }
    mount_binfmt()
}

#[cfg(target_os = "linux")]
#[allow(unsafe_code)] // libc::mount(2) C ABI: no safe wrapper for the binfmt_misc fs
fn mount_binfmt() -> Result<(), String> {
    use std::ffi::CString;
    let src = CString::new("none").map_err(|_| "nul in source".to_string())?;
    let tgt = CString::new(BINFMT_DIR).map_err(|_| "nul in target".to_string())?;
    let fs = CString::new("binfmt_misc").map_err(|_| "nul in fstype".to_string())?;
    debug_assert!(!src.as_bytes().is_empty(), "source tag non-empty");
    debug_assert!(!fs.as_bytes().is_empty(), "fstype non-empty");
    let rc = unsafe { libc::mount(src.as_ptr(), tgt.as_ptr(), fs.as_ptr(), 0, std::ptr::null()) };
    if rc != 0 {
        let err = std::io::Error::last_os_error();
        if err.raw_os_error() == Some(libc::EBUSY) {
            return Ok(());
        }
        return Err(err.to_string());
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn register_one(name: &str, line: &str) {
    debug_assert!(!name.is_empty(), "handler name must be non-empty");
    debug_assert!(
        line.starts_with(':'),
        "registration line is colon-delimited"
    );
    match std::fs::write(REGISTER_PATH, line) {
        Ok(()) => crate::log::info(&format!("binfmt: registered {name}")),
        Err(e) => crate::log::warn(&format!("binfmt: register {name}: {e}")),
    }
}

#[cfg(test)]
mod tests {
    use super::{INTERP_PATH, REGISTER_MACHO, REGISTER_MACHO_FAT};

    #[test]
    fn registration_lines_match_protocol() {
        assert_eq!(
            REGISTER_MACHO,
            ":msl-macho:M::\\xcf\\xfa\\xed\\xfe::/tools/mac-binfmt:F"
        );
        assert_eq!(
            REGISTER_MACHO_FAT,
            ":msl-macho-fat:M::\\xca\\xfe\\xba\\xbe::/tools/mac-binfmt:F"
        );
    }

    #[test]
    fn handler_names_are_distinct() {
        assert_ne!(REGISTER_MACHO, REGISTER_MACHO_FAT);
        assert!(REGISTER_MACHO.starts_with(":msl-macho:"));
        assert!(REGISTER_MACHO_FAT.starts_with(":msl-macho-fat:"));
    }

    #[test]
    fn interpreter_matches_staged_name() {
        assert_eq!(INTERP_PATH, "/tools/mac-binfmt");
        assert!(REGISTER_MACHO.contains(INTERP_PATH));
        assert!(REGISTER_MACHO_FAT.contains(INTERP_PATH));
        assert!(REGISTER_MACHO.ends_with(":F") && REGISTER_MACHO_FAT.ends_with(":F"));
    }
}
