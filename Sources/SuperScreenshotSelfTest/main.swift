import AppKit
import SuperScreenshotCore

// Headless checks for pure logic (no XCTest in the Command Line Tools toolchain).
// Run: swift run SuperScreenshotSelfTest   — exits non-zero on failure.
// Modules add cases by appending to `SelfTest.cases` in Sources/SuperScreenshotSelfTest/<Module>Tests.swift.

var failures = 0
func check(_ cond: @autoclosure () -> Bool, _ msg: String, file: String = #fileID, line: Int = #line) {
    if !cond() { failures += 1; print("✗ \(file):\(line) \(msg)") }
}

enum SelfTest {
    nonisolated(unsafe) static var cases: [(String, () -> Void)] = []
}

final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>? }

/// Runs async work to completion from the synchronous self-test loop.
func blocking<T>(_ body: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    let box = ResultBox<T>(), done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return box.result!
}

// Core
SelfTest.cases.append(("FileNameTemplate", {
    var c = DateComponents(); c.year = 2026; c.month = 3; c.day = 7; c.hour = 14; c.minute = 5; c.second = 9
    let d = Calendar.current.date(from: c)!
    check(FileNameTemplate.render("%a %Y-%m-%d at %H.%M.%S", kind: "Screenshot", date: d) == "Screenshot 2026-03-07 at 14.05.09", "default template")
    check(FileNameTemplate.render("%h%p 100%%", kind: "x", date: d) == "02PM 100%", "12h + literal percent")
    check(FileNameTemplate.render("a/b:c", kind: "x", date: d) == "a-b.c", "sanitizes path chars")
}))
SelfTest.cases.append(("Defaults", {
    let suite = UserDefaults(suiteName: "superscreenshot.selftest")!
    suite.removePersistentDomain(forName: "superscreenshot.selftest")
    Defaults.store = suite
    let k = Defaults.Key<ImageFormat>("t.format", default: .png)
    check(Defaults[k] == .png, "default value")
    Defaults[k] = .jpeg
    check(Defaults[k] == .jpeg && suite.string(forKey: "t.format") == "jpeg", "enum stored as raw string")
    let s = Defaults.Key<Set<AfterCaptureAction>>("t.set", default: [])
    Defaults[s] = [.save, .pin]
    check(Defaults[s] == [.save, .pin], "set roundtrip")
    let o = Defaults.Key<CodableRect?>("t.opt", default: nil)
    Defaults[o] = CodableRect(CGRect(x: 1, y: 2, width: 3, height: 4))
    check(Defaults[o]?.cgRect == CGRect(x: 1, y: 2, width: 3, height: 4), "optional struct")
    Defaults[o] = nil
    check(Defaults[o] == nil, "optional cleared")
    Defaults.store = .standard
}))
SelfTest.cases.append(("LegacyMigration paths", {
    let old = "/Users/u/Library/Application Support/Shotcraft", new = "/Users/u/Library/Application Support/SuperScreenshot"
    func r(_ v: Any) -> Any { LegacyMigration.rewritingPaths(in: v, from: old, to: new) }
    check(r(old + "/Media/a b.png") as? String == new + "/Media/a b.png", "path inside the folder")
    check(r(old) as? String == new, "the folder itself")
    check(r(old + "Backup/x.png") as? String == old + "Backup/x.png", "sibling folder with the same prefix untouched")
    check(r("/Users/u/Desktop") as? String == "/Users/u/Desktop", "unrelated path untouched")
    let oldURL = URL(fileURLWithPath: old + "/Recordings/clip.mp4").absoluteString
    check(r(oldURL) as? String == URL(fileURLWithPath: new + "/Recordings/clip.mp4").absoluteString, "file URL (percent-encoded)")
    check(r("https://example.com\(old)/x") as? String == "https://example.com\(old)/x", "web URL untouched")
    let domain = r(["exportLocation": old + "/Exports", "recent": [old + "/Projects/p.json", "/tmp/q"],
                    "count": 3, "flag": true]) as? [String: Any]
    check(domain?["exportLocation"] as? String == new + "/Exports", "dictionary value")
    check(domain?["recent"] as? [String] == [new + "/Projects/p.json", "/tmp/q"], "array inside dictionary")
    check(domain?["count"] as? Int == 3 && domain?["flag"] as? Bool == true, "non-string values kept")
    struct Entry: Codable, Equatable { var url: URL; var date: Date }
    let entries = [Entry(url: URL(fileURLWithPath: old + "/Media/s.png"), date: Date(timeIntervalSince1970: 7))]
    let json = try! JSONEncoder().encode(entries)
    let back = (r(json) as? Data).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) }
    check(back == [Entry(url: URL(fileURLWithPath: new + "/Media/s.png"), date: Date(timeIntervalSince1970: 7))],
          "JSON-encoded Data (Defaults / History index)")
    let opaque = Data([0x62, 0x70, 0x6c, 0x69, 0x73, 0x74])
    check(r(opaque) as? Data == opaque, "non-JSON Data untouched")
}))
SelfTest.cases.append(("LegacyMigration move", {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("superscreenshot-migration-\(UUID().uuidString)")
    let (domain, legacyDomain) = ("superscreenshot.selftest.migrated", "superscreenshot.selftest.legacy")
    let defaults = UserDefaults.standard
    defer {
        try? fm.removeItem(at: base)
        defaults.removePersistentDomain(forName: domain); defaults.removePersistentDomain(forName: legacyDomain)
    }
    let old = base.appendingPathComponent("Shotcraft"), new = base.appendingPathComponent(AppPaths.folderName)
    let shot = old.appendingPathComponent("Media/Screenshot 1.png")
    try? fm.createDirectory(at: shot.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? fm.createDirectory(at: old.appendingPathComponent("History"), withIntermediateDirectories: true)
    try? fm.createDirectory(at: old.appendingPathComponent("Projects"), withIntermediateDirectories: true)
    try? Data([1]).write(to: shot)
    try? JSONEncoder().encode(["items": [["url": shot]]]).write(to: old.appendingPathComponent("History/history.json"))
    try? JSONEncoder().encode(["sourcePath": shot.path]).write(to: old.appendingPathComponent("Projects/p.shotcraft"))
    defaults.setPersistentDomain(["customWallpaperPath": shot.path, "playSounds": false], forName: legacyDomain)

    check(LegacyMigration.migrate(supportBase: base, domain: domain, legacyDomain: legacyDomain), "preferences copied")
    let moved = new.appendingPathComponent("Media/Screenshot 1.png")
    check(!fm.fileExists(atPath: old.path) && fm.fileExists(atPath: moved.path), "folder moved")
    let history = (try? Data(contentsOf: new.appendingPathComponent("History/history.json")))
        .flatMap { try? JSONDecoder().decode([String: [[String: URL]]].self, from: $0) }
    check(history?["items"]?.first?["url"] == moved, "history index re-pointed")
    let sidecar = (try? Data(contentsOf: new.appendingPathComponent("Projects/p.shotcraft")))
        .flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
    check(sidecar?["sourcePath"] == moved.path, "sidecar project re-pointed")
    let prefs = defaults.persistentDomain(forName: domain)
    check(prefs?["customWallpaperPath"] as? String == moved.path && prefs?["playSounds"] as? Bool == false, "preferences re-pointed")
    defaults.setPersistentDomain(["playSounds": true], forName: domain)
    check(!LegacyMigration.migrate(supportBase: base, domain: domain, legacyDomain: legacyDomain)
          && defaults.persistentDomain(forName: domain)?["playSounds"] as? Bool == true, "runs once: existing preferences win")
}))
SelfTest.cases.append(("AppAction", {
    check(AppAction.captureArea.urlCommand == "capture-area", "url command kebab-case")
    check(Set(AppAction.allCases.compactMap(\.defaultShortcut)).count == AppAction.allCases.compactMap(\.defaultShortcut).count, "unique default shortcuts")
}))
SelfTest.cases.append(("ScreenGeometry", {
    let r = CGRect(x: 10, y: 20, width: 30, height: 40)
    check(ScreenGeometry.cocoaRect(fromCG: ScreenGeometry.cgRect(fromCocoa: r)) == r, "cocoa↔cg roundtrip")
}))

registerModuleTests()
for (name, run) in SelfTest.cases {
    let before = failures
    run()
    print(failures == before ? "✓ \(name)" : "✗ \(name)")
}
print(failures == 0 ? "All self-tests passed." : "\(failures) failure(s).")
exit(failures == 0 ? 0 : 1)
