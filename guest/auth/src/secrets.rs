#![allow(
    clippy::missing_const_for_fn,
    clippy::missing_errors_doc,
    clippy::must_use_candidate,
    clippy::needless_pass_by_value,
    clippy::unnecessary_literal_bound,
    clippy::unused_self
)]

use std::collections::{BTreeSet, HashMap};
use std::sync::{Arc, Mutex};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::Value as JsonValue;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

use crate::proto::{
    AUTH_VERSION, Attributes, AuthReply, AuthRequest, MAX_SECRET_ATTRIBUTES, MAX_SECRET_BYTES,
    MAX_SECRET_FIELD_BYTES, SecretItemCreateRequest, SecretItemRequest, SecretItemSetRequest,
    SecretSearchRequest, peer_from_env,
};

pub const SERVICE_NAME: &str = "org.freedesktop.secrets";
pub const SERVICE_PATH: &str = "/org/freedesktop/secrets";
pub const DEFAULT_COLLECTION_PATH: &str = "/org/freedesktop/secrets/collection/login";
pub const DEFAULT_ALIAS_PATH: &str = "/org/freedesktop/secrets/aliases/default";
pub const SESSION_PATH_PREFIX: &str = "/org/freedesktop/secrets/session/";
pub const PROMPT_NONE: &str = "/";
pub const MAX_SESSIONS: usize = 64;

pub type Secret = (OwnedObjectPath, Vec<u8>, Vec<u8>, String);
pub type SecretMap = HashMap<OwnedObjectPath, Secret>;
pub type ItemPair = (Vec<OwnedObjectPath>, Vec<OwnedObjectPath>);

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

/// Live `org.freedesktop.Secret.Session` ids. Ids are never reused, so a stale
/// path from a closed session can never address a later session.
#[derive(Clone, Debug, Default)]
pub struct Sessions {
    state: Arc<Mutex<SessionState>>,
}

#[derive(Debug, Default)]
struct SessionState {
    next: u64,
    live: BTreeSet<u64>,
}

impl Sessions {
    fn open(&self) -> Result<u64, String> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "session registry is poisoned".to_string())?;
        if state.live.len() >= MAX_SESSIONS {
            return Err(format!("at most {MAX_SESSIONS} sessions may be open"));
        }
        let id = state.next;
        state.next = id.saturating_add(1);
        let fresh = state.live.insert(id);
        assert!(fresh, "monotonic session ids are never reused");
        assert!(state.live.len() <= MAX_SESSIONS, "session count is bounded");
        drop(state);
        Ok(id)
    }

    fn close(&self, id: u64) -> bool {
        self.state
            .lock()
            .is_ok_and(|mut state| state.live.remove(&id))
    }

    fn is_live(&self, path: &str) -> bool {
        let Some(id) = session_id_from_path(path) else {
            return false;
        };
        self.state
            .lock()
            .is_ok_and(|state| state.live.contains(&id))
    }
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
        assert!(
            secret.is_empty() || !req.secret_b64.is_empty(),
            "a non-empty secret encodes to non-empty base64"
        );
        let data: SecretItemData = Self::call("secret.item.create", req)?;
        Ok(data.item)
    }

    fn search(&self, attributes: Attributes) -> Result<Vec<SecretItemSummary>, String> {
        validate_attributes(&attributes)?;
        assert!(
            attributes.len() <= MAX_SECRET_ATTRIBUTES,
            "validated bound holds"
        );
        let data: SecretItemsData =
            Self::call("secret.item.search", SecretSearchRequest { attributes })?;
        Ok(data.items)
    }

    fn get(&self, item_id: &str) -> Result<(SecretItemSummary, Vec<u8>), String> {
        validate_item_id(item_id)?;
        let data: SecretItemData = Self::call("secret.item.get", item_request(item_id)?)?;
        assert!(!data.item.id.is_empty(), "host items carry a stable id");
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
        assert!(
            req.item_id == item_id,
            "the request carries the requested id"
        );
        let data: SecretItemData = Self::call("secret.item.set", req)?;
        Ok(data.item)
    }

    fn delete(&self, item_id: &str) -> Result<(), String> {
        validate_item_id(item_id)?;
        assert!(!item_id.is_empty(), "a validated item id is non-empty");
        let _: Option<JsonValue> = Self::call("secret.item.delete", item_request(item_id)?)?;
        Ok(())
    }

    fn call<T, R>(op: &'static str, req: T) -> Result<R, String>
    where
        T: serde::Serialize,
        R: serde::de::DeserializeOwned,
    {
        assert!(
            op.starts_with("secret."),
            "secrets surface ops are namespaced"
        );
        let peer = peer_from_env()?;
        assert!(
            !peer.token.is_empty(),
            "the session token is validated by env"
        );
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
    Timeout(String),
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

#[must_use]
pub fn session_path(id: u64) -> String {
    format!("{SESSION_PATH_PREFIX}{id}")
}

#[must_use]
pub fn session_id_from_path(path: &str) -> Option<u64> {
    assert!(!SESSION_PATH_PREFIX.is_empty(), "the prefix is a literal");
    let suffix = path.strip_prefix(SESSION_PATH_PREFIX)?;
    let id = suffix.parse::<u64>().ok()?;
    assert!(session_path(id) == path, "parsing a path is its inverse");
    Some(id)
}

#[derive(Clone, Debug)]
pub struct SecretSession {
    id: u64,
    sessions: Sessions,
}

#[zbus::interface(name = "org.freedesktop.Secret.Session")]
impl SecretSession {
    pub fn close(
        &self,
        #[zbus(object_server)] server: &zbus::ObjectServer,
    ) -> Result<(), SecretError> {
        let object = session_path(self.id);
        assert!(
            object.starts_with(SESSION_PATH_PREFIX),
            "session paths are namespaced"
        );
        if !self.sessions.close(self.id) {
            return Err(SecretError::NoSession(
                "session is already closed".to_string(),
            ));
        }
        let removed =
            zbus::block_on(server.remove::<Self, _>(object.as_str())).map_err(SecretError::ZBus)?;
        if !removed {
            return Err(SecretError::NoSuchObject(
                "session object was not registered".to_string(),
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug)]
pub struct SecretService {
    bridge: SecretBridge,
    sessions: Sessions,
}

#[zbus::interface(name = "org.freedesktop.Secret.Service")]
impl SecretService {
    pub fn open_session(
        &self,
        algorithm: &str,
        input: Value<'_>,
        #[zbus(object_server)] server: &zbus::ObjectServer,
    ) -> Result<(OwnedValue, OwnedObjectPath), SecretError> {
        let output = plain_session_output(algorithm, &input)?;
        let id = self.sessions.open().map_err(SecretError::NotSupported)?;
        let object = session_path(id);
        let session = SecretSession {
            id,
            sessions: self.sessions.clone(),
        };
        let attached = zbus::block_on(server.at(object.as_str(), session));
        if matches!(attached, Ok(true)) {
            return Ok((output, path(&object)));
        }
        let released = self.sessions.close(id);
        assert!(released, "a session that failed to serve releases its id");
        Err(attached.err().map_or_else(
            || SecretError::NotSupported("session path is already served".to_string()),
            SecretError::ZBus,
        ))
    }

    pub fn search_items(
        &self,
        attributes: Attributes,
        #[zbus(object_server)] server: &zbus::ObjectServer,
    ) -> Result<ItemPair, SecretError> {
        let items = self.bridge.search(attributes).map_err(map_bridge_error)?;
        let paths = self.register_items(server, items)?;
        Ok((paths, Vec::new()))
    }

    pub fn get_secrets(
        &self,
        items: Vec<OwnedObjectPath>,
        session: OwnedObjectPath,
        #[zbus(object_server)] server: &zbus::ObjectServer,
    ) -> Result<SecretMap, SecretError> {
        validate_session(&self.sessions, &session)?;
        if items.is_empty() {
            return Ok(HashMap::new());
        }
        let mut out = HashMap::new();
        for item_path in items {
            let item_id = item_id_from_path(&item_path)?;
            let (summary, secret) = self.bridge.get(&item_id).map_err(map_bridge_error)?;
            let registered = self.register_item(server, summary)?;
            let replaced = out.insert(registered, make_secret(&session, secret));
            assert!(replaced.is_none(), "each item path is registered once");
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

impl SecretService {
    fn register_items(
        &self,
        server: &zbus::ObjectServer,
        items: Vec<SecretItemSummary>,
    ) -> Result<Vec<OwnedObjectPath>, SecretError> {
        let count = items.len();
        let mut paths = Vec::with_capacity(count);
        for summary in items {
            paths.push(self.register_item(server, summary)?);
        }
        assert!(paths.len() == count, "every item registers one object path");
        Ok(paths)
    }

    fn register_item(
        &self,
        server: &zbus::ObjectServer,
        summary: SecretItemSummary,
    ) -> Result<OwnedObjectPath, SecretError> {
        register_item(server, &self.bridge, &self.sessions, summary)
    }
}

#[derive(Clone, Debug)]
pub struct SecretCollection {
    bridge: SecretBridge,
    sessions: Sessions,
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
        validate_session(&self.sessions, &secret.0)?;
        let request = create_request(&properties, secret)?;
        let summary = if replace {
            self.replace_existing(&request)?
        } else {
            self.bridge
                .create(request.label, request.attributes, &request.secret)
                .map_err(map_bridge_error)?
        };
        let item_path = register_item(server, &self.bridge, &self.sessions, summary)?;
        Ok((item_path, path(PROMPT_NONE)))
    }

    pub fn search_items(
        &self,
        attributes: Attributes,
        #[zbus(object_server)] server: &zbus::ObjectServer,
    ) -> Result<Vec<OwnedObjectPath>, SecretError> {
        let items = self.bridge.search(attributes).map_err(map_bridge_error)?;
        let mut paths = Vec::with_capacity(items.len());
        for summary in items {
            paths.push(register_item(
                server,
                &self.bridge,
                &self.sessions,
                summary,
            )?);
        }
        Ok(paths)
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
    /// `CreateItem(replace=true)` is a search-then-set at the D-Bus layer; the
    /// host `secret.item.create` operation has no replace field.
    fn replace_existing(&self, request: &CreateRequest) -> Result<SecretItemSummary, SecretError> {
        let found = self
            .bridge
            .search(request.attributes.clone())
            .map_err(map_bridge_error)?;
        if let Some(existing) = found.first() {
            assert!(!existing.id.is_empty(), "host items carry a stable id");
            return self
                .bridge
                .set(&existing.id, &request.secret)
                .map_err(map_bridge_error);
        }
        assert!(found.is_empty(), "no match means nothing to replace");
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
    sessions: Sessions,
    summary: SecretItemSummary,
}

#[zbus::interface(name = "org.freedesktop.Secret.Item")]
impl SecretItem {
    pub fn get_secret(&self, session: OwnedObjectPath) -> Result<Secret, SecretError> {
        validate_session(&self.sessions, &session)?;
        assert!(!self.summary.id.is_empty(), "a registered item has an id");
        let (_, secret) = self
            .bridge
            .get(&self.summary.id)
            .map_err(map_bridge_error)?;
        Ok(make_secret(&session, secret))
    }

    pub fn set_secret(&self, secret: Secret) -> Result<(), SecretError> {
        validate_session(&self.sessions, &secret.0)?;
        validate_secret(&secret.2).map_err(SecretError::NotSupported)?;
        let updated = self
            .bridge
            .set(&self.summary.id, &secret.2)
            .map_err(map_bridge_error)?;
        assert!(updated.id == self.summary.id, "the host updated this item");
        Ok(())
    }

    pub fn delete(&self) -> Result<OwnedObjectPath, SecretError> {
        assert!(!self.summary.id.is_empty(), "a registered item has an id");
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
    assert!(!message.is_empty(), "an error reply names its failure");
    Err(message)
}

fn run_daemon_result() -> Result<(), String> {
    require_session_bus()?;
    let bridge = SecretBridge;
    let sessions = Sessions::default();
    let _connection = zbus::blocking::connection::Builder::session()
        .map_err(|e| format!("connect session bus: {e}"))?
        .serve_at(
            SERVICE_PATH,
            SecretService {
                bridge: bridge.clone(),
                sessions: sessions.clone(),
            },
        )
        .map_err(|e| format!("serve service object: {e}"))?
        .serve_at(
            DEFAULT_COLLECTION_PATH,
            SecretCollection {
                bridge: bridge.clone(),
                sessions: sessions.clone(),
            },
        )
        .map_err(|e| format!("serve collection object: {e}"))?
        .serve_at(DEFAULT_ALIAS_PATH, SecretCollection { bridge, sessions })
        .map_err(|e| format!("serve alias object: {e}"))?
        .name(SERVICE_NAME)
        .map_err(|e| format!("own {SERVICE_NAME}: {e}"))?
        .build()
        .map_err(|e| format!("start Secret Service adapter: {e}"))?;
    std::thread::park();
    Ok(())
}

fn plain_session_output(algorithm: &str, input: &Value<'_>) -> Result<OwnedValue, SecretError> {
    assert!(
        SESSION_PATH_PREFIX.ends_with('/'),
        "session ids append to the prefix"
    );
    if algorithm != "plain" {
        return Err(SecretError::NotSupported(
            "only plain Secret Service sessions are supported".to_string(),
        ));
    }
    input
        .try_to_owned()
        .map_err(|e| SecretError::NotSupported(format!("invalid session value: {e}")))
}

fn create_request(
    properties: &HashMap<String, OwnedValue>,
    secret: Secret,
) -> Result<CreateRequest, SecretError> {
    let label = label_property(properties)?;
    let attributes = attribute_property(properties)?;
    validate_label(&label).map_err(SecretError::NotSupported)?;
    validate_attributes(&attributes).map_err(SecretError::NotSupported)?;
    validate_secret(&secret.2).map_err(SecretError::NotSupported)?;
    assert!(
        label.len() <= MAX_SECRET_FIELD_BYTES,
        "the label is bounded"
    );
    assert!(secret.2.len() <= MAX_SECRET_BYTES, "the secret is bounded");
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
    assert!(!name.is_empty(), "a validated field has a name");
    if value.len() > MAX_SECRET_FIELD_BYTES {
        return Err(format!("{name} exceeds {MAX_SECRET_FIELD_BYTES} bytes"));
    }
    Ok(())
}

fn validate_session(sessions: &Sessions, session: &OwnedObjectPath) -> Result<(), SecretError> {
    if sessions.is_live(session.as_str()) {
        Ok(())
    } else {
        Err(SecretError::NoSession(
            "unknown Secret Service session".to_string(),
        ))
    }
}

#[must_use]
pub fn is_timeout_message(message: &str) -> bool {
    message.starts_with("timeout:") || message.starts_with("timeout ")
}

#[must_use]
pub fn is_not_found_message(message: &str) -> bool {
    message.contains("not_found") || message.contains("not found")
}

fn map_bridge_error(message: String) -> SecretError {
    assert!(!message.is_empty(), "a bridge failure names its cause");
    if is_timeout_message(&message) {
        SecretError::Timeout(message)
    } else if is_not_found_message(&message) {
        SecretError::NoSuchObject(message)
    } else {
        SecretError::NotSupported(message)
    }
}

fn path(value: &str) -> OwnedObjectPath {
    assert!(value.starts_with('/'), "object paths are absolute");
    OwnedObjectPath::try_from(value).expect("static Secret Service path must be valid")
}

fn item_path(summary: &SecretItemSummary) -> OwnedObjectPath {
    assert!(!summary.id.is_empty(), "host items carry a stable id");
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
    assert!(
        !id.contains('/'),
        "item ids never nest below the collection"
    );
    Ok(id.to_string())
}

fn validate_item_id(item_id: &str) -> Result<(), String> {
    if item_id.is_empty() || item_id.len() > 128 || item_id.contains('/') {
        Err("invalid secret item id".to_string())
    } else {
        Ok(())
    }
}

fn item_request(item_id: &str) -> Result<SecretItemRequest, String> {
    validate_item_id(item_id)?;
    assert!(!item_id.is_empty(), "a validated item id is non-empty");
    Ok(SecretItemRequest {
        item_id: item_id.to_string(),
    })
}

fn register_item(
    server: &zbus::ObjectServer,
    bridge: &SecretBridge,
    sessions: &Sessions,
    summary: SecretItemSummary,
) -> Result<OwnedObjectPath, SecretError> {
    let object_path = item_path(&summary);
    assert!(
        object_path.as_str().starts_with(DEFAULT_COLLECTION_PATH),
        "items live under the login collection"
    );
    zbus::block_on(server.at(
        object_path.as_str(),
        SecretItem {
            bridge: bridge.clone(),
            sessions: sessions.clone(),
            summary,
        },
    ))
    .map_err(SecretError::ZBus)?;
    Ok(object_path)
}

fn make_secret(session: &OwnedObjectPath, secret: Vec<u8>) -> Secret {
    assert!(secret.len() <= MAX_SECRET_BYTES, "the secret is bounded");
    assert!(
        session.as_str().starts_with(SESSION_PATH_PREFIX),
        "a secret is returned against a live session"
    );
    (
        session.clone(),
        Vec::new(),
        secret,
        "text/plain".to_string(),
    )
}

fn parse_data_reply<R>(reply: &[u8]) -> Result<R, String>
where
    R: serde::de::DeserializeOwned,
{
    assert!(!reply.is_empty(), "a framed reply is never empty");
    let data = parse_empty_reply(reply)?.ok_or_else(|| "secret reply missing data".to_string())?;
    serde_json::from_value(data).map_err(|e| format!("secret reply data: {e}"))
}

fn send_auth_request<T: serde::Serialize>(request: &AuthRequest<T>) -> Result<Vec<u8>, String> {
    assert!(request.v == AUTH_VERSION, "requests carry the wire version");
    let bytes = serde_json::to_vec(request).map_err(|e| format!("auth encode: {e}"))?;
    assert!(!bytes.is_empty(), "an encoded request is never empty");
    send_auth_bytes(&bytes)
}

#[cfg(target_os = "linux")]
fn send_auth_bytes(bytes: &[u8]) -> Result<Vec<u8>, String> {
    use crate::proto::{connect_auth_host, io_message};
    use msl_wire::frame::{read_frame, write_frame};

    let mut host = connect_auth_host()?;
    write_frame(&mut host, bytes).map_err(|e| io_message("auth send", &e))?;
    read_frame(&mut host).map_err(|e| io_message("auth reply", &e))
}

#[cfg(not(target_os = "linux"))]
fn send_auth_bytes(_bytes: &[u8]) -> Result<Vec<u8>, String> {
    Err("host Secret Service bridge is available only inside Linux sessions".to_string())
}

#[cfg(test)]
mod tests {
    use super::{
        Attributes, DEFAULT_COLLECTION_PATH, MAX_SESSIONS, PROMPT_NONE, SESSION_PATH_PREFIX,
        SecretBridge, SecretError, SecretService, Sessions, map_bridge_error, parse_empty_reply,
        plain_session_output, session_id_from_path, session_path, validate_attributes,
        validate_label, validate_secret,
    };
    use crate::proto::{MAX_SECRET_ATTRIBUTES, MAX_SECRET_BYTES, MAX_SECRET_FIELD_BYTES};
    use zbus::zvariant::{OwnedObjectPath, Value};

    fn service() -> SecretService {
        SecretService {
            bridge: SecretBridge,
            sessions: Sessions::default(),
        }
    }

    #[test]
    fn secrets_plain_session_output_rejects_encrypted_algorithms() {
        let opened = plain_session_output("plain", &Value::from("")).expect("plain session");
        assert_eq!(opened, Value::from("").try_to_owned().expect("owned"));
        assert!(
            plain_session_output("dh-ietf1024-sha256-aes128-cbc-pkcs7", &Value::from("")).is_err()
        );
    }

    #[test]
    fn secrets_alias_and_collection_shape_are_stable() {
        let service = service();

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
    fn secrets_bridge_reply_errors_are_clear() {
        let reply = br#"{"id":1,"ok":false,"error":{"code":"unsupported","message":"no store"}}"#;
        let message = parse_empty_reply(reply).expect_err("error reply");

        assert!(message.contains("unsupported"));
        assert!(message.contains("no store"));
    }

    #[test]
    fn secrets_timeouts_do_not_masquerade_as_missing_items() {
        let timeout = map_bridge_error("timeout: auth reply exceeded 10s".to_string());
        let missing = map_bridge_error("not_found: no such item".to_string());
        let other = map_bridge_error("denied: policy".to_string());

        assert!(matches!(timeout, SecretError::Timeout(_)));
        assert!(matches!(missing, SecretError::NoSuchObject(_)));
        assert!(matches!(other, SecretError::NotSupported(_)));
    }

    #[test]
    fn secrets_session_paths_round_trip() {
        assert_eq!(session_path(3), format!("{SESSION_PATH_PREFIX}3"));
        assert_eq!(session_id_from_path(&session_path(3)), Some(3));
        assert_eq!(session_id_from_path("/org/freedesktop/secrets"), None);
        assert_eq!(
            session_id_from_path(&format!("{SESSION_PATH_PREFIX}a/b")),
            None
        );
    }

    #[test]
    fn secrets_sessions_are_bounded_and_close_drops_state() {
        let sessions = Sessions::default();
        let first = sessions.open().expect("first session");

        assert!(sessions.is_live(&session_path(first)));
        assert!(sessions.close(first));
        assert!(!sessions.is_live(&session_path(first)));
        assert!(!sessions.close(first));

        let mut opened = Vec::new();
        for _ in 0..MAX_SESSIONS {
            opened.push(sessions.open().expect("session within bound"));
        }
        assert_eq!(opened.len(), MAX_SESSIONS);
        assert!(sessions.open().is_err());
        assert!(!sessions.is_live(&session_path(first)));
    }

    #[test]
    fn secrets_reject_operations_on_closed_sessions() {
        let service = service();
        let id = service.sessions.open().expect("session");
        let live = OwnedObjectPath::try_from(session_path(id)).expect("path");

        assert!(super::validate_session(&service.sessions, &live).is_ok());
        assert!(service.sessions.close(id));
        let closed = super::validate_session(&service.sessions, &live);
        assert!(matches!(closed, Err(SecretError::NoSession(_))));
    }
}
