import Foundation

/// Direct HTTP access to the public Eastmoney endpoints that AkShare wraps on
/// the Mac. Everything runs on the iPad; no local bridge is required.
actor EastmoneyClient {
    static let shared = EastmoneyClient()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.httpMaximumConnectionsPerHost = 8
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
    private let userAgent = "Mozilla/5.0 (iPad; CPU OS 16_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.4 Mobile/15E148 Safari/604.1"
    private var klineCache: [String: (Date, [Candle])] = [:]
    private var newsCache: [String: (Date, [NewsItem])] = [:]

    enum ClientError: LocalizedError {
        case badResponse(String)
        var errorDescription: String? { if case .badResponse(let text) = self { return text }; return nil }
    }

    private func json(_ urlString: String, referer: String? = nil) async throws -> Any {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.badResponse("HTTP \(http.statusCode)")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { let v = number.doubleValue; return v.isFinite ? v : nil }
        if let text = value as? String, let v = Double(text), v.isFinite { return v }
        return nil
    }

    // MARK: Full market

    private static let marketFields = "f2,f3,f5,f6,f8,f10,f12,f14,f15,f16,f17,f18,f20,f21,f100"
    private static let marketFilter = "m:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23,m:0+t:81+s:2048"

    private func marketPage(_ page: Int) async throws -> (total: Int, rows: [[String: Any]]) {
        let url = "https://push2.eastmoney.com/api/qt/clist/get?pn=\(page)&pz=100&po=1&np=1&fltt=2&invt=2&fid=f12&fs=\(Self.marketFilter)&fields=\(Self.marketFields)"
        let object = try await json(url)
        guard let root = object as? [String: Any], let data = root["data"] as? [String: Any],
              let diff = data["diff"] as? [[String: Any]] else { throw ClientError.badResponse("行情列表为空") }
        return ((data["total"] as? Int) ?? diff.count, diff)
    }

    /// The whole A-share market (~5,900 rows) in parallel pages of 100.
    func fetchMarket() async throws -> [Quote] {
        let first = try await marketPage(1)
        let pages = Int((Double(first.total) / 100).rounded(.up))
        var quotes = first.rows.compactMap(Self.quote(from:))
        if pages > 1 {
            try await withThrowingTaskGroup(of: [Quote].self) { group in
                var next = 2
                let parallel = 8
                for _ in 0..<min(parallel, pages - 1) {
                    let page = next; next += 1
                    group.addTask { try await self.marketPageWithRetry(page) }
                }
                while let result = try await group.next() {
                    quotes += result
                    if next <= pages {
                        let page = next; next += 1
                        group.addTask { try await self.marketPageWithRetry(page) }
                    }
                }
            }
        }
        return quotes
    }

    private func marketPageWithRetry(_ page: Int) async throws -> [Quote] {
        do { return try await marketPage(page).rows.compactMap(Self.quote(from:)) }
        catch {
            try await Task.sleep(nanoseconds: 400_000_000)
            return try await marketPage(page).rows.compactMap(Self.quote(from:))
        }
    }

    private static func quote(from row: [String: Any]) -> Quote? {
        guard let code = row["f12"] as? String, let name = row["f14"] as? String else { return nil }
        let price = number(row["f2"]) ?? 0
        let change = number(row["f3"]) ?? 0
        let prevClose = number(row["f18"])
        var limitUp: Double?, limitDown: Double?
        if let ratio = Market.limitRatio(code: code, name: name), let base = prevClose, base > 0 {
            limitUp = Market.roundPrice(base * (1 + ratio))
            limitDown = Market.roundPrice(base * (1 - ratio))
        }
        let upper = price > 0 && limitUp.map { price >= $0 - 0.005 } == true
        let lower = price > 0 && limitDown.map { price <= $0 + 0.005 } == true
        return Quote(code: code, name: name, price: price, changePercent: change,
                     amount: number(row["f6"]) ?? 0, volume: number(row["f5"]) ?? 0,
                     turnover: number(row["f8"]), volumeRatio: number(row["f10"]),
                     high: number(row["f15"]), low: number(row["f16"]), open: number(row["f17"]),
                     prevClose: prevClose, totalMarketCap: number(row["f20"]), floatMarketCap: number(row["f21"]),
                     industry: (row["f100"] as? String).flatMap { $0 == "-" ? nil : $0 } ?? "",
                     limitUpPrice: limitUp, limitDownPrice: limitDown, upperLimit: upper, lowerLimit: lower,
                     suspended: price <= 0)
    }

    // MARK: Indexes

    func fetchIndexes() async throws -> [IndexQuote] {
        let secids = ["1.000001", "0.399001", "0.399006", "1.000680"]
        let url = "https://push2.eastmoney.com/api/qt/ulist.np/get?fltt=2&secids=\(secids.joined(separator: ","))&fields=f2,f3,f12,f13,f14"
        let object = try await json(url)
        guard let root = object as? [String: Any], let data = root["data"] as? [String: Any],
              let diff = data["diff"] as? [[String: Any]] else { return [] }
        return diff.compactMap { row in
            guard let code = row["f12"] as? String, let price = Self.number(row["f2"]) else { return nil }
            let market = (row["f13"] as? Int) ?? 1
            return IndexQuote(code: code, name: row["f14"] as? String ?? code, price: price,
                              changePercent: Self.number(row["f3"]) ?? 0, secid: "\(market).\(code)")
        }
    }

    // MARK: Limit-up pools

    private func pool(_ endpoint: String, date: String, sort: String) async throws -> [[String: Any]] {
        let url = "https://push2ex.eastmoney.com/\(endpoint)?ut=7eea3edcaed734bea9cbfc24409ed989&dpt=wz.ztzt&Pageindex=0&pagesize=10000&sort=\(sort)&date=\(date)"
        let object = try await json(url)
        guard let root = object as? [String: Any], let data = root["data"] as? [String: Any] else { return [] }
        return data["pool"] as? [[String: Any]] ?? []
    }

    private static func hms(_ value: Any?) -> String? {
        guard let number = number(value) else { return nil }
        let text = String(format: "%06d", Int(number))
        return "\(text.prefix(2)):\(text.dropFirst(2).prefix(2)):\(text.suffix(2))"
    }

    private static func poolItem(_ row: [String: Any], previous: Bool = false) -> LimitPoolItem? {
        guard let code = row["c"] as? String else { return nil }
        let stats = row["zttj"] as? [String: Any]
        return LimitPoolItem(
            code: code, name: row["n"] as? String ?? code,
            changePercent: number(row["zdp"]), price: number(row["p"]).map { $0 / 1000 },
            floatMarketCap: number(row["ltsz"]), turnover: number(row["hs"]),
            industry: row["hybk"] as? String ?? "", sealAmount: number(row["fund"]),
            firstTime: hms(previous ? row["yfbt"] : row["fbt"]), openCount: Int(number(row["zbc"]) ?? 0),
            streak: Int(number(previous ? row["ylbc"] : row["lbc"]) ?? 1),
            stat: stats.map { "\(Int(number($0["days"]) ?? 0))/\(Int(number($0["ct"]) ?? 0))" },
            limitUpPrice: number(row["ztp"]).map { $0 / 1000 })
    }

    /// Latest trading day's sealed, broken and previous-day limit-up pools.
    func fetchLimitPools() async throws -> LimitPools {
        for date in Market.tradingDates(count: 6) {
            let rows = try await pool("getTopicZTPool", date: date, sort: "fbt:asc")
            guard !rows.isEmpty else { continue }
            var result = LimitPools(date: date)
            for row in rows { if let item = Self.poolItem(row) { result.pool[item.code] = item } }
            if let broken = try? await pool("getTopicZBPool", date: date, sort: "fbt:asc") {
                for row in broken { if let item = Self.poolItem(row) { result.broken[item.code] = item } }
            }
            if let previous = try? await pool("getYesterdayZTPool", date: date, sort: "zs:desc") {
                for row in previous { if let item = Self.poolItem(row, previous: true) { result.previous[item.code] = item } }
            }
            return result
        }
        throw ClientError.badResponse("涨停池暂无数据")
    }

    /// Codes that sealed the limit on one past date (strong-stock pool).
    func fetchLimitUpCodes(date: String) async throws -> [String] {
        try await pool("getTopicZTPool", date: date, sort: "fbt:asc").compactMap { $0["c"] as? String }
    }

    // MARK: Bars

    /// About one year of forward-adjusted daily bars, cached for six hours.
    func fetchDaily(code: String, limit: Int = 260) async throws -> [Candle] {
        if let cached = klineCache[code], Date().timeIntervalSince(cached.0) < 6 * 3600 { return cached.1 }
        let url = "https://push2his.eastmoney.com/api/qt/stock/kline/get?secid=\(Market.secid(code))&fields1=f1,f2,f3&fields2=f51,f52,f53,f54,f55,f56,f57&klt=101&fqt=1&end=20500101&lmt=\(limit)"
        let object = try await json(url)
        guard let root = object as? [String: Any], let data = root["data"] as? [String: Any],
              let lines = data["klines"] as? [String] else { return [] }
        let candles: [Candle] = lines.compactMap { line in
            let parts = line.split(separator: ",").map(String.init)
            guard parts.count >= 7, let open = Double(parts[1]), let close = Double(parts[2]),
                  let high = Double(parts[3]), let low = Double(parts[4]), close > 0 else { return nil }
            return Candle(date: parts[0], open: open, close: close, high: high, low: low, amount: Double(parts[6]) ?? 0)
        }
        klineCache[code] = (Date(), candles)
        return candles
    }

    func cachedDaily(code: String) -> [Candle]? {
        guard let cached = klineCache[code], Date().timeIntervalSince(cached.0) < 6 * 3600 else { return nil }
        return cached.1
    }

    func restoreDaily(_ entries: [String: [Candle]], at date: Date) {
        for (code, candles) in entries where klineCache[code] == nil { klineCache[code] = (date, candles) }
    }

    func dailySnapshot() -> [String: [Candle]] {
        klineCache.filter { Date().timeIntervalSince($0.value.0) < 6 * 3600 }.mapValues { Array($0.1.suffix(260)) }
    }

    /// Minute prices for today (days = 1) or the last five sessions (days = 5).
    func fetchTrends(secid: String, days: Int) async throws -> (points: [PricePoint], preClose: Double?) {
        let url = "https://push2his.eastmoney.com/api/qt/stock/trends2/get?secid=\(secid)&fields1=f1,f2,f8&fields2=f51,f53&ndays=\(days)&iscr=0"
        let object = try await json(url)
        guard let root = object as? [String: Any], let data = root["data"] as? [String: Any],
              let trends = data["trends"] as? [String] else { return ([], nil) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let points: [PricePoint] = trends.compactMap { line in
            let parts = line.split(separator: ",").map(String.init)
            guard parts.count >= 2, let time = formatter.date(from: parts[0]), let price = Double(parts[1]), price > 0 else { return nil }
            return PricePoint(time: time, price: price)
        }
        return (points, Self.number(data["preClose"]))
    }

    // MARK: News

    func fetchNews(code: String) async throws -> [NewsItem] {
        if let cached = newsCache[code], Date().timeIntervalSince(cached.0) < 600 { return cached.1 }
        let inner: [String: Any] = [
            "uid": "", "keyword": code, "type": ["cmsArticleWebOld"], "client": "web", "clientType": "web", "clientVersion": "curr",
            "param": ["cmsArticleWebOld": ["searchScope": "default", "sort": "time", "pageIndex": 1, "pageSize": 20, "preTag": "", "postTag": ""]],
        ]
        let paramData = try JSONSerialization.data(withJSONObject: inner)
        var components = URLComponents(string: "https://search-api-web.eastmoney.com/search/jsonp")!
        components.queryItems = [URLQueryItem(name: "cb", value: "cb"), URLQueryItem(name: "param", value: String(data: paramData, encoding: .utf8))]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://so.eastmoney.com/", forHTTPHeaderField: "Referer")
        let (data, _) = try await session.data(for: request)
        guard var text = String(data: data, encoding: .utf8) else { return [] }
        if text.hasPrefix("cb(") { text.removeFirst(3) }
        if text.hasSuffix(")") { text.removeLast() }
        guard let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let rows = result["cmsArticleWebOld"] as? [[String: Any]] else { return [] }
        func clean(_ value: Any?) -> String {
            (value as? String ?? "").replacingOccurrences(of: "<em>", with: "").replacingOccurrences(of: "</em>", with: "")
                .replacingOccurrences(of: "\u{3000}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let items = rows.map { row in
            NewsItem(title: clean(row["title"]), content: String(clean(row["content"]).prefix(220)),
                     time: String((row["date"] as? String ?? "").prefix(16)), source: clean(row["mediaName"]),
                     url: row["url"] as? String ?? "")
        }.filter { !$0.title.isEmpty }.sorted { $0.time > $1.time }
        newsCache[code] = (Date(), items)
        return items
    }
}
