import SwiftUI

/// ダッシュボードから満空タイムライン画面へ遷移する値（`deviceId` の `String` と衝突しない型）。
struct TimelineRoute: Hashable {}

/// ダッシュボードの入口カード。
struct TimelineEntryCard: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar.day.timeline.left")
                .font(.title3)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("満空タイムライン")
                    .font(.headline)
                Text("日 × 時刻で満空を振り返り、データなしの欠落率を見る")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .cardStyle()
        .accessibilityElement(children: .combine)
    }
}

/// `TimelineViewModel` に結んだ画面。
struct TimelineView: View {
    @ObservedObject var viewModel: TimelineViewModel
    let names: DeviceNames
    /// ダッシュボードが持っている機体（直近 3 日に受信があるもの）。
    let activeIds: [String]

    private var masterIds: Set<String> { Set(names.names.keys) }

    var body: some View {
        TimelineScreen(
            timelines: viewModel.timelines,
            names: names,
            period: $viewModel.period,
            isLoading: viewModel.isLoading,
            errorMessage: viewModel.errorMessage,
            lastFetchedAt: viewModel.lastFetchedAt,
            onRefresh: { await viewModel.refresh(masterIds: masterIds, activeIds: activeIds) }
        )
        // 自動更新（autoRefreshing）は付けない。開いたときと手動更新だけで読む（#77）。
        .task { await viewModel.loadIfNeeded(masterIds: masterIds, activeIds: activeIds) }
    }
}

/// 満空タイムラインの表示部。データの取得には関与しない（デモ・プレビューからも使う）。
struct TimelineScreen: View {
    let timelines: [DeviceTimeline]
    let names: DeviceNames
    @Binding var period: TimelinePeriod
    let isLoading: Bool
    let errorMessage: String?
    let lastFetchedAt: Date?
    let onRefresh: () async -> Void

    @State private var selection: TimelineSelection?
    @State private var pickedDeviceId: String?

    init(
        timelines: [DeviceTimeline],
        names: DeviceNames,
        period: Binding<TimelinePeriod>,
        isLoading: Bool,
        errorMessage: String?,
        lastFetchedAt: Date?,
        onRefresh: @escaping () async -> Void,
        initialSelection: TimelineSelection? = nil
    ) {
        self.timelines = timelines
        self.names = names
        self._period = period
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.lastFetchedAt = lastFetchedAt
        self.onRefresh = onRefresh
        self._selection = State(initialValue: initialSelection)
    }

    private static let chartBottomID = "timeline-chart-bottom"

    private func title(of deviceId: String) -> String { names.name(for: deviceId) ?? deviceId }

    var body: some View {
        GeometryReader { geometry in
            let layout = TimelineChartLayout(availableWidth: geometry.size.width - 32, deviceCount: timelines.count)
            let shown = shownTimelines(layout: layout)
            VStack(alignment: .leading, spacing: 10) {
                controls
                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(Theme.full)
                        .cardStyle()
                }
                if layout.isPaged {
                    devicePicker
                }
                if !shown.isEmpty {
                    headerRow(shown: shown, layout: layout)
                    readout(shown: shown)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if shown.isEmpty {
                                emptyState
                            } else {
                                TimelineChartView(
                                    timelines: shown,
                                    layout: layout,
                                    titles: Dictionary(uniqueKeysWithValues: shown.map { ($0.deviceId, title(of: $0.deviceId)) }),
                                    selection: $selection
                                )
                                // 最新の日が見える位置で開く（内容が短いときは動かない）。
                                Color.clear.frame(height: 0).id(Self.chartBottomID)
                            }
                            caption
                        }
                        .padding(.bottom, 24)
                    }
                    .refreshable { await onRefresh() }
                    .onAppear { proxy.scrollTo(Self.chartBottomID, anchor: .bottom) }
                    .onChange(of: period) { _, _ in
                        proxy.scrollTo(Self.chartBottomID, anchor: .bottom)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("満空タイムライン")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isLoading {
                    ProgressView()
                } else {
                    Button {
                        Task { await onRefresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("更新")
                }
            }
        }
        .onChange(of: period) { _, _ in selection = nil }
    }

    // MARK: - Pieces

    private func shownTimelines(layout: TimelineChartLayout) -> [DeviceTimeline] {
        guard layout.isPaged else { return timelines }
        let picked = timelines.first { $0.deviceId == pickedDeviceId } ?? timelines.first
        return picked.map { [$0] } ?? []
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("期間", selection: $period) {
                ForEach(TimelinePeriod.allCases) { period in
                    Text(period.label).tag(period)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                LegendItem(label: "満") { RoundedRectangle(cornerRadius: 2).fill(Theme.full) }
                LegendItem(label: "空") { RoundedRectangle(cornerRadius: 2).fill(Theme.available) }
                LegendItem(label: "不明") { RoundedRectangle(cornerRadius: 2).fill(Theme.unknown) }
                LegendItem(label: "データなし") { NoDataSwatch() }
                Spacer(minLength: 0)
            }
        }
    }

    private var devicePicker: some View {
        Picker("デバイス", selection: Binding(
            get: { pickedDeviceId ?? timelines.first?.deviceId ?? "" },
            set: { pickedDeviceId = $0; selection = nil }
        )) {
            ForEach(timelines) { timeline in
                Text(title(of: timeline.deviceId)).tag(timeline.deviceId)
            }
        }
        .pickerStyle(.menu)
    }

    private func headerRow(shown: [DeviceTimeline], layout: TimelineChartLayout) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Color.clear.frame(width: TimelineChartLayout.dayLabelWidth, height: 1)
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, timeline in
                VStack(alignment: .leading, spacing: 2) {
                    // 駐車場名（#108）を見出しに、deviceId は補助。未登録なら deviceId だけ。
                    let name = names.name(for: timeline.deviceId)
                    Text(name ?? timeline.deviceId)
                        .font(name == nil ? .caption.weight(.bold).monospaced() : .caption.weight(.bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    // 名前が無いときも 1 行分の高さを確保して、列ごとの時刻軸の高さを揃える。
                    Text(name == nil ? " " : timeline.deviceId)
                        .font(.system(size: 9).monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    rateLabel(for: timeline)
                    hourAxis(plotWidth: layout.plotWidth)
                }
                .frame(width: layout.columnWidth, alignment: .leading)
                .padding(.leading, index == 0 ? 0 : TimelineChartLayout.columnGap)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func rateLabel(for timeline: DeviceTimeline) -> some View {
        Group {
            if let rate = timeline.noDataRate {
                Text("欠落 \(String(format: "%.1f", rate * 100))%")
                    .foregroundStyle(rate > 0 ? Theme.warning : Color.secondary)
            } else {
                Text("欠落 —").foregroundStyle(.secondary)
            }
        }
        .font(.caption2.weight(.semibold).monospacedDigit())
    }

    private func hourAxis(plotWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                Text("\(hour)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .position(x: plotWidth * CGFloat(hour) / 24, y: 6)
            }
        }
        .frame(width: plotWidth, height: 12, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    /// 選んだマスの読み出し。指で隠れないよう、固定の行に出す。
    private func readout(shown: [DeviceTimeline]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let selection,
               let timeline = shown.first(where: { $0.deviceId == selection.deviceId }),
               let day = timeline.days.first(where: { $0.day == selection.day }) {
                let name = title(of: timeline.deviceId)
                if let run = day.run(containing: selection.bin),
                   let span = timeline.continuousSpan(of: run, onDay: day.day) {
                    HStack(spacing: 6) {
                        Text(name).font(.footnote.weight(.semibold))
                        Text(run.state.label)
                            .font(.footnote.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(run.state == .noData ? Theme.noDataFill : run.state.color.opacity(0.25)))
                    }
                    let minutes = Int(span.end.timeIntervalSince(span.start) / 60)
                    // 区間が表示期間の先頭で切れているときは、その前から続くことを示す。
                    let continuesBefore = span.start == timeline.days.first?.day.startDate
                    Text("\(continuesBefore ? "（これ以前から）" : "")\(JSTTime.dayTimeFormatter.string(from: span.start)) 〜 \(JSTTime.dayTimeFormatter.string(from: span.end))（\(continuesBefore ? "表示期間内で " : "")\(JSTTime.durationLabel(minutes: minutes))）")
                        .font(.footnote.monospacedDigit())
                } else {
                    Text(name).font(.footnote.weight(.semibold))
                    Text("\(JSTTime.dayLabelFormatter.string(from: day.day.startDate)) \(JSTTime.clockLabel(minutesOfDay: selection.bin * 10)) は設置前、または未来のため対象外です")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let rate = day.noDataRate {
                    Text("この日の欠落率 \(String(format: "%.1f", rate * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("マスをタップ（iPad はポインタを重ねる）すると、時刻と状態を表示します。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
    }

    private var emptyState: some View {
        Text(isLoading ? "読み込み中…" : "表示できるデバイスがありません。下に引いて更新してください。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160)
            .cardStyle()
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("1 マス 10 分。最後の受信から 90 分を超えるとデータなし。時刻は受信時刻（JST）です。")
            Text("欠落率 = データなし ÷ 全マス（設置前を除く）。")
            Text("駐車場名はデバイスマスターの現在の対応です。センサーを付け替えた機体の過去分も、現在の名前で表示します。")
            Text("期間内に受信が無い機体は表示しません。")
            if let lastFetchedAt {
                Text("最終取得 \(JSTTime.shortDateTimeFormatter.string(from: lastFetchedAt))")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

private struct LegendItem<Swatch: View>: View {
    let label: String
    @ViewBuilder let swatch: () -> Swatch

    var body: some View {
        HStack(spacing: 4) {
            swatch().frame(width: 14, height: 10)
            Text(label).font(.caption2)
        }
    }
}

/// 凡例用の「データなし」見本（斜線 + 枠）。
private struct NoDataSwatch: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.4, dy: 0.4)
            let path = Path(rect)
            context.fill(path, with: .color(Theme.noDataFill))
            context.drawLayer { layer in
                layer.clip(to: path)
                var hatch = Path()
                var x = -size.height
                while x < size.width {
                    hatch.move(to: CGPoint(x: x, y: size.height))
                    hatch.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += 4
                }
                layer.stroke(hatch, with: .color(Theme.noDataHatch), lineWidth: 0.75)
            }
            context.stroke(path, with: .color(Theme.noDataBorder), lineWidth: 0.75)
        }
    }
}
