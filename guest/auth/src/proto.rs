use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const AUTH_VERSION: u32 = 1;
pub const DEFAULT_AUTH_PORT: u32 = 5040;
pub const MAX_SSH_PACKET: usize = 1024 * 1024;
pub const MAX_SECRET_BYTES: usize = 1024 * 1024;
pub const MAX_SECRET_ATTRIBUTES: usize = 64;
pub const MAX_SECRET_FIELD_BYTES: usize = 512;

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
pub struct AuthQueryRequest {
    pub surface: &'static str,
}

#[derive(Debug, Serialize)]
pub struct SecretSearchRequest {
    pub attributes: std::collections::BTreeMap<String, String>,
}

#[derive(Debug, Serialize)]
pub struct SecretItemCreateRequest {
    pub label: String,
    pub attributes: std::collections::BTreeMap<String, String>,
    pub secret_b64: String,
    pub content_type: String,
    pub replace: bool,
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

fn required_env(key: &str) -> Result<String, String> {
    let value = std::env::var(key).map_err(|_| format!("{key} is not set"))?;
    if value.is_empty() {
        return Err(format!("{key} is empty"));
    }
    Ok(value)
}

#[cfg(test)]
mod tests {
    use super::{AUTH_VERSION, AuthPeer, AuthRequest, SshForwardRequest};

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
}
