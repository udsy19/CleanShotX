import Foundation
import Security
import SuperScreenshotCore
import UpdateKit

/// Append cases with `SelfTest.cases.append(("name", { check(..., "msg") }))`.
/// Nothing here talks to GitHub: the end-to-end case serves a disk image of the locally built app from a loopback
/// server it starts (and stops) itself, and swaps bundles inside a temporary folder without relaunching anything.
func registerUpdateKitTests() {
    SelfTest.cases.append(("UpdateKit.AppVersion", {
        func v(_ s: String) -> AppVersion { AppVersion(s)! }
        check(v("1.10.0") > v("1.9.2"), "numeric, not lexical")
        check(v("2.0") > v("1.99.99"), "major wins")
        check(v("v1.3") == v("1.3.0") && v("1.3.0") == v("1.3"), "leading v and trailing zeros")
        check(Set([v("1.3"), v("1.3.0"), v("v1.3.0")]).count == 1, "hash matches equality")
        check(v("1.3.0").description == "1.3.0" && v("v1.3.0").description == "1.3.0", "description drops the v")
        check(v("1.3.0+42") == v("1.3.0"), "build metadata ignored")
        check(v("1.3.0-beta.1") < v("1.3.0"), "pre-release below release")
        check(v("1.3.0-beta.1") > v("1.2.9"), "pre-release above older release")
        check(v("1.3.0-beta.2") < v("1.3.0-beta.10"), "numeric pre-release identifiers")
        check(v("1.3.0-alpha") < v("1.3.0-alpha.1"), "shorter pre-release first")
        check(v("1.3.0-1") < v("1.3.0-alpha"), "numeric identifier before alphanumeric")
        check(!(v("1.2.0") < v("1.2.0")) && !(v("1.2.0") > v("1.2.0")), "irreflexive")
        for bad in ["", "abc", "1..2", "1.2.x", "1.2-", "-1.2", "1.+2", " "] { check(AppVersion(bad) == nil, "rejects '\(bad)'") }
    }))

    SelfTest.cases.append(("UpdateKit.ReleaseFeed", {
        let sha = String(repeating: "ab12", count: 16)
        let notes = """
        ### Added\\n- In-app updates.\\n\\n**Install:** `curl -fsSL https://udsy19.github.io/super-screenshot/install.sh | bash` — or download the DMG below.\\n\\nSHA-256 (SuperScreenshot.dmg): `\(sha)`
        """
        func payload(tag: String = "v1.3.0", body: String = notes, assets: [String] = ["SuperScreenshot-1.3.0.dmg", "SuperScreenshot.dmg"],
                     prerelease: Bool = false) -> Data {
            let list = assets.map { #"{"name": "\#($0)", "size": 7340032, "browser_download_url": "https://github.com/udsy19/super-screenshot/releases/download/\#(tag)/\#($0)"}"# }
            return Data("""
            {"url": "https://api.github.com/repos/udsy19/super-screenshot/releases/1", "html_url": "https://github.com/udsy19/super-screenshot/releases/tag/\(tag)",
             "tag_name": "\(tag)", "name": "Super Screenshot 1.3.0", "draft": false, "prerelease": \(prerelease),
             "published_at": "2026-10-17T18:00:00Z", "author": {"login": "udsy19"},
             "assets": [\(list.joined(separator: ","))], "body": "\(body)"}
            """.utf8)
        }
        let info = try? ReleaseFeed.parse(payload())
        check(info?.version == AppVersion("1.3.0"), "tag parsed without v")
        check(info?.assetName == "SuperScreenshot.dmg"
              && info?.downloadURL.absoluteString == "https://github.com/udsy19/super-screenshot/releases/download/v1.3.0/SuperScreenshot.dmg",
              "stable asset preferred")
        check(info?.sha256 == sha, "SHA-256 from the release.sh line")
        check((try? ReleaseFeed.parse(payload(assets: ["SuperScreenshot-1.3.0.dmg", "notes.txt"])))?.assetName == "SuperScreenshot-1.3.0.dmg",
              "versioned asset as fallback")
        check(throwsError(.noInstallableAsset) { _ = try ReleaseFeed.parse(payload(assets: ["SuperScreenshot-1.2.0.dmg", "Other.dmg"])) },
              "no matching asset")
        check((try? ReleaseFeed.parse(payload(body: "No checksum here")))?.sha256 == nil, "missing SHA → nil")
        check(throwsError(.feed("not a published release")) { _ = try ReleaseFeed.parse(payload(prerelease: true)) }, "pre-release rejected")
        check(throwsError(.feed("unrecognised tag nightly")) { _ = try ReleaseFeed.parse(payload(tag: "nightly")) }, "bad tag rejected")
        check(throwsError(.feed("unexpected response")) { _ = try ReleaseFeed.parse(Data(#"{"message": "API rate limit exceeded"}"#.utf8)) },
              "error payload rejected")

        check(ReleaseFeed.sha256(inNotes: "SHA-256 (SuperScreenshot.dmg): `\(sha.uppercased())`") == sha, "uppercase digest lowercased")
        check(ReleaseFeed.sha256(inNotes: "SHA-256 (Other.dmg): `\(sha)`") == nil, "other file's digest ignored")
        check(ReleaseFeed.sha256(inNotes: "SHA-256 (SuperScreenshot.dmg): `\(sha.dropLast())`") == nil, "short digest ignored")
        let assets = [ReleaseFeed.Asset(name: "SuperScreenshot-2.0.0.dmg", url: URL(string: "https://x/a")!)]
        check(ReleaseFeed.pickAsset(assets, version: AppVersion("v2.0")!) == nil, "versioned name uses the tag as written")
        check(ReleaseFeed.pickAsset(assets, version: AppVersion("2.0.0")!) == assets[0], "versioned name match")
        check(ReleaseFeed.gitHubURL.absoluteString == "https://api.github.com/repos/udsy19/super-screenshot/releases/latest", "GitHub feed")
    }))

    SelfTest.cases.append(("UpdateKit.Schedule", {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        check(UpdateSchedule.isCheckDue(now: now, lastCheck: nil), "never checked")
        check(!UpdateSchedule.isCheckDue(now: now, lastCheck: now.addingTimeInterval(-3 * 3600)), "3 h ago: too soon")
        check(UpdateSchedule.isCheckDue(now: now, lastCheck: now.addingTimeInterval(-4 * 3600)), "4 h ago: due")
        check(UpdateSchedule.isCheckDue(now: now, lastCheck: now.addingTimeInterval(3600)), "clock set backwards: due")
        check(UpdateSchedule.firstCheckDelay == 60 && UpdateSchedule.interval == 6 * 3600, "60 s after launch, then every 6 h")

        let suite = UserDefaults(suiteName: "superscreenshot.selftest.update")!
        suite.removePersistentDomain(forName: "superscreenshot.selftest.update")
        Defaults.store = suite
        defer { Defaults.store = .standard; suite.removePersistentDomain(forName: "superscreenshot.selftest.update") }
        check(Defaults[.lastUpdateCheck] == nil && Defaults[.installUpdatesAutomatically], "defaults: never checked, updates on")
        Defaults[.lastUpdateCheck] = now
        check(Defaults[.lastUpdateCheck] == now && suite.object(forKey: "lastUpdateCheck") is Date, "last check stored as a plist date")
    }))

    SelfTest.cases.append(("UpdateKit.ApplyGate", {
        let idle = AppActivity(secondsSinceInput: 600, isRecording: false, isUploading: false, hasOpenWindows: false)
        check(UpdateApplyGate.canApplyWhileRunning(idle), "idle 10 min, nothing open → apply")
        var a = idle; a.secondsSinceInput = 599
        check(!UpdateApplyGate.canApplyWhileRunning(a), "input within 10 min → wait")
        a = idle; a.isRecording = true; a.secondsSinceInput = 7200
        check(!UpdateApplyGate.canApplyWhileRunning(a), "never during a recording")
        a = idle; a.isUploading = true
        check(!UpdateApplyGate.canApplyWhileRunning(a), "not while uploading")
        a = idle; a.hasOpenWindows = true
        check(!UpdateApplyGate.canApplyWhileRunning(a), "not with overlays or windows open")
    }))

    SelfTest.cases.append(("UpdateKit.Leftovers", {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("superscreenshot-update-leftovers-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let names = ["SuperScreenshot.app", ".SuperScreenshot-update-1.3.0.app", ".SuperScreenshot-previous-123.app",
                     "Other.app", ".SuperScreenshot-update-notes.txt"]
        for n in names { try? fm.createDirectory(at: dir.appendingPathComponent(n), withIntermediateDirectories: true) }
        let installed = dir.appendingPathComponent("SuperScreenshot.app")
        check(UpdateInstaller.stagingURL(for: installed, version: AppVersion("v1.3.0")!) == dir.appendingPathComponent(".SuperScreenshot-update-1.3.0.app"),
              "staged next to the installed app")
        UpdateInstaller.removeLeftovers(nextTo: installed)
        let left = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        check(left == ["SuperScreenshot.app", "Other.app", ".SuperScreenshot-update-notes.txt"], "only staged/previous bundles removed: \(left)")
    }))

    SelfTest.cases.append(("UpdateKit.EndToEnd", { UpdateEndToEnd.run() }))
}

private func throwsError(_ expected: UpdateError, _ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return (error as? UpdateError) == expected }
}

private final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>? }

/// Runs async work to completion from the synchronous self-test loop.
private func blocking<T>(_ body: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    let box = ResultBox<T>(), done = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return box.result!
}

/// Feed → download → SHA-256 → mount → signature → stage → swap, with the real app from `scripts/build-app.sh`.
private enum UpdateEndToEnd {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func run() {
        let fm = FileManager.default
        let built = root.appendingPathComponent("build/SuperScreenshot.app")
        guard fm.fileExists(atPath: built.path) else { print("  – skipped: build/SuperScreenshot.app not found (run scripts/build-app.sh)"); return }
        guard let requirement = UpdateInstaller.designatedRequirement(ofApp: built) else {
            print("  – skipped: build/SuperScreenshot.app is ad-hoc signed (run scripts/signing-setup.sh)"); return
        }
        let info = NSDictionary(contentsOf: built.appendingPathComponent("Contents/Info.plist"))
        guard let bundleID = info?["CFBundleIdentifier"] as? String,
              let versionString = info?["CFBundleShortVersionString"] as? String, let version = AppVersion(versionString) else {
            check(false, "built app has no bundle id / version"); return
        }

        let base = fm.temporaryDirectory.appendingPathComponent("superscreenshot-update-e2e-\(UUID().uuidString)")
        let serve = base.appendingPathComponent("serve"), work = base.appendingPathComponent("work")
        let installDir = base.appendingPathComponent("My Apps"),  // a space exercises the helper's quoting
            installed = installDir.appendingPathComponent("SuperScreenshot.app")
        var server: Process?
        defer {
            server?.terminate()   // only the server this test started
            server?.waitUntilExit()
            try? fm.removeItem(at: base)
        }

        // 1. A release DMG of the built app, laid out like scripts/make-dmg.sh.
        let dmgStage = base.appendingPathComponent("dmg")
        try? fm.createDirectory(at: dmgStage, withIntermediateDirectories: true)
        try? fm.createDirectory(at: serve, withIntermediateDirectories: true)
        let dmg = serve.appendingPathComponent("SuperScreenshot.dmg")
        guard shell("/usr/bin/ditto", built.path, dmgStage.appendingPathComponent("SuperScreenshot.app").path),
              (try? fm.createSymbolicLink(atPath: dmgStage.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")) != nil,
              shell("/usr/bin/hdiutil", "create", "-quiet", "-volname", "Super Screenshot \(version)", "-srcfolder", dmgStage.path,
                    "-fs", "HFS+", "-format", "UDZO", "-ov", dmg.path),
              let sha = try? UpdateInstaller.sha256Hex(of: dmg) else { check(false, "couldn't build the test DMG"); return }

        // 2. A loopback server for the feed and the DMG.
        guard let (process, port) = startServer(serving: serve) else { print("  – skipped: python3 http.server unavailable"); return }
        server = process
        let host = "http://127.0.0.1:\(port)"
        let feedURL = URL(string: "\(host)/repos/udsy19/super-screenshot/releases/latest")!
        let latest = serve.appendingPathComponent("repos/udsy19/super-screenshot/releases/latest")
        try? fm.createDirectory(at: latest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = "### Added\\n- In-app updates.\\n\\n**Install:** `curl -fsSL https://udsy19.github.io/super-screenshot/install.sh | bash` — or download the DMG below.\\n\\nSHA-256 (SuperScreenshot.dmg): `\(sha)`"
        try? Data("""
        {"tag_name": "v\(version)", "name": "Super Screenshot \(version)", "draft": false, "prerelease": false, "body": "\(body)",
         "assets": [{"name": "SuperScreenshot-\(version).dmg", "browser_download_url": "\(host)/missing.dmg"},
                    {"name": "SuperScreenshot.dmg", "browser_download_url": "\(host)/SuperScreenshot.dmg"}]}
        """.utf8).write(to: latest)

        // 3. Feed.
        guard case .success(let release) = blocking({ try await UpdateInstaller.fetchLatestRelease(from: feedURL, userAgent: "SuperScreenshot/test") }) else {
            check(false, "feed request failed"); return
        }
        check(release.version == version && release.sha256 == sha && release.downloadURL.absoluteString == "\(host)/SuperScreenshot.dmg",
              "feed parsed from the server")

        // 4. Rejections leave nothing behind.
        try? fm.createDirectory(at: installed.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try? NSDictionary(dictionary: ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": "0.9.0"])
            .write(to: installed.appendingPathComponent("Contents/Info.plist"))
        try? Data("old".utf8).write(to: installed.appendingPathComponent("Contents/old-marker"))
        func prepare(_ r: ReleaseInfo, requirement: SecRequirement = requirement, bundleID: String = bundleID) -> Result<URL, Error> {
            blocking { try await UpdateInstaller.prepare(r, installed: installed, workDirectory: work, requirement: requirement,
                                                        bundleID: bundleID, userAgent: "SuperScreenshot/test") }
        }
        func clean() -> Bool {
            let work = (try? fm.contentsOfDirectory(atPath: work.path)) ?? []
            let siblings = (try? fm.contentsOfDirectory(atPath: installDir.path)) ?? []
            return work.isEmpty && siblings == ["SuperScreenshot.app"] && !hdiutilInfo().contains(base.path)
        }
        var tampered = release; tampered.sha256 = String(repeating: "0", count: 64)
        check(error(of: prepare(tampered)) == .checksumMismatch && clean(), "wrong SHA-256 rejected, files removed")
        var unsigned = release; unsigned.sha256 = nil
        check(error(of: prepare(unsigned)) == .missingChecksum && clean(), "missing SHA-256 rejected")
        var otherRequirement: SecRequirement?
        SecRequirementCreateWithString(#"identifier "com.example.other" and anchor apple generic"# as CFString, [], &otherRequirement)
        if case .signature = error(of: prepare(release, requirement: otherRequirement!)) { check(clean(), "rejected signature leaves nothing mounted or staged") }
        else { check(false, "foreign designated requirement rejected") }
        check(error(of: prepare(release, bundleID: "com.example.other")) == .wrongBundle(bundleID) && clean(), "bundle id must match")
        var newer = release; newer.version = AppVersion("99.0.0")!
        check(error(of: prepare(newer)) == .wrongVersion(expected: "99.0.0", found: versionString) && clean(), "version must match the release")

        // 5. The real thing: download, verify and stage.
        let prepared = prepare(release)
        guard case .success(let staged) = prepared else {
            if case .failure(let e) = prepared { check(false, "prepare failed: \(e.localizedDescription)") }
            return
        }
        check(staged == UpdateInstaller.stagingURL(for: installed, version: version), "staged next to the installed app")
        check((try? UpdateInstaller.verify(app: staged, requirement: requirement, bundleID: bundleID, version: version)) != nil, "staged copy verifies")
        check(((try? fm.contentsOfDirectory(atPath: work.path)) ?? []).isEmpty && !hdiutilInfo().contains(base.path), "DMG detached and deleted")

        // 6. Swap helper: a process that's still running keeps everything as it was.
        let decoy = installDir.appendingPathComponent(".SuperScreenshot-update-decoy.app")
        try? fm.createDirectory(at: decoy, withIntermediateDirectories: true)
        let busyLog = base.appendingPathComponent("busy.log")
        if let busy = try? UpdateInstaller.spawnSwapHelper(waitingFor: getpid(), installed: installed, staged: decoy, relaunch: false,
                                                          maxWait: 1, log: busyLog) {
            busy.waitUntilExit()
            check(busy.terminationStatus == 1 && fm.fileExists(atPath: installed.appendingPathComponent("Contents/old-marker").path)
                  && !fm.fileExists(atPath: decoy.path), "running app: helper gives up after the timeout")
            check((try? String(contentsOf: busyLog, encoding: .utf8))?.contains("status: abandoned") == true, "abandon logged")
        } else { check(false, "couldn't start the swap helper") }

        // 7. Swap helper after the app has quit (a process that already exited), without relaunching.
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? exited.run(); exited.waitUntilExit()
        let swapLog = base.appendingPathComponent("swap.log")
        guard let helper = try? UpdateInstaller.spawnSwapHelper(waitingFor: exited.processIdentifier, installed: installed, staged: staged,
                                                               relaunch: false, log: swapLog) else { check(false, "couldn't start the swap helper"); return }
        helper.waitUntilExit()
        let log = (try? String(contentsOf: swapLog, encoding: .utf8)) ?? ""
        check(helper.terminationStatus == 0 && log.contains("status: done") && !log.contains("relaunched"), "swap finished without relaunch")
        check(!fm.fileExists(atPath: installed.appendingPathComponent("Contents/old-marker").path), "old bundle replaced")
        check((try? UpdateInstaller.verify(app: installed, requirement: requirement, bundleID: bundleID, version: version)) != nil,
              "installed app is the verified new version")
        check(((try? fm.contentsOfDirectory(atPath: installDir.path)) ?? []) == ["SuperScreenshot.app"], "no staged or previous copy left")
        print("  – end-to-end: \(sha.prefix(12))… served on 127.0.0.1:\(port), staged and swapped \(version) in \(installDir.path)")
    }

    private static func error(of result: Result<URL, Error>) -> UpdateError? {
        if case .failure(let e) = result { return e as? UpdateError }
        return nil
    }

    @discardableResult
    private static func shell(_ tool: String, _ args: String...) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private static func hdiutilInfo() -> String {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["info"]
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// `python3 -m http.server` on an ephemeral loopback port; returns the process and the port it printed.
    private static func startServer(serving dir: URL) -> (Process, Int)? {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", "-u", "-m", "http.server", "0", "--bind", "127.0.0.1", "--directory", dir.path]
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        final class Line: @unchecked Sendable { var text = "" }
        let line = Line(), ready = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            line.text = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
            ready.signal()
        }
        // "Serving HTTP on 127.0.0.1 port 54321 (http://127.0.0.1:54321/) ..."
        guard ready.wait(timeout: .now() + 10) == .success,
              let range = line.text.range(of: #"port (\d+)"#, options: .regularExpression),
              let port = Int(line.text[range].dropFirst(5)) else {
            p.terminate(); p.waitUntilExit()
            return nil
        }
        return (p, port)
    }
}
