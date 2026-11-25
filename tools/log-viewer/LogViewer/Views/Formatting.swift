import Foundation

enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.unitsStyle = .short
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// All log/device timestamps are shown in JST regardless of the device's own
/// time zone setting — the site operators think in local (Japan) time.
enum JSTTime {
    static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static let shortDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "MM/dd HH:mm:ss"
        return formatter
    }()
}

extension JSTTime {
    /// "11/25(火)" — タイムラインの日付ラベル。
    static let dayLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "M/d(E)"
        return formatter
    }()

    /// "11/25(火) 13:20" — 選択した区間の開始・終了。
    static let dayTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")
        formatter.dateFormat = "M/d(E) H:mm"
        return formatter
    }()

    /// "13:20"（24:00 は日付をまたぐので "24:00" と書く）。`minutesOfDay` は 0...1440。
    static func clockLabel(minutesOfDay: Int) -> String {
        String(format: "%d:%02d", minutesOfDay / 60, minutesOfDay % 60)
    }

    /// "1時間30分" / "40分" / "2日3時間"。
    static func durationLabel(minutes: Int) -> String {
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        let mins = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)日\(hours)時間" : "\(days)日" }
        if hours > 0 { return mins > 0 ? "\(hours)時間\(mins)分" : "\(hours)時間" }
        return "\(mins)分"
    }
}
