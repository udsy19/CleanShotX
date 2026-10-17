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
            Section("Window") {
                Toggle("Keep window always on top", isOn: $alwaysOnTop)
                SettingToggle("Show Dock icon while editing", isOn: $showDockIcon,
                              help: "Makes the editor reachable from the Dock and ⌘-Tab.")
                Picker("Save button", selection: $saveBehavior) {
                    ForEach(SaveButtonBehavior.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }

            Section("Drawing") {
                SettingToggle("Smooth drawing", isOn: $smoothDrawing, help: "Smooths freehand pencil and highlighter strokes.")
                Toggle("Draw shadow on objects", isOn: $drawShadow)
                Toggle("Inverse arrow direction", isOn: $inverseArrow)
                Toggle("Show color names", isOn: $showColorNames)
            }

            Section("Canvas") {
                SettingToggle("Expand canvas automatically", isOn: $expandCanvas,
                              help: "Grows the canvas when you draw or drop objects outside the image.")
                Toggle("Snap crop to content edges", isOn: $snapCrop)
                Toggle("Remember background tool state", isOn: $rememberBackground)
            }
        }
    }
}
