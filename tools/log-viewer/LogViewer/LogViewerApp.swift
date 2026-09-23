import SwiftUI
import UserNotifications

@main
struct LogViewerApp: App {
    @StateObject private var auth: CognitoAuthService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let authService = CognitoAuthService()
        _auth = StateObject(wrappedValue: authService)

        BackgroundRefreshScheduler.shared.configure(auth: authService)
        BackgroundRefreshScheduler.shared.registerTask()
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                BackgroundRefreshScheduler.shared.scheduleNextRefresh()
            }
        }
    }
}
