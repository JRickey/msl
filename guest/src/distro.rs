//! Distro lifecycle: the boot state machine (host-testable) and the Linux
//! `clone`-into-namespaces boot that mounts an ext4 root, sets up the guest
//! filesystems, `pivot_root`s and execs `/sbin/init`.

use std::time::{Duration, Instant};

use crate::proto::DistroStateData;

pub const READY_WINDOW: Duration = Duration::from_secs(5);

pub const DOWN_MIN_MS: u64 = 1_000;
pub const DOWN_MAX_MS: u64 = 60_000;
pub const DOWN_DEFAULT_MS: u64 = 15_000;

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
            state: State::Stopped,
            init_pid: None,
            started: None,
        }
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

    pub fn begin(&mut self, pid: i32) {
        assert!(pid > 0, "init pid must be positive");
        self.state = State::Starting;
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

    use super::{DOWN_MAX_MS, Distro, validate_dev, validate_hostname};
    use crate::exec::{self, ExecOpts};
    use crate::proto::{DistroStateData, DistroUpReq};
    use crate::sys::{self, BootSpec, MountOp};

    const NEWROOT: &str = "/run/msl/newroot";
    const MAC_SRC: &str = "/run/msl/mac";
    const READY_TICKS: u32 = 50;
    const TICK: Duration = Duration::from_millis(100);
    const DOWN_TICK: Duration = Duration::from_millis(100);
    // 600 * 100ms == 60s, the maximum clamped distro_down timeout.
    const DOWN_MAX_TICKS: u32 = 600;
    const KILL_GRACE: Duration = Duration::from_secs(2);
    // Fixed poweroff-exec budget (v1.1.1): independent of timeout_ms, since
    // `systemctl poweroff` only requests shutdown and returns immediately.
    const POWEROFF_EXEC_MS: u64 = 3_000;

    pub fn distro_up(distro: &Mutex<Distro>, req: &DistroUpReq) -> Result<DistroStateData, String> {
        validate_dev(&req.dev)?;
        validate_hostname(&req.hostname)?;
        {
            let guard = distro.lock().map_err(|_| "distro lock".to_string())?;
            if guard.is_active() {
                return Ok(guard.snapshot());
            }
        }
        let spec = prepare_boot(req)?;
        {
            // Hold the spawn lock across fork+register so the reaper cannot see
            // the init pid before begin() records it.
            let _spawn = crate::wait::spawn_lock();
            let pid = sys::spawn_distro_init(&spec).map_err(|e| format!("distro boot: {e}"))?;
            distro
                .lock()
                .map_err(|_| "distro lock".to_string())?
                .begin(pid);
        }
        Ok(await_ready(distro))
    }

    fn await_ready(distro: &Mutex<Distro>) -> DistroStateData {
        // bounded: at most READY_TICKS polls of the ready window
        for _ in 0..READY_TICKS {
            thread::sleep(TICK);
            if let Ok(guard) = distro.lock()
                && !guard.is_active()
            {
                return guard.snapshot();
            }
        }
        if let Ok(mut guard) = distro.lock() {
            guard.promote();
            return guard.snapshot();
        }
        DistroStateData {
            state: "failed",
            init_pid: None,
        }
    }

    // Poweroff inside the distro ns, wait for init exit via the reaper-updated
    // state machine, SIGKILL on timeout. The caller owns the teardown.
    pub fn poweroff_and_wait(distro: &Mutex<Distro>, init_pid: i32, timeout_ms: u64) {
        assert!(init_pid > 0, "poweroff_and_wait needs a live init pid");
        assert!(timeout_ms >= 1, "timeout must be positive");
        let deadline = Instant::now() + Duration::from_millis(timeout_ms);
        fire_poweroff(init_pid);
        if !poll_stopped(distro, deadline) {
            let _ = sys::send_signal(init_pid, libc::SIGKILL);
            let _ = poll_stopped(distro, Instant::now() + KILL_GRACE);
        }
    }

    // sync(2) flushes the shared page cache to the block device (mandatory even
    // for a failed boot that dirtied it); the unmount is best-effort.
    pub fn teardown() {
        let _ = sys::sync_and_unmount(NEWROOT);
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

    // Poll the reaper-written state machine until stopped or the deadline; the
    // lock is held only to sample, never across the sleep (no reaper deadlock).
    fn poll_stopped(distro: &Mutex<Distro>, deadline: Instant) -> bool {
        debug_assert!(
            u128::from(DOWN_MAX_TICKS) * DOWN_TICK.as_millis() >= u128::from(DOWN_MAX_MS)
        );
        // bounded: DOWN_MAX_TICKS caps iterations; the deadline caps wall time
        for _ in 0..DOWN_MAX_TICKS {
            if let Ok(guard) = distro.lock()
                && !guard.is_active()
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

    fn prepare_boot(req: &DistroUpReq) -> Result<BootSpec, String> {
        std::fs::create_dir_all(NEWROOT).map_err(|e| format!("newroot: {e}"))?;
        let mac = if req.mac_share && Path::new(MAC_SRC).exists() {
            Some((cstr(MAC_SRC)?, cstr(&format!("{NEWROOT}/mnt/mac"))?))
        } else {
            None
        };
        Ok(BootSpec {
            dev: cstr(&req.dev)?,
            newroot: cstr(NEWROOT)?,
            mounts: guest_mounts()?,
            mac,
            hostname: cstr(&req.hostname)?,
            argv: vec![cstr("/sbin/init")?],
            envp: vec![
                cstr("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")?,
                cstr("container=msl")?,
            ],
        })
    }

    fn guest_mounts() -> Result<Vec<MountOp>, String> {
        Ok(vec![
            mnt("proc", "/proc", "proc", None)?,
            mnt("sysfs", "/sys", "sysfs", None)?,
            mnt("devtmpfs", "/dev", "devtmpfs", None)?,
            mnt(
                "devpts",
                "/dev/pts",
                "devpts",
                Some("mode=0620,ptmxmode=0666"),
            )?,
            mnt("tmpfs", "/dev/shm", "tmpfs", Some("mode=1777"))?,
            mnt("tmpfs", "/run", "tmpfs", Some("mode=0755"))?,
            mnt("cgroup2", "/sys/fs/cgroup", "cgroup2", None)?,
        ])
    }

    fn mnt(
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
            target: cstr(&format!("{NEWROOT}{target}"))?,
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
    use super::{DOWN_DEFAULT_MS, DOWN_MAX_MS, DOWN_MIN_MS, Distro, clamp_down_timeout};

    #[test]
    fn settle_collapses_failed_to_stopped() {
        let mut distro = Distro::new();
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
