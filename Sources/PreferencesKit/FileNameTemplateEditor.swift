import AppKit
import SwiftUI
import SuperScreenshotCore

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
    /// Edited as text so a value typed just before clicking OK is never lost (number fields commit on Return only).
    @State private var counterText = String(Defaults[FileNameTemplate.counterKey])
    @StateObject private var field = TemplateFieldController()

    init(initial: String, fileExtension: String, finish: @escaping (String?) -> Void) {
        self.fileExtension = fileExtension
        self.finish = finish
        _draft = State(initialValue: initial)
    }

    private var counter: Int? {
        Int(counterText.trimmingCharacters(in: .whitespaces)).flatMap { $0 >= 0 ? $0 : nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("File name format").font(.headline)
                Text("Type text and click elements to create a custom format:").font(.callout).foregroundStyle(.secondary)
            }

            TemplateTextField(text: $draft, controller: field)
                .frame(height: 24)

            VStack(alignment: .leading, spacing: 4) {
                previewRow("Preview:", kind: CaptureMode.area.fileNameKind, ext: fileExtension)
                previewRow("Recording:", kind: CaptureMode.recording.fileNameKind, ext: Defaults[.videoFormat].fileExtension)
                let unknown = TemplateEditing.unknownTokens(in: draft)
                if !unknown.isEmpty {
                    Label("Unknown \(unknown.joined(separator: ", ")) will appear literally. Use %% for a percent sign.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            // Token legend: two columns of chips; clicking one inserts it at the caret.
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(FileNameTemplate.tokens, id: \.token) { token in
                    Button { field.insert(token.token, into: &draft) } label: {
                        HStack(spacing: 8) {
                            Text(token.description)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.22)))
                            Text(token.token).font(.callout.monospaced()).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Insert \(token.description.lowercased()) (\(token.token))")
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))

            HStack(spacing: 8) {
                Text("Auto-increment next number:")
                TextField("Next number", text: $counterText)
                    .labelsHidden().frame(width: 80)
                    .monospacedDigit()
                if counter == nil {
                    Label("Enter a whole number", systemImage: "exclamationmark.circle.fill")
                        .font(.callout).foregroundStyle(.red)
                }
            }

            HStack {
                Button("Restore Defaults") { draft = FileNameTemplate.defaultTemplate }
                Spacer()
                Button("Cancel", role: .cancel) { finish(nil) }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    if let counter { Defaults[FileNameTemplate.counterKey] = counter }
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    finish(trimmed.isEmpty ? FileNameTemplate.defaultTemplate : trimmed)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(counter == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func previewRow(_ title: String, kind: String, ext: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(preview(kind: kind) + "." + ext)
                .font(.callout).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func preview(kind: String) -> String {
        // Show the number the next capture will use rather than the stored counter.
        FileNameTemplate.render(TemplateEditing.substitutingCounter(in: draft, with: counter ?? 0),
                                kind: kind, appName: "Safari", advanceCounter: false)
    }
}
