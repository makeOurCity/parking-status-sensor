import SwiftUI

@main
struct LogViewerApp: App {
    @StateObject private var auth = CognitoAuthService()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
        }
    }
}
