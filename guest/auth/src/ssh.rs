pub const SSH_AGENT_FAILURE: u8 = 5;
pub const SSH_AGENTC_REQUEST_IDENTITIES: u8 = 11;
pub const SSH_AGENTC_SIGN_REQUEST: u8 = 13;
pub const SSH_AGENTC_ADD_IDENTITY: u8 = 17;
pub const SSH_AGENTC_REMOVE_IDENTITY: u8 = 18;
pub const SSH_AGENTC_REMOVE_ALL_IDENTITIES: u8 = 19;
pub const SSH_AGENTC_ADD_SMARTCARD_KEY: u8 = 20;
pub const SSH_AGENTC_REMOVE_SMARTCARD_KEY: u8 = 21;
pub const SSH_AGENTC_LOCK: u8 = 22;
pub const SSH_AGENTC_UNLOCK: u8 = 23;
pub const SSH_AGENTC_ADD_ID_CONSTRAINED: u8 = 25;
pub const SSH_AGENTC_ADD_SMARTCARD_KEY_CONSTRAINED: u8 = 26;
pub const SSH_AGENTC_EXTENSION: u8 = 27;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    Forward,
    Reject,
}

#[must_use]
pub fn decision(packet: &[u8], forwarding_allowed: bool) -> Decision {
    let Some((&kind, rest)) = packet.split_first() else {
        return Decision::Reject;
    };
    match kind {
        SSH_AGENTC_REQUEST_IDENTITIES | SSH_AGENTC_SIGN_REQUEST => Decision::Forward,
        SSH_AGENTC_EXTENSION => extension_decision(rest, forwarding_allowed),
        _ => Decision::Reject,
    }
}

#[must_use]
pub const fn failure_packet() -> [u8; 1] {
    [SSH_AGENT_FAILURE]
}

fn extension_decision(rest: &[u8], forwarding_allowed: bool) -> Decision {
    let Some((name, tail)) = read_string(rest) else {
        return Decision::Reject;
    };
    if name != b"session-bind@openssh.com" {
        return Decision::Forward;
    }
    let Some((_, tail)) = read_string(tail) else {
        return Decision::Reject;
    };
    let Some((_, tail)) = read_string(tail) else {
        return Decision::Reject;
    };
    let Some((_, tail)) = read_string(tail) else {
        return Decision::Reject;
    };
    let Some((&flag, _)) = tail.split_first() else {
        return Decision::Reject;
    };
    if flag != 0 && !forwarding_allowed {
        Decision::Reject
    } else {
        Decision::Forward
    }
}

fn read_string(input: &[u8]) -> Option<(&[u8], &[u8])> {
    let len_bytes: [u8; 4] = input.get(0..4)?.try_into().ok()?;
    let len = u32::from_be_bytes(len_bytes) as usize;
    let start = 4usize;
    let end = start.checked_add(len)?;
    let data = input.get(start..end)?;
    let rest = input.get(end..)?;
    Some((data, rest))
}

#[cfg(test)]
mod tests {
    use super::{Decision, SSH_AGENTC_ADD_IDENTITY, SSH_AGENTC_EXTENSION, decision};

    fn string(value: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        let len = u32::try_from(value.len()).expect("test extension string fits u32");
        out.extend_from_slice(&len.to_be_bytes());
        out.extend_from_slice(value);
        out
    }

    #[test]
    fn rejects_mutation_messages() {
        assert_eq!(
            decision(&[SSH_AGENTC_ADD_IDENTITY], false),
            Decision::Reject
        );
    }

    #[test]
    fn forwards_identity_query() {
        assert_eq!(decision(&[11], false), Decision::Forward);
    }

    #[test]
    fn rejects_forwarding_session_bind_when_disabled() {
        let mut packet = vec![SSH_AGENTC_EXTENSION];
        packet.extend_from_slice(&string(b"session-bind@openssh.com"));
        packet.extend_from_slice(&string(b"hostkey"));
        packet.extend_from_slice(&string(b"session"));
        packet.extend_from_slice(&string(b"signature"));
        packet.push(1);
        assert_eq!(decision(&packet, false), Decision::Reject);
        assert_eq!(decision(&packet, true), Decision::Forward);
    }
}
