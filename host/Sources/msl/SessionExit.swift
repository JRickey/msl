import ArgumentParser
import MSLCore

/// Map a session outcome to a process exit status: the child's code, or the
/// shell convention 128+signal when a terminating signal ended the attach.
func sessionExitCode(_ outcome: AttachOutcome) -> Int32 {
    switch outcome {
    case .exited(let code): return code
    case .signaled(let sig): return 128 &+ sig
    }
}
