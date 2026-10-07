import BackgroundTasks
import Foundation

/// Wires up iOS's BackgroundTasks framework so the dashboard keeps checking
/// for device status changes even when the app isn't in the foreground, and
/// posts a local notification when something changed.
///
/// Important limitation: `BGAppRefreshTask` timing is opportunistic — iOS
/// decides when to actually wake the app based on usage patterns, battery,
/// and Low Power Mode, so the real gap between checks can range from minutes
/// to several hours. `AWSConfig.backgroundRefreshMinimumInterval` is only the
/// *earliest* the OS may run it, not a guarantee. There is no way to get a
/// tighter, reliable interval without a server pushing changes via APNs —
/// this app has no such server component (see docs/ios-app-cognito.md).
final class BackgroundRefreshScheduler {
    static let shared = BackgroundRefreshScheduler()

    private var auth: CognitoAuthService?

    private init() {}

    func configure(auth: CognitoAuthService) {
        self.auth = auth
    }

    /// Must run before the app finishes launching (call from the App
    /// struct's `init()`), per BGTaskScheduler's requirements.
    func registerTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: AWSConfig.backgroundRefreshTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let appRefreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self?.handle(task: appRefreshTask)
        }
    }

    /// Asks iOS to wake the app again no earlier than
    /// `AWSConfig.backgroundRefreshMinimumInterval` from now. Call whenever
    /// the app backgrounds, and again after each background execution so the
    /// chain continues.
    func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: AWSConfig.backgroundRefreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: AWSConfig.backgroundRefreshMinimumInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Common in the Simulator (unsupported there) or if a request is
            // already pending — not fatal, the next background/foreground
            // transition tries again.
            print("BackgroundRefreshScheduler: could not schedule refresh: \(error)")
        }
    }

    private func handle(task: BGAppRefreshTask) {
        // Keep the chain going regardless of whether this run succeeds.
        scheduleNextRefresh()

        guard let auth else {
            task.setTaskCompleted(success: false)
            return
        }

        let refreshTask = Task {
            do {
                let service = CloudWatchLogsService(auth: auth)
                // Status-only: change detection only needs status/lastSeen,
                // never the expensive 400-day reset-time lookup (#77).
                let statuses = try await service.fetchDeviceStatuses()
                // Names come from the cache when it's fresh (#108); a failure just
                // falls back to showing the deviceId in the notification.
                let names = await DeviceMasterService(auth: auth).names()
                let devices = statuses.map { status in
                    DeviceSummary(
                        deviceId: status.deviceId,
                        name: names.name(for: status.deviceId),
                        status: status.status,
                        lastSeen: status.lastSeen,
                        bootStatus: nil,
                        transport: status.transport
                    )
                }
                await DeviceStateStore.detectChangesAndNotify(devices: devices)
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            refreshTask.cancel()
        }
    }
}
