//! Distro lifecycle: the per-name boot state machine and its table
//! (host-testable) plus the Linux `clone`-into-namespaces boot that mounts an
//! ext4 root, sets up the guest filesystems, `pivot_root`s and execs
//! `/sbin/init`. v1.2 runs up to 16 named distros concurrently in one VM.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use crate::proto::{DistroListEntry, DistroStateData};

pub const READY_WINDOW: Duration = Duration::from_secs(5);

pub const DOWN_MIN_MS: u64 = 1_000;
pub const DOWN_MAX_MS: u64 = 60_000;
pub const DOWN_DEFAULT_MS: u64 = 15_000;

// Concurrent-distro cap (ADR 0005) and the distro-name length bound.
pub const MAX_DISTROS: usize = 16;
pub const NAME_MAX_LEN: usize = 32;

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
}

impl State {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Stopped => "stopped",
            Self::Starting => "starting",
            Self::Running => "running",
            Self::Failed => "failed",
        }
    }
}

pub struct Distro {
    dev: String,
    state: State,
    init_pid: Option<i32>,
    started: Option<Instant>,
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
            started: None,
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
    pub const fn running_pid(&self) -> Option<i32> {
        if matches!(self.state, State::Running) {
            self.init_pid
        } else {
            None
        }
    }

    // The init pid while the distro is still up (starting or running); the
    // target for a graceful `distro_down`. None once stopped or failed.
    #[must_use]
    pub const fn active_pid(&self) -> Option<i32> {
        if self.is_active() {
            self.init_pid
        } else {
            None
        }
    }

    // A bare reservation: Starting with the dev recorded but no init pid yet.
    // It counts as active so admission (cap, dev reuse) rejects a racing peer.
    fn reserve(&mut self, dev: &str) {
        assert!(!dev.is_empty(), "distro dev required");
        self.dev = dev.to_string();
        self.state = State::Starting;
        self.init_pid = None;
        self.started = None;
    }

    #[must_use]
    const fn is_reserved(&self) -> bool {
        matches!(self.state, State::Starting) && self.init_pid.is_none()
    }

    // Fill a reserved entry with its spawned init pid, starting the ready clock.
    pub fn begin(&mut self, pid: i32) {
        assert!(pid > 0, "init pid must be positive");
        assert!(
            self.is_reserved(),
            "begin requires an outstanding reservation"
        );
        self.init_pid = Some(pid);
        self.started = Some(Instant::now());
    }

    pub fn promote(&mut self) {
        if self.state == State::Starting {
            self.state = State::Running;
        }
    }

    // Records init death; distinguishes an early crash (failed) from a clean
    // later shutdown (stopped) by the ready window.
    pub fn on_init_exit(&mut self, pid: i32) -> bool {
        if self.init_pid != Some(pid) {
            return false;
        }
        let early = self.started.is_some_and(|t| t.elapsed() < READY_WINDOW);
        self.state = if early { State::Failed } else { State::Stopped };
        self.init_pid = None;
        self.started = None;
        true
    }

    // Collapse a failed boot to stopped after a distro_down teardown so repeated
    // calls report a consistent terminal state.
    pub fn settle_stopped(&mut self) {
        if self.state == State::Failed {
            self.state = State::Stopped;
            self.init_pid = None;
            self.started = None;
        }
        debug_assert!(self.state != State::Failed);
        debug_assert!(self.state != State::Stopped || self.init_pid.is_none());
    }
}

// The named-distro table: at most MAX_DISTROS live entries keyed by name. An
// entry exists only while a distro is starting/running/terminal-pending; a
// clean teardown drops it so absent names read back as the stopped default.
#[derive(Default)]
pub struct Distros {
    map: HashMap<String, Distro>,
}

impl Distros {
    #[must_use]
    pub fn new() -> Self {
        Self {
            map: HashMap::new(),
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
    pub fn active_pid(&self, name: &str) -> Option<i32> {
        self.map.get(name).and_then(Distro::active_pid)
    }

    fn active_count(&self) -> usize {
        self.map.values().filter(|d| d.is_active()).count()
    }

    // Reserve a not-yet-active name under one lock (cap + dev-uniqueness, with
    // reservations counted), blocking a racing distro_up from double-admitting.
    pub fn reserve(&mut self, name: &str, dev: &str) -> Result<(), String> {
        assert!(!name.is_empty(), "reserve needs a name");
        assert!(!dev.is_empty(), "reserve needs a dev");
        if !self.is_active(name) && self.active_count() >= MAX_DISTROS {
            return Err("too many distros (max 16)".to_string());
        }
        // bounded: at most MAX_DISTROS entries
        for (other, distro) in &self.map {
            if other != name && distro.is_active() && distro.backs_dev(dev) {
                return Err(format!("dev {dev} already backs an active distro"));
            }
        }
        self.map.entry(name.to_string()).or_default().reserve(dev);
        debug_assert!(self.is_active(name));
        Ok(())
    }

    // Drop an outstanding reservation (spawn/prepare failure); never touches a
    // live entry that already has an init pid.
    pub fn release_reservation(&mut self, name: &str) {
        assert!(!name.is_empty(), "release needs a name");
        if self.map.get(name).is_some_and(Distro::is_reserved) {
            let _ = self.map.remove(name);
        }
    }

    pub fn begin(&mut self, name: &str, pid: i32) {
        assert!(pid > 0, "init pid must be positive");
        assert!(!name.is_empty(), "distro name required");
        if let Some(distro) = self.map.get_mut(name) {
            distro.begin(pid);
        }
    }

    pub fn promote(&mut self, name: &str) {
        assert!(!name.is_empty(), "promote needs a name");
        if let Some(distro) = self.map.get_mut(name) {
            distro.promote();
        }
    }

    // Reaper-side pid → name resolution across all entries (O(entries)); records
    // the init death on the matching entry and returns its name for logging.
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

    // Failed → Stopped settle, then drop the terminal entry so the table tracks
    // only live distros and a name query falls back to the stopped default.
    pub fn settle_and_remove(&mut self, name: &str) {
        assert!(!name.is_empty(), "settle needs a name");
        if let Some(distro) = self.map.get_mut(name) {
            distro.settle_stopped();
            if !distro.is_active() {
                let _ = self.map.remove(name);
            }
        }
        debug_assert!(!self.map.contains_key(name) || self.is_active(name));
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
pub use linux::{distro_up, poweroff_and_wait, teardown};

#[cfg(target_os = "linux")]
mod linux {
    use std::collections::HashMap;
    use std::ffi::CString;
    use std::path::Path;
    use std::sync::Mutex;
    use std::thread;
    use std::time::{Duration, Instant};

    use super::{DOWN_MAX_MS, Distros, validate_dev, validate_hostname, validate_name};
    use crate::exec::{self, ExecOpts};
    use crate::proto::{DistroStateData, DistroUpReq};
    use crate::sys::{self, BootSpec, MountOp, ToolsBind};

    const DISTRO_ROOT: &str = "/run/msl/distros";
    const MAC_SRC: &str = "/run/msl/mac";
    // The initramfs directory holding the projected interop shim (ADR 0008).
    const TOOLS_SRC: &str = "/tools";
    const READY_TICKS: u32 = 50;
    const TICK: Duration = Duration::from_millis(100);
    const DOWN_TICK: Duration = Duration::from_millis(100);
    // 600 * 100ms == 60s, the maximum clamped distro_down timeout.
    const DOWN_MAX_TICKS: u32 = 600;
    const KILL_GRACE: Duration = Duration::from_secs(2);
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
        {
            // Reserve under one lock: idempotent for a live name, else insert a
            // Starting placeholder that blocks a racing distro_up's admission.
            let mut guard = distros.lock().map_err(|_| "distro lock".to_string())?;
            if guard.is_active(&req.name) {
                return Ok(guard.snapshot(&req.name));
            }
            guard.reserve(&req.name, &req.dev)?;
        }
        match boot_reserved(distros, req) {
            Ok(()) => Ok(await_ready(distros, &req.name)),
            Err(e) => {
                if let Ok(mut guard) = distros.lock() {
                    guard.release_reservation(&req.name);
                }
                Err(e)
            }
        }
    }

    // Boot into the reserved slot: prepare mounts, clone init, record the pid.
    // The spawn lock keeps {fork, begin} atomic against the reaper.
    fn boot_reserved(distros: &Mutex<Distros>, req: &DistroUpReq) -> Result<(), String> {
        let spec = prepare_boot(req)?;
        let _spawn = crate::wait::spawn_lock();
        let pid = sys::spawn_distro_init(&spec).map_err(|e| format!("distro boot: {e}"))?;
        distros
            .lock()
            .map_err(|_| "distro lock".to_string())?
            .begin(&req.name, pid);
        Ok(())
    }

    fn await_ready(distros: &Mutex<Distros>, name: &str) -> DistroStateData {
        assert!(!name.is_empty(), "await_ready needs a name");
        // bounded: at most READY_TICKS polls of the ready window
        for _ in 0..READY_TICKS {
            thread::sleep(TICK);
            if let Ok(guard) = distros.lock()
                && !guard.is_active(name)
            {
                return guard.snapshot(name);
            }
        }
        if let Ok(mut guard) = distros.lock() {
            guard.promote(name);
            return guard.snapshot(name);
        }
        DistroStateData {
            state: "failed",
            init_pid: None,
        }
    }

    // Poweroff inside the named distro's ns, wait for init exit via the
    // reaper-updated state machine, SIGKILL on timeout. Caller owns teardown.
    pub fn poweroff_and_wait(distros: &Mutex<Distros>, name: &str, init_pid: i32, timeout_ms: u64) {
        assert!(init_pid > 0, "poweroff_and_wait needs a live init pid");
        assert!(timeout_ms >= 1, "timeout must be positive");
        let deadline = Instant::now() + Duration::from_millis(timeout_ms);
        fire_poweroff(init_pid);
        if !poll_stopped(distros, name, deadline) {
            let _ = sys::send_signal(init_pid, libc::SIGKILL);
            let _ = poll_stopped(distros, name, Instant::now() + KILL_GRACE);
        }
    }

    // sync(2) flushes the shared page cache to the block device (mandatory even
    // for a failed boot that dirtied it); the per-name unmount is best-effort.
    pub fn teardown(name: &str) {
        assert!(!name.is_empty(), "teardown needs a distro name");
        let _ = sys::sync_and_unmount(&newroot_for(name));
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

    // Poll the reaper-written state machine until the named distro stops or the
    // deadline; the lock is sampled only, never held across the sleep.
    fn poll_stopped(distros: &Mutex<Distros>, name: &str, deadline: Instant) -> bool {
        debug_assert!(
            u128::from(DOWN_MAX_TICKS) * DOWN_TICK.as_millis() >= u128::from(DOWN_MAX_MS)
        );
        // bounded: DOWN_MAX_TICKS caps iterations; the deadline caps wall time
        for _ in 0..DOWN_MAX_TICKS {
            if let Ok(guard) = distros.lock()
                && !guard.is_active(name)
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
        Ok(BootSpec {
            dev: cstr(&req.dev)?,
            newroot: cstr(&newroot)?,
            mounts: guest_mounts(&newroot)?,
            mac,
            tools,
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
        DOWN_DEFAULT_MS, DOWN_MAX_MS, DOWN_MIN_MS, Distro, Distros, MAX_DISTROS,
        clamp_down_timeout, validate_name,
    };

    const DEV_A: &str = "/dev/vda";
    const DEV_B: &str = "/dev/vdb";

    // Reserve-then-begin, the two-step admission a live distro goes through.
    fn up(table: &mut Distros, name: &str, dev: &str, pid: i32) {
        table.reserve(name, dev).expect("reserve under cap");
        table.begin(name, pid);
    }

    #[test]
    fn settle_collapses_failed_to_stopped() {
        let mut distro = Distro::new();
        distro.reserve(DEV_A);
        distro.begin(4242);
        assert!(distro.on_init_exit(4242), "recorded init exit");
        assert_eq!(distro.snapshot().state, "failed");
        distro.settle_stopped();
        assert_eq!(distro.snapshot().state, "stopped");
        assert!(distro.snapshot().init_pid.is_none());
    }

    #[test]
    fn settle_leaves_stopped_untouched() {
        let mut distro = Distro::new();
        distro.settle_stopped();
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
        up(&mut table, "one", DEV_A, 100);
        up(&mut table, "two", DEV_B, 200);
        table.promote("one");
        table.promote("two");
        assert_eq!(table.running_pid("one"), Some(100));
        assert_eq!(table.running_pid("two"), Some(200));
        // one clean shutdown (outside the ready window) leaves two untouched.
        assert_eq!(table.on_init_exit(100).as_deref(), Some("one"));
        assert!(!table.is_active("one"));
        assert!(table.is_active("two"));
        assert_eq!(table.running_pid("two"), Some(200));
        table.settle_and_remove("one");
        assert_eq!(table.snapshot("one").state, "stopped");
        assert_eq!(table.list().len(), 1);
    }

    #[test]
    fn dev_reuse_rejected_among_active() {
        let mut table = Distros::new();
        up(&mut table, "one", DEV_A, 100);
        assert!(table.reserve("two", DEV_A).is_err(), "dev A already active");
        assert!(table.reserve("two", DEV_B).is_ok(), "distinct dev admitted");
        table.begin("two", 200);
        // once the holder exits and tears down, its dev is free to reuse.
        assert!(table.on_init_exit(100).is_some());
        table.settle_and_remove("one");
        assert!(
            table.reserve("three", DEV_A).is_ok(),
            "dev freed after teardown"
        );
    }

    // A reservation counts before any pid exists, so a concurrent distro_up for
    // the same dev cannot double-pass admission — the fix for the earlier TOCTOU.
    #[test]
    fn reservation_blocks_concurrent_admission() {
        let mut table = Distros::new();
        table.reserve("ubuntu", DEV_A).expect("first reservation");
        // The bare reservation is visible as active with no pid yet.
        assert!(table.is_active("ubuntu"), "reservation counts as active");
        assert_eq!(table.snapshot("ubuntu").state, "starting");
        assert!(table.snapshot("ubuntu").init_pid.is_none());
        // A racing peer reusing the dev is rejected before it can spawn.
        assert!(
            table.reserve("other", DEV_A).is_err(),
            "dev held by reservation"
        );
        // Abandoning the reservation frees the dev again.
        table.release_reservation("ubuntu");
        assert!(!table.is_active("ubuntu"));
        assert!(
            table.reserve("other", DEV_A).is_ok(),
            "dev freed on release"
        );
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
        // an already-active name is not a new admission and stays allowed.
        assert!(table.reserve("d0", "/dev/vda").is_ok(), "reentrant name ok");
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
