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

/// Runs async work to completion from the synchronous self-test loop (the main thread blocks meanwhile).
func blocking<T>(_ body: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    let box = ResultBox<T>(), done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return box.result!
}

/// Like `blocking`, for work that needs the main actor or main-queue callbacks: pumps the main run loop while waiting.
func blockingOnMain<T>(timeout: TimeInterval = 120, _ body: @escaping @MainActor () async throws -> T) -> Result<T, Error> {
    let box = ResultBox<T>()
    Task { @MainActor in
        do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
    }
    let deadline = Date().addingTimeInterval(timeout)
    while box.result == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    return box.result ?? .failure(NSError(domain: "SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "timed out after \(Int(timeout)) s"]))
}

/// Resident memory of this process, for "memory stays flat" checks.
func residentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? info.resident_size : 0
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
SelfTest.cases.append(("LegacyMigration resumable", {
    // A launch died after the new folder was created but before the old one was moved (or the move was only
    // half done): the old files must still be carried over, and the old folder must survive until it is empty.
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("superscreenshot-migration-\(UUID().uuidString)")
    let (domain, legacyDomain) = ("superscreenshot.selftest.resume", "superscreenshot.selftest.resume.legacy")
    defer { try? fm.removeItem(at: base); UserDefaults.standard.removePersistentDomain(forName: domain) }
    let old = base.appendingPathComponent("Shotcraft"), new = base.appendingPathComponent(AppPaths.folderName)
    for dir in ["Media", "History"] { try? fm.createDirectory(at: old.appendingPathComponent(dir), withIntermediateDirectories: true) }
    try? fm.createDirectory(at: new.appendingPathComponent("Media"), withIntermediateDirectories: true)
    let oldShot = old.appendingPathComponent("Media/old.png")
    try? Data([1]).write(to: oldShot)
    try? Data([2]).write(to: new.appendingPathComponent("Media/new.png"))
    try? Data([3]).write(to: old.appendingPathComponent("Media/both.png"))
    try? Data([4]).write(to: new.appendingPathComponent("Media/both.png"))
    try? JSONEncoder().encode(["items": [["url": oldShot]]]).write(to: old.appendingPathComponent("History/history.json"))
    LegacyMigration.migrate(supportBase: base, domain: domain, legacyDomain: legacyDomain)
    check(fm.fileExists(atPath: new.appendingPathComponent("Media/old.png").path), "old file merged into the new folder")
    check((try? Data(contentsOf: new.appendingPathComponent("Media/new.png"))) == Data([2]), "new folder's own file untouched")
    check((try? Data(contentsOf: new.appendingPathComponent("Media/both.png"))) == Data([4]), "a name present on both sides keeps the new copy")
    check((try? Data(contentsOf: old.appendingPathComponent("Media/both.png"))) == Data([3]), "…and the old copy is left in the old folder, not deleted")
    check(fm.fileExists(atPath: old.path), "old folder kept while something is still in it")
    let history = (try? Data(contentsOf: new.appendingPathComponent("History/history.json")))
        .flatMap { try? JSONDecoder().decode([String: [[String: URL]]].self, from: $0) }
    check(history?["items"]?.first?["url"] == new.appendingPathComponent("Media/old.png"), "merged history index re-pointed")
    try? fm.removeItem(at: old.appendingPathComponent("Media/both.png"))
    LegacyMigration.migrate(supportBase: base, domain: domain, legacyDomain: legacyDomain)
    check(!fm.fileExists(atPath: old.path), "old folder removed once it is empty")
}))
SelfTest.cases.append(("Export location probing", {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent("superscreenshot-export-\(UUID().uuidString)")
    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    let readOnly = base.appendingPathComponent("ReadOnly")
    try? fm.createDirectory(at: readOnly, withIntermediateDirectories: true)
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path); try? fm.removeItem(at: base) }
    check(AppPaths.isWritableDirectory(base), "a normal folder is writable")
    check(!AppPaths.isWritableDirectory(base.appendingPathComponent("missing")), "a missing folder is not")
    let file = base.appendingPathComponent("file.txt")
    try? Data("x".utf8).write(to: file)
    check(!AppPaths.isWritableDirectory(file), "a file where the folder should be is not")
    try? fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
    check(getuid() == 0 || !AppPaths.isWritableDirectory(readOnly), "a chmod 0500 folder is not writable")

    // The pipeline falls back to the library: a broken export location yields nil, never a lost capture.
    let suite = UserDefaults(suiteName: "superscreenshot.selftest.export")!
    suite.removePersistentDomain(forName: "superscreenshot.selftest.export")
    Defaults.store = suite
    defer { Defaults.store = .standard }
    Defaults[.exportLocation] = file.path
    check(MainActor.assumeIsolated { MediaPipeline.usableExportLocation() } == nil, "export location that is a file → unusable")
    Defaults[.exportLocation] = base.appendingPathComponent("New Folder").path
    check(MainActor.assumeIsolated { MediaPipeline.usableExportLocation() } != nil, "missing export folder is created and used")
    if getuid() != 0 {
        Defaults[.exportLocation] = readOnly.path
        check(MainActor.assumeIsolated { MediaPipeline.usableExportLocation() } == nil, "read-only export folder → unusable")
    }
}))
SelfTest.cases.append(("Atomic exclusive image writes", {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("superscreenshot-write-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let ctx = ImageTools.context(width: 4, height: 4)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let red = ctx.makeImage()!
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    let blue = ctx.makeImage()!
    let url = dir.appendingPathComponent("shot.png")
    check((try? ImageTools.write(red, to: url, format: .png, replacing: false)) != nil, "first write succeeds")
    let redBytes = try? Data(contentsOf: url)
    var refused = false
    do { try ImageTools.write(blue, to: url, format: .png, replacing: false) } catch ImageError.fileExists { refused = true } catch {}
    check(refused, "second exclusive write is refused")
    check((try? Data(contentsOf: url)) == redBytes, "…and the existing file is byte-for-byte untouched")
    check((try? ImageTools.write(blue, to: url, format: .png, replacing: true)) != nil, "explicit replace still works")
    check((try? Data(contentsOf: url)) != redBytes, "replaced content differs")
    let leftovers = (try? fm.contentsOfDirectory(atPath: dir.path))?.filter { $0 != "shot.png" } ?? []
    check(leftovers.isEmpty, "no temporary files left behind: \(leftovers)")
    check(ImageTools.pngData(ImageTools.load(url)!) != nil, "written file decodes")

    // Two captures in the same second: the pipeline picks the next free name instead of overwriting.
    let first = MainActor.assumeIsolated { MediaPipeline.writeCapture(red, named: "Screenshot.png", in: dir, format: .png, scale: 2) }
    let second = MainActor.assumeIsolated { MediaPipeline.writeCapture(blue, named: "Screenshot.png", in: dir, format: .png, scale: 2) }
    check(first?.lastPathComponent == "Screenshot.png" && second?.lastPathComponent == "Screenshot 2.png", "same-second captures get distinct names")
    let bogus = MainActor.assumeIsolated { MediaPipeline.writeCapture(red, named: "x.png", in: dir.appendingPathComponent("nope"), format: .png, scale: 1) }
    check(bogus == nil, "unwritable folder reports failure instead of throwing or crashing")
    check(ImageTools.encode(red, format: .jpeg, quality: 42) != nil && ImageTools.encode(red, format: .jpeg, quality: -1) != nil,
          "out-of-range JPEG quality from a corrupt preference is clamped")
}))
SelfTest.cases.append(("Orphaned media sweep", {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("superscreenshot-sweep-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let now = Date()
    let old = dir.appendingPathComponent("old.png"), fresh = dir.appendingPathComponent("fresh.png")
    try? Data([1]).write(to: old); try? Data([1]).write(to: fresh)
    try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-90_000)], ofItemAtPath: old.path)
    try? fm.setAttributes([.modificationDate: now.addingTimeInterval(-90_000)], ofItemAtPath: dir.appendingPathComponent("sub").path)
    MainActor.assumeIsolated { MediaPipeline.sweep(dir, olderThan: 86_400, now: now) }
    check(!fm.fileExists(atPath: old.path), "day-old unsaved capture removed")
    check(fm.fileExists(atPath: fresh.path), "recent capture kept (still restorable)")
    check(fm.fileExists(atPath: dir.appendingPathComponent("sub").path), "folders are never swept")
}))
SelfTest.cases.append(("Defaults corruption", {
    let suite = UserDefaults(suiteName: "superscreenshot.selftest.corrupt")!
    suite.removePersistentDomain(forName: "superscreenshot.selftest.corrupt")
    Defaults.store = suite
    defer { Defaults.store = .standard }
    suite.set("abc", forKey: "c.int"); check(Defaults[Defaults.Key<Int>("c.int", default: 7)] == 7, "string where Int expected → default")
    suite.set(true, forKey: "c.str"); check(Defaults[Defaults.Key<String>("c.str", default: "d")] == "d", "bool where String expected → default")
    suite.set("yes", forKey: "c.bool"); check(Defaults[Defaults.Key<Bool>("c.bool", default: true)] == true, "string where Bool expected → default")
    suite.set("tiff2", forKey: "c.enum"); check(Defaults[Defaults.Key<ImageFormat>("c.enum", default: .png)] == .png, "unknown enum raw value → default")
    suite.set(Data("{garbage".utf8), forKey: "c.rect"); check(Defaults[Defaults.Key<CodableRect?>("c.rect", default: nil)] == nil, "garbage JSON for optional struct → nil")
    suite.set(Data("[\"save\", 12".utf8), forKey: "c.set")
    check(Defaults[Defaults.Key<Set<AfterCaptureAction>>("c.set", default: [.showQuickAccess])] == [.showQuickAccess], "truncated JSON array → default")
    suite.set(Data("{\"captureArea\": 5}".utf8), forKey: Defaults.Keys.shortcuts.name)
    check(AppAction.captureArea.shortcut == AppAction.captureArea.defaultShortcut, "corrupt shortcuts map → defaults, no crash")
    suite.set("nope", forKey: Defaults.Keys.lastRecordingArea.name)
    check(Defaults[.lastRecordingArea] == nil, "corrupt lastRecordingArea → nil")
    suite.set(["a": "b"], forKey: Defaults.Keys.uploadFolderPath.name)
    check(Defaults[.uploadFolderPath] == "", "dictionary where String expected → default")
    suite.set(-5, forKey: Defaults.Keys.quickAccessSizeIndex.name)
    check(QuickAccessSize.clamped(Defaults[.quickAccessSizeIndex]) == 0, "negative size index clamps")
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
