import CryptoKit
import Foundation
import Security
import SuperScreenshotCore

/// Download → SHA-256 → mount → code-signature check → stage next to the installed app → swap after quit.
/// Nonisolated and UI-free; every step takes explicit paths so the self-tests can run it against temporary folders.
public enum UpdateInstaller {
    private static let session = URLSession(configuration: .ephemeral)

    // MARK: Feed & download

    public static func fetchLatestRelease(from feedURL: URL, userAgent: String) async throws -> ReleaseInfo {
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.feed("HTTP \(status)") }
        return try ReleaseFeed.parse(data)
    }

    static func download(_ url: URL, to destination: URL, userAgent: String) async throws {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.feed("download failed with HTTP \(status)") }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    public static func sha256Hex(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Disk image

    /// Mounts read-only and hidden from Finder; returns the mount point.
    static func attach(_ dmg: URL) throws -> URL {
        let output: Data
        do {
            output = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist", dmg.path])
        } catch { throw UpdateError.diskImage(error.localizedDescription) }
        let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any]
        let entities = plist?["system-entities"] as? [[String: Any]] ?? []
        guard let mount = entities.lazy.compactMap({ $0["mount-point"] as? String }).first else {
            throw UpdateError.diskImage("no mounted volume")
        }
        return URL(fileURLWithPath: mount, isDirectory: true)
    }

    static func detach(_ mountPoint: URL) {
        if (try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])) == nil {
            _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet", "-force"])
        }
    }

    /// Detaches disk images left mounted from `directory` (the app quit while an update was being verified).
    static func detachImages(from directory: URL) {
        guard let output = try? run("/usr/bin/hdiutil", ["info", "-plist"]),
              let plist = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return }
        let prefix = directory.standardizedFileURL.path + "/"
        for image in images where (image["image-path"] as? String)?.hasPrefix(prefix) == true {
            for case let mount? in (image["system-entities"] as? [[String: Any]] ?? []).map({ $0["mount-point"] as? String }) {
                Log.update.info("Detaching leftover update image at \(mount, privacy: .public)")
                detach(URL(fileURLWithPath: mount))
            }
        }
    }

    /// `SuperScreenshot.app` at the top of the volume, else any top-level app with the expected bundle identifier.
    static func findApp(in volume: URL, bundleID: String) throws -> URL {
        let named = volume.appendingPathComponent(ReleaseFeed.appName)
        if FileManager.default.fileExists(atPath: named.path) { return named }
        let apps = (try? FileManager.default.contentsOfDirectory(at: volume, includingPropertiesForKeys: nil)) ?? []
        guard let app = apps.first(where: { $0.pathExtension == "app" && info(of: $0)?["CFBundleIdentifier"] as? String == bundleID })
        else { throw UpdateError.appNotFound }
        return app
    }

    // MARK: Code signature

    private static let strictFlags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)

    /// The running app's designated requirement, or nil for an ad-hoc signed build (a local debug build), whose
    /// requirement is a single cdhash that no other build can satisfy.
    public static func runningAppRequirement() -> SecRequirement? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return stableRequirement(of: staticCode)
    }

    /// Designated requirement of the app at `url`, or nil when it isn't signed with a certificate.
    public static func designatedRequirement(ofApp url: URL) -> SecRequirement? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return stableRequirement(of: staticCode)
    }

    private static func stableRequirement(of code: SecStaticCode) -> SecRequirement? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [Any], !certificates.isEmpty
        else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// The app at `url` must have a valid, strictly checked signature that satisfies `requirement` (the running app's
    /// designated requirement), the expected bundle identifier and exactly the advertised version.
    public static func verify(app url: URL, requirement: SecRequirement, bundleID: String, version: AppVersion) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError.signature("unreadable")
        }
        var error: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(staticCode, strictFlags, nil, &error) == errSecSuccess else {
            throw UpdateError.signature(describe(error, fallback: "invalid signature"))
        }
        guard SecStaticCodeCheckValidityWithErrors(staticCode, strictFlags, requirement, &error) == errSecSuccess else {
            throw UpdateError.signature(describe(error, fallback: "not signed by the same developer as this app"))
        }
        let plist = info(of: url)
        let id = plist?["CFBundleIdentifier"] as? String ?? "none"
        guard id == bundleID else { throw UpdateError.wrongBundle(id) }
        let found = plist?["CFBundleShortVersionString"] as? String ?? "none"
        guard AppVersion(found) == version else { throw UpdateError.wrongVersion(expected: version.description, found: found) }
    }

    private static func describe(_ error: Unmanaged<CFError>?, fallback: String) -> String {
        error.map { ($0.takeRetainedValue() as Error).localizedDescription } ?? fallback
    }

    /// Read without `Bundle`, which caches bundles by path.
    private static func info(of app: URL) -> [String: Any]? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    }

    // MARK: Staging

    static let stagedPrefix = ".SuperScreenshot-update-"
    static let previousPrefix = ".SuperScreenshot-previous-"

    /// Hidden sibling of the installed app, on the same volume so the final swap is two renames.
    public static func stagingURL(for installed: URL, version: AppVersion) -> URL {
        installed.deletingLastPathComponent().appendingPathComponent("\(stagedPrefix)\(version).app", isDirectory: true)
    }

    /// Downloads, verifies and stages `release` next to `installed`; returns the staged bundle. The disk image is
    /// detached and deleted whether this succeeds or not.
    public static func prepare(_ release: ReleaseInfo, installed: URL, workDirectory: URL, requirement: SecRequirement,
                               bundleID: String, userAgent: String) async throws -> URL {
        guard let expected = release.sha256 else { throw UpdateError.missingChecksum }
        let fm = FileManager.default
        try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let dmg = workDirectory.appendingPathComponent(release.assetName)
        defer { try? fm.removeItem(at: dmg) }

        Log.update.info("Downloading \(release.downloadURL.absoluteString, privacy: .public)")
        try await download(release.downloadURL, to: dmg, userAgent: userAgent)
        try Task.checkCancellation()
        guard try sha256Hex(of: dmg) == expected else { throw UpdateError.checksumMismatch }
        Log.update.info("SHA-256 matches the release notes")

        let mount = try attach(dmg)
        defer { detach(mount) }
        let app = try findApp(in: mount, bundleID: bundleID)
        try verify(app: app, requirement: requirement, bundleID: bundleID, version: release.version)
        Log.update.info("Signature of \(release.version.description, privacy: .public) verified")
        try Task.checkCancellation()

        let staged = stagingURL(for: installed, version: release.version)
        try? fm.removeItem(at: staged)
        do {
            try run("/usr/bin/ditto", [app.path, staged.path])
            try verify(app: staged, requirement: requirement, bundleID: bundleID, version: release.version)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        Log.update.info("Staged \(release.version.description, privacy: .public) at \(staged.path, privacy: .public)")
        return staged
    }

    /// Removes staged or replaced copies left next to `installed` by an interrupted update.
    public static func removeLeftovers(nextTo installed: URL) {
        let dir = installed.deletingLastPathComponent()
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in items where name.hasSuffix(".app") && (name.hasPrefix(stagedPrefix) || name.hasPrefix(previousPrefix)) {
            Log.update.info("Removing leftover \(name, privacy: .public)")
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }

    // MARK: Swap

    /// Positional parameters: $1 PID to wait for, $2 installed app, $3 staged app, $4 "1" to relaunch, $5 max wait (s).
    /// Waits for the app to quit, renames the old bundle aside, renames the staged bundle into place (restoring the
    /// old one if that fails), clears quarantine, deletes the old bundle and optionally relaunches in the background.
    static let swapScript = #"""
    trap '' HUP
    pid=$1 target=$2 staged=$3 relaunch=$4 limit=$5
    log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
    log "waiting for process $pid to quit"
    ticks=0
    while kill -0 "$pid" 2>/dev/null; do
      ticks=$((ticks + 1))
      if [ "$ticks" -gt $((limit * 10)) ]; then
        log "status: abandoned (process $pid still running after $limit s)"
        rm -rf "$staged"
        exit 1
      fi
      sleep 0.1
    done
    backup="$(dirname "$target")/.SuperScreenshot-previous-$$.app"
    if [ -e "$target" ] && ! mv "$target" "$backup"; then
      log "status: failed (could not move the installed app aside)"
      rm -rf "$staged"
      [ "$relaunch" = 1 ] && open -n -g "$target"
      exit 1
    fi
    if ! mv "$staged" "$target"; then
      log "status: failed (could not move the new app into place)"
      [ -e "$backup" ] && mv "$backup" "$target"
      rm -rf "$staged"
      [ "$relaunch" = 1 ] && open -n -g "$target"
      exit 1
    fi
    log "installed $target"
    xattr -dr com.apple.quarantine "$target" 2>/dev/null
    rm -rf "$backup" && log "removed the previous version"
    if [ "$relaunch" = 1 ]; then open -n -g "$target" && log "relaunched"; fi
    log "status: done"
    """#

    /// Starts the swap helper in its own process group (so it outlives the app); its output goes to `log`.
    @discardableResult
    public static func spawnSwapHelper(waitingFor pid: Int32, installed: URL, staged: URL, relaunch: Bool,
                                       maxWait: Int = 30, log: URL) throws -> Process {
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", swapScript, "superscreenshot-update", String(pid), installed.path, staged.path,
                       relaunch ? "1" : "0", String(maxWait)]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = output
        p.standardError = output
        try p.run()
        Log.update.info("Swap helper \(p.processIdentifier) waiting for \(pid) (relaunch: \(relaunch))")
        return p
    }

    // MARK: Tools

    /// Runs a command-line tool and returns its standard output; throws with its error output on failure.
    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError.tool("\((tool as NSString).lastPathComponent) failed (\(p.terminationStatus)): \(message)")
        }
        return data
    }
}
