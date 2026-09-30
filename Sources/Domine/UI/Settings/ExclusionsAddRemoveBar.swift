import SwiftUI

/// The +/- strip under the exclusions list, like the ones in System Settings.
/// "+" offers the suggested call apps first, then any app via `chooseApp`.
struct ExclusionsAddRemoveBar: View {
    let suggestions: [ExclusionItem]
    let canRemove: Bool
    let add: (ExclusionItem) -> Void
    let chooseApp: @MainActor () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(suggestions) { suggestion in
                    Button(suggestion.appName) { add(suggestion) }
                }
                if !suggestions.isEmpty {
                    Divider()
                }
                Button("Other…") { chooseApp() }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Add app")

            Divider().frame(height: 16)

            Button(action: remove) {
                Image(systemName: "minus")
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!canRemove)
            .accessibilityLabel("Remove app")

            Divider().frame(height: 16)
            Spacer()
        }
        .padding(.horizontal, 2)
        .frame(height: 22)
        .background(.background.secondary)
        .overlay(alignment: .top) { Divider() }
        .border(Color(nsColor: .separatorColor))
    }
}
