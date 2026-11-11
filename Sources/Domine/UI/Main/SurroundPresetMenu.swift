import SwiftUI

/// The "Preset" menu in the Surround controls: built-in and saved field
/// presets, "Save Preset…", and rename and delete for the saved ones.
struct SurroundPresetMenu: View {
    @Environment(AppModel.self) private var model: AppModel?

    private enum Prompt: Identifiable {
        case save
        case rename(String)
        var id: String {
            switch self {
            case .save: "save"
            case .rename(let name): "rename:" + name
            }
        }
    }

    @State private var prompt: Prompt?
    @State private var name = ""

    var body: some View {
        if let model {
            let current = model.currentSurroundPresetName
            Menu(current ?? "No Preset") {
                Section {
                    Toggle("No Preset", isOn: Binding(
                        get: { current == nil },
                        set: { _ in model.clearSurroundFieldPreset() }))
                        .disabled(current == nil || !model.canClearSurroundFieldPreset)
                }
                Section {
                    ForEach(SurroundFieldPreset.builtIn) { preset in
                        item(preset, current: current, model: model)
                    }
                }
                if !model.surroundFieldPresets.isEmpty {
                    Section {
                        ForEach(model.surroundFieldPresets) { preset in
                            item(preset, current: current, model: model)
                        }
                    }
                }
                Section {
                    Button("Save Preset…") { present(.save, text: "") }
                    if !model.surroundFieldPresets.isEmpty {
                        Menu("Rename") {
                            ForEach(model.surroundFieldPresets) { preset in
                                Button(preset.name) { present(.rename(preset.name), text: preset.name) }
                            }
                        }
                        Menu("Delete") {
                            ForEach(model.surroundFieldPresets) { preset in
                                Button(preset.name) { model.deleteSurroundFieldPreset(preset.name) }
                            }
                        }
                    }
                }
            }
            .fixedSize()
            .help("Surround preset")
            .accessibilityLabel("Surround preset")
            .accessibilityValue(current ?? "No Preset")
            .sheet(item: $prompt) { prompt in
                SurroundPresetNameSheet(
                    title: title(prompt), name: $name,
                    done: { commit(prompt, model: model) },
                    cancel: { self.prompt = nil })
            }
        }
    }

    private func item(_ preset: SurroundFieldPreset, current: String?, model: AppModel) -> some View {
        Toggle(preset.name, isOn: Binding(
            get: { current == preset.name },
            set: { _ in model.applySurroundFieldPreset(preset) }))
    }

    private func present(_ prompt: Prompt, text: String) {
        name = text
        self.prompt = prompt
    }

    private func title(_ prompt: Prompt) -> String {
        switch prompt {
        case .save: "Save Preset"
        case .rename: "Rename Preset"
        }
    }

    private func commit(_ prompt: Prompt, model: AppModel) {
        switch prompt {
        case .save: model.saveSurroundFieldPreset(name: name)
        case .rename(let old): model.renameSurroundFieldPreset(old, to: name)
        }
        self.prompt = nil
    }
}

private struct SurroundPresetNameSheet: View {
    var title: String
    @Binding var name: String
    var done: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Name", text: $name)
                .frame(width: 240)
                .onSubmit(done)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Save", action: done)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }
}
