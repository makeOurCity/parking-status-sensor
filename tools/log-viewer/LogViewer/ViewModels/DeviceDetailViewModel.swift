import Foundation

@MainActor
final class DeviceDetailViewModel: ObservableObject {
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    let deviceId: String
    /// Parking lot name from the device master (#108); nil → show the deviceId.
    let name: String?
    private let logsService: CloudWatchLogsService

    var title: String { name ?? deviceId }

    init(deviceId: String, name: String?, auth: CognitoAuthService) {
        self.deviceId = deviceId
        self.name = name
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
