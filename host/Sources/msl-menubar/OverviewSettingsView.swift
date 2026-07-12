import SwiftUI

struct OverviewStatusView: View {
    @ObservedObject var model: MainWindowModel

    var body: some View {
        List {
            Section("Subsystem") {
                DetailRow(
                    label: "Daemon", value: model.overview.daemonRunning ? "Running" : "Stopped")
                DetailRow(label: "Shared VM", value: model.overview.vmState.capitalized)
                DetailRow(label: "Installed distros", value: "\(model.overview.installedDistros)")
                DetailRow(label: "Running distros", value: "\(model.overview.runningDistros)")
                DetailRow(label: "Live sessions", value: "\(model.overview.liveSessions)")
            }
            Section("Memory") { memoryRows }
            Section("Localhost") {
                DetailRow(label: "Forwarded ports", value: portLabel)
            }
        }
        .safeAreaInset(edge: .bottom) { lifecycleActions }
        .accessibilityLabel("Subsystem overview")
    }

    @ViewBuilder
    private var memoryRows: some View {
        if let memory = model.overview.memory {
            DetailRow(label: "Target", value: "\(memory.targetMiB) MiB")
            DetailRow(label: "Maximum", value: "\(memory.maxMiB) MiB")
            DetailRow(label: "Available", value: "\(memory.availableMiB) MiB")
        } else {
            Text("Available while the shared VM is running.").foregroundStyle(.secondary)
        }
    }

    private var portLabel: String {
        guard !model.overview.forwardedPorts.isEmpty else { return "None" }
        return model.overview.forwardedPorts.map(String.init).joined(separator: ", ")
    }

    private var lifecycleActions: some View {
        HStack {
            if model.overview.daemonRunning {
                Button("Shut Down", systemImage: "power", action: model.shutdownSubsystem)
            } else {
                Button("Start", systemImage: "play.fill", action: model.startSubsystem)
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding(12)
        .background(.bar)
        .disabled(model.operationInFlight)
    }
}

struct OverviewSettingsView: View {
    @ObservedObject var model: MainWindowModel
    @State private var confirmRestart = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.subsystemNeedsRestart { restartBanner }
                settingsForm
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(28)
        }
        .confirmationDialog(
            "Restart the subsystem to apply settings?", isPresented: $confirmRestart,
            titleVisibility: .visible
        ) {
            Button("Restart Subsystem", action: model.restartSubsystemToApply)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(subsystemRestartMessage)
        }
    }

    private var settingsForm: some View {
        Form {
            Section("Shared Virtual Machine") {
                Toggle("Automatic CPU allocation", isOn: $model.hostSettingsDraft.automaticCPU)
                if !model.hostSettingsDraft.automaticCPU { cpuPicker }
                Toggle(
                    "Automatic memory allocation", isOn: $model.hostSettingsDraft.automaticMemory)
                if !model.hostSettingsDraft.automaticMemory { memoryStepper }
            }
            Section("Behavior") {
                Stepper(
                    "Idle shutdown: \(idleLabel)", value: $model.hostSettingsDraft.idleTimeoutS,
                    in: 0...86_400, step: 30)
                Toggle("Share Mac home folder", isOn: $model.hostSettingsDraft.shareHome)
                Toggle(
                    "Allow Linux-to-Mac command interop",
                    isOn: $model.hostSettingsDraft.interopEnabled)
            }
            if let error = model.hostSettingsDraft.validationError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if model.hostHasChanges { hostEditActions }
        }
        .disabled(model.operationInFlight)
    }

    private var cpuPicker: some View {
        Picker("Virtual CPUs", selection: $model.hostSettingsDraft.cpuCount) {
            ForEach(1...model.hostSettingsDraft.cpuUpperBound, id: \.self) { count in
                Text("\(count)").tag(count)
            }
        }
    }

    private var memoryStepper: some View {
        Stepper(
            "Memory: \(model.hostSettingsDraft.memoryMiB) MiB",
            value: $model.hostSettingsDraft.memoryMiB,
            in: 1024...model.hostSettingsDraft.memoryUpperBoundMiB, step: 1024)
    }

    private var hostEditActions: some View {
        HStack {
            Spacer()
            Button("Revert", action: model.revertHostSettings)
            Button("Save", action: model.saveHostSettings)
                .buttonStyle(.borderedProminent)
                .disabled(!model.hostCanSave)
        }
    }

    private var restartBanner: some View {
        RestartBanner(
            title: "Restart to Apply",
            message: "Shared VM settings will apply after the subsystem restarts.",
            buttonTitle: "Restart to Apply", action: { confirmRestart = true }
        )
        .disabled(model.operationInFlight)
    }

    private var idleLabel: String {
        model.hostSettingsDraft.idleTimeoutS == 0
            ? "Never" : "\(model.hostSettingsDraft.idleTimeoutS) seconds"
    }

    private var subsystemRestartMessage: String {
        "Every active distro and all \(model.overview.liveSessions) live session(s) will stop."
    }
}

struct RestartBanner: View {
    let title: String
    let message: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.semibold)
                Text(message).foregroundStyle(.secondary)
            }
            Spacer()
            Button(buttonTitle, action: action)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
