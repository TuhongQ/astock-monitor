import Foundation

/// Thin client for the bundled companion service. All remote rate limiting is performed there.
actor MarketService {
    static let shared = MarketService()
    private var baseURL: String { UserDefaults.standard.string(forKey: "serviceURL") ?? "http://127.0.0.1:8767" }
    private var etags: [String: String] = [:]
    private var intradayHistoryCache: [String: (Date, [PricePoint])] = [:]
    private var fiveDayTrendCache: [String: (Date, [PricePoint])] = [:]
    private var candleHistoryCache: [String: (Date, [CandlePoint])] = [:]
    private var indexHistoryCache: [String: (Date, [PricePoint])] = [:]
    func fetchIndexQuotes() async throws -> [MarketIndex] {
        guard let url = URL(string: baseURL + "/index-quotes") else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.timeoutInterval = 12
        let started = ProcessInfo.processInfo.systemUptime
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            DebugLog.write("指数快照 HTTP 失败 status=\((response as? HTTPURLResponse)?.statusCode ?? -1), elapsed=\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - started))s")
            throw URLError(.badServerResponse)
        }
        let quotes = try JSONDecoder().decode([MarketIndex].self, from: data)
        DebugLog.write("指数快照读取完成 status=\(http.statusCode), received=\(quotes.count), elapsed=\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - started))s")
        return quotes
    }
    func fetchIndexHistory(symbol: String) async throws -> [PricePoint] {
        if let cached = indexHistoryCache[symbol], Date().timeIntervalSince(cached.0) < 60 {
            DebugLog.write("指数分钟历史缓存命中 symbol=\(symbol), records=\(cached.1.count)")
            return cached.1
        }
        guard var components = URLComponents(string: baseURL + "/index-history") else { throw URLError(.badURL) }
        components.queryItems = [URLQueryItem(name: "symbol", value: symbol)]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 90
        let started = ProcessInfo.processInfo.systemUptime
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(ServiceError.self, from: data).error) ?? "HTTP \(http.statusCode)"
            DebugLog.write("指数分钟历史请求失败 symbol=\(symbol), status=\(http.statusCode), error=\(message)")
            throw NSError(domain: "AStockMonitor.IndexHistory", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        struct Row: Decodable { let time: String; let price: Double }
        let rows = try JSONDecoder().decode([Row].self, from: data)
        let formatter = ISO8601DateFormatter()
        let points = rows.compactMap { row -> PricePoint? in
            guard row.price > 0, let date = formatter.date(from: row.time) else { return nil }
            return PricePoint(date: date, price: row.price)
        }
        indexHistoryCache[symbol] = (Date(), points)
        let first = points.first?.date.ISO8601Format() ?? "none"
        let last = points.last?.date.ISO8601Format() ?? "none"
        DebugLog.write("指数分钟历史请求完成 symbol=\(symbol), records=\(points.count), range=\(first)~\(last), elapsed=\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - started))s")
        return points
    }
    func fetch(codes: [String], provider: String = "auto", industryCodes: [String] = [], baseURL override: String? = nil) async throws -> [Quote] {
        let root = (override ?? baseURL).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components = URLComponents(string: root + "/quotes")
        components?.queryItems = [URLQueryItem(name: "codes", value: codes.joined(separator: ",")), URLQueryItem(name: "provider", value: provider), URLQueryItem(name: "industry_codes", value: industryCodes.joined(separator: ","))]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.timeoutInterval = 150
        let cacheKey = root + "|" + provider + "|" + codes.sorted().joined(separator: ",")
        if let etag = etags[cacheKey] { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let requestStarted = ProcessInfo.processInfo.systemUptime
        let (data, response) = try await URLSession.shared.data(for: request)
        let elapsed = ProcessInfo.processInfo.systemUptime - requestStarted
        let http = response as? HTTPURLResponse
        DebugLog.write("行情 HTTP 完成 provider=\(provider), endpoint=\(root)/quotes, status=\(http?.statusCode ?? -1), elapsed=\(String(format: "%.3f", elapsed))s, bytes=\(data.count), requested=\(codes.contains("*") ? "全市场" : String(codes.count)), serverFetch=\(http?.value(forHTTPHeaderField: "X-Upstream-Fetch") ?? "n/a")s, cache=\(http?.value(forHTTPHeaderField: "X-Snapshot-Cache") ?? "n/a")")
        if let http, http.statusCode == 304 {
            DebugLog.write("行情未变化 provider=\(provider)，使用本地快照")
            return []
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(ServiceError.self, from: data).error) ?? "HTTP \(http.statusCode)"
            DebugLog.write("行情请求失败 provider=\(provider), status=\(http.statusCode), error=\(message)")
            throw NSError(domain: "AStockMonitor.AkShare", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        if let http = response as? HTTPURLResponse, let etag = http.value(forHTTPHeaderField: "ETag") { etags[cacheKey] = etag }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let quotes = try decoder.decode([Quote].self, from: data)
        DebugLog.write("行情请求成功 provider=\(provider), requested=\(codes.contains("*") ? "全市场" : String(codes.count)), received=\(quotes.count)")
        return quotes
    }
    func fetchHistory(code: String) async throws -> [PricePoint] {
        if let cached = intradayHistoryCache[code], Date().timeIntervalSince(cached.0) < 20 { return cached.1 }
        guard let url = URL(string: baseURL + "/history?code=" + code) else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(ServiceError.self, from: data).error) ?? "HTTP \(http.statusCode)"
            DebugLog.write("分时请求失败 code=\(code), status=\(http.statusCode), error=\(message)")
            throw NSError(domain: "AStockMonitor.AkShare", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        struct Row: Decodable { let time: String; let price: Double }
        let rows = try JSONDecoder().decode([Row].self, from: data)
        let formatter = ISO8601DateFormatter()
        let points = rows.compactMap { row in formatter.date(from: row.time).map { PricePoint(date: $0, price: row.price) } }
        intradayHistoryCache[code] = (Date(), points)
        DebugLog.write("分时请求完成 code=\(code), records=\(points.count)")
        return points
    }
    func fetchFiveDayTrend(code: String) async throws -> [PricePoint] {
        if let cached = fiveDayTrendCache[code], Date().timeIntervalSince(cached.0) < 60 { return cached.1 }
        guard var components = URLComponents(string: baseURL + "/five-day-trend") else { throw URLError(.badURL) }
        components.queryItems = [URLQueryItem(name: "code", value: code)]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.timeoutInterval = 90
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(ServiceError.self, from: data).error) ?? "HTTP \(http.statusCode)"
            DebugLog.write("5日分钟走势请求失败 code=\(code), status=\(http.statusCode), error=\(message)")
            throw NSError(domain: "AStockMonitor.AkShare", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        struct Row: Decodable { let time: String; let price: Double }
        let rows = try JSONDecoder().decode([Row].self, from: data)
        let formatter = ISO8601DateFormatter()
        let points = rows.compactMap { row in formatter.date(from: row.time).map { PricePoint(date: $0, price: row.price) } }
        fiveDayTrendCache[code] = (Date(), points)
        DebugLog.write("5日分钟走势请求完成 code=\(code), records=\(points.count)")
        return points
    }
    func fetchCandles(code: String, range: String) async throws -> [CandlePoint] {
        let cacheKey = "\(code)|\(range)"
        if let cached = candleHistoryCache[cacheKey], Date().timeIntervalSince(cached.0) < 3600 {
            DebugLog.write("日K客户端缓存命中 code=\(code), range=\(range), records=\(cached.1.count)")
            return cached.1
        }
        guard var components = URLComponents(string: baseURL + "/daily-history") else { throw URLError(.badURL) }
        components.queryItems = [URLQueryItem(name: "code", value: code), URLQueryItem(name: "range", value: range)]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.timeoutInterval = 90
        let started = ProcessInfo.processInfo.systemUptime
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(ServiceError.self, from: data).error) ?? "HTTP \(http.statusCode)"
            DebugLog.write("日K请求失败 code=\(code), range=\(range), status=\((response as? HTTPURLResponse)?.statusCode ?? 0), error=\(message)")
            throw NSError(domain: "AStockMonitor.AkShare", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        struct Row: Decodable { let date: String; let open: Double; let high: Double; let low: Double; let close: Double }
        let rows = try JSONDecoder().decode([Row].self, from: data)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let candles = rows.compactMap { row in formatter.date(from: row.date).map { CandlePoint(date: $0, open: row.open, high: row.high, low: row.low, close: row.close) } }
        candleHistoryCache[cacheKey] = (Date(), candles)
        DebugLog.write("日K请求完成 code=\(code), range=\(range), records=\(candles.count), elapsed=\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - started))s")
        return candles
    }
    /// Returns the latest screener result immediately; the bridge rescans in
    /// the background (every 5 min in session, 30 min otherwise).
    func fetchPotential(provider: String, force: Bool = false) async throws -> PotentialReport {
        guard var components = URLComponents(string: baseURL + "/potential") else { throw URLError(.badURL) }
        components.queryItems = [URLQueryItem(name: "provider", value: provider), URLQueryItem(name: "force", value: force ? "1" : "0")]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(ServiceError.self, from: data).error) ?? "HTTP \(http.statusCode)"
            DebugLog.write("潜力股请求失败 status=\(http.statusCode), error=\(message)")
            throw NSError(domain: "AStockMonitor.Potential", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let report = try JSONDecoder().decode(PotentialReport.self, from: data)
        DebugLog.write("潜力股结果 scanning=\(report.scanning), progress=\(report.progress)/\(report.total), stocks=\(report.stocks.count), updatedAt=\(report.updatedAt ?? "nil")")
        return report
    }
    func fetchInsight(code: String, provider: String) async throws -> StockInsight {
        try await getJSON(path: "/stock-insight", query: ["code": code, "provider": provider], timeout: 60)
    }
    func fetchAnalysis(query: String, provider: String) async throws -> StockAnalysis {
        try await getJSON(path: "/analyze", query: ["q": query, "provider": provider], timeout: 90)
    }
    /// Open / high / low / price from Eastmoney for next-day tracking of 隔夜 picks.
    func fetchOHLC(codes: [String]) async throws -> [String: DayOHLC] {
        try await getJSON(path: "/ohlc", query: ["codes": codes.joined(separator: ",")], timeout: 20)
    }
    func fetchNews(code: String) async throws -> [StockNewsItem] {
        try await getJSON(path: "/news", query: ["code": code], timeout: 30)
    }
    private func getJSON<T: Decodable>(path: String, query: [String: String], timeout: TimeInterval) async throws -> T {
        guard var components = URLComponents(string: baseURL + path) else { throw URLError(.badURL) }
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (try? JSONDecoder().decode(ServiceError.self, from: data).error) ?? "HTTP \(http.statusCode)"
            DebugLog.write("请求失败 \(path) status=\(http.statusCode), error=\(message)")
            throw NSError(domain: "AStockMonitor.Service", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private struct ServiceError: Decodable { let error: String }
}
