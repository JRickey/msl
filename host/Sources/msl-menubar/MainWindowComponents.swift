import MSLMenuBarCore
import SwiftUI

struct SourceList: View {
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

struct AppToolbar: ToolbarContent {
    @ObservedObject var model: MainWindowModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button(
                action: { model.refresh() },
                label: { Label("Refresh", systemImage: "arrow.clockwise") }
            )
            .keyboardShortcut("r", modifiers: .command)
            .disabled(model.isRefreshing)
            .accessibilityLabel("Refresh subsystem information")
        }
    }
}

struct FinderRestartBanner: View {
    let restart: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Restart Required").fontWeight(.semibold)
                Text("Restart your Mac to finish enabling Finder integration.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restart Mac", action: restart)
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

struct DetailGroup<Content: View>: View {
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

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label, value: value)
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
    }
}

struct HonestEmptyState: View {
    let destination: AppDestination

    var body: some View {
        ContentUnavailableView(
            destination.rawValue, systemImage: destination.symbolName,
            description: Text("This section is not available yet.")
        )
        .accessibilityLabel("\(destination.rawValue). This section is not available yet.")
    }
}
