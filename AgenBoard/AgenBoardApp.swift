import SwiftUI

@main
struct AgenBoardApp: App {
    init() {
        RecordingLaunchMetrics.mark("main_app_initialized")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
