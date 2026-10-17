import AppKit
import SuperScreenshotCore

LegacyMigration.runIfNeeded()
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
