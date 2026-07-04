import AppKit

let application = NSApplication.shared
let controller = AppDelegate()
application.delegate = controller
application.setActivationPolicy(.accessory)
application.run()
