import Foundation

// 満空タイムライン（#132）のデータモデル。
// Foundation と DeviceOperationalStatus だけに依存し、SwiftUI / Theme には依存しない
// （集計の純粋関数を XCTest で試験するため）。

/// Lambda の受信イベント 1 件（Logs Insights の `@timestamp` / `deviceId` / `status`）。
///
/// 時刻は Lambda の受信時刻（UTC）。端末が送る `timestamp` は未同期のことがあるので使わない。
struct ReceivedEvent: Equatable {
    let deviceId: String
    let receivedAt: Date
    /// `available` は `.open` に読み替え済み（`DeviceOperationalStatus.parse`）。
    let status: DeviceOperationalStatus

    init(deviceId: String, receivedAt: Date, status: DeviceOperationalStatus) {
        self.deviceId = deviceId
        self.receivedAt = receivedAt
        self.status = status
    }

    /// `fields @timestamp ... | display @timestamp, deviceId, status` の 1 行から作る。
    /// - `@timestamp` が読めない／`deviceId` が無い／`status` の行が無い → nil
    /// - `status` が未知の文字列 → `.unknown`（`fetchDeviceStatuses` と同じ扱い）
    init?(row: [String: String]) {
        guard let timestamp = row["@timestamp"],
              let receivedAt = LogEntry.timestampFormatter.date(from: timestamp),
              let deviceId = row["deviceId"], !deviceId.isEmpty,
              let rawStatus = row["status"]
        else { return nil }
        self.init(
            deviceId: deviceId,
            receivedAt: receivedAt,
            status: DeviceOperationalStatus.parse(rawStatus) ?? .unknown
        )
    }
}

/// タイムライン上の 1 マス（10 分）の状態。
enum TimelineState: Equatable {
    case full
    case open
    case unknown
    /// 最後の受信から `staleAfter`（90 分）を超えた。欠落率の分子。
    case noData

    init(_ status: DeviceOperationalStatus) {
        switch status {
        case .full: self = .full
        case .open: self = .open
        case .unknown: self = .unknown
        }
    }
}

/// JST の暦日。`index` は 1970-01-01（JST）からの日数。
///
/// `Calendar` を使わず固定オフセット +9 時間の整数演算で決める。日本は DST が無く、
/// 試験が端末のタイムゾーン設定に依存しない。
struct JSTDay: Hashable, Comparable {
    static let offsetSeconds = 9 * 3600

    let index: Int

    init(index: Int) {
        self.index = index
    }

    init(date: Date) {
        let seconds = Int(floor(date.timeIntervalSince1970)) + Self.offsetSeconds
        self.index = Int(floor(Double(seconds) / 86_400))
    }

    /// その日の 0:00（JST）の UTC エポック秒。
    var startEpoch: Int { index * 86_400 - Self.offsetSeconds }

    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(startEpoch)) }

    func adding(days: Int) -> JSTDay { JSTDay(index: index + days) }

    static func < (lhs: JSTDay, rhs: JSTDay) -> Bool { lhs.index < rhs.index }
}

/// 同じ状態が続く区間。`[startBin, endBin)`（マス番号。1 日 = 144 マス）。
struct TimelineRun: Equatable {
    let startBin: Int
    let endBin: Int
    let state: TimelineState

    var binCount: Int { endBin - startBin }
}

/// 1 デバイスの 1 日分。
struct DayTimeline: Equatable, Identifiable {
    let day: JSTDay
    /// 描画する区間。設置前と未来のマスは含まない。
    let runs: [TimelineRun]
    /// 欠落率の分母（設置前・未来を除いたマス数）。
    let countedBins: Int
    /// 欠落率の分子（`.noData` のマス数）。
    let noDataBins: Int

    var id: Int { day.index }

    /// 分母が 0（設置前の日・未来の日）なら nil。
    var noDataRate: Double? {
        countedBins == 0 ? nil : Double(noDataBins) / Double(countedBins)
    }

    /// `bin`（0..<144）を含む区間。設置前・未来のマスは nil。
    func run(containing bin: Int) -> TimelineRun? {
        runs.first { $0.startBin <= bin && bin < $0.endBin }
    }
}

/// 1 デバイスの表示期間分。
struct DeviceTimeline: Equatable, Identifiable {
    let deviceId: String
    /// 古い日 → 新しい日。表示範囲の全日を含む（runs が空の日もある）。
    let days: [DayTimeline]
    let firstReceivedAt: Date?

    var id: String { deviceId }

    var countedBins: Int { days.reduce(0) { $0 + $1.countedBins } }
    var noDataBins: Int { days.reduce(0) { $0 + $1.noDataBins } }

    /// 表示期間全体の欠落率。分母 0 なら nil。
    var noDataRate: Double? {
        countedBins == 0 ? nil : Double(noDataBins) / Double(countedBins)
    }

    /// `run`（`day` の区間）が日をまたいで続く範囲。同じ状態の区間が 0:00 の境目で
    /// 隣の日につながっていれば、そこまで延ばす。停止期間の長さを読み出すのに使う。
    func continuousSpan(of run: TimelineRun, onDay day: JSTDay) -> (start: Date, end: Date)? {
        guard let dayIndex = days.firstIndex(where: { $0.day == day }) else { return nil }
        var first = dayIndex
        var startBin = run.startBin
        while startBin == 0, first > 0,
              let previous = days[first - 1].runs.last,
              previous.endBin == TimelineAggregator.binsPerDay, previous.state == run.state {
            first -= 1
            startBin = previous.startBin
        }
        var last = dayIndex
        var endBin = run.endBin
        while endBin == TimelineAggregator.binsPerDay, last + 1 < days.count,
              let next = days[last + 1].runs.first,
              next.startBin == 0, next.state == run.state {
            last += 1
            endBin = next.endBin
        }
        let binSeconds = TimelineAggregator.binMinutes * 60
        return (
            Date(timeIntervalSince1970: TimeInterval(days[first].day.startEpoch + startBin * binSeconds)),
            Date(timeIntervalSince1970: TimeInterval(days[last].day.startEpoch + endBin * binSeconds))
        )
    }
}
