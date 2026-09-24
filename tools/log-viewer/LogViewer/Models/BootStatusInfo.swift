import Foundation

/// Device-level "how long has it been running" snapshot shown on the
/// dashboard's device cards, derived from CloudWatch Logs Insights aggregate
/// queries (see `CloudWatchLogsService.fetchDeviceSummaries`).
///
/// `bootCount` lives in ESP32 RTC memory (firmware/src/main.cpp): it
/// survives deep sleep and increments by 1 on every boot — including plain
/// deep-sleep timer wakes, not just power-on resets — but resets to 0 (so
/// the next boot reports 1) on a genuine power-on/brownout/hard reset. So
/// "bootCount == 1" always marks the first telemetry send after the
/// device's most recent hard reset, which is what `sessionStartedAt` points
/// to.
struct BootStatusInfo: Equatable {
    let bootCount: Int
    /// nil when no bootCount==1 entry was found within the lookback window
    /// (the device has been running longer than that — uncommon but not
    /// impossible for a long-lived PoC unit).
    let sessionStartedAt: Date?
    let latestTimestamp: Date

    var uptime: TimeInterval? {
        guard let sessionStartedAt else { return nil }
        return latestTimestamp.timeIntervalSince(sessionStartedAt)
    }

    var uptimeLabel: String {
        guard let uptime else { return "不明" }
        let totalMinutes = max(0, Int(uptime / 60))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return "\(days)日\(hours)時間"
        } else if hours > 0 {
            return "\(hours)時間\(minutes)分"
        } else {
            return "\(minutes)分"
        }
    }
}
