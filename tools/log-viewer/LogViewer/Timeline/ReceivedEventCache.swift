import Foundation

/// 取得済みの受信イベントをメモリに持ち、再読み込みを「前回の最終受信以降だけ」に絞る（#77, #132）。
///
/// 内部は `[deviceId: [受信秒: イベント]]`。同じ秒は ms の遅い方で上書きするので、
/// 取得範囲の重なりや Lambda の再実行による重複を、原理的に作らない。
struct ReceivedEventCache {
    /// 直近に**成功した**取得の終了時刻。
    private(set) var fetchedThrough: Date?
    private var bySecond: [String: [Int: ReceivedEvent]] = [:]

    /// 全デバイスを通した最後の受信時刻。
    private(set) var latestEventAt: Date?

    /// 取得済みイベントに現れた deviceId。
    var deviceIds: Set<String> { Set(bySecond.filter { !$0.value.isEmpty }.keys) }

    /// 取得済みの全イベント（順不同）。
    var allEvents: [ReceivedEvent] { bySecond.values.flatMap(\.values) }

    /// 取得に成功した分を取り込む。失敗した取得は呼ばない（キャッシュを変えない）。
    mutating func merge(_ events: [ReceivedEvent], through: Date) {
        for event in events {
            let second = TimelineAggregator.epochSecond(event.receivedAt)
            if let existing = bySecond[event.deviceId]?[second], existing.receivedAt >= event.receivedAt { continue }
            bySecond[event.deviceId, default: [:]][second] = event
            if latestEventAt == nil || event.receivedAt > latestEventAt! { latestEventAt = event.receivedAt }
        }
        if fetchedThrough == nil || through > fetchedThrough! { fetchedThrough = through }
    }

    /// 次に取得する範囲。
    ///
    /// - 初回は `windowStart` から `now` まで。
    /// - 2 回目以降は、前回取得の終了時刻と最終受信の早い方から `overlap` 戻した時刻から。
    ///   最終受信そのままではなく少し戻すのは、取り込みが遅れた機体のイベントが、
    ///   別の機体の新しい受信より古い時刻を持つことがあるため（重なりは同秒除去が吸収する）。
    func nextFetchRange(now: Date, windowStart: Date, overlap: TimeInterval = 10 * 60) -> (start: Date, end: Date) {
        guard let fetchedThrough else { return (windowStart, now) }
        let anchor = min(latestEventAt ?? fetchedThrough, fetchedThrough)
        let start = max(windowStart, anchor.addingTimeInterval(-overlap))
        return (start, now)
    }

    /// `date` より前のイベントを捨てる（長時間起動してもメモリが増えない）。
    mutating func trim(before date: Date) {
        let cutoff = TimelineAggregator.epochSecond(date)
        for deviceId in Array(bySecond.keys) {
            bySecond[deviceId] = bySecond[deviceId]?.filter { $0.key >= cutoff }
            if bySecond[deviceId]?.isEmpty == true { bySecond[deviceId] = nil }
        }
    }
}
