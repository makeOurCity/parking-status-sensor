import Foundation

/// 受信イベントの点を、日ごとの連続区間（10 分マス）に直す純粋関数（#132）。
///
/// 端末は「状態が変わったとき」と「約 65 分ごとの heartbeat」にしか送らないので、
/// 各マスの中央時点で「直近に受信した状態」をそのマスの状態にする。
///
/// ルール（Issue #132 の「集計のルール」）:
/// 1. 時刻は Lambda の受信時刻（UTC）→ JST。
/// 2. 10 分のマスの中央時点（`b*10 + 5` 分）で `t <= 中央` を満たす最新の受信を使う（中央ちょうどを含む）。
/// 3. 最後の受信から `staleAfter`（90 分）を**超えたら**データなし（ちょうど 90 分は有効）。
/// 4. `available` → `open` は `ReceivedEvent` 側で済んでいる。
/// 5. 同じ秒の重複は 1 件（ms の遅い方を残す）。
/// 6. 欠落率 = データなし ÷ 数えるマス。最初の受信より前（設置前）は数えず描かない。
/// 7. 現在時刻より先のマス（中央 > now）は数えず描かない。
enum TimelineAggregator {
    static let binMinutes = 10
    static let binsPerDay = 144
    private static let binSeconds = binMinutes * 60

    /// 1 台分の受信を、秒単位で重複除去して昇順にそろえる。同じ秒に複数あれば
    /// `receivedAt`（ms）の遅い方を残す（入力の並びに依存しない）。
    static func normalize(_ events: [ReceivedEvent]) -> [ReceivedEvent] {
        var bySecond: [Int: ReceivedEvent] = [:]
        for event in events {
            let second = epochSecond(event.receivedAt)
            if let existing = bySecond[second], existing.receivedAt >= event.receivedAt { continue }
            bySecond[second] = event
        }
        return bySecond.keys.sorted().compactMap { bySecond[$0] }
    }

    /// - Parameters:
    ///   - events: 順不同・重複可。表示範囲の前後を含んでよい（範囲の最初の 90 分の状態は
    ///     範囲前の受信から決まる）。他のデバイスの行は無視する。
    ///   - firstDay / dayCount: 表示する JST の日（古い方から連続）。
    ///   - firstReceivedAt: そのデバイスの最初の受信が分かっていれば渡す。nil なら `events` の最小。
    static func build(
        deviceId: String,
        events: [ReceivedEvent],
        firstDay: JSTDay,
        dayCount: Int,
        now: Date,
        staleAfter: TimeInterval = AWSConfig.offlineThreshold,
        firstReceivedAt: Date? = nil
    ) -> DeviceTimeline {
        let normalized = normalize(events.filter { $0.deviceId == deviceId })
        let seconds = normalized.map { epochSecond($0.receivedAt) }
        let first = firstReceivedAt.map(epochSecond) ?? seconds.first
        let nowSecond = epochSecond(now)
        let staleSeconds = Int(staleAfter)

        var pointer = -1 // 中央時点までに受信した最新イベントの添字
        var days: [DayTimeline] = []
        days.reserveCapacity(max(dayCount, 0))

        for offset in 0..<max(dayCount, 0) {
            let day = firstDay.adding(days: offset)
            let dayStart = day.startEpoch
            var runs: [TimelineRun] = []
            var counted = 0
            var noData = 0

            for bin in 0..<binsPerDay {
                let mid = dayStart + bin * binSeconds + binSeconds / 2
                if mid > nowSecond { break } // ルール 7（以降のマスはすべて未来）
                guard let first, mid >= first else { continue } // ルール 6（設置前）

                while pointer + 1 < seconds.count && seconds[pointer + 1] <= mid { pointer += 1 }

                let state: TimelineState
                if pointer < 0 || mid - seconds[pointer] > staleSeconds {
                    state = .noData
                } else {
                    state = TimelineState(normalized[pointer].status)
                }

                counted += 1
                if state == .noData { noData += 1 }

                if let last = runs.last, last.state == state, last.endBin == bin {
                    runs[runs.count - 1] = TimelineRun(startBin: last.startBin, endBin: bin + 1, state: state)
                } else {
                    runs.append(TimelineRun(startBin: bin, endBin: bin + 1, state: state))
                }
            }

            days.append(DayTimeline(day: day, runs: runs, countedBins: counted, noDataBins: noData))
        }

        return DeviceTimeline(
            deviceId: deviceId,
            days: days,
            firstReceivedAt: first.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    /// `deviceIds` の順に 1 台ずつ `build` する。`events` は全デバイス混在でよい。
    static func buildAll(
        events: [ReceivedEvent],
        deviceIds: [String],
        firstDay: JSTDay,
        dayCount: Int,
        now: Date,
        staleAfter: TimeInterval = AWSConfig.offlineThreshold
    ) -> [DeviceTimeline] {
        let grouped = Dictionary(grouping: events, by: \.deviceId)
        return deviceIds.map { deviceId in
            build(
                deviceId: deviceId,
                events: grouped[deviceId] ?? [],
                firstDay: firstDay,
                dayCount: dayCount,
                now: now,
                staleAfter: staleAfter
            )
        }
    }

    static func epochSecond(_ date: Date) -> Int {
        Int(floor(date.timeIntervalSince1970))
    }
}
