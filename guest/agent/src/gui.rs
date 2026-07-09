//! GUI runtime helpers executed inside a running distro namespace.

use std::collections::HashMap;

use serde::Serialize;

use crate::exec::{self, ExecOpts};
use crate::proto::ExecData;

pub const WAYLAND_DISPLAY: &str = "msl-way-0";
const RUNTIME_TIMEOUT_MS: u64 = 5_000;
const START_TIMEOUT_MS: u64 = 8_000;
const LAUNCH_TIMEOUT_MS: u64 = 2_000;

#[derive(Debug, Serialize)]
pub struct GuiRuntimeData {
    pub state: String,
    pub runtime_dir: String,
    pub wayland_display: &'static str,
    pub socket_present: bool,
    pub pid: Option<u32>,
    pub log_tail: String,
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

pub fn probe(init_pid: i32) -> Result<GuiProbeData, String> {
    let data = run_script(init_pid, PROBE_SCRIPT, RUNTIME_TIMEOUT_MS, &HashMap::new())?;
    if data.exit_code != 0 {
        return Err(format!("gui_probe failed: {}", data.stderr));
    }
    let fields = parse_fields(&data.stdout);
    Ok(GuiProbeData {
        runtime: runtime_from_fields(&fields),
        capabilities: vec![
            capability("msl-way", &fields, "msl_way"),
            capability("xkb-data", &fields, "xkb_data"),
            capability("gtk4-widget-factory", &fields, "gtk4_widget_factory"),
            capability("gimp", &fields, "gimp"),
        ],
    })
}

pub fn status(init_pid: i32) -> Result<GuiRuntimeData, String> {
    let script = status_script();
    let data = run_script(init_pid, &script, RUNTIME_TIMEOUT_MS, &HashMap::new())?;
    if data.exit_code != 0 {
        return Err(format!("gui_status failed: {}", data.stderr));
    }
    Ok(runtime_from_fields(&parse_fields(&data.stdout)))
}

pub fn start(init_pid: i32) -> Result<GuiRuntimeData, String> {
    let script = start_script();
    let data = run_script(init_pid, &script, START_TIMEOUT_MS, &HashMap::new())?;
    if data.exit_code != 0 {
        return Err(format!("gui_start failed: {}", data.stderr));
    }
    Ok(runtime_from_fields(&parse_fields(&data.stdout)))
}

pub fn stop(init_pid: i32) -> Result<GuiRuntimeData, String> {
    let script = stop_script();
    let data = run_script(init_pid, &script, RUNTIME_TIMEOUT_MS, &HashMap::new())?;
    if data.exit_code != 0 {
        return Err(format!("gui_stop failed: {}", data.stderr));
    }
    Ok(runtime_from_fields(&parse_fields(&data.stdout)))
}

pub fn launch(
    init_pid: i32,
    argv: &[String],
    env: &HashMap<String, String>,
    cwd: Option<&str>,
) -> Result<ExecData, String> {
    validate_argv(argv)?;
    let mut scoped = gui_env();
    for (key, value) in env {
        scoped.insert(key.clone(), value.clone());
    }
    run_exec(
        init_pid,
        argv,
        LAUNCH_TIMEOUT_MS,
        &scoped,
        cwd.or(Some("/")),
    )
}

pub fn gui_env() -> HashMap<String, String> {
    HashMap::from([
        ("WAYLAND_DISPLAY".to_string(), WAYLAND_DISPLAY.to_string()),
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

fn run_script(
    init_pid: i32,
    script: &str,
    timeout_ms: u64,
    env: &HashMap<String, String>,
) -> Result<ExecData, String> {
    let argv = vec!["/bin/sh".to_string(), "-lc".to_string(), script.to_string()];
    run_exec(init_pid, &argv, timeout_ms, env, Some("/"))
}

fn run_exec(
    init_pid: i32,
    argv: &[String],
    timeout_ms: u64,
    env: &HashMap<String, String>,
    cwd: Option<&str>,
) -> Result<ExecData, String> {
    assert!(init_pid > 0, "gui exec needs a running distro init pid");
    let opts = ExecOpts {
        distro: true,
        cwd,
        init_pid: Some(init_pid),
    };
    exec::run(argv, env, timeout_ms, &opts)
}

fn runtime_from_fields(fields: &HashMap<String, String>) -> GuiRuntimeData {
    GuiRuntimeData {
        state: fields
            .get("state")
            .cloned()
            .unwrap_or_else(|| "unknown".to_string()),
        runtime_dir: fields
            .get("runtime_dir")
            .cloned()
            .unwrap_or_else(|| "/tmp".to_string()),
        wayland_display: WAYLAND_DISPLAY,
        socket_present: bool_field(fields, "socket"),
        pid: fields.get("pid").and_then(|pid| pid.parse::<u32>().ok()),
        log_tail: fields.get("log_tail").cloned().unwrap_or_default(),
    }
}

pub fn parse_fields(text: &str) -> HashMap<String, String> {
    let mut fields = HashMap::new();
    for line in text.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        if !key.is_empty() {
            fields.insert(key.to_string(), value.to_string());
        }
    }
    fields
}

fn bool_field(fields: &HashMap<String, String>, key: &str) -> bool {
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
    GuiCapabilityData {
        name,
        present: bool_field(fields, key),
    }
}

const COMMON: &str = r#"
uid="$(id -u)"
runtime="${XDG_RUNTIME_DIR:-}"
if [ -z "$runtime" ]; then
  runtime="/tmp/msl-gui-$uid"
fi
if ! mkdir -p "$runtime" 2>/dev/null; then
  runtime="/tmp/msl-gui-$uid"
  mkdir -p "$runtime"
fi
chmod 700 "$runtime" 2>/dev/null || true
export XDG_RUNTIME_DIR="$runtime"
pattern='/run/msl/tools/msl-way.*--wayland-socket msl-way-0'
"#;

const PROBE_SCRIPT: &str = r#"
uid="$(id -u)"
runtime="${XDG_RUNTIME_DIR:-/run/user/$uid}"
printf 'runtime_dir=%s\n' "$runtime"
[ -x /run/msl/tools/msl-way ] && echo "msl_way=present" || echo "msl_way=missing"
[ -d /usr/share/X11/xkb ] && echo "xkb_data=present" || echo "xkb_data=missing"
command -v gtk4-widget-factory >/dev/null 2>&1 && echo "gtk4_widget_factory=present" || echo "gtk4_widget_factory=missing"
command -v gimp >/dev/null 2>&1 && echo "gimp=present" || echo "gimp=missing"
"#;

fn status_script() -> String {
    [
        COMMON,
        r#"
if pgrep -u "$uid" -f "$pattern" >/dev/null 2>&1; then
  echo "state=running"
  pgrep -u "$uid" -f "$pattern" | head -n 1 | sed 's/^/pid=/'
else
  echo "state=stopped"
fi
printf 'runtime_dir=%s\n' "$runtime"
printf 'wayland=%s\n' "msl-way-0"
[ -S "$runtime/msl-way-0" ] && echo "socket=present" || echo "socket=missing"
if [ -f "$runtime/msl-way.log" ]; then
  printf 'log_tail=%s\n' "$(tail -20 "$runtime/msl-way.log" | tr '\n' '|')"
fi
"#,
    ]
    .concat()
}

fn start_script() -> String {
    [
        COMMON,
        r#"
if [ ! -x /run/msl/tools/msl-way ]; then
  echo "missing=/run/msl/tools/msl-way" >&2
  exit 44
fi
if [ ! -d /usr/share/X11/xkb ]; then
  echo "missing=xkb-data" >&2
  exit 45
fi
if pgrep -u "$uid" -f "$pattern" >/dev/null 2>&1; then
  echo "state=running"
  pgrep -u "$uid" -f "$pattern" | head -n 1 | sed 's/^/pid=/'
  printf 'runtime_dir=%s\n' "$runtime"
  echo "socket=present"
  exit 0
fi
XDG_RUNTIME_DIR="$runtime" nohup /run/msl/tools/msl-way --wayland-socket msl-way-0 \
  > "$runtime/msl-way.log" 2>&1 < /dev/null &
for i in $(seq 1 40); do
  if [ -S "$runtime/msl-way-0" ]; then
    echo "state=running"
    pgrep -u "$uid" -f "$pattern" | head -n 1 | sed 's/^/pid=/'
    printf 'runtime_dir=%s\n' "$runtime"
    echo "socket=present"
    exit 0
  fi
  sleep 0.1
done
[ -f "$runtime/msl-way.log" ] && tail -40 "$runtime/msl-way.log" >&2
echo "state=failed"
printf 'runtime_dir=%s\n' "$runtime"
echo "socket=missing"
exit 46
"#,
    ]
    .concat()
}

fn stop_script() -> String {
    [
        COMMON,
        r#"
if pgrep -u "$uid" -f "$pattern" >/dev/null 2>&1; then
  pkill -u "$uid" -f "$pattern" || true
  echo "state=stopping"
else
  echo "state=stopped"
fi
printf 'runtime_dir=%s\n' "$runtime"
[ -S "$runtime/msl-way-0" ] && echo "socket=present" || echo "socket=missing"
"#,
    ]
    .concat()
}

#[cfg(test)]
mod tests {
    use super::{gui_env, parse_fields, validate_argv};

    #[test]
    fn parse_fields_ignores_non_assignments() {
        let fields = parse_fields("state=running\nnoise\nsocket=present\n");
        assert_eq!(fields.get("state").map(String::as_str), Some("running"));
        assert_eq!(fields.get("socket").map(String::as_str), Some("present"));
        assert_eq!(fields.len(), 2);
    }

    #[test]
    fn gui_env_sets_wayland_without_display() {
        let env = gui_env();
        assert_eq!(
            env.get("WAYLAND_DISPLAY").map(String::as_str),
            Some("msl-way-0")
        );
        assert!(!env.contains_key("DISPLAY"), "XWayland owns DISPLAY later");
        assert_eq!(
            env.get("LIBGL_ALWAYS_SOFTWARE").map(String::as_str),
            Some("1")
        );
    }

    #[test]
    fn launch_argv_must_be_absolute() {
        assert!(validate_argv(&[]).is_err());
        assert!(validate_argv(&["gimp".to_string()]).is_err());
        assert!(validate_argv(&["/usr/bin/gimp".to_string()]).is_ok());
    }
}
