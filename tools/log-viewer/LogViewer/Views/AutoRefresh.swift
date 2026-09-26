import SwiftUI

extension View {
    /// Loads data immediately and then repeats every `AWSConfig.autoRefreshInterval`
    /// while the app is in the foreground — so pull-to-refresh is rarely needed.
    ///
    /// Keyed off `scenePhase` via `.task(id:)`: SwiftUI cancels and restarts the
    /// task whenever `scenePhase` changes, which gives us both behaviors for
    /// free — backgrounding stops the loop (the new task's guard fails), and
    /// foregrounding starts a fresh one that loads right away.
    ///
    /// `action` receives `isInitial: true` only for that first call (app
    /// startup / foreground resume), `false` for every periodic repeat —
    /// `DashboardViewModel` uses this to decide whether to re-run its
    /// expensive reset-time lookup (see #77).
    func autoRefreshing(scenePhase: ScenePhase, action: @escaping (_ isInitial: Bool) async -> Void) -> some View {
        task(id: scenePhase) {
            guard scenePhase == .active else { return }
            var isInitial = true
            while !Task.isCancelled {
                await action(isInitial)
                isInitial = false
                try? await Task.sleep(for: .seconds(AWSConfig.autoRefreshInterval))
            }
        }
    }
}
