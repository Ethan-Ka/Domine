import SwiftUI

/// Settings > General > Display group: how the level meters look.
struct DisplaySettingsSection: View {
    @Binding var state: GeneralSettingsState

    var body: some View {
        LabeledContent("Display:") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Show meters", isOn: $state.showMeters)
                Toggle("Peak hold", isOn: $state.meterPeakHold)
                    .disabled(!state.showMeters)
                Picker("Meter style:", selection: $state.meterStyle) {
                    ForEach(MeterStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                .disabled(!state.showMeters)
                .fixedSize()
            }
        }
    }
}
