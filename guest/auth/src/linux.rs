use std::fmt::Write as _;
use std::io::{self, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use msl_wire::frame::{read_frame, write_frame};
use vsock::{VsockAddr, VsockStream};

use crate::proto::{
    AUTH_VERSION, AuthReply, AuthRequest, MAX_SSH_PACKET, SshForwardData, SshForwardRequest,
    auth_port_from_env, peer_from_env,
};
use crate::ssh::{self, Decision};

const SOCKET_WAIT_TICKS: usize = 50;
const SOCKET_WAIT: Duration = Duration::from_millis(20);
const DBUS_DAEMON_CANDIDATES: &[&str] = &["/usr/bin/dbus-daemon", "/bin/dbus-daemon"];
const DBUS_BROKER_CANDIDATES: &[&str] = &["/usr/bin/dbus-broker-launch", "/bin/dbus-broker-launch"];
const SOCKET_ACTIVATE_CANDIDATES: &[&str] = &[
    "/usr/bin/systemd-socket-activate",
    "/bin/systemd-socket-activate",
];

#[derive(Clone, Debug, PartialEq, Eq)]
enum BusLauncher {
    DbusDaemon { path: String },
    DbusBroker { broker: String, activator: String },
}

#[must_use]
pub fn run_session() -> i32 {
    let argv = match parse_session_args() {
        Ok(argv) => argv,
        Err(message) => return fail(&message),
    };
    let mut env = std::env::vars().collect::<Vec<_>>();
    if std::env::var("MSL_AUTH_SECRETS").ok().as_deref() == Some("1") {
        match prepare_secret_service(&mut env) {
            Ok(()) => {}
            Err(message) => eprintln!("msl-session: Secret Service unavailable: {message}"),
        }
    }
    if std::env::var("MSL_AUTH_SSH").ok().as_deref() == Some("1") {
        match prepare_ssh_agent() {
            Ok(sock) => {
                env.retain(|(key, _)| key != "SSH_AUTH_SOCK");
                env.push(("SSH_AUTH_SOCK".to_string(), sock));
            }
            Err(message) => eprintln!("msl-session: ssh-agent unavailable: {message}"),
        }
    }
    exec_with_env(&argv, &env)
}

#[must_use]
pub fn run_ssh_agent() -> i32 {
    let sock = match std::env::var("MSL_AUTH_SSH_SOCK") {
        Ok(sock) if !sock.is_empty() => sock,
        _ => return fail("MSL_AUTH_SSH_SOCK is not set"),
    };
    if let Err(message) = serve_ssh_agent(&sock) {
        return fail(&message);
    }
    0
}

fn parse_session_args() -> Result<Vec<String>, String> {
    let mut input = std::env::args().skip(1);
    match input.next().as_deref() {
        Some("--") => {}
        _ => return Err("usage: msl-session -- <command> [args...]".to_string()),
    }
    let argv: Vec<String> = input.collect();
    if argv.is_empty() {
        return Err("missing command".to_string());
    }
    if !argv[0].starts_with('/') {
        return Err("command must be an absolute path".to_string());
    }
    Ok(argv)
}

fn prepare_ssh_agent() -> Result<String, String> {
    let dir = auth_runtime_dir()?;
    let sock = format!("{dir}/ssh-agent.sock");
    let _ = std::fs::remove_file(&sock);
    spawn_agent(&sock)?;
    wait_for_socket(&sock)?;
    Ok(sock)
}

fn runtime_root() -> Result<String, String> {
    if let Ok(value) = std::env::var("XDG_RUNTIME_DIR")
        && !value.is_empty()
    {
        return Ok(value);
    }
    let id = std::env::var("MSL_AUTH_ID").map_err(|_| "MSL_AUTH_ID is not set".to_string())?;
    let root = format!("/tmp/msl-auth-{id}");
    std::fs::create_dir_all(&root).map_err(|e| format!("runtime root: {e}"))?;
    let mut perms = std::fs::metadata(&root)
        .map_err(|e| format!("runtime root metadata: {e}"))?
        .permissions();
    perms.set_mode(0o700);
    std::fs::set_permissions(&root, perms).map_err(|e| format!("runtime root mode: {e}"))?;
    Ok(root)
}

fn auth_runtime_dir() -> Result<String, String> {
    let root = runtime_root()?;
    let dir = format!("{root}/msl");
    ensure_private_dir(&dir)?;
    Ok(dir)
}

fn ensure_private_dir(dir: &str) -> Result<(), String> {
    assert!(!dir.is_empty(), "runtime directory must not be empty");
    std::fs::create_dir_all(dir).map_err(|e| format!("runtime dir: {e}"))?;
    let mut perms = std::fs::metadata(dir)
        .map_err(|e| format!("runtime metadata: {e}"))?
        .permissions();
    perms.set_mode(0o700);
    std::fs::set_permissions(dir, perms).map_err(|e| format!("runtime mode: {e}"))
}

fn spawn_agent(sock: &str) -> Result<(), String> {
    let exe = "/run/msl/tools/msl-ssh-agent";
    let child = Command::new(exe)
        .env("MSL_AUTH_SSH_SOCK", sock)
        .spawn()
        .map_err(|e| format!("spawn ssh-agent adapter: {e}"))?;
    assert!(child.id() > 0, "spawned adapter pid must be positive");
    Ok(())
}

fn wait_for_socket(sock: &str) -> Result<(), String> {
    for _ in 0..SOCKET_WAIT_TICKS {
        if Path::new(sock).exists() {
            return Ok(());
        }
        thread::sleep(SOCKET_WAIT);
    }
    Err("adapter socket did not appear".to_string())
}

fn prepare_secret_service(env: &mut Vec<(String, String)>) -> Result<(), String> {
    assert!(
        !env.is_empty(),
        "session env must include process variables"
    );
    let address = match env_value(env, "DBUS_SESSION_BUS_ADDRESS") {
        Some(value) if !value.is_empty() => value,
        _ => start_session_bus(env)?,
    };
    set_env(env, "DBUS_SESSION_BUS_ADDRESS", &address);
    spawn_secretsd(env)?;
    Ok(())
}

fn start_session_bus(env: &[(String, String)]) -> Result<String, String> {
    let launcher = find_session_bus_launcher().ok_or_else(bus_provider_error)?;
    start_bus_launcher(&launcher, env)
}

fn start_bus_launcher(launcher: &BusLauncher, env: &[(String, String)]) -> Result<String, String> {
    assert!(!env.is_empty(), "session env must include variables");
    match launcher {
        BusLauncher::DbusDaemon { path } => start_dbus_daemon(path, env),
        BusLauncher::DbusBroker { broker, activator } => start_dbus_broker(broker, activator, env),
    }
}

fn start_dbus_daemon(daemon: &str, env: &[(String, String)]) -> Result<String, String> {
    assert!(!daemon.is_empty(), "dbus-daemon path must not be empty");
    let output = Command::new(daemon)
        .args(["--session", "--fork", "--print-address=1", "--print-pid=1"])
        .env_clear()
        .envs(env.iter().map(|(key, value)| (key, value)))
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| format!("start dbus-daemon: {e}"))?;
    if !output.status.success() {
        return Err(command_error("dbus-daemon", &output.stderr));
    }
    parse_bus_address(&output.stdout)
}

fn start_dbus_broker(
    broker: &str,
    activator: &str,
    env: &[(String, String)],
) -> Result<String, String> {
    assert!(
        !broker.is_empty(),
        "dbus-broker-launch path must not be empty"
    );
    assert!(
        !activator.is_empty(),
        "systemd-socket-activate path must not be empty"
    );
    let dir = auth_runtime_dir()?;
    let sock = format!("{dir}/session-bus.sock");
    let _ = std::fs::remove_file(&sock);
    let address = dbus_unix_path_address(&sock);
    let child = Command::new(activator)
        .arg(format!("--listen={sock}"))
        .arg(broker)
        .arg("--scope")
        .arg("user")
        .env_clear()
        .envs(env.iter().map(|(key, value)| (key, value)))
        .spawn()
        .map_err(|e| format!("start dbus-broker-launch: {e}"))?;
    assert!(child.id() > 0, "spawned bus launcher pid must be positive");
    wait_for_socket(&sock)?;
    Ok(address)
}

fn find_session_bus_launcher() -> Option<BusLauncher> {
    find_session_bus_launcher_with(|path| Path::new(path).is_file())
}

fn find_session_bus_launcher_with<F>(exists: F) -> Option<BusLauncher>
where
    F: Fn(&str) -> bool,
{
    if let Some(path) = first_existing(DBUS_DAEMON_CANDIDATES, &exists) {
        return Some(BusLauncher::DbusDaemon { path });
    }
    let broker = first_existing(DBUS_BROKER_CANDIDATES, &exists)?;
    let activator = first_existing(SOCKET_ACTIVATE_CANDIDATES, &exists)?;
    Some(BusLauncher::DbusBroker { broker, activator })
}

fn first_existing<F>(candidates: &[&str], exists: &F) -> Option<String>
where
    F: Fn(&str) -> bool,
{
    for candidate in candidates {
        if exists(candidate) {
            return Some((*candidate).to_string());
        }
    }
    None
}

fn bus_provider_error() -> String {
    "dbus-daemon is not installed, and dbus-broker-launch requires systemd-socket-activate"
        .to_string()
}

fn spawn_secretsd(env: &[(String, String)]) -> Result<(), String> {
    let exe = "/run/msl/tools/msl-secretsd";
    let child = Command::new(exe)
        .env_clear()
        .envs(env.iter().map(|(key, value)| (key, value)))
        .spawn()
        .map_err(|e| format!("spawn Secret Service adapter: {e}"))?;
    assert!(
        child.id() > 0,
        "spawned secrets adapter pid must be positive"
    );
    Ok(())
}

fn parse_bus_address(stdout: &[u8]) -> Result<String, String> {
    let text = std::str::from_utf8(stdout).map_err(|e| format!("dbus output utf8: {e}"))?;
    let Some(first) = text.lines().next() else {
        return Err("dbus-daemon printed no bus address".to_string());
    };
    if first.is_empty() {
        Err("dbus-daemon printed an empty bus address".to_string())
    } else {
        Ok(first.to_string())
    }
}

fn dbus_unix_path_address(path: &str) -> String {
    assert!(!path.is_empty(), "dbus socket path must not be empty");
    format!("unix:path={}", dbus_address_escape(path))
}

fn dbus_address_escape(value: &str) -> String {
    assert!(!value.is_empty(), "dbus address value must not be empty");
    let mut escaped = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'/' | b'.') {
            escaped.push(char::from(byte));
        } else {
            escaped.push('%');
            let result = write!(&mut escaped, "{byte:02X}");
            assert!(result.is_ok(), "writing to String cannot fail");
        }
    }
    escaped
}

fn command_error(label: &str, stderr: &[u8]) -> String {
    let detail = String::from_utf8_lossy(stderr).trim().to_string();
    if detail.is_empty() {
        format!("{label} failed")
    } else {
        format!("{label} failed: {detail}")
    }
}

fn env_value(env: &[(String, String)], key: &str) -> Option<String> {
    env.iter()
        .find(|(candidate, _)| candidate == key)
        .map(|(_, value)| value.clone())
}

fn set_env(env: &mut Vec<(String, String)>, key: &str, value: &str) {
    assert!(!key.is_empty(), "env key must not be empty");
    env.retain(|(candidate, _)| candidate != key);
    env.push((key.to_string(), value.to_string()));
}

fn exec_with_env(argv: &[String], env: &[(String, String)]) -> i32 {
    use std::os::unix::process::CommandExt;

    assert!(!argv.is_empty(), "exec argv must be non-empty");
    let mut command = Command::new(&argv[0]);
    command.args(&argv[1..]);
    command.env_clear();
    for (key, value) in env {
        command.env(key, value);
    }
    let err = command.exec();
    fail(&format!("exec {}: {err}", argv[0]))
}

fn serve_ssh_agent(sock: &str) -> Result<(), String> {
    let _ = std::fs::remove_file(sock);
    let listener = UnixListener::bind(sock).map_err(|e| format!("bind ssh socket: {e}"))?;
    let mut perms = std::fs::metadata(sock)
        .map_err(|e| format!("socket metadata: {e}"))?
        .permissions();
    perms.set_mode(0o600);
    std::fs::set_permissions(sock, perms).map_err(|e| format!("socket mode: {e}"))?;
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let _ = thread::Builder::new()
                    .name("ssh-agent".to_string())
                    .spawn(move || serve_client(stream));
            }
            Err(e) => return Err(format!("accept ssh client: {e}")),
        }
    }
    Ok(())
}

fn serve_client(mut client: UnixStream) {
    while let Ok(packet) = read_agent_packet(&mut client) {
        let reply = handle_packet(&packet).unwrap_or_else(|_| ssh::failure_packet().to_vec());
        if write_agent_packet(&mut client, &reply).is_err() {
            return;
        }
    }
}

fn handle_packet(packet: &[u8]) -> Result<Vec<u8>, String> {
    let forwarding = std::env::var("MSL_AUTH_SSH_FORWARDING").ok().as_deref() == Some("1");
    if ssh::decision(packet, forwarding) == Decision::Reject {
        return Ok(ssh::failure_packet().to_vec());
    }
    let peer = peer_from_env()?;
    let req = AuthRequest {
        v: AUTH_VERSION,
        id: 1,
        surface: "ssh-agent",
        session: peer,
        op: "ssh.forward_packet",
        req: SshForwardRequest {
            packet_b64: STANDARD.encode(packet),
        },
    };
    let mut host = connect_host()?;
    let bytes = serde_json::to_vec(&req).map_err(|e| format!("auth encode: {e}"))?;
    write_frame(&mut host, &bytes).map_err(|e| format!("auth send: {e}"))?;
    let reply = read_frame(&mut host).map_err(|e| format!("auth reply: {e}"))?;
    parse_forward_reply(&reply)
}

fn parse_forward_reply(reply: &[u8]) -> Result<Vec<u8>, String> {
    let parsed: AuthReply =
        serde_json::from_slice(reply).map_err(|e| format!("auth reply json: {e}"))?;
    if !parsed.ok {
        let message = parsed
            .error
            .map_or_else(|| "auth request failed".to_string(), |e| e.message);
        return Err(message);
    }
    let data = parsed
        .data
        .ok_or_else(|| "auth reply missing data".to_string())?;
    let body: SshForwardData =
        serde_json::from_value(data).map_err(|e| format!("auth reply data: {e}"))?;
    STANDARD
        .decode(body.packet_b64)
        .map_err(|e| format!("auth reply base64: {e}"))
}

fn connect_host() -> Result<VsockStream, String> {
    let addr = VsockAddr::new(libc::VMADDR_CID_HOST, auth_port_from_env());
    VsockStream::connect(&addr).map_err(|e| format!("connect auth bridge: {e}"))
}

fn read_agent_packet<R: Read>(reader: &mut R) -> io::Result<Vec<u8>> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf)?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > MAX_SSH_PACKET {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "packet too large",
        ));
    }
    let mut packet = vec![0u8; len];
    reader.read_exact(&mut packet)?;
    Ok(packet)
}

fn write_agent_packet<W: Write>(writer: &mut W, packet: &[u8]) -> io::Result<()> {
    if packet.len() > MAX_SSH_PACKET {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "packet too large",
        ));
    }
    let len = u32::try_from(packet.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "packet overflow"))?;
    writer.write_all(&len.to_be_bytes())?;
    writer.write_all(packet)?;
    Ok(())
}

fn fail(message: &str) -> i32 {
    eprintln!("msl-auth: {message}");
    255
}

#[cfg(test)]
mod tests {
    use super::{
        BusLauncher, bus_provider_error, dbus_address_escape, dbus_unix_path_address,
        find_session_bus_launcher_with, parse_bus_address,
    };

    fn exists(path: &str, present: &[&str]) -> bool {
        assert!(!path.is_empty(), "candidate path must not be empty");
        present.contains(&path)
    }

    #[test]
    fn bus_launcher_prefers_dbus_daemon() {
        let launcher = find_session_bus_launcher_with(|path| {
            exists(
                path,
                &[
                    "/usr/bin/dbus-daemon",
                    "/usr/bin/dbus-broker-launch",
                    "/usr/bin/systemd-socket-activate",
                ],
            )
        });
        assert_eq!(
            launcher,
            Some(BusLauncher::DbusDaemon {
                path: "/usr/bin/dbus-daemon".to_string(),
            })
        );
    }

    #[test]
    fn bus_launcher_accepts_broker_with_activator() {
        let launcher = find_session_bus_launcher_with(|path| {
            exists(
                path,
                &["/bin/dbus-broker-launch", "/bin/systemd-socket-activate"],
            )
        });
        assert_eq!(
            launcher,
            Some(BusLauncher::DbusBroker {
                broker: "/bin/dbus-broker-launch".to_string(),
                activator: "/bin/systemd-socket-activate".to_string(),
            })
        );
    }

    #[test]
    fn bus_launcher_rejects_broker_without_activator() {
        let launcher =
            find_session_bus_launcher_with(|path| exists(path, &["/usr/bin/dbus-broker-launch"]));
        let message = bus_provider_error();
        assert_eq!(launcher, None);
        assert!(message.contains("dbus-daemon"));
        assert!(message.contains("systemd-socket-activate"));
    }

    #[test]
    fn dbus_address_escapes_socket_path() {
        let escaped = dbus_address_escape("/tmp/msl auth/session,bus.sock");
        let address = dbus_unix_path_address("/tmp/msl auth/session,bus.sock");
        assert_eq!(escaped, "/tmp/msl%20auth/session%2Cbus.sock");
        assert_eq!(address, "unix:path=/tmp/msl%20auth/session%2Cbus.sock");
    }

    #[test]
    fn bus_address_parser_takes_first_line() {
        let parsed = parse_bus_address(b"unix:path=/tmp/bus\n1234\n").expect("valid address");
        assert_eq!(parsed, "unix:path=/tmp/bus");
        assert!(parse_bus_address(b"").is_err());
        assert!(parse_bus_address(b"\n123\n").is_err());
    }
}
