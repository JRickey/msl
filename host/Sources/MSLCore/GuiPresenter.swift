import AppKit
import Darwin
import Foundation

/// Drives the spike: one NSApplication, a reader thread decoding GUI frames onto
/// the main queue, a native window per remote toplevel, and the latency ledger.
/// All AppKit and window state lives on the main thread; the reader thread only
/// reads frames and hands them across via `DispatchQueue.main.async`.
@MainActor
public final class GuiPresenter: NSObject, GuiHost {
    private let channel: GuiChannel
    private let distro: String
    private let csvPath: String
    private let scale: Double
    private let refreshHz: Double

    private let commitRouter = GuiCommitRouter()
    private var windows: [UInt32: GuiWindow] = [:]
    private var windowNumbers: Set<Int> = []
    private let popupManager: GuiPopupManager
    private var ledger = GuiLedger()
    private var guestStatsJSON: String?
    private var signalSource: DispatchSourceSignal?
    private var shuttingDown = false

    public init(channel: GuiChannel, distro: String, csvPath: String) {
        precondition(!csvPath.isEmpty, "csv path must not be empty")
        self.channel = channel
        self.distro = distro
        self.csvPath = csvPath
        self.popupManager = GuiPopupManager(channel: channel)
        let screen = NSScreen.main
        self.scale = Double(screen?.backingScaleFactor ?? 2.0)
        self.refreshHz = Double(screen?.maximumFramesPerSecond ?? 60)
        super.init()
    }

    /// Become a regular app, start the reader, and run the AppKit loop (blocks).
    public func run() {
        // Flush the ledger if the loop ever returns without going through an
        // explicit exit path, so data still lands on disk.
        defer { writeReport() }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        popupManager.begin { [weak self] win in self?.windows[win]?.detachAndHide() }
        installStallHandler()
        installSignalSource()
        startReader()
        app.activate(ignoringOtherApps: true)
        app.run()
    }

    private func installStallHandler() {
        channel.setStallHandler { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.fail("guest link stalled (writer backlog full)") }
            }
        }
    }

    private func startReader() {
        assert(!csvPath.isEmpty, "csv path resolved before the reader starts")
        Thread.detachNewThread { [self] in self.readerLoop() }
    }

    nonisolated private func readerLoop() {
        while true {  // sanctioned: decode frames until the channel drops
            let frame: GuiInboundFrame
            do {
                frame = try channel.readFrame()
            } catch {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.handleDisconnect() }
                }
                return
            }
            let recvNs = GuiClock.nowNs()
            if frame.type == GuiType.commit.rawValue {
                routeCommit(frame.payload, recvNs: recvNs)
                continue
            }
            if frame.type == GuiType.winNew.rawValue {
                routeWinNew(frame.payload)
                continue
            }
            if frame.type == GuiType.popupNew.rawValue {
                routePopupNew(frame.payload)
                continue
            }
            let type = frame.type
            let payload = frame.payload
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.handleFrame(type: type, payload: payload) }
            }
        }
    }

    /// Parse a commit off the main thread and deposit it in its window's
    /// keep-latest slot; the display tick copies only the newest one.
    nonisolated private func routeCommit(_ payload: Data, recvNs: UInt64) {
        guard let commit = try? GuiProto.parseCommit(payload) else { return }
        commitRouter.store(win: commit.win, held: GuiHeldCommit(commit: commit, recvNs: recvNs))
    }

    /// Register the window's latch on the reader thread *before* dispatching the
    /// NSWindow build to main, so commits arriving in that gap latch normally and
    /// the first display tick presents them (no first-paint-until-resize race).
    nonisolated private func routeWinNew(_ payload: Data) {
        guard let spec = try? GuiProto.decode(GuiWinNew.self, from: payload) else { return }
        let latch = GuiCommitLatch()
        commitRouter.register(win: spec.win, latch: latch)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.createWindow(spec, latch: latch) }
        }
    }

    // MARK: - Frame dispatch

    private func handleFrame(type: UInt32, payload: Data) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let kind = GuiType(rawValue: type) else { return }
        switch kind {
        case .hello: handleHello(payload)
        case .stats: guestStatsJSON = String(bytes: payload, encoding: .utf8)
        default: handleWindowFrame(kind, payload)
        }
    }

    private func handleWindowFrame(_ kind: GuiType, _ payload: Data) {
        assert(kind != .commit && kind != .winNew, "commit/win_new are routed off the main thread")
        switch kind {
        case .winMap: routeRef(payload) { $0.mapWindow() }
        case .winUnmap: routeRef(payload) { $0.unmapWindow() }
        case .winDestroy: handleWinDestroy(payload)
        case .winTitle: handleWinTitle(payload)
        case .winLimits: handleWinLimits(payload)
        case .cursorNamed: handleCursor(payload)
        case .popupMoved: handlePopupMoved(payload)
        default: break
        }
    }

    private func handleHello(_ payload: Data) {
        guard let hello = try? GuiProto.decode(GuiHello.self, from: payload) else {
            fail("malformed hello from guest compositor")
            return
        }
        guard hello.version == GuiProto.version else {
            fail("gui protocol mismatch: guest v\(hello.version), host v\(GuiProto.version)")
            return
        }
        let ack = GuiHelloAck(version: GuiProto.version, scale: scale, refreshHz: refreshHz)
        guard let data = try? GuiProto.encode(ack) else { return }
        channel.send(type: GuiType.helloAck.rawValue, flags: 0, payload: data)
    }

    /// Build the NSWindow on main using the latch the reader already registered.
    /// A duplicate win_new re-registers the existing window's latch so the router
    /// keeps pointing at the live window.
    private func createWindow(_ spec: GuiWinNew, latch: GuiCommitLatch) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let existing = windows[spec.win] {
            commitRouter.register(win: spec.win, latch: existing.latch)
            return
        }
        guard let window = GuiWindow(spec: spec, channel: channel, host: self, latch: latch) else {
            note("failed to create window \(spec.win)")
            commitRouter.unregister(win: spec.win)
            return
        }
        windows[spec.win] = window
    }

    private func handleWinDestroy(_ payload: Data) {
        guard let ref = try? GuiProto.decode(GuiWinRef.self, from: payload) else { return }
        popupManager.dismissChildren(of: ref.win)
        popupManager.unregister(win: ref.win)
        commitRouter.unregister(win: ref.win)
        windows.removeValue(forKey: ref.win)?.destroy()
        writeReport()
        closeIfLastWindow()
    }

    private func handleWinTitle(_ payload: Data) {
        guard let msg = try? GuiProto.decode(GuiWinTitle.self, from: payload) else { return }
        windows[msg.win]?.setTitle(msg.title)
    }

    private func handleWinLimits(_ payload: Data) {
        guard let msg = try? GuiProto.decode(GuiWinLimits.self, from: payload) else { return }
        windows[msg.win]?.applyLimits(msg)
    }

    private func handleCursor(_ payload: Data) {
        guard let msg = try? GuiProto.decode(GuiCursorNamed.self, from: payload) else { return }
        windows[msg.win]?.setCursor(msg.name)
    }

    private func routeRef(_ payload: Data, _ action: (GuiWindow) -> Void) {
        guard let ref = try? GuiProto.decode(GuiWinRef.self, from: payload) else { return }
        guard let window = windows[ref.win] else { return }
        action(window)
    }

    // MARK: - GuiHost

    public func ledgerCommit(_ sample: GuiCommitSample) {
        dispatchPrecondition(condition: .onQueue(.main))
        ledger.addCommit(sample)
    }

    public func ledgerInput(_ sample: GuiInputSample) {
        dispatchPrecondition(condition: .onQueue(.main))
        ledger.addInput(sample)
    }

    public func windowClosed(_ win: UInt32) {
        popupManager.dismissChildren(of: win)
        popupManager.unregister(win: win)
        commitRouter.unregister(win: win)
        // AppKit already closed the window and windowShouldClose tore down its
        // resources; just drop our reference (no destroy — that would re-close).
        windows.removeValue(forKey: win)
        writeReport()
        closeIfLastWindow()
    }

    /// When no windows remain, finalize like a graceful exit so the CSV lands.
    private func closeIfLastWindow() {
        guard windows.isEmpty else { return }
        beginShutdown()
    }

    // MARK: - Shutdown & reporting

    private func installSignalSource() {
        signal(SIGINT, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.beginShutdown() }
        }
        source.resume()
        signalSource = source
    }

    private func beginShutdown() {
        guard !shuttingDown else { return }
        shuttingDown = true
        note("shutting down; requesting guest stats")
        channel.send(type: GuiType.statsReq.rawValue, flags: 0, payload: Data("{}".utf8))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.finalizeAndExit(code: 0) }
        }
    }

    private func handleDisconnect() {
        guard !shuttingDown else { return }
        shuttingDown = true
        note("guest compositor disconnected")
        finalizeAndExit(code: 0)
    }

    private func fail(_ message: String) {
        guard !shuttingDown else { return }
        shuttingDown = true
        note("error: \(message)")
        finalizeAndExit(code: 1)
    }

    private func finalizeAndExit(code: Int32) {
        writeReport()
        note(ledger.summary())
        popupManager.end()
        channel.close()
        exit(code)
    }

    private func writeReport() {
        var text = ledger.csv()
        if let stats = guestStatsJSON {
            text += "# guest_stats " + stats + "\n"
        }
        do {
            try text.write(toFile: csvPath, atomically: true, encoding: .utf8)
            note(
                "wrote \(ledger.commitCount) commit / \(ledger.inputCount) input rows to \(csvPath)"
            )
        } catch {
            note("failed to write csv \(csvPath): \(error)")
        }
    }

    private func note(_ message: String) {
        let line = "gui-spike[\(distro)]: \(message)\n"
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }
}

// Popup routing: mirrors the toplevel win_new path and builds child panels.
extension GuiPresenter {
    /// Mirror `routeWinNew` for popups: register the latch on the reader thread
    /// before the panel build is dispatched, so commits in that gap latch.
    nonisolated func routePopupNew(_ payload: Data) {
        guard let spec = try? GuiProto.decode(GuiPopupNew.self, from: payload) else { return }
        let latch = GuiCommitLatch()
        commitRouter.register(win: spec.win, latch: latch)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.createPopup(spec, latch: latch) }
        }
    }

    /// Build a popup panel on main against a live parent. An unknown parent is a
    /// guest bug (pacing's starvation fallback keeps the client alive), so the
    /// popup is dropped with one line rather than crashing.
    func createPopup(_ spec: GuiPopupNew, latch: GuiCommitLatch) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let existing = windows[spec.win] {
            note("popup \(spec.win) collides with an existing window; re-registering latch")
            commitRouter.register(win: spec.win, latch: existing.latch)
            return
        }
        guard let parent = windows[spec.parent] else {
            note("popup \(spec.win) names unknown parent \(spec.parent); dropping")
            commitRouter.unregister(win: spec.win)
            return
        }
        guard popupManager.hasCapacity else {
            note("popup \(spec.win) exceeds the \(GuiPopupManager.maxPopups)-popup cap; dropping")
            commitRouter.unregister(win: spec.win)
            popupManager.dismiss(win: spec.win)
            return
        }
        guard
            let popup = GuiWindow(
                popup: spec, parent: parent, channel: channel, host: self, latch: latch)
        else {
            note("failed to create popup \(spec.win)")
            commitRouter.unregister(win: spec.win)
            return
        }
        windows[spec.win] = popup
        popupManager.register(win: spec.win, parent: spec.parent, panel: popup.backingWindow)
    }

    func handlePopupMoved(_ payload: Data) {
        guard let msg = try? GuiProto.decode(GuiPopupMoved.self, from: payload) else { return }
        windows[msg.win]?.popupReposition(posX: msg.posX, posY: msg.posY)
    }
}

// On-screen window-number registry for the pointer occlusion filter (GuiHost).
extension GuiPresenter {
    public func registerWindowNumber(_ number: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard number > 0 else { return }
        windowNumbers.insert(number)
        assert(windowNumbers.contains(number), "registered number is tracked")
    }

    public func unregisterWindowNumber(_ number: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        windowNumbers.remove(number)
        assert(!windowNumbers.contains(number), "unregistered number is dropped")
    }

    public func ownsWindowNumber(_ number: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        assert(windowNumbers.count <= GuiCommitRouter.maxWindows, "number set stays bounded")
        return number > 0 && windowNumbers.contains(number)
    }
}
