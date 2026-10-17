import AppKit
import SwiftUI
import Combine
import ShotcraftCore

/// State of one open Studio project (FLEditor + FLDocument): the project value, undo history, selection,
/// playhead and dirty/autosave tracking. Views observe it; all edits go through `update`.
@MainActor
final class EditorModel: ObservableObject {
    enum Selection: Equatable { case none, clip(UUID), zoom(UUID), camera(UUID) }
    /// Timeline pointer tool: V = selection, B = cut (click a clip to split it there).
    enum Tool { case selection, cut }

    private(set) var package: StudioPackage
    let events: StudioEvents
    @Published private(set) var project: StudioProject
    @Published var selection: Selection = .none
    /// Output-timeline seconds.
    @Published var playhead: Double = 0
    @Published var isPlaying = false
    @Published var tool: Tool = .selection
    @Published private(set) var isEdited = false
    /// Set when the project was opened from autosave.json.
    let recovered: Bool

    private var history: [StudioProject]
    private var historyIndex = 0
    private var coalesceKey: String?
    private var coalesceTime = Date.distantPast
    private var savedProject: StudioProject
    private var autosaveWork: DispatchWorkItem?
    /// Package writes (autosave, save, discard) are serialized here so a late autosave can't resurrect
    /// autosave.json after a save or "Don't Save".
    private static let io = DispatchQueue(label: "shotcraft.studio.project-io", qos: .utility)

    init(package: StudioPackage, project: StudioProject, events: StudioEvents, recovered: Bool) throws {
        self.package = package
        self.project = project
        self.events = events
        self.recovered = recovered
        history = [project]
        savedProject = recovered ? (try? StudioPackage.decodeProject(Data(contentsOf: package.projectURL))) ?? project : project
        isEdited = recovered
    }

    var timeline: ClipTimeline { project.timeline }
    var duration: Double { timeline.outputDuration }
    var playheadSource: Double { timeline.sourceTime(forOutput: playhead) }
    var hasCamera: Bool { project.recording.hasCamera }
    var hasAudio: Bool { project.recording.hasMicrophone || project.recording.hasSystemAudio }
    var frameDuration: Double { 1 / Double(max(project.recording.fps, 1)) }

    // MARK: Editing

    /// Applies an edit. Edits sharing a `coalesce` key within 1.5 s collapse into one undo step (slider drags).
    func update(coalesce key: String? = nil, _ mutate: (inout StudioProject) -> Void) {
        var p = project
        mutate(&p)
        guard p != project else { return }
        project = p
        let now = Date()
        if let key, key == coalesceKey, now.timeIntervalSince(coalesceTime) < 1.5, historyIndex == history.count - 1, historyIndex > 0 {
            history[historyIndex] = p
        } else {
            history.removeSubrange((historyIndex + 1)...)
            history.append(p)
            if history.count > 200 { history.removeFirst(history.count - 200) }
            historyIndex = history.count - 1
        }
        coalesceKey = key
        coalesceTime = now
        afterChange()
    }

    /// Ends coalescing so the next edit starts a new undo step.
    func endCoalescing() { coalesceKey = nil }

    func undo() {
        guard historyIndex > 0 else { NSSound.beep(); return }
        historyIndex -= 1
        project = history[historyIndex]
        coalesceKey = nil
        afterChange()
    }

    func redo() {
        guard historyIndex < history.count - 1 else { NSSound.beep(); return }
        historyIndex += 1
        project = history[historyIndex]
        coalesceKey = nil
        afterChange()
    }

    private func afterChange() {
        isEdited = project != savedProject
        playhead = min(playhead, duration)
        validateSelection()
        scheduleAutosave()
    }

    private func validateSelection() {
        switch selection {
        case .clip(let id) where !project.clips.contains(where: { $0.id == id }): selection = .none
        case .zoom(let id) where !project.zooms.contains(where: { $0.id == id }): selection = .none
        case .camera(let id) where !project.cameraFullscreen.contains(where: { $0.id == id }): selection = .none
        default: break
        }
    }

    /// Two-way binding into the project for SwiftUI controls (one undo step per gesture).
    func binding<T: Equatable>(_ kp: WritableKeyPath<StudioProject, T>, _ coalesce: String) -> Binding<T> {
        Binding(get: { self.project[keyPath: kp] }, set: { v in self.update(coalesce: coalesce) { $0[keyPath: kp] = v } })
    }

    /// Binding into the selected zoom segment.
    func zoomBinding<T: Equatable>(_ id: UUID, _ kp: WritableKeyPath<ZoomSegment, T>, fallback: T) -> Binding<T> {
        Binding(get: { self.project.zooms.first { $0.id == id }?[keyPath: kp] ?? fallback },
                set: { v in self.update(coalesce: "zoom-\(id)-\(kp.hashValue)") { p in
                    if let i = p.zooms.firstIndex(where: { $0.id == id }) { p.zooms[i][keyPath: kp] = v }
                } })
    }

    // MARK: Saving

    func save() throws {
        cancelAutosave()
        let pkg = package, p = project
        try Self.io.sync { try pkg.write(project: p) }
        savedProject = p
        isEdited = false
        StudioStyleMemory.remember(p.style)
    }

    /// "Don't Save": drops pending and written autosaves.
    func discardChanges() {
        cancelAutosave()
        let pkg = package
        Self.io.sync { pkg.discardAutosave() }
    }

    private func cancelAutosave() {
        autosaveWork?.cancel()
        autosaveWork = nil
    }

    private func scheduleAutosave() {
        cancelAutosave()
        let pkg = package
        guard isEdited else { Self.io.async { pkg.discardAutosave() }; return }
        let snapshot = project
        // The work item is cancelled on the main queue, so a save that runs first always wins.
        let work = DispatchWorkItem { Self.io.async { pkg.autosave(project: snapshot) } }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// Renames the package on disk and the project title.
    func rename(to newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        guard !title.isEmpty, title != project.title else { return }
        cancelAutosave()
        Self.io.sync {}   // no write may land in the old location after the move
        let dest = AppPaths.uniqueURL(package.url.deletingLastPathComponent().appendingPathComponent(title).appendingPathExtension(StudioPackage.fileExtension))
        do {
            try FileManager.default.moveItem(at: package.url, to: dest)
            package = StudioPackage(url: dest)
            let final = dest.deletingPathExtension().lastPathComponent
            // The title follows the package name and is not part of undo history.
            for i in history.indices { history[i].title = final }
            savedProject.title = final
            project.title = final
            if isEdited { scheduleAutosave() } else { let pkg = package, p = project; Self.io.sync { try? pkg.write(project: p) } }
        } catch {
            Alerts.error("An error occurred while saving the project", error)
        }
    }

    // MARK: Timeline commands

    func splitClipAtPlayhead() { splitClip(atOutput: playhead) }

    /// Cut tool / ⌘B: splits the clip under output time `t`.
    func splitClip(atOutput t: Double) {
        var tl = timeline
        guard tl.split(atOutput: t) != nil else { NSSound.beep(); return }
        update { $0.clips = tl.clips }
    }

    func deleteClip(_ id: UUID) {
        var tl = timeline
        guard tl.remove(id) else { NSSound.beep(); return }
        update { $0.clips = tl.clips }
        selection = .none
    }

    func deleteSelection() {
        switch selection {
        case .clip(let id): deleteClip(id)
        case .zoom(let id): update { $0.zooms.removeAll { $0.id == id } }; selection = .none
        case .camera(let id): update { $0.cameraFullscreen.removeAll { $0.id == id } }; selection = .none
        case .none: NSSound.beep()
        }
    }

    /// Adds a zoom between two *output* times (clamped against neighbours). Returns its id.
    @discardableResult
    func addZoom(outputStart: Double, outputEnd: Double) -> UUID? {
        let tl = timeline
        let s = tl.sourceTime(forOutput: outputStart), e = tl.sourceTime(forOutput: outputEnd)
        guard let (a, b) = LaneMath.place(start: min(s, e), end: max(s, e), in: project.zooms, duration: project.recording.duration) else {
            NSSound.beep(); return nil
        }
        let z = project.style.zoom
        let focus = CursorTrack.position(in: events.cursor, at: a) ?? .center
        let seg = ZoomSegment(start: a, end: b, level: z.defaultLevel, mode: z.followCursorByDefault && !events.cursor.isEmpty ? .followCursor : .manual,
                              focus: focus.clamped)
        update { $0.zooms.append(seg); $0.zooms.sort { $0.start < $1.start } }
        selection = .zoom(seg.id)
        return seg.id
    }

    @discardableResult
    func addCameraSegment(outputStart: Double, outputEnd: Double) -> UUID? {
        let tl = timeline
        let s = tl.sourceTime(forOutput: outputStart), e = tl.sourceTime(forOutput: outputEnd)
        guard let (a, b) = LaneMath.place(start: min(s, e), end: max(s, e), in: project.cameraFullscreen, duration: project.recording.duration) else {
            NSSound.beep(); return nil
        }
        let seg = TimeSegment(start: a, end: b)
        update { $0.cameraFullscreen.append(seg); $0.cameraFullscreen.sort { $0.start < $1.start } }
        selection = .camera(seg.id)
        return seg.id
    }

    func splitZoomAtPlayhead() {
        var zooms = project.zooms
        guard LaneMath.split(at: playheadSource, in: &zooms, makeCopy: { $0.duplicated() }) != nil else { NSSound.beep(); return }
        update { $0.zooms = zooms }
    }

    func duplicateZoom(_ id: UUID) {
        var zooms = project.zooms
        guard let copy = LaneMath.duplicate(id, in: &zooms, duration: project.recording.duration) else { NSSound.beep(); return }
        update { $0.zooms = zooms }
        selection = .zoom(copy)
    }

    func setZoom(_ id: UUID, level: Double? = nil, mode: ZoomMode? = nil) {
        update { p in
            guard let i = p.zooms.firstIndex(where: { $0.id == id }) else { return }
            if let level { p.zooms[i].level = level }
            if let mode { p.zooms[i].mode = mode }
        }
    }

    func applyZoomLevelToAll() {
        let level: Double
        if case .zoom(let id) = selection, let z = project.zooms.first(where: { $0.id == id }) { level = z.level }
        else { level = project.style.zoom.defaultLevel }
        update { $0.zooms.applyLevelToAll(level) }
    }

    func removeAllZooms() {
        guard !project.zooms.isEmpty else { return }
        update { $0.zooms = [] }
        selection = .none
    }

    func regenerateZooms() {
        let z = SmartZoomAnalyzer().analyze(clicks: events.clicks, duration: project.recording.duration, defaultLevel: project.style.zoom.defaultLevel)
        update { p in
            p.zooms = z.map { var s = $0; if p.style.zoom.followCursorByDefault { s.mode = .followCursor }; return s }
        }
        selection = .none
    }

    /// "Toggle Camera Fullscreen": removes the segment under the playhead, or adds one (to the next clip edge, ≤ 5 s).
    func toggleCameraFullscreen() {
        guard hasCamera else { NSSound.beep(); return }
        let t = playheadSource
        if let seg = project.cameraFullscreen.first(where: { t >= $0.start && t <= $0.end }) {
            update { $0.cameraFullscreen.removeAll { $0.id == seg.id } }
            if selection == .camera(seg.id) { selection = .none }
            return
        }
        let end = min(timeline.nextEdge(after: playhead), playhead + 5)
        addCameraSegment(outputStart: playhead, outputEnd: max(end, playhead + LaneMath.minimumDuration))
    }
}
