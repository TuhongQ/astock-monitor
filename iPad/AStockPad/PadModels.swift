import Foundation

/// One A-share quote from the Eastmoney full-market list.
struct Quote: Codable, Identifiable, Hashable {
    var code: String
    var name: String
    var price: Double
    var changePercent: Double
    var amount: Double
    var volume: Double
    var turnover: Double?
    var volumeRatio: Double?
    var high: Double?
    var low: Double?
    var open: Double?
    var prevClose: Double?
    var totalMarketCap: Double?
    var floatMarketCap: Double?
    var industry: String
    var limitUpPrice: Double?
    var limitDownPrice: Double?
    var upperLimit: Bool
    var lowerLimit: Bool
    var suspended: Bool
    var limitStreak: Int?
    var firstLimitTime: String?
    var limitOpenCount: Int?
    var sealAmount: Double?

    var id: String { code }
    var isST: Bool { name.uppercased().contains("ST") }
    var board: String {
        if code.hasPrefix("688") || code.hasPrefix("689") { return "科创板" }
        if code.hasPrefix("300") || code.hasPrefix("301") { return "创业板" }
        if code.hasPrefix("8") || code.hasPrefix("4") || code.hasPrefix("92") { return "北交所" }
        return "主板"
    }
    /// Touched the limit today but is no longer sealed (炸板).
    var openedLimit: Bool {
        guard !upperLimit, let limit = limitUpPrice, let high else { return false }
        return high >= limit - 0.005
    }
}

struct IndexQuote: Identifiable, Hashable {
    let code: String
    let name: String
    let price: Double
    let changePercent: Double
    let secid: String
    var id: String { code }
}

struct PricePoint: Identifiable, Hashable {
    let id = UUID()
    let time: Date
    let price: Double
}

struct Candle: Codable, Identifiable, Hashable {
    let date: String
    let open: Double
    let close: Double
    let high: Double
    let low: Double
    let amount: Double
    var id: String { date }
}

struct NewsItem: Identifiable, Hashable {
    let title: String
    let content: String
    let time: String
    let source: String
    let url: String
    var id: String { url.isEmpty ? time + title : url }
}

/// Row of Eastmoney's limit-up / broken-limit / previous-day limit-up pools.
struct LimitPoolItem: Codable, Hashable {
    var code: String
    var name: String
    var changePercent: Double?
    var price: Double?
    var floatMarketCap: Double?
    var turnover: Double?
    var industry: String
    var sealAmount: Double?
    var firstTime: String?
    var openCount: Int
    var streak: Int
    var stat: String?
    var limitUpPrice: Double?
}

struct LimitPools: Codable {
    var date: String = ""
    var pool: [String: LimitPoolItem] = [:]
    var broken: [String: LimitPoolItem] = [:]
    var previous: [String: LimitPoolItem] = [:]
}

struct LimitEmotion: Hashable {
    struct Ladder: Hashable { let streak: Int; let count: Int; let names: [String] }
    let limitUpCount: Int
    let brokenCount: Int
    let brokenRate: Double?
    let maxStreak: Int
    let previousPremium: Double?
    let mood: String
    let ladder: [Ladder]
    let topIndustries: [(String, Int)]

    static func == (lhs: LimitEmotion, rhs: LimitEmotion) -> Bool {
        lhs.limitUpCount == rhs.limitUpCount && lhs.brokenCount == rhs.brokenCount && lhs.mood == rhs.mood && lhs.maxStreak == rhs.maxStreak
    }
    func hash(into hasher: inout Hasher) { hasher.combine(limitUpCount); hasher.combine(brokenCount); hasher.combine(mood) }
}

struct MarketBreadth: Hashable {
    let upCount: Int
    let downCount: Int
    let medianChange: Double
    let regime: String
    let limitUpCount: Int
    let limitDownCount: Int
    let strongIndustries: [String]
}

struct StrategyMeta: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let summary: String
    let description: String
}

/// One stock selected by a strategy.
struct StockPick: Identifiable, Hashable {
    var code: String
    var name: String
    var price: Double
    var changePercent: Double
    var industry: String
    var score: Int
    var grade: String
    var strategy: String
    var strategies: [String]
    var signals: [String]
    var risks: [String]
    var highlights: [String]
    var tags: [String]
    var pivot: Double?
    var stopLoss: Double?
    var riskPercent: Double?
    var buyable: Bool = true
    /// 尾盘隔夜 only: estimated chance (%) that tomorrow's high is ≥ 3% / ≥ 5% above the price.
    var pHi3: Double? = nil
    var pHi5: Double? = nil
    var takeProfit: Double? = nil
    var board: String? = nil
    var id: String { code }
}

struct AlertRecord: Codable, Identifiable, Hashable {
    var id = UUID()
    let code: String
    let name: String
    let time: Date
    let price: Double
    let change: Double
    let type: String
    var industry: String?
    var detail: String?
    var startPrice: Double?
    var startChangePercent: Double?
    var limitStreak: Int?
    var silent: Bool?

    var typeLabel: String { AlertRecord.label(type) }
    var isLimitSide: Bool { type != "rapid" }
    static func label(_ type: String) -> String {
        switch type {
        case "daily": "涨幅"
        case "limitUp": "涨停"
        case "limitReseal": "回封"
        case "limitOpen": "炸板"
        case "limitDown": "跌停"
        case "rapid": "速拉"
        default: type
        }
    }
}

/// Snapshot of an automatic daily recommendation.
struct DailyPick: Codable, Hashable {
    var code: String
    var name: String
    var initialScore: Int
    var score: Int
    var price: Double
    var time: Date
    var strategies: [String]
    var grade: String
    var signals: [String]
    var risks: [String]
    var highlights: [String]
    var tags: [String]
    var pivot: Double?
    var stopLoss: Double?
    var riskPercent: Double?
    var industry: String
    /// "overnight" for 尾盘隔夜 picks and their next-day outcome (all optional so
    /// records saved by older builds still decode).
    var kind: String? = nil
    var pHi3: Double? = nil
    var pHi5: Double? = nil
    var takeProfit: Double? = nil
    var nextDay: String? = nil
    var nextOpen: Double? = nil
    var nextHigh: Double? = nil
    var nextClose: Double? = nil

    init(pick: StockPick, price: Double, time: Date) {
        code = pick.code; name = pick.name; initialScore = pick.score; score = pick.score
        self.price = price; self.time = time; strategies = pick.strategies; grade = pick.grade
        signals = pick.signals; risks = pick.risks; highlights = pick.highlights; tags = pick.tags
        pivot = pick.pivot; stopLoss = pick.stopLoss; riskPercent = pick.riskPercent; industry = pick.industry
        if pick.strategy == "overnight" { kind = "overnight"; pHi3 = pick.pHi3; pHi5 = pick.pHi5; takeProfit = pick.takeProfit }
    }

    var isOvernight: Bool { kind == "overnight" }
    var nextOpenReturn: Double? { nextOpen.flatMap { price > 0 ? ($0 / price - 1) * 100 : nil } }
    var nextHighReturn: Double? { nextHigh.flatMap { price > 0 ? ($0 / price - 1) * 100 : nil } }
    var nextCloseReturn: Double? { nextClose.flatMap { price > 0 ? ($0 / price - 1) * 100 : nil } }
}

struct PadSettings: Codable, Equatable {
    var threshold = 5.0
    var rapidThreshold = 3.0
    var windowSeconds = 60
    var refreshSeconds = 15
    var cooldownSeconds = 180
    var rapidCooldownSeconds = 180
    var limitMonitorAll = true
    var limitBannerAll = false
    var autoPicks = true
    var dailyPickLimit = 10
    var filterST = true
    /// Optional so settings saved by older builds still decode.
    var overnightEnabled: Bool? = nil
    var overnightLimitValue: Int? = nil

    var autoOvernight: Bool {
        get { overnightEnabled ?? true }
        set { overnightEnabled = newValue }
    }
    var overnightLimit: Int {
        get { min(max(overnightLimitValue ?? 10, 3), 15) }
        set { overnightLimitValue = newValue }
    }
}

struct WatchData: Codable, Equatable {
    var codes: [String] = ["600519", "000001", "300750", "688981"]
    var groups: [String] = ["默认分组"]
    var groupByCode: [String: String] = [:]
    var blacklist: [String] = []
    var picksByDay: [String: [DailyPick]] = [:]
    var replacedByDay: [String: [String]] = [:]
    /// 尾盘隔夜 picks locked at 14:50 by trading day (optional for older saves).
    var overnightByDay: [String: [DailyPick]]? = nil

    static let pickGroupPrefix = "推荐 "
    static let overnightGroupPrefix = "隔夜 "
    static func overnightGroupName(day: String, board: String) -> String { overnightGroupPrefix + String(day.suffix(5)) + " " + board }
    static func overnightGroupName(day: String, code: String) -> String { overnightGroupName(day: day, board: pickBoard(code: code)) }
    static func isAutoGroup(_ name: String) -> Bool { name.hasPrefix(pickGroupPrefix) || name.hasPrefix(overnightGroupPrefix) }
    static let pickBoards = ["主板", "创业科创"]
    static func pickBoard(code: String) -> String {
        code.hasPrefix("688") || code.hasPrefix("689") || code.hasPrefix("300") || code.hasPrefix("301") ? "创业科创" : "主板"
    }
    static func pickGroupName(day: String, board: String) -> String { pickGroupPrefix + String(day.suffix(5)) + " " + board }
    static func pickGroupName(day: String, code: String) -> String { pickGroupName(day: day, board: pickBoard(code: code)) }
}

enum Persist {
    static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AStockPad", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func read<T: Decodable>(_ type: T.Type, _ name: String, fallback: T) -> T {
        let decoder = JSONDecoder()
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
              let value = try? decoder.decode(type, from: data) else { return fallback }
        return value
    }
    static func write<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }
}

enum Fmt {
    static func pct(_ value: Double?, _ digits: Int = 2) -> String {
        guard let value else { return "—" }
        return String(format: "%+.\(digits)f%%", value)
    }
    static func price(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return String(format: "%.2f", value)
    }
    static func yuan(_ value: Double?) -> String {
        guard let value else { return "—" }
        let magnitude = abs(value)
        let text = magnitude >= 1e8 ? String(format: "%.2f亿", magnitude / 1e8) : (magnitude >= 1e4 ? String(format: "%.0f万", magnitude / 1e4) : String(format: "%.0f元", magnitude))
        return value < 0 ? "-" + text : text
    }
}

enum Market {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }()
    /// Trading minutes since 09:30 (0–240) or nil outside the two sessions.
    static func sessionMinute(_ date: Date = Date()) -> Double? {
        let parts = calendar.dateComponents([.weekday, .hour, .minute, .second], from: date)
        guard let weekday = parts.weekday, (2...6).contains(weekday) else { return nil }
        let minute = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) + Double(parts.second ?? 0) / 60
        if (570...690).contains(minute) { return minute - 570 }
        if (780...900).contains(minute) { return 120 + minute - 780 }
        return nil
    }
    static func isSession(_ date: Date = Date()) -> Bool { sessionMinute(date) != nil }
    static func minuteOfDay(_ date: Date = Date()) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
    static func dayKey(_ date: Date = Date()) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    /// Latest trading dates (yyyyMMdd), today first once the 09:25 auction has printed.
    static func tradingDates(count: Int, from date: Date = Date()) -> [String] {
        var day = date
        let parts = calendar.dateComponents([.weekday], from: date)
        if !(2...6).contains(parts.weekday ?? 1) || minuteOfDay(date) < 565 {
            day = calendar.date(byAdding: .day, value: -1, to: date) ?? date
        }
        var result: [String] = []
        while result.count < count {
            let p = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            if (2...6).contains(p.weekday ?? 1) {
                result.append(String(format: "%04d%02d%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0))
            }
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return result
    }
    /// Fraction of a full day's turnover traded by now (A-share volume is U-shaped).
    static func volumeFraction(_ date: Date = Date()) -> Double {
        guard let minute = sessionMinute(date) else { return 1 }
        let profile: [(Double, Double)] = [(0, 0), (15, 0.13), (30, 0.22), (60, 0.35), (90, 0.45), (120, 0.53),
                                           (150, 0.61), (180, 0.69), (210, 0.79), (230, 0.90), (240, 1)]
        for (a, b) in zip(profile, profile.dropFirst()) where minute <= b.0 {
            return max(a.1 + (b.1 - a.1) * (minute - a.0) / (b.0 - a.0), 0.03)
        }
        return 1
    }
    static func limitRatio(code: String, name: String) -> Double? {
        let upper = name.uppercased()
        if upper.hasPrefix("N") || upper.hasPrefix("C") { return nil }
        if code.hasPrefix("688") || code.hasPrefix("689") || code.hasPrefix("300") || code.hasPrefix("301") { return 0.20 }
        if code.hasPrefix("8") || code.hasPrefix("4") || code.hasPrefix("92") { return 0.30 }
        return upper.contains("ST") ? 0.05 : 0.10
    }
    static func roundPrice(_ value: Double) -> Double { (value * 100 + 0.5 + 1e-7).rounded(.down) / 100 }
    static func secid(_ code: String) -> String {
        (code.hasPrefix("6") || code.hasPrefix("9") && !code.hasPrefix("92")) ? "1.\(code)" : "0.\(code)"
    }
}
