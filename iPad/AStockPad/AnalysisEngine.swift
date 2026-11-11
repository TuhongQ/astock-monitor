import Foundation

// Swift port of the Mac bridge's 个股分析 (/analyze): the short-term index uses the same
// strategy scores as 潜力股, the trend index scores trend / momentum / volume / environment,
// and the probabilities come from logistic models backtested on 1,490 A-shares in 2026.

struct AnalysisComponent: Hashable { let name: String; let score: Double; let max: Double; let detail: String; let group: String }
struct AnalysisProbability: Hashable { let label: String; let value: Double; let baseline: Double; let note: String }
struct AnalysisLevel: Hashable { let label: String; let price: Double; let note: String }
struct FlowRow: Hashable { let name: String; let inflow: Double?; let outflow: Double?; let net: Double?; let netRatio: Double? }
struct FlowMinute: Hashable { let index: Int; let main: Double; let retail: Double; let superLarge: Double }
struct FlowDay: Hashable { let date: String; let main: Double }
struct BookLevel: Hashable { let price: Double; let volume: Double }
struct StatItem: Hashable { let label: String; let value: String; let tone: Int; let hint: String? }
struct StatGroup: Hashable { let title: String; let items: [StatItem] }
struct IntradayPoint: Hashable { let index: Int; let price: Double; let avg: Double? }

struct AnalysisExtras {
    var flowRows: [FlowRow] = []
    var mainNet: Double?
    var retailNet: Double?
    var mainRatio: Double?
    var minutes: [FlowMinute] = []
    var days: [FlowDay] = []
    var intraday: [IntradayPoint] = []
    var preClose: Double?
    var bids: [BookLevel] = []
    var asks: [BookLevel] = []
    var stats: [StatGroup] = []
}

struct StockAnalysisResult {
    let code: String
    let name: String
    let industry: String
    let price: Double
    let change: Double
    let index: Int
    let shortIndex: Int
    let trendIndex: Int
    let shortBasis: String
    let horizon: String
    let verdict: String
    let tone: String
    let buyer: String
    let holder: String
    let components: [AnalysisComponent]
    let probabilities: [AnalysisProbability]
    let levels: [AnalysisLevel]
    let signals: [String]
    let risks: [String]
    let strategies: [StockPick]
    let news: [NewsItem]
    let extras: AnalysisExtras
    let daily: [Candle]
    let time: Date

    static let notes = [
        "短线指数与潜力股同一套策略评分（最高分 + 多策略各加 6 分，A ≥ 75）；趋势指数由趋势、动量、量能、环境打分。入选策略时推荐指数以短线为主，否则以趋势为主。都是规则评分，不是对涨跌的预测。",
        "回测（1490 只个股，2026 年）显示：日线技术指标无法预测 5 日涨跌方向（AUC 0.50），能预测的主要是波动大小；概率栏为这类模型结果，括号内为全市场平均。",
        "仅供参考，不构成投资建议。",
    ]
}

extension EastmoneyClient {
    /// Quote stats, fund flow by order size, intraday curve with average price, and the order book.
    func fetchAnalysisExtras(code: String) async -> AnalysisExtras {
        let secid = Market.secid(code)
        let fields = "f43,f48,f49,f50,f55,f92,f105,f116,f117,f135,f136,f137,f138,f139,f140,f141,f142,f143,f144,f145,f146,f147,f148,f149,"
            + "f161,f162,f164,f167,f168,f171,f173,f186,f187,f188,f191,f11,f12,f13,f14,f15,f16,f17,f18,f19,f20,f31,f32,f33,f34,f35,f36,f37,f38,f39,f40"
        let referer = "https://quote.eastmoney.com/"
        async let quoteObject = try? json("https://push2.eastmoney.com/api/qt/stock/get?secid=\(secid)&fltt=2&invt=2&fields=\(fields)", referer: referer)
        async let minuteObject = try? json("https://push2.eastmoney.com/api/qt/stock/fflow/kline/get?lmt=0&klt=1&secid=\(secid)&fields1=f1,f2,f3,f7&fields2=f51,f52,f53,f54,f55,f56", referer: referer)
        async let dayObject = try? json("https://push2his.eastmoney.com/api/qt/stock/fflow/daykline/get?lmt=20&klt=101&secid=\(secid)&fields1=f1,f2,f3,f7&fields2=f51,f52,f53,f54,f55,f56,f57", referer: referer)
        async let trendObject = try? json("https://push2his.eastmoney.com/api/qt/stock/trends2/get?secid=\(secid)&fields1=f1,f2,f8&fields2=f51,f53,f58&ndays=1&iscr=0", referer: referer)
        let (quoteRaw, minuteRaw, dayRaw, trendRaw) = await (quoteObject, minuteObject, dayObject, trendObject)
        func data(_ object: Any?) -> [String: Any] { ((object as? [String: Any])?["data"] as? [String: Any]) ?? [:] }
        let q = data(quoteRaw)
        func n(_ key: String) -> Double? { Self.number(q[key]) }
        var extras = AnalysisExtras()

        if let main = n("f137") {
            let amount = n("f48") ?? 0
            func ratio(_ net: Double?) -> Double? { amount > 0 ? (net ?? 0) / amount * 100 : nil }
            let superLarge = FlowRow(name: "超大单", inflow: n("f138"), outflow: n("f139"), net: n("f140"), netRatio: ratio(n("f140")))
            let large = FlowRow(name: "大单", inflow: n("f141"), outflow: n("f142"), net: n("f143"), netRatio: ratio(n("f143")))
            let medium = FlowRow(name: "中单", inflow: n("f144"), outflow: n("f145"), net: n("f146"), netRatio: ratio(n("f146")))
            let small = FlowRow(name: "小单", inflow: n("f147"), outflow: n("f148"), net: n("f149"), netRatio: ratio(n("f149")))
            let retailNet = (medium.net ?? 0) + (small.net ?? 0)
            let retail = FlowRow(name: "散户", inflow: (medium.inflow ?? 0) + (small.inflow ?? 0),
                                 outflow: (medium.outflow ?? 0) + (small.outflow ?? 0), net: retailNet, netRatio: ratio(retailNet))
            let mainRow = FlowRow(name: "主力", inflow: n("f135"), outflow: n("f136"), net: main, netRatio: ratio(main))
            extras.flowRows = [mainRow, superLarge, large, retail, medium, small]
            extras.mainNet = main
            extras.retailNet = retailNet
            extras.mainRatio = ratio(main)
        }
        for (i, line) in ((data(minuteRaw)["klines"] as? [String]) ?? []).enumerated() {
            let f = line.split(separator: ",").map { Double($0) ?? 0 }
            guard f.count >= 6 else { continue }
            extras.minutes.append(FlowMinute(index: i, main: f[1], retail: f[2] + f[3], superLarge: f[5]))
        }
        for line in (data(dayRaw)["klines"] as? [String]) ?? [] {
            let f = line.split(separator: ",").map(String.init)
            guard f.count >= 2 else { continue }
            extras.days.append(FlowDay(date: f[0], main: Double(f[1]) ?? 0))
        }
        let trend = data(trendRaw)
        extras.preClose = Self.number(trend["preClose"])
        for (i, line) in ((trend["trends"] as? [String]) ?? []).enumerated() {
            let f = line.split(separator: ",").map(String.init)
            guard f.count >= 3, let price = Double(f[1]), price > 0 else { continue }
            extras.intraday.append(IntradayPoint(index: i, price: price, avg: Double(f[2])))
        }
        let bidKeys = [("f19", "f20"), ("f17", "f18"), ("f15", "f16"), ("f13", "f14"), ("f11", "f12")]
        let askKeys = [("f39", "f40"), ("f37", "f38"), ("f35", "f36"), ("f33", "f34"), ("f31", "f32")]
        extras.bids = bidKeys.compactMap { p, v in n(p).flatMap { $0 > 0 ? BookLevel(price: $0, volume: n(v) ?? 0) : nil } }
        extras.asks = askKeys.compactMap { p, v in n(p).flatMap { $0 > 0 ? BookLevel(price: $0, volume: n(v) ?? 0) : nil } }

        if !q.isEmpty {
            func pct(_ v: Double?, signed: Bool = false) -> String { v.map { String(format: signed ? "%+.2f%%" : "%.2f%%", $0) } ?? "—" }
            func plain(_ v: Double?, _ digits: Int = 2) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "—" }
            let price = n("f43") ?? 0
            let outer = n("f49"), inner = n("f161")
            extras.stats = [
                StatGroup(title: "交易", items: [
                    StatItem(label: "换手率", value: pct(n("f168")), tone: (n("f168") ?? 0) >= 5 ? 1 : 0, hint: nil),
                    StatItem(label: "量比", value: plain(n("f50")), tone: (n("f50") ?? 0) > 1.5 ? 1 : 0, hint: nil),
                    StatItem(label: "振幅", value: pct(n("f171")), tone: 0, hint: nil),
                    StatItem(label: "成交额", value: Fmt.yuan(n("f48")), tone: 0, hint: nil),
                    StatItem(label: "外盘 / 内盘", value: outer != nil && inner != nil ? "\(Fmt.yuan(outer! * 100 * price)) / \(Fmt.yuan(inner! * 100 * price))" : "—",
                             tone: (outer ?? 0) > (inner ?? 0) ? 1 : -1, hint: "主动买入 / 主动卖出"),
                    StatItem(label: "委比", value: pct(n("f191"), signed: true), tone: (n("f191") ?? 0) > 0 ? 1 : ((n("f191") ?? 0) < 0 ? -1 : 0), hint: nil),
                ]),
                StatGroup(title: "估值与财务", items: [
                    StatItem(label: "市盈率（动）", value: plain(n("f162")), tone: 0, hint: nil),
                    StatItem(label: "市盈率（TTM）", value: plain(n("f164")), tone: 0, hint: nil),
                    StatItem(label: "市净率", value: plain(n("f167")), tone: 0, hint: nil),
                    StatItem(label: "总市值", value: Fmt.yuan(n("f116")), tone: 0, hint: nil),
                    StatItem(label: "流通市值", value: Fmt.yuan(n("f117")), tone: 0, hint: nil),
                    StatItem(label: "每股收益", value: plain(n("f55"), 3), tone: 0, hint: nil),
                    StatItem(label: "每股净资产", value: plain(n("f92")), tone: 0, hint: nil),
                    StatItem(label: "ROE", value: pct(n("f173")), tone: 0, hint: nil),
                    StatItem(label: "毛利率", value: pct(n("f186")), tone: 0, hint: nil),
                    StatItem(label: "净利率", value: pct(n("f187")), tone: 0, hint: nil),
                    StatItem(label: "负债率", value: pct(n("f188")), tone: 0, hint: nil),
                    StatItem(label: "净利润", value: Fmt.yuan(n("f105")), tone: (n("f105") ?? 0) >= 0 ? 0 : -1, hint: nil),
                ]),
            ]
        }
        return extras
    }
}

enum AnalysisEngine {
    // 5-day outlook logistic models (same coefficients as the Mac bridge).
    private static let feats = ["chg", "limitPct", "pos", "upper", "ret5", "ret20", "ret60", "bias20", "bias60", "maBull", "ma20Up",
                                "maSpread", "amtRatioL", "volTrendL", "trL", "vol10", "volRatio", "toHigh60", "toLow60", "brk20", "macd",
                                "difPos", "limitUp", "limits10", "lnAmt", "gem"]
    private static let clip: [(Double, Double)] = [(-9.016, 10.039), (-0.752, 1.0), (0, 1), (0, 9.703), (-18.735, 24.947), (-34.243, 54.375),
                                                   (-41.117, 112.379), (-21.653, 26.889), (-29.499, 51.158), (0, 1), (0, 1), (0.335, 23.785),
                                                   (-0.858, 1.21), (-0.864, 0.828), (-1.386, 2.988), (0.763, 8.082), (0.342, 1.925),
                                                   (-50.447, -0.609), (0.2, 129.196), (0, 1), (-3.973, 2.867), (0, 1), (0, 1), (0, 2),
                                                   (7.243, 9.829), (0, 1)]
    private static let mu: [Double] = [-0.09728, -0.00577, 0.46538, 2.31283, -0.30962, 0.27888, 4.10872, -0.52138, 0.25459, 0.17982, 0.44462,
                                       5.10942, -0.05345, -0.04658, 0.8971, 2.96072, 1.01785, -17.41837, 20.01435, 0.04808, -0.11804, 0.43679,
                                       0.01498, 0.13729, 8.28127, 0.37061]
    private static let sd: [Double] = [3.23356, 0.26946, 0.30198, 1.95768, 7.28384, 15.17045, 27.15103, 8.0672, 14.48688, 0.38404, 0.49693,
                                       4.05884, 0.38646, 0.33631, 0.90959, 1.51963, 0.34955, 10.42961, 24.95056, 0.21394, 1.07278, 0.49599,
                                       0.12148, 0.42112, 0.57111, 0.48297]
    private static let wBig: [Double] = [-1.63395, 0.05013, -0.02189, -0.03932, 0.08358, -0.08476, -0.08375, -0.13068, 0.05714, 0.02339,
                                         -0.00494, 0.00921, -0.01249, -0.03914, -0.00352, 0.07756, 0.18633, -0.0963, 0.00216, 0.20312, 0.02603,
                                         0.08336, 0.03132, 0.09039, -0.06832, 0.14114, 0.03533]
    private static let wDrop: [Double] = [-1.19753, 0.02644, -0.00162, 0.22881, 0.25251, 0.08587, 0.09318, -0.00307, -0.22205, -0.04905,
                                          0.06787, -0.01534, -0.03843, -0.01373, 0.00227, 0.17602, 0.32059, -0.25336, 0.03879, -0.01443,
                                          -0.00776, 0.02327, 0.00002, -0.01327, 0.06121, 0.03198, 0.03137]
    static let baseBig = 17.5, baseDrop = 21.0

    struct Swing {
        let pBig: Double, pDrop: Double
        let raw: [String: Double]
        let ma5: Double, ma10: Double, ma20: Double, ma60: Double
        let dif: Double, dea: Double
        let high20: Double, high60: Double, low20: Double
        let amountRatio: Double?
        let upDown: Double?
    }

    static func swing(_ q: Quote, history: [Candle], now: Date) -> Swing? {
        let today = Market.dayKey(now)
        var bars = history.filter { $0.date != today }
        guard bars.count >= 70 else { return nil }
        let price = q.price
        if let last = bars.last, abs(last.close - price) < 0.006, bars.count >= 2,
           abs((last.close / bars[bars.count - 2].close - 1) * 100 - q.changePercent) < 0.06 {
            bars.removeLast()
        }
        let prev = bars.last!.close
        let high = q.high ?? price, low = q.low ?? price
        let closes = bars.map(\.close) + [price]
        let highs = bars.map(\.high) + [high]
        let lows = bars.map(\.low) + [low]
        let amounts = bars.map(\.amount)
        let fraction = Market.volumeFraction(now)
        let todayAmount = q.amount / max(fraction, 0.03)
        let ratio = Market.limitRatio(code: q.code, name: q.name) ?? 0.1
        func sma(_ values: [Double], _ n: Int) -> Double { let w = values.suffix(n); return w.reduce(0, +) / Double(w.count) }
        let ma5 = sma(closes, 5), ma10 = sma(closes, 10), ma20 = sma(closes, 20), ma60 = sma(closes, 60)
        let ma20Prev = sma(Array(closes.dropLast(5)), 20)
        let returns = zip(closes.dropFirst(), closes).map { $0 / $1 - 1 }
        func std(_ values: ArraySlice<Double>) -> Double {
            let m = values.reduce(0, +) / Double(values.count)
            return sqrt(values.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(max(values.count - 1, 1)))
        }
        var ema12 = closes[0], ema26 = closes[0], difs: [Double] = []
        for c in closes { ema12 = 2 / 13 * c + 11 / 13 * ema12; ema26 = 2 / 27 * c + 25 / 27 * ema26; difs.append(ema12 - ema26) }
        var dea = difs[0]
        for d in difs { dea = 0.2 * d + 0.8 * dea }
        let avg5 = amounts.count >= 5 ? amounts.suffix(5).reduce(0, +) / 5 : 0
        let avg20 = amounts.count >= 20 ? amounts.suffix(20).reduce(0, +) / 20 : 0
        var limitHits = 0
        for i in (closes.count - 10)..<closes.count where closes[i] >= ((closes[i - 1] * (1 + ratio)) * 100).rounded() / 100 - 0.005 { limitHits += 1 }
        let change = (price / prev - 1) * 100
        let turnover = q.turnover.map { $0 / max(fraction, 0.03) }
        let spread = [ma5, ma10, ma20]
        var up = 0.0, down = 0.0
        for i in (bars.count - 20)..<bars.count where i > 0 {
            if bars[i].close >= bars[i - 1].close { up += bars[i].amount } else { down += bars[i].amount }
        }
        let raw: [String: Double] = [
            "chg": change, "limitPct": change / (ratio * 100), "pos": high > low ? (price - low) / (high - low) : 1,
            "upper": (high - price) / prev * 100,
            "ret5": (price / closes[closes.count - 6] - 1) * 100, "ret20": (price / closes[closes.count - 21] - 1) * 100,
            "ret60": (price / closes[closes.count - 61] - 1) * 100,
            "bias20": (price / ma20 - 1) * 100, "bias60": (price / ma60 - 1) * 100,
            "maBull": ma5 > ma10 && ma10 > ma20 && ma20 > ma60 ? 1 : 0, "ma20Up": ma20 > ma20Prev ? 1 : 0,
            "maSpread": (spread.max()! - spread.min()!) / price * 100,
            "amtRatioL": avg5 > 0 ? log(min(max(todayAmount / avg5, 0.1), 20)) : 0,
            "volTrendL": avg20 > 0 ? log(min(max(avg5 / avg20, 0.1), 10)) : 0,
            "trL": turnover.map { log(min(max($0, 0.1), 60)) } ?? mu[14],
            "vol10": std(returns.suffix(10)) * 100,
            "volRatio": min(std(returns.suffix(10)) / max(std(returns.suffix(60)), 1e-9), 4),
            "toHigh60": (price / highs.suffix(60).max()! - 1) * 100, "toLow60": (price / lows.suffix(60).min()! - 1) * 100,
            "brk20": price > highs.dropLast().suffix(20).max()! ? 1 : 0,
            "macd": (difs.last! - dea) / price * 100, "difPos": difs.last! > 0 ? 1 : 0,
            "limitUp": q.upperLimit ? 1 : 0, "limits10": Double(limitHits),
            "lnAmt": log10(max(todayAmount, 1)), "gem": ratio >= 0.2 ? 1 : 0,
        ]
        var z: [Double] = [1]
        for (i, name) in feats.enumerated() { z.append((min(max(raw[name] ?? 0, clip[i].0), clip[i].1) - mu[i]) / sd[i]) }
        func logistic(_ w: [Double]) -> Double { 1 / (1 + exp(-zip(w, z).reduce(0) { $0 + $1.0 * $1.1 })) }
        return Swing(pBig: logistic(wBig) * 100, pDrop: logistic(wDrop) * 100, raw: raw, ma5: ma5, ma10: ma10, ma20: ma20, ma60: ma60,
                     dif: difs.last!, dea: dea, high20: highs.dropLast().suffix(20).max()!, high60: highs.dropLast().suffix(60).max()!,
                     low20: lows.dropLast().suffix(20).min()!, amountRatio: avg5 > 0 ? todayAmount / avg5 : nil,
                     upDown: down > 0 ? up / down : nil)
    }

    static func analyze(_ q: Quote, history: [Candle], lists: [String: [StockPick]], breadth: MarketBreadth?, emotion: LimitEmotion?,
                        pools: LimitPools, tracker: TickTracker, extras: AnalysisExtras, news: [NewsItem], now: Date) -> StockAnalysisResult {
        let price = q.price, change = q.changePercent
        let sw = swing(q, history: history, now: now)
        let matches = QuantEngine.strategies.filter { $0.id != "all" }.compactMap { meta in lists[meta.id]?.first { $0.code == q.code } }
        let snap = QuantEngine.overnightSnapshot(q, fraction: Market.volumeFraction(now))
        let sealed = pools.pool[q.code], broken = pools.broken[q.code]
        let surges = tracker.events[q.code] ?? []
        var components: [AnalysisComponent] = [], signals: [String] = [], risks: [String] = []
        func add(_ name: String, _ score: Double, _ maxScore: Double, _ detail: String, _ group: String) {
            components.append(AnalysisComponent(name: name, score: (min(max(score, 0), maxScore) * 10).rounded() / 10, max: maxScore, detail: detail, group: group))
        }

        // 趋势（25）
        var trend = 0.0, trendNotes: [String] = []
        if let s = sw {
            if s.raw["maBull"] == 1 { trend += 9; trendNotes.append("均线多头排列") }
            if price > s.ma20 { trend += 5; trendNotes.append("站上 20 日线") } else { trendNotes.append("在 20 日线下方") }
            if price > s.ma60 { trend += 4; trendNotes.append("站上 60 日线") }
            if s.raw["ma20Up"] == 1 { trend += 3; trendNotes.append("20 日线向上") }
            if s.dif > s.dea { trend += s.dif > 0 ? 4 : 2; trendNotes.append("MACD 多头" + (s.dif > 0 ? "（零轴上）" : "")) } else { trendNotes.append("MACD 空头") }
        }
        add("趋势", trend, 25, trendNotes.isEmpty ? "日线不足" : trendNotes.joined(separator: "，"), "趋势")

        // 动量与位置（15）
        var momentum = 0.0, momNotes: [String] = []
        if let s = sw, let r20 = s.raw["ret20"], let b20 = s.raw["bias20"] {
            if r20 > 0 && r20 <= 25 { momentum += 7; momNotes.append(String(format: "20 日涨 %.1f%%，强而不过热", r20)) }
            else if r20 > 25 { momentum += 3; momNotes.append(String(format: "20 日涨 %.1f%%，短期过热", r20)) }
            else { momNotes.append(String(format: "20 日 %+.1f%%", r20)) }
            if s.raw["brk20"] == 1 { momentum += 5; momNotes.append("突破 20 日高点") }
            else if (s.raw["toHigh60"] ?? -99) > -5 { momentum += 3; momNotes.append("接近 60 日高点") }
            if b20 > 15 { momentum -= 4; risks.append(String(format: "偏离 20 日线 %.1f%%，追高风险", b20)) }
            else if b20 >= -3 && b20 <= 6 { momentum += 3 }
        }
        add("动量与位置", momentum, 15, momNotes.isEmpty ? "—" : momNotes.joined(separator: "，"), "趋势")

        // 量能（15）
        var volume = 0.0, volNotes: [String] = []
        if let ratio = sw?.amountRatio {
            if ratio >= 1.2 && ratio <= 3 && change > 0 { volume += 8; volNotes.append(String(format: "放量上涨（%.1f 倍）", ratio)) }
            else if ratio > 3 && change > 0 { volume += 4; volNotes.append(String(format: "巨量（%.1f 倍），分歧大", ratio)) }
            else if ratio > 1.5 && change < 0 { volume -= 2; volNotes.append(String(format: "放量下跌（%.1f 倍）", ratio)); risks.append("放量下跌，资金在离场") }
            else if ratio < 0.8 { volume += change >= 0 ? 3 : 4; volNotes.append(String(format: "缩量（%.1f 倍）", ratio)) }
            else { volume += 4; volNotes.append(String(format: "量能平稳（%.1f 倍）", ratio)) }
        }
        if let ud = sw?.upDown {
            if ud >= 1.5 { volume += 5; volNotes.append(String(format: "近 20 日红肥绿瘦（%.1f）", ud)) }
            else if ud < 0.8 { volNotes.append(String(format: "近 20 日绿肥红瘦（%.1f）", ud)) }
            else { volume += 2 }
        }
        add("量能", volume, 15, volNotes.isEmpty ? "—" : volNotes.joined(separator: "，"), "趋势")

        // 盘中（10）
        var intraday = 5.0, intraNotes: [String] = []
        if let high = q.high, let low = q.low, high > low {
            let position = (price - low) / (high - low)
            intraday += (position - 0.5) * 6
            intraNotes.append(String(format: "日内位置 %.0f%%", position * 100))
        }
        if let vwap = snap?.vwap {
            let dev = (price / vwap - 1) * 100
            intraday += dev > 0 ? 1.5 : -1.5
            intraNotes.append(String(format: "%@分时均价 %.1f%%", dev > 0 ? "高于" : "低于", abs(dev)))
        }
        if !surges.isEmpty { intraday += 2; intraNotes.append("今日速拉 \(surges.count) 次") }
        if let sealed {
            intraday = 10; intraNotes.append("已封涨停（\(sealed.firstTime ?? "—") 首封）"); risks.append("已封涨停，排队难买入")
        } else if broken != nil {
            intraday -= 2; intraNotes.append("今日炸板"); risks.append("今日冲板失败（炸板），抛压较重")
        }
        add("盘中", intraday, 10, intraNotes.isEmpty ? "—" : intraNotes.joined(separator: "，"), "短线")

        // 策略评分（与潜力股同一套）
        let best = matches.max { $0.score < $1.score }
        add("策略评分", Double(best?.score ?? 0), 100,
            matches.isEmpty ? "未入选任何选股策略" : matches.map { "\(QuantEngine.titles[$0.strategy] ?? $0.strategy) \($0.score)（\($0.grade)）" }.joined(separator: "、"), "短线")

        // 市场环境（10）
        var env = 5.0, envNotes: [String] = []
        let regime = breadth?.regime
        if regime == "强势" { env += 3; envNotes.append("市场强势") } else if regime == "弱势" { env -= 3; envNotes.append("市场弱势") } else if regime != nil { envNotes.append("市场震荡") }
        let mood = emotion?.mood
        if mood == "高潮" || mood == "回暖" { env += 2 } else if mood == "退潮" { env -= 2 }
        if let mood { envNotes.append("打板情绪\(mood)") }
        if !q.industry.isEmpty, breadth?.strongIndustries.contains(q.industry) == true { env += 2; envNotes.append("所属行业「\(q.industry)」领涨") }
        add("市场环境", env, 10, envNotes.isEmpty ? "—" : envNotes.joined(separator: "，"), "趋势")

        // 风险（只扣趋势分；波动大只提示）
        var penalty = 0.0
        if let s = sw {
            if let r20 = s.raw["ret20"], r20 > 50 { penalty += 12; risks.append(String(format: "20 日涨幅 %.0f%%，高位", r20)) }
            if let v = s.raw["vol10"], v > 5 { risks.append(String(format: "近 10 日日波动 %.1f%%，波动剧烈，仓位宜轻", v)) }
            if s.pDrop > 35 { risks.append(String(format: "模型估计 5 日内跌超 5%% 的概率 %.0f%%（全市场约 %.0f%%）", s.pDrop, baseDrop)) }
            if price < s.ma20 && price < s.ma60 { penalty += 5 }
        }
        if let streak = sealed?.streak, streak >= 4 { penalty += 8; risks.append("\(streak) 连板高位，接力风险大") }
        if q.isST { penalty += 20; risks.append("ST 股，有退市风险") }
        if penalty > 0 { components.append(AnalysisComponent(name: "风险扣分", score: -penalty, max: 0, detail: "高位 / 破位 / 高连板 / ST", group: "趋势")) }

        let trendIndex = Int(max(0, min((trend + momentum + volume + env) / 65 * 100 - penalty, 100)).rounded())
        var short: Double
        let shortBasis: String
        if let best {
            short = min(Double(best.score + 6 * (matches.count - 1)), 100)
            shortBasis = "\(QuantEngine.titles[best.strategy] ?? best.strategy) \(best.score)" + (matches.count > 1 ? " 等 \(matches.count) 个策略" : "")
        } else {
            short = 35 + (snap.map { ($0.p5 * 100 - 12) * 0.8 } ?? 0) + (intraday - 5) * 2
            short = min(max(short, 0), 58)
            shortBasis = "未入选策略，按盘中走势与次日冲高概率估算（上限 58）"
        }
        if mood == "退潮" { short -= 5 }
        if regime == "弱势" { short -= 5 }
        if broken != nil && !matches.contains(where: { $0.strategy == "limit" }) { short -= 5 }
        if q.isST { short = min(short, 20) }
        let shortIndex = Int(max(0, min(short, 100)).rounded())
        let index = matches.isEmpty ? Int((0.35 * Double(shortIndex) + 0.65 * Double(trendIndex)).rounded())
                                    : max(shortIndex, Int((0.65 * Double(shortIndex) + 0.35 * Double(trendIndex)).rounded()))

        let trendDown = sw.map { price < $0.ma20 && $0.dif < $0.dea } ?? false
        let topName = best.map { "\(QuantEngine.titles[$0.strategy] ?? $0.strategy) \($0.score)（\($0.grade)）" } ?? ""
        var verdict: String, tone: String, buyer: String, holder: String
        if sealed != nil {
            (verdict, tone, buyer, holder) = ("已涨停 · 等开板", "watch", "封板买不进，可排队或等次日开板再看", "持有，封板不动；开板放量再减仓")
        } else if !matches.isEmpty && shortIndex >= 75 {
            if trendIndex >= 55 { (verdict, tone, buyer, holder) = ("买入", "buy", "可分批买入，设好止损", "持有，跌破止损位再走") }
            else { (verdict, tone, buyer, holder) = ("短线买入", "buy", "短线参与、轻仓，快进快出，跌破止损就走", "短线持有，冲高分批止盈") }
        } else if !matches.isEmpty && shortIndex >= 60 {
            (verdict, tone, buyer, holder) = ("逢低关注", "watch", "轻仓或等回踩支撑再买", "持有，冲高分批止盈")
        } else if trendIndex >= 70 {
            (verdict, tone, buyer, holder) = ("逢低关注", "watch", "趋势好但没有短线入场信号，等回踩或新的启动", "持有，跌破 20 日线再减")
        } else if trendIndex >= 45 {
            (verdict, tone, buyer, holder) = ("观望", "neutral", "暂不买入", trendDown ? "减仓，等待重新站上 20 日线" : "持有观察，跌破支撑减仓")
        } else if trendIndex >= 30 {
            (verdict, tone, buyer, holder) = ("减仓", "reduce", "不买入", "逢反弹减仓")
        } else {
            (verdict, tone, buyer, holder) = ("卖出 / 回避", "sell", "回避", "卖出，趋势转弱")
        }
        let horizon: String
        if !matches.isEmpty && shortIndex >= 75 && trendIndex < 55 {
            horizon = "短线信号强（\(topName)），但趋势面偏弱（趋势指数 \(trendIndex)）：适合 1–3 天短线，不宜长拿。"
        } else if !matches.isEmpty && shortIndex >= 60 && trendIndex >= 55 {
            horizon = "短线（\(topName)）与趋势（\(trendIndex)）同向，信号较一致。"
        } else if matches.isEmpty && trendIndex >= 70 {
            horizon = "趋势良好，但今天没有进入任何短线策略：适合等回踩或新的启动信号。"
        } else if matches.isEmpty {
            horizon = "没有进入任何短线策略，以趋势面为主判断。"
        } else {
            horizon = "短线评分 \(shortIndex)（\(topName)），趋势指数 \(trendIndex)。"
        }

        var levels: [AnalysisLevel] = []
        if let s = sw {
            let supports = ([("MA5", s.ma5), ("MA10", s.ma10), ("MA20", s.ma20), ("MA60", s.ma60), ("20 日低点", s.low20)]).filter { $0.1 < price }.sorted { $0.1 > $1.1 }
            let resistances = [("20 日高点", s.high20), ("60 日高点", s.high60)].filter { $0.1 > price }.sorted { $0.1 < $1.1 }
            if let support = supports.first { levels.append(AnalysisLevel(label: "支撑", price: support.1, note: support.0)) }
            if let resistance = resistances.first { levels.append(AnalysisLevel(label: "压力", price: resistance.1, note: resistance.0)) }
            let stop = max(min((supports.first?.1 ?? price * 0.95) * 0.98, price * 0.97), price * 0.92)
            levels.append(AnalysisLevel(label: "止损参考", price: stop, note: String(format: "距现价 %.1f%%", (stop / price - 1) * 100)))
            if let resistance = resistances.first {
                levels.append(AnalysisLevel(label: "目标参考", price: resistance.1, note: String(format: "距现价 %+.1f%%", (resistance.1 / price - 1) * 100)))
            }
        }
        var probabilities: [AnalysisProbability] = []
        if let s = sw {
            probabilities.append(AnalysisProbability(label: "5 日内涨超 5%", value: s.pBig, baseline: baseBig, note: "回测 AUC 0.60"))
            probabilities.append(AnalysisProbability(label: "5 日内跌超 5%", value: s.pDrop, baseline: baseDrop, note: "回测 AUC 0.69"))
        }
        if let snap {
            probabilities.append(AnalysisProbability(label: "次日盘中冲高 ≥3%", value: snap.p3 * 100, baseline: 25, note: "尾盘隔夜模型"))
            probabilities.append(AnalysisProbability(label: "次日盘中冲高 ≥5%", value: snap.p5 * 100, baseline: 12, note: "尾盘隔夜模型"))
        }
        for c in components where c.max > 0 && c.score >= c.max * 0.7 { signals.append("\(c.name)：\(c.detail)") }
        if let main = extras.mainNet {
            let ratioText = extras.mainRatio.map { String(format: "（占成交额 %+.1f%%）", $0) } ?? ""
            if main > 0 { signals.append("主力今日净流入 \(Fmt.yuan(main))\(ratioText)") }
            else if main < 0 { risks.append("主力今日净流出 \(Fmt.yuan(-main))\(ratioText)" + ((extras.retailNet ?? 0) > 0 ? "，散户在接盘" : "")) }
        }
        if extras.days.count >= 5 {
            let recent = extras.days.suffix(5).map(\.main).reduce(0, +)
            if recent > 0 { signals.append("近 5 日主力累计净流入 \(Fmt.yuan(recent))") } else { risks.append("近 5 日主力累计净流出 \(Fmt.yuan(-recent))") }
        }
        var seen = Set<String>()
        risks = risks.filter { seen.insert($0).inserted }

        return StockAnalysisResult(code: q.code, name: q.name, industry: q.industry, price: price, change: change, index: max(0, min(index, 100)),
                                   shortIndex: shortIndex, trendIndex: trendIndex, shortBasis: shortBasis, horizon: horizon,
                                   verdict: verdict, tone: tone, buyer: buyer, holder: holder, components: components,
                                   probabilities: probabilities, levels: levels, signals: signals, risks: risks, strategies: matches,
                                   news: Array(news.prefix(5)), extras: extras, daily: Array(history.suffix(120)), time: now)
    }
}
