#![allow(
    clippy::missing_const_for_fn,
    clippy::missing_errors_doc,
    clippy::must_use_candidate,
    clippy::needless_pass_by_value,
    clippy::unnecessary_literal_bound,
    clippy::unused_self
)]

use std::collections::HashMap;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::Value as JsonValue;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

use crate::proto::{AUTH_VERSION, AuthPeer, peer_from_env};
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

pub type Attributes = HashMap<String, String>;
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
}

#[derive(Debug, serde::Serialize)]
pub struct SecretItemRequest {
    pub item_id: String,
}

#[derive(Debug, serde::Serialize)]
pub struct SecretItemSetRequest {
    pub item_id: String,
    pub secret_b64: String,
}

struct CreateRequest {
    label: String,
    attributes: Attributes,
    secret: Vec<u8>,
}

#[derive(Clone, Debug, serde::Deserialize, PartialEq, Eq)]
pub struct SecretItemSummary {
    pub id: String,
    pub collection: String,
    pub label: String,
    pub attributes: Attributes,
    pub created: u64,
    pub modified: u64,
}

#[derive(Debug, serde::Deserialize)]
struct SecretItemData {
    item: SecretItemSummary,
    #[serde(default)]
    secret_b64: Option<String>,
}

#[derive(Debug, serde::Deserialize)]
struct SecretItemsData {
    items: Vec<SecretItemSummary>,
}

#[derive(Clone, Debug)]
struct SecretBridge;

impl SecretBridge {
    fn create(
        &self,
        label: String,
        attributes: Attributes,
        secret: &[u8],
    ) -> Result<SecretItemSummary, String> {
        validate_label(&label)?;
        validate_attributes(&attributes)?;
        validate_secret(secret)?;
        let req = SecretItemCreateRequest {
            label,
            attributes,
            secret_b64: STANDARD.encode(secret),
        };
        let data: SecretItemData = Self::call("secret.item.create", req)?;
        Ok(data.item)
    }

    fn search(&self, attributes: Attributes) -> Result<Vec<SecretItemSummary>, String> {
        validate_attributes(&attributes)?;
        let data: SecretItemsData =
            Self::call("secret.item.search", SecretSearchRequest { attributes })?;
        Ok(data.items)
    }

    fn get(&self, item_id: &str) -> Result<(SecretItemSummary, Vec<u8>), String> {
        validate_item_id(item_id)?;
        let data: SecretItemData = Self::call("secret.item.get", item_request(item_id)?)?;
        let encoded = data
            .secret_b64
            .ok_or_else(|| "secret reply missing bytes".to_string())?;
        let secret = STANDARD
            .decode(encoded)
            .map_err(|e| format!("secret reply base64: {e}"))?;
        validate_secret(&secret)?;
        Ok((data.item, secret))
    }

    fn set(&self, item_id: &str, secret: &[u8]) -> Result<SecretItemSummary, String> {
        validate_item_id(item_id)?;
        validate_secret(secret)?;
        let req = SecretItemSetRequest {
            item_id: item_id.to_string(),
            secret_b64: STANDARD.encode(secret),
        };
        let data: SecretItemData = Self::call("secret.item.set", req)?;
        Ok(data.item)
    }

    fn delete(&self, item_id: &str) -> Result<(), String> {
        validate_item_id(item_id)?;
        let _: Option<JsonValue> = Self::call("secret.item.delete", item_request(item_id)?)?;
        Ok(())
    }

    fn call<T, R>(op: &'static str, req: T) -> Result<R, String>
    where
        T: serde::Serialize,
        R: serde::de::DeserializeOwned,
    {
        let peer = peer_from_env()?;
        let request = AuthRequest {
            v: AUTH_VERSION,
            id: 1,
            surface: "secrets",
            session: peer,
            op,
            req,
        };
        let reply = send_auth_request(&request)?;
        parse_data_reply(&reply)
    }
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
pub struct SecretService {
    bridge: SecretBridge,
}

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

    pub fn search_items(
        &self,
        attributes: Attributes,
        #[zbus(object_server)] server: &zbus::ObjectServer,
    ) -> Result<ItemPair, SecretError> {
        let items = self.bridge.search(attributes).map_err(map_bridge_error)?;
        let paths = register_items(server, &self.bridge, items)?;
        Ok((paths, Vec::new()))
    }

    pub fn get_secrets(
        &self,
        items: Vec<OwnedObjectPath>,
        session: OwnedObjectPath,
        #[zbus(object_server)] server: &zbus::ObjectServer,
    ) -> Result<SecretMap, SecretError> {
        validate_session(&session)?;
        if items.is_empty() {
            return Ok(HashMap::new());
        }
        let mut out = HashMap::new();
        for item_path in items {
            let item_id = item_id_from_path(&item_path)?;
            let (summary, secret) = self.bridge.get(&item_id).map_err(map_bridge_error)?;
            let registered = register_item(server, &self.bridge, summary)?;
            out.insert(registered, make_secret(secret));
        }
        Ok(out)
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
pub struct SecretCollection {
    bridge: SecretBridge,
}

#[zbus::interface(name = "org.freedesktop.Secret.Collection")]
impl SecretCollection {
    pub fn create_item(
        &self,
        properties: HashMap<String, OwnedValue>,
        secret: Secret,
        replace: bool,
        #[zbus(object_server)] server: &zbus::ObjectServer,
    ) -> Result<(OwnedObjectPath, OwnedObjectPath), SecretError> {
        validate_session(&secret.0)?;
        let request = create_request(&properties, secret, replace)?;
        let summary = if replace {
            self.replace_existing(&request)?
        } else {
            self.bridge
                .create(request.label, request.attributes, &request.secret)
                .map_err(map_bridge_error)?
        };
        let item_path = register_item(server, &self.bridge, summary)?;
        Ok((item_path, path(PROMPT_NONE)))
    }

    pub fn search_items(
        &self,
        attributes: Attributes,
        #[zbus(object_server)] server: &zbus::ObjectServer,
    ) -> Result<Vec<OwnedObjectPath>, SecretError> {
        let items = self.bridge.search(attributes).map_err(map_bridge_error)?;
        register_items(server, &self.bridge, items)
    }

    #[zbus(property)]
    pub fn items(&self) -> Vec<OwnedObjectPath> {
        self.bridge
            .search(HashMap::new())
            .map(|items| items.iter().map(item_path).collect())
            .unwrap_or_default()
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

impl SecretCollection {
    fn replace_existing(&self, request: &CreateRequest) -> Result<SecretItemSummary, SecretError> {
        let found = self
            .bridge
            .search(request.attributes.clone())
            .map_err(map_bridge_error)?;
        if let Some(existing) = found.first() {
            return self
                .bridge
                .set(&existing.id, &request.secret)
                .map_err(map_bridge_error);
        }
        self.bridge
            .create(
                request.label.clone(),
                request.attributes.clone(),
                &request.secret,
            )
            .map_err(map_bridge_error)
    }
}

#[derive(Clone, Debug)]
pub struct SecretItem {
    bridge: SecretBridge,
    summary: SecretItemSummary,
}

#[zbus::interface(name = "org.freedesktop.Secret.Item")]
impl SecretItem {
    pub fn get_secret(&self, session: OwnedObjectPath) -> Result<Secret, SecretError> {
        validate_session(&session)?;
        let (_, secret) = self
            .bridge
            .get(&self.summary.id)
            .map_err(map_bridge_error)?;
        Ok(make_secret(secret))
    }

    pub fn set_secret(&self, secret: Secret) -> Result<(), SecretError> {
        validate_session(&secret.0)?;
        validate_secret(&secret.2).map_err(SecretError::NotSupported)?;
        let _ = self
            .bridge
            .set(&self.summary.id, &secret.2)
            .map_err(map_bridge_error)?;
        Ok(())
    }

    pub fn delete(&self) -> Result<OwnedObjectPath, SecretError> {
        self.bridge
            .delete(&self.summary.id)
            .map_err(map_bridge_error)?;
        Ok(path(PROMPT_NONE))
    }

    #[zbus(property)]
    pub fn attributes(&self) -> Attributes {
        self.summary.attributes.clone()
    }

    #[zbus(property)]
    pub fn label(&self) -> &str {
        &self.summary.label
    }

    #[zbus(property)]
    pub fn locked(&self) -> bool {
        false
    }

    #[zbus(property)]
    pub fn created(&self) -> u64 {
        self.summary.created
    }

    #[zbus(property)]
    pub fn modified(&self) -> u64 {
        self.summary.modified
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
    let bridge = SecretBridge;
    let _connection = zbus::blocking::connection::Builder::session()
        .map_err(|e| format!("connect session bus: {e}"))?
        .serve_at(
            SERVICE_PATH,
            SecretService {
                bridge: bridge.clone(),
            },
        )
        .map_err(|e| format!("serve service object: {e}"))?
        .serve_at(
            DEFAULT_COLLECTION_PATH,
            SecretCollection {
                bridge: bridge.clone(),
            },
        )
        .map_err(|e| format!("serve collection object: {e}"))?
        .serve_at(DEFAULT_ALIAS_PATH, SecretCollection { bridge })
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
) -> Result<CreateRequest, SecretError> {
    let label = label_property(properties)?;
    let attributes = attribute_property(properties)?;
    validate_label(&label).map_err(SecretError::NotSupported)?;
    validate_attributes(&attributes).map_err(SecretError::NotSupported)?;
    validate_secret(&secret.2).map_err(SecretError::NotSupported)?;
    let _ = replace;
    Ok(CreateRequest {
        label,
        attributes,
        secret: secret.2,
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

fn attribute_property(properties: &HashMap<String, OwnedValue>) -> Result<Attributes, SecretError> {
    let Some(value) = properties.get("org.freedesktop.Secret.Item.Attributes") else {
        return Ok(HashMap::new());
    };
    let cloned = value
        .try_clone()
        .map_err(|e| SecretError::NotSupported(format!("invalid attributes: {e}")))?;
    Attributes::try_from(cloned)
        .map_err(|e| SecretError::NotSupported(format!("invalid attributes: {e}")))
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

fn map_bridge_error(message: String) -> SecretError {
    if message.contains("not_found") || message.contains("not found") {
        SecretError::NoSuchObject(message)
    } else {
        SecretError::NotSupported(message)
    }
}

fn path(value: &str) -> OwnedObjectPath {
    OwnedObjectPath::try_from(value).expect("static Secret Service path must be valid")
}

fn item_path(summary: &SecretItemSummary) -> OwnedObjectPath {
    path(&format!("{DEFAULT_COLLECTION_PATH}/{}", summary.id))
}

fn item_id_from_path(item_path: &OwnedObjectPath) -> Result<String, SecretError> {
    let prefix = format!("{DEFAULT_COLLECTION_PATH}/");
    let Some(id) = item_path.as_str().strip_prefix(&prefix) else {
        return Err(SecretError::NoSuchObject(
            "item path is outside login collection".to_string(),
        ));
    };
    validate_item_id(id).map_err(SecretError::NotSupported)?;
    Ok(id.to_string())
}

fn validate_item_id(item_id: &str) -> Result<(), String> {
    if item_id.is_empty() || item_id.len() > 128 {
        Err("invalid secret item id".to_string())
    } else {
        Ok(())
    }
}

fn item_request(item_id: &str) -> Result<SecretItemRequest, String> {
    validate_item_id(item_id)?;
    Ok(SecretItemRequest {
        item_id: item_id.to_string(),
    })
}

fn register_items(
    server: &zbus::ObjectServer,
    bridge: &SecretBridge,
    items: Vec<SecretItemSummary>,
) -> Result<Vec<OwnedObjectPath>, SecretError> {
    let mut paths = Vec::with_capacity(items.len());
    for summary in items {
        paths.push(register_item(server, bridge, summary)?);
    }
    Ok(paths)
}

fn register_item(
    server: &zbus::ObjectServer,
    bridge: &SecretBridge,
    summary: SecretItemSummary,
) -> Result<OwnedObjectPath, SecretError> {
    let object_path = item_path(&summary);
    zbus::block_on(server.at(
        object_path.as_str(),
        SecretItem {
            bridge: bridge.clone(),
            summary,
        },
    ))
    .map_err(SecretError::ZBus)?;
    Ok(object_path)
}

fn make_secret(secret: Vec<u8>) -> Secret {
    (
        path(DEFAULT_SESSION_PATH),
        Vec::new(),
        secret,
        "text/plain".to_string(),
    )
}

fn parse_data_reply<R>(reply: &[u8]) -> Result<R, String>
where
    R: serde::de::DeserializeOwned,
{
    let data = parse_empty_reply(reply)?.ok_or_else(|| "secret reply missing data".to_string())?;
    serde_json::from_value(data).map_err(|e| format!("secret reply data: {e}"))
}

fn send_auth_request<T: serde::Serialize>(request: &AuthRequest<T>) -> Result<Vec<u8>, String> {
    let bytes = serde_json::to_vec(request).map_err(|e| format!("auth encode: {e}"))?;
    send_auth_bytes(&bytes)
}

#[cfg(target_os = "linux")]
fn send_auth_bytes(bytes: &[u8]) -> Result<Vec<u8>, String> {
    use msl_wire::frame::{read_frame, write_frame};
    use vsock::{VsockAddr, VsockStream};

    let addr = VsockAddr::new(libc::VMADDR_CID_HOST, crate::proto::auth_port_from_env());
    let mut host = VsockStream::connect(&addr).map_err(|e| format!("connect auth bridge: {e}"))?;
    write_frame(&mut host, bytes).map_err(|e| format!("auth send: {e}"))?;
    read_frame(&mut host).map_err(|e| format!("auth reply: {e}"))
}

#[cfg(not(target_os = "linux"))]
fn send_auth_bytes(_bytes: &[u8]) -> Result<Vec<u8>, String> {
    Err("host Secret Service bridge is available only inside Linux sessions".to_string())
}

#[cfg(test)]
mod tests {
    use super::{
        Attributes, DEFAULT_COLLECTION_PATH, DEFAULT_SESSION_PATH, PROMPT_NONE, SecretBridge,
        SecretService, parse_empty_reply, query_request, search_request, validate_attributes,
        validate_label, validate_secret,
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
        let service = SecretService {
            bridge: SecretBridge,
        };
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
        let service = SecretService {
            bridge: SecretBridge,
        };

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
