import AppKit
import Combine
import SuperScreenshotCore

extension Defaults.Keys {
    /// Version handed to the swap helper; the next launch shows "Updated to …" once if it is that version.
    static let updateNoticeVersion = Key<String>("updateKit.noticeVersion", default: "")
}

/// Silent background updates: checks the release feed on a schedule, downloads and verifies a newer release, stages it
/// next to the running app, and swaps it in when the user quits — or earlier, relaunching in the background, once the
/// app has been idle with nothing on screen. Failures are logged and retried on the next check; nothing is shown.
@MainActor
final class UpdateController {
    static let shared = UpdateController()

    private let installed = Bundle.main.bundleURL
    private let bundleID = AppPaths.bundleID
    private let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    private var userAgent: String { "SuperScreenshot/\(currentVersion)" }
    private var workDirectory: URL { AppPaths.support.appendingPathComponent("Updates", isDirectory: true) }
    private var helperLog: URL { workDirectory.appendingPathComponent("helper.log") }

    private var checkTimer: Timer?
    private var idleTimer: Timer?
    private var task: Task<Void, Never>?
    private var staged: (version: AppVersion, url: URL)?
    private var helper: Process?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        // A notice for another version means the last swap didn't happen.
        if let notice = AppVersion(Defaults[.updateNoticeVersion]), notice != AppVersion(currentVersion) {
            Defaults[.updateNoticeVersion] = ""
        }
        let work = workDirectory, installed = installed, isBundle = installed.pathExtension == "app"
        Task.detached(priority: .utility) {
            Self.reportHelperRun(log: work.appendingPathComponent("helper.log"))
            UpdateInstaller.detachImages(from: work)
            try? FileManager.default.removeItem(at: work)
            if isBundle { UpdateInstaller.removeLeftovers(nextTo: installed) }
        }
        Defaults.publisher(.installUpdatesAutomatically)
            .removeDuplicates()
            .sink { [weak self] on in self?.setEnabled(on) }
            .store(in: &cancellables)
    }

    private func setEnabled(_ on: Bool) {
        checkTimer?.invalidate()
        checkTimer = nil
        guard on else {
            task?.cancel()  // clears `task` itself once it has unwound, so no second check can overlap it
            discardStagedUpdate()
            return
        }
        let timer = Timer(fire: Date().addingTimeInterval(UpdateSchedule.firstCheckDelay), interval: UpdateSchedule.interval,
                          repeats: true) { _ in MainActor.assumeIsolated { UpdateController.shared.check() } }
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    // MARK: Check, download, stage

    private func check() {
        guard task == nil, Defaults[.installUpdatesAutomatically],
              UpdateSchedule.isCheckDue(now: Date(), lastCheck: Defaults[.lastUpdateCheck]),
              let current = AppVersion(currentVersion) else { return }
        guard installed.pathExtension == "app" else {
            Log.update.info("Not running from an app bundle; skipping the update check")
            return
        }
        guard FileManager.default.isWritableFile(atPath: installed.deletingLastPathComponent().path) else {
            Log.update.info("\(self.installed.deletingLastPathComponent().path, privacy: .public) isn't writable; skipping the update check")
            return
        }
        guard let requirement = UpdateInstaller.runningAppRequirement() else {
            Log.update.info("This copy is ad-hoc signed and can't verify updates; skipping the update check")
            return
        }
        let newest = staged?.version ?? current
        let (installed, work, bundleID, userAgent) = (installed, workDirectory, bundleID, userAgent)
        task = Task {
            defer { task = nil; try? FileManager.default.removeItem(at: work) }
            do {
                let release = try await UpdateInstaller.fetchLatestRelease(from: ReleaseFeed.url, userAgent: userAgent)
                Defaults[.lastUpdateCheck] = Date()
                guard release.version > newest else {
                    Log.update.info("Up to date (\(newest.description, privacy: .public); latest \(release.version.description, privacy: .public))")
                    return
                }
                Log.update.info("Update \(release.version.description, privacy: .public) available")
                let url = try await UpdateInstaller.prepare(release, installed: installed, workDirectory: work,
                                                            requirement: requirement, bundleID: bundleID, userAgent: userAgent)
                guard Defaults[.installUpdatesAutomatically] else { try? FileManager.default.removeItem(at: url); return }
                didStage(release.version, at: url)
            } catch {
                if Task.isCancelled { Log.update.info("Update check cancelled"); return }
                Log.update.error("Update failed: \(error.localizedDescription, privacy: .public); retrying at the next check")
            }
        }
    }

    private func didStage(_ version: AppVersion, at url: URL) {
        if let old = staged, old.url != url { try? FileManager.default.removeItem(at: old.url) }
        staged = (version, url)
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { UpdateController.shared.applyIfIdle() } }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func discardStagedUpdate() {
        idleTimer?.invalidate()
        idleTimer = nil
        if let staged { try? FileManager.default.removeItem(at: staged.url) }
        staged = nil
    }

    // MARK: Apply

    /// Swaps the update in now and relaunches in the background, but only when nobody can notice.
    private func applyIfIdle() {
        let anyInput = CGEventType(rawValue: ~0)!
        let activity = AppActivity(
            secondsSinceInput: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput),
            isRecording: Services.recording?.isRecording == true || Services.recording?.isFinalizing == true
                || Services.studio?.isRecording == true,
            isUploading: Services.upload?.isUploading == true,
            hasOpenWindows: hasOpenWindows)
        guard UpdateApplyGate.canApplyWhileRunning(activity), handOff(relaunch: true) else { return }
        Log.update.info("Idle: quitting to install the update")
        NSApp.terminate(nil)
        // Still running: quitting was cancelled. Stop the helper (the PID we started) and keep the staged copy.
        Log.update.info("Quit was cancelled; the update stays staged")
        helper?.terminate()
        helper = nil
        Defaults[.updateNoticeVersion] = ""
    }

    /// Anything the user could be looking at or working in, including minimised editors and hidden pins.
    private var hasOpenWindows: Bool {
        NSApp.activationPolicy() != .accessory || Services.quickAccess?.hasOverlays == true || Services.pin?.hasPins == true
            || NSApp.windows.contains { ($0.isVisible || $0.isMiniaturized) && $0.className != "NSStatusBarWindow" }
    }

    /// From `applicationWillTerminate`: the helper installs the staged update after the app has quit; the next launch
    /// is the new version.
    func installOnQuit() {
        task?.cancel()
        guard helper == nil else { return }
        handOff(relaunch: false)
    }

    /// Re-verifies the staged copy and starts the swap helper. Returns false when there's nothing to install.
    @discardableResult
    private func handOff(relaunch: Bool) -> Bool {
        guard let staged, helper == nil, Defaults[.installUpdatesAutomatically] else { return false }
        do {
            guard let requirement = UpdateInstaller.runningAppRequirement() else { throw UpdateError.signature("unsigned app") }
            try UpdateInstaller.verify(app: staged.url, requirement: requirement, bundleID: bundleID, version: staged.version)
            helper = try UpdateInstaller.spawnSwapHelper(waitingFor: getpid(), installed: installed, staged: staged.url,
                                                         relaunch: relaunch, log: helperLog)
        } catch {
            Log.update.error("Staged update unusable: \(error.localizedDescription, privacy: .public)")
            discardStagedUpdate()
            return false
        }
        Defaults[.updateNoticeVersion] = staged.version.description
        return true
    }

    // MARK: After an update

    func showUpdatedNoticeIfNeeded() {
        let notice = Defaults[.updateNoticeVersion]
        guard !notice.isEmpty else { return }
        Defaults[.updateNoticeVersion] = ""
        if AppVersion(notice) == AppVersion(currentVersion) { HUD.show("Updated to \(currentVersion)") }
    }

    /// Copies the previous swap helper's output into the log.
    nonisolated private static func reportHelperRun(log: URL) {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") { Log.update.info("helper: \(line, privacy: .public)") }
    }
}
