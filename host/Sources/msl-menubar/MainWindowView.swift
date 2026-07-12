import MSLMenuBarCore
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        NavigationSplitView {
            SourceList(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } content: {
            DestinationContent(model: model)
                .navigationSplitViewColumnWidth(min: 360, ideal: 470, max: 620)
        } detail: {
            DestinationDetail(model: model)
        }
        .navigationTitle(model.destination.rawValue)
        .toolbar { AppToolbar(model: model) }
        .alert("msl", isPresented: errorPresented) {
            Button("OK") { model.presentedError = nil }
        } message: {
            Text(model.presentedError ?? "Unknown error")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.presentedError != nil },
            set: { if !$0 { model.presentedError = nil } })
    }
}

private struct DestinationContent: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        if model.destination == .overview {
            OverviewStatusView(model: model)
        } else if model.destination == .distros {
            DistroLibrary(model: model)
        } else {
            HonestEmptyState(destination: model.destination)
        }
    }
}

private struct DestinationDetail: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        if model.destination == .overview {
            OverviewSettingsView(model: model)
        } else if model.destination == .distros {
            DistroDetail(model: model)
        } else {
            HonestEmptyState(destination: model.destination)
        }
    }
}

private struct DistroLibrary: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        Group {
            if model.isRefreshing && model.snapshot.distros.isEmpty {
                ProgressView("Loading distros…")
            } else if model.snapshot.distros.isEmpty {
                ContentUnavailableView(
                    "No Distros Installed", systemImage: "shippingbox",
                    description: Text("Install a Linux distribution to get started."))
            } else {
                distroTable
            }
        }
        .accessibilityLabel("Installed Linux distributions")
    }

    private var distroTable: some View {
        Table(model.snapshot.distros, selection: $model.selectedName) {
            TableColumn("Distro") { distro in
                DistroNameCell(
                    distro: distro, isDefault: model.snapshot.defaultDistro == distro.name)
            }
            .width(min: 180, ideal: 220)
            TableColumn("Status") { distro in
                StatusCell(distro: distro)
            }
            .width(min: 90, ideal: 110)
            TableColumn("Sessions") { distro in
                Text("\(distro.sessions)")
            }
            .width(70)
            TableColumn("Mac Storage") { distro in
                Text(distro.storageLabel(distro.inventory.allocatedBytes))
            }
            .width(min: 100, ideal: 120)
        }
        .contextMenu(forSelectionType: String.self) { names in
            if names.count == 1 {
                Button("Open Shell") { model.openShell() }
            }
        }
    }
}

private struct DistroNameCell: View {
    let distro: AppDistroSnapshot
    let isDefault: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName).fontWeight(.medium)
                if isDefault { Text("Default").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var displayName: String {
        distro.inventory.catalogSelector ?? distro.name.capitalized
    }
}

private struct StatusCell: View {
    let distro: AppDistroSnapshot

    var body: some View {
        Label(distro.state.capitalized, systemImage: "circle.fill")
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(distro.isRunning ? .green : .secondary)
            .font(.callout)
    }
}

private struct DistroDetail: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        if let distro = model.selectedDistro {
            DistroInspector(model: model, distro: distro)
                .id(distro.id)
        } else {
            ContentUnavailableView(
                "Select a Distro", systemImage: "sidebar.right",
                description: Text("Choose an installed distro to see its settings and actions."))
        }
    }
}

private struct DistroInspector: View {
    @ObservedObject var model: MainWindowModel
    let distro: AppDistroSnapshot
    @State private var confirmStop = false
    @State private var confirmUnmount = false
    @State private var confirmRestart = false
    @State private var confirmSubsystemRestart = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                identity
                actions
                if model.selectedNeedsRestart { distroRestartBanner }
                if model.subsystemNeedsRestart { subsystemRestartBanner }
                statusSection
                storageSection
                configurationSection
                finderSection
                networkingSection
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(28)
        }
        .confirmationDialog(
            "Stop \(distro.name)?", isPresented: $confirmStop, titleVisibility: .visible
        ) {
            Button("Stop Distro", role: .destructive, action: model.stopSelected)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(stopMessage)
        }
        .confirmationDialog(
            "Restart \(distro.name) to apply settings?", isPresented: $confirmRestart,
            titleVisibility: .visible
        ) {
            Button("Restart Distro", action: model.restartSelectedToApply)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(restartMessage)
        }
        .confirmationDialog(
            "Unmount \(distro.name) from Finder?", isPresented: $confirmUnmount,
            titleVisibility: .visible
        ) {
            Button("Unmount from Finder", role: .destructive, action: model.unmountFromFinder)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Open Finder files for this distro will no longer be available.")
        }
        .confirmationDialog(
            "Restart the subsystem to apply settings?", isPresented: $confirmSubsystemRestart,
            titleVisibility: .visible
        ) {
            Button("Restart Subsystem", action: model.restartSubsystemToApply)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(subsystemRestartMessage)
        }
    }

    private var identity: some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(distro.name.capitalized).font(.title2).fontWeight(.semibold)
                Text(identitySubtitle).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Open Shell", systemImage: "terminal", action: model.openShell)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
            FinderActionControls(
                model: model, distro: distro, confirmUnmount: $confirmUnmount)
            Button("Stop", systemImage: "stop.fill") { requestStop() }
                .disabled(!model.snapshot.daemonRunning || !distro.isRunning)
        }
        .controlSize(.large)
        .disabled(model.operationInFlight)
        .accessibilityElement(children: .contain)
    }

    private var statusSection: some View {
        DetailGroup(title: "Status") {
            DetailRow(label: "Runtime", value: distro.state.capitalized)
            DetailRow(label: "Sessions", value: "\(distro.sessions)")
            DetailRow(label: "Default distro", value: isDefault ? "Yes" : "No")
        }
    }

    private var storageSection: some View {
        DetailGroup(title: "Storage") {
            DetailRow(
                label: "Mac allocation",
                value: distro.storageLabel(distro.inventory.allocatedBytes))
            DetailRow(
                label: "Linux capacity",
                value: distro.storageLabel(distro.inventory.capacityBytes))
            DetailRow(label: "Linux free", value: "Available when the mount service reports it")
        }
    }

    private var configurationSection: some View {
        Form {
            Section("Configuration") {
                TextField("Hostname", text: $model.distroDraft.hostname)
                TextField("Default user", text: $model.distroDraft.defaultUser)
                Picker("Mac home sharing", selection: $model.distroDraft.macShare) {
                    ForEach(MacShareChoice.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                Toggle("Use Rosetta for x86-64 Linux binaries", isOn: $model.distroDraft.rosetta)
                Text("Rosetta is normally off and is only needed for x86-64 Linux software.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Default distro", isOn: $model.distroDraft.isDefault)
                    .disabled(isDefault)
                LabeledContent("Created", value: distro.inventory.createdAt)
                if let error = model.distroDraft.validationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                if model.distroHasChanges { distroEditActions }
            }
        }
        .disabled(model.operationInFlight)
    }

    private var distroEditActions: some View {
        HStack {
            Spacer()
            Button("Revert", action: model.revertDistroSettings)
            Button("Save", action: model.saveDistroSettings)
                .buttonStyle(.borderedProminent)
                .disabled(!model.distroCanSave)
        }
    }

    private var distroRestartBanner: some View {
        RestartBanner(
            title: "Restart to Apply",
            message: "Hostname or Mac sharing changes are waiting for a distro restart.",
            buttonTitle: "Restart to Apply", action: { confirmRestart = true }
        )
        .disabled(model.operationInFlight)
    }

    private var subsystemRestartBanner: some View {
        RestartBanner(
            title: "Subsystem Restart Required",
            message: "Rosetta or shared VM changes are waiting for a subsystem restart.",
            buttonTitle: "Restart Subsystem", action: { confirmSubsystemRestart = true }
        )
        .disabled(model.operationInFlight)
    }

    private var finderSection: some View {
        DetailGroup(title: "Finder") {
            if let path = distro.inventory.finderPath {
                DetailRow(label: "Mounted at", value: path)
            } else {
                finderSetupContent
            }
        }
    }

    @ViewBuilder
    private var finderSetupContent: some View {
        switch model.finderSetupState {
        case .checking:
            ProgressView("Checking Finder integration…")
        case .disabled:
            HStack {
                Text("Finder integration is not set up.").foregroundStyle(.secondary)
                Spacer()
                Button("Set Up Finder", action: model.enableFinder)
            }
        case .ready:
            Text("Ready to mount. Use Mount in Finder above to browse and edit Linux files.")
                .foregroundStyle(.secondary)
        case .restartRequired:
            FinderRestartBanner(restart: model.restartMac)
        }
    }

    private var networkingSection: some View {
        DetailGroup(title: "Networking") {
            DetailRow(label: "Forwarded ports", value: portLabel)
        }
    }

    private var identitySubtitle: String {
        var parts = [distro.state.capitalized, "\(distro.sessions) sessions"]
        if isDefault { parts.append("Default") }
        return parts.joined(separator: " · ")
    }

    private var isDefault: Bool { model.snapshot.defaultDistro == distro.name }

    private var portLabel: String {
        guard !model.snapshot.forwardedPorts.isEmpty else { return "None" }
        return model.snapshot.forwardedPorts.map(String.init).joined(separator: ", ")
    }

    private var stopMessage: String {
        if distro.sessions > 0 {
            return "This distro has \(distro.sessions) live session(s). They will be closed."
        }
        return "Running processes in this distro will be stopped."
    }

    private var restartMessage: String {
        if distro.sessions > 0 {
            return "This will stop \(distro.sessions) live session(s), then start the distro again."
        }
        return "The distro will stop and start again."
    }

    private var subsystemRestartMessage: String {
        "Every active distro and all \(model.overview.liveSessions) live session(s) will stop."
    }

    private func requestStop() {
        assert(distro.isRunning, "only a running distro can request stop")
        confirmStop = true
    }
}
