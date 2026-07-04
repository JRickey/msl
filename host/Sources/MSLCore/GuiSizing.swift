import Foundation

/// A content size in logical points; the unit the window and every configure
/// speak (protocol: configure w/h and commit buffer points are points).
public struct GuiSizePoints: Sendable, Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// The size-authority states of the protocol's host state machine.
public enum GuiSizeState: Sendable, Equatable {
    case initialMap
    case settled
    case liveResize
}

/// What a drained commit is allowed to do to the window: touch pixels only, or
/// resize the content to the client's buffer points. `pixelsOnlyStaleFuture`
/// marks a commit whose serial exceeds what the host sent (a guest bug): still
/// pixels-only, but the caller logs it once.
public enum GuiSizeVerdict: Sendable, Equatable {
    case pixelsOnly
    case applyGeometry(GuiSizePoints)
    case pixelsOnlyStaleFuture
}

/// Pure size-authority decision (protocol "Size authority"): the load-bearing
/// invariant is that a stale commit updates pixels but never window geometry,
/// so an echo of the host's own configure can never re-grow the window.
public enum GuiSizing {
    /// Sub-point slack: differences below half a logical point are rounding
    /// noise, not a client-initiated resize, so they never trigger geometry.
    static let pointEpsilon = 0.5

    /// Buffer points = pixels × 4096 / scale_e12 (the single conversion the
    /// spec permits on the host side).
    public static func bufferPoints(
        widthPx: UInt32, heightPx: UInt32, scaleE12: UInt32
    ) -> GuiSizePoints {
        assert(scaleE12 > 0, "scale_e12 must be positive")
        guard scaleE12 > 0 else {
            return GuiSizePoints(width: Double(widthPx), height: Double(heightPx))
        }
        let factor = 4096.0 / Double(scaleE12)
        let points = GuiSizePoints(
            width: Double(widthPx) * factor, height: Double(heightPx) * factor)
        assert(points.width >= 0 && points.height >= 0, "buffer points are non-negative")
        return points
    }

    /// Decide a drained commit's effect. `sentSerial` is the newest serial the
    /// host has sent; a commit is current iff its serial equals it. `lastApplied`
    /// dedups rule 3: repeating an already-applied (serial, points) pair never
    /// re-applies, even while content points still differ (AppKit constraints).
    public static func verdict(
        state: GuiSizeState, sentSerial: UInt32, commitSerial: UInt32,
        bufferPoints: GuiSizePoints, contentPoints: GuiSizePoints,
        lastApplied: GuiAppliedGeometry? = nil
    ) -> GuiSizeVerdict {
        assert(bufferPoints.width >= 0 && bufferPoints.height >= 0, "buffer points non-negative")
        assert(contentPoints.width >= 0 && contentPoints.height >= 0, "content points non-negative")
        guard commitSerial <= sentSerial else { return .pixelsOnlyStaleFuture }
        switch state {
        // .initialMap mirrors the spec machine but is unreachable at runtime: the
        // initial frame is set before any commit is judged, so no commit sees it.
        case .initialMap, .liveResize:
            return .pixelsOnly
        case .settled:
            guard commitSerial == sentSerial else { return .pixelsOnly }
            guard differs(bufferPoints, contentPoints) else { return .pixelsOnly }
            let repeated = lastApplied.map {
                $0.serial == commitSerial && !differs($0.points, bufferPoints)
            }
            guard repeated != true else { return .pixelsOnly }
            return .applyGeometry(bufferPoints)
        }
    }

    /// True when two sizes differ by at least the epsilon on either axis.
    public static func differs(_ lhs: GuiSizePoints, _ rhs: GuiSizePoints) -> Bool {
        assert(pointEpsilon > 0, "epsilon must be positive")
        let dw = abs(lhs.width - rhs.width)
        let dh = abs(lhs.height - rhs.height)
        return dw >= pointEpsilon || dh >= pointEpsilon
    }
}

/// The (serial, buffer points) pair of the most recent geometry apply; rule 3
/// applies once per pair, so a client pinned at its minimum cannot re-trigger.
public struct GuiAppliedGeometry: Sendable, Equatable {
    public let serial: UInt32
    public let points: GuiSizePoints

    public init(serial: UInt32, points: GuiSizePoints) {
        self.serial = serial
        self.points = points
    }
}
