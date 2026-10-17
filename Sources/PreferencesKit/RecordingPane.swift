import SwiftUI
import SuperScreenshotCore

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
    private static let countdownChoices = [1, 2, 3, 5, 10]

    var body: some View {
        PaneForm(pane: .recording) {
            Section("General") {
                SettingToggle("Show controls while recording", isOn: $showControls)
                SettingToggle("Remember last selection", isOn: $rememberArea)
                SettingToggle("Display recording time in menu bar", isOn: $showTime)
                SettingToggle("Dim screen while recording", isOn: $dimScreen)
                SettingToggle("Show countdown", isOn: $countdown)
                Picker("Countdown", selection: $countdownSeconds) {
                    ForEach(PickerChoices.including(countdownSeconds, in: Self.countdownChoices), id: \.self) {
                        Text($0 == 1 ? "1 second" : "\($0) seconds").tag($0)
                    }
                }
                .disabled(!countdown)
                SettingToggle("“Do Not Disturb” while recording", isOn: $doNotDisturb,
                              help: "Keeps notification banners out of your recordings.")
                SettingToggle("Record in Studio Mode by default", isOn: $studioMode)
            }

            Section("Cursor") {
                SettingToggle("Show cursor", isOn: $showCursor)
                SettingToggle("Hide cursor when not moving", isOn: $hideIdleCursor).disabled(!showCursor)
                LabeledContent {
                    HStack(spacing: 8) {
                        OptionsButton {
                            ColorPicker("Highlight color", selection: $clickColor.color, supportsOpacity: true)
                        }
                        .disabled(!highlightClicks)
                        SettingToggle("Highlight clicks", isOn: $highlightClicks)
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                } label: { Text("Highlight clicks") }
            }

            Section("Keystrokes") {
                SettingToggle("Show keystrokes", isOn: $showKeystrokes,
                              help: "Displays pressed key combinations on the recording.")
                if showKeystrokes && permissions.states[.accessibility] != .granted {
                    PermissionRow(kind: .accessibility, model: permissions)
                }
            }

            Section("Video") {
                Picker("Format", selection: $format) {
                    ForEach(VideoFormat.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                Picker("Frame rate", selection: $fps) {
                    ForEach(PickerChoices.including(fps, in: Self.fpsChoices), id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker(selection: $quality) {
                    ForEach(VideoQuality.allCases, id: \.self) { Text($0.displayName).tag($0) }
                } label: {
                    Text("Quality")
                    Text("Lower quality reduces file size and upload time.")
                }
                SettingToggle("Scale Retina videos to 1x", isOn: $scaleRetina)
            }

            Section {
                SettingToggle("Record audio in mono", isOn: $mono).disabled(!microphone && !systemAudio)
                SettingToggle("Record microphone", isOn: $microphone)
                if microphone {
                    DevicePicker(title: "Microphone", devices: devices.microphones, selection: $microphoneID)
                    if permissions.states[.microphone] != .granted { PermissionRow(kind: .microphone, model: permissions) }
                }
                SettingToggle("Record system audio", isOn: $systemAudio,
                              help: "Enable this option to record sound that comes from other applications.")
            } header: { Text("Audio") }

            Section("Camera") {
                SettingToggle("Record camera", isOn: $camera)
                if camera {
                    DevicePicker(title: "Camera", devices: devices.cameras, selection: $cameraID)
                    if permissions.states[.camera] != .granted { PermissionRow(kind: .camera, model: permissions) }
                }
            }

            Section("GIF") {
                Picker("Frame rate", selection: $gifFPS) {
                    ForEach(PickerChoices.including(gifFPS, in: Self.gifFPSChoices), id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("Resolution", selection: $gifMaxWidth) {
                    ForEach(PickerChoices.including(gifMaxWidth, in: Self.gifWidthChoices), id: \.self) {
                        Text($0 == 0 ? "Original" : "\($0) × auto").tag($0)
                    }
                }
            }
        }
        .onAppear { permissions.startMonitoring(); devices.reload() }
        .onDisappear { permissions.stopMonitoring() }
    }
}
