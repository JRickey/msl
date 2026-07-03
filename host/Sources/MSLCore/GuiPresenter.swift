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
    private var ledger = GuiLedger()
    private var guestStatsJSON: String?
    private var signalSource: DispatchSourceSignal?
    private var shuttingDown = false

    public init(channel: GuiChannel, distro: String, csvPath: String) {
        precondition(!csvPath.isEmpty, "csv path must not be empty")
        self.channel = channel
        self.distro = distro
        self.csvPath = csvPath
        let screen = NSScreen.main
        self.scale = Double(screen?.backingScaleFactor ?? 2.0)
        self.refreshHz = Double(screen?.maximumFramesPerSecond ?? 60)
        super.init()
    }

    /// Become a regular app, start the reader, and run the AppKit loop (blocks).
    public func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
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
        assert(kind != .commit, "commits are routed off the main thread")
        switch kind {
        case .winNew: handleWinNew(payload)
        case .winMap: routeRef(payload) { $0.mapWindow() }
        case .winUnmap: routeRef(payload) { $0.unmapWindow() }
        case .winDestroy: handleWinDestroy(payload)
        case .winTitle: handleWinTitle(payload)
        case .cursorNamed: handleCursor(payload)
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

    private func handleWinNew(_ payload: Data) {
        guard let spec = try? GuiProto.decode(GuiWinNew.self, from: payload) else { return }
        guard windows[spec.win] == nil else { return }
        guard let window = GuiWindow(spec: spec, channel: channel, host: self) else {
            note("failed to create window \(spec.win)")
            return
        }
        windows[spec.win] = window
        commitRouter.register(win: spec.win, latch: window.latch)
    }

    private func handleWinDestroy(_ payload: Data) {
        guard let ref = try? GuiProto.decode(GuiWinRef.self, from: payload) else { return }
        commitRouter.unregister(win: ref.win)
        windows.removeValue(forKey: ref.win)?.destroy()
    }

    private func handleWinTitle(_ payload: Data) {
        guard let msg = try? GuiProto.decode(GuiWinTitle.self, from: payload) else { return }
        windows[msg.win]?.setTitle(msg.title)
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
        commitRouter.unregister(win: win)
        windows.removeValue(forKey: win)?.destroy()
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
