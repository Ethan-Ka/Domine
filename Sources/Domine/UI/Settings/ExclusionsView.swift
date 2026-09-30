import SwiftUI

/// Settings > Exclusions (docs/mockups/SettingsExclusions.dc.html).
struct ExclusionsView: View {
    @Binding var state: ExclusionsState
    var actions = ExclusionsActions()

    @State private var selection = Set<String>()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Excluded apps play through:", selection: $state.playThroughDeviceUID) {
                Text("Previous output").tag(String?.none)
                ForEach(state.outputChoices) { choice in
                    Text(choice.label).tag(Optional(choice.uid))
                }
            }
            .fixedSize()

            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach($state.items) { $item in
                        ExclusionRow(item: $item)
                    }
                }
                .listStyle(.bordered)
                .alternatingRowBackgrounds(.disabled)

                ExclusionsAddRemoveBar(
                    suggestions: state.availableSuggestions,
                    canRemove: !selection.isEmpty,
                    add: { state.add($0) },
                    chooseApp: actions.chooseApp,
                    remove: {
                        state.remove(bundleIDs: selection)
                        selection.removeAll()
                    }
                )
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
        .frame(width: 560, height: 320, alignment: .top)
    }
}

#if DEBUG
#Preview("Exclusions") {
    @Previewable @State var state = ExclusionsState.sample
    ExclusionsView(state: $state)
}
#endif
