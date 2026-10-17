import AppKit
import SwiftUI
import SuperScreenshotCore

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
    @Default(.selfTimerSeconds) private var selfTimerSeconds
    @Default(.captureWindowShadow) private var windowShadow
    @Default(.windowBackgroundStyle) private var backgroundStyle
    @Default(.windowBackgroundPadding) private var backgroundPadding

    private static let timerChoices = [3, 5, 10]

    var body: some View {
        PaneForm(pane: .screenshots) {
            Section("Output") {
                Picker("File format", selection: $format) {
                    ForEach(ImageFormat.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if format == .jpeg || format == .heic {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: $jpegQuality.snapped(to: 0.05), in: 0.3...1.0) { Text("Quality") }
                                .labelsHidden().frame(maxWidth: 220)
                            Text("\(Int((jpegQuality * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }

            Section {
                SettingToggle("Convert to sRGB profile", isOn: $convertToSRGB,
                              help: "Gives consistent colors in browsers and apps that ignore display profiles.")
                SettingToggle("Scale Retina screenshots to 1x", isOn: $scaleRetina,
                              help: "Saves screenshots at their point size, producing smaller files.")
                SettingToggle("Add 1px border to all screenshots", isOn: $addBorder)
            }

            Section("Capture") {
                Picker("Self-Timer interval", selection: $selfTimerSeconds) {
                    ForEach(PickerChoices.including(selfTimerSeconds, in: Self.timerChoices), id: \.self) {
                        Text("\($0) Seconds").tag($0)
                    }
                }
                SettingToggle("Show cursor on screenshots", isOn: $showCursor,
                              help: "This works in Fullscreen or Self-Timer modes only.")
                SettingToggle("Freeze screen when taking a screenshot", isOn: $freezeScreen)
            }

            Section {
                LabeledContent {
                    HStack(spacing: 12) {
                        BackgroundTile(title: "With wallpaper", selected: backgroundStyle != .transparent) {
                            WindowBackgroundMapping.applyWallpaper()
                        } preview: { WindowBackgroundSample(transparent: false) }
                        BackgroundTile(title: "Transparent", selected: backgroundStyle == .transparent) {
                            backgroundStyle = .transparent
                        } preview: { WindowBackgroundSample(transparent: true) }
                    }
                } label: {
                    Text("Background")
                    Text("Hold ⇧ Shift while taking a screenshot to switch between the two. You can customize the wallpaper in [wallpaper settings](settings://wallpaper).")
                }
                LabeledContent("Padding") {
                    HStack {
                        Slider(value: $backgroundPadding.snapped(to: 4), in: 0...160) { Text("Padding") }
                            .labelsHidden().frame(maxWidth: 200)
                        Text("\(Int(backgroundPadding)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(backgroundStyle == .transparent)
                SettingToggle("Capture window shadow", isOn: $windowShadow)
            } header: { Text("Window Screenshots") } footer: {
                HStack {
                    Spacer()
                    Button("Reset Defaults") {
                        Defaults.reset(.windowBackgroundStyle)
                        Defaults.reset(.windowBackgroundColor)
                        Defaults.reset(.windowBackgroundPadding)
                        Defaults.reset(.captureWindowShadow)
                    }
                }
            }

            Section("Crosshair") {
                Picker("Crosshair Mode", selection: crosshairBinding) {
                    Text("Disabled").tag(false)
                    Text("Enabled").tag(true)
                }
                Toggle(isOn: $magnifier) {
                    Text("Show magnifier")
                    if !crosshair { Text("To enable magnifier, you must enable Crosshair Mode first.") }
                }
                .accessibilityLabel("Show magnifier")
                .disabled(!crosshair)
            }
        }
    }

    /// Turning crosshair mode off also turns the magnifier off (it depends on it).
    private var crosshairBinding: Binding<Bool> {
        Binding(get: { crosshair }, set: { on in
            crosshair = on
            if !on { magnifier = false }
        })
    }
}

/// Selectable image tile ("With wallpaper" / "Transparent") with a 2 pt accent ring when selected.
private struct BackgroundTile<Preview: View>: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var preview: Preview

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                preview
                    .frame(width: 96, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2 : 1)
                    )
                Text(title).font(.callout).foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A tiny window drawn over a wallpaper gradient or a transparency checkerboard.
private struct WindowBackgroundSample: View {
    let transparent: Bool

    var body: some View {
        ZStack {
            if transparent {
                Checkerboard()
            } else {
                LinearGradient(colors: [Color(red: 0.36, green: 0.55, blue: 0.98), Color(red: 0.72, green: 0.42, blue: 0.95)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: .top) {
                    HStack(spacing: 2) {
                        ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 4, height: 4) }
                        Spacer()
                    }
                    .padding(4)
                }
                .padding(transparent ? 6 : 12)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        }
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let cell: CGFloat = 6
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for row in 0..<Int(size.height / cell) + 1 {
                for col in 0..<Int(size.width / cell) + 1 where (row + col).isMultiple(of: 2) {
                    ctx.fill(Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                             with: .color(Color(white: 0.85)))
                }
            }
        }
    }
}
