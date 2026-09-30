import SwiftUI

/// Choose the device for one position (docs/mockups/Assign.dc.html).
struct AssignSheet: View {
    var state: AssignSheetState
    var actions: AssignSheetActions = .none

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.title)
                .font(.headline)
            if let note = state.note {
                Text(note)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            rowList
            if let footnote = state.footnote {
                Text(footnote)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: actions.cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Use This Speaker") {
                    if let uid = state.selectedUID { actions.confirm(uid) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.selectedUID == nil)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .frame(width: 440)
    }

    private var rowList: some View {
        VStack(spacing: 0) {
            ForEach(state.rows) { row in
                AssignRowView(row: row, actions: actions)
                if row.id != state.rows.last?.id {
                    Divider()
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Outputs")
    }
}

private struct AssignRowView: View {
    var row: AssignRow
    var actions: AssignSheetActions

    var body: some View {
        HStack(spacing: 10) {
            RadioButton(
                isOn: row.isSelected,
                accessibilityTitle: "\(row.name) \(row.suffix)",
                action: { actions.select(row.uid) })
            VStack(alignment: .leading, spacing: 2) {
                DeviceNameLabel(name: row.name, suffix: row.suffix)
                HStack(spacing: 8) {
                    ForEach(Array(row.details.enumerated()), id: \.offset) { _, detail in
                        Text(detail)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            Button("Play tone") { actions.playTone(row.uid) }
                .disabled(!row.canPlayTone)
                .accessibilityLabel("Play tone on \(row.name) \(row.suffix)")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(row.isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { actions.select(row.uid) }
    }
}

#Preview("Selected") {
    AssignSheet(state: SampleStates.assign)
}

#Preview("No selection") {
    var state = SampleStates.assign
    state.rows = state.rows.map { row in
        var row = row
        row.isSelected = false
        return row
    }
    return AssignSheet(state: state)
}
