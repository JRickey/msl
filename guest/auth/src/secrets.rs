#![allow(
    clippy::missing_const_for_fn,
    clippy::missing_errors_doc,
    clippy::must_use_candidate,
    clippy::needless_pass_by_value,
    clippy::unnecessary_literal_bound
)]

use std::collections::{BTreeMap, HashMap};

use serde_json::Value as JsonValue;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

use crate::proto::{AUTH_VERSION, AuthPeer};
use crate::proto::{AuthReply, AuthRequest};

pub const MAX_SECRET_BYTES: usize = 1024 * 1024;
pub const MAX_SECRET_ATTRIBUTES: usize = 64;
pub const MAX_SECRET_FIELD_BYTES: usize = 512;

pub const SERVICE_NAME: &str = "org.freedesktop.secrets";
pub const SERVICE_PATH: &str = "/org/freedesktop/secrets";
pub const DEFAULT_COLLECTION_PATH: &str = "/org/freedesktop/secrets/collection/login";
pub const DEFAULT_ALIAS_PATH: &str = "/org/freedesktop/secrets/aliases/default";
pub const DEFAULT_SESSION_PATH: &str = "/org/freedesktop/secrets/session/plain";
pub const PROMPT_NONE: &str = "/";

pub type Attributes = BTreeMap<String, String>;
pub type Secret = (OwnedObjectPath, Vec<u8>, Vec<u8>, String);
pub type SecretMap = HashMap<OwnedObjectPath, Secret>;
pub type ItemPair = (Vec<OwnedObjectPath>, Vec<OwnedObjectPath>);

#[derive(Debug, serde::Serialize)]
pub struct AuthQueryRequest {
    pub surface: &'static str,
}

#[derive(Debug, serde::Serialize)]
pub struct SecretSearchRequest {
    pub attributes: Attributes,
}

#[derive(Debug, serde::Serialize)]
pub struct SecretItemCreateRequest {
    pub label: String,
    pub attributes: Attributes,
    pub secret_b64: String,
    pub content_type: String,
    pub replace: bool,
}

#[derive(Debug, zbus::DBusError)]
#[zbus(prefix = "org.freedesktop.Secret.Error", impl_display = true)]
pub enum SecretError {
    #[zbus(error)]
    ZBus(zbus::Error),
    NotSupported(String),
    NoSession(String),
    NoSuchObject(String),
}

pub fn run_daemon() -> i32 {
    match run_daemon_result() {
        Ok(()) => 0,
        Err(message) => {
            eprintln!("msl-secretsd: {message}");
            255
        }
    }
}

pub fn validate_attributes(attributes: &Attributes) -> Result<(), String> {
    if attributes.len() > MAX_SECRET_ATTRIBUTES {
        return Err("too many secret attributes".to_string());
    }
    for (key, value) in attributes {
        validate_field("attribute key", key)?;
        validate_field("attribute value", value)?;
    }
    Ok(())
}

pub fn validate_label(label: &str) -> Result<(), String> {
    validate_field("label", label)
}

pub fn validate_secret(secret: &[u8]) -> Result<(), String> {
    if secret.len() > MAX_SECRET_BYTES {
        return Err("secret payload too large".to_string());
    }
    Ok(())
}

#[derive(Clone, Debug)]
pub struct SecretService;

#[zbus::interface(name = "org.freedesktop.Secret.Service")]
impl SecretService {
    pub fn open_session(
        &self,
        algorithm: &str,
        input: Value<'_>,
    ) -> Result<(OwnedValue, OwnedObjectPath), SecretError> {
        if algorithm != "plain" {
            return Err(SecretError::NotSupported(
                "only plain Secret Service sessions are supported".to_string(),
            ));
        }
        let value = input
            .try_to_owned()
            .map_err(|e| SecretError::NotSupported(format!("invalid session value: {e}")))?;
        Ok((value, path(DEFAULT_SESSION_PATH)))
    }

    pub fn search_items(&self, attributes: Attributes) -> Result<ItemPair, SecretError> {
        map_validation(validate_attributes(&attributes))?;
        Ok((Vec::new(), Vec::new()))
    }

    pub fn get_secrets(
        &self,
        items: Vec<OwnedObjectPath>,
        session: OwnedObjectPath,
    ) -> Result<SecretMap, SecretError> {
        validate_session(&session)?;
        if items.is_empty() {
            return Ok(HashMap::new());
        }
        Err(unsupported_store())
    }

    pub fn read_alias(&self, name: &str) -> OwnedObjectPath {
        if name == "default" {
            path(DEFAULT_COLLECTION_PATH)
        } else {
            path(PROMPT_NONE)
        }
    }

    #[zbus(property)]
    pub fn collections(&self) -> Vec<OwnedObjectPath> {
        vec![path(DEFAULT_COLLECTION_PATH)]
    }
}

#[derive(Clone, Debug)]
pub struct SecretCollection;

#[zbus::interface(name = "org.freedesktop.Secret.Collection")]
impl SecretCollection {
    pub fn create_item(
        &self,
        properties: HashMap<String, OwnedValue>,
        secret: Secret,
        replace: bool,
    ) -> Result<(OwnedObjectPath, OwnedObjectPath), SecretError> {
        let req = create_request(&properties, secret, replace)?;
        let _ = serde_json::to_value(req).map_err(|e| {
            SecretError::NotSupported(format!("secret request encoding failed: {e}"))
        })?;
        Err(unsupported_store())
    }

    pub fn search_items(
        &self,
        attributes: Attributes,
    ) -> Result<Vec<OwnedObjectPath>, SecretError> {
        map_validation(validate_attributes(&attributes))?;
        Ok(Vec::new())
    }

    #[zbus(property)]
    pub fn items(&self) -> Vec<OwnedObjectPath> {
        Vec::new()
    }

    #[zbus(property)]
    pub fn label(&self) -> &str {
        "Login"
    }

    #[zbus(property)]
    pub fn locked(&self) -> bool {
        false
    }

    #[zbus(property)]
    pub fn created(&self) -> u64 {
        0
    }

    #[zbus(property)]
    pub fn modified(&self) -> u64 {
        0
    }
}

#[derive(Clone, Debug)]
pub struct SecretItem;

impl SecretItem {
    pub fn get_secret(&self, session: OwnedObjectPath) -> Result<Secret, SecretError> {
        validate_session(&session)?;
        Err(SecretError::NoSuchObject(
            "secret item is not present".to_string(),
        ))
    }

    pub fn set_secret(&self, secret: Secret) -> Result<(), SecretError> {
        validate_secret(&secret.2).map_err(SecretError::NotSupported)?;
        Err(unsupported_store())
    }

    pub fn delete(&self) -> Result<OwnedObjectPath, SecretError> {
        Err(unsupported_store())
    }

    pub fn attributes(&self) -> Attributes {
        BTreeMap::new()
    }

    pub fn label(&self) -> &str {
        ""
    }

    pub fn locked(&self) -> bool {
        false
    }

    pub fn created(&self) -> u64 {
        0
    }

    pub fn modified(&self) -> u64 {
        0
    }
}

pub fn query_request(peer: AuthPeer) -> AuthRequest<AuthQueryRequest> {
    AuthRequest {
        v: AUTH_VERSION,
        id: 1,
        surface: "secrets",
        session: peer,
        op: "secret.query",
        req: AuthQueryRequest { surface: "secrets" },
    }
}

pub fn search_request(peer: AuthPeer, attributes: Attributes) -> AuthRequest<SecretSearchRequest> {
    AuthRequest {
        v: AUTH_VERSION,
        id: 1,
        surface: "secrets",
        session: peer,
        op: "secret.item.search",
        req: SecretSearchRequest { attributes },
    }
}

pub fn parse_empty_reply(reply: &[u8]) -> Result<Option<JsonValue>, String> {
    let parsed: AuthReply =
        serde_json::from_slice(reply).map_err(|e| format!("auth reply json: {e}"))?;
    if parsed.ok {
        return Ok(parsed.data);
    }
    let message = parsed.error.map_or_else(
        || "secret bridge request failed".to_string(),
        |e| format!("{}: {}", e.code, e.message),
    );
    Err(message)
}

fn run_daemon_result() -> Result<(), String> {
    require_session_bus()?;
    let _connection = zbus::blocking::connection::Builder::session()
        .map_err(|e| format!("connect session bus: {e}"))?
        .serve_at(SERVICE_PATH, SecretService)
        .map_err(|e| format!("serve service object: {e}"))?
        .serve_at(DEFAULT_COLLECTION_PATH, SecretCollection)
        .map_err(|e| format!("serve collection object: {e}"))?
        .serve_at(DEFAULT_ALIAS_PATH, SecretCollection)
        .map_err(|e| format!("serve alias object: {e}"))?
        .name(SERVICE_NAME)
        .map_err(|e| format!("own {SERVICE_NAME}: {e}"))?
        .build()
        .map_err(|e| format!("start Secret Service adapter: {e}"))?;
    std::thread::park();
    Ok(())
}

fn create_request(
    properties: &HashMap<String, OwnedValue>,
    secret: Secret,
    replace: bool,
) -> Result<SecretItemCreateRequest, SecretError> {
    let label = label_property(properties)?;
    validate_label(&label).map_err(SecretError::NotSupported)?;
    validate_secret(&secret.2).map_err(SecretError::NotSupported)?;
    Ok(SecretItemCreateRequest {
        label,
        attributes: BTreeMap::new(),
        secret_b64: base64::Engine::encode(&base64::engine::general_purpose::STANDARD, secret.2),
        content_type: secret.3,
        replace,
    })
}

fn label_property(properties: &HashMap<String, OwnedValue>) -> Result<String, SecretError> {
    let Some(value) = properties.get("org.freedesktop.Secret.Item.Label") else {
        return Ok(String::new());
    };
    let cloned = value
        .try_clone()
        .map_err(|e| SecretError::NotSupported(format!("invalid label: {e}")))?;
    String::try_from(cloned).map_err(|e| SecretError::NotSupported(format!("invalid label: {e}")))
}

fn require_session_bus() -> Result<(), String> {
    match std::env::var("DBUS_SESSION_BUS_ADDRESS") {
        Ok(value) if !value.is_empty() => Ok(()),
        Ok(_) => Err("DBUS_SESSION_BUS_ADDRESS is empty".to_string()),
        Err(_) => Err("DBUS_SESSION_BUS_ADDRESS is not set".to_string()),
    }
}

fn validate_field(name: &str, value: &str) -> Result<(), String> {
    if value.len() > MAX_SECRET_FIELD_BYTES {
        return Err(format!("{name} exceeds {MAX_SECRET_FIELD_BYTES} bytes"));
    }
    Ok(())
}

fn validate_session(session: &OwnedObjectPath) -> Result<(), SecretError> {
    if session.as_str() == DEFAULT_SESSION_PATH {
        Ok(())
    } else {
        Err(SecretError::NoSession(
            "unknown Secret Service session".to_string(),
        ))
    }
}

fn map_validation(result: Result<(), String>) -> Result<(), SecretError> {
    result.map_err(SecretError::NotSupported)
}

fn unsupported_store() -> SecretError {
    SecretError::NotSupported("host Secret Service store is not available".to_string())
}

fn path(value: &str) -> OwnedObjectPath {
    OwnedObjectPath::try_from(value).expect("static Secret Service path must be valid")
}

#[cfg(test)]
mod tests {
    use super::{
        Attributes, DEFAULT_COLLECTION_PATH, DEFAULT_SESSION_PATH, PROMPT_NONE, SecretService,
        parse_empty_reply, query_request, search_request, validate_attributes, validate_label,
        validate_secret,
    };
    use crate::proto::{AuthPeer, MAX_SECRET_ATTRIBUTES, MAX_SECRET_BYTES, MAX_SECRET_FIELD_BYTES};
    use zbus::zvariant::Value;

    fn peer() -> AuthPeer {
        AuthPeer {
            id: "id".to_string(),
            token: "token".to_string(),
            distro: "ubuntu".to_string(),
            uid: Some(1000),
            pid: Some(42),
            comm: Some("secret-tool".to_string()),
        }
    }

    #[test]
    fn secrets_open_plain_session_uses_stable_path() {
        let service = SecretService;
        let opened = service
            .open_session("plain", Value::from(""))
            .expect("plain session");

        assert_eq!(opened.1.as_str(), DEFAULT_SESSION_PATH);
        assert!(
            service
                .open_session("dh-ietf1024-sha256-aes128-cbc-pkcs7", Value::from(""))
                .is_err()
        );
    }

    #[test]
    fn secrets_alias_and_collection_shape_are_stable() {
        let service = SecretService;

        assert_eq!(
            service.read_alias("default").as_str(),
            DEFAULT_COLLECTION_PATH
        );
        assert_eq!(service.read_alias("missing").as_str(), PROMPT_NONE);
        assert_eq!(service.collections().len(), 1);
    }

    #[test]
    fn secrets_bounds_reject_oversized_inputs() {
        let mut attrs = Attributes::new();
        for i in 0..=MAX_SECRET_ATTRIBUTES {
            attrs.insert(format!("k{i}"), "v".to_string());
        }
        let long = "x".repeat(MAX_SECRET_FIELD_BYTES + 1);
        let secret = vec![0u8; MAX_SECRET_BYTES + 1];

        assert!(validate_attributes(&attrs).is_err());
        assert!(validate_label(&long).is_err());
        assert!(validate_secret(&secret).is_err());
    }

    #[test]
    fn secrets_bridge_requests_match_auth_contract() {
        let query = serde_json::to_value(query_request(peer())).expect("query json");
        let search =
            serde_json::to_value(search_request(peer(), Attributes::new())).expect("search json");

        assert_eq!(query["surface"], "secrets");
        assert_eq!(query["op"], "secret.query");
        assert_eq!(search["op"], "secret.item.search");
    }

    #[test]
    fn secrets_bridge_reply_errors_are_clear() {
        let reply = br#"{"id":1,"ok":false,"error":{"code":"unsupported","message":"no store"}}"#;
        let message = parse_empty_reply(reply).expect_err("error reply");

        assert!(message.contains("unsupported"));
        assert!(message.contains("no store"));
    }
}
