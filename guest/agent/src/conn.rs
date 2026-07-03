//! Lock-free connection admission for the control plane: reserve-then-check so
//! a burst of connections can never drive the live count past the cap or abort.
//! The reservation is an RAII guard, so a dropped serve thread (including a
//! failed `thread::spawn`) always releases its slot.

use std::sync::atomic::{AtomicUsize, Ordering};

pub struct ConnSlot<'a> {
    counter: &'a AtomicUsize,
}

impl Drop for ConnSlot<'_> {
    fn drop(&mut self) {
        let prev = self.counter.fetch_sub(1, Ordering::SeqCst);
        debug_assert!(prev > 0, "release without a matching reserve");
    }
}

// Reserve a slot; `None` (and the reservation given back) when already at the cap.
pub fn try_reserve(counter: &AtomicUsize, max: usize) -> Option<ConnSlot<'_>> {
    let prev = counter.fetch_add(1, Ordering::SeqCst);
    if prev >= max {
        let _ = counter.fetch_sub(1, Ordering::SeqCst);
        return None;
    }
    Some(ConnSlot { counter })
}

#[cfg(test)]
mod tests {
    use super::try_reserve;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::thread;

    #[test]
    fn reserve_then_check_never_exceeds_cap_under_contention() {
        const MAX: usize = 16;
        const THREADS: usize = 64;
        let counter = Arc::new(AtomicUsize::new(0));
        // `live` counts only successful reservations, so its peak is the real
        // admission invariant (the raw counter transiently overshoots on refusal).
        let live = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        let mut handles = Vec::new();
        for _ in 0..THREADS {
            let counter = Arc::clone(&counter);
            let live = Arc::clone(&live);
            let peak = Arc::clone(&peak);
            handles.push(thread::spawn(move || {
                // bounded: fixed number of admission attempts per thread
                for _ in 0..1000 {
                    if let Some(_slot) = try_reserve(&counter, MAX) {
                        let held = live.fetch_add(1, Ordering::SeqCst) + 1;
                        peak.fetch_max(held, Ordering::SeqCst);
                        live.fetch_sub(1, Ordering::SeqCst);
                        // _slot drops here, releasing the reservation.
                    }
                }
            }));
        }
        // bounded: fixed thread set
        for handle in handles {
            handle.join().expect("worker thread");
        }
        assert_eq!(
            counter.load(Ordering::SeqCst),
            0,
            "all reservations released"
        );
        assert!(peak.load(Ordering::SeqCst) <= MAX, "cap never exceeded");
    }
}
