import Foundation
import AppKit

public enum AppPaths {
    public static let bundleID = Bundle.main.bundleIdentifier ?? "com.udsy.superscreenshot"
    /// Name of the app's folder in Application Support (and in the temporary directory).
    public static let folderName = "SuperScreenshot"

    public static var defaultExportLocation: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
    }

    /// ~/Library/Application Support/SuperScreenshot
    public static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ensure(base.appendingPathComponent(folderName, isDirectory: true))
    }

    /// Captured media that has not been explicitly saved lives here (and is what History indexes).
    public static var media: URL { ensure(support.appendingPathComponent("Media", isDirectory: true)) }
    public static var history: URL { ensure(support.appendingPathComponent("History", isDirectory: true)) }
    public static var recordings: URL { ensure(support.appendingPathComponent("Recordings", isDirectory: true)) }
    public static var projects: URL { ensure(support.appendingPathComponent("Projects", isDirectory: true)) }
    public static var temporary: URL {
        ensure(FileManager.default.temporaryDirectory.appendingPathComponent(folderName, isDirectory: true))
    }

    /// The user's chosen export folder, created if needed.
    public static var exportLocation: URL {
        ensure(URL(fileURLWithPath: (Defaults[.exportLocation] as NSString).expandingTildeInPath, isDirectory: true))
    }

    @discardableResult
    public static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Whether files can be created in `url` right now: it exists, is a folder (not a file or a placeholder) and the
    /// current user may write to it (not read-only, not on an unmounted or locked volume).
    public static func isWritableDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        return fm.isWritableFile(atPath: url.path)
    }

    /// Returns `url` or, if taken, `name 2.ext`, `name 3.ext`, …
    public static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var i = 2
        while true {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }
}

/// File-name templates, e.g. `Super Screenshot %Y-%m-%d at %H.%M.%S`.
///
/// Tokens: `%Y` year, `%m` month, `%d` day, `%H` hour (24h), `%h` hour (12h), `%M` minute, `%S` second,
/// `%p` AM/PM, `%a` capture type ("Screenshot", "Recording", …), `%A` frontmost app name,
/// `%i` incrementing counter, `%r` 6 random characters, `%%` literal percent.
public enum FileNameTemplate {
    public static let defaultTemplate = "%a %Y-%m-%d at %H.%M.%S"

    public static let tokens: [(token: String, description: String)] = [
        ("%Y", "Year"), ("%m", "Month"), ("%d", "Day"), ("%H", "Hour (24h)"), ("%h", "Hour (12h)"),
        ("%M", "Minute"), ("%S", "Second"), ("%p", "AM/PM"), ("%a", "Capture type"),
        ("%A", "App name"), ("%i", "Counter"), ("%r", "Random"),
    ]

    /// Next value of the `%i` token (editable in Settings).
    public static let counterKey = Defaults.Key<Int>("fileNameCounter", default: 1)

    public static func render(_ template: String, kind: String, appName: String? = nil,
                              date: Date = Date(), advanceCounter: Bool = true) -> String {
        let cal = Calendar.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ v: Int?, _ n: Int = 2) -> String { String(format: "%0\(n)d", v ?? 0) }
        var out = ""
        var it = template.makeIterator()
        var usedCounter = false
        while let ch = it.next() {
            guard ch == "%" else { out.append(ch); continue }
            guard let t = it.next() else { out.append("%"); break }
            switch t {
            case "Y": out += pad(c.year, 4)
            case "m": out += pad(c.month)
            case "d": out += pad(c.day)
            case "H": out += pad(c.hour)
            case "h": out += pad({ let h = (c.hour ?? 0) % 12; return h == 0 ? 12 : h }())
            case "M": out += pad(c.minute)
            case "S": out += pad(c.second)
            case "p": out += (c.hour ?? 0) < 12 ? "AM" : "PM"
            case "a": out += kind
            case "A": out += appName ?? NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
            case "i": out += String(Defaults[counterKey]); usedCounter = true
            case "r": out += String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
            case "%": out += "%"
            default: out += "%"; out.append(t)
            }
        }
        if usedCounter && advanceCounter { Defaults[counterKey] += 1 }
        let sanitized = out.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Super Screenshot" : sanitized
    }
}
