import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var devices: [DeviceSummary] = []
    @Published private(set) var recentLogs: [LogEntry] = []
    /// deviceId -> parking lot name (#108). Empty until the device master is read.
    @Published private(set) var deviceNames = DeviceNames()
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let logsService: CloudWatchLogsService
    private let masterService: DeviceMasterService

    // Reset-timestamp cache (see #77): `fetchResetTimestamps` scans 400 days
    // of logs and accounted for ~90% of this app's CloudWatch Logs Insights
    // volume when it ran on every poll. It's only re-run on app start,
    // manual pull-to-refresh, or when a device's bootCount just dropped —
    // the only time the cached value can actually be stale.
    private var resetTimestampCache: [String: Date] = [:]
    private var lastKnownBootCount: [String: Int] = [:]
    private var hasFetchedResetTimestamps = false

    init(auth: CognitoAuthService) {
        self.logsService = CloudWatchLogsService(auth: auth)
        self.masterService = DeviceMasterService(auth: auth)
    }

    /// - Parameter forceResetRefresh: true on app start / foreground resume
    ///   and on manual pull-to-refresh. Otherwise (periodic auto-refresh)
    ///   the expensive reset-time lookup only re-runs if a device's
    ///   bootCount dropped since the last check (i.e. it actually reset) or
    ///   a never-before-seen device showed up.
    func load(forceResetRefresh: Bool = false) async {
        isLoading = true
        errorMessage = nil
        do {
            async let statusesTask = logsService.fetchDeviceStatuses()
            async let recentTask = logsService.fetchRecentLogs(limit: 5)
            // Manual / start-up refreshes re-read the master; periodic ones reuse the cache.
            async let namesTask = masterService.names(maxAge: forceResetRefresh ? 0 : AWSConfig.deviceNamesCacheTTL)
            let (statuses, recent) = try await (statusesTask, recentTask)
            self.recentLogs = recent
            self.deviceNames = await namesTask

            let needsResetRefresh = forceResetRefresh
                || !hasFetchedResetTimestamps
                || statuses.contains { status in
                    guard resetTimestampCache[status.deviceId] != nil else { return true }
                    guard let bootCount = status.bootCount, let previous = lastKnownBootCount[status.deviceId] else { return false }
                    return bootCount < previous
                }

            if needsResetRefresh {
                resetTimestampCache = try await logsService.fetchResetTimestamps()
                hasFetchedResetTimestamps = true
            }

            for status in statuses {
                if let bootCount = status.bootCount {
                    lastKnownBootCount[status.deviceId] = bootCount
                }
            }

            self.devices = statuses.map { status in
                let bootStatus = status.bootCount.map { bootCount in
                    BootStatusInfo(
                        bootCount: bootCount,
                        sessionStartedAt: resetTimestampCache[status.deviceId],
                        latestTimestamp: status.lastSeen
                    )
                }
                return DeviceSummary(
                    deviceId: status.deviceId,
                    name: deviceNames.name(for: status.deviceId),
                    status: status.status,
                    lastSeen: status.lastSeen,
                    bootStatus: bootStatus,
                    transport: status.transport
                )
            }

            await DeviceStateStore.detectChangesAndNotify(devices: devices)
        } catch {
            if !isCancellationError(error) {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }
}
