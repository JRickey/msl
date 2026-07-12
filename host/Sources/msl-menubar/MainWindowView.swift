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

private struct SourceList: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        List(AppDestination.allCases, selection: $model.destination) { destination in
            Label(destination.rawValue, systemImage: destination.symbolName)
                .tag(destination)
                .accessibilityLabel(destination.rawValue)
        }
        .listStyle(.sidebar)
        .accessibilityLabel("MSL sections")
    }
}

private struct AppToolbar: ToolbarContent {
    @ObservedObject var model: MainWindowModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(action: model.refresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isRefreshing)
            .accessibilityLabel("Refresh subsystem information")
        }
    }
}

private struct DestinationContent: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        if model.destination == .distros {
            DistroLibrary(model: model)
        } else {
            HonestEmptyState(destination: model.destination)
        }
    }
}

private struct DestinationDetail: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        if model.destination == .distros {
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                identity
                actions
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
            Button("Open in Finder", systemImage: "folder", action: model.openFinder)
                .disabled(!distro.finderAvailable)
            Button("Stop", systemImage: "stop.fill") { requestStop() }
                .disabled(!model.snapshot.daemonRunning || !distro.isRunning)
        }
        .controlSize(.large)
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
        DetailGroup(title: "Configuration") {
            DetailRow(label: "Hostname", value: distro.inventory.hostname)
            DetailRow(label: "Default user", value: distro.inventory.defaultUser ?? "root")
            DetailRow(label: "Mac home sharing", value: macShareLabel)
            DetailRow(label: "Rosetta", value: distro.inventory.rosetta ? "On" : "Off")
            DetailRow(label: "Created", value: distro.inventory.createdAt)
        }
    }

    private var finderSection: some View {
        DetailGroup(title: "Finder") {
            if let path = distro.inventory.finderPath {
                DetailRow(label: "Mounted at", value: path)
            } else if model.finderEnabled == false {
                HStack {
                    Text("Finder integration is not set up.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Set Up Finder", action: model.enableFinder)
                }
            } else {
                Text("Not mounted. Mount controls will appear when the mount service is available.")
                    .foregroundStyle(.secondary)
            }
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

    private var macShareLabel: String {
        guard let value = distro.inventory.macShare else { return "Inherit" }
        return value ? "On" : "Off"
    }

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

    private func requestStop() {
        assert(distro.isRunning, "only a running distro can request stop")
        confirmStop = true
    }
}

private struct DetailGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        precondition(!title.isEmpty, "detail group needs a title")
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox(title) {
            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label, value: value)
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
    }
}

private struct HonestEmptyState: View {
    let destination: AppDestination

    var body: some View {
        ContentUnavailableView(
            destination.rawValue, systemImage: destination.symbolName,
            description: Text("This section is not available yet.")
        )
        .accessibilityLabel("\(destination.rawValue). This section is not available yet.")
    }
}
