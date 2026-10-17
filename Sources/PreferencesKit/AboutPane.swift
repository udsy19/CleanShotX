import AppKit
import SwiftUI
import SuperScreenshotCore

struct AboutPane: View {
    @Default(.lastUpdateCheck) private var lastUpdateCheck
    private var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    private var name: String { (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String ?? "Super Screenshot" }
    private var version: String {
        let short = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String
        return build.map { $0 == short ? "Version \(short)" : "Version \(short) (\($0))" } ?? "Version \(short)"
    }

    /// "Today at 10:42", "Yesterday at 18:05", "12 Oct 2026 at 09:30".
    private var lastCheckedText: String {
        guard let lastUpdateCheck else { return "Never" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: lastUpdateCheck)
    }

    var body: some View {
        PaneForm(pane: .about) {
            Section {
                VStack(spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable().frame(width: 96, height: 96)
                    Text(name).font(.title.bold())
                    Text(version).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Screenshots, screen recordings, annotation, OCR and sharing — from your menu bar.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section("Credits") {
                Text("\(name) is an independent reimplementation of the CleanShot X feature set, built from scratch with Apple frameworks only. It is not affiliated with, endorsed by, or connected to CleanShot X or MTW.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Icons are SF Symbols; sounds are macOS system sounds.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Last checked for updates") { Text(lastCheckedText) }
                LabeledContent("Bundle identifier") { Text(AppPaths.bundleID).textSelection(.enabled) }
                LabeledContent("Data folder") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.support]) }
                }
                LabeledContent("Welcome guide") {
                    Button("Show Onboarding…") { Services.preferences?.showOnboarding() }
                }
            }
        }
    }
}
