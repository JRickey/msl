import AppKit
import Foundation
import QuartzCore

/// Callbacks a `GuiWindow` makes back into the presenter (ledger + lifecycle).
@MainActor
public protocol GuiHost: AnyObject {
    func ledgerCommit(_ sample: GuiCommitSample)
    func ledgerInput(_ sample: GuiInputSample)
    func windowClosed(_ win: UInt32)
}

/// One native window for a remote toplevel: presents from a surface pool at
/// display-link cadence, paces present_acks, applies the size-authority
/// verdict, and translates NSEvents without ever blocking the main thread.
@MainActor
final class GuiWindow: NSObject, NSWindowDelegate {
    let win: UInt32
    let latch: GuiCommitLatch
    weak var host: GuiHost?
    let channel: GuiChannel

    let window: NSWindow
    let view: GuiSurfaceView
    private let pool: GuiSurfacePool
    private var pacer = GuiPacer()
    private var displayLink: CADisplayLink?

    let role: GuiRole
    weak var popupParent: GuiWindow?
    var popupOffset: (x: Double, y: Double) = (0, 0)
    var popupSize = GuiSizePoints(width: 1, height: 1)

    var backingWindow: NSWindow { window }

    var sentSerial: UInt32 = 0
    var sizeState: GuiSizeState = .settled
    var remoteApplying = false
    var lastApplied: GuiAppliedGeometry?
    var lastConfigured: GuiSizePoints?
    var resizePending: GuiSizePoints?
    var pending: GuiHeldCommit?
    var pendingInput: (kind: String, tNs: UInt64)?
    var loggedPartialResize = false
    var loggedSerialBug = false
    var loggedBadLimits = false

    init?(spec: GuiWinNew, channel: GuiChannel, host: GuiHost, latch: GuiCommitLatch) {
        guard spec.scale > 0, spec.width > 0, spec.height > 0 else { return nil }
        guard let pool = GuiSurfacePool(width: Int(spec.width), height: Int(spec.height))
        else { return nil }
        self.win = spec.win
        self.latch = latch
        self.channel = channel
        self.host = host
        self.pool = pool
        self.role = .toplevel
        let desired = GuiSizePoints(
            width: Double(spec.width) / spec.scale, height: Double(spec.height) / spec.scale)
        let clamped = GuiWindow.clamp(desired, to: NSScreen.main)
        let logical = NSRect(x: 0, y: 0, width: clamped.width, height: clamped.height)
        self.window = NSWindow(
            contentRect: logical, styleMask: GuiWindow.styleMask,
            backing: .buffered, defer: false)
        self.view = GuiSurfaceView(frame: logical)
        super.init()
        configureWindow(title: spec.title, scale: spec.scale)
        if clamped != desired { enqueueConfigure(clamped) }
    }

    /// A popup (`popup_new`) as a borderless, non-activating child panel anchored
    /// to `parent`. It reuses the whole presentation pipeline but runs no
    /// size-authority machine: every commit resizes to the client's buffer points
    /// and re-runs placement, and the host never emits a configure for it.
    init?(
        popup spec: GuiPopupNew, parent: GuiWindow, channel: GuiChannel, host: GuiHost,
        latch: GuiCommitLatch
    ) {
        guard spec.scale.isFinite, spec.scale > 0, spec.scale <= 16 else { return nil }
        guard spec.width > 0, spec.height > 0 else { return nil }
        guard let pool = GuiSurfacePool(width: Int(spec.width), height: Int(spec.height))
        else { return nil }
        self.win = spec.win
        self.latch = latch
        self.channel = channel
        self.host = host
        self.pool = pool
        self.role = .popup
        let content = GuiSizePoints(
            width: Double(spec.width) / spec.scale, height: Double(spec.height) / spec.scale)
        let logical = NSRect(x: 0, y: 0, width: content.width, height: content.height)
        let panel = NSPanel(
            contentRect: logical, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.becomesKeyOnlyIfNeeded = true
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false
        self.window = panel
        self.view = GuiSurfaceView(frame: logical)
        super.init()
        self.popupParent = parent
        self.popupOffset = (x: Double(spec.posX), y: Double(spec.posY))
        self.popupSize = content
        attachContentView(scale: spec.scale)
        applyPlacement()
    }

    private func configureWindow(title: String, scale: Double) {
        assert(scale > 0, "window scale must be positive")
        window.title = title.isEmpty ? "msl" : title
        window.delegate = self
        attachContentView(scale: scale)
    }

    /// Install the content view and its presentation layer; shared by toplevels
    /// and popup panels. The lifetime override keeps Swift as the sole owner: the
    /// window is held in the presenter's dict, and without this AppKit
    /// over-releases it on close and crashes in the close animation.
    func attachContentView(scale: Double) {
        assert(scale > 0, "content scale must be positive")
        assert(view.owner == nil, "view is freshly created")
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.contentView = view
        view.owner = self
        view.wantsLayer = true
        view.layerContentsRedrawPolicy = .never
        if let layer = view.layer {
            layer.contentsGravity = .resizeAspect
            layer.contentsScale = scale
        }
    }

    func mapWindow() {
        switch role {
        case .toplevel: window.makeKeyAndOrderFront(nil)
        case .popup: attachAsChild()
        }
        startDisplayLink()
        assert(displayLink != nil, "a mapped window drives a display link")
    }

    func unmapWindow() {
        if role == .popup { detachFromParent() }
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

    /// Stop the display link and detach from the surface/event graph. Ordered
    /// before any window close so no tick or event lands on a tearing-down window.
    private func teardownResources() {
        displayLink?.invalidate()
        displayLink = nil
        view.layer?.contents = nil
        pool.detach()
        window.delegate = nil
        view.owner = nil
    }

    /// Guest-initiated teardown (`win_destroy`): a popup detaches from its parent
    /// first (AppKit requires removeChildWindow before the child deallocates),
    /// then tear down and close the window.
    func destroy() {
        if role == .popup { detachFromParent() }
        teardownResources()
        window.close()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = view.displayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
        assert(displayLink != nil, "display link must be installed")
    }

    @objc private func step() {
        dispatchPrecondition(condition: .onQueue(.main))
        // An owed configure advances sentSerial before any commit is judged, so a
        // commit echoing the prior serial is stale (pixels only), never re-applied.
        emitPendingConfigure()
        drainAndDecide()
        guard !pacer.isUnacked, pacer.hasPending, let held = pending else { return }
        guard ensurePool(held.commit) else { return }
        guard let target = pool.reusableTarget() else { return }
        guard case .present(let seq) = pacer.tick() else { return }
        presentFrame(held: held, target: target, seq: seq)
    }

    /// Drain the newest coalesced commit, run the size-authority verdict against
    /// its serial, and record it as pending (kept until a tick presents it).
    private func drainAndDecide() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let held = latch.take() else { return }
        assert(held.commit.win == win, "commit routed to the wrong window")
        pending = held
        switch role {
        case .toplevel: applySizeVerdict(held.commit)
        case .popup: applyPopupCommit(held.commit)
        }
        pacer.onCommit(seq: held.commit.seq)
        assert(pending != nil, "drain leaves a pending commit")
    }

    private func applySizeVerdict(_ commit: GuiCommit) {
        let buffer = GuiSizing.bufferPoints(
            widthPx: commit.width, heightPx: commit.height, scaleE12: commit.scaleE12)
        let content = boundsPoints()
        let verdict = GuiSizing.verdict(
            state: sizeState, sentSerial: sentSerial, commitSerial: commit.serial,
            bufferPoints: buffer, contentPoints: content, lastApplied: lastApplied)
        assert(content.width >= 0 && content.height >= 0, "content points non-negative")
        switch verdict {
        case .pixelsOnly: break
        case .pixelsOnlyStaleFuture: logSerialBugOnce(commit.serial)
        case .applyGeometry(let points): applyRemoteGeometry(points, serial: commit.serial)
        }
    }

    /// Rule 3: apply the client's buffer points once per (serial, points) pair,
    /// under a guard that suppresses the echo configure. Idempotent: when the
    /// window already sits at the clamp target nothing moves and nothing is sent,
    /// so a client that refuses a size can never drive a configure loop.
    private func applyRemoteGeometry(_ points: GuiSizePoints, serial: UInt32) {
        dispatchPrecondition(condition: .onQueue(.main))
        let clamped = GuiWindow.clamp(points, to: window.screen ?? NSScreen.main)
        guard clamped.width >= 1, clamped.height >= 1 else { return }
        lastApplied = GuiAppliedGeometry(serial: serial, points: points)
        guard GuiSizing.differs(clamped, boundsPoints()) else { return }
        remoteApplying = true
        window.setContentSize(NSSize(width: clamped.width, height: clamped.height))
        remoteApplying = false
        assert(!remoteApplying, "remote-apply guard cleared after setContentSize")
        let achieved = boundsPoints()
        let owed = GuiSizing.differs(achieved, points)
        let repeated = lastConfigured.map { !GuiSizing.differs($0, achieved) } ?? false
        if owed, !repeated { enqueueConfigure(achieved) }
    }

    private func emitPendingConfigure() {
        guard let points = resizePending else { return }
        resizePending = nil
        enqueueConfigure(points)
    }

    /// Stamp the next serial (monotonic from 1) and send one configure in the
    /// window's current state (resizing state only during a live drag).
    private func enqueueConfigure(_ points: GuiSizePoints) {
        sentSerial += 1
        assert(sentSerial > 0, "serials start at 1")
        lastConfigured = points
        let width = UInt32(max(1, points.width.rounded()))
        let height = UInt32(max(1, points.height.rounded()))
        assert(width > 0 && height > 0, "configure size must be positive")
        let states = sizeState == .liveResize ? ["activated", "resizing"] : ["activated"]
        let cfg = GuiConfigure(
            win: win, width: width, height: height, serial: sentSerial, states: states)
        if let payload = try? GuiProto.encode(cfg) {
            channel.send(type: GuiType.configure.rawValue, flags: 0, payload: payload)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let payload = try? GuiProto.encode(GuiClose(win: win)) {
            channel.send(type: GuiType.close.rawValue, flags: 0, payload: payload)
        }
        // AppKit is closing the window itself; tear down our resources but do not
        // call window.close() again (that path is destroy(), guest-initiated).
        teardownResources()
        host?.windowClosed(win)
        return true
    }
}

// Present pipeline shared by toplevels and popups: pool management, the
// surface swap, and the present_ack/ledger record on each display tick.
extension GuiWindow {
    /// Reallocate the pool on a buffer-size change; the guest sends full damage on
    /// resize, so a partial-damage resize is logged once and the rest left blank.
    func ensurePool(_ commit: GuiCommit) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        if Int(commit.width) == pool.width, Int(commit.height) == pool.height { return true }
        guard pool.resize(width: Int(commit.width), height: Int(commit.height)) else {
            return false
        }
        if !commitCoversFullBuffer(commit) { logPartialResizeOnce() }
        assert(pool.front == nil, "resized pool has no front surface")
        return true
    }

    private func commitCoversFullBuffer(_ commit: GuiCommit) -> Bool {
        assert(commit.width > 0 && commit.height > 0, "commit dimensions positive")
        for rect in commit.rects {  // bounded: ≤ maxRects
            let atOrigin = rect.originX == 0 && rect.originY == 0
            let fullSize = rect.width == commit.width && rect.height == commit.height
            if atOrigin, fullSize { return true }
        }
        return false
    }

    /// Bring `target` current (full copy of the on-screen frame, then this commit's
    /// damage), swap it in as the front surface in one CATransaction, and ack.
    func presentFrame(held: GuiHeldCommit, target: GuiSurface, seq: UInt32) {
        dispatchPrecondition(condition: .onQueue(.main))
        assert(target.reusable, "present target must be reusable")
        if let front = pool.front { target.copyContents(from: front) }
        target.apply(held.commit)
        let outgoing = pool.promote(target)
        let scale = held.commit.scale > 0 ? held.commit.scale : 1
        let tPresent = commitLayer(target: target, scale: scale, outgoing: outgoing)
        recordAndAck(held: held, seq: seq, tPresent: tPresent)
    }

    private func commitLayer(target: GuiSurface, scale: Double, outgoing: GuiSurface?) -> UInt64 {
        dispatchPrecondition(condition: .onQueue(.main))
        assert(scale > 0, "contents scale must be positive")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let layer = view.layer {
            if layer.contentsScale != scale { layer.contentsScale = scale }
            layer.contents = target.ioSurface
        }
        if let outgoing {
            // CA may fire this off the main thread; hop before touching actor state.
            CATransaction.setCompletionBlock {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { outgoing.reusable = true }
                }
            }
        }
        CATransaction.commit()
        return GuiClock.nowNs()
    }

    private func recordAndAck(held: GuiHeldCommit, seq: UInt32, tPresent: UInt64) {
        assert(tPresent > 0, "present timestamp is monotonic non-zero")
        let ack = GuiPresentAck(win: win, seq: seq, tRecvNs: held.recvNs, tPresentNs: tPresent)
        if let payload = try? GuiProto.encode(ack) {
            channel.send(type: GuiType.presentAck.rawValue, flags: 0, payload: payload)
        }
        host?.ledgerCommit(
            GuiCommitSample(
                win: win, seq: seq, tRecvNs: held.recvNs, tPresentNs: tPresent,
                tClientCommitNs: held.commit.tClientCommitNs, tSendNs: held.commit.tSendNs))
        if let input = pendingInput {
            host?.ledgerInput(
                GuiInputSample(
                    win: win, kind: input.kind, tInputNs: input.tNs, tPresentNs: tPresent))
            pendingInput = nil
        }
        pacer.onAck()
    }

    func boundsPoints() -> GuiSizePoints {
        let bounds = view.bounds
        return GuiSizePoints(
            width: max(1, Double(bounds.width)), height: max(1, Double(bounds.height)))
    }
}
