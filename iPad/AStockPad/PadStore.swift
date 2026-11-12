import AudioToolbox
import Foundation
import SwiftUI
import UIKit

struct Banner: Identifiable, Equatable {
    let id = UUID()
    let kind: String
    let name: String
    let code: String
    let text: String
}

@MainActor
final class PadStore: ObservableObject {
    @Published private(set) var quotes: [Quote] = []
    @Published private(set) var indexes: [IndexQuote] = []
    @Published private(set) var lists: [String: [StockPick]] = [:]
    @Published private(set) var breadth: MarketBreadth?
    @Published private(set) var emotion: LimitEmotion?
    @Published private(set) var pools = LimitPools()
    @Published private(set) var status = "正在连接东方财富行情…"
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var scanProgress: (done: Int, total: Int)?
    @Published private(set) var lastScan: Date?
    @Published private(set) var banner: Banner?
    @Published private(set) var unseenAlerts = 0
    @Published var alerts: [AlertRecord] = Persist.read([AlertRecord].self, "alerts.json", fallback: []) { didSet { Persist.write(alerts, "alerts.json") } }
    @Published var watch: WatchData = Persist.read(WatchData.self, "watch.json", fallback: WatchData()) { didSet { Persist.write(watch, "watch.json") } }
    @Published var settings: PadSettings = Persist.read(PadSettings.self, "settings.json", fallback: PadSettings()) { didSet { Persist.write(settings, "settings.json") } }

    // 个股分析
    @Published private(set) var analysis: StockAnalysisResult?
    @Published private(set) var analysisCandidates: [Quote] = []
    @Published private(set) var analysisMessage: String?
    @Published private(set) var analysisLoading = false
    @Published private(set) var analysisHistory: [String] = UserDefaults.standard.stringArray(forKey: "analysis.history") ?? []
    /// Set to a code to switch to the 分析 tab and analyse it (from lists / detail pages).
    @Published var analysisJump: String?
    /// 持仓与卖点提醒（与 Mac 版同一套规则和回测参数）。
    @Published var holdings: [Holding] = Persist.read([Holding].self, "holdings.json", fallback: []) { didSet { Persist.write(holdings, "holdings.json") } }
    @Published var sellSignals: [SellSignal] = Persist.read([SellSignal].self, "sell-signals.json", fallback: []) { didSet { Persist.write(sellSignals, "sell-signals.json") } }
    @Published var sellAlertsEnabled: Bool = UserDefaults.standard.object(forKey: "sellAlertsEnabled") as? Bool ?? true { didSet { UserDefaults.standard.set(sellAlertsEnabled, forKey: "sellAlertsEnabled") } }
    var pendingSellSignals: [SellSignal] { sellSignals.filter { !$0.acknowledged } }
    private var analysisTask: Task<Void, Never>?

    let tracker = TickTracker()
    private let client = EastmoneyClient.shared
    private var byCode: [String: Quote] = [:]
    private var loopTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var bannerQueue: [Banner] = []
    private var bannerTask: Task<Void, Never>?
    private var lastPoolsFetch = Date.distantPast
    private var samples: [String: [(Date, Double, Double)]] = [:]
    private var lastAlert: [String: Date] = [:]
    private var limitState: [String: Bool] = [:]
    private var limitDownState: [String: Bool] = [:]
    private var sealedToday: Set<String> = []
    private var limitDownToday: Set<String> = []
    private var limitDayKey = ""
    private var limitHistory: [String: [String]] = Persist.read([String: [String]].self, "limit-history.json", fallback: [:])
    private var historyBootstrapDay = ""

    init() {
        struct DailyDisk: Codable { let day: String; let savedAt: Date; let bars: [String: [Candle]] }
        if let disk = Persist.read(DailyDisk?.self, "daily-bars.json", fallback: nil), disk.day == Market.dayKey() {
            Task { await client.restoreDaily(disk.bars, at: disk.savedAt) }
        }
        let cutoff = Market.calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        if alerts.contains(where: { $0.time < cutoff }) { alerts.removeAll { $0.time < cutoff } }
        // Exchange Level-1 snapshots update about every 3 s and a full-market fetch takes
        // ~0.3 s, so move the old 15-second default to 3 seconds once.
        if !UserDefaults.standard.bool(forKey: "refresh.fast.v1") {
            UserDefaults.standard.set(true, forKey: "refresh.fast.v1")
            if settings.refreshSeconds == 15 { settings.refreshSeconds = 3 }
        }
    }

    // MARK: Lifecycle

    func start() {
        guard loopTask == nil else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let started = Date()
                await self.refreshOnce()
                let elapsed = Date().timeIntervalSince(started)
                let interval = Double(max(self.settings.refreshSeconds, 3))
                try? await Task.sleep(nanoseconds: UInt64(max(interval - elapsed, 1) * 1_000_000_000))
            }
        }
    }

    func stop() {
        loopTask?.cancel(); loopTask = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func refreshNow() {
        Task { await refreshOnce(); scheduleScan(force: true) }
    }

    func quote(_ code: String) -> Quote? { byCode[code] }

    // MARK: Refresh

    private func refreshOnce() async {
        do {
            let started = Date()
            async let indexTask = try? client.fetchIndexes()
            var fresh = try await client.fetchMarket()
            if Date().timeIntervalSince(lastPoolsFetch) > (Market.isSession() ? 60 : 1800) || pools.date.isEmpty {
                lastPoolsFetch = Date()
                if let fetched = try? await client.fetchLimitPools() {
                    pools = fetched
                    emotion = QuantEngine.emotion(fetched)
                    let compact = fetched.date
                    if limitHistory[compact] != Array(fetched.pool.keys).sorted() {
                        limitHistory[compact] = Array(fetched.pool.keys).sorted()
                        Persist.write(limitHistory, "limit-history.json")
                    }
                    bootstrapLimitHistory()
                }
            }
            for index in fresh.indices {
                if let item = pools.pool[fresh[index].code] ?? pools.broken[fresh[index].code] {
                    fresh[index].limitStreak = pools.pool[fresh[index].code] != nil ? item.streak : nil
                    fresh[index].firstLimitTime = item.firstTime
                    fresh[index].limitOpenCount = item.openCount
                    fresh[index].sealAmount = item.sealAmount
                }
            }
            if let indexes = await indexTask, !indexes.isEmpty { self.indexes = indexes }
            let now = Date()
            tracker.record(fresh, at: now)
            restoreLimitDay(now)
            for q in fresh { ingest(q, at: now) }
            quotes = fresh
            byCode = Dictionary(uniqueKeysWithValues: fresh.map { ($0.code, $0) })
            checkHoldings(at: now)
            breadth = QuantEngine.breadth(fresh)
            lastUpdate = now
            status = String(format: "已连接东方财富 · %d 只 · 用时 %.1f 秒", fresh.count, now.timeIntervalSince(started))
            await computeLiveLists()
            scheduleScan(force: false)
        } catch {
            status = "行情获取失败：\(error.localizedDescription)"
        }
    }

    private func context() async -> QuantContext {
        let daily = await client.dailySnapshot()
        return QuantContext(quotes: quotes, byCode: byCode, breadth: breadth ?? QuantEngine.breadth(quotes), now: Date(),
                            live: Market.isSession(), weak: breadth?.regime == "弱势", pools: pools, emotion: emotion,
                            tracker: tracker, daily: daily, limitHistory: limitHistory)
    }

    private func computeLiveLists() async {
        let ctx = await context()
        var updated = lists
        updated["surge"] = QuantEngine.surge(ctx)
        updated["limit"] = QuantEngine.limit(ctx)
        updated["leader"] = QuantEngine.leader(ctx)
        updated["tail"] = QuantEngine.tail(ctx)
        updated["overnight"] = QuantEngine.overnight(ctx)
        updated["all"] = QuantEngine.combine(updated)
        lists = updated
        autoAddPicks()
        autoAddOvernight()
        trackOvernight()
    }

    /// Daily-bar strategies: fetch bars for candidates (cached), then score.
    private func scheduleScan(force: Bool) {
        guard scanTask == nil, !quotes.isEmpty else { return }
        let interval: TimeInterval = Market.isSession() ? 300 : 1800
        guard force || lastScan.map({ Date().timeIntervalSince($0) >= interval }) ?? true else { return }
        scanTask = Task { [weak self] in
            guard let self else { return }
            await self.runScan()
            self.scanTask = nil
        }
    }

    private func runScan() async {
        let ctx = await context()
        let trendCandidates = QuantEngine.trendCandidates(ctx)
        let pullbackCandidates = QuantEngine.pullbackCandidates(ctx)
        var codes: [String] = []
        for list in ["surge", "limit", "leader", "tail"] { codes += (lists[list] ?? []).prefix(20).map(\.code) }
        codes += trendCandidates.map(\.2.code) + pullbackCandidates.map(\.code)
        var seen = Set<String>()
        codes = codes.filter { seen.insert($0).inserted }
        var missing: [String] = []
        for code in codes where await client.cachedDaily(code: code) == nil { missing.append(code) }
        scanProgress = (0, missing.count)
        var done = 0
        let client = self.client
        await withTaskGroup(of: Void.self) { group in
            var iterator = missing.makeIterator()
            for _ in 0..<min(6, missing.count) {
                if let code = iterator.next() { group.addTask { _ = try? await client.fetchDaily(code: code) } }
            }
            while await group.next() != nil {
                done += 1
                scanProgress = (done, missing.count)
                if let code = iterator.next() { group.addTask { _ = try? await client.fetchDaily(code: code) } }
            }
        }
        let full = await context()
        var updated = lists
        updated["trend"] = QuantEngine.trend(full, candidates: trendCandidates)
        updated["pullback"] = QuantEngine.pullback(full, candidates: pullbackCandidates)
        updated["all"] = QuantEngine.combine(updated)
        lists = updated
        lastScan = Date()
        scanProgress = nil
        struct DailyDisk: Codable { let day: String; let savedAt: Date; let bars: [String: [Candle]] }
        Persist.write(DailyDisk(day: Market.dayKey(), savedAt: Date(), bars: full.daily), "daily-bars.json")
        await computeLiveLists()
    }

    private func bootstrapLimitHistory() {
        let today = Market.dayKey()
        guard historyBootstrapDay != today else { return }
        historyBootstrapDay = today
        let wanted = Market.tradingDates(count: 14).filter { limitHistory[$0] == nil }
        guard !wanted.isEmpty else { return }
        Task {
            for date in wanted {
                if let codes = try? await client.fetchLimitUpCodes(date: date), !codes.isEmpty { limitHistory[date] = codes.sorted() }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let keep = Set(limitHistory.keys.sorted().suffix(20))
            limitHistory = limitHistory.filter { keep.contains($0.key) }
            Persist.write(limitHistory, "limit-history.json")
        }
    }

    // MARK: Alerts

    private func restoreLimitDay(_ now: Date) {
        let key = Market.dayKey(now)
        guard key != limitDayKey else { return }
        limitDayKey = key
        let todays = alerts.filter { Market.dayKey($0.time) == key }
        sealedToday = Set(todays.filter { ["limitUp", "limitReseal", "limitOpen"].contains($0.type) }.map(\.code))
        limitDownToday = Set(todays.filter { $0.type == "limitDown" }.map(\.code))
    }

    private func outsideCooldown(_ code: String, _ type: String, _ now: Date) -> Bool {
        let cooldown = type == "rapid" ? settings.rapidCooldownSeconds : settings.cooldownSeconds
        return now.timeIntervalSince(lastAlert["\(code):\(type)"] ?? .distantPast) >= TimeInterval(cooldown)
    }

    private func ingest(_ q: Quote, at now: Date) {
        let session = Market.isSession(now)
        var list = samples[q.code, default: []]
        let previous = list.last
        list.append((now, q.price, q.changePercent))
        list.removeAll { now.timeIntervalSince($0.0) > 360 }
        samples[q.code] = list
        let blacklisted = watch.blacklist.contains(q.code)
        let inWatch = watch.codes.contains(q.code)
        let previousToday = previous.map { Market.dayKey($0.0) == Market.dayKey(now) } ?? false
        guard session, !q.suspended, !blacklisted else {
            limitState[q.code] = q.upperLimit; limitDownState[q.code] = q.lowerLimit
            return
        }
        let moved = previousToday && abs(q.changePercent - (previous?.2 ?? q.changePercent)) >= 0.01
        if inWatch, moved, !q.isST || !settings.filterST, q.changePercent >= settings.threshold, outsideCooldown(q.code, "daily", now) {
            fire(q, type: "daily", change: q.changePercent, detail: String(format: "达到阈值 %.1f%%", settings.threshold), banner: true, now: now)
        }
        if moved, !(settings.filterST && q.isST) {
            let window = TimeInterval(min(max(settings.windowSeconds, 30), 300))
            var low: (Date, Double, Double)?
            var cursor = now
            for sample in list.dropLast().reversed() {
                guard cursor.timeIntervalSince(sample.0) <= TimeInterval(settings.refreshSeconds + 10),
                      now.timeIntervalSince(sample.0) <= window + 1, sample.1 > 0 else { break }
                if sample.1 < (low?.1 ?? .infinity) { low = sample }
                cursor = sample.0
            }
            if let low, now > low.0 {
                let rise = (q.price / low.1 - 1) * 100
                if rise >= settings.rapidThreshold, outsideCooldown(q.code, "rapid", now) {
                    let peers = Set(alerts.prefix { now.timeIntervalSince($0.time) <= 600 }
                        .filter { $0.type == "rapid" && $0.industry == q.industry && $0.code != q.code }.map(\.code)).count
                    var record = "\(Int(now.timeIntervalSince(low.0))) 秒拉升"
                    if peers > 0 { record += " · 同行业 10 分钟内另有 \(peers) 只速拉" }
                    fire(q, type: "rapid", change: rise, detail: record, banner: true, now: now, startPrice: low.1, startChange: low.2)
                }
            }
        }
        let wasUp = limitState[q.code], wasDown = limitDownState[q.code]
        limitState[q.code] = q.upperLimit; limitDownState[q.code] = q.lowerLimit
        guard inWatch || (settings.limitMonitorAll && !q.isST) else { return }
        let showBanner = inWatch || settings.limitBannerAll
        let streak = q.limitStreak.map { $0 > 1 ? "\($0) 连板" : "首板" } ?? "涨停"
        let seal = q.sealAmount.map { String(format: " · 封单 %.2f 亿", $0 / 1e8) } ?? ""
        let first = q.firstLimitTime.map { " · 首封 \($0)" } ?? ""
        if q.upperLimit, wasUp != true {
            let firstSample = wasUp == nil || !previousToday
            if !sealedToday.contains(q.code) {
                sealedToday.insert(q.code)
                fire(q, type: "limitUp", change: q.changePercent, detail: streak + first + seal + (firstSample ? " · 启动时已封板" : ""),
                     banner: showBanner && !firstSample, now: now)
            } else if !firstSample, outsideCooldown(q.code, "limitReseal", now) {
                fire(q, type: "limitReseal", change: q.changePercent, detail: (q.limitOpenCount.map { "炸板 \($0) 次后" } ?? "") + "回封 · " + streak + seal,
                     banner: showBanner, now: now)
            }
        } else if !q.upperLimit, wasUp == true, previousToday, outsideCooldown(q.code, "limitOpen", now) {
            let gap = q.limitUpPrice.map { String(format: "距涨停 %.2f%%", ($0 - q.price) / $0 * 100) } ?? ""
            fire(q, type: "limitOpen", change: q.changePercent, detail: "第 \((q.limitOpenCount ?? 0) + 1) 次炸板 · \(gap)", banner: showBanner, now: now)
        }
        if q.lowerLimit, wasDown == false, previousToday, !limitDownToday.contains(q.code) {
            limitDownToday.insert(q.code)
            fire(q, type: "limitDown", change: q.changePercent, detail: "封跌停", banner: inWatch, now: now)
        }
    }

    private func fire(_ q: Quote, type: String, change: Double, detail: String, banner showBanner: Bool, now: Date,
                      startPrice: Double? = nil, startChange: Double? = nil) {
        lastAlert["\(q.code):\(type)"] = now
        let record = AlertRecord(code: q.code, name: q.name, time: now, price: q.price, change: change, type: type,
                                 industry: q.industry.isEmpty ? nil : q.industry, detail: detail, startPrice: startPrice,
                                 startChangePercent: startChange, limitStreak: type.hasPrefix("limit") ? q.limitStreak : nil,
                                 silent: showBanner ? nil : true)
        alerts.insert(record, at: 0)
        if alerts.count > 1500 { alerts.removeLast(alerts.count - 1500) }
        unseenAlerts += 1
        if showBanner {
            let text = type == "rapid"
                ? String(format: "%@：%.2f → %.2f，区间 %+.2f%%", detail, startPrice ?? q.price, q.price, change)
                : String(format: "%@ ¥%.2f（%+.2f%%）", detail, q.price, q.changePercent)
            enqueue(Banner(kind: AlertRecord.label(type), name: q.name, code: q.code, text: text))
        }
    }

    func markAlertsSeen() { unseenAlerts = 0 }
    func deleteAlerts(_ ids: Set<UUID>) { alerts.removeAll { ids.contains($0.id) } }

    private func enqueue(_ banner: Banner) {
        bannerQueue.append(banner)
        if self.banner == nil { showNextBanner() }
    }
    private func showNextBanner() {
        guard !bannerQueue.isEmpty else { banner = nil; return }
        banner = bannerQueue.removeFirst()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.showNextBanner()
        }
    }
    func dismissBanner() { bannerTask?.cancel(); showNextBanner() }

    // MARK: Daily picks (主板 / 创业科创 各 N 只)

    private func autoAddPicks() {
        let now = Date()
        guard settings.autoPicks, Market.isSession(now) else { return }
        let day = Market.dayKey(now)
        let limit = min(max(settings.dailyPickLimit, 3), 30)
        var updated = watch
        let ranked = lists["all"] ?? []
        let latest = Dictionary(ranked.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })
        var picks = (updated.picksByDay[day] ?? []).filter {
            updated.codes.contains($0.code) && updated.groupByCode[$0.code] == WatchData.pickGroupName(day: day, code: $0.code)
        }
        for i in picks.indices { picks[i].score = latest[picks[i].code]?.score ?? max(picks[i].score - 10, 0) }
        var replaced = Set(updated.replacedByDay[day] ?? [])
        var added: [DailyPick] = [], swaps: [(DailyPick, DailyPick)] = []
        for stock in ranked where stock.grade == "A" {
            guard !updated.codes.contains(stock.code), !replaced.contains(stock.code), !updated.blacklist.contains(stock.code),
                  stock.buyable, let live = byCode[stock.code], !live.upperLimit, !live.suspended, !live.isST else { continue }
            if let up = live.limitUpPrice, live.price >= up - 0.01 { continue }
            let board = WatchData.pickBoard(code: stock.code)
            let group = WatchData.pickGroupName(day: day, board: board)
            let pick = DailyPick(pick: stock, price: live.price, time: now)
            let boardIndices = picks.indices.filter { WatchData.pickBoard(code: picks[$0].code) == board }
            // Sealed limit-up picks stay in the group but no longer use up the quota.
            let buyableCount = boardIndices.filter { byCode[picks[$0].code]?.upperLimit != true }.count
            if buyableCount < limit {
                picks.append(pick); added.append(pick)
            } else {
                let replaceable = boardIndices.filter { byCode[picks[$0].code]?.upperLimit != true && now.timeIntervalSince(picks[$0].time) >= 600 }
                guard let weakest = replaceable.min(by: { picks[$0].score < picks[$1].score }), stock.score >= picks[weakest].score + 3 else { continue }
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
        let days = updated.picksByDay.keys.sorted()
        for old in days.dropLast(30) {
            let groups = Set(WatchData.pickBoards.map { WatchData.pickGroupName(day: old, board: $0) })
            let codes = Set(updated.codes.filter { groups.contains(updated.groupByCode[$0] ?? "") })
            updated.codes.removeAll { codes.contains($0) }
            for code in codes { updated.groupByCode.removeValue(forKey: code) }
            updated.groups.removeAll { groups.contains($0) }
            updated.picksByDay.removeValue(forKey: old); updated.replacedByDay.removeValue(forKey: old)
        }
        if updated != watch { watch = updated }
        for board in WatchData.pickBoards {
            let boardAdded = added.filter { WatchData.pickBoard(code: $0.code) == board }
            guard let firstPick = boardAdded.first else { continue }
            let names = boardAdded.map(\.name)
            enqueue(Banner(kind: "当日推荐", name: names.prefix(3).joined(separator: "、") + (names.count > 3 ? " 等" : ""), code: firstPick.code,
                           text: "综合 A 级、未涨停可买入，加入「\(WatchData.pickGroupName(day: day, board: board))」"))
        }
        for (out, into) in swaps {
            enqueue(Banner(kind: "推荐替换", name: into.name, code: into.code, text: "评分 \(into.score) 替换 \(out.name)（\(out.score)）"))
        }
    }

    func pickHistory(_ code: String) -> [(day: String, pick: DailyPick)] {
        let daily = watch.picksByDay.compactMap { day, picks in picks.first { $0.code == code }.map { (day, $0) } }
        let overnight = (watch.overnightByDay ?? [:]).compactMap { day, picks in picks.first { $0.code == code }.map { (day, $0) } }
        return (daily + overnight).sorted { ($0.day, $0.pick.time) > ($1.day, $1.pick.time) }
    }

    // MARK: 尾盘隔夜 (14:50 锁定，次日跟踪)

    /// At 14:50–15:00 lock the top `overnightLimit` 尾盘隔夜 picks of each board once.
    private func autoAddOvernight() {
        let now = Date()
        guard settings.autoOvernight, Market.isSession(now), (890..<900).contains(Market.minuteOfDay(now)) else { return }
        let day = Market.dayKey(now)
        guard watch.overnightByDay?[day] == nil else { return }
        let ranked = lists["overnight"] ?? []
        guard !ranked.isEmpty else { return }
        var updated = watch
        var picks: [DailyPick] = []
        var watched: [String: [String]] = [:]
        for board in WatchData.pickBoards {
            let group = WatchData.overnightGroupName(day: day, board: board)
            let candidates = ranked.filter { ($0.board ?? WatchData.pickBoard(code: $0.code)) == board && !updated.blacklist.contains($0.code) }
                .filter { byCode[$0.code].map { !$0.upperLimit && !$0.suspended && !$0.isST } ?? true }
            for stock in candidates.prefix(settings.overnightLimit) {
                picks.append(DailyPick(pick: stock, price: byCode[stock.code]?.price ?? stock.price, time: now))
                if updated.codes.contains(stock.code) {
                    watched[board, default: []].append(stock.name)
                } else {
                    updated.codes.append(stock.code)
                    updated.groupByCode[stock.code] = group
                    if !updated.groups.contains(group) { updated.groups.append(group) }
                }
            }
        }
        guard !picks.isEmpty else { return }
        var byDay = updated.overnightByDay ?? [:]
        byDay[day] = picks
        for old in byDay.keys.sorted().dropLast(30) {
            let groups = Set(WatchData.pickBoards.map { WatchData.overnightGroupName(day: old, board: $0) })
            let codes = Set(updated.codes.filter { groups.contains(updated.groupByCode[$0] ?? "") })
            updated.codes.removeAll { codes.contains($0) }
            for code in codes { updated.groupByCode.removeValue(forKey: code) }
            updated.groups.removeAll { groups.contains($0) }
            byDay.removeValue(forKey: old)
        }
        updated.overnightByDay = byDay
        watch = updated
        for board in WatchData.pickBoards {
            let boardPicks = picks.filter { WatchData.pickBoard(code: $0.code) == board }
            guard let first = boardPicks.first else { continue }
            let others = watched[board] ?? []
            enqueue(Banner(kind: "尾盘隔夜", name: boardPicks.prefix(3).map(\.name).joined(separator: "、") + (boardPicks.count > 3 ? " 等" : ""),
                           code: first.code,
                           text: "\(board) \(boardPicks.count) 只锁定到「\(WatchData.overnightGroupName(day: day, board: board))」"
                               + (others.isEmpty ? "" : "（\(others.joined(separator: "、")) 已在其他分组）") + "，次日挂 +3% 止盈"))
        }
    }

    /// Next trading day: record open / high / latest of the previous day's 隔夜 picks from the live snapshot.
    private func trackOvernight() {
        let now = Date()
        guard Market.isSession(now) || (900..<930).contains(Market.minuteOfDay(now)), var byDay = watch.overnightByDay else { return }
        let today = Market.dayKey(now)
        guard let day = byDay.keys.filter({ $0 < today }).max(), var picks = byDay[day] else { return }
        var changed = false
        for i in picks.indices where picks[i].nextDay == nil || picks[i].nextDay == today {
            guard let q = byCode[picks[i].code], let open = q.open, open > 0, q.price > 0 else { continue }
            let high = max(q.high ?? q.price, picks[i].nextHigh ?? 0)
            if picks[i].nextDay != today || picks[i].nextOpen != open || picks[i].nextHigh != high || picks[i].nextClose != q.price {
                picks[i].nextDay = today; picks[i].nextOpen = open; picks[i].nextHigh = high; picks[i].nextClose = q.price
                changed = true
            }
        }
        guard changed else { return }
        byDay[day] = picks
        watch.overnightByDay = byDay
    }

    func overnightPick(_ code: String) -> (day: String, pick: DailyPick)? {
        guard let group = watch.groupByCode[code], group.hasPrefix(WatchData.overnightGroupPrefix) else { return nil }
        for (day, picks) in watch.overnightByDay ?? [:] where WatchData.overnightGroupName(day: day, code: code) == group {
            if let pick = picks.first(where: { $0.code == code }) { return (day, pick) }
        }
        return nil
    }

    func overnightSummary(group: String) -> (day: String, count: Int, tracked: Int, hit3: Int, hit5: Int, avgOpen: Double?, avgHigh: Double?)? {
        for (day, picks) in watch.overnightByDay ?? [:] {
            for board in WatchData.pickBoards where WatchData.overnightGroupName(day: day, board: board) == group {
                let members = picks.filter { WatchData.pickBoard(code: $0.code) == board }
                guard !members.isEmpty else { return nil }
                let tracked = members.filter { $0.nextOpen != nil }
                func avg(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
                return (day, members.count, tracked.count,
                        tracked.filter { ($0.nextHighReturn ?? -99) >= 3 }.count, tracked.filter { ($0.nextHighReturn ?? -99) >= 5 }.count,
                        avg(tracked.compactMap(\.nextOpenReturn)), avg(tracked.compactMap(\.nextHighReturn)))
            }
        }
        return nil
    }

    func overnightTrackRecord() -> (picks: Int, hit3: Int, hit5: Int, avgOpen: Double?, avgHigh: Double?)? {
        let tracked = (watch.overnightByDay ?? [:]).values.flatMap { $0 }.filter { $0.nextOpen != nil }
        guard !tracked.isEmpty else { return nil }
        let opens = tracked.compactMap(\.nextOpenReturn), highs = tracked.compactMap(\.nextHighReturn)
        return (tracked.count, highs.filter { $0 >= 3 }.count, highs.filter { $0 >= 5 }.count,
                opens.isEmpty ? nil : opens.reduce(0, +) / Double(opens.count),
                highs.isEmpty ? nil : highs.reduce(0, +) / Double(highs.count))
    }

    func picksSummary(group: String) -> (count: Int, average: Double?, winners: Int, sealed: Int)? {
        for (day, picks) in watch.picksByDay {
            for board in WatchData.pickBoards where WatchData.pickGroupName(day: day, board: board) == group {
                let members = picks.filter { WatchData.pickBoard(code: $0.code) == board && watch.groupByCode[$0.code] == group }
                guard !members.isEmpty else { return nil }
                let returns = members.compactMap { p -> Double? in
                    guard p.price > 0, let q = byCode[p.code], q.price > 0 else { return nil }
                    return (q.price / p.price - 1) * 100
                }
                let sealed = members.filter { byCode[$0.code]?.upperLimit == true }.count
                return (members.count, returns.isEmpty ? nil : returns.reduce(0, +) / Double(returns.count), returns.filter { $0 > 0 }.count, sealed)
            }
        }
        return nil
    }

    // MARK: 个股分析

    func analyze(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        let digits = query.filter(\.isNumber)
        var target: Quote?
        if digits.count == 6 {
            target = byCode[digits]
        } else {
            let key = query.uppercased().replacingOccurrences(of: " ", with: "")
            let exact = quotes.first { $0.name.uppercased().replacingOccurrences(of: " ", with: "") == key }
            let partial = quotes.filter { $0.name.uppercased().contains(key) }
            target = exact ?? (partial.count == 1 ? partial[0] : nil)
            if target == nil, partial.count > 1 {
                analysisCandidates = Array(partial.prefix(12)); analysisMessage = "匹配到多只股票，请选择"; analysis = nil
                return
            }
        }
        analysisCandidates = []
        guard let q = target else { analysisMessage = quotes.isEmpty ? "行情还在加载，请稍后再试" : "没有找到这只股票"; analysis = nil; return }
        guard !q.suspended, q.price > 0 else { analysisMessage = "该股停牌或暂无报价"; analysis = nil; return }
        analysisMessage = nil
        analysisLoading = true
        analysisTask?.cancel()
        analysisTask = Task {
            async let historyTask = try? client.fetchDaily(code: q.code)
            async let extrasTask = client.fetchAnalysisExtras(code: q.code)
            async let newsTask = try? client.fetchNews(code: q.code)
            let (history, extras, news) = await (historyTask, extrasTask, newsTask)
            guard !Task.isCancelled else { return }
            let live = byCode[q.code] ?? q
            analysis = AnalysisEngine.analyze(live, history: history ?? [], lists: lists, breadth: breadth, emotion: emotion, pools: pools,
                                              tracker: tracker, extras: extras, news: news ?? [], now: Date())
            analysisLoading = false
            let entry = "\(q.code) \(q.name)"
            analysisHistory = [entry] + analysisHistory.filter { $0 != entry }.prefix(11)
            UserDefaults.standard.set(analysisHistory, forKey: "analysis.history")
        }
    }

    // MARK: Watchlist

    func toggleWatch(_ code: String) {
        if watch.codes.contains(code) {
            watch.codes.removeAll { $0 == code }; watch.groupByCode.removeValue(forKey: code)
        } else {
            watch.codes.append(code); watch.groupByCode[code] = watch.groups.first ?? "默认分组"
        }
    }
    func addCode(_ raw: String) {
        let code = raw.filter(\.isNumber)
        guard code.count == 6, !watch.codes.contains(code) else { return }
        watch.codes.append(code); watch.groupByCode[code] = watch.groups.first ?? "默认分组"
    }
    func toggleBlacklist(_ code: String) {
        if watch.blacklist.contains(code) { watch.blacklist.removeAll { $0 == code } } else { watch.blacklist.append(code) }
    }
    func moveWatch(from source: IndexSet, to destination: Int, in codes: [String]) {
        var reordered = codes
        reordered.move(fromOffsets: source, toOffset: destination)
        let others = watch.codes.filter { !codes.contains($0) }
        watch.codes = reordered + others
    }

    /// Live quantitative profile for the detail panel (same fields as the Mac's /stock-insight).
    func insight(for code: String) async -> [(String, [(String, String, Int)])] {
        guard let q = byCode[code] else { return [] }
        var groups: [(String, [(String, String, Int)])] = []
        func tone(_ value: Double?, _ neutral: Double = 0) -> Int { guard let value else { return 0 }; return value > neutral ? 1 : (value < neutral ? -1 : 0) }
        var position: Double?
        var amplitude: Double?
        if let h = q.high, let l = q.low, h > l {
            position = (q.price - l) / (h - l) * 100
            if let base = q.prevClose, base > 0 { amplitude = (h - l) / base * 100 }
        }
        groups.append(("当日行情", [
            ("涨跌幅", Fmt.pct(q.changePercent), tone(q.changePercent)),
            ("今开 / 昨收", "\(Fmt.price(q.open)) / \(Fmt.price(q.prevClose))", 0),
            ("最高 / 最低", "\(Fmt.price(q.high)) / \(Fmt.price(q.low))", 0),
            ("振幅", amplitude.map { String(format: "%.2f%%", $0) } ?? "—", 0),
            ("日内位置", position.map { String(format: "%.0f%%", $0) } ?? "—", (position ?? 0) >= 80 ? 1 : 0),
            ("成交额", Fmt.yuan(q.amount), 0),
            ("量比", q.volumeRatio.map { String(format: "%.2f", $0) } ?? "—", tone(q.volumeRatio, 1.5)),
            ("换手率", q.turnover.map { String(format: "%.2f%%", $0) } ?? "—", 0),
            ("流通市值", Fmt.yuan(q.floatMarketCap), 0),
            ("涨停价", Fmt.price(q.limitUpPrice), 0),
        ]))
        let m = tracker.metrics(code)
        var speed: [(String, String, Int)] = [
            ("1 分钟涨速", Fmt.pct(m.speed1), tone(m.speed1)), ("3 分钟涨速", Fmt.pct(m.speed3), tone(m.speed3)),
            ("5 分钟涨速", Fmt.pct(m.speed5), tone(m.speed5)), ("5 分钟低点拉升", Fmt.pct(m.rise5), tone(m.rise5)),
            ("近 3 分钟额速", m.accel.map { String(format: "%.1f×", $0) } ?? "—", tone(m.accel, 2)),
        ]
        let events = tracker.events[code] ?? []
        speed.append(("今日速拉", events.isEmpty ? "无" : "\(events.count) 次", events.isEmpty ? 0 : 1))
        for e in events.suffix(4) { speed.append(("\(e.time) 速拉", String(format: "%d 秒 +%.1f%%，额速 %.1f×", e.seconds, e.rise, e.accel), 1)) }
        groups.append(("盘中速度（本机逐快照）", speed))
        if let item = pools.pool[code] ?? pools.broken[code] {
            groups.append(("涨停数据（东方财富涨停池）", [
                ("状态", pools.pool[code] != nil ? "封板" : "炸板", pools.pool[code] != nil ? 1 : 0),
                ("首次封板", item.firstTime ?? "—", 0), ("炸板次数", "\(item.openCount)", 0),
                ("连板", pools.pool[code] != nil ? "\(item.streak) 板" : "—", 1), ("封单", Fmt.yuan(item.sealAmount), 0),
                ("涨停统计", item.stat ?? "—", 0),
            ]))
        }
        let candles: [Candle]
        if let cached = await client.cachedDaily(code: code) { candles = cached } else { candles = (try? await client.fetchDaily(code: code)) ?? [] }
        if let f = DailyFeatures.compute(q, candles) {
            let trendText = f.ma5 > f.ma10 && f.ma10 > f.ma20 && f.ma20 > f.ma60 ? "均线多头" : (f.price > f.ma20 ? "站上 20 日线" : "20 日线下方")
            groups.append(("日线结构（前复权）", [
                ("趋势", trendText, trendText == "20 日线下方" ? -1 : 1),
                ("MA5 / MA10", String(format: "%.2f / %.2f", f.ma5, f.ma10), 0),
                ("MA20 / MA60", String(format: "%.2f / %.2f", f.ma20, f.ma60), 0),
                ("均线粘合度", String(format: "%.1f%%", f.maSpread * 100), f.maSpread < 0.03 ? 1 : 0),
                ("乖离 20 日线", Fmt.pct(f.bias20 * 100), f.bias20 > 0.15 ? -1 : tone(f.bias20)),
                ("近 5 / 20 / 60 日", String(format: "%+.1f%% / %+.1f%% / %+.1f%%", f.ret5 * 100, f.ret20 * 100, f.ret60 * 100), tone(f.ret20)),
                ("距 60 日高点", Fmt.pct((f.price / f.high60 - 1) * 100), f.price > f.high60 ? 1 : 0),
                ("成交额 / 5 日均额", f.amountRatio.map { String(format: "%.2f×", $0) } ?? "—", tone(f.amountRatio, 1.5)),
                ("5 日 / 20 日均额", f.avg20 > 0 ? String(format: "%.2f", f.avg5 / f.avg20) : "—", 0),
                ("近 20 日红肥绿瘦", f.downAmount > 0 ? String(format: "%.2f", f.upAmount / f.downAmount) : "—", f.downAmount > 0 && f.upAmount / f.downAmount > 1.5 ? 1 : 0),
                ("MACD", f.goldenCross ? (f.dif > 0 ? "零轴上方金叉" : "金叉") : (f.dif > f.dea ? "多头" : "空头"), f.dif > f.dea ? 1 : -1),
                ("近 15 日涨停", "\(f.limitUps15) 次", f.limitUps15 > 0 ? 1 : 0),
            ]))
        }
        return groups
    }
}

// MARK: - 持仓卖点监控（逻辑与 Mac 版 MonitorStore.checkHoldings 一致）

extension PadStore {
    func addHolding(code: String, cost: Double, shares: Int?, buyDate: Date, style: String) {
        let name = quote(code)?.name ?? code
        var holding = Holding.make(code: code, name: name, cost: cost, shares: shares, buyDate: buyDate, style: style)
        if let q = quote(code) {
            let boughtToday = Market.dayKey(buyDate) == Market.dayKey()
            holding.peakPrice = max(cost, boughtToday ? q.price : (q.high ?? q.price))
        }
        holdings.append(holding)
        let id = holding.id
        Task {
            // 用日线补全买入后的最高价；波段止损参考 20 日线。
            guard let bars = try? await client.fetchDaily(code: code, limit: 60), let index = holdings.firstIndex(where: { $0.id == id }) else { return }
            var h = holdings[index]
            let bought = Market.dayKey(h.buyDate)
            if let high = bars.filter({ $0.date > bought }).map(\.high).max() { h.peakPrice = max(h.peakPrice, high) }
            let closes = bars.map(\.close)
            if style == "swing", closes.count >= 20 {
                let ma20 = closes.suffix(20).reduce(0, +) / 20
                if ma20 < h.cost { h.stopPrice = max(h.stopPrice, (ma20 * 0.98 * 100).rounded() / 100) }
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

    func tradingDaysHeld(_ h: Holding, now: Date = Date()) -> Int {
        let cal = Market.calendar
        var day = cal.startOfDay(for: h.buyDate), n = 0
        let end = cal.startOfDay(for: now)
        while day < end {
            day = cal.date(byAdding: .day, value: 1, to: day)!
            let wd = cal.component(.weekday, from: day)
            if wd != 1 && wd != 7 { n += 1 }
        }
        return n
    }

    func checkHoldings(at now: Date) {
        guard !holdings.isEmpty else { return }
        let today = Market.dayKey(now)
        let minutes = Market.minuteOfDay(now)
        let session = Market.isSession(now)
        var changed = holdings
        var newSignals: [SellSignal] = []
        for i in changed.indices {
            var h = changed[i]
            guard let q = quote(h.code), q.price > 0, !q.suspended else { continue }
            let boughtToday = Market.dayKey(h.buyDate) == today
            if session { h.peakPrice = max(h.peakPrice, boughtToday ? q.price : (q.high ?? q.price)) }
            if q.upperLimit && session { h.sealedDay = today }
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
        guard sellAlertsEnabled else { return }
        AudioServicesPlaySystemSound(newSignals.contains(where: \.critical) ? 1005 : 1007)
    }
}
