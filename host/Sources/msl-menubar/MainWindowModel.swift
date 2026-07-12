import AppKit
import Combine
import Foundation
import MSLCore
import MSLMenuBarCore

@MainActor
final class MainWindowModel: ObservableObject {
    @Published private(set) var snapshot = AppSnapshot.empty
    @Published var selectedName: String?
    @Published var destination = AppDestination.distros
    @Published private(set) var isRefreshing = false
    @Published private(set) var finderEnabled: Bool?
    @Published var presentedError: String?

    private let home: MSLHome
    private var refreshID = UUID()

    init(home: MSLHome) {
        self.home = home
    }

    var selectedDistro: AppDistroSnapshot? {
        snapshot.distro(named: selectedName)
    }

    func refresh() {
        let requestID = UUID()
        refreshID = requestID
        isRefreshing = true
        let home = self.home
        Task { @MainActor [weak self] in
            do {
                async let snapshot = AppInventoryProbe.snapshot(home: home)
                async let finderEnabled = FSKitAction.status()
                let values = try await (snapshot, finderEnabled)
                self?.apply(snapshot: values.0, finderEnabled: values.1, requestID: requestID)
            } catch {
                self?.finish(error: error, requestID: requestID)
            }
        }
    }

    func openShell() {
        guard let name = selectedDistro?.name else { return }
        let home = self.home
        Task { @MainActor [weak self] in
            if let error = await AppRuntimeAction.openShell(home: home, name: name) {
                self?.presentedError = error
            }
        }
    }

    func openFinder() {
        guard let path = selectedDistro?.inventory.finderPath else {
            presentedError = "Mount this distro before opening it in Finder."
            return
        }
        let opened = NSWorkspace.shared.open(URL(fileURLWithPath: path))
        if !opened { presentedError = "Finder could not open \(path)." }
    }

    func stopSelected() {
        guard let name = selectedDistro?.name else { return }
        let home = self.home
        Task { @MainActor [weak self] in
            if let error = await AppRuntimeAction.stop(home: home, name: name) {
                self?.presentedError = error
            } else {
                self?.refresh()
            }
        }
    }

    func enableFinder() {
        Task { @MainActor [weak self] in
            switch await FSKitAction.enable() {
            case .ready:
                self?.finderEnabled = true
            case .restartRequired:
                self?.finderEnabled = true
                self?.presentedError = "Restart your Mac before Finder mounts are available."
            case .failed(let message):
                self?.presentedError = message
            }
        }
    }

    private func apply(snapshot: AppSnapshot, finderEnabled: Bool, requestID: UUID) {
        guard refreshID == requestID else { return }
        selectedName = snapshot.selectedName(preserving: selectedName)
        self.snapshot = snapshot
        self.finderEnabled = finderEnabled
        isRefreshing = false
        assert(selectedName == nil || snapshot.distro(named: selectedName) != nil)
        assert(!snapshot.vmState.isEmpty)
    }

    private func finish(error: Error, requestID: UUID) {
        guard refreshID == requestID else { return }
        let message = "Could not load msl: \(error.localizedDescription)"
        presentedError = message
        isRefreshing = false
        assert(!message.isEmpty)
        assert(refreshID == requestID)
    }
}

enum AppRuntimeAction {
    private static let queue = DispatchQueue(label: "dev.msl.app.runtime")

    static func openShell(home: MSLHome, name: String) async -> String? {
        await run { try LauncherRuntime.openShell(home: home, name: name) }
    }

    static func stop(home: MSLHome, name: String) async -> String? {
        await run { try DaemonClient.down(home, name: name, all: false) }
    }

    private static func run(_ body: @escaping @Sendable () throws -> Void) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async {
                do {
                    try body()
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: "\(error)")
                }
            }
        }
    }
}
