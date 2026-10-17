import AppKit
import ShotcraftCore

// Headless checks for pure logic (no XCTest in the Command Line Tools toolchain).
// Run: swift run ShotcraftSelfTest   — exits non-zero on failure.
// Modules add cases by appending to `SelfTest.cases` in Sources/ShotcraftSelfTest/<Module>Tests.swift.

var failures = 0
func check(_ cond: @autoclosure () -> Bool, _ msg: String, file: String = #fileID, line: Int = #line) {
    if !cond() { failures += 1; print("✗ \(file):\(line) \(msg)") }
}

enum SelfTest {
    nonisolated(unsafe) static var cases: [(String, () -> Void)] = []
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
    let suite = UserDefaults(suiteName: "shotcraft.selftest")!
    suite.removePersistentDomain(forName: "shotcraft.selftest")
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
