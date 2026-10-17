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

    var body: some View {
        PaneForm(pane: .quickAccess) {
            Section {
                QuickAccessPreview(side: side, scale: size)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            Section("Position") {
                Picker("Position on screen", selection: $side) {
                    Text("Left").tag(ScreenSide.left)
                    Text("Right").tag(ScreenSide.right)
                }
                .pickerStyle(.segmented)
                Picker("Show on", selection: $screen) {
                    Text("Active screen (follows the cursor)").tag(OverlayScreenChoice.activeScreen)
                    Text("Main screen").tag(OverlayScreenChoice.mainScreen)
                }
                LabeledContent("Overlay size") {
                    HStack {
                        Image(systemName: "rectangle.portrait").imageScale(.small).foregroundStyle(.secondary)
                        Slider(value: $size, in: 0.6...1.4, step: 0.1)
                            .frame(maxWidth: 220)
                        Image(systemName: "rectangle.portrait").imageScale(.large).foregroundStyle(.secondary)
                        Text("\(Int((size * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }

            Section("Auto-close") {
                Toggle("Close overlay automatically", isOn: $autoClose)
                if autoClose {
                    Stepper(value: $autoCloseSeconds, in: 3...120, step: 1) {
                        LabeledContent("After", value: "\(autoCloseSeconds) seconds")
                    }
                    Picker(selection: $autoCloseAction) {
                        Text("Just close").tag(AfterCaptureAction?.none)
                        ForEach(Self.autoCloseActions, id: \.self) { Text(label(for: $0)).tag(AfterCaptureAction?.some($0)) }
                    } label: {
                        Text("When closing")
                        Text("What happens to the capture when the overlay closes on its own.")
                    }
                }
            }

            Section("Behavior") {
                Toggle("Close after dragging", isOn: $closeAfterDragging)
                Toggle("Close after uploading", isOn: $closeAfterUploading)
                Toggle("Show upload button", isOn: $showUploadButton)
                Picker("Save button", selection: $saveBehavior) {
                    ForEach(SaveButtonBehavior.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
        }
    }

    private func label(for action: AfterCaptureAction) -> String {
        switch action {
        case .save: "Save to export location"
        case .copyToClipboard: "Copy to clipboard"
        case .upload: "Upload & copy link"
        default: action.displayName
        }
    }
}

/// Miniature screen showing where (and how large) the overlay appears.
private struct QuickAccessPreview: View {
    let side: ScreenSide
    let scale: Double

    var body: some View {
        let screen = CGSize(width: 300, height: 180)
        let card = CGSize(width: 64 * scale, height: 44 * scale)
        ZStack(alignment: side == .left ? .bottomLeading : .bottomTrailing) {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [Color.accentColor.opacity(0.55), Color.purple.opacity(0.45)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Rectangle().fill(.ultraThinMaterial).frame(height: 8)
                .frame(maxHeight: .infinity, alignment: .top)
            VStack(spacing: 6) {
                ForEach(0..<2) { i in
                    RoundedRectangle(cornerRadius: 6 * scale)
                        .fill(.regularMaterial)
                        .overlay(Image(systemName: i == 0 ? "photo" : "play.rectangle")
                            .font(.system(size: 14 * scale)).foregroundStyle(.secondary))
                        .frame(width: card.width, height: card.height)
                        .shadow(radius: 2, y: 1)
                        .opacity(i == 0 ? 1 : 0.7)
                }
            }
            .padding(10)
        }
        .frame(width: screen.width, height: screen.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .animation(.snappy, value: side)
        .animation(.snappy, value: scale)
        .padding(.vertical, 4)
        .accessibilityLabel("Preview of the Quick Access Overlay position and size")
    }
}
