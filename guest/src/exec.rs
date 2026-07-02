//! Spawn an argv, capture stdout/stderr (each capped at 1 MiB), enforce a
//! wall-clock timeout with `SIGKILL`, and reap the child.

use std::collections::HashMap;
use std::io::{self, Read};
use std::os::unix::io::AsRawFd;
use std::process::{Child, ChildStderr, ChildStdout, Command, ExitStatus, Stdio};
use std::time::{Duration, Instant};

use crate::proto::ExecData;
use crate::sys::{self, PollTarget};

const MAX_CAPTURE: usize = 1024 * 1024;
const READ_CHUNK: usize = 16 * 1024;
const MAX_POLL_ITERS: usize = 8 * 1024 * 1024;
const POLL_SLICE_MS: u128 = 1000;
const POLL_IDLE_MS: u64 = 20;
const MAX_TIMEOUT_MS: u64 = 86_400_000;

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
) -> Result<ExecData, String> {
    assert_valid_argv(argv)?;
    let deadline_ms = timeout_ms.min(MAX_TIMEOUT_MS);
    let mut child = spawn_child(argv, env)?;
    match capture(&mut child, deadline_ms) {
        Ok(data) => Ok(data),
        Err(message) => {
            let _ = child.kill();
            let _ = child.wait();
            Err(message)
        }
    }
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

fn spawn_child(argv: &[String], env: &HashMap<String, String>) -> Result<Child, String> {
    assert_valid_argv(argv)?;
    debug_assert!(!argv[0].is_empty());
    let mut cmd = Command::new(&argv[0]);
    cmd.args(&argv[1..]);
    cmd.env_clear();
    for (key, value) in env {
        cmd.env(key, value);
    }
    cmd.stdin(Stdio::null());
    cmd.stdout(Stdio::piped());
    cmd.stderr(Stdio::piped());
    cmd.spawn().map_err(|e| format!("exec failed: {e}"))
}

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

fn finish(status: ExitStatus, out: &Capture, err: &Capture) -> ExecData {
    let exit_code = status.code().unwrap_or(-1);
    ExecData {
        exit_code,
        stdout: String::from_utf8_lossy(out.bytes()).into_owned(),
        stderr: String::from_utf8_lossy(err.bytes()).into_owned(),
        truncated: out.truncated() || err.truncated(),
    }
}

#[cfg(test)]
mod tests {
    use super::run;
    use std::collections::HashMap;
    use std::time::Instant;

    #[test]
    fn rejects_empty_argv() {
        let argv: Vec<String> = Vec::new();
        let err = run(&argv, &HashMap::new(), 1000).expect_err("empty argv rejected");
        assert!(err.contains("non-empty"));
    }

    #[test]
    fn rejects_relative_argv0() {
        let argv = vec!["echo".to_string()];
        let err = run(&argv, &HashMap::new(), 1000).expect_err("relative path rejected");
        assert!(err.contains("absolute"));
    }

    #[test]
    fn timeout_kills_child() {
        let argv = vec!["/bin/sleep".to_string(), "5".to_string()];
        let err = run(&argv, &HashMap::new(), 100).expect_err("must time out");
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
        let err = run(&argv, &HashMap::new(), 100).expect_err("must time out");
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
        let data = run(&argv, &HashMap::new(), u64::MAX).expect("must complete without panic");
        assert_eq!(data.exit_code, 0);
        assert_eq!(data.stdout, "ok\n");
    }
}
