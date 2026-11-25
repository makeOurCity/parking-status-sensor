import XCTest
@testable import LogViewer

/// 集計ルール（Issue #132）の試験。期待値は Python の参照実装（試作 `build_timeline.py` の
/// ロジック + 設置前・未来の除外）で機械的に出した値。マス b の中央は `b*10 分 + 5 分`。
final class TimelineAggregatorTests: XCTestCase {

    // MARK: - 10 分のマスと中央時点

    func testBinUsesLatestReceiptAtBinMidpoint() {
        // 10:04:59 の受信は bin 60（10:00–10:10、中央 10:05:00）から有効。
        let day = buildOneDay([event("2026-11-10 10:04:59", .open)])
        XCTAssertEqual(day.runs, [seg(60, 69, .open), seg(69, 144, .noData)])
        XCTAssertEqual(day.countedBins, 84)
        XCTAssertEqual(day.noDataBins, 75)
    }

    func testReceiptExactlyAtMidpointIsIncluded() {
        // 中央ちょうど（10:05:00）の受信は含む。そこから ちょうど 90 分後の bin 69（11:35:00）も有効。
        let day = buildOneDay([event("2026-11-10 10:05:00", .open)])
        XCTAssertEqual(day.runs, [seg(60, 70, .open), seg(70, 144, .noData)])
        XCTAssertEqual(day.countedBins, 84)
        XCTAssertEqual(day.noDataBins, 74)
    }

    func testReceiptAfterMidpointStartsFromNextBin() {
        // 10:05:01 は bin 60 の中央より後。最初の受信なので bin 60 は設置前（描かない）。
        let day = buildOneDay([event("2026-11-10 10:05:01", .open)])
        XCTAssertEqual(day.runs, [seg(61, 70, .open), seg(70, 144, .noData)])
        XCTAssertEqual(day.countedBins, 83)
        XCTAssertEqual(day.noDataBins, 74)
    }

    func testReceiptAfterMidpointKeepsPreviousStateForThatBin() {
        // 先に full があれば、bin 60 は full のまま（open は bin 61 から）。
        let day = buildOneDay([
            event("2026-11-10 09:00:00", .full),
            event("2026-11-10 10:05:01", .open),
        ])
        XCTAssertEqual(day.runs, [seg(54, 61, .full), seg(61, 70, .open), seg(70, 144, .noData)])
        XCTAssertEqual(day.countedBins, 90)
        XCTAssertEqual(day.noDataBins, 74)
    }

    // MARK: - 90 分での打ち切り

    func testNinetyMinutesBoundaryIsInclusive() {
        // 最後の受信 10:04:59。bin 68 の中央 11:25:00 は 80:01 後で有効、bin 69 の中央 11:35:00 は 90:01 後で noData。
        let day = buildOneDay([event("2026-11-10 10:04:59", .open)])
        XCTAssertEqual(day.run(containing: 68)?.state, .open)
        XCTAssertEqual(day.run(containing: 69)?.state, .noData)
    }

    func testHeartbeatEvery65MinutesNeverGoesNoData() {
        // heartbeat（約 65 分）は 90 分より短いので、欠落は 0。
        var events: [ReceivedEvent] = []
        var minutes = 0
        while minutes < 24 * 60 {
            events.append(event(String(format: "2026-11-10 %02d:%02d:00", minutes / 60, minutes % 60), .open))
            minutes += 65
        }
        let day = buildOneDay(events)
        XCTAssertEqual(day.runs, [seg(0, 144, .open)])
        XCTAssertEqual(day.countedBins, 144)
        XCTAssertEqual(day.noDataBins, 0)
    }

    func testStaleAfterIsConfigurable() {
        let day = TimelineAggregator.build(
            deviceId: "dev",
            events: [event("2026-11-10 10:04:59", .open)],
            firstDay: jstDay("2026-11-10"),
            dayCount: 1,
            now: jst("2026-11-10 23:59:59"),
            staleAfter: 30 * 60
        ).days[0]
        // 30 分: bin 60（10:05）、61（10:15）、62（10:25）、63（10:35 = 30:01 で打ち切り）
        XCTAssertEqual(day.runs, [seg(60, 63, .open), seg(63, 144, .noData)])
    }

    // MARK: - 状態の読み替え（available → open）

    func testAvailableIsReadAsOpen() throws {
        let parsed = try XCTUnwrap(ReceivedEvent(row: [
            "@timestamp": "2026-11-10 01:00:00.000", "deviceId": "x", "status": "available",
        ]))
        XCTAssertEqual(parsed.status, .open)
    }

    func testRowParsing() throws {
        let parsed = try XCTUnwrap(ReceivedEvent(row: [
            "@timestamp": "2026-11-10 01:00:00.250", "deviceId": "x", "status": "full",
        ]))
        XCTAssertEqual(parsed.deviceId, "x")
        XCTAssertEqual(parsed.status, .full)
        // @timestamp は UTC。JST では 10:00:00.250。
        XCTAssertEqual(parsed.receivedAt, jst("2026-11-10 10:00:00.250"))

        // status の行が無い／deviceId が無い／時刻が読めない → nil
        XCTAssertNil(ReceivedEvent(row: ["@timestamp": "2026-11-10 01:00:00.000", "deviceId": "x"]))
        XCTAssertNil(ReceivedEvent(row: ["@timestamp": "2026-11-10 01:00:00.000", "status": "full"]))
        XCTAssertNil(ReceivedEvent(row: ["@timestamp": "garbage", "deviceId": "x", "status": "full"]))
        // 未知の status 文字列は .unknown
        XCTAssertEqual(
            ReceivedEvent(row: ["@timestamp": "2026-11-10 01:00:00.000", "deviceId": "x", "status": "weird"])?.status,
            .unknown
        )
    }

    // MARK: - 同じ秒の重複

    func testSameSecondKeepsLaterMillisecondRegardlessOfOrder() {
        let early = event("2026-11-10 10:00:00.100", .full)
        let late = event("2026-11-10 10:00:00.800", .open)
        for input in [[early, late], [late, early]] {
            let normalized = TimelineAggregator.normalize(input)
            XCTAssertEqual(normalized, [late])
        }
    }

    func testSameSecondOfDifferentDevicesIsNotADuplicate() {
        let day = TimelineAggregator.buildAll(
            events: [
                event("2026-11-10 10:00:00.100", .full, device: "a"),
                event("2026-11-10 10:00:00.200", .open, device: "b"),
            ],
            deviceIds: ["a", "b"],
            firstDay: jstDay("2026-11-10"),
            dayCount: 1,
            now: jst("2026-11-10 23:59:59")
        )
        XCTAssertEqual(day[0].days[0].run(containing: 60)?.state, .full)
        XCTAssertEqual(day[1].days[0].run(containing: 60)?.state, .open)
    }

    func testExactDuplicateRowsEqualSingleRow() {
        let single = buildOneDay([event("2026-11-10 10:05:00", .open)])
        let doubled = buildOneDay([event("2026-11-10 10:05:00", .open), event("2026-11-10 10:05:00", .open)])
        XCTAssertEqual(single, doubled)
    }

    // MARK: - 設置前の除外・欠落率

    func testDaysBeforeFirstReceiptAreNotCounted() {
        // 最初の受信が 11/10 12:03:00、以降 65 分間隔。範囲は 11/1〜11/10。
        var events: [ReceivedEvent] = []
        var cursor = jst("2026-11-10 12:03:00")
        while cursor < jst("2026-11-10 23:59:59") {
            events.append(ReceivedEvent(deviceId: "dev", receivedAt: cursor, status: .open))
            cursor.addTimeInterval(65 * 60)
        }
        let timeline = TimelineAggregator.build(
            deviceId: "dev",
            events: events,
            firstDay: jstDay("2026-11-01"),
            dayCount: 10,
            now: jst("2026-11-10 23:59:59")
        )
        for day in timeline.days.dropLast() {
            XCTAssertEqual(day.runs, [], "\(day.day)")
            XCTAssertEqual(day.countedBins, 0)
            XCTAssertNil(day.noDataRate)
        }
        let last = timeline.days.last!
        XCTAssertEqual(last.runs, [seg(72, 144, .open)]) // 中央 12:05 ≥ 12:03
        XCTAssertEqual(last.countedBins, 72)
        XCTAssertEqual(timeline.noDataBins, 0)
        XCTAssertEqual(timeline.noDataRate, 0)
    }

    func testFirstReceiptJustAfterMidpointStartsNextBin() {
        // 12:07:00 は bin 72（中央 12:05）より後 → bin 73 から。
        let day = buildOneDay([event("2026-11-10 12:07:00", .open)])
        XCTAssertEqual(day.runs.first, seg(73, 82, .open))
        XCTAssertEqual(day.countedBins, 144 - 73)
    }

    func testNoDataRateIsNoDataOverCountedBins() {
        // 00:00:00 の 1 件だけ。bin 0〜8 が open、9〜143 の 135 マスが noData。
        let day = buildOneDay([event("2026-11-10 00:00:00", .open)])
        XCTAssertEqual(day.runs, [seg(0, 9, .open), seg(9, 144, .noData)])
        XCTAssertEqual(day.countedBins, 144)
        XCTAssertEqual(day.noDataBins, 135)
        XCTAssertEqual(day.noDataRate ?? -1, 135.0 / 144.0, accuracy: 1e-12)
    }

    func testUnknownIsNotCountedAsNoData() {
        var events: [ReceivedEvent] = []
        for hour in 0..<24 {
            events.append(event(String(format: "2026-11-10 %02d:00:00", hour), .unknown))
        }
        let day = buildOneDay(events)
        XCTAssertEqual(day.runs, [seg(0, 144, .unknown)])
        XCTAssertEqual(day.noDataBins, 0)
    }

    // MARK: - 未来のマス

    func testFutureBinsAreNotDrawnOrCounted() {
        var events: [ReceivedEvent] = []
        for hour in 0...12 {
            events.append(event(String(format: "2026-11-10 %02d:00:00", hour), .open))
        }
        // now 12:34:59 → 最後の数えるマスは bin 74（中央 12:25）。
        let before = buildOneDay(events, now: "2026-11-10 12:34:59")
        XCTAssertEqual(before.runs, [seg(0, 75, .open)])
        XCTAssertEqual(before.countedBins, 75)
        // now 12:35:00 → bin 75（中央 12:35 ちょうど）を含む。
        let atMid = buildOneDay(events, now: "2026-11-10 12:35:00")
        XCTAssertEqual(atMid.runs, [seg(0, 76, .open)])
        XCTAssertEqual(atMid.countedBins, 76)
    }

    func testDaysAfterNowAreEmpty() {
        let timeline = TimelineAggregator.build(
            deviceId: "dev",
            events: [event("2026-11-10 00:00:00", .open)],
            firstDay: jstDay("2026-11-10"),
            dayCount: 3,
            now: jst("2026-11-10 12:00:00")
        )
        XCTAssertEqual(timeline.days.count, 3)
        XCTAssertEqual(timeline.days[1].runs, [])
        XCTAssertNil(timeline.days[1].noDataRate)
        XCTAssertNil(timeline.days[2].noDataRate)
    }

    // MARK: - JST の日付境界・日またぎ

    func testJSTDayBoundary() {
        // 14:59:59Z は JST の 23:59:59（同日）、15:00:00Z は翌日 00:00:00。
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX")
        utc.timeZone = TimeZone(identifier: "UTC")
        utc.dateFormat = "yyyy-MM-dd HH:mm:ss"
        XCTAssertEqual(JSTDay(date: utc.date(from: "2026-11-10 14:59:59")!), jstDay("2026-11-10"))
        XCTAssertEqual(JSTDay(date: utc.date(from: "2026-11-10 15:00:00")!), jstDay("2026-11-11"))
        XCTAssertEqual(jstDay("2026-11-11").index, jstDay("2026-11-10").index + 1)
        XCTAssertEqual(jstDay("2026-11-10").startDate, jst("2026-11-10 00:00:00"))
    }

    func testRunsAreSplitAtMidnight() {
        let timeline = TimelineAggregator.build(
            deviceId: "dev",
            events: [event("2026-11-10 22:00:00", .open), event("2026-11-10 23:30:00", .open)],
            firstDay: jstDay("2026-11-10"),
            dayCount: 2,
            now: jst("2026-11-11 23:59:59")
        )
        XCTAssertEqual(timeline.days[0].runs, [seg(132, 144, .open)])
        XCTAssertEqual(timeline.days[0].countedBins, 12)
        XCTAssertEqual(timeline.days[1].runs, [seg(0, 6, .open), seg(6, 144, .noData)])
        XCTAssertEqual(timeline.days[1].countedBins, 144)
        XCTAssertEqual(timeline.days[1].noDataBins, 138)
        XCTAssertEqual(timeline.noDataRate ?? -1, 138.0 / 156.0, accuracy: 1e-12)
    }

    func testReceiptBeforeRangeDecidesFirstBins() {
        // 範囲の前日 23:00:00 の受信が、範囲の最初の 90 分の状態を決める。
        let day = buildOneDay([event("2026-11-09 23:00:00", .open)])
        XCTAssertEqual(day.runs, [seg(0, 3, .open), seg(3, 144, .noData)])
        XCTAssertEqual(day.countedBins, 144)
        XCTAssertEqual(day.noDataBins, 141)
    }

    // MARK: - 長期停止（LoRaWAN 2 号機 10/18〜10/29 相当）

    func testLongOutageShowsAsContiguousNoDataBand() {
        // 毎時 xx:40 の open（10/17 00:40〜10/18 05:40）+ 10/29 13:40 の 1 件。
        var events: [ReceivedEvent] = []
        var cursor = jst("2026-10-17 00:40:00")
        while cursor <= jst("2026-10-18 05:40:00") {
            events.append(ReceivedEvent(deviceId: "dev", receivedAt: cursor, status: .open))
            cursor.addTimeInterval(3600)
        }
        events.append(event("2026-10-29 13:40:00", .open))

        let timeline = TimelineAggregator.build(
            deviceId: "dev",
            events: events,
            firstDay: jstDay("2026-10-17"),
            dayCount: 14,
            now: jst("2026-10-30 23:59:59")
        )
        let byDay = Dictionary(uniqueKeysWithValues: timeline.days.map { ($0.day.index, $0) })
        func day(_ s: String) -> DayTimeline { byDay[jstDay(s).index]! }

        XCTAssertEqual(day("2026-10-17").runs, [seg(4, 144, .open)])
        XCTAssertEqual(day("2026-10-17").countedBins, 140)
        XCTAssertEqual(day("2026-10-18").runs, [seg(0, 43, .open), seg(43, 144, .noData)])
        XCTAssertEqual(day("2026-10-18").noDataBins, 101)
        for d in 19...28 {
            let s = "2026-10-\(d)"
            XCTAssertEqual(day(s).runs, [seg(0, 144, .noData)], s)
            XCTAssertEqual(day(s).noDataRate, 1.0, s)
        }
        XCTAssertEqual(day("2026-10-29").runs, [seg(0, 82, .noData), seg(82, 91, .open), seg(91, 144, .noData)])
        XCTAssertEqual(day("2026-10-29").noDataBins, 135)
        XCTAssertEqual(day("2026-10-30").runs, [seg(0, 144, .noData)])
        XCTAssertEqual(timeline.countedBins, 2012)
        XCTAssertEqual(timeline.noDataBins, 1820)
    }

    // MARK: - 入力の形

    func testEmptyOrOtherDeviceOnlyInputYieldsEmptyTimeline() {
        for input in [[], [event("2026-11-10 10:00:00", .open, device: "other")]] {
            let timeline = TimelineAggregator.build(
                deviceId: "dev",
                events: input,
                firstDay: jstDay("2026-11-10"),
                dayCount: 2,
                now: jst("2026-11-11 23:59:59")
            )
            XCTAssertNil(timeline.firstReceivedAt)
            XCTAssertNil(timeline.noDataRate)
            for day in timeline.days {
                XCTAssertEqual(day.runs, [])
                XCTAssertNil(day.noDataRate)
            }
        }
    }

    func testUnorderedAndDuplicatedInputMatchesSortedInput() {
        let sorted = [
            event("2026-11-10 08:00:00", .open),
            event("2026-11-10 09:00:00.100", .full),
            event("2026-11-10 14:00:00", .open),
        ]
        let shuffled = [sorted[2], sorted[0], event("2026-11-10 09:00:00.100", .full), sorted[1], sorted[0]]
        XCTAssertEqual(buildOneDay(sorted), buildOneDay(shuffled))
    }

    func testAdjacentSameStateBinsMerge() {
        let day = buildOneDay([
            event("2026-11-10 10:00:00", .open),
            event("2026-11-10 11:00:00", .open),
        ])
        XCTAssertEqual(day.runs.filter { $0.state == .open }.count, 1)
    }
}
