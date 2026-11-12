import Foundation

// Swift port of the Mac bridge's multi-strategy screener (service/akshare_server.py).
// Scores are 0–100, A ≥ 75, B ≥ 60. Rule-based watch lists, not forecasts.

struct SurgeEvent: Codable, Hashable {
    var ts: Date
    var time: String
    var low: Double
    var price: Double
    var peak: Double
    var rise: Double
    var seconds: Int
    var accel: Double
    var sessionMinute: Double
}

struct TickMetrics {
    var speed1: Double?
    var speed3: Double?
    var speed5: Double?
    var rise5: Double = 0
    var retention: Double = 1
    var accel: Double?
}

/// Samples every fresh full-market snapshot during the session and records
/// rapid-rise events: ≥ 1.8% from the 5-minute low over consecutive samples.
final class TickTracker {
    private struct Sample { let ts: Date; let price: Double; let amount: Double }
    private var history: [String: [Sample]] = [:]
    private var marks: [String: [(slot: Int, price: Double)]] = [:]
    private(set) var events: [String: [SurgeEvent]] = [:]
    private var day = ""
    private var lastTs = Date.distantPast
    private let windowSeconds: TimeInterval = 600
    private let lookback: TimeInterval = 300
    private let maxGap: TimeInterval = 45
    private let minRise = 1.8
    private let cooldown: TimeInterval = 180

    init() { restore(day: Market.dayKey()) }

    private func restore(day: String) {
        self.day = day
        history = [:]; marks = [:]
        struct Saved: Codable { let day: String; let events: [String: [SurgeEvent]] }
        let saved = Persist.read(Saved?.self, "surge-events.json", fallback: nil)
        events = saved?.day == day ? saved?.events ?? [:] : [:]
    }

    private func save() {
        struct Saved: Codable { let day: String; let events: [String: [SurgeEvent]] }
        Persist.write(Saved(day: day, events: events.mapValues { Array($0.suffix(20)) }), "surge-events.json")
    }

    @discardableResult
    func record(_ quotes: [Quote], at now: Date = Date()) -> Int {
        let today = Market.dayKey(now)
        if today != day { restore(day: today) }
        guard let minute = Market.sessionMinute(now), now.timeIntervalSince(lastTs) >= 3 else { return 0 }
        lastTs = now
        let slot = Int(minute / 5)
        let clock = Market.calendar.dateComponents([.hour, .minute, .second], from: now)
        let clockText = String(format: "%02d:%02d:%02d", clock.hour ?? 0, clock.minute ?? 0, clock.second ?? 0)
        var newEvents = 0
        for q in quotes where q.price > 0 && !q.suspended {
            var samples = history[q.code, default: []]
            samples.append(Sample(ts: now, price: q.price, amount: q.amount))
            if let first = samples.firstIndex(where: { now.timeIntervalSince($0.ts) <= windowSeconds }), first > 0 {
                samples.removeFirst(first)
            }
            history[q.code] = samples
            var codeMarks = marks[q.code, default: []]
            if codeMarks.last?.slot == slot { codeMarks[codeMarks.count - 1].price = q.price } else { codeMarks.append((slot, q.price)) }
            marks[q.code] = codeMarks

            if var list = events[q.code], let last = list.last, now.timeIntervalSince(last.ts) < 1800, q.price > last.peak {
                list[list.count - 1].peak = q.price
                events[q.code] = list
            }
            guard samples.count >= 2 else { continue }
            var low = samples[samples.count - 1]
            var cursor = now
            for sample in samples.dropLast().reversed() {
                guard cursor.timeIntervalSince(sample.ts) <= maxGap, now.timeIntervalSince(sample.ts) <= lookback else { break }
                if sample.price < low.price { low = sample }
                cursor = sample.ts
            }
            guard low.ts < now, low.price > 0 else { continue }
            let rise = (q.price / low.price - 1) * 100
            guard rise >= minRise else { continue }
            let seconds = now.timeIntervalSince(low.ts)
            let dayMinuteAmount = q.amount / max(minute, 1)
            let accel = dayMinuteAmount > 0 ? (max(q.amount - low.amount, 0) / max(seconds / 60, 0.5)) / dayMinuteAmount : 0
            var event = SurgeEvent(ts: now, time: clockText, low: low.price, price: q.price, peak: q.price,
                                   rise: (rise * 100).rounded() / 100, seconds: Int(seconds), accel: (accel * 100).rounded() / 100,
                                   sessionMinute: minute)
            var list = events[q.code, default: []]
            if let last = list.last, now.timeIntervalSince(last.ts) < cooldown, low.ts <= last.ts {
                if rise > last.rise {
                    event.ts = last.ts; event.time = last.time; event.peak = max(last.peak, q.price)
                    list[list.count - 1] = event
                }
            } else if list.last.map({ now.timeIntervalSince($0.ts) >= cooldown }) ?? true {
                list.append(event); newEvents += 1
            }
            events[q.code] = list
        }
        if newEvents > 0 { save() }
        return newEvents
    }

    func metrics(_ code: String, now: Date = Date()) -> TickMetrics {
        guard let samples = history[code], samples.count >= 2, let last = samples.last,
              now.timeIntervalSince(last.ts) <= 90 else { return TickMetrics() }
        func before(_ seconds: TimeInterval) -> Sample? {
            samples.last { $0.ts <= last.ts.addingTimeInterval(-seconds + 5) }
        }
        var result = TickMetrics()
        for (seconds, keyPath) in [(60.0, \TickMetrics.speed1), (180, \TickMetrics.speed3), (300, \TickMetrics.speed5)] {
            if let sample = before(seconds), sample.price > 0, last.ts.timeIntervalSince(sample.ts) <= seconds + 45 {
                result[keyPath: keyPath] = (last.price / sample.price - 1) * 100
            }
        }
        let window = samples.filter { last.ts.timeIntervalSince($0.ts) <= lookback }
        if let low = window.min(by: { $0.price < $1.price }), low.price > 0 {
            result.rise5 = (last.price / low.price - 1) * 100
            let peak = window.filter { $0.ts >= low.ts }.map(\.price).max() ?? last.price
            result.retention = peak > low.price ? (last.price - low.price) / (peak - low.price) : 1
        }
        let minute = Market.sessionMinute(now) ?? 240
        let dayMinute = last.amount / max(minute, 1)
        if let base = before(180), dayMinute > 0, last.ts > base.ts {
            result.accel = (max(last.amount - base.amount, 0) / (last.ts.timeIntervalSince(base.ts) / 60)) / dayMinute
        }
        return result
    }

    func afternoonMarks(_ code: String) -> [Double] { (marks[code] ?? []).filter { $0.slot >= 24 }.map(\.price) }
}

struct DailyFeatures {
    let price: Double, change: Double
    let ma5: Double, ma10: Double, ma20: Double, ma60: Double, ma20Before: Double
    let maSpread: Double
    let high20: Double, high60: Double, low20: Double
    let avg5: Double, avg20: Double, amountRatio: Double?
    let std10: Double, std60: Double
    let ret5: Double, ret20: Double, ret60: Double, bias20: Double
    let upAmount: Double, downAmount: Double
    let dif: Double, dea: Double, goldenCross: Bool
    let streak: Int, limitUps15: Int
    let prevClose: Double
    let todayHigh: Double, todayLow: Double
    let prior: [Candle]

    static func compute(_ q: Quote, _ history: [Candle], now: Date = Date(), minBars: Int = 60) -> DailyFeatures? {
        let today = Market.dayKey(now)
        let bars = history.filter { $0.date != today }
        guard bars.count >= minBars, let last = bars.last else { return nil }
        let price = q.price, change = q.changePercent
        let previousChange = (last.close / bars[bars.count - 2].close - 1) * 100
        let sameSession = abs(last.close - price) < 0.006 && abs(previousChange - change) < 0.06
        let prior = sameSession ? Array(bars.dropLast()) : bars
        let todayAmount = sameSession ? last.amount : q.amount / Market.volumeFraction(now)
        let todayHigh = sameSession ? last.high : max(q.high ?? price, price)
        let todayLow = sameSession ? last.low : min(q.low ?? price, price)
        let closes = prior.map(\.close) + [price]
        func mean(_ values: ArraySlice<Double>) -> Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
        func sma(_ values: [Double], _ n: Int) -> Double { mean(values.suffix(n)) }
        let yesterday = Array(closes.dropLast())
        let y5 = sma(yesterday, 5), y10 = sma(yesterday, 10), y20 = sma(yesterday, 20)
        let amounts = prior.map(\.amount).filter { $0 > 0 }
        let avg5 = mean(amounts.suffix(5)), avg20 = mean(amounts.suffix(20))
        let returns = zip(closes.dropFirst(), closes).map { $0 / $1 - 1 }
        func stdev(_ values: ArraySlice<Double>) -> Double {
            guard values.count >= 2 else { return 0 }
            let m = mean(values)
            return (values.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(values.count)).squareRoot()
        }
        var streak = 0, limitUps15 = 0
        if let ratio = Market.limitRatio(code: q.code, name: q.name) {
            let hits = zip(prior.dropFirst(), prior).map { $0.close / $1.close - 1 >= ratio - 0.003 }
            for hit in hits.reversed() { if hit { streak += 1 } else { break } }
            limitUps15 = hits.suffix(15).filter { $0 }.count
        }
        func ema(_ values: [Double], _ span: Double) -> [Double] {
            let alpha = 2 / (span + 1)
            var current = values.first ?? 0
            return values.map { current = alpha * $0 + (1 - alpha) * current; return current }
        }
        let ema12 = ema(closes, 12), ema26 = ema(closes, 26)
        let difs = zip(ema12, ema26).map { $0 - $1 }
        let deas = ema(difs, 9)
        let n = difs.count
        let golden = n >= 4 && (n - 3..<n).contains { difs[$0 - 1] <= deas[$0 - 1] && difs[$0] > deas[$0] }
        let window20 = prior.suffix(20)
        var up = 0.0, down = 0.0
        for i in max(prior.count - 20, 1)..<prior.count {
            if prior[i].close >= prior[i - 1].close { up += prior[i].amount } else { down += prior[i].amount }
        }
        let ma20 = sma(closes, 20)
        return DailyFeatures(
            price: price, change: change,
            ma5: sma(closes, 5), ma10: sma(closes, 10), ma20: ma20, ma60: sma(closes, 60),
            ma20Before: mean(closes.dropLast(5).suffix(20)),
            maSpread: (max(y5, y10, y20) - min(y5, y10, y20)) / (yesterday.last ?? 1),
            high20: window20.map(\.high).max() ?? price, high60: prior.suffix(60).map(\.high).max() ?? price,
            low20: window20.map(\.low).min() ?? price,
            avg5: avg5, avg20: avg20, amountRatio: avg5 > 0 && todayAmount > 0 ? todayAmount / avg5 : nil,
            std10: stdev(returns.dropLast().suffix(10)), std60: stdev(returns.dropLast().suffix(60)),
            ret5: price / closes[closes.count - 6] - 1, ret20: price / closes[closes.count - 21] - 1,
            ret60: price / closes[closes.count - 61] - 1, bias20: price / ma20 - 1,
            upAmount: up, downAmount: down, dif: difs.last ?? 0, dea: deas.last ?? 0, goldenCross: golden,
            streak: streak, limitUps15: limitUps15, prevClose: closes[closes.count - 2],
            todayHigh: todayHigh, todayLow: todayLow, prior: prior)
    }
}

struct QuantContext {
    let quotes: [Quote]
    let byCode: [String: Quote]
    let breadth: MarketBreadth
    let now: Date
    let live: Bool
    let weak: Bool
    let pools: LimitPools
    let emotion: LimitEmotion?
    let tracker: TickTracker
    let daily: [String: [Candle]]
    let limitHistory: [String: [String]]

    func features(_ q: Quote) -> DailyFeatures? { daily[q.code].flatMap { DailyFeatures.compute(q, $0, now: now) } }
}

enum QuantEngine {
    static let strategies: [StrategyMeta] = [
        StrategyMeta(id: "all", title: "综合", icon: "square.stack.3d.up.fill", summary: "各策略合并，多策略共振加分",
                     description: "把下面六种策略的结果按个股合并：取最高分，每多命中一种策略加 6 分。同时被多个独立逻辑选中的个股，信号更可靠。"),
        StrategyMeta(id: "surge", title: "速拉异动", icon: "bolt.fill", summary: "5 分钟内从低点快速拉升且放量",
                     description: "本机逐快照跟踪全市场，5 分钟内从低点拉升 ≥ 1.8% 记为一次速拉。评分看拉升幅度、拉升期间额速、承接、同行业同期异动只数、多波攻击、发生时间和日线是否同时突破；高位速拉、冲高回落、已封板、流动性不足扣分。观察位为速拉起点。"),
        StrategyMeta(id: "limit", title: "涨停接力", icon: "flag.fill", summary: "冲板 / 封板 / 回封，看封板质量与情绪",
                     description: "东方财富涨停池、炸板池、昨日涨停池加上距涨停 2% 以内的冲板股。评分看封板时间、炸板次数、连板高度（2 进 3 最优）、封单占流通市值、同行业涨停梯队、炸板率与昨日涨停溢价、流通市值；一字板、尾盘板、高位板扣分。"),
        StrategyMeta(id: "trend", title: "趋势突破", icon: "chart.line.uptrend.xyaxis", summary: "均线多头 / 粘合后放量突破平台",
                     description: "全市场快照初筛约 60 只（成交额 ≥ 1 亿、量比放大、收在日内高位、行业强度、盘中速拉加分），再用日 K 复核均线多头、均线粘合、振幅收敛、20 / 60 日平台突破、缩量后放量、红肥绿瘦、MACD；乖离过大、短期涨幅过大、放量滞涨、长上影扣分。"),
        StrategyMeta(id: "pullback", title: "强势回踩", icon: "arrow.uturn.up", summary: "近期涨停过的强势股缩量回踩均线",
                     description: "候选来自近 15 个交易日出现过涨停的个股。要求从 20 日高点回撤 6%–28%、在上行 20 日线附近、近期缩量；回踩 10 / 20 日线 2.5% 内、下影承接、行业仍强加分；放量下跌扣分。"),
        StrategyMeta(id: "leader", title: "板块龙头", icon: "crown.fill", summary: "最强行业里的领涨个股",
                     description: "按中位涨幅、前五强均值和涨停家数给东财行业打热度，取最热的 6 个行业；在板块内按涨幅、成交额、是否涨停及封板早晚、盘中涨速挑出前两名。"),
        StrategyMeta(id: "tail", title: "尾盘潜伏", icon: "moon.stars.fill", summary: "14:30 后温和放量、收在高位",
                     description: "涨 2.5%–6%、量比 ≥ 1.2、换手 3%–12%、流通 30–300 亿、收在日内高位，午后 5 分钟线稳步走高、日线短均线多头、近 20 日涨幅不大。14:30 前为预览。"),
        StrategyMeta(id: "overnight", title: "尾盘隔夜", icon: "sunrise.fill", summary: "14:50 买入、次日冲高卖出，主板 / 创业科创各 10 只",
                     description: "全市场（剔除 ST、北交所、停牌、涨停封死、跌停、成交额 < 5000 万）逐只估算「次日盘中最高价比现价高 3% / 5%」的概率。模型用 1490 只随机个股 2026 年以来约 16.5 万个交易日拟合并做样本外检验：入选前 10 只次日冲高 ≥5% 的实际比例约 33%（全市场约 12%），≥3% 约 49%（全市场约 25%）。换手、振幅、成交额、上影线加分，量比过大和尾盘追高（高于分时均价）减分。这类股票次日开盘平均低开约 1%，开盘直接卖期望为负：建议次日挂 +3% 止盈单，10:30 前未成交或跌破 −3% 就卖出。14:50 自动锁定，此前为预览。不并入「综合」。"),
    ]
    static let titles = Dictionary(uniqueKeysWithValues: strategies.map { ($0.id, $0.title) })

    static func grade(_ score: Double) -> String { score >= 75 ? "A" : (score >= 60 ? "B" : "C") }

    static func tradeable(_ q: Quote) -> Bool {
        !q.isST && !q.name.contains("退") && q.board != "北交所" && Market.limitRatio(code: q.code, name: q.name) != nil
    }

    private static func item(_ q: Quote, _ strategy: String, _ score: Double, signals: [String], risks: [String],
                             pivot: Double?, stop: Double?, highlights: [String], tags: [String] = [], buyable: Bool = true) -> StockPick {
        let clamped = Int(max(0, min(score, 100)).rounded())
        var stopLevel = stop
        if let s = stopLevel, s >= q.price { stopLevel = q.price * 0.95 }
        return StockPick(code: q.code, name: q.name, price: q.price, changePercent: q.changePercent, industry: q.industry,
                         score: clamped, grade: grade(Double(clamped)), strategy: strategy, strategies: [strategy],
                         signals: signals, risks: risks, highlights: highlights, tags: tags.filter { !$0.isEmpty },
                         pivot: pivot.map { ($0 * 100).rounded() / 100 }, stopLoss: stopLevel.map { ($0 * 100).rounded() / 100 },
                         riskPercent: stopLevel.map { ((q.price - $0) / q.price * 10000).rounded() / 100 }, buyable: buyable)
    }

    private static func finalize(_ items: [StockPick], min: Int, limit: Int = 30) -> [StockPick] {
        Array(items.filter { $0.score >= min }.sorted { ($0.score, $0.changePercent) > ($1.score, $1.changePercent) }.prefix(limit))
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    // MARK: Market

    static func breadth(_ quotes: [Quote]) -> MarketBreadth {
        let active = quotes.filter { !$0.suspended && $0.price > 0 }
        let changes = active.map(\.changePercent)
        let up = changes.filter { $0 > 0 }.count, down = changes.filter { $0 < 0 }.count
        let ratio = Double(up) / Double(max(up + down, 1))
        let med = median(changes)
        let regime = ratio >= 0.6 && med > 0.3 ? "强势" : (ratio <= 0.35 || med < -0.8 ? "弱势" : "震荡")
        let byIndustry = Dictionary(grouping: active.filter { !$0.industry.isEmpty }, by: \.industry)
        let strong = byIndustry.filter { $0.value.count >= 8 }.map { ($0.key, median($0.value.map(\.changePercent))) }
            .sorted { $0.1 > $1.1 }.prefix(5).filter { $0.1 > 0 }.map(\.0)
        return MarketBreadth(upCount: up, downCount: down, medianChange: med, regime: regime,
                             limitUpCount: active.filter(\.upperLimit).count, limitDownCount: active.filter(\.lowerLimit).count,
                             strongIndustries: Array(strong))
    }

    static func emotion(_ pools: LimitPools) -> LimitEmotion? {
        guard !pools.date.isEmpty else { return nil }
        let sealed = pools.pool.values.filter { !$0.name.uppercased().contains("ST") }
        let touched = pools.pool.count + pools.broken.count
        let premiumValues = pools.previous.values.filter { !$0.name.uppercased().contains("ST") }.compactMap(\.changePercent)
        let premium = premiumValues.isEmpty ? nil : premiumValues.reduce(0, +) / Double(premiumValues.count)
        let brokenRate = touched > 0 ? Double(pools.broken.count) / Double(touched) * 100 : nil
        let maxStreak = sealed.map(\.streak).max() ?? 0
        let mood: String
        if let rate = brokenRate {
            if (premium ?? 0) >= 2 && rate < 30 && maxStreak >= 4 { mood = "高潮" }
            else if (premium ?? 0) <= -1 || rate >= 45 { mood = "退潮" }
            else if (premium ?? 0) >= 0.8 && rate < 35 { mood = "回暖" }
            else { mood = "分歧" }
        } else { mood = "未知" }
        let ladder = Dictionary(grouping: sealed, by: \.streak).sorted { $0.key > $1.key }.prefix(6).map { streak, items in
            LimitEmotion.Ladder(streak: streak, count: items.count, names: items.sorted { ($0.firstTime ?? "99") < ($1.firstTime ?? "99") }.prefix(4).map(\.name))
        }
        var industryCounts: [String: Int] = [:]
        for item in sealed where !item.industry.isEmpty { industryCounts[item.industry, default: 0] += 1 }
        let industries: [(String, Int)] = industryCounts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.map { ($0.key, $0.value) }
        return LimitEmotion(limitUpCount: sealed.count, brokenCount: pools.broken.count, brokenRate: brokenRate,
                            maxStreak: maxStreak, previousPremium: premium, mood: mood, ladder: Array(ladder),
                            topIndustries: Array(industries.prefix(6)))
    }

    private static func dailyBonus(_ f: DailyFeatures) -> (Double, [String], [String]) {
        var score = 0.0, signals: [String] = [], risks: [String] = []
        if f.price > f.high60 { score += 12; signals.append("同时突破 60 日高点") }
        else if f.price > f.high20 { score += 8; signals.append("同时突破 20 日高点") }
        if f.price > f.ma20, f.ma20 > f.ma60, f.ma20 > f.ma20Before { score += 6; signals.append("日线趋势向上") }
        if f.ret20 > 0.5 { score -= 12; risks.append(String(format: "近 20 日已涨 %.0f%%，高位异动警惕出货", f.ret20 * 100)) }
        else if f.ret20 > 0.3 { score -= 5; risks.append(String(format: "近 20 日已涨 %.0f%%", f.ret20 * 100)) }
        if f.price < f.ma60 { score -= 4; risks.append("仍在 60 日线下方") }
        return (score, signals, risks)
    }

    // MARK: 速拉异动

    static func surge(_ ctx: QuantContext) -> [StockPick] {
        let now = ctx.now
        let recentSpan: TimeInterval = ctx.live ? 1800 : 86400
        let resonanceSpan: TimeInterval = ctx.live ? 900 : 86400
        var industryHeat: [String: Int] = [:]
        for (code, list) in ctx.tracker.events {
            guard let last = list.last, now.timeIntervalSince(last.ts) <= resonanceSpan,
                  let industry = ctx.byCode[code]?.industry, !industry.isEmpty else { continue }
            industryHeat[industry, default: 0] += 1
        }
        var results: [StockPick] = []
        for (code, list) in ctx.tracker.events {
            guard let event = list.last, now.timeIntervalSince(event.ts) <= recentSpan,
                  let q = ctx.byCode[code], !q.suspended, q.price >= 2, tradeable(q), q.amount >= 30_000_000 else { continue }
            let metrics = ctx.live ? ctx.tracker.metrics(code, now: now) : TickMetrics()
            var signals: [String] = [], risks: [String] = [], tags: [String] = []
            let rise = max(event.rise, metrics.rise5)
            var score = min(rise / 4, 1) * 22
            let accel = max(event.accel, metrics.accel ?? 0)
            if accel > 0 { score += min(max(log2(max(accel, 1)), 0) / 3, 1) * 18 }
            if accel >= 3 { signals.append(String(format: "拉升期间额速 %.1f 倍，资金主动攻击", accel)) }
            let peak = max(event.peak, q.price)
            let retention = peak > event.low ? (q.price - event.low) / (peak - event.low) : 1
            if retention >= 0.8 { score += 10; signals.append("拉升后承接良好，几乎不回吐") }
            else if retention >= 0.6 { score += 6 }
            else if retention < 0.4 { score -= 8; risks.append(String(format: "冲高回落，回吐 %.0f%% 涨幅", 100 - retention * 100)) }
            if let high = q.high, high > 0, q.price >= high * 0.99 { score += 6 }
            let peers = max((industryHeat[q.industry] ?? 0) - 1, 0)
            if peers >= 3 { score += 12 } else if peers >= 2 { score += 8 } else if peers >= 1 { score += 4 }
            if peers >= 1 { signals.append("板块联动：\(q.industry) 同期 \(peers) 只异动"); tags.append(q.industry) }
            if list.count >= 2 { score += 5; signals.append("今日第 \(list.count) 波拉升") }
            if (q.volumeRatio ?? 0) >= 2 { score += 5 }
            let ratio = Market.limitRatio(code: q.code, name: q.name) ?? 0.1
            let room = ratio * 100 - q.changePercent
            if q.upperLimit { tags.append("已封板"); score -= 15; risks.append("已封涨停，普通委托难以成交，见「涨停接力」") }
            else if room <= 2 { score += 3; tags.append("逼近涨停") }
            else if (2...7).contains(q.changePercent) { score += 6 }
            else if q.changePercent < 0 { score += 1; tags.append("水下拉升") }
            if event.sessionMinute <= 60 { score += 5; signals.append("早盘发起") }
            else if event.sessionMinute >= 210 { score -= 3; risks.append("尾盘拉升，次日溢价不确定") }
            let cap = q.floatMarketCap ?? 0
            if (2e9...3e10).contains(cap) { score += 4 } else if cap > 1e11 { score -= 3 }
            if q.amount < 1e8 { score -= 4; risks.append("成交额不足 1 亿，流动性一般") }
            if let f = ctx.features(q) {
                let (bonus, s, r) = dailyBonus(f); score += bonus; signals += s; risks += r
                let (chase, cr) = QuantEngine.chasePenalty(f, change: q.changePercent, upperLimit: q.upperLimit)
                score -= chase * 0.5; risks += cr.filter { !risks.contains($0) }
                if q.changePercent >= 5 && !q.upperLimit { risks.append("速拉是盘中信号：尾盘追入过夜，次日平均低开") }
            }
            if ctx.weak { score *= 0.9 }
            var highlights = ["\(event.time) 起拉", String(format: "%d 秒 +%.1f%%", max(event.seconds, 1), event.rise),
                              accel > 0 ? String(format: "额速 %.1f×", accel) : "额速 —", String(format: "承接 %.0f%%", max(retention, 0) * 100)]
            if let s3 = metrics.speed3 { highlights.append(String(format: "3 分钟 %+.2f%%", s3)) }
            results.append(item(q, "surge", score, signals: signals, risks: risks, pivot: event.low,
                                stop: max(event.low * 0.985, q.price * 0.93), highlights: highlights, tags: tags, buyable: !q.upperLimit))
        }
        return finalize(results, min: 45)
    }

    // MARK: 涨停接力

    static func limit(_ ctx: QuantContext) -> [StockPick] {
        let pools = ctx.pools
        var sealedByIndustry: [String: Int] = [:]
        for item in pools.pool.values where !item.industry.isEmpty { sealedByIndustry[item.industry, default: 0] += 1 }
        var candidates: [String: (String, LimitPoolItem?)] = [:]
        for (code, item) in pools.pool { candidates[code] = ("sealed", item) }
        for (code, item) in pools.broken where candidates[code] == nil { candidates[code] = ("broken", item) }
        if ctx.live {
            for q in ctx.quotes where candidates[q.code] == nil && !q.suspended && !q.upperLimit {
                if let limit = q.limitUpPrice, q.price >= limit * 0.98 { candidates[q.code] = ("near", nil) }
            }
        }
        var results: [StockPick] = []
        for (code, entry) in candidates {
            guard let q = ctx.byCode[code], tradeable(q) else { continue }
            var (status, poolItem) = entry
            if q.upperLimit && status != "sealed" { status = "sealed"; poolItem = pools.pool[code] ?? poolItem }
            var signals: [String] = [], risks: [String] = [], highlights: [String] = [], tags: [String] = []
            let features = ctx.features(q)
            let previous = pools.previous[code]
            var streak = poolItem?.streak ?? 0
            if status != "sealed" || streak == 0 { streak = previous.map { $0.streak + 1 } ?? ((features?.streak ?? 0) + 1) }
            if status == "sealed", let s = poolItem?.streak { streak = s }
            let firstTime = poolItem?.firstTime
            let opens = poolItem?.openCount ?? 0
            var score: Double
            switch status {
            case "near":
                score = 22; tags.append("冲板中"); signals.append("距涨停不足 2%，仍可挂单")
            case "sealed":
                score = 14; tags.append(streak > 1 ? "\(streak) 连板" : "首板")
                if opens > 0 { tags.append("回封"); signals.append("炸板 \(opens) 次后回封，分歧转一致") }
            default:
                let limitUp = poolItem?.limitUpPrice ?? q.limitUpPrice ?? q.price
                let gap = limitUp > 0 ? (limitUp - q.price) / limitUp * 100 : 99
                score = 10 + (gap <= 2 ? 6 : 0); tags.append("炸板")
                if gap <= 2 { signals.append(String(format: "炸板后仍在涨停价下 %.1f%%，有回封可能", gap)) }
                else { risks.append(String(format: "炸板后回落至涨停价下 %.1f%%", gap)) }
            }
            if let t = firstTime {
                if t <= "09:25:59" { tags.append("一字板") }
                if t < "10:00:00" { score += 12; signals.append("\(t.prefix(5)) 早盘封板") }
                else if t < "11:30:01" { score += 8; signals.append("\(t.prefix(5)) 上午封板") }
                else if t < "14:00:00" { score += 4 }
                else { risks.append("\(t.prefix(5)) 尾盘封板，封板意愿偏弱") }
                highlights.append("首封 \(t.prefix(5))")
            }
            if opens == 0 && status == "sealed" { score += 6 } else if opens >= 3 { score -= 6; risks.append("炸板 \(opens) 次，分歧较大") } else if opens == 1 { score += 2 }
            switch streak {
            case 1: score += 8
            case 2: score += 12; signals.append("2 进 3 关键位，资金最活跃")
            case 3: score += 8
            case 4: score += 4
            default: risks.append("\(streak) 连板高度板，接力风险陡增")
            }
            let cap = poolItem?.floatMarketCap ?? q.floatMarketCap ?? 0
            if let seal = poolItem?.sealAmount, seal > 0, cap > 0 {
                let ratio = seal / cap * 100
                if ratio >= 3 { score += 8; signals.append(String(format: "封单占流通市值 %.1f%%，封板坚决", ratio)) } else if ratio >= 1 { score += 4 }
                highlights.append(String(format: "封单 %.2f 亿", seal / 1e8))
            }
            if tags.contains("一字板") { score -= 6; risks.append("一字板几乎无法买入") }
            else if let turnover = poolItem?.turnover ?? q.turnover {
                if (3...15).contains(turnover) { score += 6 } else if turnover > 25 { score -= 4; risks.append(String(format: "换手 %.0f%% 过高，筹码松动", turnover)) }
            }
            let industry = poolItem?.industry ?? q.industry
            let peers = (sealedByIndustry[industry] ?? 0) - (pools.pool[code] != nil ? 1 : 0)
            if peers >= 3 { score += 12; signals.append("板块梯队：\(industry) 另有 \(peers) 只涨停"); tags.append(industry) }
            else if peers >= 1 { score += 6; tags.append(industry) }
            if let rate = ctx.emotion?.brokenRate {
                if rate < 25 { score += 6 } else if rate > 45 { score -= 8; risks.append(String(format: "炸板率 %.0f%%，打板环境差", rate)) }
            }
            if let premium = ctx.emotion?.previousPremium {
                if premium > 2 { score += 5 } else if premium < -1 { score -= 6; risks.append(String(format: "昨日涨停今日平均 %+.1f%%，接力亏钱效应", premium)) }
            }
            if (2e9...1.5e10).contains(cap) { score += 5 } else if cap > 5e10 { score -= 4 }
            if let f = features {
                if f.price > f.high60 { score += 6; signals.append("涨停突破 60 日新高") }
                if f.ret20 > 0.6 { score -= 10; risks.append(String(format: "近 20 日已涨 %.0f%%", f.ret20 * 100)) }
            }
            if opens > 0 { highlights.append("炸板 \(opens) 次") }
            if let stat = poolItem?.stat { highlights.append("涨停统计 \(stat)") }
            if ctx.weak { score *= 0.9 }
            let limitUp = q.limitUpPrice ?? q.price
            let stop = status == "broken" ? q.price * 0.95 : max(limitUp * 0.95, (q.low ?? 0) * 0.99)
            results.append(item(q, "limit", score, signals: signals, risks: risks, pivot: limitUp, stop: stop,
                                highlights: highlights, tags: tags, buyable: status != "sealed" || opens > 0))
        }
        return finalize(results, min: 45)
    }

    // MARK: 趋势突破

    /// Stage 1: snapshot screen; returns codes worth a daily-bar review.
    static func trendCandidates(_ ctx: QuantContext, limit: Int = 60) -> [(Double, [String], Quote)] {
        var picks: [(Double, [String], Quote)] = []
        for q in ctx.quotes {
            guard !q.suspended, q.price >= 2, tradeable(q), !q.upperLimit,
                  let ratio = Market.limitRatio(code: q.code, name: q.name),
                  q.changePercent >= -1.5, q.changePercent <= ratio * 100 - 1.5, q.amount >= 1e8 else { continue }
            if let vr = q.volumeRatio, vr < 0.9 { continue }
            if let t = q.turnover, !(1...25).contains(t) { continue }
            var score = 0.0, reasons: [String] = []
            if let vr = q.volumeRatio { score += min(max(vr - 1, 0), 3) / 3 * 20; if vr >= 1.5 { reasons.append(String(format: "量比 %.2f", vr)) } }
            score += (1...5).contains(q.changePercent) ? 12 : (q.changePercent > 5 ? 10 : (q.changePercent > 0 ? 6 : 2))
            if let t = q.turnover { score += (3...12).contains(t) ? 8 : 3 }
            if let high = q.high, let low = q.low, high > low {
                let position = min(max((q.price - low) / (high - low), 0), 1)
                score += position * 10
                if position >= 0.8 && q.changePercent > 0 { reasons.append("收于日内高位") }
            }
            if let open = q.open, q.price > open { score += 4 }
            if ctx.breadth.strongIndustries.contains(q.industry) { score += 8 }
            if ctx.live {
                let m = ctx.tracker.metrics(q.code, now: ctx.now)
                if m.rise5 >= 1.5, (m.accel ?? 0) >= 2 { score += 10; reasons.append(String(format: "盘中速拉 +%.1f%%", m.rise5)) }
            }
            picks.append((score, reasons, q))
        }
        return Array(picks.sorted { $0.0 > $1.0 }.prefix(limit))
    }

    static func trend(_ ctx: QuantContext, candidates: [(Double, [String], Quote)]) -> [StockPick] {
        var results: [StockPick] = []
        for (stage1, reasons, q) in candidates {
            guard let f = ctx.features(q) else { continue }
            var score = 0.0, signals: [String] = [], risks: [String] = []
            var trendPoints = 0.0
            let rising = f.ma20 > f.ma20Before
            if f.ma5 > f.ma10 && f.ma10 > f.ma20 && f.ma20 > f.ma60 && rising { trendPoints = 15; signals.append("均线多头排列") }
            else if f.price > f.ma20 && f.ma20 > f.ma60 && rising { trendPoints = 10; signals.append("站上上行的 20 日线") }
            else if f.price > f.ma20 && rising { trendPoints = 6; signals.append("站上 20 日线") }
            score += trendPoints
            if f.maSpread < 0.03 { score += 10; signals.append(String(format: "均线粘合 %.1f%%，蓄势待变", f.maSpread * 100)) } else if f.maSpread < 0.05 { score += 5 }
            if f.std60 > 0 && f.std10 / f.std60 < 0.65 { score += 8; signals.append("振幅收敛，筹码趋稳") } else if f.std60 > 0 && f.std10 / f.std60 < 0.85 { score += 4 }
            var breakout = 0.0, pivot: Double?
            if f.price > f.high60 { breakout = 18; pivot = f.high60; signals.append(String(format: "突破 60 日高点 %.2f", f.high60)) }
            else if f.price > f.high20 { breakout = 12; pivot = f.high20; signals.append(String(format: "突破 20 日高点 %.2f", f.high20)) }
            else if f.price >= f.high60 * 0.97 { breakout = 7; signals.append(String(format: "逼近 60 日平台上沿 %.2f", f.high60)) }
            score += breakout
            guard trendPoints > 0 || breakout > 0 else { continue }
            var volume = 0.0
            if let ar = f.amountRatio {
                if ar >= 2 { volume += 12; signals.append(String(format: "放量 %.1f 倍", ar)) }
                else if ar >= 1.5 { volume += 8; signals.append(String(format: "温和放量 %.1f 倍", ar)) }
                else if ar >= 1.2 { volume += 4 }
                if f.avg20 > 0 && f.avg5 / f.avg20 < 0.8 && ar >= 1.5 { volume += 6; signals.append("缩量调整后放量") }
            }
            if f.downAmount > 0 && f.upAmount / f.downAmount > 1.5 { volume += 5; signals.append("近 20 日红肥绿瘦") }
            score += min(volume, 20)
            if (0.05...0.25).contains(f.ret20) { score += 8; signals.append(String(format: "近 20 日 +%.1f%%", f.ret20 * 100)) } else if (0..<0.05).contains(f.ret20) { score += 4 }
            if (0.2...0.6).contains(f.ret60) && f.ret20 <= 0.25 { score += 4; signals.append("60 日相对强度靠前") }
            if f.goldenCross && f.dif > 0 { score += 10; signals.append("MACD 零轴上方金叉") }
            else if f.goldenCross { score += 7; signals.append("MACD 金叉") }
            else if f.dif > f.dea && f.dif > 0 { score += 4 }
            if ctx.tracker.events[q.code]?.isEmpty == false { score += 6; signals.append("盘中资金攻击") }
            if ctx.breadth.strongIndustries.contains(q.industry) { score += 6; signals.append("行业领涨（\(q.industry)）") }
            score += min(stage1, 72) / 72 * 15
            signals += reasons.filter { !signals.contains($0) }
            if f.bias20 > 0.15 { score -= 15; risks.append(String(format: "偏离 20 日线 %.0f%%，追高风险大", f.bias20 * 100)) }
            else if f.bias20 > 0.10 { score -= 6; risks.append(String(format: "偏离 20 日线 %.0f%%", f.bias20 * 100)) }
            if f.ret20 > 0.4 { score -= 15; risks.append(String(format: "近 20 日已涨 %.0f%%", f.ret20 * 100)) }
            else if f.ret5 > 0.2 { score -= 10; risks.append(String(format: "近 5 日已涨 %.0f%%", f.ret5 * 100)) }
            if f.price < f.ma60 { score -= 6; risks.append("仍在 60 日线下方，上方有套牢盘") }
            if let ar = f.amountRatio, ar > 3.5, q.changePercent < 1 { score -= 10; risks.append("放量滞涨") }
            if (f.todayHigh - f.price) / f.prevClose > 0.03 { score -= 6; risks.append("冲高回落，上影线较长") }
            let (chase, chaseRisks) = QuantEngine.chasePenalty(f, change: q.changePercent, upperLimit: q.upperLimit)
            score -= chase; risks += chaseRisks.filter { !risks.contains($0) }
            if ctx.weak { score *= 0.85 }
            let level = pivot ?? f.ma10
            let stop = max(min(level * 0.97, f.ma20 * 0.98), f.price * 0.92)
            results.append(item(q, "trend", score, signals: signals, risks: risks, pivot: level, stop: stop,
                                highlights: [f.amountRatio.map { String(format: "额比 %.1f", $0) } ?? "额比 —",
                                             String(format: "20日 %+.1f%%", f.ret20 * 100), String(format: "乖离 %+.1f%%", f.bias20 * 100)]))
        }
        return finalize(results, min: 50)
    }

    // MARK: 强势回踩

    static func pullbackCandidates(_ ctx: QuantContext, limit: Int = 80) -> [Quote] {
        // Strong-stock pool: limit-ups of the previous 15 trading days (not today's).
        let today = Market.dayKey(ctx.now).replacingOccurrences(of: "-", with: "")
        let dates = ctx.limitHistory.keys.filter { $0 < today }.sorted(by: >).prefix(15)
        var counts: [String: Int] = [:]
        for date in dates { for code in ctx.limitHistory[date] ?? [] { counts[code, default: 0] += 1 } }
        return counts.compactMap { code, count -> (Int, Quote)? in
            guard let q = ctx.byCode[code], !q.suspended, tradeable(q), (-5...3).contains(q.changePercent), q.amount >= 5e7 else { return nil }
            return (count, q)
        }.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
    }

    static func pullback(_ ctx: QuantContext, candidates: [Quote]) -> [StockPick] {
        var results: [StockPick] = []
        for q in candidates {
            guard let f = ctx.features(q), f.high20 > 0 else { continue }
            let drawdown = (f.high20 - f.price) / f.high20
            guard (0.06...0.28).contains(drawdown), f.price >= f.ma20 * 0.97, f.limitUps15 > 0 else { continue }
            let base = f.prior.count >= 30 ? (f.prior.suffix(30).prefix(20).map(\.close).min() ?? f.low20) : f.low20
            guard base > 0, f.high20 / base >= 1.2 else { continue }
            var score = 0.0, signals = [String(format: "近 15 日 %d 次涨停，前期涨幅 %.0f%%", f.limitUps15, (f.high20 / base - 1) * 100)], risks: [String] = []
            score += f.limitUps15 >= 2 ? 14 : 8
            let d10 = f.price / f.ma10 - 1, d20 = f.price / f.ma20 - 1
            var support: Double?
            if abs(d10) <= 0.025 { score += 18; support = f.ma10; signals.append(String(format: "回踩 10 日线 %.2f", f.ma10)) }
            else if abs(d20) <= 0.025 { score += 16; support = f.ma20; signals.append(String(format: "回踩 20 日线 %.2f", f.ma20)) }
            else if f.price > f.ma10 { score += 6 }
            score += (0.10...0.20).contains(drawdown) ? 10 : (drawdown < 0.10 ? 5 : 0)
            signals.append(String(format: "自高点回撤 %.0f%%", drawdown * 100))
            if f.avg20 > 0 && f.avg5 / f.avg20 < 0.85 { score += 12; signals.append("回调缩量，抛压减轻") }
            if let ar = f.amountRatio, ar < 0.9 { score += 5 }
            if f.ma20 > f.ma20Before { score += 10; signals.append("20 日线仍在上行") }
            if f.todayLow > 0, (f.price - f.todayLow) / f.prevClose >= 0.02 { score += 6; signals.append("盘中下探后拉回，下影承接") }
            if ctx.breadth.strongIndustries.contains(q.industry) { score += 6; signals.append("所属行业仍强（\(q.industry)）") }
            if let ar = f.amountRatio, ar > 1.5, q.changePercent < -2 { score -= 12; risks.append("放量下跌，可能是出货而非洗盘") }
            if f.price < f.ma20 { score -= 5; risks.append("略破 20 日线，需尽快收回") }
            if drawdown > 0.22 { risks.append(String(format: "回撤 %.0f%% 偏深，强势可能已结束", drawdown * 100)) }
            if ctx.weak { score *= 0.9 }
            let level = support ?? f.ma20
            results.append(item(q, "pullback", score, signals: signals, risks: risks, pivot: level, stop: max(level * 0.96, f.price * 0.9),
                                highlights: [String(format: "回撤 %.0f%%", drawdown * 100), String(format: "距10日线 %+.1f%%", d10 * 100),
                                             String(format: "距20日线 %+.1f%%", d20 * 100)]))
        }
        return finalize(results, min: 50)
    }

    // MARK: 板块龙头

    static func leader(_ ctx: QuantContext) -> [StockPick] {
        let groups = Dictionary(grouping: ctx.quotes.filter { !$0.suspended && $0.price > 0 && !$0.industry.isEmpty }, by: \.industry)
        let ranked = groups.filter { $0.value.count >= 8 }.map { name, members -> (String, Double, Double, Int, [Quote]) in
            let changes = members.map(\.changePercent).sorted(by: >)
            let limitUps = members.filter(\.upperLimit).count
            let top5 = changes.prefix(5).reduce(0, +) / Double(min(5, changes.count))
            return (name, median(changes) * 4 + top5 + Double(limitUps) * 1.5, median(changes), limitUps, members)
        }.sorted { $0.1 > $1.1 }.filter { $0.2 > 0 || $0.3 >= 2 }.prefix(6)
        var best: [String: StockPick] = [:]
        for (rank, sector) in ranked.enumerated() {
            let members = sector.4.filter { tradeable($0) && $0.amount >= 5e7 }
            guard members.count >= 3 else { continue }
            let byChange = members.sorted { $0.changePercent > $1.changePercent }
            let byAmount = members.sorted { $0.amount > $1.amount }
            let changeRank = Dictionary(uniqueKeysWithValues: byChange.enumerated().map { ($1.code, $0) })
            let amountRank = Dictionary(uniqueKeysWithValues: byAmount.enumerated().map { ($1.code, $0) })
            let n = Double(members.count)
            let scored = byChange.prefix(12).map { q -> (Double, Quote) in
                var lead = (1 - Double(changeRank[q.code]!) / n) * 40 + (1 - Double(amountRank[q.code]!) / n) * 25
                let first = ctx.pools.pool[q.code]?.firstTime
                if q.upperLimit {
                    lead += 15
                    if let t = first { lead += t < "10:00:00" ? 10 : (t < "11:30:01" ? 6 : 2) }
                }
                if ctx.live { lead += min(max(ctx.tracker.metrics(q.code, now: ctx.now).rise5, 0) / 3, 1) * 10 }
                return (lead, q)
            }.sorted { $0.0 > $1.0 }
            for (lead, q) in scored.prefix(2) {
                var score = max(35 - Double(rank) * 5, 10) + lead * 0.55
                var signals = [String(format: "行业「%@」热度第 %d（中位 %+.2f%%，涨停 %d 只）", sector.0, rank + 1, sector.2, sector.3),
                               "板块内涨幅第 \(changeRank[q.code]! + 1)、成交额第 \(amountRank[q.code]! + 1)"]
                var risks: [String] = [], tags = [sector.0]
                if q.upperLimit { tags.append("已封板"); signals.append(ctx.pools.pool[q.code]?.firstTime.map { "\($0.prefix(5)) 封板" } ?? "已封涨停") }
                if let f = ctx.features(q) { let (b, s, r) = dailyBonus(f); score += min(b, 10); signals += s; risks += r }
                if ctx.weak { score *= 0.9 }
                let pick = item(q, "leader", score, signals: signals, risks: risks, pivot: q.open ?? q.price,
                                stop: max((q.low ?? q.price) * 0.98, q.price * 0.92),
                                highlights: [sector.0, "板内涨幅 #\(changeRank[q.code]! + 1)", "板内成交 #\(amountRank[q.code]! + 1)"],
                                tags: tags, buyable: !q.upperLimit)
                if (best[q.code]?.score ?? -1) < pick.score { best[q.code] = pick }
            }
        }
        return finalize(Array(best.values), min: 45)
    }

    // MARK: 尾盘潜伏

    static func tail(_ ctx: QuantContext) -> [StockPick] {
        let minute = Market.minuteOfDay(ctx.now)
        var results: [StockPick] = []
        for q in ctx.quotes {
            guard !q.suspended, !q.upperLimit, q.price >= 2, tradeable(q), (2.5...6).contains(q.changePercent),
                  let vr = q.volumeRatio, vr >= 1.2, let turnover = q.turnover, (3...12).contains(turnover),
                  let cap = q.floatMarketCap, (3e9...3e10).contains(cap) else { continue }
            let high = q.high ?? q.price, low = q.low ?? q.price
            let position = high > low ? (q.price - low) / (high - low) : 1
            guard position >= 0.75 else { continue }
            var score = 20 + min(vr - 1.2, 1.8) / 1.8 * 12 + position * 10
            var signals: [String] = [], risks: [String] = []
            if (5...10).contains(turnover) { score += 6 }
            let afternoon = ctx.tracker.afternoonMarks(q.code)
            if afternoon.count >= 4 {
                let rises = zip(afternoon.dropFirst(), afternoon).filter { $0 >= $1 }.count
                if Double(rises) / Double(afternoon.count - 1) >= 0.7, afternoon.last! > afternoon.first! { score += 14; signals.append("午后 5 分钟线稳步走高") }
                else if afternoon.last! < (afternoon.max() ?? 0) * 0.99 { score -= 6; risks.append("午后冲高回落") }
            }
            if ctx.breadth.strongIndustries.contains(q.industry) { score += 6; signals.append("行业走强（\(q.industry)）") }
            if let f = ctx.features(q) {
                if f.ma5 > f.ma10 && f.ma10 > f.ma20 { score += 10; signals.append("日线短均线多头") }
                if f.ret20 > 0.25 { score -= 10; risks.append(String(format: "近 20 日已涨 %.0f%%", f.ret20 * 100)) }
                if f.streak > 0 { score -= 6; risks.append("昨日涨停，次日溢价已透支") }
                if f.avg20 > 0 && f.avg5 > f.avg20 { score += 4 }
            }
            signals.insert(String(format: "涨 %.1f%%、量比 %.1f、换手 %.1f%%，收在日内 %.0f%% 位置", q.changePercent, vr, turnover, position * 100), at: 0)
            if ctx.weak { score *= 0.9 }
            let preview = Market.isSession(ctx.now) && minute < 870
            results.append(item(q, "tail", score, signals: signals, risks: risks, pivot: low + (high - low) * 0.5, stop: q.price * 0.95,
                                highlights: [String(format: "量比 %.2f", vr), String(format: "换手 %.1f%%", turnover), String(format: "流通 %.0f 亿", cap / 1e8)],
                                tags: preview ? ["预览"] : []))
        }
        return finalize(results, min: 50)
    }

    // MARK: 尾盘隔夜

    /// Logistic models (same coefficients as the Mac bridge) for P(next-day high ≥ +3% / +5%)
    /// from 14:50 snapshot features, plus a small ridge model of the relative next-open gap.
    private static let overnightMu: [Double] = [-0.02299, 0.45772, 2.54109, -0.85013, 1.39985, 1.02516, -0.03806, 8.40879, 0.37384]
    private static let overnightSd: [Double] = [0.25786, 0.29975, 2.11196, 1.71071, 0.5524, 0.87328, 0.38893, 0.51185, 0.48382]
    private static let overnightClip: [(Double, Double)] = [(-0.8019, 0.6801), (0, 1), (0, 10.0885), (-5.7016, 3.7886), (0.0685, 2.6749),
                                                             (-1.273, 3.0227), (-0.8484, 1.2074), (7.7112, 9.8854), (0, 1)]
    private static let overnightW3: [Double] = [-1.05845, -0.00627, -0.05349, -0.02967, 0.04499, 0.51576, 0.13095, -0.16436, 0.16597, 0.06625]
    private static let overnightW5: [Double] = [-2.08604, 0.00571, 0.00745, 0.03622, 0.07755, 0.48858, 0.20956, -0.16658, 0.22457, 0.04491]
    private static let overnightWGap: [Double] = [0.0033, 0.03033, -0.05259, -0.04161, -0.02969, 0.0223, -0.08234, -0.05187, -0.05035, 0.04183]
    /// Out of sample the top decile's predicted probability ran ~17% high.
    private static let overnightCalibration = 0.83

    struct OvernightSnapshot {
        let p3: Double; let p5: Double; let gap: Double; let raw: [Double]
        let amp: Double; let turnover: Double?; let fullAmount: Double; let vwap: Double?
    }

    /// 14:50 snapshot features and the next-day-high probabilities for one stock (no eligibility filters).
    static func overnightSnapshot(_ q: Quote, fraction: Double) -> OvernightSnapshot? {
        guard let high = q.high, let low = q.low, high > 0, low > 0, q.price > 0 else { return nil }
        let prev = q.prevClose ?? q.price / (1 + q.changePercent / 100)
        guard prev > 0 else { return nil }
        let ratio = Market.limitRatio(code: q.code, name: q.name) ?? 0.1
        let fullAmount = q.amount / max(fraction, 0.03)
        var vwap: Double?
        for scale in [100.0, 1.0] where q.volume > 0 {
            let candidate = q.amount / (q.volume * scale)
            if candidate >= low * 0.97 && candidate <= high * 1.03 { vwap = candidate; break }
        }
        let turnover = q.turnover.map { $0 / max(fraction, 0.03) }
        let amp = (high - low) / prev * 100
        let raw: [Double] = [
            q.changePercent / (ratio * 100),
            high > low ? (q.price - low) / (high - low) : 1,
            (high - q.price) / prev * 100,
            vwap.map { (q.price / $0 - 1) * 100 } ?? 0,
            log(max(amp, 0.3)),
            turnover.map { log(max($0, 0.2)) } ?? overnightMu[5],
            q.volumeRatio.map { log(min(max($0, 0.1), 20)) } ?? overnightMu[6],
            log10(max(fullAmount, 1)),
            ratio >= 0.2 ? 1 : 0,
        ]
        var z: [Double] = [1]
        for i in raw.indices { z.append((min(max(raw[i], overnightClip[i].0), overnightClip[i].1) - overnightMu[i]) / overnightSd[i]) }
        func dot(_ w: [Double]) -> Double { zip(w, z).reduce(0) { $0 + $1.0 * $1.1 } }
        return OvernightSnapshot(p3: 1 / (1 + exp(-dot(overnightW3))) * overnightCalibration,
                                 p5: 1 / (1 + exp(-dot(overnightW5))) * overnightCalibration,
                                 gap: dot(overnightWGap), raw: raw, amp: amp, turnover: turnover, fullAmount: fullAmount, vwap: vwap)
    }

    static func overnight(_ ctx: QuantContext, perBoard: Int = 15) -> [StockPick] {
        let minute = Market.minuteOfDay(ctx.now)
        let preview = Market.isSession(ctx.now) && minute < 890
        let fraction = Market.volumeFraction(ctx.now)
        var byBoard: [String: [(rank: Double, p3: Double, p5: Double, gap: Double, raw: [Double], amp: Double, turnover: Double?, amount: Double, q: Quote)]] = [:]
        for q in ctx.quotes {
            guard !q.suspended, !q.upperLimit, !q.lowerLimit, q.price >= 2, tradeable(q) else { continue }
            if let up = q.limitUpPrice, q.price >= up - 0.011 { continue }
            guard let snap = overnightSnapshot(q, fraction: fraction), snap.fullAmount >= 5e7 else { continue }
            let (p3, p5, gap, raw, amp, turnover, fullAmount) = (snap.p3, snap.p5, snap.gap, snap.raw, snap.amp, snap.turnover, snap.fullAmount)
            let board = WatchData.pickBoard(code: q.code)
            byBoard[board, default: []].append((p5 + 0.1 * gap, p3, p5, gap, raw, amp, turnover, fullAmount, q))
        }
        var results: [StockPick] = []
        for (board, entries) in byBoard {
            for (index, e) in entries.sorted(by: { $0.rank > $1.rank }).prefix(perBoard).enumerated() {
                let q = e.q
                let score = 100 * (0.5 * min(e.p3 / 0.6, 1) + 0.5 * min(e.p5 / 0.4, 1))
                var signals = [String(format: "次日盘中冲高 ≥3%% 概率约 %.0f%%，≥5%% 约 %.0f%%（全市场平均约 25%% / 12%%）", e.p3 * 100, e.p5 * 100),
                               "\(board)第 \(index + 1) 名：" + String(format: "振幅 %.1f%%", e.amp)
                                + (e.turnover.map { String(format: "、换手 %.1f%%", $0) } ?? "") + "、成交 \(Fmt.yuan(e.amount))（全天折算）"]
                if e.raw[2] >= 3 { signals.append(String(format: "上影 %.1f%%：盘中资金试过拉升，次日再冲概率更高", e.raw[2])) }
                if e.raw[3] <= 0 { signals.append("现价在分时均价线下方，没有尾盘追高") }
                var risks = ["高波动股次日开盘平均低开约 1%：不要开盘市价卖，挂止盈单等冲高"]
                if e.raw[3] > 1.5 { risks.append(String(format: "高于分时均价 %.1f%%，尾盘追高，次日低开概率大", e.raw[3])) }
                if e.raw[1] > 0.9 && q.changePercent > 3 { risks.append("收在日内最高附近，回测显示次日开盘更弱") }
                if e.gap < -0.4 { risks.append("隔夜模型估计其低开幅度在候选中偏大") }
                if ctx.weak { risks.append("今日市场弱势") }
                let takeProfit = Market.roundPrice(q.price * 1.03)
                var pick = item(q, "overnight", score, signals: signals, risks: risks, pivot: takeProfit, stop: Market.roundPrice(q.price * 0.97),
                                highlights: [String(format: "冲高≥3%% %.0f%%", e.p3 * 100), String(format: "冲高≥5%% %.0f%%", e.p5 * 100),
                                             String(format: "振幅 %.1f%%", e.amp)],
                                tags: [board] + (preview ? ["预览"] : []))
                pick.pHi3 = (e.p3 * 1000).rounded() / 10
                pick.pHi5 = (e.p5 * 1000).rounded() / 10
                pick.takeProfit = takeProfit
                pick.board = board
                results.append(pick)
            }
        }
        return results.sorted { ($0.pHi5 ?? 0) > ($1.pHi5 ?? 0) }
    }

    // MARK: 综合

    static func combine(_ lists: [String: [StockPick]]) -> [StockPick] {
        var merged: [String: (pick: StockPick, base: Int)] = [:]
        for id in strategies.map(\.id) where id != "all" && id != "overnight" {
            for pick in lists[id] ?? [] {
                if var current = merged[pick.code] {
                    current.pick.strategies.append(id)
                    if pick.score > current.base {
                        var replacement = pick; replacement.strategies = current.pick.strategies
                        current = (replacement, pick.score)
                    }
                    merged[pick.code] = current
                } else {
                    merged[pick.code] = (pick, pick.score)
                }
            }
        }
        return merged.values.map { entry -> StockPick in
            var pick = entry.pick
            let score = min(entry.base + 6 * (pick.strategies.count - 1), 100)
            pick.score = score; pick.grade = grade(Double(score))
            let titles = pick.strategies.compactMap { self.titles[$0] }
            if titles.count > 1 { pick.signals.insert("多策略共振：" + titles.joined(separator: "、"), at: 0) }
            pick.tags = titles + pick.tags.filter { !titles.contains($0) }
            return pick
        }.sorted { ($0.score, $0.strategies.count) > ($1.score, $1.strategies.count) }.prefix(30).map { $0 }
    }
}


extension QuantEngine {
    /// 追高型突破扣分，与服务端 `_chase_penalty` 一致（2026-11-12 复盘 + 1057 只 × 1 年日线回测：
    /// 当日涨 ≥5%、额比 ≥3.5、乖离 ≥10% 的趋势信号 5 日平均跑输大盘约 2%）。
    static func chasePenalty(_ f: DailyFeatures, change: Double, upperLimit: Bool) -> (Double, [String]) {
        var penalty = 0.0, risks: [String] = [], hits = 0
        let ratio = f.amountRatio
        if let r = ratio, r >= 5 { penalty += 12; hits += 1; risks.append(String(format: "巨量 %.1f 倍，回测 5 日平均跑输大盘", r)) }
        else if let r = ratio, r >= 3.5, change >= 1 { penalty += 6; hits += 1; risks.append(String(format: "放量 %.1f 倍，分歧加大", r)) }
        if f.bias20 > 0.10 && f.bias20 <= 0.15 { penalty += 6; hits += 1 } else if f.bias20 > 0.15 { hits += 1 }
        if f.prevClose > 0 && f.todayHigh > 0 && (f.todayHigh - f.price) / f.prevClose > 0.05 {
            penalty += 10; hits += 1
            risks.append(String(format: "冲高回落 %.1f%%，抛压重", (f.todayHigh - f.price) / f.prevClose * 100))
        }
        if !upperLimit && change >= 6 && change < 12 {
            penalty += 6; hits += 1; risks.append(String(format: "当日已涨 %.1f%%，次日回吐概率高", change))
        }
        if hits >= 3 || (change >= 5 && (ratio ?? 0) >= 3.5 && f.bias20 >= 0.10) {
            risks.insert("追高型突破：回测次日平均低开约 1%、5 日跑输大盘约 2%，等回踩 10 日线再考虑", at: 0)
        }
        return (penalty, risks)
    }
}
