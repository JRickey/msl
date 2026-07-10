import Foundation

public struct GuiRuntimeReq: Codable, Equatable, Sendable {
    public let distro: String
    public let user: String?

    public init(distro: String, user: String? = nil) {
        precondition(!distro.isEmpty, "GUI runtime distro must not be empty")
        self.distro = distro
        self.user = user
    }
}

public struct GuiLaunchReq: Codable, Equatable, Sendable {
    public let distro: String
    public let user: String?
    public let argv: [String]
    public let env: [String: String]
    public let cwd: String?

    public init(
        distro: String, user: String? = nil, argv: [String], env: [String: String] = [:],
        cwd: String? = nil
    ) {
        precondition(!distro.isEmpty, "GUI launch distro must not be empty")
        precondition(!argv.isEmpty, "GUI launch argv must not be empty")
        self.distro = distro
        self.user = user
        self.argv = argv
        self.env = env
        self.cwd = cwd
    }
}

public struct GuiRuntimeData: Codable, Equatable, Sendable {
    public let state: String
    public let runtimeDir: String
    public let waylandDisplay: String
    public let socketPresent: Bool
    public let pid: UInt32?
    public let logTail: String
    // A runtime is keyed by (distro, user); `windows` is the guest's bounded
    // live-window count. Optional so a v1.4 agent still decodes.
    public let user: String?
    public let windows: UInt32?

    enum CodingKeys: String, CodingKey {
        case state, pid, user, windows
        case runtimeDir = "runtime_dir"
        case waylandDisplay = "wayland_display"
        case socketPresent = "socket_present"
        case logTail = "log_tail"
    }

    public init(
        state: String, runtimeDir: String, waylandDisplay: String, socketPresent: Bool,
        pid: UInt32?, logTail: String, user: String? = nil, windows: UInt32? = nil
    ) {
        self.state = state
        self.runtimeDir = runtimeDir
        self.waylandDisplay = waylandDisplay
        self.socketPresent = socketPresent
        self.pid = pid
        self.logTail = logTail
        self.user = user
        self.windows = windows
    }
}

public struct GuiProbeData: Codable, Equatable, Sendable {
    public let runtime: GuiRuntimeData
    public let capabilities: [GuiCapabilityData]

    public init(runtime: GuiRuntimeData, capabilities: [GuiCapabilityData]) {
        self.runtime = runtime
        self.capabilities = capabilities
    }
}

public struct GuiCapabilityData: Codable, Equatable, Sendable {
    public let name: String
    public let present: Bool

    public init(name: String, present: Bool) {
        self.name = name
        self.present = present
    }
}
