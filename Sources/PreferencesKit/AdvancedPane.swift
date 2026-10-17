import AppKit
import SwiftUI
import ShotcraftCore

struct AdvancedPane: View {
    @Default(.ocrKeepLineBreaks) private var keepLineBreaks
    @Default(.ocrLanguageMode) private var languageMode
    @Default(.ocrLanguages) private var languages
    @Default(.ocrOpenLinks) private var openLinks
    @Default(.historyEnabled) private var historyEnabled
    @Default(.historyRetentionDays) private var retentionDays
    @Default(.pinLockAndHideOnHover) private var pinLockAndHide
    @Default(.pinShowShadow) private var pinShadow
    @Default(.allowURLSchemeAPI) private var allowURLScheme
    @Default(.suppressedWarnings) private var suppressedWarnings
    @State private var showingLanguages = false
    @State private var showingURLDocs = false

    private static let retentionChoices = [1, 3, 7, 14, 30, 90, 0]

    var body: some View {
        PaneForm(pane: .advanced) {
            Section("Text recognition") {
                Toggle("Keep line breaks", isOn: $keepLineBreaks)
                Toggle(isOn: $openLinks) {
                    Text("Open detected links")
                    Text("When the recognized text is a single link, open it in your browser.")
                }
                Toggle("Automatically Detect Language", isOn: autoDetectBinding)
                if languageMode == .manual {
                    LabeledContent {
                        Button("Choose…") { showingLanguages = true }
                    } label: {
                        Text("Languages")
                        Text(languages.map(OCRLanguageCatalog.displayName).joined(separator: ", "))
                    }
                }
            }

            Section {
                Toggle("Save captures to history", isOn: $historyEnabled)
                Picker("Keep captures for", selection: $retentionDays) {
                    ForEach(retentionChoices, id: \.self) { d in
                        Text(d == 0 ? "Forever" : d == 1 ? "1 day" : "\(d) days").tag(d)
                    }
                }
                .disabled(!historyEnabled)
                LabeledContent("Captured files") {
                    Button("Clear History…", role: .destructive) { clearHistory() }
                        .disabled(Services.history == nil)
                }
            } header: { Text("Capture History") } footer: {
                if !historyEnabled { HelpText("Capture History is disabled.") }
            }

            Section("Pinned screenshots") {
                Toggle("Lock and hide screenshot on mouse over", isOn: $pinLockAndHide)
                Toggle("Show shadow", isOn: $pinShadow)
            }

            Section {
                Toggle(isOn: $allowURLScheme) {
                    Text("Allow URL scheme API")
                    Text("Lets other apps and scripts (Shortcuts, Raycast, Alfred) control Shotcraft with shotcraft:// links. When off, you're asked the first time an app tries.")
                }
                DisclosureGroup("Commands", isExpanded: $showingURLDocs) {
                    URLSchemeDocs()
                }
            } header: { Text("Automation") }

            Section("Reset") {
                LabeledContent {
                    Button("Reset All Warning Dialogs") {
                        suppressedWarnings = []
                        HUD.show("All warning dialogs are now enabled.")
                    }
                } label: {
                    Text("Warning dialogs")
                    Text(suppressedWarnings.isEmpty ? "No dialogs are hidden." : "\(suppressedWarnings.count) hidden with “Don't ask again”.")
                }
                LabeledContent {
                    Button("Restore Defaults…", role: .destructive) { restoreDefaults() }
                } label: {
                    Text("All settings")
                    Text("Shortcuts and every preference return to their original values. Upload secrets stay in the Keychain.")
                }
            }
        }
        .sheet(isPresented: $showingLanguages) {
            OCRLanguagesSheet(selection: $languages) { showingLanguages = false }
        }
    }

    private var retentionChoices: [Int] {
        Self.retentionChoices.contains(retentionDays) ? Self.retentionChoices : Self.retentionChoices + [retentionDays]
    }

    private var autoDetectBinding: Binding<Bool> {
        Binding(get: { languageMode == .automatic }, set: { languageMode = $0 ? .automatic : .manual })
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
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recognition Languages").font(.title3.bold())
            HelpText("Text is recognized in these languages, in order of preference. At least one is required.")
            List {
                ForEach(OCRLanguageCatalog.codes, id: \.self) { code in
                    Toggle(isOn: Binding(get: { selection.contains(code) },
                                         set: { selection = OCRLanguageCatalog.toggling(code, on: $0, in: selection) })) {
                        HStack {
                            Text(OCRLanguageCatalog.displayName(code))
                            Spacer()
                            Text(code).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(height: 300)
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
