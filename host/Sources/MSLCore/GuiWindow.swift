import AppKit
import Foundation
import IOSurface
import QuartzCore

/// Callbacks a `GuiWindow` makes back into the presenter (ledger + lifecycle).
@MainActor
public protocol GuiHost: AnyObject {
    func ledgerCommit(_ sample: GuiCommitSample)
    func ledgerInput(_ sample: GuiInputSample)
    func windowClosed(_ win: UInt32)
}

/// A BGRA IOSurface backing one window; damaged rects are copied in honoring
/// the destination row stride. Touched only on the main thread.
@MainActor
final class GuiSurface {
    let ioSurface: IOSurface
    let width: Int
    let height: Int

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
}

/// One native window for a remote toplevel: presents the backing surface at
/// display-link cadence, paces present_acks, translates NSEvents to protocol
/// input, and tracks live resize without ever blocking the main thread.
@MainActor
final class GuiWindow: NSObject, NSWindowDelegate {
    let win: UInt32
    let latch = GuiCommitLatch()
    private weak var host: GuiHost?
    private let channel: GuiChannel

    private let window: NSWindow
    private let view: GuiSurfaceView
    private var surface: GuiSurface
    private var pacer = GuiPacer()
    private var displayLink: CADisplayLink?

    private var configureSerial: UInt32 = 0
    private var resizePending: (w: UInt32, h: UInt32)?
    private var resizing = false

    private var appliedSeq: UInt32 = 0
    private var appliedRecvNs: UInt64 = 0
    private var appliedClientNs: UInt64 = 0
    private var appliedSendNs: UInt64 = 0
    private var haveApplied = false
    private var pendingInput: (kind: String, tNs: UInt64)?

    init?(spec: GuiWinNew, channel: GuiChannel, host: GuiHost) {
        guard spec.scale > 0, spec.width > 0, spec.height > 0 else { return nil }
        guard let surface = GuiSurface(width: Int(spec.width), height: Int(spec.height))
        else { return nil }
        self.win = spec.win
        self.channel = channel
        self.host = host
        self.surface = surface
        let logical = NSRect(
            x: 0, y: 0, width: Double(spec.width) / spec.scale,
            height: Double(spec.height) / spec.scale)
        self.window = NSWindow(
            contentRect: logical, styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        self.view = GuiSurfaceView(frame: logical)
        super.init()
        configureWindow(title: spec.title, scale: spec.scale)
    }

    private func configureWindow(title: String, scale: Double) {
        assert(scale > 0, "window scale must be positive")
        window.title = title.isEmpty ? "msl" : title
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        window.contentView = view
        view.owner = self
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .never
        if let layer = view.layer {
            layer.contentsGravity = .resize
            layer.contentsScale = scale
            layer.contents = surface.ioSurface
        }
    }

    // MARK: - Lifecycle

    func mapWindow() {
        window.makeKeyAndOrderFront(nil)
        startDisplayLink()
        assert(window.isVisible, "mapped window must be visible")
    }

    func unmapWindow() {
        window.orderOut(nil)
        assert(!window.isVisible, "unmapped window must be hidden")
    }

    func setTitle(_ title: String) {
        window.title = title.isEmpty ? "msl" : title
    }

    func setCursor(_ name: String) {
        view.cursor = GuiWindow.cursor(for: name)
        window.invalidateCursorRects(for: view)
    }

    func destroy() {
        displayLink?.invalidate()
        displayLink = nil
        window.delegate = nil
        view.owner = nil
        window.close()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
        assert(displayLink != nil, "display link must be installed")
    }

    // MARK: - Present pipeline

    /// Copy the latest coalesced commit into the backing surface. Called only
    /// from the display tick, so at most one pixel copy happens per frame no
    /// matter how many commits the peer sent since the last tick.
    private func applyLatest() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let held = latch.take() else { return }
        assert(held.commit.win == win, "commit routed to the wrong window")
        applyToSurface(held.commit)
        appliedSeq = held.commit.seq
        appliedRecvNs = held.recvNs
        appliedClientNs = held.commit.tClientCommitNs
        appliedSendNs = held.commit.tSendNs
        haveApplied = true
        pacer.onCommit(seq: held.commit.seq)
    }

    private func applyToSurface(_ commit: GuiCommit) {
        if commit.width != UInt32(surface.width) || commit.height != UInt32(surface.height) {
            guard let fresh = GuiSurface(width: Int(commit.width), height: Int(commit.height))
            else { return }
            surface = fresh
            view.layer?.contents = fresh.ioSurface
        }
        view.layer?.contentsScale = commit.scale > 0 ? commit.scale : 1
        surface.apply(commit)
    }

    @objc private func step() {
        dispatchPrecondition(condition: .onQueue(.main))
        applyLatest()
        emitPendingConfigure()
        guard case .present(let seq) = pacer.tick() else { return }
        presentFrame(seq: seq)
    }

    private func presentFrame(seq: UInt32) {
        dispatchPrecondition(condition: .onQueue(.main))
        assert(haveApplied, "present requires an applied commit")
        let tPresent = commitLayer()
        let ack = GuiPresentAck(
            win: win, seq: seq, tRecvNs: appliedRecvNs, tPresentNs: tPresent)
        if let payload = try? GuiProto.encode(ack) {
            channel.send(type: GuiType.presentAck.rawValue, flags: 0, payload: payload)
        }
        host?.ledgerCommit(
            GuiCommitSample(
                win: win, seq: seq, tRecvNs: appliedRecvNs, tPresentNs: tPresent,
                tClientCommitNs: appliedClientNs, tSendNs: appliedSendNs))
        if let input = pendingInput {
            host?.ledgerInput(
                GuiInputSample(
                    win: win, kind: input.kind, tInputNs: input.tNs, tPresentNs: tPresent))
            pendingInput = nil
        }
        pacer.onAck()
    }

    private func commitLayer() -> UInt64 {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.contents = surface.ioSurface
        CATransaction.commit()
        return GuiClock.nowNs()
    }

    // MARK: - Resize (never blocks on the guest)

    func windowWillStartLiveResize(_ notification: Notification) {
        resizing = true
    }

    func windowDidResize(_ notification: Notification) {
        let bounds = view.bounds
        resizePending = (UInt32(max(1, bounds.width)), UInt32(max(1, bounds.height)))
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        resizing = false
        let bounds = view.bounds
        resizePending = (UInt32(max(1, bounds.width)), UInt32(max(1, bounds.height)))
    }

    private func emitPendingConfigure() {
        guard let size = resizePending else { return }
        resizePending = nil
        configureSerial += 1
        let states = resizing ? ["activated", "resizing"] : ["activated"]
        let cfg = GuiConfigure(
            win: win, width: size.w, height: size.h, serial: configureSerial, states: states)
        assert(size.w > 0 && size.h > 0, "configure size must be positive")
        if let payload = try? GuiProto.encode(cfg) {
            channel.send(type: GuiType.configure.rawValue, flags: 0, payload: payload)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let payload = try? GuiProto.encode(GuiClose(win: win)) {
            channel.send(type: GuiType.close.rawValue, flags: 0, payload: payload)
        }
        host?.windowClosed(win)
        return true
    }

    // MARK: - Input translation (called by the content view on the main thread)

    /// Window-local logical pointer state for one event (top-left origin).
    struct PointerSample {
        let kind: String
        let posX: Double
        let posY: Double
        var button: UInt32 = 0
        var state: UInt32 = 0
        var dx: Double = 0
        var dy: Double = 0
    }

    func pointerMotion(posX: Double, posY: Double) {
        sendPointer(PointerSample(kind: "motion", posX: posX, posY: posY), note: true)
    }

    func pointerButton(button: UInt32, down: Bool, posX: Double, posY: Double) {
        sendPointer(
            PointerSample(
                kind: "button", posX: posX, posY: posY, button: button, state: down ? 1 : 0),
            note: true)
    }

    func pointerAxis(dx: Double, dy: Double, posX: Double, posY: Double) {
        sendPointer(
            PointerSample(kind: "axis", posX: posX, posY: posY, dx: dx, dy: dy), note: true)
    }

    func pointerCrossing(entered: Bool, posX: Double, posY: Double) {
        sendPointer(
            PointerSample(kind: entered ? "enter" : "leave", posX: posX, posY: posY), note: false)
    }

    func keyEvent(virtualCode: UInt16, down: Bool) {
        let code = GuiKeymap.evdev(for: virtualCode)
        guard code != GuiKeymap.keyReserved else { return }
        let now = GuiClock.nowNs()
        pendingInput = ("key", now)
        let key = GuiKey(win: win, keycode: code, state: down ? 1 : 0, tHostNs: now)
        if let payload = try? GuiProto.encode(key) {
            channel.send(type: GuiType.key.rawValue, flags: 0, payload: payload)
        }
    }

    private func sendPointer(_ sample: PointerSample, note: Bool) {
        assert(!sample.kind.isEmpty, "pointer kind must not be empty")
        let now = GuiClock.nowNs()
        if note { pendingInput = (sample.kind, now) }
        let pointer = GuiPointer(
            win: win, kind: sample.kind, posX: sample.posX, posY: sample.posY,
            button: sample.button, state: sample.state, dx: sample.dx, dy: sample.dy, tHostNs: now)
        if let payload = try? GuiProto.encode(pointer) {
            channel.send(type: GuiType.pointer.rawValue, flags: 0, payload: payload)
        }
    }

    private static func cursor(for name: String) -> NSCursor {
        switch name {
        case "text": return .iBeam
        case "pointer": return .pointingHand
        case "grab": return .openHand
        default: return .arrow
        }
    }
}
