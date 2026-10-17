import SwiftUI
import ShotcraftCore

struct RecordingPane: View {
    @Default(.videoFormat) private var format
    @Default(.videoFPS) private var fps
    @Default(.videoQuality) private var quality
    @Default(.scaleRetinaVideosTo1x) private var scaleRetina
    @Default(.gifFPS) private var gifFPS
    @Default(.gifMaxWidth) private var gifMaxWidth
    @Default(.recordShowCursor) private var showCursor
    @Default(.recordHighlightClicks) private var highlightClicks
    @Default(.clickHighlightColor) private var clickColor
    @Default(.recordShowKeystrokes) private var showKeystrokes
    @Default(.recordHideCursorWhenNotMoving) private var hideIdleCursor
    @Default(.recordDimScreen) private var dimScreen
    @Default(.recordShowControls) private var showControls
    @Default(.recordShowTimeInMenuBar) private var showTime
    @Default(.recordCountdown) private var countdown
    @Default(.recordCountdownSeconds) private var countdownSeconds
    @Default(.recordMicrophone) private var microphone
    @Default(.microphoneDeviceID) private var microphoneID
    @Default(.recordSystemAudio) private var systemAudio
    @Default(.recordAudioMono) private var mono
    @Default(.recordCamera) private var camera
    @Default(.cameraDeviceID) private var cameraID
    @Default(.recordDoNotDisturb) private var doNotDisturb
    @Default(.recordInStudioMode) private var studioMode
    @Default(.rememberLastRecordingArea) private var rememberArea

    @StateObject private var devices = CaptureDevicesModel()
    @StateObject private var permissions = PermissionsModel()

    private static let fpsChoices = [24, 30, 50, 60]
    private static let gifFPSChoices = [5, 10, 15, 20, 25, 30]
    private static let gifWidthChoices = [0, 480, 640, 800, 1024, 1280, 1920]

    var body: some View {
        PaneForm(pane: .recording) {
            Section("Video") {
                Picker("Format", selection: $format) {
                    ForEach(VideoFormat.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Frame rate", selection: $fps) {
                    ForEach(Self.fpsChoices, id: \.self) { Text("\($0) FPS").tag($0) }
                }
                Picker("Quality", selection: $quality) {
                    ForEach(VideoQuality.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                SettingToggle("Scale Retina videos to 1x", isOn: $scaleRetina,
                              help: "Halves the resolution on Retina displays for much smaller files.")
                Toggle("Record in Studio Mode by default", isOn: $studioMode)
                Toggle("Remember last recording area", isOn: $rememberArea)
            }

            Section("GIF") {
                Picker("Frame rate", selection: $gifFPS) {
                    ForEach(Self.gifFPSChoices, id: \.self) { Text("\($0) FPS").tag($0) }
                }
                Picker("Maximum width", selection: $gifMaxWidth) {
                    ForEach(Self.gifWidthChoices, id: \.self) { Text($0 == 0 ? "Original" : "\($0) px").tag($0) }
                }
            }

            Section("Cursor & keyboard") {
                Toggle("Show cursor", isOn: $showCursor)
                Toggle("Hide cursor when not moving", isOn: $hideIdleCursor).disabled(!showCursor)
                Toggle("Highlight clicks", isOn: $highlightClicks)
                if highlightClicks {
                    ColorPicker("Highlight color", selection: $clickColor.color, supportsOpacity: true)
                }
                Toggle(isOn: $showKeystrokes) {
                    Text("Show Keystrokes")
                    Text("Displays pressed key combinations on the recording.")
                }
                if showKeystrokes && permissions.states[.accessibility] != .granted {
                    PermissionRow(kind: .accessibility, model: permissions)
                }
            }

            Section("While recording") {
                Toggle("Show recording controls", isOn: $showControls)
                Toggle("Display recording time in menu bar", isOn: $showTime)
                Toggle("Dim screen while recording", isOn: $dimScreen)
                Toggle(isOn: $countdown) {
                    Text("Show countdown")
                }
                if countdown {
                    Stepper(value: $countdownSeconds, in: 1...10) {
                        LabeledContent("Countdown", value: "\(countdownSeconds) s")
                    }
                }
                Toggle(isOn: $doNotDisturb) {
                    Text("Turn on Do Not Disturb while recording")
                    Text("Keeps notification banners out of your recordings.")
                }
            }

            Section("Audio") {
                Toggle("Record microphone", isOn: $microphone)
                if microphone {
                    DevicePicker(title: "Microphone", devices: devices.microphones, selection: $microphoneID)
                    if permissions.states[.microphone] != .granted { PermissionRow(kind: .microphone, model: permissions) }
                }
                Toggle(isOn: $systemAudio) {
                    Text("Record computer audio")
                    Text("Enable this option to record sound that comes from other applications.")
                }
                Toggle("Record audio in mono", isOn: $mono).disabled(!microphone && !systemAudio)
            }

            Section("Camera") {
                Toggle("Record camera", isOn: $camera)
                if camera {
                    DevicePicker(title: "Camera", devices: devices.cameras, selection: $cameraID)
                    if permissions.states[.camera] != .granted { PermissionRow(kind: .camera, model: permissions) }
                }
            }
        }
        .onAppear { permissions.startMonitoring(); devices.reload() }
        .onDisappear { permissions.stopMonitoring() }
    }
}
