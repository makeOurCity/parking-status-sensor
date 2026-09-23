import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: CognitoAuthService

    var body: some View {
        Group {
            if auth.isBootstrapping {
                ProgressView("読み込み中…")
            } else if auth.isSignedIn {
                DashboardView(auth: auth)
            } else {
                SignInView()
            }
        }
        .task {
            await auth.bootstrap()
        }
    }
}
