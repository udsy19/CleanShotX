import AppKit
import SuperScreenshotCore

/// Maps every `AppAction` to the module service that implements it.
@MainActor
enum ActionRouter {
    static var isAnyRecording: Bool { Services.recording.isRecording || Services.studio.isRecording }

    static func stopAnyRecording() {
        if Services.studio.isRecording { Services.studio.stopRecording() } else { Services.recording.stopRecording() }
    }

    static func perform(_ action: AppAction) {
        // A capture shortcut pressed while recording stops the recording instead (matches the menu bar behavior).
        if isAnyRecording, [.recordScreen, .recordGIF, .recordStudio].contains(action) {
            stopAnyRecording(); return
        }
        switch action {
        case .allInOne: Services.capture.allInOne()
        case .captureArea: Services.capture.captureArea(CaptureOptions())
        case .capturePreviousArea: Services.capture.capturePreviousArea(CaptureOptions())
        case .captureFullscreen: Services.capture.captureFullscreen(CaptureOptions())
        case .captureWindow: Services.capture.captureWindow(CaptureOptions())
        case .selfTimer: Services.capture.selfTimer(CaptureOptions())
        case .captureAreaAndCopy: Services.capture.captureArea(CaptureOptions(actions: [.copyToClipboard]))
        case .captureAreaAndSave: Services.capture.captureArea(CaptureOptions(actions: [.save]))
        case .captureAreaAndAnnotate: Services.capture.captureArea(CaptureOptions(actions: [.annotate]))
        case .captureAreaAndUpload: Services.capture.captureArea(CaptureOptions(actions: [.upload, .showQuickAccess]))
        case .captureAreaAndPin: Services.capture.captureArea(CaptureOptions(actions: [.pin]))
        case .scrollingCapture: Services.text.startScrollingCapture(CaptureOptions())
        case .captureText: Services.text.captureText(keepLineBreaks: nil)
        case .recordScreen:
            if Defaults[.recordInStudioMode] { Services.studio.startStudioRecording(rect: nil) }
            else { Services.recording.startRecording(.video, rect: nil) }
        case .recordGIF: Services.recording.startRecording(.gif, rect: nil)
        case .recordStudio: Services.studio.startStudioRecording(rect: nil)
        case .toggleDesktopIcons: Services.capture.setDesktopIconsHidden(!Services.capture.desktopIconsHidden)
        case .openAnnotate: Services.annotate.openWithPanel()
        case .openFromClipboard: Services.annotate.openFromClipboard()
        case .annotateLast:
            if let last = Services.history.items.first(where: \.isImage) { Services.annotate.open(last) } else { NSSound.beep() }
        case .pinScreenshot: Services.pin.pinWithPanel()
        case .pinLast:
            if let last = Services.history.items.first(where: \.isImage) { Services.pin.pin(last) } else { NSSound.beep() }
        case .togglePins: Services.pin.toggleVisibility()
        case .closeAllOverlays: Services.quickAccess.closeAll(); Services.pin.closeAll()
        case .openHistory: Services.history.showWindow()
        case .restoreLastCapture: Services.history.restoreLast()
        case .colorPicker: Services.capture.pickColor()
        case .openPreferences: Services.preferences.show(pane: nil)
        }
    }
}
