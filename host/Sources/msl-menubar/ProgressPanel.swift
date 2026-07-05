import AppKit
import Foundation

/// A minimal indeterminate-progress panel shown while an install runs. One
/// panel is reused across serialized installs; `show` retitles it, `hide` orders
/// it out. Deliberately modeless: the app has no main window to attach to.
@MainActor
final class ProgressPanel {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var spinner: NSProgressIndicator?

    func show(message: String) {
        assert(!message.isEmpty, "progress message must not be empty")
        let panel = self.panel ?? build()
        self.panel = panel
        label?.stringValue = message
        spinner?.startAnimation(nil)
        panel.center()
        panel.orderFrontRegardless()
    }

    func hide() {
        spinner?.stopAnimation(nil)
        panel?.orderOut(nil)
    }

    private func build() -> NSPanel {
        let frame = NSRect(x: 0, y: 0, width: 360, height: 96)
        let panel = NSPanel(
            contentRect: frame, styleMask: [.titled, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = "msl"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        let spinner = makeSpinner()
        let label = makeLabel()
        let content = panel.contentView
        assert(content != nil, "an NSPanel provides a content view")
        content?.addSubview(spinner)
        content?.addSubview(label)
        self.spinner = spinner
        self.label = label
        return panel
    }

    private func makeSpinner() -> NSProgressIndicator {
        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 36, width: 24, height: 24))
        spinner.style = .spinning
        spinner.isIndeterminate = true
        return spinner
    }

    private func makeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 56, y: 36, width: 284, height: 24)
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }
}
