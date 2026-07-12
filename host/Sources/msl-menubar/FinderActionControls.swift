import MSLMenuBarCore
import SwiftUI

struct FinderActionControls: View {
    @ObservedObject var model: MainWindowModel
    let distro: AppDistroSnapshot
    @Binding var confirmUnmount: Bool

    @ViewBuilder
    var body: some View {
        Button(action: model.openFinder) {
            if let operation {
                ProgressView().controlSize(.small)
                Text(operation == .mounting ? "Mounting…" : "Unmounting…")
            } else {
                Label(primaryTitle, systemImage: primarySymbol)
            }
        }
        .disabled(primaryDisabled)
        if distro.finderAvailable {
            Menu {
                Button("Unmount from Finder", systemImage: "eject", role: .destructive) {
                    confirmUnmount = true
                }
            } label: {
                Label("Finder Options", systemImage: "ellipsis.circle")
            }
            .disabled(operation != nil || model.operationInFlight)
        }
    }

    private var operation: FinderDistroOperation? {
        model.finderOperation(for: distro.name)
    }

    private var primaryTitle: String {
        distro.finderAvailable ? "Open in Finder" : "Mount in Finder"
    }

    private var primarySymbol: String {
        distro.finderAvailable ? "folder" : "externaldrive.badge.plus"
    }

    private var primaryDisabled: Bool {
        if model.operationInFlight { return true }
        if operation != nil { return true }
        if distro.finderAvailable { return false }
        return model.finderSetupState != .ready
    }
}
