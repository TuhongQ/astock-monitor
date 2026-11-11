import SwiftUI
import Charts

struct StockDetailView: View {
    @EnvironmentObject var store: PadStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    let code: String
    @State private var range = "intraday"
    @State private var points: [PricePoint] = []
    @State private var preClose: Double?
    @State private var candles: [Candle] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var panel = "all"
    @State private var insight: [(String, [(String, String, Int)])] = []
    @State private var news: [NewsItem] = []
    @State private var newsError: String?

    private var quote: Quote? { store.quote(code) }

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > 900 {
                HStack(spacing: 0) {
                    chartPane.frame(maxWidth: .infinity)
                    Divider()
                    insightPane.frame(width: min(420, geo.size.width * 0.4))
                }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        chartPane.frame(height: 460)
                        Divider()
                        insightContent.padding(14)
                    }
                }
            }
        }
        .navigationTitle(quote.map { "\($0.name) \(code)" } ?? code)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { store.toggleWatch(code) } label: {
                    Image(systemName: store.watch.codes.contains(code) ? "star.fill" : "star")
                }
            }
        }
        .task(id: range) { await loadChart() }
        .task(id: code) { await loadNews() }
        .task(id: code) {
            while !Task.isCancelled {
                insight = await store.insight(for: code)
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    // MARK: Chart

    private var chartPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(quote?.name ?? code).font(.title2.bold())
                        if let record = store.pickHistory(code).first {
                            Text("推荐 \(String(record.day.suffix(5)))").font(.caption.bold()).foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.orange))
                        }
                    }
                    Text("\(code) · \(quote?.industry ?? "") · \(quote?.board ?? "")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let q = quote {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "¥%.2f", q.price)).font(.title2.bold()).monospacedDigit()
                        Text(Fmt.pct(q.changePercent)).foregroundStyle(q.changePercent >= 0 ? Color.red : Color.green)
                    }
                }
            }
            Picker("周期", selection: $range) {
                Text("分时").tag("intraday"); Text("5日").tag("5d"); Text("一月").tag("1m")
                Text("3月").tag("3m"); Text("一年").tag("year")
            }
            .pickerStyle(.segmented).frame(maxWidth: 420)
            ZStack {
                if range == "intraday" || range == "5d" { lineChart } else { candleChart }
                if loading { ProgressView() }
                if let errorText, !loading { Text(errorText).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(maxHeight: .infinity)
            if let q = quote {
                HStack {
                    Text("量比 \(q.volumeRatio.map { String(format: "%.2f", $0) } ?? "—")")
                    Spacer(); Text("换手 \(q.turnover.map { String(format: "%.2f%%", $0) } ?? "—")")
                    Spacer(); Text("成交额 \(Fmt.yuan(q.amount))")
                    Spacer(); Text("流通 \(Fmt.yuan(q.floatMarketCap))")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    private var lineChart: some View {
        let rising = (points.last?.price ?? 0) >= (preClose ?? points.first?.price ?? 0)
        let color = rising ? Color.red : Color.green
        let prices = points.map(\.price) + (preClose.map { [$0] } ?? [])
        let low = prices.min() ?? 0, high = prices.max() ?? 1
        let pad = max((high - low) * 0.08, high * 0.002)
        return Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                LineMark(x: .value("序号", index), y: .value("价格", point.price))
                    .foregroundStyle(color).interpolationMethod(.linear)
            }
            if let preClose, range == "intraday" {
                RuleMark(y: .value("昨收", preClose)).foregroundStyle(.secondary).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .chartYScale(domain: (low - pad)...(high + pad))
        .chartXScale(domain: 0...max(range == "intraday" ? 240 : points.count - 1, 1))
        .chartXAxis {
            AxisMarks(values: axisIndices) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let index = value.as(Int.self), points.indices.contains(index) {
                        Text(axisLabel(points[index].time))
                    }
                }
            }
        }
    }

    private var axisIndices: [Int] {
        guard !points.isEmpty else { return [] }
        if range == "intraday" { return [0, 60, 120, 180, 240].filter { $0 < points.count } }
        var result: [Int] = [0]
        for i in 1..<points.count where Market.dayKey(points[i].time) != Market.dayKey(points[i - 1].time) { result.append(i) }
        return result
    }

    private func axisLabel(_ date: Date) -> String {
        let parts = Market.calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        return range == "intraday" ? String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0) : String(format: "%02d-%02d", parts.month ?? 0, parts.day ?? 0)
    }

    private var candleChart: some View {
        let low = candles.map(\.low).min() ?? 0, high = candles.map(\.high).max() ?? 1
        let pad = (high - low) * 0.05
        return Chart {
            ForEach(Array(candles.enumerated()), id: \.offset) { index, c in
                let color = c.close >= c.open ? Color.red : Color.green
                RuleMark(x: .value("日", index), yStart: .value("低", c.low), yEnd: .value("高", c.high)).foregroundStyle(color)
                BarMark(x: .value("日", index), yStart: .value("开", min(c.open, c.close)), yEnd: .value("收", max(c.open, c.close) + 0.0001), width: .ratio(0.7))
                    .foregroundStyle(color)
            }
        }
        .chartYScale(domain: (low - pad)...(high + pad))
        .chartXAxis {
            AxisMarks(values: candleAxis) { value in
                AxisGridLine()
                AxisValueLabel { if let i = value.as(Int.self), candles.indices.contains(i) { Text(String(candles[i].date.dropFirst(5))) } }
            }
        }
    }

    private var candleAxis: [Int] {
        guard candles.count > 1 else { return [0] }
        return (0..<5).map { Int((Double(candles.count - 1) * Double($0) / 4).rounded()) }
    }

    private func loadChart() async {
        loading = true; errorText = nil
        defer { loading = false }
        do {
            switch range {
            case "intraday", "5d":
                let result = try await EastmoneyClient.shared.fetchTrends(secid: Market.secid(code), days: range == "5d" ? 5 : 1)
                points = result.points; preClose = result.preClose
                if points.isEmpty { errorText = "暂无分时数据" }
            default:
                let all = try await EastmoneyClient.shared.fetchDaily(code: code)
                let count = range == "1m" ? 22 : (range == "3m" ? 66 : 250)
                candles = Array(all.suffix(count))
                if candles.isEmpty { errorText = "暂无日 K 数据" }
            }
        } catch {
            errorText = "加载失败：\(error.localizedDescription)"
        }
    }

    private func loadNews() async {
        do { news = try await EastmoneyClient.shared.fetchNews(code: code); newsError = nil }
        catch { newsError = error.localizedDescription }
    }

    // MARK: Insight panel

    private var insightPane: some View {
        VStack(spacing: 0) {
            Picker("内容", selection: $panel) {
                Text("全部").tag("all"); Text("推荐").tag("pick"); Text("量化").tag("quant"); Text("资讯").tag("news")
            }
            .pickerStyle(.segmented).padding(10)
            Divider()
            ScrollView { insightContent.padding(12) }
        }
        .background(Color.primary.opacity(0.025))
    }

    @ViewBuilder private var insightContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if panel == "all" || panel == "pick" { recommendation }
            if panel == "all" || panel == "quant" { quant }
            if panel == "all" || panel == "news" { newsList }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var matches: [StockPick] {
        QuantEngine.strategies.filter { $0.id != "all" }.compactMap { meta in store.lists[meta.id]?.first { $0.code == code } }
    }

    @ViewBuilder private var recommendation: some View {
        Label("推荐说明", systemImage: "star.circle.fill").font(.headline).foregroundStyle(.orange)
        let history = store.pickHistory(code)
        if history.isEmpty && matches.isEmpty {
            Text("该股不在推荐池，当前也未入选任何选股策略。").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(Array(history.enumerated()), id: \.offset) { index, record in pickCard(record.day, record.pick, latest: index == 0) }
        if !matches.isEmpty {
            Text(history.isEmpty ? "当前入选策略" : "最新量化评估").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(matches) { match in matchCard(match) }
        }
    }

    private func pickCard(_ day: String, _ pick: DailyPick, latest: Bool) -> some View {
        let since = quote.map { pick.price > 0 ? ($0.price / pick.price - 1) * 100 : 0 }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                grade(pick.grade)
                Text("\(day) \(pick.time.formatted(date: .omitted, time: .shortened)) 推荐").font(.subheadline.bold())
                Text(WatchData.pickBoard(code: pick.code)).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                metric("推荐价", Fmt.price(pick.price))
                metric("现价", Fmt.price(quote?.price))
                metric("推荐以来", Fmt.pct(since), tone: since)
                metric("评分", "\(pick.initialScore) → \(pick.score)")
            }
            chips(Array(Set(pick.strategies.compactMap { QuantEngine.titles[$0] } + pick.tags)).sorted())
            if !pick.highlights.isEmpty { Text(pick.highlights.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
            bullets(pick.signals, icon: "checkmark.circle", color: .primary)
            bullets(pick.risks, icon: "exclamationmark.triangle", color: .orange)
            HStack(spacing: 16) {
                if let pivot = pick.pivot { metric("观察位", Fmt.price(pivot)) }
                if let stop = pick.stopLoss { metric("止损参考", Fmt.price(stop) + (pick.riskPercent.map { String(format: "（-%.1f%%）", $0) } ?? ""), tone: -1) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(latest ? 0.09 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(latest ? 0.35 : 0.15)))
    }

    private func matchCard(_ p: StockPick) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                grade(p.grade)
                Text(QuantEngine.titles[p.strategy] ?? p.strategy).font(.subheadline.bold())
                Text("\(p.score) 分").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let pivot = p.pivot { Text("观察 \(Fmt.price(pivot))").font(.caption2) }
                if let stop = p.stopLoss { Text("止损 \(Fmt.price(stop))").font(.caption2).foregroundStyle(.green) }
            }
            if !p.highlights.isEmpty { Text(p.highlights.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
            bullets(p.signals, icon: "checkmark.circle", color: .primary)
            bullets(p.risks, icon: "exclamationmark.triangle", color: .orange)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }

    @ViewBuilder private var quant: some View {
        Label("量化数据", systemImage: "function").font(.headline).foregroundStyle(.blue)
        if insight.isEmpty {
            HStack(spacing: 6) { ProgressView(); Text("正在计算量化数据…").font(.caption).foregroundStyle(.secondary) }
        }
        ForEach(insight, id: \.0) { title, items in
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack {
                        Text(item.0).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(item.1).font(.system(size: 13, weight: .medium)).monospacedDigit()
                            .foregroundStyle(item.2 > 0 ? Color.red : (item.2 < 0 ? Color.green : Color.primary))
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
        }
    }

    @ViewBuilder private var newsList: some View {
        HStack {
            Label("最新资讯", systemImage: "newspaper.fill").font(.headline).foregroundStyle(.purple)
            Spacer()
            Button { Task { await loadNews() } } label: { Image(systemName: "arrow.clockwise") }
        }
        if news.isEmpty {
            Text(newsError.map { "资讯暂不可用：\($0)" } ?? "正在获取东方财富个股资讯…").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(news) { item in
            Link(destination: URL(string: item.url) ?? URL(string: "https://www.eastmoney.com")!) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.subheadline.weight(.medium)).foregroundStyle(.primary).multilineTextAlignment(.leading)
                    if !item.content.isEmpty { Text(item.content).font(.caption).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading) }
                    Text("\(item.time) · \(item.source)").font(.caption2).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
            }
        }
    }

    private func grade(_ value: String) -> some View {
        Text(value).font(.caption.bold()).foregroundStyle(.white).frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(value == "A" ? Color.red : (value == "B" ? .orange : .gray)))
    }
    private func metric(_ title: String, _ value: String, tone: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                .foregroundStyle(tone.map { $0 > 0 ? Color.red : ($0 < 0 ? Color.green : Color.primary) } ?? Color.primary)
        }
    }
    private func chips(_ values: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(values, id: \.self) { Text($0).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.accentColor.opacity(0.12))) }
            }
        }
    }
    @ViewBuilder private func bullets(_ items: [String], icon: String, color: Color) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, text in
            Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: icon) }
                .font(.caption).foregroundStyle(color)
        }
    }
}
