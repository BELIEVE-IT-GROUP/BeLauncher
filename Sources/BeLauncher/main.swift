import AppKit

// Menu-bar only: no Dock icon, no main window (LSUIElement is also set in Info.plist).
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
