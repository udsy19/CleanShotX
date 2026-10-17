import AppKit
import SwiftUI
import SuperScreenshotCore

struct GeneralPane: View {
    @Default(.launchAtLogin) private var launchAtLogin
    @Default(.playSounds) private var playSounds
    @Default(.captureSound) private var captureSound
    @Default(.showMenuBarIcon) private var showMenuBarIcon
    @Default(.exportLocation) private var exportLocation
    @Default(.hideDesktopIconsWhileCapturing) private var hideDesktopIcons
    /// Bumped when a confirmation is cancelled, so the switch snaps back to the stored value.
    @State private var menuBarIconRevision = 0

    var body: some View {
        PaneForm(pane: .general) {
            Section("App") {
                SettingToggle("Launch at login", isOn: $launchAtLogin)
                Toggle(isOn: menuBarIconBinding) {
                    Text("Show menu bar icon")
                    if !showMenuBarIcon { Text("Open Super Screenshot again (e.g. from Finder or Spotlight) to show this window.") }
                }
                .accessibilityLabel("Show menu bar icon")
                .id(menuBarIconRevision)
            }

            Section {
                SettingToggle("Hide desktop icons while capturing", isOn: $hideDesktopIcons)
            } header: { Text("Capture") } footer: {
                HelpText("You can set a custom wallpaper to hide desktop icons in [wallpaper settings](settings://wallpaper).")
            }

            Section("Sounds") {
                SettingToggle("Play sounds", isOn: $playSounds)
                LabeledContent("Shutter sound") {
                    HStack(spacing: 6) {
                        Picker("Shutter sound", selection: shutterBinding) {
                            ForEach(CaptureSound.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button { Sound.play(.capture) } label: { Image(systemName: "speaker.wave.2") }
                            .buttonStyle(.borderless)
                            .help("Play shutter sound")
                            .disabled(captureSound == .none)
                    }
                }
                .disabled(!playSounds)
            }

            Section {
                FolderRow(title: "Export location", path: $exportLocation)
            } header: { Text("Export") } footer: {
                HelpText("Set the default save location used when saving from the Quick Access Overlay, After Capture, and other Save actions across the app.")
            }

            AfterCaptureTable()

            PermissionsSection()
        }
    }

    /// Picking a sound previews it (only on a user change, not when defaults are restored elsewhere).
    private var shutterBinding: Binding<CaptureSound> {
        Binding(get: { captureSound }, set: { new in
            captureSound = new
            if new != .none { Sound.play(.capture) }
        })
    }

    /// Hiding the icon asks for confirmation first, since Settings is then only reachable by relaunching.
    private var menuBarIconBinding: Binding<Bool> {
        Binding(get: { showMenuBarIcon }, set: { show in
            if show { showMenuBarIcon = true; return }
            let ok = Alerts.confirm("The menu bar icon will be hidden.",
                                    info: "In order to show the Settings window again, launch Super Screenshot twice.",
                                    confirmTitle: "Hide Icon", suppressionID: "prefs.hideMenuBarIcon")
            if ok { showMenuBarIcon = false } else { menuBarIconRevision += 1 }
        })
    }
}

/// "After Capture": Action | Screenshot | Recording checkbox table. Neither list may become empty.
private struct AfterCaptureTable: View {
    @Default(.afterScreenshotActions) private var screenshot
    @Default(.afterRecordingActions) private var recording
    /// Bumped when a change is refused, so the checkbox snaps back.
    @State private var revision = 0

    private static let columnWidth: CGFloat = 76

    var body: some View {
        Section {
            HStack {
                Text("Action")
                Spacer()
                Text("Screenshot").frame(width: Self.columnWidth)
                Text("Recording").frame(width: Self.columnWidth)
            }
            .font(.callout).foregroundStyle(.secondary)

            ForEach(AfterCaptureRules.tableRows, id: \.self) { action in
                HStack {
                    Text(AfterCaptureRules.title(for: action))
                    Spacer()
                    cell(action, in: $screenshot, applicable: AfterCaptureRules.screenshotChoices.contains(action),
                         kind: "screenshot")
                    cell(action, in: $recording, applicable: AfterCaptureRules.recordingChoices.contains(action),
                         kind: "recording")
                }
            }
            .id(revision)
        } header: {
            SectionHeader(title: "After Capture",
                          detail: "Decide what should happen after taking a screenshot or recording a video.")
        }
    }

    @ViewBuilder
    private func cell(_ action: AfterCaptureAction, in set: Binding<Set<AfterCaptureAction>>, applicable: Bool,
                      kind: String) -> some View {
        Group {
            if applicable {
                Toggle(isOn: binding(action, in: set)) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("\(AfterCaptureRules.title(for: action)) after \(kind)")
            } else {
                Text("—").foregroundStyle(.tertiary).accessibilityLabel("Not available")
            }
        }
        .frame(width: Self.columnWidth)
    }

    private func binding(_ action: AfterCaptureAction, in set: Binding<Set<AfterCaptureAction>>) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(action) }, set: { on in
            if let next = AfterCaptureRules.toggling(action, on: on, in: set.wrappedValue) {
                set.wrappedValue = next
            } else {
                revision += 1
                NSSound.beep()
                let a = NSAlert()
                a.messageText = AfterCaptureRules.atLeastOneTitle
                a.informativeText = AfterCaptureRules.atLeastOneMessage
                a.runModal()
            }
        })
    }
}
