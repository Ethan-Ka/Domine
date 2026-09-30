import SwiftUI

/// Trailing toolbar items: Stereo / Quad, swap, and the on/off switch.
struct MainToolbarControls: View {
    var state: MainWindowState
    var actions: MainWindowActions

    var body: some View {
        ModePicker(
            selection: state.mode,
            isQuadEnabled: state.isQuadAvailable,
            onChange: actions.setMode)
            .accessibilityLabel("Mode")

        Button(action: actions.swap) {
            Image(systemName: "arrow.left.arrow.right")
        }
        .disabled(!state.canSwap)
        .help("Swap left and right")
        .accessibilityLabel("Swap left and right")

        Toggle("Domine output", isOn: Binding(
            get: { state.isOn },
            set: { actions.setOn($0) }))
            .toggleStyle(.switch)
            .labelsHidden()
            .help(state.isOn ? "Turn Domine off" : "Turn Domine on")
    }
}
