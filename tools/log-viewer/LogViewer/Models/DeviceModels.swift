import SwiftUI

/// Mirrors the `status` field in the telemetry payload (docs/data-model.md).
enum DeviceOperationalStatus: String {
    case full
    case available
    case unknown

    var label: String {
        switch self {
        case .full: return "満"
        case .available: return "空"
        case .unknown: return "不明"
        }
    }

    var color: Color {
        switch self {
        case .full: return Theme.full
        case .available: return Theme.available
        case .unknown: return Theme.unknown
        }
    }

    var icon: String {
        switch self {
        case .full: return "car.fill"
        case .available: return "checkmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

struct DeviceSummary: Identifiable, Equatable {
    let deviceId: String
    let status: DeviceOperationalStatus
    let lastSeen: Date

    var id: String { deviceId }

    var isOffline: Bool {
        Date().timeIntervalSince(lastSeen) > AWSConfig.offlineThreshold
    }
}

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let deviceId: String?
    let status: DeviceOperationalStatus?
    let message: String

    /// Row from a CloudWatch Logs Insights query with `fields @timestamp, @message`
    /// plus `parse`d `deviceId` / `status` fields (see CloudWatchLogsService).
    init?(row: [String: String]) {
        guard let timestampString = row["@timestamp"], let message = row["@message"] else { return nil }
        guard let date = LogEntry.timestampFormatter.date(from: timestampString) else { return nil }
        self.timestamp = date
        self.deviceId = row["deviceId"]
        self.status = row["status"].flatMap(DeviceOperationalStatus.init(rawValue:))
        self.message = message
    }

    /// CloudWatch Logs Insights renders `@timestamp` as `yyyy-MM-dd HH:mm:ss.SSS` (UTC).
    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
}
