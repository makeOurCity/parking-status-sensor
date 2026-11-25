import XCTest
@testable import LogViewer

/// キャッシュ・デバイス選択・連続区間（#132）の試験。
final class ReceivedEventCacheTests: XCTestCase {
    private let windowStart = jst("2026-09-27 00:00:00")

    func testFirstFetchCoversWholeWindow() {
        let cache = ReceivedEventCache()
        let range = cache.nextFetchRange(now: jst("2026-11-25 12:00:00"), windowStart: windowStart)
        XCTAssertEqual(range.start, windowStart)
        XCTAssertEqual(range.end, jst("2026-11-25 12:00:00"))
    }

    func testIncrementalFetchStartsFromLatestEventMinusOverlap() {
        var cache = ReceivedEventCache()
        cache.merge(
            [event("2026-11-25 11:00:00", .open, device: "a"), event("2026-11-25 10:00:00", .full, device: "b")],
            through: jst("2026-11-25 11:30:00")
        )
        let range = cache.nextFetchRange(now: jst("2026-11-25 12:00:00"), windowStart: windowStart)
        XCTAssertEqual(range.start, jst("2026-11-25 10:50:00")) // 最終受信 11:00 の 10 分前
        XCTAssertEqual(range.end, jst("2026-11-25 12:00:00"))
    }

    func testIncrementalStartIsCappedByFetchedThrough() {
        // 最終受信が取得終了より新しいことは無い想定だが、早い方を使う。
        var cache = ReceivedEventCache()
        cache.merge([event("2026-11-25 11:00:00", .open)], through: jst("2026-11-25 10:00:00"))
        let range = cache.nextFetchRange(now: jst("2026-11-25 12:00:00"), windowStart: windowStart)
        XCTAssertEqual(range.start, jst("2026-11-25 09:50:00"))
    }

    func testIncrementalStartNeverPrecedesWindow() {
        var cache = ReceivedEventCache()
        cache.merge([event("2026-09-27 00:05:00", .open)], through: jst("2026-09-27 00:10:00"))
        let range = cache.nextFetchRange(now: jst("2026-09-27 01:00:00"), windowStart: windowStart)
        XCTAssertEqual(range.start, windowStart)
    }

    func testMergeIsIdempotentAndSameSecondKeepsLaterMillisecond() {
        var cache = ReceivedEventCache()
        let early = event("2026-11-25 10:00:00.100", .full)
        let late = event("2026-11-25 10:00:00.800", .open)
        cache.merge([early, late], through: jst("2026-11-25 10:30:00"))
        cache.merge([late, early], through: jst("2026-11-25 10:40:00"))
        XCTAssertEqual(cache.allEvents, [late])
        XCTAssertEqual(cache.fetchedThrough, jst("2026-11-25 10:40:00"))
    }

    func testFetchedThroughNeverMovesBackwards() {
        var cache = ReceivedEventCache()
        cache.merge([], through: jst("2026-11-25 10:40:00"))
        cache.merge([], through: jst("2026-11-25 10:00:00"))
        XCTAssertEqual(cache.fetchedThrough, jst("2026-11-25 10:40:00"))
    }

    func testTrimDropsOldEventsAndEmptyDevices() {
        var cache = ReceivedEventCache()
        cache.merge(
            [event("2026-10-01 00:00:00", .open, device: "old"), event("2026-11-25 00:00:00", .open, device: "new")],
            through: jst("2026-11-25 01:00:00")
        )
        cache.trim(before: jst("2026-11-01 00:00:00"))
        XCTAssertEqual(cache.deviceIds, ["new"])
        XCTAssertEqual(cache.allEvents.count, 1)
    }
}

final class TimelineDeviceSelectorTests: XCTestCase {
    func testSilentRegisteredDeviceStaysEvenIfDashboardDroppedIt() {
        // ダッシュボードは直近 3 日に受信のある機体だけ。マスターの機体は停止中でも残す。
        let result = TimelineDeviceSelector.select(
            masterIds: ["lora", "ltem"],
            activeIds: ["ltem"],
            eventDeviceIds: ["lora", "ltem"]
        )
        XCTAssertEqual(result, ["lora", "ltem"])
    }

    func testUnregisteredActiveDeviceIsShown() {
        let result = TimelineDeviceSelector.select(masterIds: ["a"], activeIds: ["b"], eventDeviceIds: ["a", "b"])
        XCTAssertEqual(result, ["a", "b"])
    }

    func testStaleTestDeviceNotInMasterOrDashboardIsHidden() {
        let result = TimelineDeviceSelector.select(
            masterIds: ["a"], activeIds: ["a"], eventDeviceIds: ["a", "xiao-test-device"]
        )
        XCTAssertEqual(result, ["a"])
    }

    func testDeviceWithoutAnyReceiptInPeriodIsHidden() {
        let result = TimelineDeviceSelector.select(masterIds: ["a", "gone"], activeIds: [], eventDeviceIds: ["a"])
        XCTAssertEqual(result, ["a"])
    }

    func testOrderIsByDeviceId() {
        let result = TimelineDeviceSelector.select(
            masterIds: ["c", "a"], activeIds: ["b"], eventDeviceIds: ["a", "b", "c"]
        )
        XCTAssertEqual(result, ["a", "b", "c"])
    }
}

final class ContinuousSpanTests: XCTestCase {
    func testNoDataRunIsExtendedAcrossMidnightAndDays() {
        // 10/17 午後に最後の受信 → 10/19 の途中に次の受信。10/18 は丸 1 日 noData。
        let timeline = TimelineAggregator.build(
            deviceId: "dev",
            events: [event("2026-10-17 12:00:00", .open), event("2026-10-19 06:00:00", .open)],
            firstDay: jstDay("2026-10-17"),
            dayCount: 3,
            now: jst("2026-10-19 23:59:59")
        )
        let day18 = timeline.days[1]
        let span = timeline.continuousSpan(of: day18.runs[0], onDay: day18.day)
        XCTAssertEqual(span?.start, jst("2026-10-17 13:30:00")) // bin 80 の中央 13:25 は 85 分後で有効、bin 81（13:30〜）の中央 13:35 は 95 分後で noData
        XCTAssertEqual(span?.end, jst("2026-10-19 06:00:00"))
    }

    func testRunsWithDifferentStateAreNotMerged() {
        let timeline = TimelineAggregator.build(
            deviceId: "dev",
            events: [event("2026-11-10 23:00:00", .full), event("2026-11-11 00:30:00", .open)],
            firstDay: jstDay("2026-11-10"),
            dayCount: 2,
            now: jst("2026-11-11 23:59:59")
        )
        // full は 23:00 から、90 分以内なので翌日 00:30（open の受信）まで日をまたいで続く。
        let day10 = timeline.days[0]
        let full = timeline.continuousSpan(of: day10.runs[0], onDay: day10.day)
        XCTAssertEqual(full?.start, jst("2026-11-10 23:00:00"))
        XCTAssertEqual(full?.end, jst("2026-11-11 00:30:00"))
        // open は 0:30 から。直前の full とは結合しない。
        let day11 = timeline.days[1]
        let open = day11.runs.first { $0.state == .open }!
        XCTAssertEqual(timeline.continuousSpan(of: open, onDay: day11.day)?.start, jst("2026-11-11 00:30:00"))
    }
}

@MainActor
final class DataHorizonTests: XCTestCase {
    func testHorizonIsCappedAtFetchedThrough() {
        // 10:00 に取得した後、12:00 に再計算しても、10:00 より先のマスは数えない。
        let horizon = TimelineViewModel.dataHorizon(now: jst("2026-11-10 12:00:00"), fetchedThrough: jst("2026-11-10 10:00:00"))
        XCTAssertEqual(horizon, jst("2026-11-10 10:00:00"))

        let day = TimelineAggregator.build(
            deviceId: "dev",
            events: [event("2026-11-10 09:55:00", .open)],
            firstDay: jstDay("2026-11-10"),
            dayCount: 1,
            now: horizon
        ).days[0]
        // bin 59（9:50〜10:00、中央 9:55）まで。10:00 より後を「データなし」にしない。
        XCTAssertEqual(day.runs, [seg(59, 60, .open)])
        XCTAssertEqual(day.noDataBins, 0)
    }

    func testHorizonIsNowWhenFetchIsNewerOrMissing() {
        let now = jst("2026-11-10 12:00:00")
        XCTAssertEqual(TimelineViewModel.dataHorizon(now: now, fetchedThrough: nil), now)
        XCTAssertEqual(TimelineViewModel.dataHorizon(now: now, fetchedThrough: jst("2026-11-10 12:00:01")), now)
    }
}
