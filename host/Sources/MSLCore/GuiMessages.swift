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

/// Host→guest `hello_ack` {version, scale, refresh_hz}: local display facts.
public struct GuiHelloAck: Codable, Sendable, Equatable {
    public let version: UInt32
    public let scale: Double
    public let refreshHz: Double

    enum CodingKeys: String, CodingKey {
        case version, scale
        case refreshHz = "refresh_hz"
    }

    public init(version: UInt32, scale: Double, refreshHz: Double) {
        precondition(scale > 0, "display scale must be positive")
        precondition(refreshHz > 0, "refresh rate must be positive")
        self.version = version
        self.scale = scale
        self.refreshHz = refreshHz
    }
}

/// Guest→host `win_new` {win, app_id, title, w, h, scale}.
public struct GuiWinNew: Codable, Sendable, Equatable {
    public let win: UInt32
    public let appID: String
    public let title: String
    public let width: UInt32
    public let height: UInt32
    public let scale: Double

    enum CodingKeys: String, CodingKey {
        case win, title, scale
        case appID = "app_id"
        case width = "w"
        case height = "h"
    }

    public init(
        win: UInt32, appID: String, title: String, width: UInt32, height: UInt32, scale: Double
    ) {
        self.win = win
        self.appID = appID
        self.title = title
        self.width = width
        self.height = height
        self.scale = scale
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

extension GuiProto {
    /// Parse a `commit` payload, validating every bound the header asserts:
    /// n_rects ≤ 4096, stride ≥ w*4, each rect inside the buffer, and enough
    /// trailing bytes for the row-packed pixels. Rejects malformed input rather
    /// than trusting the guest.
    public static func parseCommit(_ data: Data) throws -> GuiCommit {
        guard data.count >= commitFixed else {
            throw MSLError.framing("commit shorter than \(commitFixed)-byte header")
        }
        var reader = GuiReader(data)
        let head = try readCommitHead(&reader)
        guard head.format <= 1 else {
            throw MSLError.protocolMismatch("commit format \(head.format) unsupported")
        }
        guard head.width > 0, head.height > 0 else {
            throw MSLError.protocolMismatch("commit has zero dimension")
        }
        guard UInt64(head.stride) >= UInt64(head.width) * 4 else {
            throw MSLError.protocolMismatch("commit stride \(head.stride) < w*4")
        }
        guard head.nRects <= UInt32(maxRects) else {
            throw MSLError.protocolMismatch("commit n_rects \(head.nRects) exceeds \(maxRects)")
        }
        let rects = try readRects(
            &reader, count: Int(head.nRects), bufW: head.width, bufH: head.height)
        let need = try pixelBytes(for: rects)
        guard UInt64(reader.remaining) >= need else {
            throw MSLError.framing("commit pixels short: have \(reader.remaining), need \(need)")
        }
        let pixels = try reader.take(Int(need))
        guard reader.remaining == 0 else {
            throw MSLError.framing(
                "commit has \(reader.remaining) trailing bytes (spec: no padding)")
        }
        return GuiCommit(
            win: head.win, seq: head.seq, width: head.width, height: head.height,
            stride: head.stride, format: head.format, scaleE12: head.scaleE12, serial: head.serial,
            rects: rects, tClientCommitNs: head.tClient, tSendNs: head.tSend, pixels: pixels)
    }

    private struct CommitHead {
        let win: UInt32
        let seq: UInt32
        let width: UInt32
        let height: UInt32
        let stride: UInt32
        let format: UInt32
        let scaleE12: UInt32
        let nRects: UInt32
        let serial: UInt32
        let tClient: UInt64
        let tSend: UInt64
    }

    private static func readCommitHead(_ reader: inout GuiReader) throws -> CommitHead {
        let win = try reader.u32()
        let seq = try reader.u32()
        let width = try reader.u32()
        let height = try reader.u32()
        let stride = try reader.u32()
        let format = try reader.u32()
        let scaleE12 = try reader.u32()
        let nRects = try reader.u32()
        let serial = try reader.u32()
        _ = try reader.u32()  // reserved: sender writes 0, receiver ignores the value
        let tClient = try reader.u64()
        let tSend = try reader.u64()
        assert(reader.offset == commitFixed, "commit head must consume the fixed prefix")
        return CommitHead(
            win: win, seq: seq, width: width, height: height, stride: stride, format: format,
            scaleE12: scaleE12, nRects: nRects, serial: serial, tClient: tClient, tSend: tSend)
    }

    private static func readRects(
        _ reader: inout GuiReader, count: Int, bufW: UInt32, bufH: UInt32
    ) throws -> [GuiRect] {
        precondition(count >= 0, "rect count must be non-negative")
        precondition(count <= maxRects, "rect count already bounded by caller")
        var rects: [GuiRect] = []
        rects.reserveCapacity(count)
        for _ in 0..<count {  // bounded: count ≤ maxRects (4096)
            let rect = GuiRect(
                originX: try reader.u32(), originY: try reader.u32(), width: try reader.u32(),
                height: try reader.u32())
            guard UInt64(rect.originX) + UInt64(rect.width) <= UInt64(bufW),
                UInt64(rect.originY) + UInt64(rect.height) <= UInt64(bufH)
            else {
                throw MSLError.protocolMismatch("commit rect outside buffer bounds")
            }
            rects.append(rect)
        }
        assert(rects.count == count, "rect parse must yield the requested count")
        return rects
    }

    private static func pixelBytes(for rects: [GuiRect]) throws -> UInt64 {
        precondition(rects.count <= maxRects, "rect count already bounded")
        var total: UInt64 = 0
        for rect in rects {  // bounded: rects.count ≤ maxRects
            total += UInt64(rect.width) * UInt64(rect.height) * 4
            guard total <= UInt64(maxFrame) else {
                throw MSLError.framing("commit pixel total exceeds \(maxFrame)")
            }
        }
        return total
    }
}
