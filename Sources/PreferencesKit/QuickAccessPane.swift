import SwiftUI
import ShotcraftCore

struct QuickAccessPane: View {
    @Default(.quickAccessSide) private var side
    @Default(.quickAccessScreen) private var screen
    @Default(.quickAccessSizeIndex) private var sizeIndex
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
                .accessibilityLabel("Move to active screen")
                LabeledContent("Overlay size") {
                    // Five ticks: one per card width in `QuickAccessSize.widths`.
                    Slider(value: sizeTick, in: 0...Double(QuickAccessSize.maxIndex), step: 1) {
                        Text("Overlay size")
                    } minimumValueLabel: {
                        Image(systemName: "rectangle.portrait").imageScale(.small)
                    } maximumValueLabel: {
                        Image(systemName: "rectangle.portrait").imageScale(.large)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .help("\(Int(QuickAccessSize.widths[QuickAccessSize.clamped(sizeIndex)])) pt")
                }
            }

            Section("Behavior") {
                SettingToggle("Auto-close", isOn: $autoClose)
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
                SettingToggle("Close after uploading", isOn: $closeAfterUploading)
                SettingToggle("Show upload button", isOn: $showUploadButton)
                Picker("Save button behavior", selection: $saveBehavior) {
                    ForEach(SaveButtonBehavior.allCases, id: \.self) { Text(saveLabel(for: $0)).tag($0) }
                }
            }
        }
    }

    /// The stored index as the slider's value.
    private var sizeTick: Binding<Double> {
        Binding(get: { Double(QuickAccessSize.clamped(sizeIndex)) }, set: { sizeIndex = QuickAccessSize.clamped(Int($0.rounded())) })
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
