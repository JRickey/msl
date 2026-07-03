//! Spawn an argv, capture stdout/stderr (each capped at 1 MiB), enforce a
//! wall-clock timeout with `SIGKILL`, and reap the child.

use std::collections::HashMap;
use std::io::{self, Read};
use std::os::unix::io::AsRawFd;
use std::process::{Child, Command, Stdio};
#[cfg(not(target_os = "linux"))]
use std::process::{ChildStderr, ChildStdout, ExitStatus};
use std::time::{Duration, Instant};

use crate::proto::ExecData;
use crate::sys::{self, PollTarget};

pub struct ExecOpts<'a> {
    pub distro: bool,
    pub cwd: Option<&'a str>,
    pub init_pid: Option<i32>,
}

const MAX_CAPTURE: usize = 1024 * 1024;
const READ_CHUNK: usize = 16 * 1024;
const MAX_POLL_ITERS: usize = 8 * 1024 * 1024;
const POLL_SLICE_MS: u128 = 1000;
const MIN_TIMEOUT_MS: u64 = 1000;
const MAX_TIMEOUT_MS: u64 = 86_400_000;
#[cfg(target_os = "linux")]
const GRACE_MS: u64 = 1000;
#[cfg(not(target_os = "linux"))]
const POLL_IDLE_MS: u64 = 20;

struct Capture {
    buf: Vec<u8>,
    truncated: bool,
}

impl Capture {
    const fn new() -> Self {
        Self {
            buf: Vec::new(),
            truncated: false,
        }
    }

    fn push(&mut self, data: &[u8]) {
        let used = self.buf.len();
        debug_assert!(used <= MAX_CAPTURE);
        let room = MAX_CAPTURE - used;
        if data.len() <= room {
            self.buf.extend_from_slice(data);
        } else {
            self.buf.extend_from_slice(&data[..room]);
            self.truncated = true;
        }
    }

    fn bytes(&self) -> &[u8] {
        &self.buf
    }

    const fn truncated(&self) -> bool {
        self.truncated
    }
}

pub fn run(
    argv: &[String],
    env: &HashMap<String, String>,
    timeout_ms: u64,
    opts: &ExecOpts,
) -> Result<ExecData, String> {
    assert_valid_argv(argv)?;
    let deadline_ms = timeout_ms.clamp(MIN_TIMEOUT_MS, MAX_TIMEOUT_MS);
    if opts.distro {
        run_distro(argv, env, deadline_ms, opts)
    } else {
        run_local(argv, env, deadline_ms, opts.cwd)
    }
}

// Host build: no reaper thread exists, so the child is waited directly.
#[cfg(not(target_os = "linux"))]
fn run_local(
    argv: &[String],
    env: &HashMap<String, String>,
    timeout_ms: u64,
    cwd: Option<&str>,
) -> Result<ExecData, String> {
    let mut child = spawn_child(argv, env, cwd)?;
    match capture(&mut child, timeout_ms) {
        Ok(data) => Ok(data),
        Err(message) => {
            let _ = child.kill();
            let _ = child.wait();
            Err(message)
        }
    }
}

// Linux: register under the spawn lock and read the status from the wait table.
#[cfg(target_os = "linux")]
fn run_local(
    argv: &[String],
    env: &HashMap<String, String>,
    timeout_ms: u64,
    cwd: Option<&str>,
) -> Result<ExecData, String> {
    let (mut child, pid) = {
        let _spawn = crate::wait::spawn_lock();
        let child = spawn_child(argv, env, cwd)?;
        let pid = i32::try_from(child.id()).map_err(|_| "exec failed: pid overflow".to_string())?;
        crate::wait::register(pid);
        (child, pid)
    };
    capture_reaped(&mut child, pid, timeout_ms)
}

#[cfg(not(target_os = "linux"))]
fn run_distro(
    _argv: &[String],
    _env: &HashMap<String, String>,
    _timeout_ms: u64,
    _opts: &ExecOpts,
) -> Result<ExecData, String> {
    Err("distro exec requires linux".to_string())
}

fn assert_valid_argv(argv: &[String]) -> Result<(), String> {
    if argv.is_empty() {
        return Err("exec failed: argv must be non-empty".to_string());
    }
    if !argv[0].starts_with('/') {
        return Err("exec failed: argv[0] must be an absolute path".to_string());
    }
    Ok(())
}

fn spawn_child(
    argv: &[String],
    env: &HashMap<String, String>,
    cwd: Option<&str>,
) -> Result<Child, String> {
    assert_valid_argv(argv)?;
    debug_assert!(!argv[0].is_empty());
    let mut cmd = Command::new(&argv[0]);
    cmd.args(&argv[1..]);
    cmd.env_clear();
    for (key, value) in env {
        cmd.env(key, value);
    }
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    cmd.stdin(Stdio::null());
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());
    cmd.spawn().map_err(|e| format!("exec failed: {e}"))
}

#[cfg(not(target_os = "linux"))]
fn capture(child: &mut Child, timeout_ms: u64) -> Result<ExecData, String> {
    debug_assert!(timeout_ms <= MAX_TIMEOUT_MS);
    let mut out = child
        .stdout
        .take()
        .ok_or_else(|| "exec failed: missing stdout pipe".to_string())?;
    let mut err = child
        .stderr
        .take()
        .ok_or_else(|| "exec failed: missing stderr pipe".to_string())?;
    sys::set_nonblocking(out.as_raw_fd()).map_err(|e| format!("exec failed: {e}"))?;
    sys::set_nonblocking(err.as_raw_fd()).map_err(|e| format!("exec failed: {e}"))?;
    drain_until_exit(child, &mut out, &mut err, timeout_ms)
}

#[cfg(not(target_os = "linux"))]
fn drain_until_exit(
    child: &mut Child,
    out: &mut ChildStdout,
    err: &mut ChildStderr,
    timeout_ms: u64,
) -> Result<ExecData, String> {
    debug_assert!(timeout_ms <= MAX_TIMEOUT_MS);
    let out_fd = out.as_raw_fd();
    let err_fd = err.as_raw_fd();
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let mut out_cap = Capture::new();
    let mut err_cap = Capture::new();
    let mut out_done = false;
    let mut err_done = false;

    // bounded drain loop: MAX_POLL_ITERS caps iterations; the deadline caps wall time
    for _ in 0..MAX_POLL_ITERS {
        if Instant::now() >= deadline {
            return Err("timeout".to_string());
        }
        if out_done && err_done {
            match child.try_wait().map_err(|e| format!("exec failed: {e}"))? {
                Some(status) => return Ok(finish(status, &out_cap, &err_cap)),
                None => std::thread::sleep(Duration::from_millis(POLL_IDLE_MS)),
            }
        } else {
            let mut targets = [
                PollTarget::read(out_fd, out_done),
                PollTarget::read(err_fd, err_done),
            ];
            sys::poll_fds(&mut targets, remaining_ms(deadline, Instant::now()))
                .map_err(|e| format!("exec failed: {e}"))?;
            if targets[0].ready || targets[0].hup {
                out_done = drain(out, &mut out_cap)?;
            }
            if targets[1].ready || targets[1].hup {
                err_done = drain(err, &mut err_cap)?;
            }
        }
    }
    Err("exec failed: output drain exceeded iteration bound".to_string())
}

fn drain(stream: &mut impl Read, cap: &mut Capture) -> Result<bool, String> {
    let mut chunk = [0u8; READ_CHUNK];
    match stream.read(&mut chunk) {
        Ok(0) => Ok(true),
        Ok(n) => {
            debug_assert!(n <= READ_CHUNK);
            cap.push(&chunk[..n]);
            Ok(false)
        }
        Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => Ok(false),
        Err(e) => Err(format!("exec failed: {e}")),
    }
}

fn remaining_ms(deadline: Instant, now: Instant) -> i32 {
    debug_assert!(deadline >= now);
    let ms = deadline.saturating_duration_since(now).as_millis();
    i32::try_from(ms.min(POLL_SLICE_MS)).unwrap_or(1000)
}

#[cfg(not(target_os = "linux"))]
fn finish(status: ExitStatus, out: &Capture, err: &Capture) -> ExecData {
    finish_code(status.code().unwrap_or(-1), out, err)
}

fn finish_code(exit_code: i32, out: &Capture, err: &Capture) -> ExecData {
    ExecData {
        exit_code,
        stdout: String::from_utf8_lossy(out.bytes()).into_owned(),
        stderr: String::from_utf8_lossy(err.bytes()).into_owned(),
        truncated: out.truncated() || err.truncated(),
    }
}

// Drain and read status; any post-registration failure goes through cleanup.
#[cfg(target_os = "linux")]
fn capture_reaped(child: &mut Child, pid: i32, timeout_ms: u64) -> Result<ExecData, String> {
    let result = capture_reaped_inner(child, pid, timeout_ms);
    if result.is_err() {
        cleanup_registered(pid, pid);
    }
    result
}

#[cfg(target_os = "linux")]
fn capture_reaped_inner(child: &mut Child, pid: i32, timeout_ms: u64) -> Result<ExecData, String> {
    let mut out = child
        .stdout
        .take()
        .ok_or_else(|| "exec failed: missing stdout pipe".to_string())?;
    let mut err = child
        .stderr
        .take()
        .ok_or_else(|| "exec failed: missing stderr pipe".to_string())?;
    sys::set_nonblocking(out.as_raw_fd()).map_err(|e| format!("exec failed: {e}"))?;
    sys::set_nonblocking(err.as_raw_fd()).map_err(|e| format!("exec failed: {e}"))?;
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let mut out_cap = Capture::new();
    let mut err_cap = Capture::new();
    let mut out_done = false;
    let mut err_done = false;
    // bounded drain loop: MAX_POLL_ITERS caps iterations; the deadline caps wall time
    for _ in 0..MAX_POLL_ITERS {
        if Instant::now() >= deadline || (out_done && err_done) {
            break;
        }
        let mut targets = [
            PollTarget::read(out.as_raw_fd(), out_done),
            PollTarget::read(err.as_raw_fd(), err_done),
        ];
        sys::poll_fds(&mut targets, remaining_ms(deadline, Instant::now()))
            .map_err(|e| format!("exec failed: {e}"))?;
        if targets[0].ready || targets[0].hup {
            out_done = drain(&mut out, &mut out_cap)?;
        }
        if targets[1].ready || targets[1].hup {
            err_done = drain(&mut err, &mut err_cap)?;
        }
    }
    let code =
        reaped_status(pid, out_done && err_done, deadline).ok_or_else(|| "timeout".to_string())?;
    Ok(finish_code(code, &out_cap, &err_cap))
}

#[cfg(target_os = "linux")]
fn reaped_status(pid: i32, drained: bool, deadline: Instant) -> Option<i32> {
    if !drained {
        return None;
    }
    crate::wait::wait(pid, deadline)
}

// Single cleanup owner: kill the command, let the reaper collect the leader, drop the slot.
#[cfg(target_os = "linux")]
fn cleanup_registered(leader: i32, target: i32) {
    let _ = sys::send_signal(target, libc::SIGKILL);
    let _ = crate::wait::wait(leader, Instant::now() + Duration::from_millis(GRACE_MS));
    crate::wait::unregister(leader);
}

#[cfg(target_os = "linux")]
fn run_distro(
    argv: &[String],
    env: &HashMap<String, String>,
    timeout_ms: u64,
    opts: &ExecOpts,
) -> Result<ExecData, String> {
    let init_pid = opts
        .init_pid
        .ok_or_else(|| "distro not running".to_string())?;
    let ns_fds = sys::open_ns_fds(init_pid).map_err(|e| format!("exec failed: {e}"))?;
    let spec = build_capture_spec(argv, env, opts.cwd, ns_fds)?;
    let child = {
        let _spawn = crate::wait::spawn_lock();
        let spawned = sys::spawn_captured(&spec);
        sys::close_all(&spec.ns_fds);
        let child = spawned.map_err(|e| format!("exec failed: {e}"))?;
        crate::wait::register(child.leader);
        child
    };
    capture_raw(&child, timeout_ms)
}

#[cfg(target_os = "linux")]
fn build_capture_spec(
    argv: &[String],
    env: &HashMap<String, String>,
    cwd: Option<&str>,
    ns_fds: Vec<std::os::unix::io::RawFd>,
) -> Result<sys::CaptureSpec, String> {
    use std::ffi::CString;
    let mut argv_c: Vec<CString> = Vec::with_capacity(argv.len());
    // bounded: argv is frame-bounded
    for item in argv {
        argv_c.push(CString::new(item.as_str()).map_err(|_| "nul in argv".to_string())?);
    }
    let mut envp_c: Vec<CString> = Vec::with_capacity(env.len());
    // bounded: env is frame-bounded
    for (key, value) in env {
        let pair = format!("{key}={value}");
        envp_c.push(CString::new(pair).map_err(|_| "nul in env".to_string())?);
    }
    let cwd_c = match cwd {
        Some(dir) => Some(CString::new(dir).map_err(|_| "nul in cwd".to_string())?),
        None => None,
    };
    assert!(!argv_c.is_empty(), "captured argv must be non-empty");
    Ok(sys::CaptureSpec {
        ns_fds,
        cwd: cwd_c,
        argv: argv_c,
        envp: envp_c,
    })
}

#[cfg(target_os = "linux")]
fn capture_raw(child: &sys::CapturedChild, timeout_ms: u64) -> Result<ExecData, String> {
    let result = capture_raw_inner(child, timeout_ms);
    if result.is_err() {
        cleanup_registered(child.leader, child.target);
    }
    result
}

#[cfg(target_os = "linux")]
fn capture_raw_inner(child: &sys::CapturedChild, timeout_ms: u64) -> Result<ExecData, String> {
    let out_fd = child.out;
    let err_fd = child.err;
    let _ = sys::set_nonblocking(out_fd);
    let _ = sys::set_nonblocking(err_fd);
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let mut out_cap = Capture::new();
    let mut err_cap = Capture::new();
    let mut out_done = false;
    let mut err_done = false;
    // bounded drain loop: MAX_POLL_ITERS caps iterations; the deadline caps wall time
    for _ in 0..MAX_POLL_ITERS {
        if Instant::now() >= deadline || (out_done && err_done) {
            break;
        }
        let mut targets = [
            PollTarget::read(out_fd, out_done),
            PollTarget::read(err_fd, err_done),
        ];
        if sys::poll_fds(&mut targets, remaining_ms(deadline, Instant::now())).is_err() {
            break;
        }
        if targets[0].ready || targets[0].hup {
            out_done = drain_raw(out_fd, &mut out_cap);
        }
        if targets[1].ready || targets[1].hup {
            err_done = drain_raw(err_fd, &mut err_cap);
        }
    }
    sys::close_fd(out_fd);
    sys::close_fd(err_fd);
    let code = reaped_status(child.leader, out_done && err_done, deadline)
        .ok_or_else(|| "timeout".to_string())?;
    Ok(finish_code(code, &out_cap, &err_cap))
}

#[cfg(target_os = "linux")]
fn drain_raw(fd: std::os::unix::io::RawFd, cap: &mut Capture) -> bool {
    let mut chunk = [0u8; READ_CHUNK];
    match sys::read_fd(fd, &mut chunk) {
        Ok(0) => true,
        Ok(n) => {
            debug_assert!(n <= READ_CHUNK);
            cap.push(&chunk[..n]);
            false
        }
        Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => false,
        Err(_) => true,
    }
}

#[cfg(test)]
mod tests {
    use super::{ExecOpts, run};
    use std::collections::HashMap;
    use std::time::Instant;

    fn local() -> ExecOpts<'static> {
        ExecOpts {
            distro: false,
            cwd: None,
            init_pid: None,
        }
    }

    #[test]
    fn rejects_empty_argv() {
        let argv: Vec<String> = Vec::new();
        let err = run(&argv, &HashMap::new(), 1000, &local()).expect_err("empty argv rejected");
        assert!(err.contains("non-empty"));
    }

    #[test]
    fn rejects_relative_argv0() {
        let argv = vec!["echo".to_string()];
        let err = run(&argv, &HashMap::new(), 1000, &local()).expect_err("relative path rejected");
        assert!(err.contains("absolute"));
    }

    #[test]
    fn timeout_kills_child() {
        let argv = vec!["/bin/sleep".to_string(), "5".to_string()];
        let err = run(&argv, &HashMap::new(), 100, &local()).expect_err("must time out");
        assert_eq!(err, "timeout");
    }

    #[test]
    fn timeout_when_child_closes_streams_but_stays_alive() {
        let argv = vec![
            "/bin/sh".to_string(),
            "-c".to_string(),
            "exec >/dev/null 2>&1; sleep 5".to_string(),
        ];
        let started = Instant::now();
        let err = run(&argv, &HashMap::new(), 100, &local()).expect_err("must time out");
        assert_eq!(err, "timeout");
        assert!(
            started.elapsed().as_secs() < 2,
            "must not block on child.wait: {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn huge_timeout_does_not_panic() {
        let argv = vec!["/bin/echo".to_string(), "ok".to_string()];
        let data =
            run(&argv, &HashMap::new(), u64::MAX, &local()).expect("must complete without panic");
        assert_eq!(data.exit_code, 0);
        assert_eq!(data.stdout, "ok\n");
    }

    #[test]
    fn tiny_timeout_clamps_to_floor() {
        // timeout_ms:1 clamps to the 1s floor, so a fast command still completes.
        let argv = vec!["/bin/echo".to_string(), "ok".to_string()];
        let data = run(&argv, &HashMap::new(), 1, &local()).expect("clamped floor completes");
        assert_eq!(data.exit_code, 0);
        assert_eq!(data.stdout, "ok\n");
    }

    #[test]
    fn cwd_is_applied() {
        let argv = vec!["/bin/pwd".to_string()];
        let opts = ExecOpts {
            distro: false,
            cwd: Some("/tmp"),
            init_pid: None,
        };
        let data = run(&argv, &HashMap::new(), 5000, &opts).expect("pwd runs");
        assert!(data.stdout.starts_with("/tmp") || data.stdout.starts_with("/private/tmp"));
    }
}
