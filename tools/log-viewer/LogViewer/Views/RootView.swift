import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: CognitoAuthService

    var body: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-timelineDemo") {
                // 認証なしで満空タイムラインの見た目を確認するための DEBUG 専用の入口。
                TimelineDemoView()
            } else {
                content
            }
            #else
            content
            #endif
        }
        .task {
            await auth.bootstrap()
        }
        .onChange(of: auth.isSignedIn) { _, isSignedIn in
            if isSignedIn {
                NotificationSender.requestAuthorizationIfNeeded()
                BackgroundRefreshScheduler.shared.scheduleNextRefresh()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if auth.isBootstrapping {
            ProgressView("読み込み中…")
        } else if auth.isSignedIn {
            DashboardView(auth: auth)
        } else {
            SignInView()
        }
    }
}
