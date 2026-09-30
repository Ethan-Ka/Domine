import SwiftUI

/// M3 temporary controls: speaker pickers, on/off, swap, test tones, and
/// the engine status. Replaced by the stage from docs/mockups/Main.dc.html in M5.
struct EngineControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        @Bindable var engine = model.engine
        let outputs = model.catalog.outputs
        let running = engine.state == .running

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                SpeakerPicker(title: "Left", selection: $model.leftUID, outputs: outputs)
                SpeakerPicker(title: "Right", selection: $model.rightUID, outputs: outputs)
            }
            .disabled(engine.state != .idle && !isError(engine.state))

            HStack(spacing: 12) {
                Toggle("On", isOn: Binding(
                    get: { engine.state.isActive },
                    set: { model.setRouting($0) }))
                    .toggleStyle(.switch)
                Toggle("Swap", isOn: $engine.swapSides)
                    .toggleStyle(.button)
                Toggle("Test L", isOn: toneBinding(.left))
                    .toggleStyle(.button)
                    .disabled(!running)
                Toggle("Test R", isOn: toneBinding(.right))
                    .toggleStyle(.button)
                    .disabled(!running)
                Spacer()
            }

            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func toneBinding(_ tone: TestTone) -> Binding<Bool> {
        let engine = model.engine
        return Binding(
            get: { engine.testTone == tone },
            set: { engine.testTone = $0 ? tone : .off })
    }

    private func isError(_ state: EngineState) -> Bool {
        if case .error = state { true } else { false }
    }

    private var status: String {
        let engine = model.engine
        switch engine.state {
        case .idle: return engine.idleReason?.description ?? "Off"
        case .starting: return "Starting"
        case .running: return engine.swapSides ? "Playing · Stereo · Swapped" : "Playing · Stereo"
        case .stopping: return "Stopping"
        case .error(let message): return "Error: \(message)"
        }
    }
}

private struct SpeakerPicker: View {
    let title: String
    @Binding var selection: String?
    let outputs: [OutputDevice]

    var body: some View {
        Picker(title, selection: $selection) {
            Text("None").tag(String?.none)
            ForEach(outputs) { device in
                Text("\(device.name) · \(device.uidSuffix)").tag(Optional(device.uid))
            }
            if let selection, !outputs.contains(where: { $0.uid == selection }) {
                Text("Not connected · \(OutputDevice.suffix(forUID: selection))").tag(Optional(selection))
            }
        }
        .frame(maxWidth: 260)
    }
}
