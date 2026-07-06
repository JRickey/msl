//! Memory telemetry (`/proc/meminfo`, `/proc/pressure/memory`) and best-effort
//! hygiene (sync + compaction + cache drop). The line parsers are pure so they
//! unit-test off Linux; the effectful reclaim/tuning paths are Linux-gated.

use crate::proto::MemStatsData;

const COMPACT_MEMORY_PATH: &str = "/proc/sys/vm/compact_memory";
const DROP_CACHES_PATH: &str = "/proc/sys/vm/drop_caches";
const DROP_PAGE_CACHE_ONLY: &str = "1";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ReclaimWrite {
    path: &'static str,
    value: &'static str,
}

pub fn mem_stats() -> Result<MemStatsData, String> {
    let meminfo =
        std::fs::read_to_string("/proc/meminfo").map_err(|e| format!("read meminfo: {e}"))?;
    let (mem_total_kib, mem_available_kib, swap_total_kib, swap_free_kib) =
        parse_meminfo(&meminfo)?;
    let (psi_some_avg10, psi_full_avg10) = read_psi();
    debug_assert!(mem_total_kib > 0, "MemTotal must be positive");
    debug_assert!(swap_free_kib <= swap_total_kib, "free swap within total");
    Ok(MemStatsData {
        mem_total_kib,
        mem_available_kib,
        swap_total_kib,
        swap_free_kib,
        psi_some_avg10,
        psi_full_avg10,
    })
}

// Missing PSI file (kernel without pressure stalls) reads as zero pressure.
fn read_psi() -> (f64, f64) {
    std::fs::read_to_string("/proc/pressure/memory")
        .ok()
        .and_then(|text| parse_psi(&text).ok())
        .unwrap_or((0.0, 0.0))
}

fn parse_meminfo(text: &str) -> Result<(u64, u64, u64, u64), String> {
    debug_assert!(!text.is_empty(), "meminfo text must be non-empty");
    let mem_total = find_kib(text, "MemTotal").ok_or("meminfo missing MemTotal")?;
    let mem_available = find_kib(text, "MemAvailable").ok_or("meminfo missing MemAvailable")?;
    let swap_total = find_kib(text, "SwapTotal").ok_or("meminfo missing SwapTotal")?;
    let swap_free = find_kib(text, "SwapFree").ok_or("meminfo missing SwapFree")?;
    debug_assert!(mem_total >= mem_available, "MemAvailable within MemTotal");
    Ok((mem_total, mem_available, swap_total, swap_free))
}

// The kB value of a `Label:  <n> kB` meminfo line; `None` if the label is absent.
fn find_kib(text: &str, key: &str) -> Option<u64> {
    debug_assert!(!key.is_empty(), "meminfo key must be non-empty");
    // bounded: one pass over a small kernel-generated table
    for line in text.lines() {
        let Some(rest) = line.strip_prefix(key) else {
            continue;
        };
        let Some(tail) = rest.strip_prefix(':') else {
            continue;
        };
        return tail.split_whitespace().next().and_then(|v| v.parse().ok());
    }
    None
}

// PSI lines read `some avg10=0.00 avg60=0.00 avg300=0.00 total=0`; we keep the
// two avg10 fields the balloon ladder reasons about.
fn parse_psi(text: &str) -> Result<(f64, f64), String> {
    debug_assert!(!text.is_empty(), "psi text must be non-empty");
    let some = psi_avg10(text, "some").ok_or("psi missing some avg10")?;
    let full = psi_avg10(text, "full").ok_or("psi missing full avg10")?;
    debug_assert!(some >= 0.0 && full >= 0.0, "psi averages are non-negative");
    Ok((some, full))
}

fn psi_avg10(text: &str, label: &str) -> Option<f64> {
    debug_assert!(!label.is_empty(), "psi label must be non-empty");
    // bounded: one pass over the two-line pressure table
    for line in text.lines() {
        let Some(rest) = line.strip_prefix(label) else {
            continue;
        };
        return field_after(rest, "avg10=");
    }
    None
}

fn field_after(rest: &str, prefix: &str) -> Option<f64> {
    debug_assert!(!prefix.is_empty(), "field prefix must be non-empty");
    // bounded: one pass over a single whitespace-split PSI line
    for tok in rest.split_whitespace() {
        if let Some(v) = tok.strip_prefix(prefix) {
            return v.parse().ok();
        }
    }
    None
}

const fn reclaim_writes() -> [ReclaimWrite; 2] {
    [
        ReclaimWrite {
            path: COMPACT_MEMORY_PATH,
            value: "1",
        },
        ReclaimWrite {
            path: DROP_CACHES_PATH,
            value: DROP_PAGE_CACHE_ONLY,
        },
    ]
}

#[cfg(target_os = "linux")]
#[allow(clippy::unnecessary_wraps)] // Result mirrors the fallible non-linux stub
pub fn reclaim() -> Result<(), String> {
    sync_now();
    // drop_caches=1 preserves dentries/inodes; virtiofs metadata is costly to refill.
    for write in reclaim_writes() {
        best_effort_write(write.path, write.value);
    }
    Ok(())
}

#[cfg(target_os = "linux")]
#[allow(unsafe_code)] // libc::sync() is an infallible C ABI flush; no safe wrapper exists
fn sync_now() {
    unsafe {
        libc::sync();
    }
}

#[cfg(target_os = "linux")]
fn best_effort_write(path: &str, value: &str) {
    debug_assert!(path.starts_with('/'), "reclaim path must be absolute");
    debug_assert!(!value.is_empty(), "reclaim value must be non-empty");
    if !std::path::Path::new(path).exists() {
        return;
    }
    match std::fs::write(path, value) {
        Ok(()) => crate::log::info(&format!("reclaim: wrote {value} to {path}")),
        Err(e) => crate::log::warn(&format!("reclaim: {path}: {e}")),
    }
}

#[cfg(target_os = "linux")]
pub fn boot_tuning() {
    const LRU_GEN: &str = "/sys/kernel/mm/lru_gen/enabled";
    if !std::path::Path::new(LRU_GEN).exists() {
        return;
    }
    match std::fs::write(LRU_GEN, "y") {
        Ok(()) => crate::log::info("boot tuning: enabled multi-gen LRU"),
        Err(e) => crate::log::warn(&format!("boot tuning: lru_gen: {e}")),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        COMPACT_MEMORY_PATH, DROP_CACHES_PATH, DROP_PAGE_CACHE_ONLY, ReclaimWrite, parse_meminfo,
        parse_psi, reclaim_writes,
    };

    const MEMINFO: &str = "MemTotal:       16307840 kB\n\
MemFree:         2043216 kB\n\
MemAvailable:   12094432 kB\n\
Buffers:          102400 kB\n\
SwapTotal:       1048576 kB\n\
SwapFree:         524288 kB\n";

    #[test]
    fn meminfo_extracts_four_fields() {
        let (total, avail, swap_total, swap_free) = parse_meminfo(MEMINFO).expect("parse");
        assert_eq!(total, 16_307_840);
        assert_eq!(avail, 12_094_432);
        assert_eq!(swap_total, 1_048_576);
        assert_eq!(swap_free, 524_288);
    }

    #[test]
    fn meminfo_errors_on_missing_field() {
        let err = parse_meminfo("MemTotal: 1 kB\nMemAvailable: 1 kB\n").expect_err("missing swap");
        assert!(err.contains("Swap"));
    }

    #[test]
    fn meminfo_does_not_confuse_prefixed_labels() {
        // `MemFree` must not satisfy a `MemF`-style prefix probe for another key.
        let text = "MemTotal: 100 kB\nMemAvailable: 40 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n";
        let (total, avail, _, _) = parse_meminfo(text).expect("parse");
        assert_eq!(total, 100);
        assert_eq!(avail, 40);
    }

    #[test]
    fn psi_reads_some_and_full_avg10() {
        let text = "some avg10=1.50 avg60=0.30 avg300=0.10 total=42\n\
full avg10=0.25 avg60=0.05 avg300=0.00 total=7\n";
        let (some, full) = parse_psi(text).expect("parse");
        assert!((some - 1.50).abs() < 1e-9);
        assert!((full - 0.25).abs() < 1e-9);
    }

    #[test]
    fn psi_errors_without_full_line() {
        let err =
            parse_psi("some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n").expect_err("no full");
        assert!(err.contains("full"));
    }

    #[test]
    fn reclaim_plan_preserves_metadata_cache() {
        let writes = reclaim_writes();
        assert_eq!(writes.len(), 2);
        assert_eq!(
            writes[0],
            ReclaimWrite {
                path: COMPACT_MEMORY_PATH,
                value: "1"
            }
        );
        assert_eq!(writes[1].path, DROP_CACHES_PATH);
        assert_eq!(writes[1].value, DROP_PAGE_CACHE_ONLY);
        assert_ne!(writes[1].value, "3");
    }
}
