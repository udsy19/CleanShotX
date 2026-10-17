import AppKit
import AVFoundation
import ShotcraftCore

/// Entry point called once by the app at launch; registers this module's services in `Services`.
public enum RecordingKitModule {
    @MainActor public static func install() {
        Services.recording = RecordingService()
    }
}

/// `RecordingServicing`: select → setup bar → countdown → record → finalize.
@MainActor
final class RecordingService: RecordingServicing {
    private enum Phase {
        case idle
        case selecting
        case setup(RecorderSetupOverlay)
        case countdown(RecordingSession, CountdownOverlay?)
        case recording(RecordingSession)
    }

    private var phase: Phase = .idle
    /// Sessions that were stopped but are still finalizing / encoding a GIF.
    private var finishing: [ObjectIdentifier: RecordingSession] = [:]
    private var editors: [ObjectIdentifier: NSWindowController] = [:]

    var isRecording: Bool {
        switch phase {
        case .countdown, .recording: true
        default: false
        }
    }

    func startRecording(_ kind: RecordingKind, rect: CGRect?) {
        guard case .idle = phase else {
            if case .setup = phase { NSApp.activate(ignoringOtherApps: true) }
            return
        }
        guard Permissions.ensureScreenRecording() else { return }

        if let rect, !rect.isEmpty {
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.active
            showSetup(kind, area: rect, screen: screen)
            return
        }
        guard let capture = Services.capture else {
            showSetup(kind, area: NSScreen.active.frame, screen: NSScreen.active)
            return
        }
        phase = .selecting
        let remembered = Defaults[.rememberLastRecordingArea] ? Defaults[.lastRecordingArea]?.cgRect : nil
        let options = AreaSelectionOptions(purpose: kind == .video ? .recording : .gifRecording, initialRect: remembered)
        capture.selectArea(options) { [weak self] selection in
            guard let self else { return }
            guard let selection else { self.phase = .idle; return }
            // An empty selection (Return without dragging) records the whole screen.
            let area = selection.rect.width < 2 || selection.rect.height < 2 ? selection.screen.frame : selection.rect
            self.showSetup(kind, area: area, screen: selection.screen)
        }
    }

    func stopRecording() {
        switch phase {
        case .recording(let session): session.stop()
        case .countdown(_, let overlay):
            // Without an overlay the stream is already starting; it can be stopped once it runs.
            overlay?.cancel()
        case .setup(let overlay):
            overlay.close()
            phase = .idle
        case .idle, .selecting: break
        }
    }

    // MARK: Flow

    private func showSetup(_ kind: RecordingKind, area: CGRect, screen: NSScreen) {
        let overlay = RecorderSetupOverlay(kind: kind, area: area, screen: screen)
        phase = .setup(overlay)
        overlay.show { [weak self, weak overlay] start in
            guard let self, let overlay else { return }
            let finalArea = overlay.area
            let camera = start ? overlay.takeCamera() : nil
            overlay.close()
            guard start else { self.phase = .idle; return }
            if Defaults[.rememberLastRecordingArea] { Defaults[.lastRecordingArea] = CodableRect(finalArea) }
            self.prepareMicrophone(overlay.kind) {
                self.beginCountdown(overlay.kind, area: finalArea, screen: screen, camera: camera)
            }
        }
    }

    /// Asks for microphone access the first time, so the system prompt doesn't land mid-recording.
    private func prepareMicrophone(_ kind: RecordingKind, then: @escaping () -> Void) {
        guard kind == .video, Defaults[.recordMicrophone], Permissions.status(for: .audio) == .notDetermined else { return then() }
        Permissions.request(.audio) { _ in then() }
    }

    private func beginCountdown(_ kind: RecordingKind, area: CGRect, screen: NSScreen, camera: CameraOverlay?) {
        let session = RecordingSession(kind: kind, area: area, screen: screen, camera: camera)
        session.onStop = { [weak self] s in self?.sessionDidStop(s) }
        session.onEnd = { [weak self] s in self?.sessionEnded(s) }
        guard Defaults[.recordCountdown], Defaults[.recordCountdownSeconds] > 0 else {
            phase = .countdown(session, nil)
            launch(session)
            return
        }
        let countdown = CountdownOverlay(area: session.area, seconds: Defaults[.recordCountdownSeconds])
        phase = .countdown(session, countdown)
        countdown.run { [weak self] start in
            guard let self else { return }
            if start { self.launch(session) } else { session.discard() }
        }
    }

    private func launch(_ session: RecordingSession) {
        Task { @MainActor in
            do {
                try await session.start()
                phase = .recording(session)
            } catch {
                session.discard()
                Alerts.error("An error occurred while starting screen recording.", error)
            }
        }
    }

    private func sessionEnded(_ session: RecordingSession) {
        finishing[ObjectIdentifier(session)] = nil
        switch phase {
        case .recording(let s) where s === session, .countdown(let s, _) where s === session: phase = .idle
        default: break
        }
    }

    /// Moves a stopped session out of `phase` so a new recording can begin while it finalizes.
    private func sessionDidStop(_ session: RecordingSession) {
        finishing[ObjectIdentifier(session)] = session
        if case .recording(let s) = phase, s === session { phase = .idle }
    }

    // MARK: Editor

    func openVideoEditor(_ media: CapturedMedia) {
        if let existing = editors.values.first(where: { ($0 as? MediaEditor)?.media == media }) {
            existing.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller: NSWindowController
        switch media.kind {
        case .gif: controller = GIFEditorWindowController(media: media)
        case .video: controller = VideoEditorWindowController(media: media)
        default: NSSound.beep(); return
        }
        let id = ObjectIdentifier(controller)
        editors[id] = controller
        (controller as? MediaEditor)?.onClose = { [weak self] in self?.editors[id] = nil }
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Common surface of the video and GIF editors.
@MainActor
protocol MediaEditor: AnyObject {
    var media: CapturedMedia { get }
    var onClose: (() -> Void)? { get set }
}
