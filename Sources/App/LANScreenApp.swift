import SwiftUI

@main
struct LANScreenApp: App {
    @StateObject private var coordinator = AppCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeView(coordinator: coordinator)
                .preferredColorScheme(.dark)
                .onAppear {
                    coordinator.onAppLaunch()
                }
                .onChange(of: scenePhase) { newPhase in
                    coordinator.handleScenePhase(newPhase)
                }
        }
    }
}
