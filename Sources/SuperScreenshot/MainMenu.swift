import AppKit
import SuperScreenshotCore

/// Standard menu bar, visible while a document window (Annotate, Studio, video editor) shows the Dock icon.
/// Editors handle their own ⌘-shortcuts at the window level first, so these items are the fallback path.
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()

        let app = NSMenu(title: "Super Screenshot")
        app.addItem(withTitle: "About Super Screenshot", action: #selector(MenuActions.about), keyEquivalent: "").target = MenuActions.shared
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(MenuActions.settings), keyEquivalent: ",").target = MenuActions.shared
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Super Screenshot", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Super Screenshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, to: main)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Open Image…", action: #selector(MenuActions.openImage), keyEquivalent: "o").target = MenuActions.shared
        file.addItem(withTitle: "Open From Clipboard", action: #selector(MenuActions.openClipboard), keyEquivalent: "").target = MenuActions.shared
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        add(file, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        add(edit, to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        add(window, to: main)
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}

@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()
    @objc func about() { Services.preferences.show(pane: "about") }
    @objc func settings() { Services.preferences.show(pane: nil) }
    @objc func openImage() { Services.annotate.openWithPanel() }
    @objc func openClipboard() { Services.annotate.openFromClipboard() }
}
