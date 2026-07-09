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

    enum CodingKeys: String, CodingKey {
        case state, pid
        case runtimeDir = "runtime_dir"
        case waylandDisplay = "wayland_display"
        case socketPresent = "socket_present"
        case logTail = "log_tail"
    }

    public init(
        state: String, runtimeDir: String, waylandDisplay: String, socketPresent: Bool,
        pid: UInt32?, logTail: String
    ) {
        self.state = state
        self.runtimeDir = runtimeDir
        self.waylandDisplay = waylandDisplay
        self.socketPresent = socketPresent
        self.pid = pid
        self.logTail = logTail
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
