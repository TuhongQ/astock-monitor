import Foundation
import AppKit

@MainActor final class MonitorStore: ObservableObject {
    @Published var quotes: [Quote] = [] {
        didSet {
            quoteIndex = Dictionary(quotes.map { ($0.code, $0) }, uniquingKeysWith: { _, latest in latest })
            refreshMenuBarQuoteCache()
            invalidateVisibleQuotes()
            cachedConceptOptions = nil
        }
    }
    @Published var alerts: [AlertRecord] = AppFiles.read([AlertRecord].self, name: "alerts.json", fallback: []) { didSet { AppFiles.write(alerts, name: "alerts.json") } }
    @Published private(set) var alertLogTradingDays: [Date] = []
    @Published private(set) var alertToast: AlertToast?
    /// 持仓与卖点提醒（holdings.json / sell-signals.json）。
    @Published var holdings: [Holding] = AppFiles.read([Holding].self, name: "holdings.json", fallback: []) { didSet { AppFiles.write(holdings, name: "holdings.json") } }
    @Published var sellSignals: [SellSignal] = AppFiles.read([SellSignal].self, name: "sell-signals.json", fallback: []) { didSet { AppFiles.write(sellSignals, name: "sell-signals.json") } }
    @Published var sellAlertsEnabled: Bool = UserDefaults.standard.object(forKey: "sellAlertsEnabled") as? Bool ?? true { didSet { UserDefaults.standard.set(sellAlertsEnabled, forKey: "sellAlertsEnabled") } }
    /// 未处理的卖出提醒，驱动置顶弹窗。
    var pendingSellSignals: [SellSignal] { sellSignals.filter { !$0.acknowledged } }
    /// Alerts raised since the user last opened the alert log (tab badge).
    @Published private(set) var unseenAlertCount = 0
    @Published var watch: WatchData = AppFiles.read(WatchData.self, name: "watchlist.json", fallback: WatchData()) {
        didSet {
            if oldValue.conceptsByCode != watch.conceptsByCode { conceptsRevision &+= 1 }
            AppFiles.write(watch, name: "watchlist.json")
            UserDefaults.standard.set(watch.menuBarCodes, forKey: "menuBarCodes.v1")
            refreshMenuBarQuoteCache()
            invalidateVisibleQuotes()
            cachedConceptOptions = nil
        }
    }
    /// Changes only when the persisted concept mapping changes; the quote table
    /// uses it to avoid rebuilding thousands of concept strings every refresh.
    private(set) var conceptsRevision = 0
    @Published private(set) var menuBarQuoteCache: [String: Quote] = {
        guard let data = UserDefaults.standard.data(forKey: "menuBarQuoteCache.v1"),
              let quotes = try? JSONDecoder().decode([String: Quote].self, from: data) else { return [:] }
        return quotes
    }()
    @Published var settings: MonitorSettings = AppFiles.read(MonitorSettings.self, name: "settings.json", fallback: MonitorSettings()) { didSet { AppFiles.write(settings, name: "settings.json"); invalidateVisibleQuotes() } }
    @Published var filters: FilterCriteria = AppFiles.read(FilterCriteria.self, name: "filters.json", fallback: FilterCriteria()) { didSet { AppFiles.write(filters, name: "filters.json"); invalidateVisibleQuotes() } }
    @Published var status = "等待本地 AkShare 服务"
    @Published var indexQuotes: [MarketIndex] = []
    @Published var indexQuotesUpdatedAt: Date?
    @Published var lastUpdate: Date?
    @Published var selectedCode: String?
    @Published var sortKey = "changePercent" { didSet { invalidateVisibleQuotes() } }
    @Published var ascending = false { didSet { invalidateVisibleQuotes() } }
    @Published var search = "" { didSet { invalidateVisibleQuotes() } }
    @Published var industryFilter = "全部行业" { didSet { invalidateVisibleQuotes() } }
    @Published var conceptFilter = "全部概念" { didSet { invalidateVisibleQuotes() } }
    @Published var boardFilter = "全部板块" { didSet { invalidateVisibleQuotes() } }
    @Published var provider = UserDefaults.standard.string(forKey: "quoteProvider") ?? "auto" {
        didSet { UserDefaults.standard.set(provider, forKey: "quoteProvider") }
    }
    private let service = MarketService.shared
    private let bridge = LocalBridgeManager()
    private var timer: Timer?
    private var monitoringActive = false
    private var isRefreshing = false
    private var refreshSequence = 0
    private var skippedRefreshTicks = 0
    private var latestSnapshotTimestamp: Date?
    private var intradayHistory: [String: [PricePoint]] = [:]
    /// Cooldown is tracked independently for daily-target and 10-second alerts.
    private var lastAlert: [String: Date] = [:]
    private var toastQueue: [AlertToast] = []
    private var toastTask: Task<Void, Never>?
    private var averageVolumes: [String: Double] = [:]
    private var cachedVisibleQuotes: [Quote]?
    /// O(1) lookup used by the watchlist, status bar and detail windows instead
    /// of scanning ~5,000 quotes for every row on every refresh.
    private var quoteIndex: [String: Quote] = [:]
    /// Last observed limit-up / limit-down state per code, for sealed / opened alerts.
    private var limitUpState: [String: Bool] = [:]
    private var limitDownState: [String: Bool] = [:]
    /// Per trading day: codes already logged as sealed / limit-down, restored from
    /// the alert log so an app restart does not log the same board twice.
    private var sealedToday: Set<String> = []
    private var limitDownToday: Set<String> = []
    private var limitDayKey = ""
    @Published private(set) var potentialReport: PotentialReport?
    /// 个股分析 page state.
    @Published var analysisQuery = ""
    @Published private(set) var analysis: StockAnalysis?
    @Published private(set) var analysisLoading = false
    @Published private(set) var analysisError: String?
    @Published private(set) var analysisHistory: [String] = UserDefaults.standard.stringArray(forKey: "analysis.history") ?? []
    private var analysisTask: Task<Void, Never>?

    /// Run /analyze for a code or name; remembers the last 12 analysed stocks.
    func analyze(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        analysisQuery = query
        analysisTask?.cancel()
        analysisLoading = true
        analysisError = nil
        let currentProvider = provider
        analysisTask = Task {
            do {
                let result = try await service.fetchAnalysis(query: query, provider: currentProvider)
                guard !Task.isCancelled else { return }
                analysis = result
                if result.error == nil, let code = result.code, let name = result.name {
                    let entry = "\(code) \(name)"
                    analysisHistory = [entry] + analysisHistory.filter { $0 != entry }.prefix(11)
                    UserDefaults.standard.set(analysisHistory, forKey: "analysis.history")
                    DebugLog.write("个股分析 \(entry)：指数 \(result.index ?? -1)，\(result.verdict ?? "")")
                }
            } catch {
                guard !Task.isCancelled else { return }
                analysisError = error.localizedDescription
            }
            analysisLoading = false
        }
    }
    @Published private(set) var potentialError: String?
    private var potentialRequestInFlight = false
    private var lastPotentialRequest = Date.distantPast
    private var lastOvernightTrack = Date.distantPast
    private var overnightTrackInFlight = false
    private var cachedConceptOptions: [String]?

    init() {
        bridge.onProgress = { [weak self] message in
            self?.status = message
            DebugLog.write("行情服务准备：\(message)")
        }
        restoreAlertLogRetention()
        restoreLimitDayState(for: Date())
        // watchlist.json is the canonical store. UserDefaults is only a legacy
        // migration source for installations created before the JSON field existed;
        // allowing an old empty defaults array to overwrite the JSON caused items
        // to disappear after relaunch.
        if !AppFiles.contains("watchlist.json"), let savedCodes = UserDefaults.standard.stringArray(forKey: "menuBarCodes.v1") {
            var seen = Set<String>()
            let normalizedCodes = savedCodes.filter { $0.count == 6 && $0.allSatisfy(\.isNumber) && seen.insert($0).inserted }
            if watch.menuBarCodes != normalizedCodes {
                watch.menuBarCodes = normalizedCodes
                AppFiles.write(watch, name: "watchlist.json")
            }
        } else {
            UserDefaults.standard.set(watch.menuBarCodes, forKey: "menuBarCodes.v1")
        }
        DebugLog.write("启动恢复状态栏列表：来源=watchlist.json, 股票=\(watch.menuBarCodes.joined(separator: ",")), 缓存行情=\(menuBarQuoteCache.count) 只")

        // The bridge now reads Eastmoney / Tencent directly (~0.5 s per full-market
        // snapshot instead of ~7 s), and exchange Level-1 snapshots update about every
        // 3 s. Move the old 10-second default to 3 seconds once.
        if !UserDefaults.standard.bool(forKey: "refresh.fastFeed.v1") {
            UserDefaults.standard.set(true, forKey: "refresh.fastFeed.v1")
            if settings.refreshSeconds == 10 {
                settings.refreshSeconds = 3
                DebugLog.write("刷新间隔改为 3 秒：已切换直连快照（全市场约 0.5 秒）")
            }
        }
        if settings.refreshSeconds < 3 { settings.refreshSeconds = 3 }
    }

    private func restoreAlertLogRetention() {
        let storedEpochs = UserDefaults.standard.array(forKey: "alertLogTradingDays.v1") as? [Double] ?? []
        let storedDays = storedEpochs.map { Calendar.current.startOfDay(for: Date(timeIntervalSince1970: $0)) }
        let loggedDays = alerts.map { Calendar.current.startOfDay(for: $0.time) }
        let recentDays = Array(Set((storedDays + loggedDays).filter(isWeekday)).sorted().suffix(5))
        alertLogTradingDays = recentDays
        persistAlertLogTradingDays()
        pruneAlerts(to: recentDays)
    }

    private func observeAlertLogTradingDay(at date: Date) {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = components.weekday, (2...6).contains(weekday),
              let hour = components.hour, let minute = components.minute else { return }
        let minuteOfDay = hour * 60 + minute
        // Count days only when the app receives market snapshots during the
        // mainland A-share trading session (weekends and overnight refreshes do not count).
        guard (570...900).contains(minuteOfDay) else { return }
        let day = calendar.startOfDay(for: date)
        guard !alertLogTradingDays.contains(where: { calendar.isDate($0, inSameDayAs: day) }) else { return }
        alertLogTradingDays = Array(Set(alertLogTradingDays + [day]).sorted().suffix(5))
        persistAlertLogTradingDays()
        pruneAlerts(to: alertLogTradingDays)
        DebugLog.write("告警日志交易日保留更新：\(alertLogTradingDays.map { $0.formatted(date: .numeric, time: .omitted) }.joined(separator: ","))")
    }

    private func restoreLimitDayState(for date: Date) {
        let key = tradingDayKey(date)
        guard key != limitDayKey else { return }
        limitDayKey = key
        let todays = alerts.filter { tradingDayKey($0.time) == key }
        sealedToday = Set(todays.filter { ["limitUp", "limitReseal", "limitOpen"].contains($0.alertType ?? "") }.map(\.code))
        limitDownToday = Set(todays.filter { $0.alertType == "limitDown" }.map(\.code))
    }

    private func tradingDayKey(_ date: Date) -> String {
        let parts = aStockCalendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }

    func markAlertsSeen() { if unseenAlertCount != 0 { unseenAlertCount = 0 } }

    /// Today's limit-up board computed from the live snapshot: sealed / opened
    /// counts, the streak ladder and the industries with the most limit-ups.
    var limitSummary: LimitSummary {
        var sealed = 0, opened = 0, maxStreak = 0, down = 0
        var byIndustry: [String: Int] = [:]
        for q in quotes where !q.isST && !q.suspended {
            if q.upperLimit {
                sealed += 1
                maxStreak = max(maxStreak, q.limitStreak ?? 1)
                if let industry = q.industry ?? q.limitIndustry, !industry.isEmpty { byIndustry[industry, default: 0] += 1 }
            } else if let limit = q.limitUpPrice, let high = q.high, high >= limit - 0.005 {
                opened += 1
            }
            if q.lowerLimit { down += 1 }
        }
        let industries = byIndustry.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(6).map { ($0.key, $0.value) }
        let touched = sealed + opened
        return LimitSummary(sealed: sealed, opened: opened, limitDown: down, maxStreak: maxStreak,
                            brokenRate: touched > 0 ? Double(opened) / Double(touched) * 100 : nil,
                            topIndustries: industries)
    }

    private func isWeekday(_ date: Date) -> Bool {
        (2...6).contains(Calendar.current.component(.weekday, from: date))
    }

    private func persistAlertLogTradingDays() {
        UserDefaults.standard.set(alertLogTradingDays.map(\.timeIntervalSince1970), forKey: "alertLogTradingDays.v1")
    }

    private func pruneAlerts(to tradingDays: [Date]) {
        let calendar = Calendar.current
        let retained = Set(tradingDays.map { calendar.startOfDay(for: $0) })
        let pruned = alerts.filter { retained.contains(calendar.startOfDay(for: $0.time)) }
        guard pruned.count != alerts.count else { return }
        DebugLog.write("清理过期告警日志：删除 \(alerts.count - pruned.count) 条，保留 \(pruned.count) 条 / \(retained.count) 个交易日")
        alerts = pruned
    }

    private func refreshMenuBarQuoteCache() {
        let selectedCodes = Set(watch.menuBarCodes)
        var updated = menuBarQuoteCache.filter { selectedCodes.contains($0.key) }
        for quote in quotes where selectedCodes.contains(quote.code) {
            updated[quote.code] = quote
        }
        guard updated != menuBarQuoteCache else { return }
        menuBarQuoteCache = updated
        if let data = try? JSONEncoder().encode(updated) {
            UserDefaults.standard.set(data, forKey: "menuBarQuoteCache.v1")
        }
        DebugLog.write("状态栏行情缓存更新：\(updated.keys.sorted().joined(separator: ","))")
    }

    var visibleQuotes: [Quote] {
        if let cachedVisibleQuotes { return cachedVisibleQuotes }
        let result = quotes.filter { q in
            if search.caseInsensitiveCompare(q.code) == .orderedSame { return true }
            return (!settings.filterST || !q.isST) && (!settings.filterSuspended || !q.suspended) &&
            (search.isEmpty || q.code.localizedCaseInsensitiveContains(search) || q.name.localizedCaseInsensitiveContains(search)) &&
            (boardFilter == "全部板块" || q.board == boardFilter) &&
            (industryFilter == "全部行业" || q.industry == industryFilter) &&
            (conceptFilter == "全部概念" || (watch.conceptsByCode[q.code] ?? []).contains(conceptFilter) || (q.concept?.localizedCaseInsensitiveContains(conceptFilter) ?? false)) &&
            passesDirection(q) &&
            passesNumericFilters(q)
        }.sorted { lhs, rhs in
            if sortKey == "code" { return ascending ? lhs.code < rhs.code : lhs.code > rhs.code }
            if sortKey == "name" { return ascending ? lhs.name < rhs.name : lhs.name > rhs.name }
            if sortKey == "industry" { return ascending ? (lhs.industry ?? "") < (rhs.industry ?? "") : (lhs.industry ?? "") > (rhs.industry ?? "") }
            if sortKey == "concept" {
                let a = concepts(for: lhs.code).joined(separator: "、"), b = concepts(for: rhs.code).joined(separator: "、")
                return ascending ? a < b : a > b
            }
            let a = sortValue(lhs), b = sortValue(rhs)
            return ascending ? a < b : a > b
        }
        cachedVisibleQuotes = result
        return result
    }
    private func invalidateVisibleQuotes() { cachedVisibleQuotes = nil }
    private func passesDirection(_ q: Quote) -> Bool {
        switch filters.direction {
        case "上涨": return q.changePercent > 0
        case "下跌": return q.changePercent < 0
        case "涨停":
            if q.upperLimit { return true }
            guard let limit = q.limitUpPrice, let high = q.high else { return false }
            return high >= limit - 0.005
        default: return true
        }
    }
    var industries: [String] { ["全部行业"] + StockCategories.industries }
    var hasIndustryData: Bool { quotes.contains { !($0.industry ?? "").isEmpty } }
    /// Blend built-in popular concepts with every concept actually returned by
    /// the live classification feed, so the selector does not hide other tags.
    var concepts: [String] {
        if let cachedConceptOptions { return cachedConceptOptions }
        var values = Set(StockCategories.concepts)
        for quote in quotes {
            for item in (quote.concept ?? "").split(separator: ",") {
                let name = item.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { values.insert(name) }
            }
        }
        for tags in watch.conceptsByCode.values { values.formUnion(tags) }
        let result = values.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        cachedConceptOptions = result
        return result
    }
    func quote(for code: String) -> Quote? { quoteIndex[code] }
    func isLiveQuote(_ code: String) -> Bool { quoteIndex[code] != nil }

    /// Price change over the last `seconds` of locally sampled snapshots.
    func recentChange(for code: String, seconds: TimeInterval = 180) -> Double? {
        let now = Date()
        guard let recent = intradayHistory[code]?.filter({ now.timeIntervalSince($0.date) <= seconds }),
              recent.count >= 3, let first = recent.first, let last = recent.last,
              now.timeIntervalSince(first.date) >= 45, first.price > 0 else { return nil }
        return (last.price / first.price - 1) * 100
    }

    /// Screened stocks of one strategy minus the user's blacklist, in score order.
    func potentialStocks(for strategy: String) -> [PotentialStock] {
        let blacklisted = Set(watch.blacklist)
        let source = potentialReport?.lists?[strategy] ?? (strategy == "all" ? potentialReport?.stocks ?? [] : [])
        return source.filter { !blacklisted.contains($0.code) }
    }

    /// Poll the screener. The bridge answers instantly with its last result and
    /// rescans in the background, so this is cheap to call on every refresh.
    func refreshPotential(force: Bool = false) {
        guard !potentialRequestInFlight else { return }
        // Live strategies (速拉 / 涨停 / 龙头 / 尾盘) are recomputed by the bridge every ~12 s.
        let minimumGap: TimeInterval = (potentialReport?.scanning ?? false) ? 4 : 15
        guard force || Date().timeIntervalSince(lastPotentialRequest) >= minimumGap else { return }
        potentialRequestInFlight = true
        lastPotentialRequest = Date()
        let currentProvider = provider
        Task {
            defer { potentialRequestInFlight = false }
            do {
                let report = try await service.fetchPotential(provider: currentProvider, force: force)
                potentialReport = report
                potentialError = nil
                autoAddDailyPicks(from: report)
                autoAddOvernightPicks(from: report)
                trackOvernightOutcomes()
            } catch {
                potentialError = error.localizedDescription
                DebugLog.write("潜力股刷新失败：\(error.localizedDescription)")
            }
        }
    }

    private func sortValue(_ q: Quote) -> Double { switch sortKey { case "price": q.price; case "volumeRatio": q.volumeRatio ?? 0; case "turnover": q.turnover ?? 0; case "amount": q.amount; case "totalMarketCap": q.totalMarketCap ?? 0; case "floatMarketCap": q.floatMarketCap ?? 0; case "annualNetProfit": q.annualNetProfit ?? 0; case "quarterlyNetProfit": q.quarterlyNetProfit ?? 0; default: q.changePercent } }
    private func passesNumericFilters(_ q: Quote) -> Bool {
        return filters.enabled.allSatisfy { key in
            let value: Double?
            switch key {
            case "price": value = q.price
            case "changePercent": value = q.changePercent
            case "volumeRatio": value = q.volumeRatio
            case "turnover": value = q.turnover
            case "amount": value = q.amount
            case "floatMarketCap": value = q.floatMarketCap
            default: return false
            }
            guard let value else { return false }
            let maximum = filters.maximums[key] ?? 0
            return value >= (filters.minimums[key] ?? 0) && (maximum <= 0 || value <= maximum)
        }
    }

    func start() {
        timer?.invalidate()
        timer = nil
        monitoringActive = true
        let savedServiceURL = UserDefaults.standard.string(forKey: "serviceURL")
        // The bundled bridge may sit on another port when 8767 is taken; the manager keeps serviceURL in sync.
        let serviceURL = savedServiceURL == nil || LocalBridgeManager.isBundledURL(savedServiceURL ?? "") ? LocalBridgeManager.currentURL : savedServiceURL!
        if savedServiceURL != serviceURL { UserDefaults.standard.set(serviceURL, forKey: "serviceURL") }
        let needsLocalBridge = serviceURL.contains("127.0.0.1") || serviceURL.contains("localhost")
        status = needsLocalBridge ? "正在启动本地 AkShare 行情服务…" : "正在连接行情服务器…"
        DebugLog.write("启动盯盘，provider=\(provider)，refresh=\(settings.refreshSeconds)s；全市场默认节奏按实测上游耗时设置")
        Task {
            if needsLocalBridge, !(await bridge.ensureRunning()) {
                status = bridge.failureMessage
                DebugLog.write("本地行情服务启动失败：\(bridge.failureMessage)")
                return
            }
            DebugLog.write("本地行情服务已就绪")
            refresh()
        }
    }
    func stop() { monitoringActive = false; timer?.invalidate(); timer = nil; bridge.stop() }
    func refresh() {
        guard !isRefreshing else { skippedRefreshTicks += 1; return }
        isRefreshing = true
        refreshSequence += 1
        let requestID = refreshSequence
        let skipped = skippedRefreshTicks
        skippedRefreshTicks = 0
        let fetchStarted = ProcessInfo.processInfo.systemUptime
        DebugLog.write("刷新开始 id=\(requestID), provider=\(provider), interval=\(settings.refreshSeconds)s, codes=全市场, accumulatedSkippedTicks=\(skipped)")
        status = "正在更新行情…"
        Task {
            defer {
                let elapsed = ProcessInfo.processInfo.systemUptime - fetchStarted
                DebugLog.write("刷新结束 id=\(requestID), elapsed=\(String(format: "%.3f", elapsed))s")
                isRefreshing = false
                scheduleNextRefresh(after: elapsed)
            }
            do {
                // The main quote table is the whole market. The watchlist is only
                // used below for alert sampling, so removing a watch item never
                // removes a stock from the market table.
                let data = try await fetchQuotesWithLocalRecovery()
                // A 304 response means the local snapshot is unchanged. Avoid
                // re-sampling identical prices when the cache has not expired.
                guard !data.isEmpty else { return }
                let connectionElapsed = ProcessInfo.processInfo.systemUptime - fetchStarted
                let now = Date()
                observeAlertLogTradingDay(at: now)
                let snapshotTimestamp = data.first?.timestamp
                if snapshotTimestamp != latestSnapshotTimestamp {
                    restoreLimitDayState(for: now)
                    for q in data { ingest(q, at: now) }
                    latestSnapshotTimestamp = snapshotTimestamp
                }
                quotes = data; lastUpdate = now
                checkHoldings(at: now)
                status = "已连接 · \(providerName(provider)) · \(data.count) 只 · 连接用时 \(String(format: "%.2f", connectionElapsed)) s · 更新 \(now.formatted(date: .omitted, time: .standard))"
                DebugLog.write("行情连接耗时 id=\(requestID), elapsed=\(String(format: "%.3f", connectionElapsed))s")
                refreshPotential()
                let sample = data.prefix(4).map { "\($0.code):\($0.name)=\($0.price)" }.joined(separator: ",")
                DebugLog.write("行情内容校验 id=\(requestID), received=\(data.count), snapshotTimestamp=\(snapshotTimestamp?.ISO8601Format() ?? "nil"), sample=[\(sample)]")
            } catch { status = "行情服务未连接：\(error.localizedDescription)"; DebugLog.write("刷新失败 id=\(requestID), error=\(error.localizedDescription)") }
        }
    }
    /// Schedule relative to the completed fetch. This keeps a roughly 10-second
    /// start-to-start cadence while ensuring the service's 2-second cache has
    /// expired, avoiding a useless 304 just before the next full-market fetch.
    private func scheduleNextRefresh(after elapsed: TimeInterval) {
        guard monitoringActive else { return }
        let cacheExpiryBuffer: TimeInterval = 1.6
        let delay = max(cacheExpiryBuffer, TimeInterval(settings.refreshSeconds) - elapsed)
        DebugLog.write("下次行情刷新计划：\(String(format: "%.2f", delay))s 后；本轮耗时=\(String(format: "%.2f", elapsed))s, 目标周期=\(settings.refreshSeconds)s")
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.timer = nil
                self?.refresh()
            }
        }
    }

    /// A second app copy can reuse a bridge owned by the first copy. If that
    /// owner exits, restart the local service and retry once on demand.
    private func fetchQuotesWithLocalRecovery() async throws -> [Quote] {
        do {
            return try await service.fetch(codes: ["*"], provider: provider, industryCodes: watch.codes)
        } catch {
            guard usesLocalService else { throw error }
            DebugLog.write("行情请求失败后检查本地服务并尝试恢复：\(error.localizedDescription)")
            guard await bridge.ensureRunning() else {
                DebugLog.write("本地服务自动恢复失败：\(bridge.failureMessage)")
                throw NSError(domain: "AStockMonitor.LocalBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: bridge.failureMessage])
            }
            DebugLog.write("本地行情服务恢复成功，重试行情请求")
            return try await service.fetch(codes: ["*"], provider: provider, industryCodes: watch.codes)
        }
    }

    private var usesLocalService: Bool {
        let url = UserDefaults.standard.string(forKey: "serviceURL") ?? "http://127.0.0.1:8767"
        return url.contains("127.0.0.1") || url.contains("localhost")
    }

    /// Let a detail window recover the bundled bridge even if no quote refresh
    /// is currently running.
    func ensureHistoryServiceAvailable() async -> Bool {
        guard usesLocalService else { return true }
        let ready = await bridge.ensureRunning()
        if !ready { DebugLog.write("个股详情无法启动本地行情服务：\(bridge.failureMessage)") }
        return ready
    }

    func applySettings(_ newSettings: MonitorSettings, provider newProvider: String, serviceURL: String) {
        var normalizedSettings = newSettings
        normalizedSettings.threshold = min(max(normalizedSettings.threshold, 0), 30)
        normalizedSettings.rapidThreshold = min(max(normalizedSettings.rapidThreshold, 0), 30)
        if normalizedSettings.refreshSeconds < 3 { normalizedSettings.refreshSeconds = 3 }
        if ![10, 30, 60, 180, 300, 600].contains(normalizedSettings.cooldownSeconds) { normalizedSettings.cooldownSeconds = 180 }
        if ![10, 30, 60, 180, 300, 600].contains(normalizedSettings.rapidCooldownSeconds) { normalizedSettings.rapidCooldownSeconds = 180 }
        if ![30, 60, 120, 180, 300].contains(normalizedSettings.windowSeconds) { normalizedSettings.windowSeconds = 60 }
        settings = normalizedSettings
        provider = newProvider
        let appliedServiceURL = LocalBridgeManager.isBundledURL(serviceURL) ? LocalBridgeManager.currentURL : serviceURL
        UserDefaults.standard.set(appliedServiceURL, forKey: "serviceURL")
        DebugLog.write("已应用设置 provider=\(newProvider), serviceURL=\(appliedServiceURL), refresh=\(normalizedSettings.refreshSeconds)s")
        start()
    }
    func testConnection(provider testProvider: String, serviceURL: String) async -> String {
        DebugLog.write("开始连接测试 provider=\(testProvider), serviceURL=\(serviceURL)")
        if serviceURL.contains("127.0.0.1") || serviceURL.contains("localhost") {
            guard await bridge.ensureRunning() else {
                DebugLog.write("连接测试失败：\(bridge.failureMessage)")
                return bridge.failureMessage
            }
        }
        do {
            let result = try await service.fetch(codes: watch.codes.isEmpty ? ["600519"] : watch.codes, provider: testProvider, baseURL: serviceURL)
            guard !result.isEmpty else { DebugLog.write("连接成功但自选股数据为空"); return "服务器连接成功，但没有返回自选股数据；请确认代码或更换数据源。" }
            DebugLog.write("连接测试成功：返回 \(result.count) 只自选股")
            return "连接成功，获取到 \(result.count) 只自选股。"
        } catch {
            DebugLog.write("连接测试失败：\(error.localizedDescription)")
            return "连接失败：\(error.localizedDescription)"
        }
    }
    private func providerName(_ value: String) -> String {
        switch value { case "eastmoney_fast": "东方财富直连"; case "tencent_fast": "腾讯直连"; case "eastmoney": "东方财富"; case "tencent": "腾讯"; case "sina": "新浪"; default: "自动（直连）" }
    }
    private func ingest(_ quote: Quote, at now: Date) {
        var chartPoints = intradayHistory[quote.code, default: []]
        let previousSample = chartPoints.last
        chartPoints.append(PricePoint(date: now, price: quote.price, changePercent: quote.changePercent))
        chartPoints.removeAll { now.timeIntervalSince($0.date) > 360 }
        intradayHistory[quote.code] = chartPoints

        let volumeOK = !settings.requireVolume || quote.volume >= (averageVolumes[quote.code] ?? 0) * settings.volumeMultiple
        let eligible = volumeOK && !watch.blacklist.contains(quote.code) && !quote.isST && !quote.suspended
        let duringTradingSession = isAStockTradingSession(at: now)
        let previousSampleIsToday = previousSample.map { isSameAStockTradingDay($0.date, now) } ?? false
        // Daily-gain alerts should represent a new move through the threshold,
        // not repeatedly notify on an unchanged quote after cooldown expires.
        // 0.01 percentage point matches the precision shown in the quote table.
        let dailyChangeMoved = previousSampleIsToday &&
            abs(quote.changePercent - (previousSample?.changePercent ?? quote.changePercent)) >= 0.01
        // Daily-gain alerts keep their original watchlist-only behavior.
        if duringTradingSession, eligible, dailyChangeMoved,
           watch.codes.contains(quote.code), quote.changePercent >= settings.threshold,
           isOutsideCooldown(code: quote.code, type: "daily", at: now) {
            fire(quote, change: quote.changePercent, type: "daily", threshold: settings.threshold, at: now)
        }
        // Rapid-rise alerts scan every listed A-share. Measure the rise from the
        // lowest price inside the configured window (default 60 s) so a move
        // spread over several snapshots is caught, not only a single-tick jump.
        // Walk back only across consecutive same-day samples: a data gap is
        // never interpreted as a short-term rise.
        if duringTradingSession, eligible, dailyChangeMoved, previousSample != nil {
            let window = TimeInterval(min(max(settings.windowSeconds, 30), 300))
            let maximumSampleGap = TimeInterval(settings.refreshSeconds + 5)
            var windowLow: PricePoint?
            var cursor = now
            for sample in chartPoints.dropLast().reversed() {
                guard cursor.timeIntervalSince(sample.date) <= maximumSampleGap,
                      now.timeIntervalSince(sample.date) <= window + 1,
                      isSameAStockTradingDay(sample.date, now), sample.price > 0 else { break }
                if sample.price < (windowLow?.price ?? .infinity) { windowLow = sample }
                cursor = sample.date
            }
            if let low = windowLow {
                let interval = now.timeIntervalSince(low.date)
                let rapidRise = (quote.price / low.price - 1) * 100
                if interval > 0, rapidRise > 0, rapidRise >= settings.rapidThreshold,
                   isOutsideCooldown(code: quote.code, type: "rapid10", at: now) {
                    fire(quote, change: rapidRise, type: "rapid10", threshold: settings.rapidThreshold, at: now,
                         startPrice: low.price, intervalSeconds: interval,
                         startChangePercent: low.changePercent, triggerChangePercent: quote.changePercent)
                }
            }
        }
        ingestLimitEvents(quote, at: now, duringTradingSession: duringTradingSession, previousSampleIsToday: previousSampleIsToday)
        // Snapshot volume is used only as an optional approximation; baseline is supplied by the service when available.
        if quote.volumeRatio != nil, let ratio = quote.volumeRatio, ratio > 0 { averageVolumes[quote.code] = quote.volume / ratio }
    }
    /// Limit-board events (涨停 / 炸板 / 回封 / 跌停). Logged for the whole market
    /// when enabled; toasts stay limited to the watchlist unless configured.
    private func ingestLimitEvents(_ quote: Quote, at now: Date, duringTradingSession: Bool, previousSampleIsToday: Bool) {
        let code = quote.code
        let wasLimitUp = limitUpState[code]
        let wasLimitDown = limitDownState[code]
        limitUpState[code] = quote.upperLimit
        limitDownState[code] = quote.lowerLimit
        guard duringTradingSession, !quote.suspended, !watch.blacklist.contains(code) else { return }
        let inWatch = watch.codes.contains(code)
        guard inWatch || (settings.limitMonitorAll && !quote.isST) else { return }
        let toast = inWatch || settings.limitToastAll
        let streakText = quote.limitStreak.map { $0 > 1 ? "\($0) 连板" : "首板" } ?? "涨停"
        let sealText = quote.sealAmount.map { String(format: " · 封单 %.2f 亿", $0 / 100_000_000) } ?? ""
        let firstText = quote.firstLimitTime.map { " · 首封 \($0)" } ?? ""

        if quote.upperLimit, wasLimitUp != true {
            let firstSample = wasLimitUp == nil || !previousSampleIsToday
            if !sealedToday.contains(code) {
                sealedToday.insert(code)
                let detail = firstSample ? "\(streakText)\(firstText)\(sealText) · 启动时已封板" : "\(streakText)\(firstText)\(sealText)"
                fire(quote, change: quote.changePercent, type: "limitUp", threshold: 0, at: now,
                     detail: detail, silent: firstSample || !toast)
            } else if !firstSample, isOutsideCooldown(code: code, type: "limitReseal", at: now) {
                let opens = quote.limitOpenCount.map { "炸板 \($0) 次后" } ?? ""
                fire(quote, change: quote.changePercent, type: "limitReseal", threshold: 0, at: now,
                     detail: "\(opens)回封 · \(streakText)\(sealText)", silent: !toast)
            }
        } else if !quote.upperLimit, wasLimitUp == true, previousSampleIsToday,
                  isOutsideCooldown(code: code, type: "limitOpen", at: now) {
            let gap = quote.limitUpPrice.map { String(format: "距涨停 %.2f%%", ($0 - quote.price) / $0 * 100) } ?? ""
            let count = (quote.limitOpenCount ?? 0) + 1
            fire(quote, change: quote.changePercent, type: "limitOpen", threshold: 0, at: now,
                 detail: "第 \(count) 次炸板 · \(gap)", silent: !toast)
        }

        if settings.limitDownAlerts, quote.lowerLimit, wasLimitDown == false, previousSampleIsToday,
           !limitDownToday.contains(code) {
            limitDownToday.insert(code)
            fire(quote, change: quote.changePercent, type: "limitDown", threshold: 0, at: now,
                 detail: "封跌停", silent: !inWatch)
        }
    }

    /// Daily recommendations: for each board (主板 / 创业科创) at most
    /// `dailyPickLimit` 综合 A-grade stocks that are not sealed at the limit and
    /// still buyable, kept in a dated group per board ("推荐 MM-dd 主板"). When a
    /// board is full, a stronger candidate (≥ 3 points) swaps out that board's
    /// weakest pick held at least 10 minutes. Past days stay for review.
    private func autoAddDailyPicks(from report: PotentialReport) {
        let now = Date()
        guard settings.autoAddDailyPicks, isAStockTradingSession(at: now) else { return }
        let day = pickDayKey(now)
        let limit = min(max(settings.dailyPickLimit, 3), 30)
        let margin = 3
        var updated = watch
        migrateLegacyAutoPicks(&updated)

        let ranked = report.lists?["all"] ?? report.stocks
        let latestScore = Dictionary(ranked.map { ($0.code, $0.score) }, uniquingKeysWith: { first, _ in first })
        let latestStock = Dictionary(ranked.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
        // Keep picks still in their board group; refresh scores. A stock that
        // fell out of the combined list has lost potential.
        var picks = (updated.picksByDay[day] ?? []).filter {
            updated.codes.contains($0.code) && updated.groupByCode[$0.code] == WatchData.pickGroupName(day: day, code: $0.code)
        }
        for index in picks.indices {
            picks[index].score = latestScore[picks[index].code] ?? max(picks[index].score - 10, 0)
            // Picks saved before snapshots existed: fill in the reason from the latest screen.
            if picks[index].signals == nil, let stock = latestStock[picks[index].code] {
                picks[index].applySnapshot(stock)
                picks[index].backfilled = true
            }
        }
        var replaced = Set(updated.replacedByDay[day] ?? [])
        let blacklisted = Set(updated.blacklist)
        var added: [DailyPick] = []
        var swaps: [(out: DailyPick, into: DailyPick)] = []

        for stock in ranked where stock.grade == "A" {
            guard !updated.codes.contains(stock.code), !replaced.contains(stock.code),
                  !blacklisted.contains(stock.code), stock.buyable != false,
                  let live = quote(for: stock.code), !live.upperLimit, !live.suspended, !live.isST else { continue }
            if let limitUp = live.limitUpPrice, live.price >= limitUpPrice(limitUp) { continue }
            let board = WatchData.pickBoard(code: stock.code)
            let group = WatchData.pickGroupName(day: day, board: board)
            var pick = DailyPick(code: stock.code, name: stock.name, initialScore: stock.score, score: stock.score,
                                 price: live.price, time: now, strategies: stock.strategies ?? [])
            pick.applySnapshot(stock)
            let boardIndices = picks.indices.filter { WatchData.pickBoard(code: picks[$0].code) == board }
            // Picks sealed at the limit can no longer be bought: they stay in the group
            // but do not use up the quota, so each board keeps `limit` buyable picks.
            let buyableCount = boardIndices.filter { quote(for: picks[$0].code)?.upperLimit != true }.count
            if buyableCount < limit {
                picks.append(pick); added.append(pick)
            } else {
                // Never swap out a pick that has since sealed the limit (it worked),
                // and hold each pick at least 10 minutes so live score noise does not churn the list.
                let replaceable = boardIndices.filter {
                    quote(for: picks[$0].code)?.upperLimit != true && now.timeIntervalSince(picks[$0].time) >= 600
                }
                guard let weakest = replaceable.min(by: { picks[$0].score < picks[$1].score }),
                      stock.score >= picks[weakest].score + margin else { continue }
                let out = picks.remove(at: weakest)
                updated.codes.removeAll { $0 == out.code }
                updated.groupByCode.removeValue(forKey: out.code)
                replaced.insert(out.code)
                picks.append(pick)
                swaps.append((out, pick))
            }
            updated.codes.append(pick.code)
            updated.groupByCode[pick.code] = group
            if !updated.groups.contains(group) { updated.groups.append(group) }
        }
        updated.picksByDay[day] = picks.sorted { $0.score > $1.score }
        updated.replacedByDay[day] = Array(replaced).sorted()
        pruneOldPickDays(&updated)
        if !watchEquivalent(updated, watch) { watch = updated }

        for board in WatchData.pickBoards {
            let boardAdded = added.filter { WatchData.pickBoard(code: $0.code) == board }
            guard !boardAdded.isEmpty else { continue }
            let group = WatchData.pickGroupName(day: day, board: board)
            let boardPicks = picks.filter { WatchData.pickBoard(code: $0.code) == board }
            let sealed = boardPicks.filter { quote(for: $0.code)?.upperLimit == true }.count
            let count = boardPicks.count - sealed
            DebugLog.write("当日推荐新增（\(board)）：\(boardAdded.map { "\($0.code)\($0.name)(\($0.score))" }.joined(separator: ","))")
            let names = boardAdded.map(\.name)
            enqueueToast(AlertToast(shortType: "当日推荐", name: names.prefix(3).joined(separator: "、") + (names.count > 3 ? " 等" : ""),
                                    code: boardAdded[0].code,
                                    effect: "综合 A 级、未涨停可买入，加入「\(group)」（\(board) 可买 \(count)/\(limit) 只" + (sealed > 0 ? "，另有 \(sealed) 只已涨停" : "") + "）"))
        }
        for swap in swaps {
            let group = WatchData.pickGroupName(day: day, code: swap.into.code)
            DebugLog.write("当日推荐替换：\(swap.out.code)\(swap.out.name)(\(swap.out.score)) → \(swap.into.code)\(swap.into.name)(\(swap.into.score))")
            enqueueToast(AlertToast(shortType: "推荐替换", name: swap.into.name, code: swap.into.code,
                                    effect: "评分 \(swap.into.score) 替换 \(swap.out.name)（\(swap.out.score)），「\(group)」保持 \(limit) 只可买"))
        }
    }

    private func minuteOfDay(_ date: Date) -> Int {
        let parts = aStockCalendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// 尾盘隔夜: at 14:50–15:00 of a trading day, lock the top `overnightPickLimit`
    /// stocks of each board (主板 / 创业科创) once. They go into dated 隔夜 groups
    /// (codes already in the watchlist keep their group but are still recorded).
    private func autoAddOvernightPicks(from report: PotentialReport) {
        let now = Date()
        guard settings.autoOvernightPicks, isAStockTradingSession(at: now),
              (890..<900).contains(minuteOfDay(now)) else { return }
        let day = pickDayKey(now)
        guard watch.overnightByDay[day] == nil else { return }
        let ranked = report.lists?["overnight"] ?? []
        guard !ranked.isEmpty else { return }
        let limit = min(max(settings.overnightPickLimit, 3), 15)
        let blacklisted = Set(watch.blacklist)
        var updated = watch
        var picks: [DailyPick] = []
        var alreadyWatched: [String: [String]] = [:]
        for board in WatchData.pickBoards {
            let candidates = ranked.filter { ($0.board ?? WatchData.pickBoard(code: $0.code)) == board && !blacklisted.contains($0.code) }
                .filter { stock in
                    guard let live = quote(for: stock.code) else { return true }
                    return !live.upperLimit && !live.suspended && !live.isST
                }
                .sorted { ($0.pHi5 ?? 0) > ($1.pHi5 ?? 0) }
            let group = WatchData.overnightGroupName(day: day, board: board)
            for stock in candidates.prefix(limit) {
                var pick = DailyPick(code: stock.code, name: stock.name, initialScore: stock.score, score: stock.score,
                                     price: quote(for: stock.code)?.price ?? stock.price, time: now, strategies: ["overnight"])
                pick.applySnapshot(stock)
                pick.kind = "overnight"
                picks.append(pick)
                if updated.codes.contains(stock.code) {
                    alreadyWatched[board, default: []].append(stock.name)
                } else {
                    updated.codes.append(stock.code)
                    updated.groupByCode[stock.code] = group
                    if !updated.groups.contains(group) { updated.groups.append(group) }
                }
            }
        }
        guard !picks.isEmpty else { return }
        updated.overnightByDay[day] = picks
        pruneOldPickDays(&updated)
        watch = updated
        for board in WatchData.pickBoards {
            let boardPicks = picks.filter { WatchData.pickBoard(code: $0.code) == board }
            guard !boardPicks.isEmpty else { continue }
            let group = WatchData.overnightGroupName(day: day, board: board)
            DebugLog.write("尾盘隔夜锁定（\(board)）：\(boardPicks.map { "\($0.code)\($0.name)(≥5% \(String(format: "%.0f", $0.pHi5 ?? 0))%)" }.joined(separator: ","))")
            let watched = alreadyWatched[board] ?? []
            enqueueToast(AlertToast(shortType: "尾盘隔夜", name: boardPicks.prefix(3).map(\.name).joined(separator: "、") + (boardPicks.count > 3 ? " 等" : ""),
                                    code: boardPicks[0].code,
                                    effect: "\(board) \(boardPicks.count) 只已锁定到「\(group)」" + (watched.isEmpty ? "" : "（\(watched.joined(separator: "、")) 已在其他分组）") + "，次日挂 +3% 止盈"))
        }
    }

    /// Next trading day: record open / high / latest price of the previous day's 隔夜
    /// picks from Eastmoney (the quote snapshot may lack open / high), once a minute.
    private func trackOvernightOutcomes() {
        let now = Date()
        guard isAStockTradingSession(at: now) || (900..<930).contains(minuteOfDay(now)),
              !overnightTrackInFlight, now.timeIntervalSince(lastOvernightTrack) >= 60 else { return }
        let today = pickDayKey(now)
        guard let day = watch.overnightByDay.keys.filter({ $0 < today }).max(),
              let picks = watch.overnightByDay[day],
              picks.contains(where: { $0.nextDay == nil || $0.nextDay == today }) else { return }
        overnightTrackInFlight = true
        lastOvernightTrack = now
        let codes = picks.map(\.code)
        Task {
            defer { overnightTrackInFlight = false }
            guard let ohlc = try? await service.fetchOHLC(codes: codes), !ohlc.isEmpty else { return }
            var updated = watch
            guard var current = updated.overnightByDay[day] else { return }
            for index in current.indices where current[index].nextDay == nil || current[index].nextDay == today {
                guard let bar = ohlc[current[index].code], let open = bar.open, open > 0 else { continue }
                current[index].nextDay = today
                current[index].nextOpen = open
                current[index].nextHigh = max(bar.high ?? open, current[index].nextHigh ?? 0)
                current[index].nextClose = bar.price ?? current[index].nextClose
            }
            updated.overnightByDay[day] = current
            if updated.overnightByDay != watch.overnightByDay { watch = updated }
        }
    }

    /// The 隔夜 record of a code that still sits in its dated 隔夜 group.
    func overnightPick(for code: String) -> (day: String, pick: DailyPick)? {
        guard let group = watch.groupByCode[code], group.hasPrefix(WatchData.overnightGroupPrefix) else { return nil }
        for (day, picks) in watch.overnightByDay where WatchData.overnightGroupName(day: day, code: code) == group {
            if let pick = picks.first(where: { $0.code == code }) { return (day, pick) }
        }
        return nil
    }

    /// Review of one dated 隔夜 group: next-day hit rate of the +3% take-profit and average returns.
    func overnightSummary(forGroup group: String) -> (day: String, count: Int, tracked: Int, hit3: Int, hit5: Int, avgOpen: Double?, avgHigh: Double?, avgClose: Double?)? {
        guard let (day, board) = watch.overnightByDay.keys.lazy.flatMap({ day in WatchData.pickBoards.map { (day, $0) } })
                .first(where: { WatchData.overnightGroupName(day: $0.0, board: $0.1) == group }) else { return nil }
        let picks = (watch.overnightByDay[day] ?? []).filter { WatchData.pickBoard(code: $0.code) == board }
        guard !picks.isEmpty else { return nil }
        let tracked = picks.filter { $0.nextOpen != nil }
        func average(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        return (day, picks.count, tracked.count,
                tracked.filter { ($0.nextHighReturn ?? -99) >= 3 }.count,
                tracked.filter { ($0.nextHighReturn ?? -99) >= 5 }.count,
                average(tracked.compactMap(\.nextOpenReturn)), average(tracked.compactMap(\.nextHighReturn)),
                average(tracked.compactMap(\.nextCloseReturn)))
    }

    /// All 隔夜 picks so far with next-day results, for the strategy's running track record.
    func overnightTrackRecord() -> (picks: Int, hit3: Int, hit5: Int, avgOpen: Double?, avgHigh: Double?)? {
        let tracked = watch.overnightByDay.values.flatMap { $0 }.filter { $0.nextOpen != nil }
        guard !tracked.isEmpty else { return nil }
        let opens = tracked.compactMap(\.nextOpenReturn), highs = tracked.compactMap(\.nextHighReturn)
        return (tracked.count, highs.filter { $0 >= 3 }.count, highs.filter { $0 >= 5 }.count,
                opens.isEmpty ? nil : opens.reduce(0, +) / Double(opens.count),
                highs.isEmpty ? nil : highs.reduce(0, +) / Double(highs.count))
    }

    private func limitUpPrice(_ limit: Double) -> Double { limit - 0.01 }

    private func watchEquivalent(_ lhs: WatchData, _ rhs: WatchData) -> Bool {
        lhs.codes == rhs.codes && lhs.groups == rhs.groups && lhs.groupByCode == rhs.groupByCode
            && lhs.picksByDay == rhs.picksByDay && lhs.replacedByDay == rhs.replacedByDay
            && lhs.overnightByDay == rhs.overnightByDay
            && lhs.autoDailyCodes == rhs.autoDailyCodes
    }

    /// The previous build used one 当日自选 group; turn it into a dated group.
    private func migrateLegacyAutoPicks(_ data: inout WatchData) {
        guard !data.autoDailyCodes.isEmpty || data.groups.contains(WatchData.legacyAutoDailyGroup) else {
            splitLegacyDayGroups(&data)
            return
        }
        let legacy = WatchData.legacyAutoDailyGroup
        let day = data.autoDailyDay.isEmpty ? pickDayKey(Date()) : normalizedDayKey(data.autoDailyDay)
        var picks = data.picksByDay[day] ?? []
        for code in data.autoDailyCodes where data.groupByCode[code] == legacy && !picks.contains(where: { $0.code == code }) {
            let live = quote(for: code)
            let score = potentialReport?.lists?["all"]?.first { $0.code == code }?.score ?? 0
            picks.append(DailyPick(code: code, name: live?.name ?? code, initialScore: score, score: score,
                                   price: live?.price ?? 0, time: Date()))
        }
        for code in data.codes where data.groupByCode[code] == legacy { data.groupByCode[code] = WatchData.legacyPickGroupName(day: day) }
        data.groups.removeAll { $0 == legacy }
        if !picks.isEmpty { data.picksByDay[day] = picks }
        data.autoDailyCodes = []
        data.autoDailyDay = ""
        splitLegacyDayGroups(&data)
    }

    /// Before the board split each day had one 推荐 MM-dd group. Move its codes
    /// into the per-board groups and keep at most `dailyPickLimit` per board.
    private func splitLegacyDayGroups(_ data: inout WatchData) {
        let limit = min(max(settings.dailyPickLimit, 3), 30)
        for (day, picks) in data.picksByDay {
            let legacy = WatchData.legacyPickGroupName(day: day)
            guard data.groups.contains(legacy) || data.groupByCode.values.contains(legacy) else { continue }
            var kept: [DailyPick] = []
            for board in WatchData.pickBoards {
                let boardPicks = picks.filter { WatchData.pickBoard(code: $0.code) == board && data.groupByCode[$0.code] == legacy }
                    .sorted { $0.score > $1.score }
                let group = WatchData.pickGroupName(day: day, board: board)
                for pick in boardPicks.prefix(limit) { data.groupByCode[pick.code] = group }
                for extra in boardPicks.dropFirst(limit) {
                    data.codes.removeAll { $0 == extra.code }
                    data.groupByCode.removeValue(forKey: extra.code)
                }
                if !boardPicks.isEmpty, !data.groups.contains(group) { data.groups.append(group) }
                kept += boardPicks.prefix(limit)
            }
            // Codes the user moved into the old group by hand go to the 主板 / 创业科创 group too.
            for code in data.codes where data.groupByCode[code] == legacy {
                data.groupByCode[code] = WatchData.pickGroupName(day: day, code: code)
            }
            data.groups.removeAll { $0 == legacy }
            data.picksByDay[day] = kept + picks.filter { pick in !kept.contains(where: { $0.code == pick.code }) && data.groupByCode[pick.code] != nil }
            DebugLog.write("推荐分组按板块拆分：\(legacy) → 主板 \(kept.filter { WatchData.pickBoard(code: $0.code) == "主板" }.count) 只，创业科创 \(kept.filter { WatchData.pickBoard(code: $0.code) == "创业科创" }.count) 只")
        }
    }

    /// Keep 30 dated recommendation groups; older ones (and their untouched codes) are removed.
    private func pruneOldPickDays(_ data: inout WatchData) {
        let overnightDays = data.overnightByDay.keys.sorted()
        if overnightDays.count > 30 {
            for day in overnightDays.dropLast(30) {
                let groups = Set(WatchData.pickBoards.map { WatchData.overnightGroupName(day: day, board: $0) })
                let codes = Set(data.codes.filter { groups.contains(data.groupByCode[$0] ?? "") })
                data.codes.removeAll { codes.contains($0) }
                for code in codes { data.groupByCode.removeValue(forKey: code) }
                data.groups.removeAll { groups.contains($0) }
                data.overnightByDay.removeValue(forKey: day)
            }
        }
        let days = data.picksByDay.keys.sorted()
        guard days.count > 30 else { return }
        for day in days.dropLast(30) {
            let groups = Set(WatchData.pickBoards.map { WatchData.pickGroupName(day: day, board: $0) } + [WatchData.legacyPickGroupName(day: day)])
            let codes = Set(data.codes.filter { groups.contains(data.groupByCode[$0] ?? "") })
            data.codes.removeAll { codes.contains($0) }
            for code in codes { data.groupByCode.removeValue(forKey: code) }
            data.groups.removeAll { groups.contains($0) }
            data.picksByDay.removeValue(forKey: day)
            data.replacedByDay.removeValue(forKey: day)
        }
    }

    private func pickDayKey(_ date: Date) -> String {
        let parts = aStockCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func normalizedDayKey(_ raw: String) -> String {
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return pickDayKey(Date()) }
        return String(format: "%04d-%02d-%02d", parts[0], parts[1], parts[2])
    }

    /// The recommendation record for a code that still sits in its dated group.
    func dailyPick(for code: String) -> (day: String, pick: DailyPick)? {
        guard let group = watch.groupByCode[code], group.hasPrefix(WatchData.pickGroupPrefix) else { return nil }
        for (day, picks) in watch.picksByDay where WatchData.pickGroupName(day: day, code: code) == group {
            if let pick = picks.first(where: { $0.code == code }) { return (day, pick) }
        }
        return nil
    }

    /// Every day a code was recommended (newest first), regardless of its current group.
    func pickHistory(for code: String) -> [(day: String, pick: DailyPick)] {
        let daily = watch.picksByDay.compactMap { day, picks in picks.first { $0.code == code }.map { (day, $0) } }
        let overnight = watch.overnightByDay.compactMap { day, picks in picks.first { $0.code == code }.map { (day, $0) } }
        return (daily + overnight).sorted { ($0.day, $0.pick.time) > ($1.day, $1.pick.time) }
    }

    /// Picks of one dated group with the return since recommendation, for review.
    func picksSummary(forGroup group: String) -> (count: Int, average: Double?, winners: Int, sealed: Int)? {
        guard let (day, board) = watch.picksByDay.keys.lazy.flatMap({ day in WatchData.pickBoards.map { (day, $0) } })
                .first(where: { WatchData.pickGroupName(day: $0.0, board: $0.1) == group }) else { return nil }
        let picks = (watch.picksByDay[day] ?? []).filter { WatchData.pickBoard(code: $0.code) == board && watch.groupByCode[$0.code] == group }
        guard !picks.isEmpty else { return nil }
        let returns = picks.compactMap { pick -> Double? in
            guard pick.price > 0, let live = quote(for: pick.code), live.price > 0 else { return nil }
            return (live.price / pick.price - 1) * 100
        }
        let average = returns.isEmpty ? nil : returns.reduce(0, +) / Double(returns.count)
        let sealed = picks.filter { quote(for: $0.code)?.upperLimit == true }.count
        return (picks.count, average, returns.filter { $0 > 0 }.count, sealed)
    }

    /// Same-industry rapid alerts in the last 10 minutes (sector co-movement).
    private func recentRapidPeers(industry: String?, excluding code: String, at now: Date) -> Int {
        guard let industry, !industry.isEmpty else { return 0 }
        var codes = Set<String>()
        for alert in alerts {
            if now.timeIntervalSince(alert.time) > 600 { break }
            if alert.alertType == "rapid10", alert.industry == industry, alert.code != code { codes.insert(alert.code) }
        }
        return codes.count
    }

    private func isAStockTradingSession(at date: Date) -> Bool {
        let calendar = aStockCalendar
        let weekday = calendar.component(.weekday, from: date)
        guard (2...6).contains(weekday) else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return false }
        let minuteOfDay = hour * 60 + minute
        return (570..<690).contains(minuteOfDay) || (780..<900).contains(minuteOfDay)
    }

    private func isSameAStockTradingDay(_ lhs: Date, _ rhs: Date) -> Bool {
        aStockCalendar.isDate(lhs, inSameDayAs: rhs)
    }

    private var aStockCalendar: Calendar { Self.shanghaiCalendar }
    private static let shanghaiCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }()
    private func isOutsideCooldown(code: String, type: String, at date: Date) -> Bool {
        let key = "\(code):\(type)"
        let cooldown = type == "rapid10" ? settings.rapidCooldownSeconds : settings.cooldownSeconds
        return date.timeIntervalSince(lastAlert[key] ?? .distantPast) >= TimeInterval(cooldown)
    }
    private func fire(_ q: Quote, change: Double, type: String, threshold: Double, at date: Date,
                      startPrice: Double? = nil, intervalSeconds: TimeInterval? = nil,
                      startChangePercent: Double? = nil, triggerChangePercent: Double? = nil,
                      detail: String? = nil, silent: Bool = false) {
        lastAlert["\(q.code):\(type)"] = date
        let industry = (q.industry?.isEmpty == false ? q.industry : nil) ?? q.limitIndustry
        var detailText = detail
        if type == "rapid10" {
            let peers = recentRapidPeers(industry: industry, excluding: q.code, at: date)
            let seconds = max(Int((intervalSeconds ?? 0).rounded()), 1)
            detailText = "\(seconds) 秒拉升" + (peers > 0 ? " · 同行业 10 分钟内另有 \(peers) 只速拉" : "")
        } else if type == "daily" {
            detailText = String(format: "达到阈值 %.1f%%", threshold) + (q.upperLimit ? " · 已封涨停" : "")
        }
        let item = AlertRecord(code: q.code, name: q.name, time: date, price: q.price, change: change,
                               startPrice: startPrice, startChangePercent: startChangePercent,
                               triggerChangePercent: triggerChangePercent, changeBasis: type, alertType: type,
                               industry: industry, detail: detailText,
                               limitStreak: type.hasPrefix("limit") ? q.limitStreak : nil,
                               silent: silent ? true : nil)
        alerts.insert(item, at: 0); if alerts.count > 1500 { alerts.removeLast(alerts.count - 1500) }
        unseenAlertCount += 1
        let shortType = AlertRecord.typeLabel(type)
        let effect: String
        if type == "daily" {
            effect = String(format: "当日 %+.2f%%，达到阈值 %.1f%%", change, threshold)
        } else if type == "limitUp" || type == "limitReseal" {
            effect = String(format: "%@ ¥%.2f（%+.2f%%）", detailText ?? shortType, q.price, q.changePercent)
        } else if type == "limitDown" {
            effect = String(format: "封跌停 ¥%.2f（%+.2f%%）", q.price, q.changePercent)
        } else if type == "limitOpen" {
            let limitText = q.limitUpPrice.map { String(format: "涨停价 ¥%.2f，", $0) } ?? ""
            effect = String(format: "涨停打开 %@现价 ¥%.2f（%+.2f%%），留意炸板回落", limitText, q.price, q.changePercent)
        } else {
            let beginPrice = startPrice ?? q.price
            let seconds = max(Int((intervalSeconds ?? 0).rounded()), 1)
            let startDayChange = startChangePercent.map { String(format: "%+.2f%%", $0) } ?? "—"
            let triggerDayChange = triggerChangePercent.map { String(format: "%+.2f%%", $0) } ?? String(format: "%+.2f%%", q.changePercent)
            effect = String(format: "\(seconds)秒：起始 %@ ¥%.2f → 触发 %@ ¥%.2f；区间 %+.2f%%，阈值 %.1f%%",
                            startDayChange, beginPrice, triggerDayChange, q.price, change, threshold)
        }
        DebugLog.write("告警触发 type=\(type), code=\(q.code), change=\(String(format: "%.3f", change))%, threshold=\(String(format: "%.1f", threshold))%, startPrice=\(startPrice.map { String(format: "%.2f", $0) } ?? "n/a"), price=\(q.price), silent=\(silent)")
        guard !silent else { return }
        enqueueToast(AlertToast(shortType: shortType, name: q.name, code: q.code, effect: effect))
        NSSound(named: .init("Glass"))?.play()
    }
    private func enqueueToast(_ toast: AlertToast) {
        toastQueue.append(toast)
        if alertToast == nil { showNextToast() }
    }
    private func showNextToast() {
        guard !toastQueue.isEmpty else { alertToast = nil; toastTask = nil; return }
        let toast = toastQueue.removeFirst()
        alertToast = toast
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, self.alertToast?.id == toast.id else { return }
            self.alertToast = nil
            self.showNextToast()
        }
    }
    func deleteAlerts(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let oldCount = alerts.count
        alerts.removeAll { ids.contains($0.id) }
        DebugLog.write("删除告警日志：选择数=\(ids.count), 删除数=\(oldCount - alerts.count), 剩余=\(alerts.count)")
    }
    func addCode(_ raw: String) { addCode(raw, toGroup: watch.groups.first ?? "默认分组") }
    func addCode(_ raw: String, toGroup group: String) {
        let code = raw.filter(\.isNumber)
        guard code.count == 6, !watch.codes.contains(code) else { return }
        if !watch.groups.contains(group) { watch.groups.append(group) }
        watch.codes.append(code)
        watch.groupByCode[code] = group
        refresh()
    }
    func removeCode(_ code: String) { watch.codes.removeAll { $0 == code }; watch.groupByCode.removeValue(forKey: code); DebugLog.write("从监控自选池移除 \(code)，全市场行情列表保留") }
    func toggleMenuBarCode(_ code: String) {
        var updated = watch
        if updated.menuBarCodes.contains(code) { updated.menuBarCodes.removeAll { $0 == code } }
        else { updated.menuBarCodes.append(code) }
        watch = updated
        // Write the status list immediately as a named operation; this makes the add/remove
        // path independent of SwiftUI's nested value-type mutation observation.
        let saved = AppFiles.write(watch, name: "watchlist.json")
        UserDefaults.standard.set(watch.menuBarCodes, forKey: "menuBarCodes.v1")
        DebugLog.write("状态栏股票切换完成：code=\(code), selected=\(watch.menuBarCodes.contains(code)), saved=\(saved), total=\(watch.menuBarCodes.count), codes=\(watch.menuBarCodes.joined(separator: ","))")
    }
    func moveMenuBarCode(_ code: String, by offset: Int) {
        var updated = watch
        guard let index = updated.menuBarCodes.firstIndex(of: code) else { return }
        let destination = index + offset
        guard updated.menuBarCodes.indices.contains(destination) else { return }
        updated.menuBarCodes.swapAt(index, destination)
        watch = updated
    }
    func moveWatchCode(_ code: String, by offset: Int, in group: String) {
        let groupCodes = group == "全部自选" ? watch.codes : watch.codes.filter { (watch.groupByCode[$0] ?? watch.groups.first ?? "默认分组") == group }
        guard let index = groupCodes.firstIndex(of: code) else { return }
        let destination = index + offset
        guard groupCodes.indices.contains(destination),
              let firstIndex = watch.codes.firstIndex(of: code),
              let secondIndex = watch.codes.firstIndex(of: groupCodes[destination]) else { return }
        watch.codes.swapAt(firstIndex, secondIndex)
    }
    func moveWatchCode(_ code: String, before targetCode: String, in group: String) {
        guard code != targetCode,
              let source = watch.codes.firstIndex(of: code),
              watch.codes.contains(targetCode) else { return }
        if group != "全部自选" {
            let fallback = watch.groups.first ?? "默认分组"
            guard (watch.groupByCode[code] ?? fallback) == group,
                  (watch.groupByCode[targetCode] ?? fallback) == group else { return }
        }
        watch.codes.remove(at: source)
        guard let destination = watch.codes.firstIndex(of: targetCode) else { return }
        watch.codes.insert(code, at: destination)
    }
    func toggleBlacklist(_ code: String) { if watch.blacklist.contains(code) { watch.blacklist.removeAll { $0 == code } } else { watch.blacklist.append(code) } }
    func moveCode(_ code: String, to group: String) {
        if !watch.groups.contains(group) { watch.groups.append(group) }
        watch.groupByCode[code] = group
    }
    func concepts(for code: String) -> [String] { watch.conceptsByCode[code] ?? [] }
    func toggleConcept(_ concept: String, for code: String) {
        var values = watch.conceptsByCode[code] ?? []
        if values.contains(concept) { values.removeAll { $0 == concept } } else { values.append(concept) }
        if values.isEmpty { watch.conceptsByCode.removeValue(forKey: code) } else { watch.conceptsByCode[code] = values }
    }
    func addGroup(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !watch.groups.contains(name) else { return nil }
        watch.groups.append(name)
        return name
    }
    func renameGroup(_ oldName: String, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !watch.groups.contains(name), let index = watch.groups.firstIndex(of: oldName) else { return }
        watch.groups[index] = name
        for code in Array(watch.groupByCode.keys) where watch.groupByCode[code] == oldName { watch.groupByCode[code] = name }
    }
    func deleteGroup(_ name: String) {
        guard watch.groups.count > 1, watch.groups.contains(name) else { return }
        let replacement = watch.groups.first(where: { $0 != name }) ?? "默认分组"
        watch.groups.removeAll { $0 == name }
        for code in Array(watch.groupByCode.keys) where watch.groupByCode[code] == name { watch.groupByCode[code] = replacement }
    }
    func openDetail(_ code: String) { selectedCode = code }
    func priceHistory(for code: String) -> [PricePoint] { intradayHistory[code] ?? [] }
    func setSort(_ key: String) { if sortKey == key { ascending.toggle() } else { sortKey = key; ascending = false } }
    func setSort(_ key: String, ascending order: Bool) {
        sortKey = key
        ascending = order
    }
}

// MARK: - 持仓卖点监控

extension MonitorStore {
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "Asia/Shanghai"); return f
    }()
    private static var shanghai: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Asia/Shanghai")!; return c
    }

    /// 录入持仓：先用默认参数入库，再用个股分析的日线补全买入后最高价、波段止损参考 20 日线。
    func addHolding(code: String, cost: Double, shares: Int?, buyDate: Date, style: String) {
        let name = quote(for: code)?.name ?? code
        var holding = Holding.make(code: code, name: name, cost: cost, shares: shares, buyDate: buyDate, style: style)
        if let q = quote(for: code) {
            let today = Self.dayFormatter.string(from: Date())
            let bought = Self.dayFormatter.string(from: buyDate)
            holding.peakPrice = max(cost, bought == today ? q.price : (q.high ?? q.price))
        }
        holdings.append(holding)
        DebugLog.write("新增持仓 code=\(code), cost=\(cost), style=\(style), stop=\(holding.stopPrice), target=\(holding.targetPrice)")
        let id = holding.id
        Task {
            guard let r = try? await service.fetchAnalysis(query: code, provider: provider), r.error == nil,
                  let index = holdings.firstIndex(where: { $0.id == id }) else { return }
            var h = holdings[index]
            if let n = r.name { h.name = n }
            let bought = Self.dayFormatter.string(from: h.buyDate)
            let after = (r.daily ?? []).filter { $0.date > bought }.map(\.high)
            if let high = after.max() { h.peakPrice = max(h.peakPrice, high) }
            if style == "swing", let ma20 = r.levels?.first(where: { $0.note == "MA20" })?.price, ma20 < h.cost {
                // 波段：止损取「−8%」与「跌破 20 日线 2%」中更近的一个。
                h.stopPrice = max(h.stopPrice, (ma20 * 0.98 * 100).rounded() / 100)
            }
            holdings[index] = h
            checkHoldings(at: Date())
        }
    }

    func removeHolding(_ id: UUID) {
        holdings.removeAll { $0.id == id }
        for i in sellSignals.indices where sellSignals[i].holdingID == id { sellSignals[i].acknowledged = true }
    }

    func acknowledgeSellSignal(_ id: UUID) {
        if let i = sellSignals.firstIndex(where: { $0.id == id }) { sellSignals[i].acknowledged = true }
    }
    func acknowledgeAllSellSignals() {
        for i in sellSignals.indices where !sellSignals[i].acknowledged { sellSignals[i].acknowledged = true }
    }

    /// 自然日里的交易日数（只扣周末，节假日不计）。
    func tradingDaysHeld(_ h: Holding, now: Date = Date()) -> Int {
        let cal = Self.shanghai
        var day = cal.startOfDay(for: h.buyDate), end = cal.startOfDay(for: now), n = 0
        while day < end {
            day = cal.date(byAdding: .day, value: 1, to: day)!
            let wd = cal.component(.weekday, from: day)
            if wd != 1 && wd != 7 { n += 1 }
        }
        return n
    }

    /// 每轮行情刷新后检查全部持仓。只在交易日 9:30–15:00 且行情是当天的才判断，避免收盘后或周末用旧价误报。
    func checkHoldings(at now: Date) {
        guard !holdings.isEmpty else { return }
        let cal = Self.shanghai
        let today = Self.dayFormatter.string(from: now)
        let minutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let weekday = cal.component(.weekday, from: now)
        let session = weekday != 1 && weekday != 7 && minutes >= 9 * 60 + 30 && minutes <= 15 * 60
        var changed = holdings
        var newSignals: [SellSignal] = []
        for i in changed.indices {
            var h = changed[i]
            guard let q = quote(for: h.code), q.price > 0, !q.suspended else { continue }
            if Self.dayFormatter.string(from: q.timestamp) != today { continue }
            let boughtToday = Self.dayFormatter.string(from: h.buyDate) == today
            // 当天买入的不用盘中更早的高点，避免把买入前的价格算进「买入后最高」。
            h.peakPrice = max(h.peakPrice, boughtToday ? q.price : (q.high ?? q.price))
            if q.upperLimit { h.sealedDay = today }
            let pnl = (q.price / h.cost - 1) * 100
            func fire(_ kind: String, _ title: String, _ detail: String, critical: Bool) {
                let key = "\(today)|\(kind)"
                guard session, !h.fired.contains(key) else { return }
                h.fired.append(key)
                newSignals.append(SellSignal(holdingID: h.id, code: h.code, name: h.name, kind: kind, title: title, detail: detail,
                                             price: q.price, pnl: pnl, time: now, critical: critical))
            }
            let held = tradingDaysHeld(h, now: now)
            if q.lowerLimit {
                fire("limitDown", "封跌停", String(format: "封跌停 ¥%.2f，盈亏 %+.2f%%。跌停可能连续，打开时优先离场。", q.price, pnl), critical: true)
            } else if q.price <= h.stopPrice {
                fire("stop", "止损", String(format: "现价 ¥%.2f 跌破止损位 ¥%.2f（成本 ¥%.2f，盈亏 %+.2f%%）。按计划止损，不要补仓摊平。", q.price, h.stopPrice, h.cost, pnl), critical: true)
            }
            if let line = h.trailLine, q.price <= line, q.price > h.stopPrice {
                let back = (1 - q.price / h.peakPrice) * 100
                let protect = line <= h.cost * 1.0031
                fire("trail", protect ? "保本卖出" : "高点回落",
                     String(format: "买入后最高 ¥%.2f（%+.1f%%），现价 ¥%.2f 回落 %.1f%%，%@。现盈亏 %+.2f%%。", h.peakPrice, h.peakGain, q.price, back,
                            protect ? "利润已回吐到成本附近，保本离场" : "跌破移动止盈线，锁定利润", pnl), critical: false)
            }
            if q.price >= h.targetPrice {
                fire("target", "到达止盈", String(format: "现价 ¥%.2f 达到止盈目标 ¥%.2f，盈利 %+.2f%%。可卖出，或先卖一半、剩余用移动止盈保护。", q.price, h.targetPrice, pnl), critical: false)
            }
            if h.sealedDay == today, !q.upperLimit, let limit = q.limitUpPrice, q.price < limit * 0.99 {
                fire("limitOpen", "涨停打开", String(format: "盘中封过涨停 ¥%.2f，现已打开到 ¥%.2f。炸板后当日回落概率大，可先卖出锁定利润（盈亏 %+.2f%%）。", limit, q.price, pnl), critical: false)
            }
            if let prev = q.prevClose, prev > 0, let high = q.high, !boughtToday, pnl > 0,
               (high / prev - 1) * 100 >= 5, (high - q.price) / prev * 100 >= 4 {
                fire("fade", "冲高回落", String(format: "今日最高 %+.1f%%，现回落到 %+.1f%%，抛压明显。持仓盈利 %+.2f%%，考虑先减仓。", (high / prev - 1) * 100, q.changePercent, pnl), critical: false)
            }
            if minutes >= 14 * 60 + 30 {
                if h.style == "overnight", held >= 1 {
                    fire("expire", "隔夜单到期", String(format: "尾盘隔夜单的计划是次日卖出，今天还没触发止盈。收盘前处理，现盈亏 %+.2f%%。", pnl), critical: false)
                } else if h.style == "steady", held >= 1 {
                    fire("expire", "保本单到期", String(format: "保本冲高单今天没碰到 +0.5%% 卖单。回测里没成交的继续拿平均更亏，收盘前卖出，现盈亏 %+.2f%%。", pnl), critical: false)
                } else if h.style == "short", held >= 3 {
                    fire("expire", "持有到期", String(format: "短线单已持有 %d 个交易日（回测最优持有期 3 天），现盈亏 %+.2f%%。继续拿的期望不再更高，考虑收盘前离场。", held, pnl), critical: false)
                } else if h.style == "swing", held >= 10 {
                    fire("expire", "波段到期", String(format: "波段单已持有 %d 个交易日，现盈亏 %+.2f%%。回测里持有超过 10 天收益反而下降，请复核是否继续持有。", held, pnl), critical: false)
                }
            }
            changed[i] = h
        }
        if changed != holdings { holdings = changed }
        guard !newSignals.isEmpty else { return }
        sellSignals.insert(contentsOf: newSignals.reversed(), at: 0)
        if sellSignals.count > 500 { sellSignals.removeLast(sellSignals.count - 500) }
        for s in newSignals { DebugLog.write("卖点提醒 \(s.kind) code=\(s.code), price=\(s.price), pnl=\(String(format: "%.2f", s.pnl))") }
        guard sellAlertsEnabled else { return }
        NSSound(named: .init(newSignals.contains(where: \.critical) ? "Sosumi" : "Glass"))?.play()
        NSApp.requestUserAttention(newSignals.contains(where: \.critical) ? .criticalRequest : .informationalRequest)
        SellAlertPanelController.shared.show(store: self)
    }
}
