import Foundation

@MainActor
final class DeviceDetailViewModel: ObservableObject {
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    let deviceId: String
    private let logsService: CloudWatchLogsService

    init(deviceId: String, auth: CognitoAuthService) {
        self.deviceId = deviceId
        self.logsService = CloudWatchLogsService(auth: auth)
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            logs = try await logsService.fetchDeviceLogs(deviceId: deviceId)
        } catch {
            if !isCancellationError(error) {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }
}
