use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::process::{Command, Stdio};
use std::thread;
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use msl_wire::frame::{read_frame, write_frame};

use crate::bootstrap::{
    BusLauncher, DBUS_BROKER_CANDIDATES, DBUS_DAEMON_CANDIDATES, SOCKET_ACTIVATE_CANDIDATES,
    auth_dir_path, bus_provider_error, command_error, dbus_unix_path_address, env_value,
    find_session_bus_launcher_with, parse_bus_address, read_agent_packet, session_bus_sock_path,
    set_env, ssh_sock_path, write_agent_packet,
};
use crate::proto::{
    AUTH_VERSION, AuthReply, AuthRequest, SshForwardData, SshForwardRequest, connect_auth_host,
    io_message, peer_from_env,
};
use crate::ssh::{self, Decision};

const SOCKET_WAIT_TICKS: usize = 50;
const SOCKET_WAIT: Duration = Duration::from_millis(20);

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
            Ok(sock) => set_env(&mut env, "SSH_AUTH_SOCK", &sock),
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
    let sock = ssh_sock_path(&dir);
    let _ = std::fs::remove_file(&sock);
    spawn_agent(&sock)?;
    wait_for_socket(&sock)?;
    assert!(Path::new(&sock).exists(), "the waited-for socket exists");
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
    let dir = auth_dir_path(&root);
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
    assert!(!sock.is_empty(), "agent socket path must not be empty");
    let exe = "/run/msl/tools/msl-ssh-agent";
    let child = Command::new(exe)
        .env("MSL_AUTH_SSH_SOCK", sock)
        .spawn()
        .map_err(|e| format!("spawn ssh-agent adapter: {e}"))?;
    assert!(child.id() > 0, "spawned adapter pid must be positive");
    Ok(())
}

fn wait_for_socket(sock: &str) -> Result<(), String> {
    assert!(!sock.is_empty(), "socket path must not be empty");
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

fn find_session_bus_launcher() -> Option<BusLauncher> {
    assert!(
        !DBUS_DAEMON_CANDIDATES.is_empty(),
        "candidates are literals"
    );
    assert!(
        !DBUS_BROKER_CANDIDATES.is_empty(),
        "candidates are literals"
    );
    find_session_bus_launcher_with(|path| Path::new(path).is_file())
}

fn start_bus_launcher(launcher: &BusLauncher, env: &[(String, String)]) -> Result<String, String> {
    assert!(!env.is_empty(), "session env must include variables");
    assert!(
        !SOCKET_ACTIVATE_CANDIDATES.is_empty(),
        "candidates are literals"
    );
    match launcher {
        BusLauncher::DbusDaemon { path } => start_dbus_daemon(path, env),
        BusLauncher::DbusBroker { broker, activator } => start_dbus_broker(broker, activator, env),
    }
}

fn start_dbus_daemon(daemon: &str, env: &[(String, String)]) -> Result<String, String> {
    assert!(!daemon.is_empty(), "dbus-daemon path must not be empty");
    assert!(!env.is_empty(), "session env must include variables");
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
    let sock = session_bus_sock_path(&dir);
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

fn spawn_secretsd(env: &[(String, String)]) -> Result<(), String> {
    assert!(!env.is_empty(), "session env must include variables");
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

fn exec_with_env(argv: &[String], env: &[(String, String)]) -> i32 {
    use std::os::unix::process::CommandExt;

    assert!(!argv.is_empty(), "exec argv must be non-empty");
    assert!(argv[0].starts_with('/'), "exec target must be absolute");
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
    assert!(!sock.is_empty(), "agent socket path must not be empty");
    let _ = std::fs::remove_file(sock);
    let listener = UnixListener::bind(sock).map_err(|e| format!("bind ssh socket: {e}"))?;
    let mut perms = std::fs::metadata(sock)
        .map_err(|e| format!("socket metadata: {e}"))?
        .permissions();
    perms.set_mode(0o600);
    std::fs::set_permissions(sock, perms).map_err(|e| format!("socket mode: {e}"))?;
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => spawn_client(stream),
            Err(e) => return Err(format!("accept ssh client: {e}")),
        }
    }
    Ok(())
}

/// A client whose thread cannot be created is dropped, not silently ignored:
/// `ssh` sees the closed socket and falls back to its other auth methods.
fn spawn_client(stream: UnixStream) {
    let spawned = thread::Builder::new()
        .name("ssh-agent".to_string())
        .spawn(move || serve_client(stream));
    match spawned {
        Ok(handle) => drop(handle),
        Err(e) => eprintln!("msl-ssh-agent: cannot serve client: {e}"),
    }
}

fn serve_client(mut client: UnixStream) {
    while let Ok(packet) = read_agent_packet(&mut client) {
        let reply = handle_packet(&packet).unwrap_or_else(|message| {
            eprintln!("msl-ssh-agent: {message}");
            ssh::failure_packet().to_vec()
        });
        if write_agent_packet(&mut client, &reply).is_err() {
            return;
        }
    }
}

fn handle_packet(packet: &[u8]) -> Result<Vec<u8>, String> {
    assert!(!packet.is_empty(), "framing rejects empty agent packets");
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
    let bytes = serde_json::to_vec(&req).map_err(|e| format!("auth encode: {e}"))?;
    let mut host = connect_auth_host()?;
    write_frame(&mut host, &bytes).map_err(|e| io_message("auth send", &e))?;
    let reply = read_frame(&mut host).map_err(|e| io_message("auth reply", &e))?;
    parse_forward_reply(&reply)
}

fn parse_forward_reply(reply: &[u8]) -> Result<Vec<u8>, String> {
    assert!(!reply.is_empty(), "a framed reply is never empty");
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

fn fail(message: &str) -> i32 {
    assert!(!message.is_empty(), "a failure names its cause");
    eprintln!("msl-auth: {message}");
    255
}
