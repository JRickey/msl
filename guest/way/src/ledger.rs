//! Per-commit latency ledger (surface protocol v0 instrumentation).
//!
//! A fixed-capacity ring the compositor fills at `commit` (client-commit + send
//! instants) and completes when the matching `present_ack` returns host
//! recv/present instants. `stats` dumps it as JSON for the prototype-gate
//! report. Pure logic — timestamps arrive as arguments.

use serde::Serialize;

pub const LEDGER_CAP: usize = 2048;

#[derive(Debug, Clone, Copy, Serialize)]
pub struct Entry {
    pub win: u32,
    pub seq: u32,
    pub t_client_commit_ns: u64,
    pub t_send_ns: u64,
    pub t_recv_ns: Option<u64>,
    pub t_present_ns: Option<u64>,
}

#[derive(Debug, Serialize)]
pub struct Stats {
    pub recorded: usize,
    pub acked: usize,
    pub commit_to_present_p50_ns: u64,
    pub commit_to_present_p95_ns: u64,
    pub send_to_present_p50_ns: u64,
    pub send_to_present_p95_ns: u64,
}

#[derive(Debug)]
pub struct Ledger {
    entries: Vec<Entry>,
    head: usize,
    len: usize,
    recorded: usize,
}

impl Ledger {
    #[must_use]
    pub fn new() -> Self {
        Self {
            entries: Vec::with_capacity(LEDGER_CAP),
            head: 0,
            len: 0,
            recorded: 0,
        }
    }

    pub fn record(&mut self, win: u32, seq: u32, t_client_commit_ns: u64, t_send_ns: u64) {
        debug_assert!(self.len <= LEDGER_CAP, "ring length exceeded capacity");
        debug_assert!(
            t_send_ns >= t_client_commit_ns,
            "send precedes client commit"
        );
        let entry = Entry {
            win,
            seq,
            t_client_commit_ns,
            t_send_ns,
            t_recv_ns: None,
            t_present_ns: None,
        };
        if self.entries.len() < LEDGER_CAP {
            self.entries.push(entry);
        } else {
            let slot = (self.head + self.len) % LEDGER_CAP;
            self.entries[slot] = entry;
        }
        if self.len == LEDGER_CAP {
            self.head = (self.head + 1) % LEDGER_CAP;
        } else {
            self.len += 1;
        }
        self.recorded = self.recorded.saturating_add(1);
    }

    /// Fill the newest un-acked entry matching `win`/`seq`. Returns whether a
    /// match was found so a stray ack cannot be mistaken for progress.
    pub fn merge_present_ack(
        &mut self,
        win: u32,
        seq: u32,
        t_recv_ns: u64,
        t_present_ns: u64,
    ) -> bool {
        debug_assert!(t_present_ns >= t_recv_ns, "present precedes host recv");
        debug_assert!(self.len <= LEDGER_CAP, "ring length exceeded capacity");
        let mut i = self.len;
        while i > 0 {
            i -= 1;
            let slot = (self.head + i) % LEDGER_CAP;
            let e = &mut self.entries[slot];
            if e.win == win && e.seq == seq && e.t_present_ns.is_none() {
                e.t_recv_ns = Some(t_recv_ns);
                e.t_present_ns = Some(t_present_ns);
                return true;
            }
        }
        false
    }

    #[must_use]
    pub fn stats(&self) -> Stats {
        debug_assert!(self.len <= self.entries.len(), "len exceeds backing store");
        let mut commit_lat = Vec::new();
        let mut send_lat = Vec::new();
        let mut acked = 0usize;
        for i in 0..self.len {
            let slot = (self.head + i) % LEDGER_CAP;
            let e = self.entries[slot];
            if let Some(present) = e.t_present_ns {
                acked += 1;
                commit_lat.push(present.saturating_sub(e.t_client_commit_ns));
                send_lat.push(present.saturating_sub(e.t_send_ns));
            }
        }
        Stats {
            recorded: self.recorded,
            acked,
            commit_to_present_p50_ns: percentile(&mut commit_lat, 50),
            commit_to_present_p95_ns: percentile(&mut commit_lat, 95),
            send_to_present_p50_ns: percentile(&mut send_lat, 50),
            send_to_present_p95_ns: percentile(&mut send_lat, 95),
        }
    }

    /// JSON dump for the `stats` message: aggregate summary only (the raw ring
    /// is bounded but large; the host keeps the per-frame CSV).
    #[must_use]
    pub fn dump_json(&self) -> String {
        let stats = self.stats();
        serde_json::to_string(&stats).unwrap_or_else(|_| "{}".to_string())
    }
}

impl Default for Ledger {
    fn default() -> Self {
        Self::new()
    }
}

fn percentile(samples: &mut [u64], pct: u32) -> u64 {
    debug_assert!(pct <= 100, "percentile out of range");
    if samples.is_empty() {
        return 0;
    }
    samples.sort_unstable();
    let last = samples.len() - 1;
    let idx = (last.saturating_mul(pct as usize)) / 100;
    debug_assert!(idx < samples.len(), "percentile index out of bounds");
    samples[idx]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_then_ack_completes_entry() {
        let mut l = Ledger::new();
        l.record(1, 10, 100, 150);
        assert!(l.merge_present_ack(1, 10, 200, 260));
        let s = l.stats();
        assert_eq!(s.recorded, 1);
        assert_eq!(s.acked, 1);
        assert_eq!(s.commit_to_present_p50_ns, 160);
        assert_eq!(s.send_to_present_p50_ns, 110);
    }

    #[test]
    fn stray_ack_is_rejected() {
        let mut l = Ledger::new();
        l.record(1, 10, 100, 150);
        assert!(!l.merge_present_ack(1, 99, 200, 260));
        assert!(!l.merge_present_ack(2, 10, 200, 260));
        assert_eq!(l.stats().acked, 0);
    }

    #[test]
    fn ring_overwrites_oldest_past_capacity() {
        let mut l = Ledger::new();
        let cap = u32::try_from(LEDGER_CAP).expect("cap fits u32");
        for seq in 0..(cap + 10) {
            l.record(1, seq, u64::from(seq), u64::from(seq) + 1);
        }
        let s = l.stats();
        assert_eq!(s.recorded, LEDGER_CAP + 10);
        assert!(
            !l.merge_present_ack(1, 0, 5, 6),
            "evicted seq must not match"
        );
        assert!(l.merge_present_ack(1, cap + 9, 5, 6));
    }

    #[test]
    fn percentiles_are_monotonic() {
        let mut l = Ledger::new();
        for seq in 0..100u32 {
            l.record(1, seq, 0, 0);
            l.merge_present_ack(1, seq, 0, u64::from(seq));
        }
        let s = l.stats();
        assert!(s.commit_to_present_p95_ns >= s.commit_to_present_p50_ns);
    }
}
