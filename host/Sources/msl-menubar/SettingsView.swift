import SwiftUI

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show MSL in the menu bar", isOn: $model.showMenuBarItem)
                Text("Keep quick subsystem and distro actions available from the menu bar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520, height: 220)
    }
}
