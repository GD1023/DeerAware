import SwiftUI

@main
struct DeerAwareApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            MapScreen()
                .environment(appModel)
        }
    }
}
