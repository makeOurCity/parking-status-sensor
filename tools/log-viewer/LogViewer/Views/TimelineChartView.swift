import SwiftUI

/// タイムライン上で選んだ 1 マス。
struct TimelineSelection: Equatable {
    let deviceId: String
    let day: JSTDay
    let bin: Int
}

/// 列の配置。日付の列 + デバイスごとの「プロット（0〜24 時）+ 日別の欠落率バー」。
///
/// 幅は画面の実幅で決める（iPad は Split View でも幅が変わるため、サイズクラスは使わない）。
/// プロット幅が `minPlotWidth` を確保できる台数までを横並びにし、超えるときは 1 台ずつ切り替える。
struct TimelineChartLayout: Equatable {
    static let rowHeight: CGFloat = 14
    static let dayLabelWidth: CGFloat = 48
    static let columnGap: CGFloat = 12
    static let rateGap: CGFloat = 4
    static let rateBarWidth: CGFloat = 14
    static let minPlotWidth: CGFloat = 120

    /// 横並びにする列の数。
    let columnCount: Int
    /// デバイスが多くて 1 台ずつ切り替える表示か。
    let isPaged: Bool
    let plotWidth: CGFloat
    let totalWidth: CGFloat

    init(availableWidth: CGFloat, deviceCount: Int) {
        let count = max(deviceCount, 1)
        let usable = max(availableWidth - Self.dayLabelWidth, 0)
        func plotWidth(forColumns n: Int) -> CGFloat {
            (usable - CGFloat(n - 1) * Self.columnGap) / CGFloat(n) - Self.rateGap - Self.rateBarWidth
        }
        if plotWidth(forColumns: count) >= Self.minPlotWidth {
            columnCount = count
            isPaged = false
        } else {
            columnCount = 1
            isPaged = count > 1
        }
        self.plotWidth = max(plotWidth(forColumns: columnCount), 40)
        self.totalWidth = availableWidth
    }

    var columnWidth: CGFloat { plotWidth + Self.rateGap + Self.rateBarWidth }

    func plotX(column: Int) -> CGFloat {
        Self.dayLabelWidth + CGFloat(column) * (columnWidth + Self.columnGap)
    }

    func rateX(column: Int) -> CGFloat {
        plotX(column: column) + plotWidth + Self.rateGap
    }
}

extension TimelineState {
    var label: String {
        switch self {
        case .full: return "満"
        case .open: return "空"
        case .unknown: return "不明"
        case .noData: return "データなし"
        }
    }
}

/// 縦が日付（古い日が上）、横が 0〜24 時（JST）の満空タイムライン。
///
/// 連続区間にまとめてから `Path` を状態ごとに 1 本にして描くので、図形の数は
/// 日 × デバイス × 数個に収まる。マスの判定は座標からの割り算（`select(at:)`）。
struct TimelineChartView: View {
    let timelines: [DeviceTimeline]
    let layout: TimelineChartLayout
    let titles: [String: String]
    @Binding var selection: TimelineSelection?

    private let dayLabels: [String]
    private let monthStartRows: Set<Int>

    init(timelines: [DeviceTimeline], layout: TimelineChartLayout, titles: [String: String], selection: Binding<TimelineSelection?>) {
        self.timelines = timelines
        self.layout = layout
        self.titles = titles
        self._selection = selection

        let days = timelines.first?.days ?? []
        dayLabels = days.map { JSTTime.dayLabelFormatter.string(from: $0.day.startDate) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        monthStartRows = Set(days.enumerated().compactMap { index, day in
            index > 0 && calendar.component(.day, from: day.day.startDate) == 1 ? index : nil
        })
    }

    private var rowCount: Int { timelines.first?.days.count ?? 0 }
    private var height: CGFloat { CGFloat(rowCount) * TimelineChartLayout.rowHeight }

    var body: some View {
        Canvas { context, size in
            draw(&context, size: size)
        }
        .frame(width: layout.totalWidth, height: height)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { select(at: $0) }
        .onContinuousHover { phase in
            if case .active(let location) = phase { select(at: location) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("満空タイムライン")
        .accessibilityChildren {
            ForEach(timelines) { timeline in
                ForEach(Array(timeline.days.enumerated()), id: \.offset) { index, day in
                    Text(accessibilityText(timeline: timeline, day: day, label: dayLabels[index]))
                }
            }
        }
    }

    // MARK: - Hit testing

    private func select(at location: CGPoint) {
        let rowHeight = TimelineChartLayout.rowHeight
        let row = Int(floor(location.y / rowHeight))
        guard location.y >= 0, row >= 0, row < rowCount else { return }
        for (column, timeline) in timelines.enumerated() {
            let plotX = layout.plotX(column: column)
            guard location.x >= plotX, location.x < plotX + layout.plotWidth else { continue }
            let fraction = (location.x - plotX) / layout.plotWidth
            let bin = min(max(Int(fraction * CGFloat(TimelineAggregator.binsPerDay)), 0), TimelineAggregator.binsPerDay - 1)
            let next = TimelineSelection(deviceId: timeline.deviceId, day: timeline.days[row].day, bin: bin)
            if selection != next { selection = next }
            return
        }
    }

    // MARK: - Drawing

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let rowHeight = TimelineChartLayout.rowHeight
        let binsPerDay = CGFloat(TimelineAggregator.binsPerDay)
        let plotWidth = layout.plotWidth

        // 日付ラベル
        for (row, label) in dayLabels.enumerated() {
            let text = context.resolve(
                Text(label).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
            )
            context.draw(
                text,
                at: CGPoint(x: TimelineChartLayout.dayLabelWidth - 6, y: (CGFloat(row) + 0.5) * rowHeight),
                anchor: .trailing
            )
        }

        for (column, timeline) in timelines.enumerated() {
            let plotX = layout.plotX(column: column)

            // 地（設置前・未来は何も描かないので、この地がそのまま見える）
            context.fill(
                Path(roundedRect: CGRect(x: plotX, y: 0, width: plotWidth, height: size.height), cornerRadius: 3),
                with: .color(.primary.opacity(0.05))
            )

            // 6 / 12 / 18 時の目盛り
            var grid = Path()
            for hour in [6, 12, 18] {
                let x = plotX + plotWidth * CGFloat(hour) / 24
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            context.stroke(grid, with: .color(.primary.opacity(0.10)), lineWidth: 0.5)

            // 区間（状態ごとに Path を 1 本にまとめる）
            var paths: [TimelineState: Path] = [:]
            for (row, day) in timeline.days.enumerated() {
                for run in day.runs {
                    let rect = CGRect(
                        x: plotX + plotWidth * CGFloat(run.startBin) / binsPerDay,
                        y: CGFloat(row) * rowHeight + 1.5,
                        width: plotWidth * CGFloat(run.binCount) / binsPerDay,
                        height: rowHeight - 3
                    )
                    paths[run.state, default: Path()].addRect(rect)
                }
            }
            for state in [TimelineState.full, .open, .unknown] {
                if let path = paths[state] {
                    context.fill(path, with: .color(state.color))
                }
            }
            if let noData = paths[.noData] {
                // 淡い地 + 斜線 + 枠。灰色の実色（不明）と色覚に頼らず区別できる。
                context.fill(noData, with: .color(Theme.noDataFill))
                context.drawLayer { layer in
                    layer.clip(to: noData)
                    var hatch = Path()
                    var x = plotX - size.height
                    while x < plotX + plotWidth {
                        hatch.move(to: CGPoint(x: x, y: size.height))
                        hatch.addLine(to: CGPoint(x: x + size.height, y: 0))
                        x += 4
                    }
                    layer.stroke(hatch, with: .color(Theme.noDataHatch), lineWidth: 0.75)
                }
                context.stroke(noData, with: .color(Theme.noDataBorder), lineWidth: 0.75)
            }

            // 選択中の区間
            if let selection, selection.deviceId == timeline.deviceId,
               let row = timeline.days.firstIndex(where: { $0.day == selection.day }),
               let run = timeline.days[row].run(containing: selection.bin) {
                let rect = CGRect(
                    x: plotX + plotWidth * CGFloat(run.startBin) / binsPerDay,
                    y: CGFloat(row) * rowHeight + 0.5,
                    width: max(plotWidth * CGFloat(run.binCount) / binsPerDay, 2),
                    height: rowHeight - 1
                )
                context.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(.primary), lineWidth: 1.5)
            }

            // 日別の欠落率（長さ = 率）
            let rateX = layout.rateX(column: column)
            for (row, day) in timeline.days.enumerated() {
                guard let rate = day.noDataRate else { continue }
                let y = CGFloat(row) * rowHeight + 4
                let barHeight = rowHeight - 8
                context.fill(
                    Path(CGRect(x: rateX, y: y, width: TimelineChartLayout.rateBarWidth, height: barHeight)),
                    with: .color(.primary.opacity(0.06))
                )
                if rate > 0 {
                    context.fill(
                        Path(CGRect(x: rateX, y: y, width: max(TimelineChartLayout.rateBarWidth * rate, 1), height: barHeight)),
                        with: .color(Theme.warning)
                    )
                }
            }
        }

        // 月初の区切り
        var monthLines = Path()
        for row in monthStartRows {
            let y = CGFloat(row) * rowHeight
            monthLines.move(to: CGPoint(x: 0, y: y))
            monthLines.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(
            monthLines,
            with: .color(.primary.opacity(0.35)),
            style: StrokeStyle(lineWidth: 0.5, dash: [3, 3])
        )
    }

    // MARK: - Accessibility

    private func accessibilityText(timeline: DeviceTimeline, day: DayTimeline, label: String) -> String {
        let title = titles[timeline.deviceId] ?? timeline.deviceId
        guard !day.runs.isEmpty else { return "\(label)、\(title)。対象外" }
        let runs = day.runs.map { run in
            "\(JSTTime.clockLabel(minutesOfDay: run.startBin * 10))から\(JSTTime.clockLabel(minutesOfDay: run.endBin * 10))まで\(run.state.label)"
        }.joined(separator: "、")
        let rate = day.noDataRate.map { "。欠落率 \(Int(($0 * 100).rounded()))パーセント" } ?? ""
        return "\(label)、\(title)。\(runs)\(rate)"
    }
}

extension TimelineState {
    var color: Color {
        switch self {
        case .full: return Theme.full
        case .open: return Theme.available
        case .unknown: return Theme.unknown
        case .noData: return Theme.noDataFill
        }
    }
}
