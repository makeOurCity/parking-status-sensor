import Foundation
@testable import LogViewer

/// "2026-11-10 12:03:00" / "2026-11-10 12:03:00.250"（JST）→ Date。
/// 固定オフセット +9h で解釈するので、端末のタイムゾーン設定に依存しない。
func jst(_ string: String) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 9 * 3600)
    formatter.dateFormat = string.contains(".") ? "yyyy-MM-dd HH:mm:ss.SSS" : "yyyy-MM-dd HH:mm:ss"
    guard let date = formatter.date(from: string) else {
        fatalError("bad JST date: \(string)")
    }
    return date
}

/// "2026-11-10"（JST の暦日）→ JSTDay。
func jstDay(_ string: String) -> JSTDay {
    JSTDay(date: jst("\(string) 12:00:00"))
}

func event(_ at: String, _ status: DeviceOperationalStatus, device: String = "dev") -> ReceivedEvent {
    ReceivedEvent(deviceId: device, receivedAt: jst(at), status: status)
}

func seg(_ start: Int, _ end: Int, _ state: TimelineState) -> TimelineRun {
    TimelineRun(startBin: start, endBin: end, state: state)
}

/// 1 日分の集計を取り出す簡易ヘルパー。
func buildOneDay(
    _ events: [ReceivedEvent],
    day: String = "2026-11-10",
    now: String = "2026-11-10 23:59:59",
    device: String = "dev"
) -> DayTimeline {
    TimelineAggregator.build(
        deviceId: device,
        events: events,
        firstDay: jstDay(day),
        dayCount: 1,
        now: jst(now)
    ).days[0]
}
