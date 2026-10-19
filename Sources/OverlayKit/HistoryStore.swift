import AppKit
import Combine
import SuperScreenshotCore

/// Capture History service: persistent JSON index of captures (CleanShot's `mediaHistory` + `MediaUtility.cleanOldMedia`).
@MainActor
final class HistoryStore: ObservableObject, HistoryServicing {
    static let shared = HistoryStore()

    /// Newest first. The same `CapturedMedia` instances are shared with Quick Access and pins.
    @Published private(set) var items: [CapturedMedia] = []
    /// Bumped on every `CapturedMedia.didChange` so views holding the same (reference-type) media re-render.
    @Published private(set) var revisions: [UUID: Int] = [:]

    private let fileURL: URL
    private var observers: [NSObjectProtocol] = []
    private var defaultsSub: AnyCancellable?
    private var pruneTimer: Timer?
    private var saveScheduled = false

    private init() {
        fileURL = AppPaths.history.appendingPathComponent("history.json")
        load()
        prune()
        observers.append(NotificationCenter.default.addObserver(forName: CapturedMedia.didChange, object: nil, queue: .main) { [weak self] n in
            guard let media = n.object as? CapturedMedia else { return }
            MainActor.assumeIsolated { self?.mediaDidChange(media) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        })
        defaultsSub = Defaults.changes.receive(on: DispatchQueue.main).sink { [weak self] name in
            MainActor.assumeIsolated {
                if name == Defaults.Keys.historyRetentionDays.name { self?.prune() }
                if name == Defaults.Keys.historyEnabled.name { self?.objectWillChange.send() }
            }
        }
        let t = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
        RunLoop.main.add(t, forMode: .common)
        pruneTimer = t
    }

    /// Folders whose unsaved files belong to Super Screenshot and may be deleted when their history entry goes away.
    static var managedDirectories: [URL] { [AppPaths.media, AppPaths.recordings] }

    // MARK: HistoryServicing

    func add(_ media: CapturedMedia) {
        var list = items.filter { $0.id != media.id }
        list.append(media)
        items = list.sorted { $0.createdAt > $1.createdAt }
        prune()      // also drops entries whose file disappeared (e.g. trashed by another module)
        save()
    }

    func showWindow() {
        HistoryWindowController.shared.show()
    }

    func restoreLast() {
        if QuickAccessController.shared.restoreLastClosed() { return }
        let fm = FileManager.default
        if let media = items.first(where: { !QuickAccessController.shared.isShowing($0) && fm.fileExists(atPath: $0.url.path) }) {
            QuickAccessController.shared.show(media)
        } else {
            HUD.show("No files to restore...", symbol: "clock.arrow.circlepath")
        }
    }

    func clear() {
        let fm = FileManager.default
        for media in items {
            let entry = HistoryEntry(media)
            guard HistoryIndex.shouldDeleteFile(of: entry, managedDirectories: Self.managedDirectories),
                  !QuickAccessController.shared.isShowing(media) else { continue }
            try? fm.removeItem(at: media.url)
        }
        items = []
        revisions = [:]
        save()
    }

    // MARK: Internal

    func remove(_ media: CapturedMedia) { remove(id: media.id) }

    func remove(id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        revisions[id] = nil
        save()
    }

    /// Drops expired entries (deleting unsaved managed files) and entries whose file disappeared.
    func prune(now: Date = Date()) {
        let entries = items.map(HistoryEntry.init)
        let fm = FileManager.default
        let result = HistoryIndex.prune(entries, now: now, retentionDays: Defaults[.historyRetentionDays],
                                        fileExists: { fm.fileExists(atPath: $0.path) })
        guard !result.expired.isEmpty || !result.missing.isEmpty else { return }
        let onScreen = Set(QuickAccessController.shared.cards.map(\.media.id))
        for e in result.expired where !onScreen.contains(e.id)
            && HistoryIndex.shouldDeleteFile(of: e, managedDirectories: Self.managedDirectories) {
            try? fm.removeItem(at: e.url)
        }
        let keep = Set(result.kept.map(\.id)).union(onScreen.subtracting(result.missing.map(\.id)))
        items = items.filter { keep.contains($0.id) }
        revisions = revisions.filter { keep.contains($0.key) }
        save()
    }

    func revision(of media: CapturedMedia) -> Int { revisions[media.id] ?? 0 }

    private func mediaDidChange(_ media: CapturedMedia) {
        guard let idx = items.firstIndex(where: { $0.id == media.id }) else { return }
        if items[idx] !== media { items[idx] = media }
        revisions[media.id, default: 0] += 1
        save()
    }

    // MARK: Persistence

    private func load() {
        items = HistoryIndex.load(from: fileURL).map { $0.makeMedia() }
    }

    /// Coalesces bursts of changes (save + upload + rename …) into one write on the next run-loop turn.
    /// All mutation and I/O stay on the main actor, so writes can never interleave or land out of order.
    private func save() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        guard saveScheduled else { return }
        saveScheduled = false
        do {
            let data = try HistoryIndex.encode(items.map(HistoryEntry.init))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.app.error("Couldn't write capture history: \(error.localizedDescription, privacy: .public)")
        }
    }
}
