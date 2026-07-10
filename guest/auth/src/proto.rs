use std::collections::HashMap;
use std::io;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const AUTH_VERSION: u32 = 1;
pub const DEFAULT_AUTH_PORT: u32 = 5040;
pub const MAX_SSH_PACKET: usize = 1024 * 1024;
pub const MAX_SECRET_BYTES: usize = 1024 * 1024;
pub const MAX_SECRET_ATTRIBUTES: usize = 64;
pub const MAX_SECRET_FIELD_BYTES: usize = 512;

/// Bound from the auth bridge contract: no host round trip may block a guest
/// client (`secret-tool`, `ssh`) longer than this.
pub const AUTH_TIMEOUT: Duration = Duration::from_secs(10);

pub type Attributes = HashMap<String, String>;

#[derive(Debug, Clone, Serialize)]
pub struct AuthPeer {
    pub id: String,
    pub token: String,
    pub distro: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub uid: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pid: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub comm: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct AuthRequest<T> {
    pub v: u32,
    pub id: u64,
    pub surface: &'static str,
    pub session: AuthPeer,
    pub op: &'static str,
    pub req: T,
}

#[derive(Debug, Serialize)]
pub struct SshForwardRequest {
    #[serde(rename = "packet_b64")]
    pub packet_b64: String,
}

#[derive(Debug, Serialize)]
pub struct SecretSearchRequest {
    pub attributes: Attributes,
}

#[derive(Debug, Serialize)]
pub struct SecretItemCreateRequest {
    pub label: String,
    pub attributes: Attributes,
    pub secret_b64: String,
}

#[derive(Debug, Serialize)]
pub struct SecretItemRequest {
    pub item_id: String,
}

#[derive(Debug, Serialize)]
pub struct SecretItemSetRequest {
    pub item_id: String,
    pub secret_b64: String,
}

#[derive(Debug, Deserialize)]
pub struct AuthReply {
    pub id: u64,
    pub ok: bool,
    #[serde(default)]
    pub data: Option<Value>,
    #[serde(default)]
    pub error: Option<AuthError>,
}

#[derive(Debug, Deserialize)]
pub struct AuthError {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Deserialize)]
pub struct SshForwardData {
    #[serde(rename = "packet_b64")]
    pub packet_b64: String,
}

/// Builds the host-auth peer descriptor from the session wrapper environment.
///
/// # Errors
///
/// Returns an error when any required `MSL_AUTH_*` value is absent or empty.
pub fn peer_from_env() -> Result<AuthPeer, String> {
    let id = required_env("MSL_AUTH_ID")?;
    let token = required_env("MSL_AUTH_TOKEN")?;
    let distro = required_env("MSL_AUTH_DISTRO")?;
    Ok(AuthPeer {
        id,
        token,
        distro,
        uid: None,
        pid: None,
        comm: None,
    })
}

/// Returns the reverse-vsock auth port advertised by the host wrapper.
#[must_use]
pub fn auth_port_from_env() -> u32 {
    std::env::var("MSL_AUTH_PORT")
        .ok()
        .and_then(|s| s.parse::<u32>().ok())
        .filter(|p| *p > 0)
        .unwrap_or(DEFAULT_AUTH_PORT)
}

/// A socket deadline surfaces as `WouldBlock` or `TimedOut` depending on libc.
#[must_use]
pub const fn is_timeout_kind(kind: io::ErrorKind) -> bool {
    matches!(kind, io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock)
}

/// Renders an I/O failure so an expired deadline is reported as `timeout`,
/// the auth bridge error code callers map onto a client-visible error.
#[must_use]
pub fn io_message(context: &str, error: &io::Error) -> String {
    assert!(!context.is_empty(), "io error context must not be empty");
    if is_timeout_kind(error.kind()) {
        let seconds = AUTH_TIMEOUT.as_secs();
        assert!(seconds > 0, "auth timeout must be a positive duration");
        return format!("timeout: {context} exceeded {seconds}s");
    }
    format!("{context}: {error}")
}

/// Opens a deadline-bounded vsock stream to the host auth bridge.
///
/// # Errors
///
/// Returns an error when the bridge is unreachable or rejects the deadline.
#[cfg(target_os = "linux")]
pub fn connect_auth_host() -> Result<vsock::VsockStream, String> {
    use vsock::{VsockAddr, VsockStream};

    let port = auth_port_from_env();
    assert!(port > 0, "auth port must be positive");
    let addr = VsockAddr::new(libc::VMADDR_CID_HOST, port);
    let stream = VsockStream::connect(&addr).map_err(|e| io_message("connect auth bridge", &e))?;
    stream
        .set_read_timeout(Some(AUTH_TIMEOUT))
        .map_err(|e| io_message("auth read deadline", &e))?;
    stream
        .set_write_timeout(Some(AUTH_TIMEOUT))
        .map_err(|e| io_message("auth write deadline", &e))?;
    Ok(stream)
}

fn required_env(key: &str) -> Result<String, String> {
    let value = std::env::var(key).map_err(|_| format!("{key} is not set"))?;
    if value.is_empty() {
        return Err(format!("{key} is empty"));
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::{
        AUTH_TIMEOUT, AUTH_VERSION, Attributes, AuthPeer, AuthRequest, SecretItemCreateRequest,
        SshForwardRequest, io_message, is_timeout_kind,
    };
    use std::io;

    #[test]
    fn auth_request_uses_contract_shape() {
        let peer = AuthPeer {
            id: "a".to_string(),
            token: "b".to_string(),
            distro: "ubuntu".to_string(),
            uid: None,
            pid: None,
            comm: None,
        };
        let req = AuthRequest {
            v: AUTH_VERSION,
            id: 7,
            surface: "ssh-agent",
            session: peer,
            op: "ssh.forward_packet",
            req: SshForwardRequest {
                packet_b64: "BQ==".to_string(),
            },
        };
        let json = serde_json::to_string(&req).expect("json");
        assert!(json.contains("\"surface\":\"ssh-agent\""));
        assert!(json.contains("\"packet_b64\""));
        assert!(!json.contains("\"uid\""));
    }

    #[test]
    fn item_create_request_carries_only_contract_fields() {
        let req = SecretItemCreateRequest {
            label: "l".to_string(),
            attributes: Attributes::new(),
            secret_b64: "BQ==".to_string(),
        };
        let json = serde_json::to_value(&req).expect("json");

        assert!(json.get("secret_b64").is_some());
        assert!(json.get("replace").is_none());
        assert!(json.get("content_type").is_none());
    }

    #[test]
    fn expired_deadlines_render_as_timeout() {
        let timed_out = io::Error::from(io::ErrorKind::TimedOut);
        let would_block = io::Error::from(io::ErrorKind::WouldBlock);
        let refused = io::Error::from(io::ErrorKind::ConnectionRefused);

        assert!(is_timeout_kind(timed_out.kind()));
        assert!(io_message("auth reply", &timed_out).starts_with("timeout: "));
        assert!(
            io_message("auth reply", &would_block)
                .contains(&format!("{}s", AUTH_TIMEOUT.as_secs()))
        );
        assert!(!is_timeout_kind(refused.kind()));
        assert!(io_message("connect auth bridge", &refused).starts_with("connect auth bridge: "));
    }
}
