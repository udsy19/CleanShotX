import Foundation

// Pure, UI-free update logic: versions, the GitHub release feed, the check schedule and the idle gate.
// Kept nonisolated so the self-tests can exercise it headlessly.

// MARK: - Versions

/// A release version such as `1.10.0`, `v1.3` or `2.0.0-beta.1`. Numeric components compare numerically and missing
/// ones count as zero (`1.3` == `1.3.0`); a pre-release sorts below the same version without one.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    /// The version as written, without a leading "v" or build metadata.
    public let description: String
    /// Numeric components with trailing zeros removed, so equal versions compare equal.
    private let numbers: [Int]
    private let preRelease: [Substring]?

    public init?(_ string: String) {
        var s = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        if let plus = s.firstIndex(of: "+") { s = s[..<plus] }  // build metadata never affects precedence
        description = String(s)
        var pre: Substring?
        if let dash = s.firstIndex(of: "-") { pre = s[s.index(after: dash)...]; s = s[..<dash] }
        var nums: [Int] = []
        for part in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            nums.append(n)
        }
        guard !nums.isEmpty, pre?.isEmpty != true else { return nil }
        while nums.count > 1, nums.last == 0 { nums.removeLast() }
        numbers = nums
        preRelease = pre.map { $0.split(separator: ".", omittingEmptySubsequences: false) }
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0, y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        switch (a.preRelease, b.preRelease) {
        case (nil, _): return false
        case (_?, nil): return true
        case let (x?, y?): return preReleaseLess(x, y)
        }
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { a.numbers == b.numbers && a.preRelease == b.preRelease }
    public func hash(into h: inout Hasher) { h.combine(numbers); h.combine(preRelease) }

    /// SemVer §11: numeric identifiers compare numerically and sort before alphanumeric ones; a shorter list of
    /// otherwise equal identifiers sorts first.
    private static func preReleaseLess(_ a: [Substring], _ b: [Substring]) -> Bool {
        for (x, y) in zip(a, b) where x != y {
            switch (Int(x), Int(y)) {
            case let (m?, n?): return m < n
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return x < y
            }
        }
        return a.count < b.count
    }
}

// MARK: - Release feed

public enum UpdateError: LocalizedError, Equatable {
    case feed(String)
    case noInstallableAsset
    case missingChecksum
    case checksumMismatch
    case diskImage(String)
    case appNotFound
    case signature(String)
    case wrongBundle(String)
    case wrongVersion(expected: String, found: String)
    case tool(String)

    public var errorDescription: String? {
        switch self {
        case .feed(let m): "The release feed couldn't be read: \(m)"
        case .noInstallableAsset: "The release has no SuperScreenshot.dmg asset."
        case .missingChecksum: "The release notes don't list a SHA-256 for SuperScreenshot.dmg."
        case .checksumMismatch: "The downloaded disk image doesn't match the SHA-256 in the release notes."
        case .diskImage(let m): "The disk image couldn't be opened: \(m)"
        case .appNotFound: "The disk image doesn't contain SuperScreenshot.app."
        case .signature(let m): "The new app's code signature was rejected: \(m)"
        case .wrongBundle(let id): "The new app has an unexpected bundle identifier (\(id))."
        case let .wrongVersion(expected, found): "The new app is version \(found), but the release is \(expected)."
        case .tool(let m): m
        }
    }
}

/// A downloadable release, as advertised by the feed.
public struct ReleaseInfo: Equatable, Sendable {
    public var version: AppVersion
    public var assetName: String
    public var downloadURL: URL
    /// SHA-256 of the DMG, from the line `scripts/release.sh` appends to the release notes; nil when absent.
    public var sha256: String?
}

/// GitHub's `releases/latest` endpoint and the conventions `scripts/release.sh` publishes releases with.
public enum ReleaseFeed {
    public static let gitHubURL = URL(string: "https://api.github.com/repos/udsy19/super-screenshot/releases/latest")!
    /// Uploaded with every release next to `SuperScreenshot-<version>.dmg`.
    public static let stableAssetName = "SuperScreenshot.dmg"
    public static let appName = "SuperScreenshot.app"

    /// The feed the app reads. Debug builds can point it at a local server with `SUPERSCREENSHOT_UPDATE_FEED`;
    /// release builds always use GitHub.
    public static var url: URL {
        #if DEBUG
        if let s = ProcessInfo.processInfo.environment["SUPERSCREENSHOT_UPDATE_FEED"], let u = URL(string: s) { return u }
        #endif
        return gitHubURL
    }

    public struct Asset: Decodable, Equatable, Sendable {
        public var name: String
        public var url: URL
        public init(name: String, url: URL) { self.name = name; self.url = url }
        private enum CodingKeys: String, CodingKey { case name, url = "browser_download_url" }
    }

    private struct Payload: Decodable {
        var tag_name: String
        var body: String?
        var draft: Bool?
        var prerelease: Bool?
        var assets: [Asset]
    }

    public static func parse(_ data: Data) throws -> ReleaseInfo {
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: data) } catch {
            throw UpdateError.feed("unexpected response")
        }
        guard payload.draft != true, payload.prerelease != true else { throw UpdateError.feed("not a published release") }
        guard let version = AppVersion(payload.tag_name) else { throw UpdateError.feed("unrecognised tag \(payload.tag_name)") }
        guard let asset = pickAsset(payload.assets, version: version) else { throw UpdateError.noInstallableAsset }
        return ReleaseInfo(version: version, assetName: asset.name, downloadURL: asset.url,
                           sha256: sha256(inNotes: payload.body ?? ""))
    }

    /// `SuperScreenshot.dmg`, else `SuperScreenshot-<version>.dmg` (both are the same file).
    public static func pickAsset(_ assets: [Asset], version: AppVersion) -> Asset? {
        assets.first { $0.name == stableAssetName } ?? assets.first { $0.name == "SuperScreenshot-\(version).dmg" }
    }

    /// The hex digest from "SHA-256 (SuperScreenshot.dmg): `<hex>`", lowercased.
    public static func sha256(inNotes notes: String) -> String? {
        let pattern = #"SHA-256 \(SuperScreenshot\.dmg\): `([0-9a-fA-F]{64})`"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: notes, range: NSRange(notes.startIndex..., in: notes)),
              let range = Range(match.range(at: 1), in: notes) else { return nil }
        return notes[range].lowercased()
    }
}

// MARK: - Schedule

/// First check a minute after launch, then every 6 hours while running; never two checks within 4 hours,
/// even across relaunches.
public enum UpdateSchedule {
    public static let firstCheckDelay: TimeInterval = 60
    public static let interval: TimeInterval = 6 * 3600
    public static let minimumSpacing: TimeInterval = 4 * 3600

    public static func isCheckDue(now: Date, lastCheck: Date?) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        // A clock set backwards must not block checks until it catches up.
        return elapsed >= minimumSpacing || elapsed < 0
    }
}

// MARK: - Applying while running

/// What the app is doing right now, sampled by the update controller.
public struct AppActivity: Sendable {
    public var secondsSinceInput: TimeInterval
    public var isRecording: Bool
    public var isUploading: Bool
    /// Any capture overlay, Quick Access card, pin, editor, Settings or other window on screen (or minimised).
    public var hasOpenWindows: Bool

    public init(secondsSinceInput: TimeInterval, isRecording: Bool, isUploading: Bool, hasOpenWindows: Bool) {
        self.secondsSinceInput = secondsSinceInput; self.isRecording = isRecording
        self.isUploading = isUploading; self.hasOpenWindows = hasOpenWindows
    }
}

/// A staged update is swapped in while the app runs only when nobody can notice the relaunch.
public enum UpdateApplyGate {
    public static let requiredIdle: TimeInterval = 10 * 60

    public static func canApplyWhileRunning(_ a: AppActivity) -> Bool {
        !a.isRecording && !a.isUploading && !a.hasOpenWindows && a.secondsSinceInput >= requiredIdle
    }
}
