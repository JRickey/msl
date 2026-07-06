import AppKit
import Foundation

/// Modeless install progress; byte downloads use a determinate bar, blocking
/// build and verification steps use the spinner.
@MainActor
final class ProgressPanel {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var spinner: NSProgressIndicator?
    private var bar: NSProgressIndicator?

    func show(message: String, fraction: Double? = nil) {
        assert(!message.isEmpty, "progress message must not be empty")
        let panel = self.panel ?? build()
        self.panel = panel
        let wasVisible = panel.isVisible
        label?.stringValue = message
        updateIndicators(fraction: fraction)
        if !wasVisible { panel.center() }
        panel.orderFrontRegardless()
    }

    func hide() {
        spinner?.stopAnimation(nil)
        panel?.orderOut(nil)
    }

    private func build() -> NSPanel {
        let frame = NSRect(x: 0, y: 0, width: 420, height: 124)
        let panel = NSPanel(
            contentRect: frame, styleMask: [.titled, .utilityWindow],
            backing: .buffered, defer: false)
        panel.title = "msl"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        let spinner = makeSpinner()
        let bar = makeBar()
        let label = makeLabel()
        let content = panel.contentView
        assert(content != nil, "an NSPanel provides a content view")
        content?.addSubview(spinner)
        content?.addSubview(bar)
        content?.addSubview(label)
        self.spinner = spinner
        self.bar = bar
        self.label = label
        return panel
    }

    private func makeSpinner() -> NSProgressIndicator {
        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 58, width: 24, height: 24))
        spinner.style = .spinning
        spinner.isIndeterminate = true
        return spinner
    }

    private func makeBar() -> NSProgressIndicator {
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 32, width: 380, height: 16))
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0
        bar.isHidden = true
        return bar
    }

    private func makeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 56, y: 58, width: 344, height: 24)
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    private func updateIndicators(fraction: Double?) {
        if let fraction {
            spinner?.stopAnimation(nil)
            spinner?.isHidden = true
            bar?.isHidden = false
            bar?.doubleValue = min(1, max(0, fraction))
            return
        }
        bar?.isHidden = true
        spinner?.isHidden = false
        spinner?.startAnimation(nil)
    }
}
