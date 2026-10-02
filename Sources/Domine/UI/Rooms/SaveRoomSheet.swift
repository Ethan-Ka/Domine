import SwiftUI

/// Names the current setup and saves it as a room.
struct SaveRoomSheet: View {
    var save: @MainActor (String) -> Void
    var cancel: @MainActor () -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Current Setup")
                .font(.headline)
            TextField("Name", text: $name)
                .onSubmit(commit)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .frame(width: 320)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func commit() {
        if !trimmed.isEmpty { save(trimmed) }
    }
}

#Preview {
    SaveRoomSheet(save: { _ in }, cancel: {})
}
