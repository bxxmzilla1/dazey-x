import SwiftUI

@main
struct DazeyXApp: App {
    @StateObject private var auth = AuthManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .background(Color.black.ignoresSafeArea())
                .statusBarHidden(true)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await auth.revalidate() } }
                }
        }
    }
}
