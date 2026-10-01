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
    let bootStatus: BootStatusInfo?
    /// Raw `network.transport` value from the latest telemetry (firmware
    /// `TransportKind`: `"wifi"` / `"lte"` / `"lorawan"` / `"none"`; LoRaWAN
    /// uplinks are normalized by the bridge Lambda to the same JSON shape,
    /// with `network.transport = "lorawan"`, see #83).
    let transport: String?

    var id: String { deviceId }

    var isOffline: Bool {
        Date().timeIntervalSince(lastSeen) > AWSConfig.offlineThreshold
    }

    /// Human-readable transport label, forward-compatible with transport
    /// values this app doesn't know about yet (falls back to the raw value
    /// uppercased, so a future firmware addition still shows *something*
    /// sensible without an app update).
    var transportLabel: String? {
        guard let transport, transport != "none" else { return nil }
        switch transport {
        case "lte": return "LTE"
        case "wifi": return "Wi-Fi"
        case "lorawan": return "LoRa"
        default: return transport.uppercased()
        }
    }
}

/// One row from `CloudWatchLogsService.fetchDeviceStatuses` — the cheap
/// per-device query (see #77). Doesn't carry a reset timestamp; callers that
/// need uptime combine this with a separately-cached
/// `fetchResetTimestamps()` result (or skip that entirely, like the
/// background refresh path, which only needs `status`/`lastSeen`).
struct DeviceStatusRow {
    let deviceId: String
    let status: DeviceOperationalStatus
    let lastSeen: Date
    let bootCount: Int?
    let transport: String?
}

struct LogEntry: Identifiable, Equatable {
    let id: String
    let timestamp: Date
    let deviceId: String?
    let status: DeviceOperationalStatus?
    let message: String

    /// Row from a CloudWatch Logs Insights query with `fields @timestamp, @message`
    /// plus `parse`d `deviceId` / `status` fields (see CloudWatchLogsService).
    init?(row: [String: String]) {
        guard let timestampString = row["@timestamp"], let message = row["@message"] else { return nil }
        guard let date = LogEntry.timestampFormatter.date(from: timestampString) else { return nil }
        // Content-derived id (millisecond timestamp + full message), not a
        // random UUID generated fresh on every fetch: the same log line then
        // gets the same SwiftUI identity across the 30s auto-refresh, so
        // `ForEach` doesn't treat every poll as "all new rows" — an expanded
        // raw-log disclosure and scroll position survive a background
        // reload instead of resetting under the user mid-interaction.
        //
        // CloudWatch's own `@ptr` looks like it should serve this purpose,
        // but it isn't actually stable: re-running the identical query for
        // the identical record returns a different `@ptr` each time
        // (verified against live data), so it can't be used here.
        self.id = "\(timestampString)|\(message)"
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
