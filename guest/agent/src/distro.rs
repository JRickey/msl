//! Distro lifecycle: the per-name boot state machine and its table
//! (host-testable) plus the Linux `clone`-into-namespaces boot that mounts an
//! ext4 root, sets up the guest filesystems, `pivot_root`s and execs
//! `/sbin/init`. v1.2 runs up to 16 named distros concurrently in one VM.

use std::collections::HashMap;
use std::time::Duration;

use crate::proto::{DistroListEntry, DistroStateData};

pub const READY_WINDOW: Duration = Duration::from_secs(5);

pub const DOWN_MIN_MS: u64 = 1_000;
pub const DOWN_MAX_MS: u64 = 60_000;
pub const DOWN_DEFAULT_MS: u64 = 15_000;

// Concurrent-distro cap (ADR 0005) and the distro-name length bound.
pub const MAX_DISTROS: usize = 16;
pub const NAME_MAX_LEN: usize = 32;

fn classify_readiness(exit_code: i32, stdout: &str) -> Result<(), String> {
    let mut fields = stdout.split_whitespace();
    let state = fields
        .next()
        .ok_or_else(|| "readiness probe returned empty output".to_string())?;
    if fields.next().is_some() {
        return Err("readiness probe returned malformed output".to_string());
    }
    match (exit_code, state) {
        (0, "running") | (1, "degraded") => Ok(()),
        (_, "running" | "degraded") => Err(format!(
            "readiness probe returned state {state} with exit status {exit_code}"
        )),
        _ => Err(format!("readiness probe returned unusable state {state}")),
    }
}

// Clamp a requested distro_down timeout into [1s, 60s], defaulting to 15s.
#[must_use]
pub fn clamp_down_timeout(timeout_ms: Option<u64>) -> u64 {
    let requested = timeout_ms.unwrap_or(DOWN_DEFAULT_MS);
    let clamped = requested.clamp(DOWN_MIN_MS, DOWN_MAX_MS);
    debug_assert!((DOWN_MIN_MS..=DOWN_MAX_MS).contains(&clamped));
    clamped
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum State {
    Stopped,
    Starting,
    Running,
    Failed,
    Cleaning,
    Finalizing,
}

impl State {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Stopped => "stopped",
            Self::Starting => "starting",
            Self::Running => "running",
            Self::Failed | Self::Cleaning | Self::Finalizing => "failed",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CleanupClaim {
    generation: u64,
    nonce: u64,
    init_pid: Option<i32>,
}

impl CleanupClaim {
    #[must_use]
    pub const fn init_pid(self) -> Option<i32> {
        self.init_pid
    }
}

pub struct Distro {
    dev: String,
    state: State,
    init_pid: Option<i32>,
    generation: Option<u64>,
    cleanup_nonce: Option<u64>,
}

impl Default for Distro {
    fn default() -> Self {
        Self::new()
    }
}

impl Distro {
    #[must_use]
    pub const fn new() -> Self {
        Self {
            dev: String::new(),
            state: State::Stopped,
            init_pid: None,
            generation: None,
            cleanup_nonce: None,
        }
    }

    fn backs_dev(&self, dev: &str) -> bool {
        assert!(!dev.is_empty(), "dev query must be non-empty");
        !self.dev.is_empty() && self.dev == dev
    }

    #[must_use]
    pub fn snapshot(&self) -> DistroStateData {
        let init_pid = self.init_pid.and_then(|p| u32::try_from(p).ok());
        DistroStateData {
            state: self.state.as_str(),
            init_pid,
        }
    }

    #[must_use]
    pub const fn is_active(&self) -> bool {
        matches!(self.state, State::Starting | State::Running)
    }

    #[must_use]
    const fn holds_resources(&self) -> bool {
        self.generation.is_some()
    }

    #[must_use]
    pub const fn running_pid(&self) -> Option<i32> {
        if matches!(self.state, State::Running) {
            self.init_pid
        } else {
            None
        }
    }

    // Reservations hold name, device, and capacity before init exists, closing
    // the admission race.
    fn reserve(&mut self, dev: &str, generation: u64) {
        assert!(!dev.is_empty(), "distro dev required");
        assert!(generation > 0, "generation must be positive");
        self.dev = dev.to_string();
        self.state = State::Starting;
        self.init_pid = None;
        self.generation = Some(generation);
        self.cleanup_nonce = None;
    }

    #[must_use]
    const fn is_reserved(&self) -> bool {
        matches!(self.state, State::Starting) && self.init_pid.is_none()
    }

    #[must_use]
    fn is_reservation(&self, generation: u64) -> bool {
        self.is_reserved() && self.generation == Some(generation)
    }

    pub fn begin(&mut self, generation: u64, pid: i32) {
        assert!(generation > 0, "generation must be positive");
        assert!(pid > 0, "init pid must be positive");
        assert!(
            self.is_reservation(generation),
            "begin requires an outstanding reservation"
        );
        self.init_pid = Some(pid);
    }

    pub fn promote(&mut self, generation: u64) {
        assert!(generation > 0, "generation must be positive");
        if self.state == State::Starting && self.generation == Some(generation) {
            self.state = State::Running;
        }
    }

    // Starting exits fail and Running exits stop; cleanup states retain ownership
    // until their generation-and-nonce claim finishes teardown.
    pub fn on_init_exit(&mut self, pid: i32) -> bool {
        if self.init_pid != Some(pid) {
            return false;
        }
        debug_assert!(matches!(
            self.state,
            State::Starting | State::Running | State::Cleaning | State::Finalizing
        ));
        self.state = match self.state {
            State::Starting => State::Failed,
            State::Running => State::Stopped,
            State::Cleaning => State::Cleaning,
            State::Finalizing => State::Finalizing,
            State::Stopped | State::Failed => return false,
        };
        self.init_pid = None;
        true
    }
}

// Entries retain name and device ownership through failure and cleanup; only
// generation-and-nonce-matched finalization removes them.
pub struct Distros {
    map: HashMap<String, Distro>,
    next_generation: u64,
    next_cleanup_nonce: u64,
}

impl Default for Distros {
    fn default() -> Self {
        Self::new()
    }
}

impl Distros {
    #[must_use]
    pub fn new() -> Self {
        Self {
            map: HashMap::new(),
            next_generation: 1,
            next_cleanup_nonce: 1,
        }
    }

    #[must_use]
    pub fn snapshot(&self, name: &str) -> DistroStateData {
        self.map.get(name).map_or(
            DistroStateData {
                state: State::Stopped.as_str(),
                init_pid: None,
            },
            Distro::snapshot,
        )
    }

    #[must_use]
    pub fn list(&self) -> Vec<DistroListEntry> {
        let mut out = Vec::with_capacity(self.map.len());
        // bounded: at most MAX_DISTROS entries
        for (name, distro) in &self.map {
            let snap = distro.snapshot();
            out.push(DistroListEntry {
                name: name.clone(),
                state: snap.state,
                init_pid: snap.init_pid,
            });
        }
        debug_assert!(out.len() <= MAX_DISTROS);
        out
    }

    #[must_use]
    pub fn is_active(&self, name: &str) -> bool {
        self.map.get(name).is_some_and(Distro::is_active)
    }

    #[must_use]
    pub fn running_pid(&self, name: &str) -> Option<i32> {
        self.map.get(name).and_then(Distro::running_pid)
    }

    #[must_use]
    pub fn is_reservation(&self, name: &str, generation: u64) -> bool {
        self.map
            .get(name)
            .is_some_and(|distro| distro.is_reservation(generation))
    }

    #[must_use]
    pub fn is_boot_active(&self, name: &str, generation: u64, pid: i32) -> bool {
        self.map.get(name).is_some_and(|distro| {
            distro.is_active()
                && distro.generation == Some(generation)
                && distro.init_pid == Some(pid)
        })
    }

    fn resource_count(&self) -> usize {
        self.map.values().filter(|d| d.holds_resources()).count()
    }

    pub fn reserve(&mut self, name: &str, dev: &str) -> Result<u64, String> {
        assert!(!name.is_empty(), "reserve needs a name");
        assert!(!dev.is_empty(), "reserve needs a dev");
        if self.map.get(name).is_some_and(Distro::holds_resources) {
            return Err("distro lifecycle already in progress".to_string());
        }
        if self.resource_count() >= MAX_DISTROS {
            return Err("too many distros (max 16)".to_string());
        }
        // bounded: at most MAX_DISTROS entries
        for (other, distro) in &self.map {
            if other != name && distro.holds_resources() && distro.backs_dev(dev) {
                return Err(format!("dev {dev} is held by another distro lifecycle"));
            }
        }
        let generation = self.next_generation;
        self.next_generation = generation
            .checked_add(1)
            .ok_or_else(|| "distro generation exhausted".to_string())?;
        self.map
            .entry(name.to_string())
            .or_default()
            .reserve(dev, generation);
        debug_assert!(self.is_active(name));
        Ok(generation)
    }

    // Matching the generation prevents a failed spawn from releasing a
    // replacement reservation.
    pub fn release_reservation(&mut self, name: &str, generation: u64) {
        assert!(!name.is_empty(), "release needs a name");
        assert!(generation > 0, "generation must be positive");
        if self
            .map
            .get(name)
            .is_some_and(|distro| distro.is_reservation(generation))
        {
            let _ = self.map.remove(name);
        }
    }

    pub fn begin(&mut self, name: &str, generation: u64, pid: i32) -> Result<(), String> {
        assert!(generation > 0, "generation must be positive");
        assert!(pid > 0, "init pid must be positive");
        assert!(!name.is_empty(), "distro name required");
        let distro = self
            .map
            .get_mut(name)
            .ok_or_else(|| "distro reservation vanished".to_string())?;
        if !distro.is_reservation(generation) {
            return Err("distro reservation changed".to_string());
        }
        distro.begin(generation, pid);
        Ok(())
    }

    pub fn promote(&mut self, name: &str, generation: u64, pid: i32) -> bool {
        assert!(!name.is_empty(), "promote needs a name");
        assert!(generation > 0, "generation must be positive");
        let Some(distro) = self.map.get_mut(name) else {
            return false;
        };
        if distro.state != State::Starting
            || distro.generation != Some(generation)
            || distro.init_pid != Some(pid)
        {
            return false;
        }
        distro.promote(generation);
        true
    }

    // PID matching lets the reaper clear only the entry that owns the exiting
    // init while preserving an in-progress cleanup claim.
    pub fn on_init_exit(&mut self, pid: i32) -> Option<String> {
        assert!(pid > 0, "reaped pid must be positive");
        // bounded: at most MAX_DISTROS entries
        for (name, distro) in &mut self.map {
            if distro.on_init_exit(pid) {
                return Some(name.clone());
            }
        }
        None
    }

    pub fn claim_cleanup(
        &mut self,
        name: &str,
        expected: Option<u64>,
    ) -> Result<Option<CleanupClaim>, String> {
        assert!(!name.is_empty(), "cleanup claim needs a name");
        let Some(distro) = self.map.get(name) else {
            return Ok(None);
        };
        let generation = distro
            .generation
            .ok_or_else(|| "distro has no boot generation".to_string())?;
        if expected.is_some_and(|value| value != generation) {
            return Err("stale distro boot generation".to_string());
        }
        if matches!(distro.state, State::Cleaning) && distro.init_pid.is_some() {
            return Err("distro cleanup already in progress".to_string());
        }
        if distro.state == State::Finalizing {
            return Err("distro cleanup finalization in progress".to_string());
        }
        if distro.is_reserved() {
            return Err("distro startup is still reserving resources".to_string());
        }
        let nonce = self.next_cleanup_nonce;
        self.next_cleanup_nonce = nonce
            .checked_add(1)
            .ok_or_else(|| "cleanup claim nonce exhausted".to_string())?;
        let distro = self
            .map
            .get_mut(name)
            .ok_or_else(|| "distro lifecycle vanished".to_string())?;
        distro.state = State::Cleaning;
        distro.cleanup_nonce = Some(nonce);
        Ok(Some(CleanupClaim {
            generation,
            nonce,
            init_pid: distro.init_pid,
        }))
    }

    #[must_use]
    pub fn claim_is_dead(&self, name: &str, claim: CleanupClaim) -> bool {
        self.map.get(name).is_some_and(|distro| {
            distro.state == State::Cleaning
                && distro.generation == Some(claim.generation)
                && distro.cleanup_nonce == Some(claim.nonce)
                && distro.init_pid.is_none()
        })
    }

    pub fn begin_finalize(&mut self, name: &str, claim: CleanupClaim) -> bool {
        assert!(!name.is_empty(), "cleanup finalization needs a name");
        if !self.claim_is_dead(name, claim) {
            return false;
        }
        if let Some(distro) = self.map.get_mut(name) {
            distro.state = State::Finalizing;
            return true;
        }
        false
    }

    pub fn finish_finalize(
        &mut self,
        name: &str,
        claim: CleanupClaim,
        unmount: Result<(), String>,
    ) -> Result<bool, String> {
        assert!(!name.is_empty(), "cleanup completion needs a name");
        let owned = self.map.get(name).is_some_and(|distro| {
            distro.state == State::Finalizing
                && distro.generation == Some(claim.generation)
                && distro.cleanup_nonce == Some(claim.nonce)
        });
        if !owned {
            return Ok(false);
        }
        if let Err(message) = unmount {
            if let Some(distro) = self.map.get_mut(name) {
                distro.state = State::Cleaning;
            }
            return Err(message);
        }
        Ok(self.map.remove(name).is_some())
    }
}

// Distro name key per protocol v1.2: ^[a-z][a-z0-9-]{0,31}$.
pub fn validate_name(name: &str) -> Result<(), String> {
    let bytes = name.as_bytes();
    let head_ok = bytes.first().is_some_and(u8::is_ascii_lowercase);
    let body_ok = bytes
        .iter()
        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'-');
    if head_ok && body_ok && bytes.len() <= NAME_MAX_LEN {
        Ok(())
    } else {
        Err("name must match ^[a-z][a-z0-9-]{0,31}$".to_string())
    }
}

pub fn validate_dev(dev: &str) -> Result<(), String> {
    let bytes = dev.as_bytes();
    let ok = bytes.len() == 8 && dev.starts_with("/dev/vd") && bytes[7].is_ascii_lowercase();
    if ok {
        Ok(())
    } else {
        Err("dev must match ^/dev/vd[a-z]$".to_string())
    }
}

pub fn validate_hostname(name: &str) -> Result<(), String> {
    if name.is_empty() || name.len() > 64 {
        return Err("hostname must be 1..=64 bytes".to_string());
    }
    let ok = name
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'.');
    if ok {
        Ok(())
    } else {
        Err("hostname has invalid characters".to_string())
    }
}

#[cfg(target_os = "linux")]
pub use linux::{complete_claimed_cleanup, distro_up, shutdown_claimed};

#[cfg(target_os = "linux")]
mod linux {
    use std::collections::HashMap;
    use std::ffi::CString;
    use std::path::Path;
    use std::sync::Mutex;
    use std::thread;
    use std::time::{Duration, Instant};

    use super::{
        CleanupClaim, DOWN_MAX_MS, Distros, READY_WINDOW, classify_readiness, validate_dev,
        validate_hostname, validate_name,
    };
    use crate::exec::{self, ExecOpts};
    use crate::proto::{DistroStateData, DistroUpReq};
    use crate::sys::{self, BootSpec, MountOp, RosettaBind, ToolsBind};

    const DISTRO_ROOT: &str = "/run/msl/distros";
    const MAC_SRC: &str = "/run/msl/mac";
    // The initramfs directory holding the projected interop shim (ADR 0008).
    const TOOLS_SRC: &str = "/tools";
    // The agent-ns mount of the VM's Rosetta virtiofs share (ADR 0001).
    const ROSETTA_SRC: &str = "/run/msl/rosetta";
    const DOWN_TICK: Duration = Duration::from_millis(100);
    // 600 * 100ms == 60s, the maximum clamped distro_down timeout.
    const DOWN_MAX_TICKS: u32 = 600;
    const CLEANUP_GRACE: Duration = Duration::from_secs(5);
    // Fixed poweroff-exec budget (v1.1.1): independent of timeout_ms, since
    // `systemctl poweroff` only requests shutdown and returns immediately.
    const POWEROFF_EXEC_MS: u64 = 3_000;

    pub fn distro_up(
        distros: &Mutex<Distros>,
        req: &DistroUpReq,
    ) -> Result<DistroStateData, String> {
        validate_dev(&req.dev)?;
        validate_hostname(&req.hostname)?;
        validate_name(&req.name)?;
        let mut generation = None;
        // bounded: one cleanup pass followed by one admission pass
        for _ in 0..2 {
            let cleanup = {
                let mut guard = distros.lock().map_err(|_| "distro lock".to_string())?;
                if guard.is_active(&req.name) {
                    return Ok(guard.snapshot(&req.name));
                }
                if let Some(claim) = guard.claim_cleanup(&req.name, None)? {
                    Some(claim)
                } else {
                    generation = Some(guard.reserve(&req.name, &req.dev)?);
                    None
                }
            };
            let Some(claim) = cleanup else {
                break;
            };
            if claim.init_pid().is_some() {
                return Err("distro cleanup already in progress".to_string());
            }
            complete_claimed_cleanup(distros, &req.name, claim)?;
        }
        let generation = generation.ok_or_else(|| "distro admission did not settle".to_string())?;
        match boot_reserved(distros, req, generation) {
            Ok(pid) => finish_boot(distros, &req.name, generation, pid),
            Err(e) => {
                if let Ok(mut guard) = distros.lock() {
                    guard.release_reservation(&req.name, generation);
                }
                Err(e)
            }
        }
    }

    // The spawn and table locks make generation validation, init spawn, and PID
    // publication atomic against the reaper.
    fn boot_reserved(
        distros: &Mutex<Distros>,
        req: &DistroUpReq,
        generation: u64,
    ) -> Result<i32, String> {
        assert!(generation > 0, "boot needs a generation");
        let spec = prepare_boot(req)?;
        let _spawn = crate::wait::spawn_lock();
        let mut guard = distros.lock().map_err(|_| "distro lock".to_string())?;
        if !guard.is_reservation(&req.name, generation) {
            return Err("distro reservation changed before spawn".to_string());
        }
        let pid = sys::spawn_distro_init(&spec).map_err(|e| format!("distro boot: {e}"))?;
        guard.begin(&req.name, generation, pid)?;
        drop(guard);
        Ok(pid)
    }

    fn finish_boot(
        distros: &Mutex<Distros>,
        name: &str,
        generation: u64,
        init_pid: i32,
    ) -> Result<DistroStateData, String> {
        assert!(!name.is_empty(), "finish_boot needs a name");
        assert!(init_pid > 0, "finish_boot needs an init pid");
        let result = observe_readiness(distros, name, generation, init_pid)
            .and_then(|()| promote_observed(distros, name, generation, init_pid));
        match result {
            Ok(snapshot) => Ok(snapshot),
            Err(probe) => {
                let cleanup = cleanup_failed_boot(distros, name, generation);
                match cleanup {
                    Ok(()) => Err(format!("distro readiness failed: {probe}")),
                    Err(message) => Err(format!(
                        "distro readiness failed: {probe}; cleanup failed: {message}"
                    )),
                }
            }
        }
    }

    fn observe_readiness(
        distros: &Mutex<Distros>,
        name: &str,
        generation: u64,
        init_pid: i32,
    ) -> Result<(), String> {
        const PROBE_ATTEMPTS: u32 = 50;
        const PROBE_POLL: Duration = Duration::from_millis(100);
        assert!(!name.is_empty(), "readiness needs a name");
        assert!(init_pid > 0, "readiness needs an init pid");
        wait_for_systemctl(distros, name, generation, init_pid)?;
        let mut attempt: u32 = 0;
        let mut last = "readiness probe did not settle".to_string();
        // bounded: retry while systemd's private bus comes up post-exec.
        while attempt < PROBE_ATTEMPTS {
            ensure_init_active(distros, name, generation, init_pid)?;
            match probe_readiness(distros, name, generation, init_pid) {
                Ok(()) => return Ok(()),
                Err(message) => last = message,
            }
            attempt = attempt.saturating_add(1);
            thread::sleep(PROBE_POLL);
        }
        Err(last)
    }

    fn probe_readiness(
        distros: &Mutex<Distros>,
        name: &str,
        generation: u64,
        init_pid: i32,
    ) -> Result<(), String> {
        assert!(!name.is_empty(), "probe needs a name");
        assert!(init_pid > 0, "probe needs an init pid");
        let argv = vec![
            "/usr/bin/systemctl".to_string(),
            "is-system-running".to_string(),
            "--wait".to_string(),
        ];
        let opts = ExecOpts {
            distro: true,
            cwd: None,
            init_pid: Some(init_pid),
            ident: None,
        };
        let timeout_ms = u64::try_from(READY_WINDOW.as_millis())
            .map_err(|_| "readiness timeout overflow".to_string())?;
        let data = exec::run(&argv, &HashMap::new(), timeout_ms, &opts).map_err(|message| {
            if init_is_active(distros, name, generation, init_pid) {
                format!("probe execution failed: {message}")
            } else {
                "init exited before readiness".to_string()
            }
        })?;
        ensure_init_active(distros, name, generation, init_pid)?;
        classify_readiness(data.exit_code, &data.stdout)
    }

    // systemctl appears only after the cloned child switch_roots and execs systemd.
    fn wait_for_systemctl(
        distros: &Mutex<Distros>,
        name: &str,
        generation: u64,
        init_pid: i32,
    ) -> Result<(), String> {
        const READY_ATTEMPTS: u32 = 50;
        const READY_POLL: Duration = Duration::from_millis(100);
        assert!(!name.is_empty(), "probe needs a name");
        assert!(init_pid > 0, "probe needs an init pid");
        let probe = format!("/proc/{init_pid}/root/usr/bin/systemctl");
        // bounded: at most READY_ATTEMPTS * READY_POLL == 5s.
        let mut attempt: u32 = 0;
        while attempt < READY_ATTEMPTS {
            ensure_init_active(distros, name, generation, init_pid)?;
            if Path::new(&probe).exists() {
                return Ok(());
            }
            attempt = attempt.saturating_add(1);
            thread::sleep(READY_POLL);
        }
        Err("unsupported init: /usr/bin/systemctl not found".to_string())
    }

    fn ensure_init_active(
        distros: &Mutex<Distros>,
        name: &str,
        generation: u64,
        init_pid: i32,
    ) -> Result<(), String> {
        assert!(!name.is_empty(), "init check needs a name");
        assert!(init_pid > 0, "init check needs a pid");
        if init_is_active(distros, name, generation, init_pid) {
            Ok(())
        } else {
            Err("init exited before readiness".to_string())
        }
    }

    fn init_is_active(
        distros: &Mutex<Distros>,
        name: &str,
        generation: u64,
        init_pid: i32,
    ) -> bool {
        assert!(!name.is_empty(), "active check needs a name");
        assert!(init_pid > 0, "active check needs a pid");
        distros
            .lock()
            .is_ok_and(|guard| guard.is_boot_active(name, generation, init_pid))
    }

    fn promote_observed(
        distros: &Mutex<Distros>,
        name: &str,
        generation: u64,
        init_pid: i32,
    ) -> Result<DistroStateData, String> {
        assert!(!name.is_empty(), "promotion needs a name");
        assert!(init_pid > 0, "promotion needs an init pid");
        let mut guard = distros.lock().map_err(|_| "distro lock".to_string())?;
        if !guard.promote(name, generation, init_pid) {
            return Err("init exited before readiness".to_string());
        }
        let snapshot = guard.snapshot(name);
        drop(guard);
        debug_assert_eq!(snapshot.state, "running");
        Ok(snapshot)
    }

    fn cleanup_failed_boot(
        distros: &Mutex<Distros>,
        name: &str,
        generation: u64,
    ) -> Result<(), String> {
        assert!(!name.is_empty(), "boot cleanup needs a name");
        assert!(generation > 0, "boot cleanup needs a generation");
        let claim = distros
            .lock()
            .map_err(|_| "distro lock".to_string())?
            .claim_cleanup(name, Some(generation))?
            .ok_or_else(|| "distro boot generation vanished".to_string())?;
        kill_and_cleanup(distros, name, claim)
    }

    pub fn shutdown_claimed(
        distros: &Mutex<Distros>,
        name: &str,
        claim: CleanupClaim,
        timeout_ms: u64,
    ) -> Result<(), String> {
        assert!(!name.is_empty(), "shutdown needs a name");
        assert!(timeout_ms >= 1, "timeout must be positive");
        let Some(init_pid) = claim.init_pid() else {
            return Ok(());
        };
        let deadline = Instant::now() + Duration::from_millis(timeout_ms);
        fire_poweroff(init_pid);
        if poll_claim_dead(distros, name, claim, deadline) {
            return Ok(());
        }
        kill_and_wait(distros, name, claim, init_pid)
    }

    fn kill_and_cleanup(
        distros: &Mutex<Distros>,
        name: &str,
        claim: CleanupClaim,
    ) -> Result<(), String> {
        assert!(!name.is_empty(), "cleanup needs a name");
        if let Some(init_pid) = claim.init_pid() {
            kill_and_wait(distros, name, claim, init_pid)?;
        } else if !claim_dead(distros, name, claim)? {
            return Err("cleanup claim is not stopped".to_string());
        }
        complete_claimed_cleanup(distros, name, claim)
    }

    fn kill_and_wait(
        distros: &Mutex<Distros>,
        name: &str,
        claim: CleanupClaim,
        init_pid: i32,
    ) -> Result<(), String> {
        assert!(!name.is_empty(), "kill wait needs a name");
        assert!(init_pid > 0, "kill wait needs an init pid");
        let signal = sys::send_signal(init_pid, libc::SIGKILL);
        if poll_claim_dead(distros, name, claim, Instant::now() + CLEANUP_GRACE) {
            return Ok(());
        }
        Err(match signal {
            Ok(()) => "init remained live after SIGKILL cleanup grace".to_string(),
            Err(error) => format!("SIGKILL failed and init remained live: {error}"),
        })
    }

    // Finalizing serializes unmount for the owned claim; failure returns the
    // claim to Cleaning for retry.
    pub fn complete_claimed_cleanup(
        distros: &Mutex<Distros>,
        name: &str,
        claim: CleanupClaim,
    ) -> Result<(), String> {
        assert!(!name.is_empty(), "completion needs a name");
        let finalizing = distros
            .lock()
            .map_err(|_| "distro lock".to_string())?
            .begin_finalize(name, claim);
        if !finalizing {
            return Err("cleanup claim changed before finalization".to_string());
        }
        let unmount = teardown(name);
        let removed = distros
            .lock()
            .map_err(|_| "distro lock".to_string())?
            .finish_finalize(name, claim, unmount)?;
        if removed {
            Ok(())
        } else {
            Err("cleanup generation changed before removal".to_string())
        }
    }

    fn claim_dead(
        distros: &Mutex<Distros>,
        name: &str,
        claim: CleanupClaim,
    ) -> Result<bool, String> {
        let guard = distros.lock().map_err(|_| "distro lock".to_string())?;
        Ok(guard.claim_is_dead(name, claim))
    }

    // Sync and unmount errors remain visible so ownership is never released early.
    pub fn teardown(name: &str) -> Result<(), String> {
        assert!(!name.is_empty(), "teardown needs a distro name");
        sys::sync_and_unmount(&newroot_for(name))
            .map_err(|error| format!("distro teardown: {error}"))
    }

    // Best-effort buffered poweroff on a fixed 3s budget (it only *requests*
    // shutdown and returns); its exit is discarded, the poll owns the deadline.
    fn fire_poweroff(init_pid: i32) {
        assert!(init_pid > 0, "poweroff needs a live init pid");
        let argv = poweroff_argv(init_pid);
        debug_assert!(!argv.is_empty());
        let opts = ExecOpts {
            distro: true,
            cwd: None,
            init_pid: Some(init_pid),
            ident: None,
        };
        let _ = exec::run(&argv, &HashMap::new(), POWEROFF_EXEC_MS, &opts);
    }

    fn poweroff_argv(init_pid: i32) -> Vec<String> {
        assert!(init_pid > 0, "argv selection needs a live init pid");
        let probe = format!("/proc/{init_pid}/root/usr/bin/systemctl");
        debug_assert!(probe.starts_with("/proc/"));
        if Path::new(&probe).exists() {
            vec!["/usr/bin/systemctl".to_string(), "poweroff".to_string()]
        } else {
            vec!["/sbin/poweroff".to_string()]
        }
    }

    fn poll_claim_dead(
        distros: &Mutex<Distros>,
        name: &str,
        claim: CleanupClaim,
        deadline: Instant,
    ) -> bool {
        debug_assert!(
            u128::from(DOWN_MAX_TICKS) * DOWN_TICK.as_millis() >= u128::from(DOWN_MAX_MS)
        );
        // bounded: DOWN_MAX_TICKS caps iterations; the deadline caps wall time
        for _ in 0..DOWN_MAX_TICKS {
            if let Ok(guard) = distros.lock()
                && guard.claim_is_dead(name, claim)
            {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            thread::sleep(DOWN_TICK);
        }
        false
    }

    fn newroot_for(name: &str) -> String {
        assert!(!name.is_empty(), "newroot needs a distro name");
        format!("{DISTRO_ROOT}/{name}")
    }

    fn prepare_boot(req: &DistroUpReq) -> Result<BootSpec, String> {
        let newroot = newroot_for(&req.name);
        std::fs::create_dir_all(&newroot).map_err(|e| format!("newroot: {e}"))?;
        let mac = if req.mac_share && Path::new(MAC_SRC).exists() {
            Some((cstr(MAC_SRC)?, cstr(&format!("{newroot}/mnt/mac"))?))
        } else {
            None
        };
        let tools = prepare_tools(&newroot)?;
        let rosetta = prepare_rosetta(req.rosetta, &newroot)?;
        Ok(BootSpec {
            dev: cstr(&req.dev)?,
            newroot: cstr(&newroot)?,
            mounts: guest_mounts(&newroot)?,
            mac,
            tools,
            rosetta,
            hostname: cstr(&req.hostname)?,
            argv: vec![cstr("/sbin/init")?],
            envp: vec![
                cstr("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")?,
                cstr("container=msl")?,
            ],
        })
    }

    // Project the initramfs shim into the distro when present; absent /tools
    // (an older initramfs) is not an error, the distro simply lacks `mac`.
    fn prepare_tools(newroot: &str) -> Result<Option<ToolsBind>, String> {
        assert!(!newroot.is_empty(), "tools projection needs a newroot");
        if !Path::new(TOOLS_SRC).exists() {
            return Ok(None);
        }
        Ok(Some(ToolsBind {
            src: cstr(TOOLS_SRC)?,
            parent: cstr(&format!("{newroot}/run/msl"))?,
            target: cstr(&format!("{newroot}/run/msl/tools"))?,
            link: cstr(&format!("{newroot}/usr/local/bin/mac"))?,
            binfmt_dir: cstr(&format!("{newroot}/etc/binfmt.d"))?,
            binfmt_conf: cstr(&format!("{newroot}/etc/binfmt.d/msl-macho.conf"))?,
        }))
    }

    // Set up x86-64 translation when the distro opted in and the VM attached
    // the share; an absent share (Rosetta off host-side) degrades to None.
    fn prepare_rosetta(enabled: bool, newroot: &str) -> Result<Option<RosettaBind>, String> {
        assert!(!newroot.is_empty(), "rosetta projection needs a newroot");
        if !enabled || !Path::new(ROSETTA_SRC).exists() {
            return Ok(None);
        }
        Ok(Some(RosettaBind {
            src: cstr(ROSETTA_SRC)?,
            parent: cstr(&format!("{newroot}/run/msl"))?,
            target: cstr(&format!("{newroot}/run/msl/rosetta"))?,
            binfmt_dir: cstr(&format!("{newroot}/etc/binfmt.d"))?,
            binfmt_conf: cstr(&format!("{newroot}/etc/binfmt.d/rosetta.conf"))?,
        }))
    }

    fn guest_mounts(newroot: &str) -> Result<Vec<MountOp>, String> {
        assert!(!newroot.is_empty(), "mounts need a newroot");
        Ok(vec![
            mnt(newroot, "proc", "/proc", "proc", None)?,
            mnt(newroot, "sysfs", "/sys", "sysfs", None)?,
            mnt(newroot, "devtmpfs", "/dev", "devtmpfs", None)?,
            mnt(
                newroot,
                "devpts",
                "/dev/pts",
                "devpts",
                Some("mode=0620,ptmxmode=0666"),
            )?,
            mnt(newroot, "tmpfs", "/dev/shm", "tmpfs", Some("mode=1777"))?,
            mnt(newroot, "tmpfs", "/run", "tmpfs", Some("mode=0755"))?,
            mnt(newroot, "cgroup2", "/sys/fs/cgroup", "cgroup2", None)?,
        ])
    }

    fn mnt(
        newroot: &str,
        source: &str,
        target: &str,
        fstype: &str,
        data: Option<&str>,
    ) -> Result<MountOp, String> {
        let data = match data {
            Some(value) => Some(cstr(value)?),
            None => None,
        };
        Ok(MountOp {
            source: cstr(source)?,
            target: cstr(&format!("{newroot}{target}"))?,
            fstype: cstr(fstype)?,
            flags: 0,
            data,
        })
    }

    fn cstr(value: &str) -> Result<CString, String> {
        CString::new(value).map_err(|_| format!("nul in {value}"))
    }
}

#[cfg(test)]
mod tests {
    use super::{
        CleanupClaim, DOWN_DEFAULT_MS, DOWN_MAX_MS, DOWN_MIN_MS, Distro, Distros, MAX_DISTROS,
        clamp_down_timeout, classify_readiness, validate_name,
    };

    const DEV_A: &str = "/dev/vda";
    const DEV_B: &str = "/dev/vdb";

    fn up(table: &mut Distros, name: &str, dev: &str, pid: i32) -> u64 {
        let generation = table.reserve(name, dev).expect("reserve under cap");
        table.begin(name, generation, pid).expect("begin boot");
        generation
    }

    fn finish(table: &mut Distros, name: &str, claim: CleanupClaim) -> bool {
        if !table.begin_finalize(name, claim) {
            return false;
        }
        table
            .finish_finalize(name, claim, Ok(()))
            .expect("successful unmount decision")
    }

    #[test]
    fn readiness_accepts_systemd_usable_states() {
        assert!(classify_readiness(0, "running\n").is_ok());
        assert!(classify_readiness(1, " \tdegraded\r\n").is_ok());
    }

    #[test]
    fn readiness_rejects_unusable_states() {
        for state in ["starting", "stopping", "maintenance", "offline", "unknown"] {
            assert!(
                classify_readiness(1, state).is_err(),
                "{state} must be rejected"
            );
        }
    }

    #[test]
    fn readiness_rejects_inconsistent_exit_statuses() {
        assert!(classify_readiness(1, "running").is_err());
        assert!(classify_readiness(0, "degraded").is_err());
        assert!(classify_readiness(127, "running").is_err());
    }

    #[test]
    fn readiness_rejects_empty_and_malformed_output() {
        for output in ["", " \t\r\n", "running degraded", "running\nunknown"] {
            assert!(
                classify_readiness(0, output).is_err(),
                "{output:?} must be rejected"
            );
        }
    }

    #[test]
    fn init_exit_while_starting_is_failed() {
        let mut distro = Distro::new();
        distro.reserve(DEV_A, 1);
        distro.begin(1, 4242);
        assert!(distro.on_init_exit(4242));
        assert_eq!(distro.snapshot().state, "failed");
    }

    #[test]
    fn init_exit_after_promotion_is_stopped() {
        let mut distro = Distro::new();
        distro.reserve(DEV_A, 1);
        distro.begin(1, 4242);
        distro.promote(1);
        assert!(distro.on_init_exit(4242));
        assert_eq!(distro.snapshot().state, "stopped");
    }

    #[test]
    fn absent_name_reads_stopped_default() {
        let table = Distros::new();
        assert_eq!(table.snapshot("ghost").state, "stopped");
        assert!(table.snapshot("ghost").init_pid.is_none());
        assert!(!table.is_active("ghost"));
        assert!(table.list().is_empty());
    }

    #[test]
    fn two_names_run_independent_lifecycles() {
        let mut table = Distros::new();
        let one = up(&mut table, "one", DEV_A, 100);
        let two = up(&mut table, "two", DEV_B, 200);
        assert!(table.promote("one", one, 100));
        assert!(table.promote("two", two, 200));
        assert_eq!(table.running_pid("one"), Some(100));
        assert_eq!(table.running_pid("two"), Some(200));
        assert_eq!(table.on_init_exit(100).as_deref(), Some("one"));
        assert!(!table.is_active("one"));
        assert!(table.is_active("two"));
        assert_eq!(table.running_pid("two"), Some(200));
        let claim = table
            .claim_cleanup("one", Some(one))
            .expect("claim")
            .expect("entry");
        assert!(finish(&mut table, "one", claim));
        assert_eq!(table.snapshot("one").state, "stopped");
        assert_eq!(table.list().len(), 1);
    }

    #[test]
    fn dev_reuse_rejected_among_active() {
        let mut table = Distros::new();
        up(&mut table, "one", DEV_A, 100);
        assert!(table.reserve("two", DEV_A).is_err(), "dev A already active");
        let two = table.reserve("two", DEV_B).expect("distinct dev admitted");
        table.begin("two", two, 200).expect("begin two");
        assert!(table.on_init_exit(100).is_some());
        let claim = table
            .claim_cleanup("one", None)
            .expect("claim")
            .expect("entry");
        assert!(finish(&mut table, "one", claim));
        assert!(
            table.reserve("three", DEV_A).is_ok(),
            "dev freed after teardown"
        );
    }

    // A reservation holds device admission before a PID exists, preventing
    // concurrent boots from both passing uniqueness checks.
    #[test]
    fn reservation_blocks_concurrent_admission() {
        let mut table = Distros::new();
        let generation = table.reserve("ubuntu", DEV_A).expect("first reservation");
        assert!(table.is_active("ubuntu"), "reservation counts as active");
        assert_eq!(table.snapshot("ubuntu").state, "starting");
        assert!(table.snapshot("ubuntu").init_pid.is_none());
        assert!(
            table.reserve("other", DEV_A).is_err(),
            "dev held by reservation"
        );
        table.release_reservation("ubuntu", generation);
        assert!(!table.is_active("ubuntu"));
        assert!(
            table.reserve("other", DEV_A).is_ok(),
            "dev freed on release"
        );
    }

    #[test]
    fn failed_and_cleaning_block_name_and_dev_reuse() {
        let mut table = Distros::new();
        let generation = up(&mut table, "ubuntu", DEV_A, 100);
        assert!(table.on_init_exit(100).is_some());
        assert_eq!(table.snapshot("ubuntu").state, "failed");
        assert!(table.reserve("ubuntu", DEV_B).is_err());
        assert!(table.reserve("other", DEV_A).is_err());

        let claim = table
            .claim_cleanup("ubuntu", Some(generation))
            .expect("first claim")
            .expect("entry");
        assert_eq!(table.snapshot("ubuntu").state, "failed");
        assert!(table.reserve("ubuntu", DEV_B).is_err());
        assert!(table.reserve("other", DEV_A).is_err());
        let resumed = table
            .claim_cleanup("ubuntu", None)
            .expect("resume dead cleanup")
            .expect("entry");
        assert!(!finish(&mut table, "ubuntu", claim));
        assert!(finish(&mut table, "ubuntu", resumed));
    }

    #[test]
    fn live_cleaning_cannot_be_stolen_and_reaper_retains_it() {
        let mut table = Distros::new();
        let generation = up(&mut table, "ubuntu", DEV_A, 100);
        let claim = table
            .claim_cleanup("ubuntu", Some(generation))
            .expect("first claim")
            .expect("entry");
        assert!(table.running_pid("ubuntu").is_none());
        assert!(table.claim_cleanup("ubuntu", Some(generation)).is_err());
        assert!(!table.claim_is_dead("ubuntu", claim));
        assert!(table.on_init_exit(100).is_some());
        assert!(table.claim_is_dead("ubuntu", claim));
        assert!(finish(&mut table, "ubuntu", claim));
    }

    #[test]
    fn dead_cleaning_reclaim_invalidates_old_owner() {
        let mut table = Distros::new();
        let generation = up(&mut table, "ubuntu", DEV_A, 100);
        let old = table
            .claim_cleanup("ubuntu", Some(generation))
            .expect("first claim")
            .expect("entry");
        assert!(table.on_init_exit(100).is_some());
        let latest = table
            .claim_cleanup("ubuntu", Some(generation))
            .expect("reclaim dead cleanup")
            .expect("entry");
        assert!(!table.claim_is_dead("ubuntu", old));
        assert!(table.claim_is_dead("ubuntu", latest));
        assert!(!finish(&mut table, "ubuntu", old));
        assert!(finish(&mut table, "ubuntu", latest));
    }

    #[test]
    fn unmount_failure_retains_reclaimable_ownership() {
        let mut table = Distros::new();
        let generation = up(&mut table, "ubuntu", DEV_A, 100);
        assert!(table.on_init_exit(100).is_some());
        let claim = table
            .claim_cleanup("ubuntu", Some(generation))
            .expect("claim")
            .expect("entry");
        assert!(table.begin_finalize("ubuntu", claim));
        let error = table
            .finish_finalize("ubuntu", claim, Err("unmount failed".to_string()))
            .expect_err("unmount failure retained");
        assert_eq!(error, "unmount failed");
        assert!(table.claim_is_dead("ubuntu", claim));
        assert!(table.reserve("ubuntu", DEV_A).is_err());
        let resumed = table
            .claim_cleanup("ubuntu", None)
            .expect("resume")
            .expect("entry");
        assert!(!table.claim_is_dead("ubuntu", claim));
        assert!(finish(&mut table, "ubuntu", resumed));
    }

    #[test]
    fn terminal_cleanup_permits_same_name_replacement() {
        let mut table = Distros::new();
        let first = up(&mut table, "ubuntu", DEV_A, 100);
        assert!(table.on_init_exit(100).is_some());
        let claim = table
            .claim_cleanup("ubuntu", Some(first))
            .expect("claim terminal")
            .expect("entry");
        assert!(finish(&mut table, "ubuntu", claim));
        let replacement = table.reserve("ubuntu", DEV_A).expect("replacement");
        assert_ne!(replacement, first);
    }

    #[test]
    fn stale_cleanup_generation_cannot_remove_replacement() {
        let mut table = Distros::new();
        let first = up(&mut table, "ubuntu", DEV_A, 100);
        assert!(table.on_init_exit(100).is_some());
        let stale = table
            .claim_cleanup("ubuntu", Some(first))
            .expect("claim first")
            .expect("entry");
        assert!(finish(&mut table, "ubuntu", stale));

        let replacement = up(&mut table, "ubuntu", DEV_A, 200);
        assert_ne!(first, replacement);
        let current = table
            .claim_cleanup("ubuntu", Some(replacement))
            .expect("claim replacement")
            .expect("entry");
        assert!(table.on_init_exit(200).is_some());
        assert!(!finish(&mut table, "ubuntu", stale));
        assert!(table.claim_is_dead("ubuntu", current));
        assert!(finish(&mut table, "ubuntu", current));
    }

    #[test]
    fn cap_enforced_at_sixteen_active() {
        let mut table = Distros::new();
        // bounded: fills exactly the concurrency cap
        for i in 0..MAX_DISTROS {
            let name = format!("d{i}");
            let dev = format!(
                "/dev/vd{}",
                (b'a' + u8::try_from(i).expect("small")) as char
            );
            up(
                &mut table,
                &name,
                &dev,
                1000 + i32::try_from(i).expect("small"),
            );
        }
        assert!(
            table.reserve("overflow", "/dev/vdz").is_err(),
            "cap reached"
        );
        assert!(table.reserve("d0", "/dev/vda").is_err());
    }

    #[test]
    fn name_validation_matches_regex() {
        for good in ["a", "ubuntu", "u1", "my-distro", "a0-b1"] {
            assert!(validate_name(good).is_ok(), "{good} should be valid");
        }
        for bad in ["", "1abc", "-abc", "Ubuntu", "a_b", "a".repeat(33).as_str()] {
            assert!(validate_name(bad).is_err(), "{bad} should be rejected");
        }
    }

    #[test]
    fn clamp_defaults_when_absent() {
        assert_eq!(clamp_down_timeout(None), DOWN_DEFAULT_MS);
    }

    #[test]
    fn clamp_floors_below_minimum() {
        assert_eq!(clamp_down_timeout(Some(0)), DOWN_MIN_MS);
        assert_eq!(clamp_down_timeout(Some(50)), DOWN_MIN_MS);
    }

    #[test]
    fn clamp_ceils_above_maximum() {
        assert_eq!(clamp_down_timeout(Some(u64::MAX)), DOWN_MAX_MS);
    }

    #[test]
    fn clamp_passes_through_in_window() {
        assert_eq!(clamp_down_timeout(Some(30_000)), 30_000);
    }
}
