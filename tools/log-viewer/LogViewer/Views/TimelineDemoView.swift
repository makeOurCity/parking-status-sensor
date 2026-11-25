#if DEBUG
import SwiftUI

/// 認証なしで満空タイムラインの見た目を確認するための DEBUG 専用の画面（#132）。
///
/// シミュレータで `-timelineDemo` を付けて起動すると、RootView がこれを出す。
/// `-timelineDemoDevices 4` で台数を変えられる（既定 2。幅が足りないと 1 台ずつ切り替える表示になる）。
/// 通信はしない。サンプルは、長期停止・途中設置・heartbeat・満空の日内変化を含む合成データ。
enum TimelineDemoData {
    /// 決定的な疑似乱数（シード固定で毎回同じ絵になる）。
    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 33) / Double(1 << 31)
        }
    }

    static let names = DeviceNames([
        "demo-lte-m": "第1駐車場",
        "demo-lorawan": "第2駐車場",
    ])

    static func deviceIds(count: Int) -> [String] {
        let all = ["demo-lorawan", "demo-lte-m", "demo-extra-1", "demo-extra-2", "demo-extra-3", "demo-extra-4"]
        return Array(all.prefix(max(1, min(count, all.count)))).sorted()
    }

    static func timelines(deviceCount: Int, days: Int, now: Date = Date()) -> [DeviceTimeline] {
        let ids = deviceIds(count: deviceCount)
        var events: [ReceivedEvent] = []
        for (index, id) in ids.enumerated() {
            events += makeEvents(deviceId: id, seed: UInt64(index + 1), now: now)
        }
        let today = JSTDay(date: now)
        return TimelineAggregator.buildAll(
            events: events,
            deviceIds: ids,
            firstDay: today.adding(days: -(days - 1)),
            dayCount: days,
            now: now
        )
    }

    private static func makeEvents(deviceId: String, seed: UInt64, now: Date) -> [ReceivedEvent] {
        var rng = LCG(state: seed &* 7919)
        // 機体ごとに設置日と停止期間をずらす。
        let installedDaysAgo = 70 - Int(seed) * 9
        let outage = (start: 40 - Int(seed) * 3, length: 6 + Int(seed))
        var events: [ReceivedEvent] = []
        var cursor = now.addingTimeInterval(-TimeInterval(installedDaysAgo) * 86_400)
        var status = DeviceOperationalStatus.open
        var lastSent = Date.distantPast

        while cursor < now {
            let daysAgo = now.timeIntervalSince(cursor) / 86_400
            let inOutage = daysAgo < Double(outage.start) && daysAgo > Double(outage.start - outage.length)
            if !inOutage {
                // 日中は満になりやすい。
                let hour = Int(cursor.timeIntervalSince1970 + 9 * 3600) / 3600 % 24
                let fullChance = (8..<19).contains(hour) ? 0.45 : 0.1
                let newStatus: DeviceOperationalStatus = rng.next() < fullChance ? .full : .open
                if newStatus != status || cursor.timeIntervalSince(lastSent) >= 65 * 60 {
                    status = newStatus
                    lastSent = cursor
                    events.append(ReceivedEvent(deviceId: deviceId, receivedAt: cursor, status: status))
                }
            }
            cursor.addTimeInterval(TimeInterval(8 * 60 + Int(rng.next() * 600)))
        }
        return events
    }
}

struct TimelineDemoView: View {
    @State private var period: TimelinePeriod = .days30
    private let deviceCount = max(UserDefaults.standard.integer(forKey: "timelineDemoDevices"), 2)
    /// `-timelineDemoSelect 1` で、停止（データなし）の区間を最初から選んだ状態にする。
    private let preselect = UserDefaults.standard.bool(forKey: "timelineDemoSelect")

    private var initialSelection: TimelineSelection? {
        guard preselect else { return nil }
        let timelines = TimelineDemoData.timelines(deviceCount: deviceCount, days: 30)
        for timeline in timelines {
            for day in timeline.days {
                if let run = day.runs.first(where: { $0.state == .noData }) {
                    return TimelineSelection(deviceId: timeline.deviceId, day: day.day, bin: (run.startBin + run.endBin) / 2)
                }
            }
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            TimelineScreen(
                timelines: TimelineDemoData.timelines(deviceCount: deviceCount, days: period.rawValue),
                names: TimelineDemoData.names,
                period: $period,
                isLoading: false,
                errorMessage: nil,
                lastFetchedAt: Date(),
                onRefresh: {},
                initialSelection: initialSelection
            )
        }
    }
}

#Preview("30日・2台") {
    TimelineDemoView()
}
#endif
