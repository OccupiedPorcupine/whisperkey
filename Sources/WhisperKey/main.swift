import AppKit

// Entry point. We run as an "accessory" app: no Dock icon, no menu bar
// (the app menu), just our own NSStatusItem. This mirrors LSUIElement=true
// in Info.plist and works even when launched as a bare binary.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
