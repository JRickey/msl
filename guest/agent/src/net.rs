//! Listener discovery (`/proc/net/tcp{,6}`) and the loopback forward data plane:
//! find LISTEN sockets bound to loopback/wildcard, dial a guest port, then pump
//! bytes between a host-driven vsock connection and that TCP stream.

const MAX_PORTS: usize = 256;
const V6_WILDCARD: &str = "00000000000000000000000000000000";
const V6_LOOPBACK: &str = "00000000000000000000000001000000";

// A `/proc/net/tcp{,6}` LISTEN scan: state `0A`, bound to loopback or wildcard.
// v4 local addresses are little-endian hex, so 127.0.0.0/8 shows `..7F` last.
fn parse_proc_net_tcp(text: &str, v6: bool) -> Vec<u16> {
    let mut out: Vec<u16> = Vec::new();
    // bounded: one pass over a kernel-generated socket table, header skipped
    for line in text.lines().skip(1) {
        if let Some(port) = parse_listen_port(line, v6) {
            out.push(port);
        }
    }
    out
}

fn parse_listen_port(line: &str, v6: bool) -> Option<u16> {
    let mut fields = line.split_whitespace();
    let _sl = fields.next()?;
    let local = fields.next()?;
    let _remote = fields.next()?;
    let state = fields.next()?;
    if state != "0A" {
        return None;
    }
    let (addr, port_hex) = local.split_once(':')?;
    let port = u16::from_str_radix(port_hex, 16).ok()?;
    if port == 0 || !is_loopback_or_wildcard(addr, v6) {
        return None;
    }
    Some(port)
}

fn is_loopback_or_wildcard(addr: &str, v6: bool) -> bool {
    if v6 {
        return addr.eq_ignore_ascii_case(V6_WILDCARD) || addr.eq_ignore_ascii_case(V6_LOOPBACK);
    }
    if addr.len() != 8 {
        return false;
    }
    if addr.eq_ignore_ascii_case("00000000") {
        return true;
    }
    // Little-endian: the IP's first octet is the trailing byte pair; 127 == 0x7F.
    addr.get(6..8).is_some_and(|b| b.eq_ignore_ascii_case("7F"))
}

#[cfg(target_os = "linux")]
pub fn listeners() -> Result<crate::proto::NetListenersData, String> {
    let v4 = std::fs::read_to_string("/proc/net/tcp").map_err(|e| format!("read tcp: {e}"))?;
    let v6 = std::fs::read_to_string("/proc/net/tcp6").unwrap_or_default();
    let mut ports = parse_proc_net_tcp(&v4, false);
    ports.extend(parse_proc_net_tcp(&v6, true));
    ports.sort_unstable();
    ports.dedup();
    ports.truncate(MAX_PORTS);
    debug_assert!(ports.len() <= MAX_PORTS, "listener list stays capped");
    debug_assert!(ports.is_sorted(), "listener list stays sorted");
    Ok(crate::proto::NetListenersData { ports })
}

#[cfg(target_os = "linux")]
pub fn forward_connect(port: u16) -> Result<std::net::TcpStream, String> {
    use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, TcpStream};
    use std::time::Duration;
    if port == 0 {
        return Err("forward port must be > 0".to_string());
    }
    let timeout = Duration::from_secs(3);
    let v4 = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
    if let Ok(stream) = TcpStream::connect_timeout(&v4, timeout) {
        return Ok(stream);
    }
    let v6 = SocketAddr::from((Ipv6Addr::LOCALHOST, port));
    TcpStream::connect_timeout(&v6, timeout).map_err(|e| format!("connect 127.0.0.1:{port}: {e}"))
}

#[cfg(target_os = "linux")]
pub use linux::pump_streams;

#[cfg(target_os = "linux")]
mod linux {
    use std::io;
    use std::os::unix::io::RawFd;

    use crate::sys::{self, PollTarget};

    const CAP: usize = 64 * 1024;
    const CHUNK: usize = 16 * 1024;
    const MAX_DRAIN: usize = 16;
    const POLL_MS: i32 = 1000;

    // Bidirectional relay that owns and closes both fds; pumps until both
    // directions are dead. Unlike session::pump it reaps nothing.
    pub fn pump_streams(a: RawFd, b: RawFd) {
        assert!(a >= 0, "pump_streams needs a valid fd a");
        assert!(b >= 0, "pump_streams needs a valid fd b");
        let _ = sys::set_nonblocking(a);
        let _ = sys::set_nonblocking(b);
        let mut a2b: Vec<u8> = Vec::new();
        let mut b2a: Vec<u8> = Vec::new();
        let mut a_eof = false;
        let mut b_eof = false;
        let mut broken = false;
        // sanctioned infinite forward pump loop: exits on both-way EOF or dead peer
        loop {
            let a2b_live = !a_eof || !a2b.is_empty();
            let b2a_live = !b_eof || !b2a.is_empty();
            if broken || (!a2b_live && !b2a_live) {
                break;
            }
            let mut t = [
                PollTarget::read_write(a, !a_eof && a2b.len() < CAP, !b2a.is_empty()),
                PollTarget::read_write(b, !b_eof && b2a.len() < CAP, !a2b.is_empty()),
            ];
            if sys::poll_fds(&mut t, POLL_MS).is_err() {
                break;
            }
            drain_side(a, &mut a2b, &t[0], &mut a_eof);
            drain_side(b, &mut b2a, &t[1], &mut b_eof);
            // A write error means that peer is gone, so tear the whole proxy down:
            // its inbound buffer is undeliverable and a surviving peer would spin
            // forever without ever reaching EOF. The `|| hup` term forces the
            // attempt when poll reports the error as HUP, not POLLOUT; a plain
            // read-EOF never lands here, so graceful half-close still drains.
            if (t[0].writable || t[0].hup) && flush(a, &mut b2a).is_err() {
                broken = true;
            }
            if (t[1].writable || t[1].hup) && flush(b, &mut a2b).is_err() {
                broken = true;
            }
        }
        sys::close_fd(a);
        sys::close_fd(b);
    }

    fn drain_side(fd: RawFd, buf: &mut Vec<u8>, target: &PollTarget, eof: &mut bool) {
        debug_assert!(fd >= 0, "drain needs a valid fd");
        if !target.ready && !target.hup {
            return;
        }
        let mut tmp = [0u8; CHUNK];
        // bounded: at most MAX_DRAIN chunks per poll cycle
        for _ in 0..MAX_DRAIN {
            if buf.len() >= CAP {
                break;
            }
            let room = (CAP - buf.len()).min(CHUNK);
            match sys::read_fd(fd, &mut tmp[..room]) {
                Ok(0) => {
                    *eof = true;
                    break;
                }
                Ok(n) => buf.extend_from_slice(&tmp[..n]),
                Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => {
                    if target.hup {
                        *eof = true;
                    }
                    break;
                }
                Err(_) => {
                    *eof = true;
                    break;
                }
            }
        }
    }

    fn flush(fd: RawFd, buf: &mut Vec<u8>) -> io::Result<()> {
        debug_assert!(fd >= 0, "flush needs a valid fd");
        if buf.is_empty() {
            return Ok(());
        }
        match sys::write_fd(fd, buf) {
            Ok(0) => Ok(()),
            Ok(n) => {
                debug_assert!(n <= buf.len(), "write cannot exceed buffer");
                let _ = buf.drain(..n);
                Ok(())
            }
            Err(ref e) if e.kind() == io::ErrorKind::WouldBlock => Ok(()),
            Err(e) => Err(e),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::parse_proc_net_tcp;

    const V4_SAMPLE: &str = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n\
   0: 0100007F:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1 1 0\n\
   1: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1 1 0\n\
   2: 0100007F:C1AC 0100007F:0016 01 00000000:00000000 00:00000000 00000000  1000        0 1 1 0\n\
   3: 0201A8C0:0035 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1 1 0\n";

    #[test]
    fn v4_keeps_loopback_and_wildcard_listeners_only() {
        let ports = parse_proc_net_tcp(V4_SAMPLE, false);
        // 0x0016 = 22 (loopback), 0x1F90 = 8080 (wildcard). The 0x0035 = 53 bind
        // on 192.168.1.2 is interface-specific and excluded; the ESTABLISHED
        // (st 01) row is skipped.
        assert_eq!(ports, vec![22, 8080]);
    }

    #[test]
    fn v6_keeps_loopback_and_wildcard_only() {
        let text = "  sl  local_address ...\n\
   0: 00000000000000000000000000000000:0050 00000000000000000000000000000000:0000 0A x\n\
   1: 00000000000000000000000001000000:0BB8 00000000000000000000000000000000:0000 0A x\n\
   2: 000080FE00000000FF57291418E0BEFE:1F40 00000000000000000000000000000000:0000 0A x\n";
        let mut ports = parse_proc_net_tcp(text, true);
        ports.sort_unstable();
        // 0x0050 = 80 (::), 0x0BB8 = 3000 (::1); the link-local bind is excluded.
        assert_eq!(ports, vec![80, 3000]);
    }
}
