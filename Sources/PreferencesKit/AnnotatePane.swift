import SwiftUI
import ShotcraftCore

struct AnnotatePane: View {
    @Default(.annotateAlwaysOnTop) private var alwaysOnTop
    @Default(.annotateShowDockIcon) private var showDockIcon
    @Default(.annotateSmoothDrawing) private var smoothDrawing
    @Default(.annotateShowColorNames) private var showColorNames
    @Default(.annotateDrawShadow) private var drawShadow
    @Default(.annotateExpandCanvas) private var expandCanvas
    @Default(.annotateInverseArrow) private var inverseArrow
    @Default(.annotateRememberBackgroundTool) private var rememberBackground
    @Default(.annotateSaveBehavior) private var saveBehavior
    @Default(.annotateSnapCrop) private var snapCrop

    var body: some View {
        PaneForm(pane: .annotate) {
            Section("Tools") {
                SettingToggle("Inverse arrow direction", isOn: $inverseArrow,
                              help: "New arrows point back to where you started drawing.")
                SettingToggle("Smooth drawing", isOn: $smoothDrawing, help: "Smooths freehand pencil and highlighter strokes.")
                SettingToggle("Remember if background tool was opened", isOn: $rememberBackground)
                SettingToggle("Draw shadow on objects", isOn: $drawShadow)
                SettingToggle("Automatically expand canvas", isOn: $expandCanvas,
                              help: "Ensures all annotations fit by dynamically resizing canvas.")
                SettingToggle("Snap crop to content edges", isOn: $snapCrop)
            }

            Section("Window") {
                SettingToggle("Always on top", isOn: $alwaysOnTop)
                SettingToggle("Show Dock icon", isOn: $showDockIcon,
                              help: "Makes the editor reachable from the Dock and ⌘-Tab.")
                Picker("Save button behavior", selection: $saveBehavior) {
                    ForEach(SaveButtonBehavior.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }

            Section("Accessibility") {
                SettingToggle("Show color names", isOn: $showColorNames)
            }
        }
    }
}
