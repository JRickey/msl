//! PTY-backed sessions: the bounded session table and single-use data-plane
//! tokens (host-testable), plus the Linux allocate/spawn/pump machinery that
//! binds a session's PTY master to a vsock data connection.

use std::collections::HashMap;
use std::fmt::Write as _;
use std::io::{self, Read};
use std::os::unix::io::RawFd;

pub const MAX_SESSIONS: usize = 64;
const TOKEN_BYTES: usize = 16;

pub struct SessionEntry {
    pub token: String,
    pub consumed: bool,
    pub attached: bool,
    // `pid` is the process the shell runs as (signal/SIGHUP target); `leader_pid`
    // is the agent's direct child whose reaped exit is the session exit.
    pub pid: i32,
    pub leader_pid: i32,
    pub master_fd: RawFd,
    pub rows: u16,
    pub cols: u16,
    pub done: bool,
    pub exit_code: Option<i32>,
}

pub struct Sessions {
    map: HashMap<u64, SessionEntry>,
    next_id: u64,
}

impl Default for Sessions {
    fn default() -> Self {
        Self::new()
    }
}

impl Sessions {
    #[must_use]
    pub fn new() -> Self {
        Self {
            map: HashMap::new(),
            next_id: 1,
        }
    }

    #[must_use]
    pub fn has_capacity(&self) -> bool {
        self.map.len() < MAX_SESSIONS
    }

    pub fn insert(&mut self, entry: SessionEntry) -> Result<u64, String> {
        if !self.has_capacity() {
            return Err("too many sessions".to_string());
        }
        let id = self.next_id;
        self.next_id = self.next_id.saturating_add(1);
        assert!(!self.map.contains_key(&id), "session id must be fresh");
        self.map.insert(id, entry);
        Ok(id)
    }

    // Validate a data-plane handshake: token must match an unconsumed session.
    pub fn authorize(&mut self, id: u64, token: &str) -> Result<RawFd, String> {
        let entry = self.map.get_mut(&id).ok_or("no such session")?;
        if entry.consumed || entry.token != token {
            return Err("bad session token".to_string());
        }
        assert!(!entry.consumed, "token single-use invariant");
        entry.consumed = true;
        entry.attached = true;
        Ok(entry.master_fd)
    }

    pub fn record_exit(&mut self, leader_pid: i32, code: i32) -> bool {
        for entry in self.map.values_mut() {
            if entry.leader_pid == leader_pid {
                entry.done = true;
                entry.exit_code = Some(code);
                return true;
            }
        }
        false
    }

    pub fn wait(&mut self, id: u64) -> Result<(bool, Option<i32>), String> {
        let entry = self.map.get(&id).ok_or("no such session")?;
        let done = entry.done;
        let code = entry.exit_code;
        let master = entry.master_fd;
        if done {
            // Close the master of a finished-but-never-attached session before
            // dropping it; an attached one was already closed by detach.
            close_master(master);
            let _ = self.map.remove(&id);
        }
        Ok((done, code))
    }

    pub fn resize(&mut self, id: u64, rows: u16, cols: u16) -> Result<RawFd, String> {
        let entry = self.map.get_mut(&id).ok_or("no such session")?;
        if entry.master_fd < 0 {
            return Err("session closed".to_string());
        }
        entry.rows = rows;
        entry.cols = cols;
        Ok(entry.master_fd)
    }

    pub fn pid_of(&self, id: u64) -> Result<i32, String> {
        let entry = self.map.get(&id).ok_or("no such session")?;
        assert!(entry.pid > 0, "live session must have a pid");
        Ok(entry.pid)
    }

    pub fn detach(&mut self, id: u64) {
        if let Some(entry) = self.map.get_mut(&id) {
            entry.attached = false;
            close_master(entry.master_fd);
            entry.master_fd = -1;
        }
    }
}

#[cfg(target_os = "linux")]
fn close_master(fd: RawFd) {
    crate::sys::close_fd(fd);
}

#[cfg(not(target_os = "linux"))]
const fn close_master(_fd: RawFd) {}

pub fn generate_token() -> Result<String, String> {
    let mut buf = [0u8; TOKEN_BYTES];
    read_urandom(&mut buf).map_err(|e| format!("token: {e}"))?;
    let mut out = String::with_capacity(TOKEN_BYTES * 2);
    // bounded: fixed 16-byte token
    for byte in buf {
        let _ = write!(out, "{byte:02x}");
    }
    assert_eq!(out.len(), TOKEN_BYTES * 2);
    Ok(out)
}

fn read_urandom(buf: &mut [u8]) -> io::Result<()> {
    assert!(!buf.is_empty());
    let mut file = std::fs::File::open("/dev/urandom")?;
    file.read_exact(buf)?;
    Ok(())
}

pub fn validate_open(argv: &[String], rows: u16, cols: u16) -> Result<(), String> {
    if argv.is_empty() {
        return Err("session argv must be non-empty".to_string());
    }
    if !argv[0].starts_with('/') {
        return Err("session argv[0] must be an absolute path".to_string());
    }
    if rows == 0 || cols == 0 {
        return Err("session rows/cols must be non-zero".to_string());
    }
    Ok(())
}

pub fn validate_signal(sig: i32) -> Result<(), String> {
    if (1..=64).contains(&sig) {
        Ok(())
    } else {
        Err("signal out of range".to_string())
    }
}

#[cfg(target_os = "linux")]
pub use linux::{open_session, pump};

#[cfg(target_os = "linux")]
mod linux {
    use std::collections::HashMap;
    use std::ffi::CString;
    use std::io;
    use std::os::unix::io::{AsRawFd, RawFd};
    use std::sync::Mutex;

    use vsock::VsockStream;

    use super::{SessionEntry, Sessions, generate_token, validate_open};
    use crate::proto::{SessionOpenData, SessionOpenReq};
    use crate::sys::{self, PollTarget, SessionSpawn, SessionSpec, SlaveSource};

    const CAP: usize = 64 * 1024;
    const CHUNK: usize = 16 * 1024;
    const MAX_DRAIN: usize = 16;
    const POLL_MS: i32 = 1000;

    pub fn open_session(
        sessions: &Mutex<Sessions>,
        req: &SessionOpenReq,
        init_pid: Option<i32>,
    ) -> Result<SessionOpenData, String> {
        validate_open(&req.argv, req.rows, req.cols)?;
        {
            let guard = sessions.lock().map_err(|_| "session lock".to_string())?;
            if !guard.has_capacity() {
                return Err("too many sessions".to_string());
            }
        }
        let token = generate_token()?;
        let (master, slave, ns_fds) = allocate_pty(req, init_pid)?;
        let spec = build_spec(req, master, slave, ns_fds)?;
        // Hold the spawn lock across fork+register so the reaper cannot reap the
        // session leader before finish_open records it.
        let _spawn = crate::wait::spawn_lock();
        let spawn = match sys::spawn_session(&spec) {
            Ok(spawn) => spawn,
            Err(e) => {
                cleanup_parent(&spec);
                sys::close_fd(master);
                return Err(format!("session spawn: {e}"));
            }
        };
        cleanup_parent(&spec);
        finish_open(sessions, &token, &spawn, master, req)
    }

    fn finish_open(
        sessions: &Mutex<Sessions>,
        token: &str,
        spawn: &SessionSpawn,
        master: RawFd,
        req: &SessionOpenReq,
    ) -> Result<SessionOpenData, String> {
        assert!(
            spawn.leader > 0 && spawn.target > 0,
            "session pids must be valid"
        );
        let entry = SessionEntry {
            token: token.to_string(),
            consumed: false,
            attached: false,
            pid: spawn.target,
            leader_pid: spawn.leader,
            master_fd: master,
            rows: req.rows,
            cols: req.cols,
            done: false,
            exit_code: None,
        };
        let id = {
            let mut guard = sessions.lock().map_err(|_| "session lock".to_string())?;
            guard.insert(entry).inspect_err(|_| {
                let _ = sys::send_signal(spawn.leader, libc::SIGKILL);
                let _ = sys::send_signal(spawn.target, libc::SIGKILL);
                sys::close_fd(master);
            })?
        };
        Ok(SessionOpenData {
            session_id: id,
            token: token.to_string(),
        })
    }

    fn allocate_pty(
        req: &SessionOpenReq,
        init_pid: Option<i32>,
    ) -> Result<(RawFd, SlaveSource, Vec<RawFd>), String> {
        if req.distro {
            let pid = init_pid.ok_or("distro not running")?;
            let ns_fds = sys::open_ns_fds(pid).map_err(|e| format!("open ns: {e}"))?;
            let (master, slave_path) = sys::open_distro_pty(pid, req.rows, req.cols)
                .inspect_err(|_| sys::close_all(&ns_fds))
                .map_err(|e| format!("open distro pty: {e}"))?;
            Ok((master, SlaveSource::Path(slave_path), ns_fds))
        } else {
            let (master, slave) =
                sys::open_pty(req.rows, req.cols).map_err(|e| format!("open pty: {e}"))?;
            Ok((master, SlaveSource::Fd(slave), Vec::new()))
        }
    }

    fn build_spec(
        req: &SessionOpenReq,
        master: RawFd,
        slave: SlaveSource,
        ns_fds: Vec<RawFd>,
    ) -> Result<SessionSpec, String> {
        let argv = cstrings(&req.argv)?;
        let envp = env_cstrings(&req.env)?;
        let cwd = match &req.cwd {
            Some(path) => Some(CString::new(path.as_str()).map_err(|_| "nul in cwd".to_string())?),
            None => None,
        };
        assert!(!argv.is_empty(), "argv must survive cstring conversion");
        Ok(SessionSpec {
            ns_fds,
            master_fd: master,
            slave,
            cwd,
            argv,
            envp,
        })
    }

    fn cleanup_parent(spec: &SessionSpec) {
        sys::close_all(&spec.ns_fds);
        if let SlaveSource::Fd(fd) = &spec.slave {
            sys::close_fd(*fd);
        }
    }

    fn cstrings(items: &[String]) -> Result<Vec<CString>, String> {
        let mut out: Vec<CString> = Vec::with_capacity(items.len());
        // bounded: argv length is host-supplied and frame-bounded
        for item in items {
            out.push(CString::new(item.as_str()).map_err(|_| "nul in argv".to_string())?);
        }
        Ok(out)
    }

    fn env_cstrings(env: &HashMap<String, String>) -> Result<Vec<CString>, String> {
        let mut out: Vec<CString> = Vec::with_capacity(env.len());
        // bounded: env map is host-supplied and frame-bounded
        for (key, value) in env {
            let pair = format!("{key}={value}");
            out.push(CString::new(pair).map_err(|_| "nul in env".to_string())?);
        }
        Ok(out)
    }

    pub fn pump(sessions: &Mutex<Sessions>, id: u64, master_fd: RawFd, data: VsockStream) {
        assert!(master_fd >= 0, "pump needs a valid master fd");
        let data_fd = data.as_raw_fd();
        let _ = sys::set_nonblocking(master_fd);
        let _ = sys::set_nonblocking(data_fd);
        let mut m2d: Vec<u8> = Vec::new();
        let mut d2m: Vec<u8> = Vec::new();
        let mut m_eof = false;
        let mut d_eof = false;
        // sanctioned infinite session pump loop: exits on child exit or host detach
        loop {
            if d_eof || (m_eof && m2d.is_empty()) {
                break;
            }
            let mut t = [
                PollTarget::read_write(master_fd, !m_eof && m2d.len() < CAP, !d2m.is_empty()),
                PollTarget::read_write(data_fd, !d_eof && d2m.len() < CAP, !m2d.is_empty()),
            ];
            if sys::poll_fds(&mut t, POLL_MS).is_err() {
                break;
            }
            drain_side(master_fd, &mut m2d, &t[0], &mut m_eof);
            drain_side(data_fd, &mut d2m, &t[1], &mut d_eof);
            if t[0].writable && flush(master_fd, &mut d2m).is_err() {
                m_eof = true;
            }
            if t[1].writable && flush(data_fd, &mut m2d).is_err() {
                d_eof = true;
            }
        }
        finish_pump(sessions, id, d_eof && !m_eof);
        drop(data);
    }

    fn drain_side(fd: RawFd, buf: &mut Vec<u8>, target: &PollTarget, eof: &mut bool) {
        if !target.ready && !target.hup {
            return;
        }
        let mut tmp = [0u8; CHUNK];
        // bounded: at most MAX_DRAIN chunks per poll cycle
        for _ in 0..MAX_DRAIN {
            if buf.len() >= CAP {
                break;
            }
            let room = (CAP - buf.len()).min(CHUNK);
            match sys::read_fd(fd, &mut tmp[..room]) {
                Ok(0) => {
                    *eof = true;
                    break;
                }
                Ok(n) => buf.extend_from_slice(&tmp[..n]),
                Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                    if target.hup {
                        *eof = true;
                    }
                    break;
                }
                Err(_) => {
                    *eof = true;
                    break;
                }
            }
        }
    }

    fn flush(fd: RawFd, buf: &mut Vec<u8>) -> io::Result<()> {
        if buf.is_empty() {
            return Ok(());
        }
        match sys::write_fd(fd, buf) {
            Ok(0) => Ok(()),
            Ok(n) => {
                debug_assert!(n <= buf.len());
                let _ = buf.drain(..n);
                Ok(())
            }
            Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => Ok(()),
            Err(e) => Err(e),
        }
    }

    fn finish_pump(sessions: &Mutex<Sessions>, id: u64, hangup: bool) {
        if hangup {
            let pid = sessions.lock().ok().and_then(|g| g.pid_of(id).ok());
            if let Some(pid) = pid {
                let _ = sys::send_signal(pid, libc::SIGHUP);
            }
        }
        if let Ok(mut guard) = sessions.lock() {
            guard.detach(id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{MAX_SESSIONS, SessionEntry, Sessions, generate_token, validate_open};

    fn dummy(token: &str) -> SessionEntry {
        SessionEntry {
            token: token.to_string(),
            consumed: false,
            attached: false,
            pid: 4242,
            leader_pid: 5555,
            master_fd: -1,
            rows: 24,
            cols: 80,
            done: false,
            exit_code: None,
        }
    }

    #[test]
    fn table_refuses_past_capacity() {
        let mut sessions = Sessions::new();
        for _ in 0..MAX_SESSIONS {
            sessions.insert(dummy("t")).expect("under capacity");
        }
        let err = sessions.insert(dummy("t")).expect_err("65th refused");
        assert!(err.contains("too many"));
    }

    #[test]
    fn authorize_rejects_bad_and_reused_token() {
        let mut sessions = Sessions::new();
        let id = sessions.insert(dummy("secret")).expect("insert");
        assert!(sessions.authorize(id, "wrong").is_err());
        assert!(sessions.authorize(id, "secret").is_ok());
        assert!(sessions.authorize(id, "secret").is_err(), "single use");
    }

    #[test]
    fn wait_reports_and_reaps_done() {
        let mut sessions = Sessions::new();
        let id = sessions.insert(dummy("t")).expect("insert");
        assert_eq!(sessions.wait(id).expect("wait"), (false, None));
        assert!(
            !sessions.record_exit(4242, 7),
            "target pid must not match reap"
        );
        assert!(sessions.record_exit(5555, 7), "leader pid is the reap key");
        assert_eq!(sessions.wait(id).expect("wait"), (true, Some(7)));
        assert!(sessions.wait(id).is_err(), "entry dropped after done");
    }

    #[test]
    fn pid_of_returns_signal_target_not_leader() {
        let mut sessions = Sessions::new();
        let id = sessions.insert(dummy("t")).expect("insert");
        assert_eq!(sessions.pid_of(id).expect("pid"), 4242);
    }

    #[test]
    fn generate_token_is_32_hex() {
        let token = generate_token().expect("urandom");
        assert_eq!(token.len(), 32);
        assert!(token.bytes().all(|b| b.is_ascii_hexdigit()));
    }

    #[test]
    fn validate_open_checks_argv_and_size() {
        assert!(validate_open(&[], 24, 80).is_err());
        assert!(validate_open(&["sh".to_string()], 24, 80).is_err());
        assert!(validate_open(&["/bin/sh".to_string()], 0, 80).is_err());
        assert!(validate_open(&["/bin/sh".to_string()], 24, 80).is_ok());
    }
}
