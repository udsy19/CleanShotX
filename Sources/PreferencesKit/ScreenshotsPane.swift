import AppKit
import SwiftUI
import ShotcraftCore

struct ScreenshotsPane: View {
    @Default(.screenshotFormat) private var format
    @Default(.jpegQuality) private var jpegQuality
    @Default(.scaleRetinaScreenshotsTo1x) private var scaleRetina
    @Default(.convertToSRGB) private var convertToSRGB
    @Default(.addBorderToScreenshots) private var addBorder
    @Default(.showCursorOnScreenshots) private var showCursor
    @Default(.freezeScreenWhenCapturing) private var freezeScreen
    @Default(.crosshairMode) private var crosshair
    @Default(.showMagnifier) private var magnifier
    @Default(.rememberLastSelection) private var rememberLastSelection
    @Default(.selfTimerSeconds) private var selfTimerSeconds
    @Default(.captureWindowShadow) private var windowShadow
    @Default(.windowBackgroundStyle) private var backgroundStyle
    @Default(.windowBackgroundColor) private var backgroundColor
    @Default(.windowBackgroundPadding) private var backgroundPadding
    @Default(.fileNameTemplate) private var fileNameTemplate
    @Default(.askForNameAfterCapture) private var askForName
    @State private var editingTemplate = false

    private static let timerChoices = [3, 5, 10]

    var body: some View {
        PaneForm(pane: .screenshots) {
            Section("Format") {
                Picker("File format", selection: $format) {
                    ForEach(ImageFormat.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                if format == .jpeg || format == .heic {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $jpegQuality, in: 0.3...1.0, step: 0.05).frame(maxWidth: 240)
                            Text("\(Int((jpegQuality * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                }
                SettingToggle("Scale Retina screenshots to 1x", isOn: $scaleRetina,
                              help: "Saves screenshots at their point size, producing smaller files.")
                SettingToggle("Convert to sRGB profile", isOn: $convertToSRGB,
                              help: "Gives consistent colors in browsers and apps that ignore display profiles.")
                Toggle("Add 1px border to all screenshots", isOn: $addBorder)
            }

            Section("Capturing") {
                Toggle("Show cursor on screenshots", isOn: $showCursor)
                Toggle("Freeze screen when taking a screenshot", isOn: $freezeScreen)
                Toggle("Remember last selection", isOn: $rememberLastSelection)
                Toggle("Crosshair mode", isOn: crosshairBinding)
                Toggle(isOn: $magnifier) {
                    Text("Show magnifier")
                    if !crosshair { Text("To enable magnifier, you must enable Crosshair Mode first.") }
                }
                .disabled(!crosshair)
                Picker("Self-timer", selection: $selfTimerSeconds) {
                    ForEach(timerChoices, id: \.self) { Text("\($0) seconds").tag($0) }
                }
            }

            Section("Window screenshots") {
                Toggle("Capture window shadow", isOn: $windowShadow)
                Picker("Background", selection: $backgroundStyle) {
                    ForEach(WindowBackgroundStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if backgroundStyle == .color {
                    ColorPicker("Background color", selection: $backgroundColor.color, supportsOpacity: false)
                }
                if backgroundStyle == .customWallpaper {
                    LabeledContent("Custom wallpaper") {
                        Button("Configure in Wallpaper…") { Services.preferences?.show(pane: PreferencesPane.wallpaper.rawValue) }
                    }
                }
                if backgroundStyle != .transparent {
                    LabeledContent("Padding") {
                        HStack {
                            Slider(value: $backgroundPadding, in: 0...160, step: 4).frame(maxWidth: 240)
                            Text("\(Int(backgroundPadding)) pt").monospacedDigit().frame(width: 50, alignment: .trailing)
                        }
                    }
                }
            }

            Section("File name") {
                LabeledContent {
                    Button("Edit…") { editingTemplate = true }
                } label: {
                    Text("File name format")
                    Text(FileNameTemplate.render(fileNameTemplate, kind: CaptureMode.area.fileNameKind, appName: "Safari",
                                                 advanceCounter: false) + "." + format.fileExtension)
                        .lineLimit(1).truncationMode(.middle)
                }
                Toggle("Ask for name after every capture", isOn: $askForName)
            }
        }
        .sheet(isPresented: $editingTemplate) {
            FileNameTemplateEditor(initial: fileNameTemplate, fileExtension: format.fileExtension) { result in
                if let result { fileNameTemplate = result }
                editingTemplate = false
            }
        }
    }

    private var timerChoices: [Int] {
        Self.timerChoices.contains(selfTimerSeconds) ? Self.timerChoices : (Self.timerChoices + [selfTimerSeconds]).sorted()
    }

    /// Turning crosshair mode off also turns the magnifier off (it depends on it).
    private var crosshairBinding: Binding<Bool> {
        Binding(get: { crosshair }, set: { on in
            crosshair = on
            if !on { magnifier = false }
        })
    }
}

// MARK: - File name template editor (NameTemplateWindow)

/// Holds the AppKit text field so token chips can be inserted at the caret.
@MainActor
final class TemplateFieldController: ObservableObject {
    weak var field: NSTextField?

    func insert(_ token: String, into text: inout String) {
        let selection = field?.currentEditor()?.selectedRange ?? NSRange(location: (text as NSString).length, length: 0)
        let result = TemplateEditing.inserting(token, into: text, replacing: selection)
        text = result.text
        guard let field else { return }
        field.stringValue = result.text
        field.window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: result.caret, length: 0)
    }
}

private struct TemplateTextField: NSViewRepresentable {
    @Binding var text: String
    let controller: TemplateFieldController

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: text)
        f.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        f.placeholderString = FileNameTemplate.defaultTemplate
        f.delegate = context.coordinator
        f.lineBreakMode = .byTruncatingTail
        f.cell?.isScrollable = true
        controller.field = f
        return f
    }

    func updateNSView(_ f: NSTextField, context: Context) {
        if f.stringValue != text { f.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ obj: Notification) {
            if let f = obj.object as? NSTextField { text.wrappedValue = f.stringValue }
        }
    }
}

struct FileNameTemplateEditor: View {
    let fileExtension: String
    let finish: (String?) -> Void
    @State private var draft: String
    @State private var counter = Defaults[FileNameTemplate.counterKey]
    @StateObject private var field = TemplateFieldController()

    init(initial: String, fileExtension: String, finish: @escaping (String?) -> Void) {
        self.fileExtension = fileExtension
        self.finish = finish
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("File name format").font(.title3.bold())

            TemplateTextField(text: $draft, controller: field)
                .frame(height: 24)

            VStack(alignment: .leading, spacing: 6) {
                Text("Click a token to insert it at the cursor:").font(.callout).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
                    ForEach(FileNameTemplate.tokens, id: \.token) { token in
                        Button { field.insert(token.token, into: &draft) } label: {
                            HStack(spacing: 4) {
                                Text(token.description)
                                Text(token.token).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Insert \(token.token)")
                    }
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    previewRow("Screenshot", kind: CaptureMode.area.fileNameKind, ext: fileExtension)
                    previewRow("Recording", kind: CaptureMode.recording.fileNameKind, ext: Defaults[.videoFormat].fileExtension)
                    let unknown = TemplateEditing.unknownTokens(in: draft)
                    if !unknown.isEmpty {
                        Label("Unknown \(unknown.joined(separator: ", ")) will appear literally. Use %% for a percent sign.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: { Text("Preview") }

            if draft.contains("%i") {
                LabeledContent("Next number (%i)") {
                    TextField("Next number", value: $counter, format: .number)
                        .labelsHidden().frame(width: 90)
                }
            }

            HStack {
                Button("Restore Defaults") { draft = FileNameTemplate.defaultTemplate }
                Spacer()
                Button("Cancel", role: .cancel) { finish(nil) }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    if draft.contains("%i") { Defaults[FileNameTemplate.counterKey] = max(0, counter) }
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    finish(trimmed.isEmpty ? FileNameTemplate.defaultTemplate : trimmed)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func previewRow(_ title: String, kind: String, ext: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(preview(kind: kind) + "." + ext)
                .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func preview(kind: String) -> String {
        // Show the number the next capture will use rather than the stored counter.
        FileNameTemplate.render(TemplateEditing.substitutingCounter(in: draft, with: counter),
                                kind: kind, appName: "Safari", advanceCounter: false)
    }
}
