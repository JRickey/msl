//! Distro lifecycle: the boot state machine (host-testable) and the Linux
//! `clone`-into-namespaces boot that mounts an ext4 root, sets up the guest
//! filesystems, `pivot_root`s and execs `/sbin/init`.

use std::time::{Duration, Instant};

use crate::proto::DistroStateData;

pub const READY_WINDOW: Duration = Duration::from_secs(5);

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
pub use linux::distro_up;

#[cfg(target_os = "linux")]
mod linux {
    use std::ffi::CString;
    use std::path::Path;
    use std::sync::Mutex;
    use std::thread;
    use std::time::Duration;

    use super::{Distro, validate_dev, validate_hostname};
    use crate::proto::{DistroStateData, DistroUpReq};
    use crate::sys::{self, BootSpec, MountOp};

    const NEWROOT: &str = "/run/msl/newroot";
    const MAC_SRC: &str = "/run/msl/mac";
    const READY_TICKS: u32 = 50;
    const TICK: Duration = Duration::from_millis(100);

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
