//! GUI runtime helpers. Every operation runs inside the target distro's
//! namespaces as the runtime's target user, keyed by `(distro, linux user)`.

use std::collections::HashMap;
use std::fs::{self, DirBuilder, Permissions};
use std::io;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt, chown};

use serde::Serialize;

use crate::exec::{self, ExecOpts};
use crate::proto::ExecData;
use crate::sys::Ident;

pub const WAYLAND_DISPLAY: &str = "msl-way-0";
pub const DEFAULT_USER: &str = "root";
pub const MAX_RUNTIMES: usize = 8;
pub const MAX_WINDOWS: u32 = 64;

const WAY_BIN: &str = "/run/msl/tools/msl-way";
const WAY_PATTERN: &str = "/run/msl/tools/msl-way.*--wayland-socket msl-way-0";
const RUNTIME_SUBDIR: &str = "msl-gui";
const LOG_NAME: &str = "msl-way.log";
const SAFE_PATH: &str = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
const NAME_MAX_LEN: usize = 32;
const MAX_ETC_LINES: usize = 8_192;
const RUNTIME_TIMEOUT_MS: u64 = 5_000;
const START_TIMEOUT_MS: u64 = 8_000;
const LAUNCH_TIMEOUT_MS: u64 = 2_000;

#[derive(Debug, Serialize)]
pub struct GuiRuntimeData {
    pub state: String,
    pub user: String,
    pub runtime_dir: String,
    pub wayland_display: &'static str,
    pub socket_present: bool,
    pub pid: Option<u32>,
    pub windows: u32,
    pub log_tail: String,
    // The X11 DISPLAY the compositor announced once XWayland readied, parsed from
    // its log; absent until then, and absent entirely when XWayland is disabled.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x11_display: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct GuiProbeData {
    pub runtime: GuiRuntimeData,
    pub capabilities: Vec<GuiCapabilityData>,
}

#[derive(Debug, Serialize)]
pub struct GuiCapabilityData {
    pub name: &'static str,
    pub present: bool,
}

// ---------------------------------------------------------------------------
// Runtime table
// ---------------------------------------------------------------------------

#[derive(Debug)]
struct Runtime {
    distro: String,
    user: String,
    owns_xdg: bool,
    windows: u32,
}

// Live GUI runtimes, capped at MAX_RUNTIMES entries each holding at most
// MAX_WINDOWS windows. `owns_xdg` records that msl created `/run/user/<uid>`
// and therefore must remove it on stop.
#[derive(Debug, Default)]
pub struct Runtimes {
    entries: Vec<Runtime>,
}

impl Runtimes {
    #[must_use]
    pub const fn new() -> Self {
        Self {
            entries: Vec::new(),
        }
    }

    // Reserve the (distro, user) slot, reporting whether it was newly created.
    pub fn insert(&mut self, distro: &str, user: &str) -> Result<bool, String> {
        assert!(!distro.is_empty(), "runtime key needs a distro");
        assert!(!user.is_empty(), "runtime key needs a user");
        if self.find(distro, user).is_some() {
            return Ok(false);
        }
        if self.entries.len() >= MAX_RUNTIMES {
            return Err(format!("gui runtime table is full ({MAX_RUNTIMES})"));
        }
        self.entries.push(Runtime {
            distro: distro.to_string(),
            user: user.to_string(),
            owns_xdg: false,
            windows: 0,
        });
        Ok(true)
    }

    pub fn mark_owns_xdg(&mut self, distro: &str, user: &str, owns: bool) {
        assert!(!distro.is_empty(), "runtime key needs a distro");
        if let Some(entry) = self.find_mut(distro, user) {
            entry.owns_xdg = owns;
        }
    }

    #[must_use]
    pub fn owns_xdg(&self, distro: &str, user: &str) -> bool {
        assert!(!user.is_empty(), "runtime key needs a user");
        self.find(distro, user).is_some_and(|entry| entry.owns_xdg)
    }

    // Charge one window against the runtime's budget, creating the slot when a
    // launch precedes an explicit start.
    pub fn add_window(&mut self, distro: &str, user: &str) -> Result<u32, String> {
        let _ = self.insert(distro, user)?;
        let entry = self
            .find_mut(distro, user)
            .ok_or_else(|| "gui runtime slot vanished".to_string())?;
        if entry.windows >= MAX_WINDOWS {
            return Err(format!(
                "gui runtime window budget exhausted ({MAX_WINDOWS})"
            ));
        }
        entry.windows = entry.windows.saturating_add(1);
        Ok(entry.windows)
    }

    pub fn release_window(&mut self, distro: &str, user: &str) {
        assert!(!distro.is_empty(), "runtime key needs a distro");
        if let Some(entry) = self.find_mut(distro, user) {
            entry.windows = entry.windows.saturating_sub(1);
        }
    }

    #[must_use]
    pub fn windows(&self, distro: &str, user: &str) -> u32 {
        assert!(!user.is_empty(), "runtime key needs a user");
        self.find(distro, user).map_or(0, |entry| entry.windows)
    }

    pub fn remove(&mut self, distro: &str, user: &str) {
        assert!(!distro.is_empty(), "runtime key needs a distro");
        assert!(!user.is_empty(), "runtime key needs a user");
        self.entries
            .retain(|entry| entry.distro != distro || entry.user != user);
    }

    fn find(&self, distro: &str, user: &str) -> Option<&Runtime> {
        debug_assert!(self.entries.len() <= MAX_RUNTIMES);
        // bounded: at most MAX_RUNTIMES entries
        self.entries
            .iter()
            .find(|entry| entry.distro == distro && entry.user == user)
    }

    fn find_mut(&mut self, distro: &str, user: &str) -> Option<&mut Runtime> {
        debug_assert!(self.entries.len() <= MAX_RUNTIMES);
        // bounded: at most MAX_RUNTIMES entries
        self.entries
            .iter_mut()
            .find(|entry| entry.distro == distro && entry.user == user)
    }
}

// ---------------------------------------------------------------------------
// Runtime identity
// ---------------------------------------------------------------------------

// A resolved `(distro, user)` runtime: the distro init pid to join, the
// credentials to drop to, and the two runtime directories, all guest-absolute.
pub struct Context {
    user: String,
    init_pid: i32,
    ident: Ident,
    xdg: String,
    root: String,
}

impl Context {
    pub fn resolve(distro: &str, user: Option<&str>, init_pid: i32) -> Result<Self, String> {
        assert!(init_pid > 0, "gui context needs a running distro init pid");
        crate::distro::validate_name(distro)?;
        validate_runtime_name(WAYLAND_DISPLAY)?;
        let user = user.unwrap_or(DEFAULT_USER);
        validate_user(user)?;
        let ident = resolve_ident(init_pid, user)?;
        assert!(
            ident.groups.len() <= Ident::MAX_GROUPS,
            "resolved groups must stay bounded"
        );
        let xdg = format!("/run/user/{}", ident.uid);
        let root = format!("{xdg}/{RUNTIME_SUBDIR}");
        Ok(Self {
            user: user.to_string(),
            init_pid,
            ident,
            xdg,
            root,
        })
    }

    #[must_use]
    pub fn user(&self) -> &str {
        &self.user
    }

    // The agent's view of a guest-absolute path: the distro's mount namespace
    // is reachable through its init's procfs root link.
    fn agent_path(&self, guest: &str) -> String {
        debug_assert!(self.init_pid > 0);
        debug_assert!(guest.starts_with('/'));
        format!("/proc/{}/root{guest}", self.init_pid)
    }

    // Create `/run/user/<uid>` and its msl-gui root owner-only, reporting
    // whether this call created `/run/user/<uid>`.
    fn prepare_dirs(&self) -> Result<bool, String> {
        assert!(self.init_pid > 0, "prepare needs a distro init pid");
        assert!(self.xdg.starts_with('/'), "runtime root must be absolute");
        ensure_root_dir(&self.agent_path("/run"))?;
        ensure_root_dir(&self.agent_path("/run/user"))?;
        let created = ensure_user_dir(&self.agent_path(&self.xdg), &self.ident)?;
        let _ = ensure_user_dir(&self.agent_path(&self.root), &self.ident)?;
        Ok(created)
    }

    // Side-effect-free counterpart of `prepare_dirs`: an absent runtime dir is
    // fine, a present one must already be private to the target user.
    fn inspect_dirs(&self) -> Result<(), String> {
        assert!(self.xdg.starts_with('/'), "runtime root must be absolute");
        let path = self.agent_path(&self.xdg);
        match fs::symlink_metadata(&path) {
            Ok(_) => check_dir(&path, self.ident.uid),
            Err(ref e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(format!("stat {}: {e}", self.xdg)),
        }
    }

    // Leave nothing stranded: the wayland socket, the compositor log, the
    // msl-gui root, and `/run/user/<uid>` when msl created it.
    fn cleanup_dirs(&self, remove_xdg: bool) {
        assert!(self.init_pid > 0, "cleanup needs a distro init pid");
        assert!(self.root.starts_with('/'), "runtime root must be absolute");
        remove_file_quietly(&self.agent_path(&format!("{}/{WAYLAND_DISPLAY}", self.xdg)));
        remove_file_quietly(&self.agent_path(&format!("{}/{LOG_NAME}", self.root)));
        remove_dir_quietly(&self.agent_path(&self.root));
        if remove_xdg {
            remove_dir_quietly(&self.agent_path(&self.xdg));
        }
    }

    fn run_script(&self, script: &str, timeout_ms: u64) -> Result<ExecData, String> {
        assert!(!script.is_empty(), "gui script must be non-empty");
        assert!(timeout_ms > 0, "gui script needs a timeout");
        let argv = vec!["/bin/sh".to_string(), "-lc".to_string(), script.to_string()];
        let env = HashMap::from([
            ("XDG_RUNTIME_DIR".to_string(), self.xdg.clone()),
            ("PATH".to_string(), SAFE_PATH.to_string()),
        ]);
        self.run_exec(&argv, timeout_ms, &env, Some("/"))
    }

    fn run_exec(
        &self,
        argv: &[String],
        timeout_ms: u64,
        env: &HashMap<String, String>,
        cwd: Option<&str>,
    ) -> Result<ExecData, String> {
        assert!(self.init_pid > 0, "gui exec needs a distro init pid");
        assert!(!argv.is_empty(), "gui exec argv must be non-empty");
        let opts = ExecOpts {
            distro: true,
            cwd,
            init_pid: Some(self.init_pid),
            ident: Some(&self.ident),
        };
        exec::run(argv, env, timeout_ms, &opts)
    }
}

pub fn validate_user(user: &str) -> Result<(), String> {
    let bytes = user.as_bytes();
    let head_ok = bytes
        .first()
        .is_some_and(|b| b.is_ascii_lowercase() || *b == b'_');
    let body_ok = bytes
        .iter()
        .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(*b, b'_' | b'-' | b'.'));
    if head_ok && body_ok && bytes.len() <= NAME_MAX_LEN {
        Ok(())
    } else {
        Err("gui user must match ^[a-z_][a-z0-9_.-]{0,31}$".to_string())
    }
}

// A runtime (socket) name is a single path component: no separators, no NUL,
// no dot entries, bounded length.
pub fn validate_runtime_name(name: &str) -> Result<(), String> {
    let bytes = name.as_bytes();
    let ok = !bytes.is_empty()
        && bytes.len() <= NAME_MAX_LEN
        && !matches!(name, "." | "..")
        && bytes
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || matches!(*b, b'_' | b'-' | b'.'));
    if ok {
        Ok(())
    } else {
        Err("gui runtime name must be a bounded path component".to_string())
    }
}

fn resolve_ident(init_pid: i32, user: &str) -> Result<Ident, String> {
    assert!(init_pid > 0, "identity lookup needs a distro init pid");
    assert!(!user.is_empty(), "identity lookup needs a user name");
    let passwd = read_guest(init_pid, "/etc/passwd")?;
    let (uid, gid) = passwd_entry(&passwd, user)
        .ok_or_else(|| format!("gui user '{user}' is not in the distro passwd file"))?;
    let group = read_guest(init_pid, "/etc/group").unwrap_or_default();
    let groups = supplementary_groups(&group, user, gid);
    Ident::new(uid, gid, groups).map_err(|e| format!("gui identity: {e}"))
}

fn read_guest(init_pid: i32, guest: &str) -> Result<String, String> {
    debug_assert!(init_pid > 0);
    debug_assert!(guest.starts_with('/'));
    let path = format!("/proc/{init_pid}/root{guest}");
    fs::read_to_string(&path).map_err(|e| format!("read {guest} in distro: {e}"))
}

pub fn passwd_entry(text: &str, user: &str) -> Option<(u32, u32)> {
    debug_assert!(!user.is_empty());
    // bounded: at most MAX_ETC_LINES lines are consulted
    for line in text.lines().take(MAX_ETC_LINES) {
        let mut cols = line.split(':');
        let Some(name) = cols.next() else { continue };
        if name != user {
            continue;
        }
        let _password = cols.next();
        let uid = cols.next().and_then(|v| v.parse::<u32>().ok());
        let gid = cols.next().and_then(|v| v.parse::<u32>().ok());
        if let (Some(uid), Some(gid)) = (uid, gid) {
            return Some((uid, gid));
        }
    }
    None
}

// initgroups(3) semantics: the primary gid first, then every group listing the
// user as a member, capped at Ident::MAX_GROUPS.
pub fn supplementary_groups(text: &str, user: &str, primary: u32) -> Vec<u32> {
    debug_assert!(!user.is_empty());
    let mut groups = vec![primary];
    // bounded: at most MAX_ETC_LINES lines, and never past MAX_GROUPS entries
    for line in text.lines().take(MAX_ETC_LINES) {
        if groups.len() >= Ident::MAX_GROUPS {
            break;
        }
        let mut cols = line.split(':');
        let _name = cols.next();
        let _password = cols.next();
        let Some(gid) = cols.next().and_then(|v| v.parse::<u32>().ok()) else {
            continue;
        };
        let Some(members) = cols.next() else { continue };
        if !groups.contains(&gid) && members.split(',').any(|member| member == user) {
            groups.push(gid);
        }
    }
    debug_assert!(groups.len() <= Ident::MAX_GROUPS);
    groups
}

// ---------------------------------------------------------------------------
// Runtime directories
// ---------------------------------------------------------------------------

// Fail closed: a real directory (never a symlink), owned by `uid`, with no
// group or other write bit.
fn check_dir(agent_path: &str, uid: u32) -> Result<(), String> {
    assert!(agent_path.starts_with('/'), "runtime path must be absolute");
    let meta = fs::symlink_metadata(agent_path).map_err(|e| format!("stat {agent_path}: {e}"))?;
    if !meta.is_dir() {
        return Err(format!("{agent_path} is not a directory"));
    }
    if meta.uid() != uid {
        return Err(format!(
            "{agent_path} is owned by uid {}, not {uid}",
            meta.uid()
        ));
    }
    if meta.mode() & 0o022 != 0 {
        return Err(format!("{agent_path} is group- or world-writable"));
    }
    Ok(())
}

fn ensure_root_dir(agent_path: &str) -> Result<(), String> {
    assert!(agent_path.starts_with('/'), "runtime path must be absolute");
    match DirBuilder::new().mode(0o755).create(agent_path) {
        Ok(()) => Ok(()),
        Err(ref e) if e.kind() == io::ErrorKind::AlreadyExists => check_dir(agent_path, 0),
        Err(e) => Err(format!("create {agent_path}: {e}")),
    }
}

// True when this call created the directory. A pre-existing path is adopted
// only if it passes `check_dir`, so a planted symlink aborts the runtime.
fn ensure_user_dir(agent_path: &str, ident: &Ident) -> Result<bool, String> {
    assert!(agent_path.starts_with('/'), "runtime path must be absolute");
    assert!(
        ident.groups.len() <= Ident::MAX_GROUPS,
        "identity groups must stay bounded"
    );
    match DirBuilder::new().mode(0o700).create(agent_path) {
        Ok(()) => {
            chown(agent_path, Some(ident.uid), Some(ident.gid))
                .map_err(|e| format!("chown {agent_path}: {e}"))?;
            fs::set_permissions(agent_path, Permissions::from_mode(0o700))
                .map_err(|e| format!("chmod {agent_path}: {e}"))?;
            Ok(true)
        }
        Err(ref e) if e.kind() == io::ErrorKind::AlreadyExists => {
            check_dir(agent_path, ident.uid)?;
            Ok(false)
        }
        Err(e) => Err(format!("create {agent_path}: {e}")),
    }
}

fn remove_file_quietly(agent_path: &str) {
    debug_assert!(agent_path.starts_with('/'));
    match fs::remove_file(agent_path) {
        Ok(()) => {}
        Err(ref e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => crate::log::warn(&format!("gui cleanup: remove {agent_path}: {e}")),
    }
}

fn remove_dir_quietly(agent_path: &str) {
    debug_assert!(agent_path.starts_with('/'));
    match fs::remove_dir(agent_path) {
        Ok(()) => {}
        Err(ref e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => crate::log::warn(&format!("gui cleanup: rmdir {agent_path}: {e}")),
    }
}

pub fn probe(ctx: &Context) -> Result<GuiProbeData, String> {
    ctx.inspect_dirs()?;
    let data = ctx.run_script(&probe_script(ctx), RUNTIME_TIMEOUT_MS)?;
    if data.exit_code != 0 {
        return Err(format!("gui_probe failed: {}", data.stderr));
    }
    let fields = parse_fields(&data.stdout);
    Ok(GuiProbeData {
        runtime: runtime_from_fields(ctx, &fields, 0),
        capabilities: vec![
            capability("msl-way", &fields, "msl_way"),
            capability("xkb-data", &fields, "xkb_data"),
            capability("xwayland", &fields, "xwayland"),
            capability("gtk4-widget-factory", &fields, "gtk4_widget_factory"),
            capability("gimp", &fields, "gimp"),
        ],
    })
}

pub fn status(ctx: &Context, windows: u32) -> Result<GuiRuntimeData, String> {
    assert!(windows <= MAX_WINDOWS, "window count must stay bounded");
    ctx.inspect_dirs()?;
    let data = ctx.run_script(&status_script(ctx), RUNTIME_TIMEOUT_MS)?;
    if data.exit_code != 0 {
        return Err(format!("gui_status failed: {}", data.stderr));
    }
    Ok(runtime_from_fields(
        ctx,
        &parse_fields(&data.stdout),
        windows,
    ))
}

// Returns the runtime state and whether this call created `/run/user/<uid>`;
// a failed start unwinds its own directory rather than stranding it.
pub fn start(ctx: &Context, windows: u32) -> Result<(GuiRuntimeData, bool), String> {
    assert!(windows <= MAX_WINDOWS, "window count must stay bounded");
    let created = ctx.prepare_dirs()?;
    let outcome = ctx.run_script(&start_script(ctx), START_TIMEOUT_MS);
    let data = match outcome {
        Ok(data) if data.exit_code == 0 => data,
        Ok(data) => {
            let stderr = data.stderr;
            unwind_start(ctx, created);
            return Err(format!("gui_start failed: {stderr}"));
        }
        Err(message) => {
            unwind_start(ctx, created);
            return Err(message);
        }
    };
    Ok((
        runtime_from_fields(ctx, &parse_fields(&data.stdout), windows),
        created,
    ))
}

pub fn stop(ctx: &Context, owns_xdg: bool) -> Result<GuiRuntimeData, String> {
    assert!(ctx.init_pid > 0, "gui_stop needs a distro init pid");
    let data = ctx.run_script(&stop_script(ctx), RUNTIME_TIMEOUT_MS)?;
    if data.exit_code != 0 {
        return Err(format!("gui_stop failed: {}", data.stderr));
    }
    ctx.cleanup_dirs(owns_xdg);
    let mut runtime = runtime_from_fields(ctx, &parse_fields(&data.stdout), 0);
    runtime.socket_present = false;
    Ok(runtime)
}

pub fn launch(
    ctx: &Context,
    argv: &[String],
    env: &HashMap<String, String>,
    cwd: Option<&str>,
) -> Result<ExecData, String> {
    validate_argv(argv)?;
    ctx.inspect_dirs()?;
    let mut scoped = gui_env(&ctx.xdg);
    // bounded: the caller's env map is frame-bounded
    for (key, value) in env {
        let _ = scoped.insert(key.clone(), value.clone());
    }
    ctx.run_exec(argv, LAUNCH_TIMEOUT_MS, &scoped, cwd.or(Some("/")))
}

fn unwind_start(ctx: &Context, created: bool) {
    if created {
        ctx.cleanup_dirs(true);
    }
}

#[must_use]
pub fn gui_env(runtime_dir: &str) -> HashMap<String, String> {
    assert!(
        runtime_dir.starts_with('/'),
        "XDG_RUNTIME_DIR must be absolute"
    );
    assert!(!runtime_dir.contains('\0'), "XDG_RUNTIME_DIR must be clean");
    HashMap::from([
        ("WAYLAND_DISPLAY".to_string(), WAYLAND_DISPLAY.to_string()),
        ("XDG_RUNTIME_DIR".to_string(), runtime_dir.to_string()),
        ("GDK_BACKEND".to_string(), "wayland,x11".to_string()),
        ("QT_QPA_PLATFORM".to_string(), "wayland;xcb".to_string()),
        ("SDL_VIDEODRIVER".to_string(), "wayland,x11".to_string()),
        ("CLUTTER_BACKEND".to_string(), "wayland".to_string()),
        ("LIBGL_ALWAYS_SOFTWARE".to_string(), "1".to_string()),
        (
            "MESA_LOADER_DRIVER_OVERRIDE".to_string(),
            "llvmpipe".to_string(),
        ),
    ])
}

fn validate_argv(argv: &[String]) -> Result<(), String> {
    if argv.is_empty() {
        return Err("gui_launch argv must be non-empty".to_string());
    }
    if !argv[0].starts_with('/') {
        return Err("gui_launch argv[0] must be absolute".to_string());
    }
    Ok(())
}

fn runtime_from_fields(
    ctx: &Context,
    fields: &HashMap<String, String>,
    windows: u32,
) -> GuiRuntimeData {
    debug_assert!(windows <= MAX_WINDOWS);
    GuiRuntimeData {
        state: fields
            .get("state")
            .cloned()
            .unwrap_or_else(|| "unknown".to_string()),
        user: ctx.user.clone(),
        runtime_dir: ctx.xdg.clone(),
        wayland_display: WAYLAND_DISPLAY,
        socket_present: bool_field(fields, "socket"),
        pid: fields.get("pid").and_then(|pid| pid.parse::<u32>().ok()),
        windows,
        log_tail: fields.get("log_tail").cloned().unwrap_or_default(),
        x11_display: fields
            .get("x11_display_line")
            .and_then(|line| parse_x11_display(line)),
    }
}

const MAX_DISPLAY_DIGITS: usize = 10;

// Extract the `:N` display token from a compositor `DISPLAY=:N` log line; the
// guest log is untrusted, so only a colon followed by ASCII digits is accepted.
#[must_use]
pub fn parse_x11_display(line: &str) -> Option<String> {
    let marker = line.find("DISPLAY=:")?;
    let rest = &line[marker + "DISPLAY=".len()..];
    let bytes = rest.as_bytes();
    debug_assert_eq!(
        bytes.first(),
        Some(&b':'),
        "display token must start with colon"
    );
    let mut end = 1;
    // bounded: display numbers are small; a runaway digit run is rejected
    for _ in 0..MAX_DISPLAY_DIGITS {
        match bytes.get(end) {
            Some(b) if b.is_ascii_digit() => end += 1,
            _ => break,
        }
    }
    if end == 1 {
        return None;
    }
    debug_assert!(end <= rest.len(), "display token within the source line");
    Some(rest[..end].to_string())
}

pub fn parse_fields(text: &str) -> HashMap<String, String> {
    let mut fields = HashMap::new();
    // bounded: the capture buffer caps stdout at 1 MiB
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        if !key.is_empty() {
            let _ = fields.insert(key.to_string(), value.to_string());
        }
    }
    fields
}

fn bool_field(fields: &HashMap<String, String>, key: &str) -> bool {
    debug_assert!(!key.is_empty());
    matches!(
        fields.get(key).map(String::as_str),
        Some("present" | "running" | "true")
    )
}

fn capability(
    name: &'static str,
    fields: &HashMap<String, String>,
    key: &str,
) -> GuiCapabilityData {
    debug_assert!(!name.is_empty());
    debug_assert!(!key.is_empty());
    GuiCapabilityData {
        name,
        present: bool_field(fields, key),
    }
}

// Every value interpolated into a script is a validated name or a uid-derived
// path, so single quoting is sufficient.
fn status_script(ctx: &Context) -> String {
    let uid = ctx.ident.uid;
    let xdg = &ctx.xdg;
    let root = &ctx.root;
    format!(
        r#"
pattern='{WAY_PATTERN}'
if pgrep -u {uid} -f "$pattern" >/dev/null 2>&1; then
  echo "state=running"
  pgrep -u {uid} -f "$pattern" | head -n 1 | sed 's/^/pid=/'
else
  echo "state=stopped"
fi
printf 'runtime_dir=%s\n' '{xdg}'
[ -S '{xdg}/{WAYLAND_DISPLAY}' ] && echo "socket=present" || echo "socket=missing"
if [ -f '{root}/{LOG_NAME}' ]; then
  printf 'log_tail=%s\n' "$(tail -20 '{root}/{LOG_NAME}' | tr '\n' '|')"
  disp_line="$(grep 'DISPLAY=:' '{root}/{LOG_NAME}' | tail -n 1)"
  [ -n "$disp_line" ] && printf 'x11_display_line=%s\n' "$disp_line"
fi
"#
    )
}

fn probe_script(ctx: &Context) -> String {
    let head = status_script(ctx);
    format!(
        r#"{head}
[ -x {WAY_BIN} ] && echo "msl_way=present" || echo "msl_way=missing"
[ -d /usr/share/X11/xkb ] && echo "xkb_data=present" || echo "xkb_data=missing"
command -v Xwayland >/dev/null 2>&1 && echo "xwayland=present" || echo "xwayland=missing"
command -v gtk4-widget-factory >/dev/null 2>&1 && echo "gtk4_widget_factory=present" || echo "gtk4_widget_factory=missing"
command -v gimp >/dev/null 2>&1 && echo "gimp=present" || echo "gimp=missing"
"#
    )
}

fn start_script(ctx: &Context) -> String {
    let uid = ctx.ident.uid;
    let xdg = &ctx.xdg;
    let root = &ctx.root;
    format!(
        r#"
if [ ! -x {WAY_BIN} ]; then
  echo "missing={WAY_BIN}" >&2
  exit 44
fi
if [ ! -d /usr/share/X11/xkb ]; then
  echo "missing=xkb-data" >&2
  exit 45
fi
pattern='{WAY_PATTERN}'
printf 'runtime_dir=%s\n' '{xdg}'
if pgrep -u {uid} -f "$pattern" >/dev/null 2>&1; then
  echo "state=running"
  pgrep -u {uid} -f "$pattern" | head -n 1 | sed 's/^/pid=/'
  echo "socket=present"
  exit 0
fi
XDG_RUNTIME_DIR='{xdg}' nohup {WAY_BIN} --wayland-socket {WAYLAND_DISPLAY} \
  > '{root}/{LOG_NAME}' 2>&1 < /dev/null &
for i in $(seq 1 40); do
  if [ -S '{xdg}/{WAYLAND_DISPLAY}' ]; then
    echo "state=running"
    pgrep -u {uid} -f "$pattern" | head -n 1 | sed 's/^/pid=/'
    echo "socket=present"
    exit 0
  fi
  sleep 0.1
done
[ -f '{root}/{LOG_NAME}' ] && tail -40 '{root}/{LOG_NAME}' >&2
echo "state=failed"
echo "socket=missing"
exit 46
"#
    )
}

fn stop_script(ctx: &Context) -> String {
    let uid = ctx.ident.uid;
    let xdg = &ctx.xdg;
    format!(
        r#"
pattern='{WAY_PATTERN}'
if pgrep -u {uid} -f "$pattern" >/dev/null 2>&1; then
  pkill -u {uid} -f "$pattern" || true
  echo "state=stopping"
else
  echo "state=stopped"
fi
printf 'runtime_dir=%s\n' '{xdg}'
"#
    )
}

#[cfg(test)]
mod tests {
    use super::{
        Ident, MAX_RUNTIMES, MAX_WINDOWS, Runtimes, check_dir, ensure_user_dir, gui_env,
        parse_fields, parse_x11_display, passwd_entry, supplementary_groups, validate_argv,
        validate_runtime_name, validate_user,
    };
    use std::fmt::Write as _;
    use std::fs;
    use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};

    fn scratch(tag: &str) -> String {
        let base = std::env::temp_dir().join(format!("msl-gui-test-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&base);
        fs::create_dir_all(&base).expect("scratch dir");
        base.to_str().expect("utf8 scratch path").to_string()
    }

    // The credentials the test process actually holds, so `chown` to self is a
    // permitted no-op whether or not the suite runs as root.
    fn owner(path: &str) -> Ident {
        let meta = fs::metadata(path).expect("scratch metadata");
        Ident::new(meta.uid(), meta.gid(), Vec::new()).expect("identity")
    }

    #[test]
    fn parse_fields_ignores_non_assignments() {
        let fields = parse_fields("state=running\nnoise\nsocket=present\n");
        assert_eq!(fields.get("state").map(String::as_str), Some("running"));
        assert_eq!(fields.get("socket").map(String::as_str), Some("present"));
        assert_eq!(fields.len(), 2);
    }

    #[test]
    fn gui_env_carries_all_eight_session_variables() {
        let env = gui_env("/run/user/1000");
        let expected = [
            ("WAYLAND_DISPLAY", "msl-way-0"),
            ("XDG_RUNTIME_DIR", "/run/user/1000"),
            ("GDK_BACKEND", "wayland,x11"),
            ("QT_QPA_PLATFORM", "wayland;xcb"),
            ("SDL_VIDEODRIVER", "wayland,x11"),
            ("CLUTTER_BACKEND", "wayland"),
            ("LIBGL_ALWAYS_SOFTWARE", "1"),
            ("MESA_LOADER_DRIVER_OVERRIDE", "llvmpipe"),
        ];
        assert_eq!(env.len(), expected.len());
        for (key, value) in expected {
            assert_eq!(env.get(key).map(String::as_str), Some(value), "{key}");
        }
        assert!(!env.contains_key("DISPLAY"), "XWayland owns DISPLAY later");
    }

    #[test]
    fn parse_x11_display_extracts_colon_number() {
        assert_eq!(
            parse_x11_display("msl-way: DISPLAY=:0"),
            Some(":0".to_string())
        );
        assert_eq!(
            parse_x11_display("prefix DISPLAY=:12 trailing text"),
            Some(":12".to_string()),
            "stops at the first non-digit"
        );
        assert_eq!(parse_x11_display("msl-way: DISPLAY=:"), None, "no digits");
        assert_eq!(parse_x11_display("no display here"), None);
        assert_eq!(
            parse_x11_display("DISPLAY=:007hostname"),
            Some(":007".to_string())
        );
    }

    #[test]
    fn launch_argv_must_be_absolute() {
        assert!(validate_argv(&[]).is_err());
        assert!(validate_argv(&["gimp".to_string()]).is_err());
        assert!(validate_argv(&["/usr/bin/gimp".to_string()]).is_ok());
    }

    #[test]
    fn user_names_reject_separators_nul_and_overlong() {
        assert!(validate_user("root").is_ok());
        assert!(validate_user("dev-user.1").is_ok());
        assert!(validate_user("_svc").is_ok());
        assert!(validate_user("").is_err());
        assert!(validate_user("../root").is_err());
        assert!(validate_user("dev/user").is_err());
        assert!(validate_user("dev\0user").is_err());
        assert!(validate_user("Root").is_err());
        assert!(validate_user(&"u".repeat(33)).is_err());
    }

    #[test]
    fn runtime_names_reject_separators_nul_and_dot_entries() {
        assert!(validate_runtime_name("msl-way-0").is_ok());
        assert!(validate_runtime_name("").is_err());
        assert!(validate_runtime_name(".").is_err());
        assert!(validate_runtime_name("..").is_err());
        assert!(validate_runtime_name("a/b").is_err());
        assert!(validate_runtime_name("a\0b").is_err());
        assert!(validate_runtime_name(&"n".repeat(33)).is_err());
    }

    #[test]
    fn passwd_entry_reads_uid_and_gid() {
        let text = "root:x:0:0:root:/root:/bin/sh\ndev:x:1000:1001:Dev:/home/dev:/bin/bash\n";
        assert_eq!(passwd_entry(text, "root"), Some((0, 0)));
        assert_eq!(passwd_entry(text, "dev"), Some((1000, 1001)));
        assert_eq!(passwd_entry(text, "nobody"), None);
        assert_eq!(passwd_entry("garbage\n", "dev"), None);
    }

    #[test]
    fn supplementary_groups_lead_with_primary_and_stay_bounded() {
        let text = "sudo:x:27:dev,other\nvideo:x:44:dev\nnope:x:50:other\n";
        assert_eq!(supplementary_groups(text, "dev", 1001), vec![1001, 27, 44]);
        let mut wide = String::new();
        // bounded: fixed synthetic group table
        for gid in 0..64_u32 {
            writeln!(wide, "g{gid}:x:{}:dev", gid + 100).expect("string write");
        }
        assert_eq!(
            supplementary_groups(&wide, "dev", 9).len(),
            Ident::MAX_GROUPS
        );
    }

    #[test]
    fn runtime_dir_rejects_wrong_owner() {
        let dir = scratch("owner");
        let alien = Ident::new(u32::MAX - 1, 0, Vec::new()).expect("identity");
        let err = ensure_user_dir(&dir, &alien).expect_err("wrong owner rejected");
        assert!(err.contains("owned by uid"), "{err}");
    }

    #[test]
    fn runtime_dir_rejects_group_writable_mode() {
        let dir = scratch("mode");
        let uid = owner(&dir).uid;
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o770)).expect("chmod");
        let err = check_dir(&dir, uid).expect_err("group-writable rejected");
        assert!(err.contains("writable"), "{err}");
    }

    #[test]
    fn runtime_dir_rejects_symlink() {
        let base = scratch("symlink");
        let target = format!("{base}/real");
        let link = format!("{base}/link");
        fs::create_dir(&target).expect("target dir");
        symlink(&target, &link).expect("symlink");
        let err = ensure_user_dir(&link, &owner(&base)).expect_err("symlink rejected");
        assert!(err.contains("not a directory"), "{err}");
    }

    #[test]
    fn runtime_dir_is_created_owner_only() {
        let base = scratch("create");
        let ident = owner(&base);
        let dir = format!("{base}/run");
        assert!(ensure_user_dir(&dir, &ident).expect("created"));
        let mode = fs::metadata(&dir).expect("metadata").permissions().mode();
        assert_eq!(mode & 0o777, 0o700);
        assert!(!ensure_user_dir(&dir, &ident).expect("adopted"));
    }

    #[test]
    fn runtime_table_bounds_runtimes_and_windows() {
        let mut table = Runtimes::new();
        // bounded: exactly MAX_RUNTIMES slots
        for slot in 0..MAX_RUNTIMES {
            assert!(table.insert(&format!("d{slot}"), "root").expect("insert"));
        }
        assert!(!table.insert("d0", "root").expect("idempotent"));
        assert!(table.insert("overflow", "root").is_err());
        assert!(
            table.insert("d0", "dev").is_err(),
            "user is part of the key"
        );

        // bounded: exactly MAX_WINDOWS windows
        for _ in 0..MAX_WINDOWS {
            let _ = table.add_window("d0", "root").expect("window");
        }
        assert_eq!(table.windows("d0", "root"), MAX_WINDOWS);
        assert!(table.add_window("d0", "root").is_err());
        table.release_window("d0", "root");
        assert_eq!(table.windows("d0", "root"), MAX_WINDOWS - 1);

        assert!(!table.owns_xdg("d0", "root"));
        table.mark_owns_xdg("d0", "root", true);
        assert!(table.owns_xdg("d0", "root"));
        table.remove("d0", "root");
        assert_eq!(table.windows("d0", "root"), 0);
    }
}
