import SwiftUI

@main
struct DomineApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Domine", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 480)
                .task { model.start() }
        }
        .windowResizability(.contentSize)
    }
}
