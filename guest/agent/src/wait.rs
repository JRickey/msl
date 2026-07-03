//! Single-owner child reaping support. The reaper thread is the only `waitpid`
//! caller in the agent process (each session/exec intermediate waits its own
//! grandchild in its own process); exec spawners hand it their child's pid and
//! block for the delivered status. The spawn lock makes {fork, register} atomic
//! against the reaper's classify step so a child can never be reaped-then-lost.

use std::collections::HashMap;
use std::sync::{Condvar, LazyLock, Mutex, MutexGuard, PoisonError};
use std::time::Instant;

static SPAWN: Mutex<()> = Mutex::new(());
static WAIT: LazyLock<Waiters> = LazyLock::new(Waiters::new);

struct Waiters {
    slots: Mutex<HashMap<i32, Option<i32>>>,
    ready: Condvar,
}

impl Waiters {
    fn new() -> Self {
        Self {
            slots: Mutex::new(HashMap::new()),
            ready: Condvar::new(),
        }
    }
}

// Held by a spawner across {fork, register} and by the reaper across each
// classify step; never held across blocking I/O or the condvar wait.
pub fn spawn_lock() -> MutexGuard<'static, ()> {
    SPAWN.lock().unwrap_or_else(PoisonError::into_inner)
}

pub fn register(pid: i32) {
    assert!(pid > 0, "registered pid must be positive");
    if let Ok(mut slots) = WAIT.slots.lock() {
        let _ = slots.insert(pid, None);
    }
}

pub fn unregister(pid: i32) {
    if let Ok(mut slots) = WAIT.slots.lock() {
        let _ = slots.remove(&pid);
    }
}

// Reaper-side: hand a reaped status to its registered waiter, if any.
pub fn deliver(pid: i32, status: i32) -> bool {
    let Ok(mut slots) = WAIT.slots.lock() else {
        return false;
    };
    slots.get_mut(&pid).is_some_and(|slot| {
        *slot = Some(status);
        WAIT.ready.notify_all();
        true
    })
}

// Block until the reaper delivers this pid's status or the deadline passes.
pub fn wait(pid: i32, deadline: Instant) -> Option<i32> {
    let mut slots = WAIT.slots.lock().ok()?;
    // bounded by `deadline`: each iteration either returns or waits with timeout
    loop {
        match slots.get(&pid) {
            Some(Some(status)) => {
                let done = *status;
                let _ = slots.remove(&pid);
                return Some(done);
            }
            Some(None) => {}
            None => return None,
        }
        let now = Instant::now();
        if now >= deadline {
            let _ = slots.remove(&pid);
            return None;
        }
        let (guard, _timed_out) = WAIT.ready.wait_timeout(slots, deadline - now).ok()?;
        slots = guard;
    }
}

#[cfg(test)]
mod tests {
    use super::{deliver, register, unregister, wait};
    use std::thread;
    use std::time::{Duration, Instant};

    #[test]
    fn delivered_status_wakes_waiter() {
        register(9001);
        let handle = thread::spawn(|| {
            thread::sleep(Duration::from_millis(20));
            assert!(deliver(9001, 42));
        });
        let got = wait(9001, Instant::now() + Duration::from_secs(5));
        handle.join().expect("deliver thread");
        assert_eq!(got, Some(42));
    }

    #[test]
    fn wait_times_out_without_delivery() {
        register(9002);
        let got = wait(9002, Instant::now() + Duration::from_millis(30));
        assert_eq!(got, None);
    }

    #[test]
    fn deliver_to_unknown_pid_is_false() {
        assert!(!deliver(9003, 0));
    }

    #[test]
    fn unregister_prevents_delivery() {
        register(9004);
        unregister(9004);
        assert!(!deliver(9004, 7));
    }
}
