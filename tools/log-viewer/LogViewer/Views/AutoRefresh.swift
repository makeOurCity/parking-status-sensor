import SwiftUI

extension View {
    /// Loads data immediately and then repeats every `AWSConfig.autoRefreshInterval`
    /// while the app is in the foreground — so pull-to-refresh is rarely needed.
    ///
    /// Keyed off `scenePhase` via `.task(id:)`: SwiftUI cancels and restarts the
    /// task whenever `scenePhase` changes, which gives us both behaviors for
    /// free — backgrounding stops the loop (the new task's guard fails), and
    /// foregrounding starts a fresh one that loads right away.
    func autoRefreshing(scenePhase: ScenePhase, action: @escaping () async -> Void) -> some View {
        task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await action()
                try? await Task.sleep(for: .seconds(AWSConfig.autoRefreshInterval))
            }
        }
    }
}
