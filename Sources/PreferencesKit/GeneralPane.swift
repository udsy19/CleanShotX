import AppKit
import SwiftUI
import ShotcraftCore

struct GeneralPane: View {
    @Default(.launchAtLogin) private var launchAtLogin
    @Default(.playSounds) private var playSounds
    @Default(.captureSound) private var captureSound
    @Default(.showMenuBarIcon) private var showMenuBarIcon
    @Default(.exportLocation) private var exportLocation
    @Default(.clipboardContent) private var clipboardContent
    @Default(.hideDesktopIconsWhileCapturing) private var hideDesktopIcons

    var body: some View {
        PaneForm(pane: .general) {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                Toggle(isOn: menuBarIconBinding) {
                    Text("Show menu bar icon")
                    if !showMenuBarIcon { Text("Open Shotcraft again (e.g. from Finder or Spotlight) to show this window.") }
                }
            }

            Section("Sounds") {
                Toggle("Play sounds", isOn: $playSounds)
                LabeledContent("Capture sound") {
                    HStack {
                        Picker("Capture sound", selection: $captureSound) {
                            ForEach(CaptureSound.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button { Sound.play(.capture) } label: { Image(systemName: "play.circle") }
                            .buttonStyle(.borderless)
                            .help("Preview")
                            .disabled(captureSound == .none)
                    }
                }
                .disabled(!playSounds)
                .onChange(of: captureSound) { _, new in if new != .none { Sound.play(.capture) } }
            }

            Section {
                FolderRow(title: "Export location", path: $exportLocation)
            } footer: {
                HelpText("Screenshots and recordings are saved here when you choose Save.")
            }

            AfterCaptureSection(title: "After taking a screenshot", key: .afterScreenshotActions,
                                choices: AfterCaptureRules.screenshotChoices,
                                header: "Decide what should happen after taking a screenshot or recording a video.")
            AfterCaptureSection(title: "After recording a video", key: .afterRecordingActions,
                                choices: AfterCaptureRules.recordingChoices, header: nil)

            Section("Capture") {
                Picker(selection: $clipboardContent) {
                    ForEach(ClipboardContent.allCases, id: \.self) { Text($0.displayName).tag($0) }
                } label: {
                    Text("Copy to clipboard as")
                    Text("File & Image pastes into both Finder and image editors.")
                }
                Toggle("Hide desktop icons while capturing", isOn: $hideDesktopIcons)
            }

            PermissionsSection()
        }
    }

    /// Hiding the icon asks for confirmation first, since Settings is then only reachable by relaunching.
    private var menuBarIconBinding: Binding<Bool> {
        Binding(get: { showMenuBarIcon }, set: { show in
            if show { showMenuBarIcon = true; return }
            let ok = Alerts.confirm("The menu bar icon will be hidden.",
                                    info: "In order to show the Settings window again, launch Shotcraft twice.",
                                    confirmTitle: "Hide Icon", suppressionID: "prefs.hideMenuBarIcon")
            if ok { showMenuBarIcon = false }
        })
    }
}

/// Checkbox list of after-capture actions; refuses to leave the set empty.
struct AfterCaptureSection: View {
    let title: String
    let key: Defaults.Key<Set<AfterCaptureAction>>
    let choices: [AfterCaptureAction]
    let header: String?
    @Default private var actions: Set<AfterCaptureAction>

    init(title: String, key: Defaults.Key<Set<AfterCaptureAction>>, choices: [AfterCaptureAction], header: String?) {
        self.title = title; self.key = key; self.choices = choices; self.header = header
        _actions = Default(key)
    }

    var body: some View {
        Section {
            ForEach(choices, id: \.self) { action in
                Toggle(action.displayName, isOn: binding(for: action))
            }
        } header: {
            VStack(alignment: .leading, spacing: 4) {
                if let header { Text(header).font(.callout).foregroundStyle(.secondary).textCase(nil) }
                Text(title)
            }
        }
    }

    private func binding(for action: AfterCaptureAction) -> Binding<Bool> {
        Binding(get: { actions.contains(action) }, set: { on in
            if let next = AfterCaptureRules.toggling(action, on: on, in: actions) {
                actions = next
            } else {
                NSSound.beep()
                let a = NSAlert()
                a.messageText = AfterCaptureRules.atLeastOneTitle
                a.informativeText = AfterCaptureRules.atLeastOneMessage
                a.runModal()
            }
        })
    }
}
