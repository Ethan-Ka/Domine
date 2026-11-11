import SwiftUI

/// Settings > General > "Menu bar shows". Reads the model from the
/// environment; without one (previews, render tests) it shows the default.
struct MenuBarSettingsSection: View {
    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        Picker("Menu bar shows:", selection: selection) {
            ForEach(MenuBarContent.allCases) { content in
                Text(content.title).tag(content)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(model == nil)
    }

    private var selection: Binding<MenuBarContent> {
        Binding(
            get: { model?.menuBarShows ?? .iconOnly },
            set: { model?.menuBarShows = $0 })
    }
}

#if DEBUG
#Preview {
    Form { MenuBarSettingsSection() }
        .formStyle(.columns)
        .padding()
}
#endif
