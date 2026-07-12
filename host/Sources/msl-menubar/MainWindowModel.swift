import AppKit
import Combine
import Foundation
import MSLCore
import MSLMenuBarCore

@MainActor
final class MainWindowModel: ObservableObject {
    @Published private(set) var snapshot = AppSnapshot.empty
    @Published var selectedName: String? {
        didSet {
            if selectedName != oldValue { resetDistroDraft() }
        }
    }
    @Published var destination = AppDestination.distros
    @Published private(set) var isRefreshing = false
    @Published private(set) var finderSetupState = FinderSetupState.checking
    @Published var distroDraft = DistroSettingsDraft(distro: nil, defaultDistro: nil)
    @Published var hostSettingsDraft = HostSettingsDraft.placeholder
    @Published private(set) var pendingRestarts = PendingRestarts()
    @Published var operationInFlight = false
    @Published var finderOperations: [String: FinderDistroOperation] = [:]
    @Published var presentedError: String?

    let home: MSLHome
    let finderActions: AppFinderActions
    let finderPathOpener: @MainActor @Sendable (String) -> Bool
    let finderRefresh: (@MainActor @Sendable () async throws -> Void)?
    private var refreshID = UUID()
    private var savedHostSettings = MSLHostSettings()
    private var hostFacts = SharedVMHardwareFacts(
        activeCPUCount: 1, performanceCoreCount: nil, physicalMemoryMiB: 4096)
    private var loadedHostSettings = false
    private var resetDistroAfterRefresh = false
    private var resetHostAfterRefresh = false

    init(
        home: MSLHome, finderActions: AppFinderActions = .live,
        finderPathOpener: @escaping @MainActor @Sendable (String) -> Bool = {
            NSWorkspace.shared.open(URL(fileURLWithPath: $0))
        },
        initialSnapshot: AppSnapshot = .empty,
        initialFinderSetupState: FinderSetupState = .checking,
        finderRefresh: (@MainActor @Sendable () async throws -> Void)? = nil
    ) {
        precondition(home.root.isFileURL, "MSL home must be a file URL")
        assert(!home.root.path.isEmpty, "MSL home path must not be empty")
        self.home = home
        self.finderActions = finderActions
        self.finderPathOpener = finderPathOpener
        self.finderRefresh = finderRefresh
        snapshot = initialSnapshot
        finderSetupState = initialFinderSetupState
        selectedName = initialSnapshot.selectedName(preserving: nil)
        resetDistroDraft()
    }

    var selectedDistro: AppDistroSnapshot? {
        snapshot.distro(named: selectedName)
    }

    var overview: AppOverviewSnapshot { AppOverviewSnapshot(snapshot: snapshot) }

    var distroChanges: DistroSettingsChanges? {
        guard let selectedDistro, distroDraft.name == selectedDistro.name else { return nil }
        return distroDraft.changes(from: selectedDistro, defaultDistro: snapshot.defaultDistro)
    }

    var distroCanSave: Bool {
        distroDraft.validationError == nil && distroChanges?.isEmpty == false && !operationInFlight
    }

    var distroHasChanges: Bool { distroChanges?.isEmpty == false }

    var hostHasChanges: Bool {
        hostChanges?.isEmpty != true
    }

    var hostChanges: HostSettingsChanges? {
        try? HostSettingsChanges(draft: hostSettingsDraft, baseline: savedHostSettings)
    }

    var hostCanSave: Bool {
        hostSettingsDraft.validationError == nil && hostHasChanges && !operationInFlight
    }

    var selectedNeedsRestart: Bool {
        guard let selectedName else { return false }
        return pendingRestarts.contains(.distro(selectedName))
    }

    var subsystemNeedsRestart: Bool { pendingRestarts.contains(.subsystem) }

    func refresh(policy: PendingRefreshPolicy = .reconcileStopped) {
        guard !operationInFlight else { return }
        let requestID = beginRefresh()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.performRefresh(requestID: requestID, policy: policy)
            } catch {
                self.finish(error: error, requestID: requestID)
            }
        }
    }

    func refreshForFinderOperation() async throws {
        if let finderRefresh {
            try await finderRefresh()
            return
        }
        let requestID = beginRefresh()
        do {
            try await performRefresh(requestID: requestID, policy: .reconcileStopped)
        } catch {
            if refreshID == requestID { isRefreshing = false }
            throw error
        }
    }

    private func beginRefresh() -> UUID {
        let requestID = UUID()
        refreshID = requestID
        isRefreshing = true
        return requestID
    }

    private func performRefresh(requestID: UUID, policy: PendingRefreshPolicy) async throws {
        let home = self.home
        async let snapshot = AppInventoryProbe.snapshot(home: home)
        async let finderEnabled = FSKitAction.status()
        async let hostLoad = AppSettingsActions.loadHost(home: home)
        let values = try await (snapshot, finderEnabled, hostLoad)
        guard refreshID == requestID else {
            throw MSLError.io("inventory refresh was superseded")
        }
        apply(
            snapshot: values.0, finderEnabled: values.1, hostLoad: values.2,
            requestID: requestID, pendingPolicy: policy)
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

    func stopSelected() {
        guard let name = selectedDistro?.name, !operationInFlight else { return }
        operationInFlight = true
        let home = self.home
        Task { @MainActor [weak self] in
            let outcome = await AppRuntimeAction.stop(home: home, name: name)
            self?.completeLifecycle(outcome, effect: .distroStop(name))
        }
    }
}

extension MainWindowModel {
    func saveDistroSettings() {
        guard let distro = selectedDistro, distroCanSave, let changes = distroChanges else {
            return
        }
        operationInFlight = true
        let draft = distroDraft
        let home = self.home
        let preVMActive = snapshot.vmState == "running"
        Task { @MainActor [weak self] in
            do {
                _ = try await AppSettingsActions.saveDistro(
                    home: home, draft: draft, changes: changes)
                let reconciliation = await self?.reconcileRuntime(home: home)
                self?.completeDistroSave(
                    distro: distro, changes: changes, preVMActive: preVMActive,
                    reconciliation: reconciliation)
            } catch {
                self?.operationFailed(error)
            }
        }
    }

    func revertDistroSettings() {
        guard !operationInFlight else { return }
        resetDistroDraft()
    }

    func restartSelectedToApply() {
        guard let name = selectedDistro?.name, selectedNeedsRestart, !operationInFlight else {
            return
        }
        operationInFlight = true
        let home = self.home
        Task { @MainActor [weak self] in
            let outcome = await AppSettingsActions.restartDistro(home: home, name: name)
            self?.completeLifecycle(outcome, effect: .distroRestart(name))
        }
    }

    func saveHostSettings() {
        guard hostCanSave, let changes = hostChanges else { return }
        operationInFlight = true
        let draft = hostSettingsDraft
        let preActive = snapshot.daemonRunning || snapshot.vmState != "stopped"
        let home = self.home
        Task { @MainActor [weak self] in
            do {
                let saved = try await AppSettingsActions.saveHost(
                    home: home, draft: draft, changes: changes)
                let reconciliation = await self?.reconcileRuntime(home: home)
                self?.completeHostSave(
                    saved: saved, preActive: preActive, reconciliation: reconciliation)
            } catch {
                self?.operationFailed(error)
            }
        }
    }

    func revertHostSettings() {
        guard !operationInFlight else { return }
        hostSettingsDraft = HostSettingsDraft(settings: savedHostSettings, facts: hostFacts)
    }

    func restartSubsystemToApply() {
        guard subsystemNeedsRestart, !operationInFlight else { return }
        operationInFlight = true
        let home = self.home
        Task { @MainActor [weak self] in
            let outcome = await AppSettingsActions.restartSubsystem(home: home)
            self?.completeLifecycle(outcome, effect: .subsystemRestart)
        }
    }

    func startSubsystem() {
        runSubsystemAction(effect: .subsystemStart) {
            await AppSettingsActions.startSubsystem(home: $0)
        }
    }

    func shutdownSubsystem() {
        runSubsystemAction(effect: .subsystemStop) {
            await AppSettingsActions.shutdownSubsystem(home: $0)
        }
    }
}

extension MainWindowModel {
    func enableFinder() {
        Task { @MainActor [weak self] in
            switch await FSKitAction.enable() {
            case .ready:
                self?.finderSetupState = .ready
            case .restartRequired:
                self?.finderSetupState = .restartRequired
                self?.presentedError = "Restart your Mac before Finder mounts are available."
            case .failed(let message):
                self?.presentedError = message
            }
        }
    }

    func restartMac() {
        let alert = NSAlert()
        alert.messageText = "Restart your Mac?"
        alert.informativeText = "Open apps will close. Save your work before continuing."
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor [weak self] in
            if let error = await AppRuntimeAction.restartMac() {
                self?.presentedError = error
            }
        }
    }

    private func apply(
        snapshot: AppSnapshot, finderEnabled: Bool, hostLoad: HostSettingsLoad, requestID: UUID,
        pendingPolicy: PendingRefreshPolicy
    ) {
        guard refreshID == requestID else { return }
        self.snapshot = snapshot
        pendingRestarts.reconcile(snapshot: snapshot, policy: pendingPolicy)
        selectedName = snapshot.selectedName(preserving: selectedName)
        applyHostLoad(hostLoad)
        applyDistroRefresh()
        finderSetupState = finderSetupState.refreshed(enabled: finderEnabled)
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

    private func applyHostLoad(_ load: HostSettingsLoad) {
        savedHostSettings = load.settings
        hostFacts = load.facts
        if !loadedHostSettings || resetHostAfterRefresh {
            hostSettingsDraft = HostSettingsDraft(settings: load.settings, facts: load.facts)
        }
        loadedHostSettings = true
        resetHostAfterRefresh = false
    }

    private func applyDistroRefresh() {
        if distroDraft.name != selectedName || resetDistroAfterRefresh { resetDistroDraft() }
        resetDistroAfterRefresh = false
    }

    private func resetDistroDraft() {
        distroDraft = DistroSettingsDraft(
            distro: snapshot.distro(named: selectedName), defaultDistro: snapshot.defaultDistro)
    }

    private func completeDistroSave(
        distro: AppDistroSnapshot, changes: DistroSettingsChanges, preVMActive: Bool,
        reconciliation: RuntimeReconciliation?
    ) {
        let post = reconciliation?.snapshot
        let distroActive = distro.isRunning || post?.distro(named: distro.name)?.isRunning != false
        let vmActive = preVMActive || post?.vmState == "running" || post == nil
        pendingRestarts.recordDistroSave(
            name: distro.name, distroActive: distroActive, vmActive: vmActive, changes: changes)
        if let error = reconciliation?.error { presentedError = error }
        resetDistroAfterRefresh = true
        operationInFlight = false
        refresh()
    }

    private func completeHostSave(
        saved: MSLHostSettings, preActive: Bool, reconciliation: RuntimeReconciliation?
    ) {
        savedHostSettings = saved
        let post = reconciliation?.snapshot
        let postActive = post.map { $0.daemonRunning || $0.vmState != "stopped" } ?? true
        pendingRestarts.recordHostSave(active: preActive || postActive)
        if let error = reconciliation?.error { presentedError = error }
        resetHostAfterRefresh = true
        operationInFlight = false
        refresh()
    }

    private func runSubsystemAction(
        effect: LifecyclePendingEffect,
        _ action: @escaping @Sendable (MSLHome) async -> LifecycleOutcome
    ) {
        guard !operationInFlight else { return }
        operationInFlight = true
        let home = self.home
        Task { @MainActor [weak self] in
            let outcome = await action(home)
            self?.completeLifecycle(outcome, effect: effect)
        }
    }

    private func completeLifecycle(_ outcome: LifecycleOutcome, effect: LifecyclePendingEffect) {
        operationInFlight = false
        pendingRestarts.recordLifecycle(outcome, effect: effect)
        if case .failed(let message) = outcome { presentedError = message }
        if outcome.needsRefresh { refresh(policy: outcome.pendingRefreshPolicy) }
    }

    private func reconcileRuntime(home: MSLHome) async -> RuntimeReconciliation {
        do {
            return RuntimeReconciliation(snapshot: try await AppInventoryProbe.snapshot(home: home))
        } catch {
            return RuntimeReconciliation(error: "Settings saved; runtime refresh failed: \(error)")
        }
    }

    private func operationFailed(_ error: Error) {
        operationInFlight = false
        presentedError = "\(error)"
    }
}

private struct RuntimeReconciliation {
    let snapshot: AppSnapshot?
    let error: String?

    init(snapshot: AppSnapshot) {
        self.snapshot = snapshot
        self.error = nil
    }

    init(error: String) {
        precondition(!error.isEmpty)
        self.snapshot = nil
        self.error = error
    }
}
