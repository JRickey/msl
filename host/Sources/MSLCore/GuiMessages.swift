import Foundation

/// Guest→host `hello` {version, distro}; the host answers `hello_ack`.
public struct GuiHello: Codable, Sendable, Equatable {
    public let version: UInt32
    public let distro: String

    public init(version: UInt32, distro: String) {
        self.version = version
        self.distro = distro
    }
}

/// local display facts. `output_w`/`output_h` are the adopted logical-pixel
/// output size, validated to `1...16384` and absent from a peer that proposes
/// none.
public struct GuiHelloAck: Codable, Sendable, Equatable {
    public let version: UInt32
    public let scale: Double
    public let refreshHz: Double
    public let outputW: UInt32?
    public let outputH: UInt32?

    enum CodingKeys: String, CodingKey {
        case version, scale
        case refreshHz = "refresh_hz"
        case outputW = "output_w"
        case outputH = "output_h"
    }

    public init(
        version: UInt32, scale: Double, refreshHz: Double, outputW: UInt32? = nil,
        outputH: UInt32? = nil
    ) {
        precondition(scale > 0, "display scale must be positive")
        precondition(refreshHz > 0, "refresh rate must be positive")
        self.version = version
        self.scale = scale
        self.refreshHz = refreshHz
        self.outputW = outputW
        self.outputH = outputH
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(UInt32.self, forKey: .version)
        scale = try container.decode(Double.self, forKey: .scale)
        refreshHz = try container.decode(Double.self, forKey: .refreshHz)
        let width = try container.decodeIfPresent(UInt32.self, forKey: .outputW)
        let height = try container.decodeIfPresent(UInt32.self, forKey: .outputH)
        try GuiHelloAck.checkOutput(width)
        try GuiHelloAck.checkOutput(height)
        outputW = width
        outputH = height
    }

    private static func checkOutput(_ dim: UInt32?) throws {
        guard let value = dim else { return }
        assert(GuiProto.helloOutputMax > 1, "output ceiling exceeds the floor")
        guard value >= 1, value <= GuiProto.helloOutputMax else {
            throw MSLError.protocolMismatch("hello_ack output dimension \(value) out of range")
        }
    }
}

/// application-identity fields (`x11`, `pid`, `class`, `instance`,
/// `transient_for`, `modal`). Guest strings are untrusted, so the decoder caps
/// `title`/`app_id`/`class`/`instance` at 512 bytes and strips control
/// characters.
public struct GuiWinNew: Codable, Sendable, Equatable {
    public let win: UInt32
    public let appID: String
    public let title: String
    public let width: UInt32
    public let height: UInt32
    public let scale: Double
    public let x11: Bool?
    public let pid: UInt32?
    public let windowClass: String?
    public let instance: String?
    public let transientFor: UInt32?
    public let modal: Bool?

    enum CodingKeys: String, CodingKey {
        case win, title, scale, x11, pid, instance, modal
        case appID = "app_id"
        case width = "w"
        case height = "h"
        case windowClass = "class"
        case transientFor = "transient_for"
    }

    public init(
        win: UInt32, appID: String, title: String, width: UInt32, height: UInt32, scale: Double,
        x11: Bool? = nil, pid: UInt32? = nil, windowClass: String? = nil, instance: String? = nil,
        transientFor: UInt32? = nil, modal: Bool? = nil
    ) {
        self.win = win
        self.appID = appID
        self.title = title
        self.width = width
        self.height = height
        self.scale = scale
        self.x11 = x11
        self.pid = pid
        self.windowClass = windowClass
        self.instance = instance
        self.transientFor = transientFor
        self.modal = modal
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        win = try container.decode(UInt32.self, forKey: .win)
        width = try container.decode(UInt32.self, forKey: .width)
        height = try container.decode(UInt32.self, forKey: .height)
        scale = try container.decode(Double.self, forKey: .scale)
        appID = GuiProto.sanitize(
            try container.decode(String.self, forKey: .appID), cap: GuiProto.winStrMax)
        title = GuiProto.sanitize(
            try container.decode(String.self, forKey: .title), cap: GuiProto.winStrMax)
        windowClass = try GuiWinNew.sanitized(container, .windowClass)
        instance = try GuiWinNew.sanitized(container, .instance)
        x11 = try container.decodeIfPresent(Bool.self, forKey: .x11)
        pid = try container.decodeIfPresent(UInt32.self, forKey: .pid)
        transientFor = try container.decodeIfPresent(UInt32.self, forKey: .transientFor)
        modal = try container.decodeIfPresent(Bool.self, forKey: .modal)
    }

    private static func sanitized(
        _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) throws -> String? {
        assert(GuiProto.winStrMax > 0, "string cap must be positive")
        guard let raw = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return GuiProto.sanitize(raw, cap: GuiProto.winStrMax)
    }
}

/// Guest→host window reference used by `win_map`/`win_unmap`/`win_destroy`.
public struct GuiWinRef: Codable, Sendable, Equatable {
    public let win: UInt32
    public init(win: UInt32) { self.win = win }
}

/// Guest→host `win_title` {win, title}.
public struct GuiWinTitle: Codable, Sendable, Equatable {
    public let win: UInt32
    public let title: String

    public init(win: UInt32, title: String) {
        self.win = win
        self.title = title
    }
}

/// Guest→host `cursor_named` {win, name} (v0: default/text/pointer/grab).
public struct GuiCursorNamed: Codable, Sendable, Equatable {
    public let win: UInt32
    public let name: String

    public init(win: UInt32, name: String) {
        self.win = win
        self.name = name
    }
}

/// Guest→host `win_limits` {win, min_w, min_h, max_w, max_h}: the client's
/// size hints in logical points; 0 on an axis means unconstrained.
public struct GuiWinLimits: Codable, Sendable, Equatable {
    public let win: UInt32
    public let minWidth: UInt32
    public let minHeight: UInt32
    public let maxWidth: UInt32
    public let maxHeight: UInt32

    enum CodingKeys: String, CodingKey {
        case win
        case minWidth = "min_w"
        case minHeight = "min_h"
        case maxWidth = "max_w"
        case maxHeight = "max_h"
    }

    public init(
        win: UInt32, minWidth: UInt32, minHeight: UInt32, maxWidth: UInt32, maxHeight: UInt32
    ) {
        self.win = win
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }
}

/// Host→guest `configure` {win, w, h, serial, states[]} in logical px.
public struct GuiConfigure: Codable, Sendable, Equatable {
    public let win: UInt32
    public let width: UInt32
    public let height: UInt32
    public let serial: UInt32
    public let states: [String]

    enum CodingKeys: String, CodingKey {
        case win, serial, states
        case width = "w"
        case height = "h"
    }

    public init(win: UInt32, width: UInt32, height: UInt32, serial: UInt32, states: [String]) {
        self.win = win
        self.width = width
        self.height = height
        self.serial = serial
        self.states = states
    }
}

/// Host→guest `close` {win}.
public struct GuiClose: Codable, Sendable, Equatable {
    public let win: UInt32
    public init(win: UInt32) { self.win = win }
}

/// Host→guest `pointer` {win, kind, x, y, button, state, dx, dy, t_host_ns}.
/// Coordinates are window-local logical px, y measured from the top.
public struct GuiPointer: Codable, Sendable, Equatable {
    public let win: UInt32
    public let kind: String
    public let posX: Double
    public let posY: Double
    public let button: UInt32
    public let state: UInt32
    public let dx: Double
    public let dy: Double
    public let tHostNs: UInt64

    enum CodingKeys: String, CodingKey {
        case win, kind, button, state, dx, dy
        case posX = "x"
        case posY = "y"
        case tHostNs = "t_host_ns"
    }

    public init(
        win: UInt32, kind: String, posX: Double, posY: Double, button: UInt32, state: UInt32,
        dx: Double, dy: Double, tHostNs: UInt64
    ) {
        self.win = win
        self.kind = kind
        self.posX = posX
        self.posY = posY
        self.button = button
        self.state = state
        self.dx = dx
        self.dy = dy
        self.tHostNs = tHostNs
    }
}

/// Host→guest `key` {win, keycode(evdev), state, t_host_ns}.
public struct GuiKey: Codable, Sendable, Equatable {
    public let win: UInt32
    public let keycode: UInt32
    public let state: UInt32
    public let tHostNs: UInt64

    enum CodingKeys: String, CodingKey {
        case win, keycode, state
        case tHostNs = "t_host_ns"
    }

    public init(win: UInt32, keycode: UInt32, state: UInt32, tHostNs: UInt64) {
        self.win = win
        self.keycode = keycode
        self.state = state
        self.tHostNs = tHostNs
    }
}

/// Host→guest `present_ack` {win, seq, t_recv_ns, t_present_ns} (host clocks).
public struct GuiPresentAck: Codable, Sendable, Equatable {
    public let win: UInt32
    public let seq: UInt32
    public let tRecvNs: UInt64
    public let tPresentNs: UInt64

    enum CodingKeys: String, CodingKey {
        case win, seq
        case tRecvNs = "t_recv_ns"
        case tPresentNs = "t_present_ns"
    }

    public init(win: UInt32, seq: UInt32, tRecvNs: UInt64, tPresentNs: UInt64) {
        self.win = win
        self.seq = seq
        self.tRecvNs = tRecvNs
        self.tPresentNs = tPresentNs
    }
}

/// One damage rectangle inside a commit's buffer.
public struct GuiRect: Sendable, Equatable {
    public let originX: UInt32
    public let originY: UInt32
    public let width: UInt32
    public let height: UInt32
}

/// A parsed `commit`: header fields, damage rects, and the row-packed pixels.
/// `serial` is the newest host configure serial the client had acked when the
/// buffer was committed (0 = none yet); the size-authority machine reads it.
public struct GuiCommit: Sendable, Equatable {
    public let win: UInt32
    public let seq: UInt32
    public let width: UInt32
    public let height: UInt32
    public let stride: UInt32
    public let format: UInt32
    public let scaleE12: UInt32
    public let serial: UInt32
    public let rects: [GuiRect]
    public let tClientCommitNs: UInt64
    public let tSendNs: UInt64
    public let pixels: Data

    /// Fractional scale the guest rendered at (scale_e12 is scale × 4096).
    public var scale: Double { Double(scaleE12) / 4096.0 }
}
