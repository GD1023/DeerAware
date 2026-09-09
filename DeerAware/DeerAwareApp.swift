import SwiftUI

@main
struct DeerAwareApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            TabView(selection: Binding(
                get: { appModel.selectedTab },
                set: { appModel.selectedTab = $0 }
            )) {
                HomeView()
                    .tabItem { Label("Home", systemImage: "house") }
                    .tag(0)
                MapScreen()
                    .tabItem { Label("Map", systemImage: "map") }
                    .tag(1)
            }
            .environment(appModel)
        }
    }
}
