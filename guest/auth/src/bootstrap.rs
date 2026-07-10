//! Platform-independent pieces of session bootstrap: bus-launcher selection,
//! D-Bus address formatting, session environment edits, and agent framing.

use std::fmt::Write as _;
use std::io::{self, Read, Write};

use crate::proto::MAX_SSH_PACKET;

pub const DBUS_DAEMON_CANDIDATES: &[&str] = &["/usr/bin/dbus-daemon", "/bin/dbus-daemon"];
pub const DBUS_BROKER_CANDIDATES: &[&str] =
    &["/usr/bin/dbus-broker-launch", "/bin/dbus-broker-launch"];
pub const SOCKET_ACTIVATE_CANDIDATES: &[&str] = &[
    "/usr/bin/systemd-socket-activate",
    "/bin/systemd-socket-activate",
];

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BusLauncher {
    DbusDaemon { path: String },
    DbusBroker { broker: String, activator: String },
}

/// Prefers `dbus-daemon`; `dbus-broker-launch` is usable only with an activator.
pub fn find_session_bus_launcher_with<F>(exists: F) -> Option<BusLauncher>
where
    F: Fn(&str) -> bool,
{
    if let Some(path) = first_existing(DBUS_DAEMON_CANDIDATES, &exists) {
        assert!(!path.is_empty(), "candidate paths are non-empty literals");
        return Some(BusLauncher::DbusDaemon { path });
    }
    let broker = first_existing(DBUS_BROKER_CANDIDATES, &exists)?;
    let activator = first_existing(SOCKET_ACTIVATE_CANDIDATES, &exists)?;
    assert!(!broker.is_empty(), "broker path is a non-empty literal");
    assert!(
        !activator.is_empty(),
        "activator path is a non-empty literal"
    );
    Some(BusLauncher::DbusBroker { broker, activator })
}

fn first_existing<F>(candidates: &[&str], exists: &F) -> Option<String>
where
    F: Fn(&str) -> bool,
{
    assert!(!candidates.is_empty(), "candidate list must not be empty");
    for candidate in candidates {
        assert!(!candidate.is_empty(), "candidate path must not be empty");
        if exists(candidate) {
            return Some((*candidate).to_string());
        }
    }
    None
}

#[must_use]
pub fn bus_provider_error() -> String {
    "dbus-daemon is not installed, and dbus-broker-launch requires systemd-socket-activate"
        .to_string()
}

/// # Errors
///
/// Returns an error when the launcher printed no usable address line.
pub fn parse_bus_address(stdout: &[u8]) -> Result<String, String> {
    let text = std::str::from_utf8(stdout).map_err(|e| format!("dbus output utf8: {e}"))?;
    let Some(first) = text.lines().next() else {
        return Err("dbus-daemon printed no bus address".to_string());
    };
    if first.is_empty() {
        Err("dbus-daemon printed an empty bus address".to_string())
    } else {
        assert!(!first.contains('\n'), "a line never contains a newline");
        Ok(first.to_string())
    }
}

#[must_use]
pub fn dbus_unix_path_address(path: &str) -> String {
    assert!(!path.is_empty(), "dbus socket path must not be empty");
    assert!(path.starts_with('/'), "dbus socket path must be absolute");
    format!("unix:path={}", dbus_address_escape(path))
}

#[must_use]
pub fn dbus_address_escape(value: &str) -> String {
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

#[must_use]
pub fn command_error(label: &str, stderr: &[u8]) -> String {
    assert!(!label.is_empty(), "command label must not be empty");
    let detail = String::from_utf8_lossy(stderr).trim().to_string();
    if detail.is_empty() {
        format!("{label} failed")
    } else {
        format!("{label} failed: {detail}")
    }
}

#[must_use]
pub fn env_value(env: &[(String, String)], key: &str) -> Option<String> {
    assert!(!key.is_empty(), "env key must not be empty");
    env.iter()
        .find(|(candidate, _)| candidate == key)
        .map(|(_, value)| value.clone())
}

pub fn set_env(env: &mut Vec<(String, String)>, key: &str, value: &str) {
    assert!(!key.is_empty(), "env key must not be empty");
    env.retain(|(candidate, _)| candidate != key);
    env.push((key.to_string(), value.to_string()));
    assert!(!env.is_empty(), "env holds at least the value just set");
}

#[must_use]
pub fn auth_dir_path(root: &str) -> String {
    assert!(!root.is_empty(), "runtime root must not be empty");
    format!("{root}/msl")
}

#[must_use]
pub fn ssh_sock_path(dir: &str) -> String {
    assert!(!dir.is_empty(), "runtime dir must not be empty");
    format!("{dir}/ssh-agent.sock")
}

#[must_use]
pub fn session_bus_sock_path(dir: &str) -> String {
    assert!(!dir.is_empty(), "runtime dir must not be empty");
    format!("{dir}/session-bus.sock")
}

/// # Errors
///
/// Returns an error on a short read or an over-long declared length.
pub fn read_agent_packet<R: Read>(reader: &mut R) -> io::Result<Vec<u8>> {
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
    assert!(packet.len() == len, "read_exact fills the whole buffer");
    Ok(packet)
}

/// # Errors
///
/// Returns an error when the packet exceeds the v1 bound or the write fails.
pub fn write_agent_packet<W: Write>(writer: &mut W, packet: &[u8]) -> io::Result<()> {
    if packet.len() > MAX_SSH_PACKET {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "packet too large",
        ));
    }
    let len = u32::try_from(packet.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "packet overflow"))?;
    assert!(
        len as usize == packet.len(),
        "length conversion is lossless"
    );
    writer.write_all(&len.to_be_bytes())?;
    writer.write_all(packet)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        BusLauncher, bus_provider_error, dbus_address_escape, dbus_unix_path_address,
        find_session_bus_launcher_with, parse_bus_address, read_agent_packet, ssh_sock_path,
        write_agent_packet,
    };
    use crate::proto::MAX_SSH_PACKET;

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

    #[test]
    fn agent_framing_round_trips_and_bounds_length() {
        let mut wire = Vec::new();
        write_agent_packet(&mut wire, &[11u8]).expect("write");
        let packet = read_agent_packet(&mut wire.as_slice()).expect("read");
        assert_eq!(packet, vec![11u8]);

        let oversize = u32::try_from(MAX_SSH_PACKET + 1).expect("bound fits u32");
        let mut framed = oversize.to_be_bytes().to_vec();
        framed.push(0);
        assert!(read_agent_packet(&mut framed.as_slice()).is_err());
        assert!(read_agent_packet(&mut [0u8, 1].as_slice()).is_err());
    }

    #[test]
    fn ssh_socket_path_lives_under_the_runtime_dir() {
        assert_eq!(
            ssh_sock_path("/run/user/1000/msl"),
            "/run/user/1000/msl/ssh-agent.sock"
        );
    }
}
