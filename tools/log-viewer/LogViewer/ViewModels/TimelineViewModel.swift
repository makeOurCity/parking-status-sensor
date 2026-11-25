import Foundation

enum TimelinePeriod: Int, CaseIterable, Identifiable {
    case days14 = 14
    case days30 = 30
    case days60 = 60

    var id: Int { rawValue }
    var label: String { "\(rawValue)日" }
}

/// 満空タイムライン画面（#132）の状態。
///
/// スキャン量（#77）のため、**自動更新はしない**。読み込むのは「画面を開いたとき」と
/// 「手動更新」だけ。取得は常に最大期間（60 日）で、14/30/60 日の切り替えは取得済みデータの
/// 切り出しだけ（通信しない）。再読み込みは前回の最終受信以降だけを取る（`ReceivedEventCache`）。
///
/// ダッシュボードが保持するので、画面を閉じて開き直しても取得済みデータが残る。
@MainActor
final class TimelineViewModel: ObservableObject {
    /// 取得する最大の日数（今日を含む）。
    static let maxDays = TimelinePeriod.days60.rawValue
    /// 画面を開いたときの再読み込みを抑える時間（戻る・進むの連打対策）。
    static let reopenSuppression: TimeInterval = 60

    @Published private(set) var timelines: [DeviceTimeline] = []
    @Published private(set) var lastFetchedAt: Date?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var period: TimelinePeriod = .days30 {
        didSet { if oldValue != period { recompute() } }
    }

    private let service: CloudWatchLogsService
    private var cache = ReceivedEventCache()
    private var masterIds: Set<String> = []
    private var activeIds: [String] = []
    private var inFlight: Task<Void, Never>?

    init(auth: CognitoAuthService) {
        self.service = CloudWatchLogsService(auth: auth)
    }

    /// 画面を開いたとき。前回の取得から `reopenSuppression` 以内なら通信しない。
    func loadIfNeeded(masterIds: Set<String>, activeIds: [String]) async {
        setDevices(masterIds: masterIds, activeIds: activeIds)
        if let lastFetchedAt, Date().timeIntervalSince(lastFetchedAt) < Self.reopenSuppression {
            recompute()
            return
        }
        await fetch()
    }

    /// 手動更新。常に差分を取りに行く。
    func refresh(masterIds: Set<String>, activeIds: [String]) async {
        setDevices(masterIds: masterIds, activeIds: activeIds)
        await fetch()
    }

    private func setDevices(masterIds: Set<String>, activeIds: [String]) {
        self.masterIds = masterIds
        self.activeIds = activeIds
    }

    /// 取得中に呼ばれたら、実行中の取得の完了を待つ（黙って捨てない）。待った取得が失敗していたときだけ、
    /// 続けてもう 1 回取りに行く。取得は呼び出し元の Task とは独立に走らせるので、画面を離れても
    /// 完了して取得済みデータに入り、開き直したときにそのまま使える。
    private func fetch() async {
        if let running = inFlight {
            await running.value
            if errorMessage == nil { return }
        }
        guard inFlight == nil else { return }
        let task = Task { [weak self] in
            await self?.performFetch()
            self?.inFlight = nil
        }
        inFlight = task
        await task.value
    }

    private func performFetch() async {
        isLoading = true
        errorMessage = nil
        let now = Date()
        let windowStart = Self.windowStart(now: now)
        let range = cache.nextFetchRange(now: now, windowStart: windowStart)
        do {
            let events = try await service.fetchReceivedEvents(from: range.start, to: range.end)
            // 全ページ成功したときだけキャッシュに入れる（失敗時は前回のデータを保つ）。
            cache.merge(events, through: range.end)
            cache.trim(before: windowStart)
            lastFetchedAt = now
        } catch {
            if !isCancellationError(error) {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
        recompute(now: now)
    }

    /// 取得済みのデータから、表示期間の集計を作り直す（通信なし）。
    func recompute(now: Date = Date()) {
        let deviceIds = TimelineDeviceSelector.select(
            masterIds: masterIds,
            activeIds: activeIds,
            eventDeviceIds: cache.deviceIds
        )
        let today = JSTDay(date: now)
        timelines = TimelineAggregator.buildAll(
            events: cache.allEvents,
            deviceIds: deviceIds,
            firstDay: today.adding(days: -(period.rawValue - 1)),
            dayCount: period.rawValue,
            now: Self.dataHorizon(now: now, fetchedThrough: cache.fetchedThrough)
        )
    }

    /// 集計に使う「現在時刻」。取得済みのデータは `fetchedThrough` までなので、それより先の
    /// マスを描くと、受信があっても「データなし」になってしまう（取得後に画面を開いたまま
    /// 期間を切り替えたときなど）。取得後の時間帯は、次の更新まで描かない。
    static func dataHorizon(now: Date, fetchedThrough: Date?) -> Date {
        guard let fetchedThrough else { return now }
        return min(now, fetchedThrough)
    }

    /// 取得の開始時刻: 最大期間の最初の日の 0:00（JST）の `offlineThreshold` 前。
    /// 最初の日の最初のマスの状態を、範囲前の受信から決めるための余白。
    static func windowStart(now: Date) -> Date {
        JSTDay(date: now).adding(days: -(maxDays - 1)).startDate
            .addingTimeInterval(-AWSConfig.offlineThreshold)
    }
}
