import AppKit
import SwiftUI
import ShotcraftCore

struct AdvancedPane: View {
    @Default(.askForNameAfterCapture) private var askForName
    @Default(.fileNameTemplate) private var fileNameTemplate
    @Default(.screenshotFormat) private var screenshotFormat
    @Default(.clipboardContent) private var clipboardContent
    @Default(.ocrKeepLineBreaks) private var keepLineBreaks
    @Default(.ocrLanguageMode) private var languageMode
    @Default(.ocrLanguages) private var languages
    @Default(.ocrOpenLinks) private var openLinks
    @Default(.historyEnabled) private var historyEnabled
    @Default(.historyRetentionDays) private var retentionDays
    @Default(.rememberLastSelection) private var rememberLastSelection
    @Default(.pinLockAndHideOnHover) private var pinLockAndHide
    @Default(.pinShowShadow) private var pinShadow
    @Default(.allowURLSchemeAPI) private var allowURLScheme
    @Default(.suppressedWarnings) private var suppressedWarnings
    @State private var editingTemplate = false
    @State private var showingLanguages = false
    @State private var showingURLDocs = false
    /// Vision's languages, read once per appearance (empty when TextKit isn't installed).
    @State private var available: [(code: String, name: String)] = []

    private static let retentionChoices = [1, 3, 7, 14, 30, 90, 0]
    /// Popup tag for "Multiple languages" in the Language picker.
    private static let multipleTag = "__multiple__"
    private static let automaticTag = "__automatic__"

    var body: some View {
        PaneForm(pane: .advanced) {
            Section("File Name") {
                SettingToggle("Ask for name after every capture", isOn: $askForName)
                LabeledContent {
                    Button("Customize…") { editingTemplate = true }
                } label: {
                    Text("File name format")
                    Text(FileNameTemplate.render(fileNameTemplate, kind: CaptureMode.area.fileNameKind, appName: "Safari",
                                                 advanceCounter: false) + "." + screenshotFormat.fileExtension)
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            Section("Clipboard") {
                Picker(selection: $clipboardContent) {
                    ForEach(ClipboardContent.allCases, id: \.self) { Text($0.displayName).tag($0) }
                } label: {
                    Text("Copy to clipboard")
                    Text("Adjust this option if you've encountered any issues with pasting from clipboard or clipboard managers.")
                }
            }

            Section("Capture History") {
                Picker(selection: historyBinding) {
                    Text("Disabled").tag(-1)
                    Divider()
                    ForEach(PickerChoices.including(retentionDays, in: Self.retentionChoices), id: \.self) { d in
                        Text(d == 0 ? "Forever" : d == 1 ? "1 day" : "\(d) days").tag(d)
                    }
                } label: {
                    Text("Keep history")
                    Text(historyEnabled ? "You can restore old files with “Capture History” option from the menu bar."
                                        : "Capture History is disabled.")
                }
                LabeledContent("Captured files") {
                    Button("Clear History…") { clearHistory() }
                        .disabled(Services.history == nil)
                }
            }

            Section("Text Recognition") {
                LabeledContent {
                    HStack(spacing: 8) {
                        Picker("Language", selection: languageBinding) {
                            Text("Automatically Detect Language").tag(Self.automaticTag)
                            Divider()
                            if languageMode == .manual && languages.count > 1 {
                                Text("\(languages.count) Languages").tag(Self.multipleTag)
                            }
                            ForEach(languageOptions, id: \.code) { Text($0.name).tag($0.code) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button("Choose…") { showingLanguages = true }
                            .help("Recognize text in several languages")
                    }
                } label: {
                    Text("Language")
                    if languageMode == .manual {
                        Text(languages.map(languageName).joined(separator: ", ")).lineLimit(2)
                    }
                }
                SettingToggle("Keep line breaks", isOn: $keepLineBreaks)
                SettingToggle("Detect links", isOn: $openLinks,
                              help: "When the recognized text is a single link, open it in your browser.")
            }

            Section("All-In-One") {
                SettingToggle("Remember last selection", isOn: $rememberLastSelection,
                              help: "All-In-One starts with the area you selected last time.")
            }

            Section("Pinned Screenshots") {
                SettingToggle("Lock and hide screenshot on mouse over", isOn: $pinLockAndHide)
                SettingToggle("Shadow", isOn: $pinShadow)
            }

            Section {
                SettingToggle("Allow URL scheme API", isOn: $allowURLScheme,
                              help: "Lets other apps and scripts (Shortcuts, Raycast, Alfred) control Shotcraft with shotcraft:// links. When off, you're asked the first time an app tries.")
                DisclosureGroup("Commands", isExpanded: $showingURLDocs) {
                    URLSchemeDocs()
                }
            } header: { Text("API") }

            Section("Reset") {
                LabeledContent {
                    Button("Reset All Warning Dialogs") {
                        suppressedWarnings = []
                        HUD.show("All warning dialogs are now enabled.")
                    }
                    .disabled(suppressedWarnings.isEmpty)
                } label: {
                    Text("Warning dialogs")
                    Text(suppressedWarnings.isEmpty ? "No dialogs are hidden." : "\(suppressedWarnings.count) hidden with “Don't ask again”.")
                }
                LabeledContent {
                    Button("Restore Defaults…") { restoreDefaults() }
                } label: {
                    Text("All settings")
                    Text("Shortcuts and every preference return to their original values. Upload secrets stay in the Keychain.")
                }
            }
        }
        .onAppear { available = Services.text?.supportedLanguages() ?? [] }
        .sheet(isPresented: $editingTemplate) {
            FileNameTemplateEditor(initial: fileNameTemplate, fileExtension: screenshotFormat.fileExtension) { result in
                if let result { fileNameTemplate = result }
                editingTemplate = false
            }
        }
        .sheet(isPresented: $showingLanguages) {
            OCRLanguagesSheet(selection: languagesBinding, available: languageOptions) { showingLanguages = false }
        }
    }

    /// The recognizer's languages plus any stored code it doesn't list (so the popup can always show the value).
    private var languageOptions: [(code: String, name: String)] {
        let extra = languages.filter { code in !available.contains { $0.code == code } }
        return available + extra.map { ($0, OCRLanguageSelection.displayName($0)) }
    }

    private func languageName(_ code: String) -> String {
        available.first { $0.code == code }?.name ?? OCRLanguageSelection.displayName(code)
    }

    private var languageBinding: Binding<String> {
        Binding(get: {
            if languageMode == .automatic { return Self.automaticTag }
            return languages.count == 1 ? languages[0] : Self.multipleTag
        }, set: { tag in
            switch tag {
            case Self.automaticTag: languageMode = .automatic
            case Self.multipleTag: break
            default: languages = [tag]; languageMode = .manual
            }
        })
    }

    /// Choosing languages in the sheet switches recognition to manual mode.
    private var languagesBinding: Binding<[String]> {
        Binding(get: { languages }, set: { languages = $0; languageMode = .manual })
    }

    private var historyBinding: Binding<Int> {
        Binding(get: { SettingsValidation.historyChoice(enabled: historyEnabled, days: retentionDays) }, set: { choice in
            if choice < 0 { historyEnabled = false; return }
            historyEnabled = true
            retentionDays = choice
        })
    }

    private func clearHistory() {
        guard let history = Services.history else { return }
        guard Alerts.confirm("Are you sure you want to delete all files from history?",
                             info: "Screenshots and recordings you haven't saved elsewhere will be permanently deleted.",
                             confirmTitle: "Clear History", destructive: true) else { return }
        history.clear()
        HUD.show("History has been cleared", symbol: "trash")
    }

    private func restoreDefaults() {
        guard Alerts.confirm("Restore all settings to their defaults?",
                             info: "This can't be undone.", confirmTitle: "Restore Defaults", destructive: true) else { return }
        PreferencesReset.restoreAll()
        HUD.show("Settings restored to defaults", symbol: "arrow.counterclockwise")
    }
}

private struct URLSchemeDocs: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HelpText("Open these URLs with `open` in Terminal, a Shortcuts “Open URL” action or any launcher. Capture commands accept action=copy|save|annotate|upload|pin; area commands accept x, y, width, height (points from the bottom-left) and display (1 = main).")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(URLSchemeReference.commands, id: \.command) { item in
                    GridRow {
                        Text(item.command).font(.callout.monospaced()).textSelection(.enabled)
                        Text(item.summary).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Examples").font(.callout.bold()).padding(.top, 4)
            ForEach(URLSchemeReference.examples, id: \.self) { example in
                HStack {
                    Text(example).font(.callout.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button { Clipboard.copy(text: example); HUD.show("Copied", symbol: "doc.on.doc") } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless).help("Copy")
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct OCRLanguagesSheet: View {
    @Binding var selection: [String]
    let available: [(code: String, name: String)]
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recognition Languages").font(.title3.bold())
            HelpText("Text is recognized in these languages, in order of preference. At least one is required.")
            if available.isEmpty {
                Text("The list of languages isn't available right now.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                List {
                    ForEach(available, id: \.code) { language in
                        Toggle(isOn: Binding(get: { selection.contains(language.code) }, set: {
                            selection = OCRLanguageSelection.toggling(language.code, on: $0, in: selection,
                                                                      available: available.map(\.code))
                        })) {
                            HStack {
                                Text(language.name)
                                Spacer()
                                Text(language.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(height: 300)
            }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onExitCommand(perform: done)
    }
}
