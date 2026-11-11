import Foundation

struct Quote: Codable, Identifiable, Hashable {
    var code: String
    var name: String
    var price: Double
    var changePercent: Double
    var volume: Double
    var amount: Double
    var turnover: Double?
    var volumeRatio: Double?
    var totalMarketCap: Double?
    var floatMarketCap: Double?
    var annualNetProfit: Double?
    var annualReportYear: Int?
    var quarterlyNetProfit: Double?
    var quarterlyReportLabel: String?
    var industry: String?
    var concept: String?
    var suspended: Bool = false
    var isST: Bool = false
    var upperLimit: Bool = false
    var lowerLimit: Bool = false
    var bidAmount: Double?
    /// Session OHLC context and exchange limit prices supplied by the bridge (API 15+).
    var open: Double?
    var high: Double?
    var low: Double?
    var prevClose: Double?
    var limitUpPrice: Double?
    var limitDownPrice: Double?
    /// Eastmoney limit-up pool fields (API 17+): consecutive boards, first seal
    /// time (HH:mm:ss), number of times the seal opened and the sealing order amount.
    var limitStreak: Int?
    var firstLimitTime: String?
    var limitOpenCount: Int?
    var sealAmount: Double?
    var limitIndustry: String?
    var timestamp: Date = Date()
    var id: String { code }
    var board: String { code.hasPrefix("688") || code.hasPrefix("689") ? "科创板" : (code.hasPrefix("300") || code.hasPrefix("301") ? "创业板" : "主板") }
}

/// One screened stock from the bridge's /potential endpoint.
struct PotentialStock: Decodable, Identifiable, Hashable {
    let code: String
    let name: String
    let price: Double
    let changePercent: Double
    let industry: String?
    let score: Int
    let grade: String
    let signals: [String]
    let risks: [String]
    /// Strategy that produced the row, and every strategy that selected it (combined list).
    let strategy: String?
    let strategies: [String]?
    /// Short badges (sector, 首板 / 连板, 冲板中…) and key metrics for the strategy.
    let tags: [String]?
    let highlights: [String]?
    let limitStreak: Int?
    let firstLimitTime: String?
    let surgeTime: String?
    let buyable: Bool?
    /// Breakout level (or 10-day average) a pullback should hold.
    let pivot: Double?
    /// Reference exit level; riskPercent is the distance from the current price.
    let stopLoss: Double?
    let riskPercent: Double?
    let amountRatio: Double?
    let ret20: Double?
    let bias20: Double?
    let volumeRatio: Double?
    let turnover: Double?
    let amount: Double?
    /// 尾盘隔夜: estimated probability (%) that tomorrow's high is ≥ 3% / ≥ 5% above the
    /// current price, the suggested take-profit price and the board it is ranked in.
    let pHi3: Double?
    let pHi5: Double?
    let takeProfit: Double?
    let board: String?
    var id: String { code }
}

struct DayOHLC: Decodable, Hashable {
    let price: Double?
    let open: Double?
    let high: Double?
    let low: Double?
}

struct PotentialMarket: Decodable, Hashable {
    let upCount: Int
    let downCount: Int
    let flatCount: Int
    let upRatio: Double
    let medianChange: Double
    let regime: String
    let limitUpCount: Int
    let limitDownCount: Int
    let strongIndustries: [String]
}

/// Limit-up sentiment (涨停情绪) derived from Eastmoney's limit-up pools.
struct LimitEmotion: Decodable, Hashable {
    struct Ladder: Decodable, Hashable { let streak: Int; let count: Int; let names: [String] }
    struct IndustryCount: Decodable, Hashable { let name: String; let count: Int }
    let date: String?
    let limitUpCount: Int
    let brokenCount: Int
    let brokenRate: Double?
    let maxStreak: Int
    let previousPremium: Double?
    let mood: String
    let ladder: [Ladder]
    let topIndustries: [IndustryCount]
}

struct PotentialStrategy: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let summary: String
    let description: String
    let count: Int
    let note: String?
}

struct PotentialReport: Decodable {
    let updatedAt: String?
    let liveUpdatedAt: String?
    let scanning: Bool
    let progress: Int
    let total: Int
    let phase: String?
    let market: PotentialMarket?
    let emotion: LimitEmotion?
    let strategies: [PotentialStrategy]?
    let lists: [String: [PotentialStock]]?
    let stocks: [PotentialStock]
    let error: String?
}

struct MarketIndex: Codable, Identifiable, Hashable {
    var symbol: String
    var name: String
    var price: Double
    var previousClose: Double
    var changePercent: Double
    var id: String { symbol }
}

struct PricePoint: Identifiable {
    let id = UUID()
    let date: Date
    let price: Double
    /// Same-day quote change, populated for live samples used by rapid alerts.
    var changePercent: Double? = nil
}
struct CandlePoint: Identifiable {
    let id = UUID()
    let date: Date
    let open: Double
    let high: Double
    let low: Double
    let close: Double
}
struct AlertRecord: Codable, Identifiable {
    var id = UUID(); let code: String; let name: String; let time: Date; let price: Double; let change: Double
    /// Starting quote price for sampled rapid-rise alerts. Older records omit it.
    var startPrice: Double? = nil
    /// Same-day change at the beginning and trigger snapshots for rapid alerts.
    var startChangePercent: Double? = nil
    var triggerChangePercent: Double? = nil
    /// Mirrors the alert type for presentation; nil identifies legacy records.
    var changeBasis: String? = nil
    /// daily = same-day percentage threshold; rapid10 = adjacent-snapshot rise (legacy identifier).
    /// Missing values are kept readable as legacy records after upgrading.
    var alertType: String? = nil
    /// Industry / sector label, a human-readable explanation and the consecutive
    /// limit-up count at trigger time (limit events). Missing on older records.
    var industry: String? = nil
    var detail: String? = nil
    var limitStreak: Int? = nil
    /// Logged without a toast (e.g. limit-ups of non-watchlist stocks).
    var silent: Bool? = nil
}
extension AlertRecord {
    static let limitTypes: Set<String> = ["limitUp", "limitReseal", "limitOpen", "limitDown"]
    static func typeLabel(_ type: String?) -> String {
        switch type ?? "" {
        case "daily": "涨幅"
        case "limitUp": "涨停"
        case "limitReseal": "回封"
        case "limitOpen": "炸板"
        case "limitDown": "跌停"
        case "rapid10": "速拉"
        default: "涨幅"
        }
    }
    /// Rows for the 涨幅 / 涨停 side of the log (legacy records without a type
    /// but with a daily basis count as daily-gain alerts).
    var isDailyOrLimit: Bool {
        if let alertType { return alertType == "daily" || Self.limitTypes.contains(alertType) }
        return changeBasis == "daily"
    }
}

/// Today's limit-up board computed from the live snapshot.
struct LimitSummary {
    let sealed: Int
    let opened: Int
    let limitDown: Int
    let maxStreak: Int
    let brokenRate: Double?
    let topIndustries: [(String, Int)]
}

struct AlertToast: Identifiable {
    let id = UUID()
    let shortType: String
    let name: String
    let code: String
    let effect: String
}
struct MonitorSettings: Codable {
    /// Alert when the market quote's daily change reaches this level.
    var threshold = 5.0
    /// Alert when the price rises this much from its low inside the rapid window.
    var rapidThreshold = 3.0
    /// Rapid-rise look-back window in seconds (30–300).
    var windowSeconds = 60
    // Tencent full-market snapshot takes about 7 seconds in observed runs.
    // A 10-second cadence allows a fresh request after each completed snapshot.
    var refreshSeconds = 3
    var cooldownSeconds = 180
    var rapidCooldownSeconds = 180
    var volumeMultiple = 1.0
    var requireVolume = false
    var filterST = true
    var filterSuspended = true
    /// Log limit-up / opened / re-sealed events for every A-share (true) or only the watchlist.
    var limitMonitorAll = true
    /// Show a toast for non-watchlist limit events too (they are always logged).
    var limitToastAll = false
    /// Log limit-down events (watchlist toast, full-market log when limitMonitorAll).
    var limitDownAlerts = true
    /// During the session, add 综合 A-grade picks that are not limit-up and still
    /// buyable to the 当日自选 group; the previous day's auto picks are cleared.
    var autoAddDailyPicks = true
    /// Maximum recommendations per trading day (stronger picks replace weaker ones).
    var dailyPickLimit = 10
    /// At 14:50 lock the 尾盘隔夜 top picks of each board into dated 隔夜 groups.
    var autoOvernightPicks = true
    var overnightPickLimit = 10

    private enum CodingKeys: String, CodingKey {
        case threshold, rapidThreshold, windowSeconds, refreshSeconds, cooldownSeconds, rapidCooldownSeconds, cooldownMinutes, volumeMultiple
        case requireVolume, filterST, filterSuspended, limitMonitorAll, limitToastAll, limitDownAlerts, autoAddDailyPicks, dailyPickLimit
        case autoOvernightPicks, overnightPickLimit
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        threshold = min(max(try values.decodeIfPresent(Double.self, forKey: .threshold) ?? 5.0, 0), 30)
        rapidThreshold = min(max(try values.decodeIfPresent(Double.self, forKey: .rapidThreshold) ?? 3.0, 0), 30)
        windowSeconds = min(max(try values.decodeIfPresent(Int.self, forKey: .windowSeconds) ?? 60, 30), 300)
        refreshSeconds = try values.decodeIfPresent(Int.self, forKey: .refreshSeconds) ?? 3
        // Keep settings.json files from older app versions working. Older builds
        // stored cooldown in minutes; new builds store it in seconds.
        let legacyCooldownMinutes = try values.decodeIfPresent(Int.self, forKey: .cooldownMinutes)
        let savedCooldownSeconds = try values.decodeIfPresent(Int.self, forKey: .cooldownSeconds)
            ?? legacyCooldownMinutes.map { $0 * 60 }
            ?? 180
        cooldownSeconds = min(max(savedCooldownSeconds, 10), 600)
        rapidCooldownSeconds = min(max(try values.decodeIfPresent(Int.self, forKey: .rapidCooldownSeconds) ?? savedCooldownSeconds, 10), 600)
        volumeMultiple = try values.decodeIfPresent(Double.self, forKey: .volumeMultiple) ?? 1.0
        requireVolume = try values.decodeIfPresent(Bool.self, forKey: .requireVolume) ?? false
        filterST = try values.decodeIfPresent(Bool.self, forKey: .filterST) ?? true
        filterSuspended = try values.decodeIfPresent(Bool.self, forKey: .filterSuspended) ?? true
        limitMonitorAll = try values.decodeIfPresent(Bool.self, forKey: .limitMonitorAll) ?? true
        limitToastAll = try values.decodeIfPresent(Bool.self, forKey: .limitToastAll) ?? false
        limitDownAlerts = try values.decodeIfPresent(Bool.self, forKey: .limitDownAlerts) ?? true
        autoAddDailyPicks = try values.decodeIfPresent(Bool.self, forKey: .autoAddDailyPicks) ?? true
        dailyPickLimit = min(max(try values.decodeIfPresent(Int.self, forKey: .dailyPickLimit) ?? 10, 3), 30)
        autoOvernightPicks = try values.decodeIfPresent(Bool.self, forKey: .autoOvernightPicks) ?? true
        overnightPickLimit = min(max(try values.decodeIfPresent(Int.self, forKey: .overnightPickLimit) ?? 10, 3), 15)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(threshold, forKey: .threshold)
        try values.encode(rapidThreshold, forKey: .rapidThreshold)
        try values.encode(windowSeconds, forKey: .windowSeconds)
        try values.encode(refreshSeconds, forKey: .refreshSeconds)
        try values.encode(cooldownSeconds, forKey: .cooldownSeconds)
        try values.encode(rapidCooldownSeconds, forKey: .rapidCooldownSeconds)
        try values.encode(volumeMultiple, forKey: .volumeMultiple)
        try values.encode(requireVolume, forKey: .requireVolume)
        try values.encode(filterST, forKey: .filterST)
        try values.encode(filterSuspended, forKey: .filterSuspended)
        try values.encode(limitMonitorAll, forKey: .limitMonitorAll)
        try values.encode(limitToastAll, forKey: .limitToastAll)
        try values.encode(limitDownAlerts, forKey: .limitDownAlerts)
        try values.encode(autoAddDailyPicks, forKey: .autoAddDailyPicks)
        try values.encode(dailyPickLimit, forKey: .dailyPickLimit)
        try values.encode(autoOvernightPicks, forKey: .autoOvernightPicks)
        try values.encode(overnightPickLimit, forKey: .overnightPickLimit)
    }
}
struct FilterCriteria: Codable {
    var enabled: Set<String> = []
    var minimums: [String: Double] = ["price": 0, "changePercent": 0, "volumeRatio": 1, "turnover": 0, "amount": 0, "floatMarketCap": 0]
    var maximums: [String: Double] = [:]
    var direction: String = "全部"

    private enum CodingKeys: String, CodingKey { case enabled, minimums, maximums, direction }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Set<String>.self, forKey: .enabled) ?? []
        minimums = try values.decodeIfPresent([String: Double].self, forKey: .minimums) ?? ["price": 0, "changePercent": 0, "volumeRatio": 1, "turnover": 0, "amount": 0, "floatMarketCap": 0]
        maximums = try values.decodeIfPresent([String: Double].self, forKey: .maximums) ?? [:]
        direction = try values.decodeIfPresent(String.self, forKey: .direction) ?? "全部"
    }
}
/// One automatic daily recommendation (综合 A 级、未涨停、可买入).
struct DailyPick: Codable, Hashable {
    var code: String
    var name: String
    /// Score when first recommended and the latest score from the screener.
    var initialScore: Int
    var score: Int
    /// Price when recommended, for tracking the return since the pick.
    var price: Double
    var time: Date
    var strategies: [String] = []
    /// Snapshot of why it was recommended (screener output at pick time).
    var grade: String? = nil
    var signals: [String]? = nil
    var risks: [String]? = nil
    var highlights: [String]? = nil
    var tags: [String]? = nil
    var pivot: Double? = nil
    var stopLoss: Double? = nil
    var riskPercent: Double? = nil
    var industry: String? = nil
    var changePercent: Double? = nil
    /// True when the snapshot was filled in after the pick (older records).
    var backfilled: Bool? = nil
    /// "overnight" for 尾盘隔夜 picks (bought ~14:50, sold on the next morning's rally).
    var kind: String? = nil
    var pHi3: Double? = nil
    var pHi5: Double? = nil
    var takeProfit: Double? = nil
    /// Outcome on the next trading day: open / high / latest (close after 15:00).
    var nextDay: String? = nil
    var nextOpen: Double? = nil
    var nextHigh: Double? = nil
    var nextClose: Double? = nil

    var isOvernight: Bool { kind == "overnight" }
    /// Next-day returns versus the pick price, in percent.
    var nextOpenReturn: Double? { nextOpen.flatMap { price > 0 ? ($0 / price - 1) * 100 : nil } }
    var nextHighReturn: Double? { nextHigh.flatMap { price > 0 ? ($0 / price - 1) * 100 : nil } }
    var nextCloseReturn: Double? { nextClose.flatMap { price > 0 ? ($0 / price - 1) * 100 : nil } }

    mutating func applySnapshot(_ stock: PotentialStock) {
        grade = stock.grade; signals = stock.signals; risks = stock.risks
        highlights = stock.highlights; tags = stock.tags; pivot = stock.pivot
        stopLoss = stock.stopLoss; riskPercent = stock.riskPercent
        industry = stock.industry; changePercent = stock.changePercent
        if strategies.isEmpty { strategies = stock.strategies ?? [] }
        if stock.strategy == "overnight" {
            kind = "overnight"; pHi3 = stock.pHi3; pHi5 = stock.pHi5; takeProfit = stock.takeProfit
        }
    }
}

/// Live quantitative profile of one stock from the bridge's /stock-insight.
struct StockInsight: Decodable {
    struct Item: Decodable, Hashable { let label: String; let value: String; let tone: String; let hint: String? }
    struct Group: Decodable, Hashable { let title: String; let items: [Item] }
    struct Match: Decodable, Hashable {
        let strategy: String; let title: String; let score: Int; let grade: String
        let signals: [String]; let risks: [String]; let highlights: [String]
        let pivot: Double?; let stopLoss: Double?; let riskPercent: Double?
    }
    let code: String
    let name: String
    let industry: String?
    let concepts: [String]
    let groups: [Group]
    let strategies: [Match]
    let updatedAt: String?
}

struct StockNewsItem: Decodable, Identifiable, Hashable {
    let title: String
    let content: String
    let time: String
    let source: String
    let url: String
    var id: String { url.isEmpty ? time + title : url }
}

struct WatchData: Codable {
    var codes: [String] = ["600519", "000001", "300750", "688981"]
    var blacklist: [String] = []
    var groups: [String] = ["默认分组"]
    var groupByCode: [String: String] = [:]
    var conceptsByCode: [String: [String]] = [:]
    var menuBarCodes: [String] = []
    /// Legacy (one build only): codes auto-added to the single 当日自选 group.
    var autoDailyCodes: [String] = []
    var autoDailyDay: String = ""
    /// Daily recommendations keyed by trading day "yyyy-MM-dd". Each day keeps
    /// its own watchlist group (推荐 MM-dd) so past picks can be reviewed.
    var picksByDay: [String: [DailyPick]] = [:]
    /// Codes swapped out on a day; they are not re-added the same day.
    var replacedByDay: [String: [String]] = [:]
    /// 尾盘隔夜 picks locked at 14:50, keyed by trading day, with next-day outcome.
    var overnightByDay: [String: [DailyPick]] = [:]

    static let legacyAutoDailyGroup = "当日自选"
    static let pickGroupPrefix = "推荐 "
    /// Recommendations are capped separately for the main board and for
    /// ChiNext + STAR (20% daily limit), each in its own dated group.
    static let pickBoards = ["主板", "创业科创"]
    static func pickBoard(code: String) -> String {
        code.hasPrefix("688") || code.hasPrefix("689") || code.hasPrefix("300") || code.hasPrefix("301") ? "创业科创" : "主板"
    }
    static func pickGroupName(day: String, board: String) -> String { pickGroupPrefix + String(day.suffix(5)) + " " + board }
    static func pickGroupName(day: String, code: String) -> String { pickGroupName(day: day, board: pickBoard(code: code)) }
    /// One-group-per-day name used before the board split.
    static func legacyPickGroupName(day: String) -> String { pickGroupPrefix + String(day.suffix(5)) }
    static let overnightGroupPrefix = "隔夜 "
    static func overnightGroupName(day: String, board: String) -> String { overnightGroupPrefix + String(day.suffix(5)) + " " + board }
    static func overnightGroupName(day: String, code: String) -> String { overnightGroupName(day: day, board: pickBoard(code: code)) }
    /// Dated groups created automatically (推荐 / 隔夜), listed apart from the user's own groups.
    static func isAutoGroup(_ name: String) -> Bool { name.hasPrefix(pickGroupPrefix) || name.hasPrefix(overnightGroupPrefix) }

    private enum CodingKeys: String, CodingKey { case codes, blacklist, groups, groupByCode, conceptsByCode, menuBarCodes, autoDailyCodes, autoDailyDay, picksByDay, replacedByDay, overnightByDay }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        codes = try values.decodeIfPresent([String].self, forKey: .codes) ?? ["600519", "000001", "300750", "688981"]
        blacklist = try values.decodeIfPresent([String].self, forKey: .blacklist) ?? []
        groups = try values.decodeIfPresent([String].self, forKey: .groups) ?? ["默认分组"]
        groupByCode = try values.decodeIfPresent([String: String].self, forKey: .groupByCode) ?? [:]
        conceptsByCode = try values.decodeIfPresent([String: [String]].self, forKey: .conceptsByCode) ?? [:]
        menuBarCodes = try values.decodeIfPresent([String].self, forKey: .menuBarCodes) ?? []
        autoDailyCodes = try values.decodeIfPresent([String].self, forKey: .autoDailyCodes) ?? []
        autoDailyDay = try values.decodeIfPresent(String.self, forKey: .autoDailyDay) ?? ""
        picksByDay = try values.decodeIfPresent([String: [DailyPick]].self, forKey: .picksByDay) ?? [:]
        replacedByDay = try values.decodeIfPresent([String: [String]].self, forKey: .replacedByDay) ?? [:]
        overnightByDay = try values.decodeIfPresent([String: [DailyPick]].self, forKey: .overnightByDay) ?? [:]
        if groups.isEmpty { groups = ["默认分组"] }
    }
}

enum StockCategories {
    static let industries = [
        "农林牧渔", "煤炭", "石油石化", "有色金属", "钢铁", "基础化工", "建筑材料", "建筑装饰", "电力设备", "机械设备",
        "国防军工", "汽车", "交通运输", "公用事业", "房地产", "银行", "非银金融（证券、保险）", "食品饮料", "美容护理", "社会服务（旅游、酒店）",
        "商贸零售", "纺织服饰", "轻工制造", "医药生物", "电子", "计算机", "传媒", "通信", "环保", "综合", "家用电器"
    ]
    static let concepts = [
        "人工智能", "算力", "半导体 / 芯片", "光伏", "储能", "新能源车", "锂电池", "机器人", "低空经济", "国产替代",
        "算力租赁", "数字经济", "国企改革", "一带一路", "碳中和", "CXO", "创新药", "MR/VR", "数据"
    ]
}

enum AppFiles {
    static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AStockMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    static func read<T: Decodable>(_ type: T.Type, name: String, fallback: T) -> T {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)), let value = try? JSONDecoder().decode(type, from: data) else { return fallback }; return value
    }
    static func contains(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }
    @discardableResult static func write<T: Encodable>(_ value: T, name: String) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        do {
            try data.write(to: folder.appendingPathComponent(name), options: .atomic)
            return true
        } catch {
            DebugLog.write("保存文件失败：\(name), error=\(error.localizedDescription)")
            return false
        }
    }
}
