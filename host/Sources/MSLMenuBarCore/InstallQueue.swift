import Foundation
import MSLCore

public enum InstallRequest: Equatable, Sendable {
    case bundle(URL)
    case catalog(CatalogResolved, installedName: String)

    public var displayName: String {
        switch self {
        case .bundle(let url):
            return url.lastPathComponent
        case .catalog(let resolved, let installedName):
            if installedName == resolved.family.name { return resolved.selector }
            return "\(resolved.selector) as \(installedName)"
        }
    }
}

/// Bounded, serialized admission policy for `.msl` installs. One install runs at
/// a time; up to `capacity` more wait; further submissions are dropped so a
/// flood of double-clicks cannot grow the backlog without bound.
public struct InstallQueue: Equatable, Sendable {
    /// Outcome of a submission: it began immediately, joined the backlog, or was
    /// rejected because the backlog is already full.
    public enum Admission: Equatable, Sendable {
        case started
        case queued
        case dropped
    }

    public let capacity: Int
    public private(set) var active: InstallRequest?
    public private(set) var waiting: [InstallRequest]

    public init(capacity: Int) {
        precondition(capacity > 0, "install queue capacity must be positive")
        self.capacity = capacity
        self.active = nil
        self.waiting = []
    }

    public var isIdle: Bool { active == nil }

    /// Admit a job: run it now when idle, else queue it under the cap, else drop.
    public mutating func submit(_ request: InstallRequest) -> Admission {
        precondition(!request.displayName.isEmpty, "install request must have a display name")
        assert(waiting.count <= capacity, "backlog never exceeds capacity")
        if active == nil {
            active = request
            return .started
        }
        guard waiting.count < capacity else { return .dropped }
        waiting.append(request)
        return .queued
    }

    /// Retire the running job and promote the next; returns the new active job,
    /// or nil when the backlog is empty.
    @discardableResult
    public mutating func complete() -> InstallRequest? {
        assert(active != nil, "complete called with no active job")
        guard active != nil else { return nil }
        active = waiting.isEmpty ? nil : waiting.removeFirst()
        assert(waiting.count < capacity, "a promotion frees a backlog slot")
        return active
    }
}
