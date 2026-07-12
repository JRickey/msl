import AppKit

let application = NSApplication.shared
let controller = AppDelegate()
application.delegate = controller
let activationChanged = application.setActivationPolicy(.regular)
assert(activationChanged, "msl must become a regular Dock application")
application.run()
