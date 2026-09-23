import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var devices: [DeviceSummary] = []
    @Published private(set) var recentLogs: [LogEntry] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let logsService: CloudWatchLogsService

    init(auth: CognitoAuthService) {
        self.logsService = CloudWatchLogsService(auth: auth)
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            async let devicesTask = logsService.fetchDeviceSummaries()
            async let recentTask = logsService.fetchRecentLogs(limit: 5)
            let (devices, recent) = try await (devicesTask, recentTask)
            self.devices = devices
            self.recentLogs = recent
            await DeviceStateStore.detectChangesAndNotify(devices: devices)
        } catch {
            if !isCancellationError(error) {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }
}
