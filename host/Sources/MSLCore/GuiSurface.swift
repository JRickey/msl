import Foundation
import IOSurface

/// A BGRA IOSurface backing one window. `reusable` gates the pool: a surface is
/// writable only when it is off screen (set true by the CATransaction
/// completion that removed it). Touched only on the main thread.
@MainActor
final class GuiSurface {
    let ioSurface: IOSurface
    let width: Int
    let height: Int
    var reusable = true

    init?(width: Int, height: Int) {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else { return nil }
        let props: [IOSurfacePropertyKey: any Sendable] = [
            .width: width, .height: height, .bytesPerElement: 4,
            .pixelFormat: UInt32(0x4247_5241),
        ]
        guard let surface = IOSurface(properties: props) else { return nil }
        self.ioSurface = surface
        self.width = width
        self.height = height
    }

    /// Copy each damaged rect's row-packed pixels into the surface. Dimensions
    /// must match; the parser already proved every rect lies in-bounds.
    func apply(_ commit: GuiCommit) {
        precondition(commit.width == UInt32(width), "commit width must match surface")
        precondition(commit.height == UInt32(height), "commit height must match surface")
        guard !commit.rects.isEmpty else { return }
        guard ioSurface.lock(options: [], seed: nil) == 0 else { return }
        defer { _ = ioSurface.unlock(options: [], seed: nil) }
        let dstStride = ioSurface.bytesPerRow
        let base = ioSurface.baseAddress
        commit.pixels.withUnsafeBytes { raw in
            guard let src = raw.baseAddress else { return }
            var srcOff = 0
            for rect in commit.rects {  // bounded: ≤ maxRects (4096)
                let rowBytes = Int(rect.width) * 4
                for row in 0..<Int(rect.height) {  // bounded: ≤ surface height
                    let dstOff = (Int(rect.originY) + row) * dstStride + Int(rect.originX) * 4
                    assert(dstOff + rowBytes <= dstStride * height, "row copy stays in surface")
                    assert(srcOff + rowBytes <= raw.count, "row copy stays in payload")
                    memcpy(base.advanced(by: dstOff), src.advanced(by: srcOff), rowBytes)
                    srcOff += rowBytes
                }
            }
        }
    }

    /// Bring this surface current with `other` (same dimensions) by a full copy
    /// that honors each surface's own row stride.
    func copyContents(from other: GuiSurface) {
        precondition(width == other.width, "copy source width must match")
        precondition(height == other.height, "copy source height must match")
        guard ioSurface.lock(options: [], seed: nil) == 0 else { return }
        defer { _ = ioSurface.unlock(options: [], seed: nil) }
        guard other.ioSurface.lock(options: [.readOnly], seed: nil) == 0 else { return }
        defer { _ = other.ioSurface.unlock(options: [.readOnly], seed: nil) }
        let dst = ioSurface.baseAddress
        let src = other.ioSurface.baseAddress
        let dstStride = ioSurface.bytesPerRow
        let srcStride = other.ioSurface.bytesPerRow
        let rowBytes = width * 4
        for row in 0..<height {  // bounded: ≤ 16384
            assert(row * dstStride + rowBytes <= dstStride * height, "dst row in surface")
            assert(row * srcStride + rowBytes <= srcStride * height, "src row in surface")
            memcpy(dst.advanced(by: row * dstStride), src.advanced(by: row * srcStride), rowBytes)
        }
    }
}

/// Fixed-depth surface pool for one window. Only an off-screen (`reusable`)
/// non-front surface may be written; the front is what is on screen. Present
/// atomicity: the presenter promotes a target and recycles the outgoing surface
/// when its removing CATransaction completes.
@MainActor
final class GuiSurfacePool {
    static let depth = 3

    private var surfaces: [GuiSurface]
    private(set) var front: GuiSurface?
    private(set) var width: Int
    private(set) var height: Int

    init?(width: Int, height: Int) {
        guard let made = GuiSurfacePool.make(width: width, height: height) else { return nil }
        self.surfaces = made
        self.front = nil
        self.width = width
        self.height = height
    }

    private static func make(width: Int, height: Int) -> [GuiSurface]? {
        assert(depth >= 2, "pool must hold at least two surfaces")
        assert(width > 0 && height > 0, "pool dimensions must be positive")
        var made: [GuiSurface] = []
        made.reserveCapacity(depth)
        for _ in 0..<depth {  // bounded: depth
            guard let surface = GuiSurface(width: width, height: height) else { return nil }
            made.append(surface)
        }
        assert(made.count == depth, "pool holds depth surfaces")
        return made
    }

    /// Reallocate to new dimensions on a buffer-size change; the front is dropped
    /// so the next present starts from a fresh surface expecting full damage.
    func resize(width newWidth: Int, height newHeight: Int) -> Bool {
        assert(newWidth > 0 && newHeight > 0, "resize dimensions must be positive")
        guard let made = GuiSurfacePool.make(width: newWidth, height: newHeight) else {
            return false
        }
        surfaces = made
        front = nil
        width = newWidth
        height = newHeight
        assert(surfaces.count == GuiSurfacePool.depth, "resized pool holds depth surfaces")
        return true
    }

    func reusableTarget() -> GuiSurface? {
        assert(surfaces.count >= 2, "pool holds at least two surfaces")
        for surface in surfaces {  // bounded: depth
            if surface.reusable, surface !== front { return surface }
        }
        return nil
    }

    /// Promote `target` to the front and return the outgoing surface, which the
    /// caller recycles only once its removing CATransaction completes.
    func promote(_ target: GuiSurface) -> GuiSurface? {
        assert(target !== front, "promoted surface must differ from the front")
        assert(target.reusable, "promoted surface must be reusable")
        target.reusable = false
        let outgoing = front
        front = target
        assert(front === target, "front is the promoted surface")
        return outgoing
    }

    func detach() {
        front = nil
        assert(front == nil, "detach clears the front surface")
    }
}
