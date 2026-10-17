import SwiftUI
import ShotcraftCore

struct QuickAccessPane: View {
    @Default(.quickAccessSide) private var side
    @Default(.quickAccessScreen) private var screen
    @Default(.quickAccessSize) private var size
    @Default(.quickAccessAutoClose) private var autoClose
    @Default(.quickAccessAutoCloseSeconds) private var autoCloseSeconds
    @Default(.quickAccessAutoCloseAction) private var autoCloseAction
    @Default(.quickAccessCloseAfterDragging) private var closeAfterDragging
    @Default(.quickAccessCloseAfterUploading) private var closeAfterUploading
    @Default(.quickAccessSaveBehavior) private var saveBehavior
    @Default(.quickAccessShowUploadButton) private var showUploadButton

    private static let autoCloseActions: [AfterCaptureAction] = [.save, .copyToClipboard, .upload]
    private static let intervalChoices = [5, 10, 15, 30, 60, 120]

    var body: some View {
        PaneForm(pane: .quickAccess) {
            Section("Appearance") {
                Picker("Position on screen", selection: $side) {
                    Text("Left").tag(ScreenSide.left)
                    Text("Right").tag(ScreenSide.right)
                }
                Toggle(isOn: moveToActiveScreen) {
                    Text("Move to active screen")
                    Text("Active screen is the screen where your cursor is pointing.")
                }
                LabeledContent("Overlay size") {
                    // Five ticks: 60 %, 80 %, 100 %, 120 %, 140 %.
                    Slider(value: $size, in: 0.6...1.4, step: 0.2) {
                        Text("Overlay size")
                    } minimumValueLabel: {
                        Image(systemName: "rectangle.portrait").imageScale(.small)
                    } maximumValueLabel: {
                        Image(systemName: "rectangle.portrait").imageScale(.large)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .help("\(Int((size * 100).rounded()))%")
                }
            }

            Section("Behavior") {
                Toggle("Auto-close", isOn: $autoClose)
                Picker("Action", selection: $autoCloseAction) {
                    Text("Close").tag(AfterCaptureAction?.none)
                    ForEach(Self.autoCloseActions, id: \.self) { Text(label(for: $0)).tag(AfterCaptureAction?.some($0)) }
                }
                .disabled(!autoClose)
                Picker("Interval", selection: $autoCloseSeconds) {
                    ForEach(PickerChoices.including(autoCloseSeconds, in: Self.intervalChoices), id: \.self) { seconds in
                        Text(seconds == 1 ? "1 second" : "\(seconds) seconds").tag(seconds)
                    }
                }
                .disabled(!autoClose)
            }

            Section {
                SettingToggle("Close after dragging", isOn: $closeAfterDragging,
                              help: "Removes the item from the overlay once it's dropped into another app.")
                Toggle("Close after uploading", isOn: $closeAfterUploading)
                Toggle("Show upload button", isOn: $showUploadButton)
                Picker("Save button behavior", selection: $saveBehavior) {
                    ForEach(SaveButtonBehavior.allCases, id: \.self) { Text(saveLabel(for: $0)).tag($0) }
                }
            }
        }
    }

    private var moveToActiveScreen: Binding<Bool> {
        Binding(get: { screen == .activeScreen }, set: { screen = $0 ? .activeScreen : .mainScreen })
    }

    private func label(for action: AfterCaptureAction) -> String {
        switch action {
        case .save: "Save and Close"
        case .copyToClipboard: "Copy and Close"
        case .upload: "Upload and Close"
        default: action.displayName
        }
    }

    private func saveLabel(for behavior: SaveButtonBehavior) -> String {
        behavior == .saveToExportLocation ? "Save to “Export location”" : behavior.displayName
    }
}
