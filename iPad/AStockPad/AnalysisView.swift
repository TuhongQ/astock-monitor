import SwiftUI
import Charts

private func signedYuan(_ value: Double?) -> String {
    guard let value else { return "—" }
    return (value > 0 ? "+" : "") + Fmt.yuan(value)
}
private func toneColor(_ value: Double?) -> Color {
    guard let value else { return .primary }
    return value > 0 ? .red : (value < 0 ? .green : .primary)
}

struct AnalysisView: View {
    @EnvironmentObject var store: PadStore
    let open: (String) -> Void
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if store.analysisLoading && store.analysis == nil {
                        HStack { ProgressView(); Text("正在拉取最新行情、日线、资金流与资讯…").foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity, minHeight: 240)
                    } else if !store.analysisCandidates.isEmpty {
                        candidates
                    } else if let message = store.analysisMessage {
                        Label(message, systemImage: "questionmark.circle").font(.headline).padding(.top, 20)
                    } else if let r = store.analysis {
                        ResultBody(r: r, open: open)
                    } else {
                        emptyState
                    }
                }
                .padding(16)
            }
        }
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("输入股票代码或名称，例如 600519、茅台", text: $input)
                    .textFieldStyle(.plain).font(.body).focused($focused)
                    .submitLabel(.search).onSubmit { store.analyze(input) }
                if store.analysisLoading { ProgressView() }
                Button("分析") { focused = false; store.analyze(input) }.buttonStyle(.borderedProminent)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                if let code = store.analysis?.code {
                    Button { store.analyze(code) } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            if !store.analysisHistory.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.analysisHistory, id: \.self) { entry in
                            Button(String(entry.dropFirst(7))) { input = String(entry.prefix(6)); store.analyze(String(entry.prefix(6))) }
                                .font(.caption).buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .onChange(of: store.analysis?.code) { code in if let code { input = code } }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "stethoscope").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("个股分析").font(.title3.bold())
            Text("输入代码或名称，自动拉取最新行情、日线、资金流、涨停数据和资讯，给出推荐指数、买卖建议、关键价位和回测概率。也可以在潜力股或个股页长按 / 点按「分析」。")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private var candidates: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(store.analysisMessage ?? "请选择", systemImage: "questionmark.circle").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 8)], spacing: 8) {
                ForEach(store.analysisCandidates) { q in
                    Button { input = q.code; store.analyze(q.code) } label: {
                        HStack { Text(q.name); Text(q.code).font(.caption.monospaced()).foregroundStyle(.secondary); Spacer() }
                            .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

private struct ResultBody: View {
    @EnvironmentObject var store: PadStore
    let r: StockAnalysisResult
    let open: (String) -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var color: Color {
        switch r.tone { case "buy": .red; case "watch": .orange; case "reduce": .teal; case "sell": .green; default: .gray }
    }

    var body: some View {
        if sizeClass == .regular {
            HStack(alignment: .top, spacing: 16) { summary.frame(maxWidth: .infinity, alignment: .leading); probabilities.frame(width: 320) }
        } else {
            summary; probabilities
        }
        Label(r.horizon, systemImage: "clock.arrow.2.circlepath").font(.callout)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.1)))
        card { LiveQuotePanel(code: r.code) }
        card { ChartPanel(r: r) }
        if !r.extras.flowRows.isEmpty || !r.extras.days.isEmpty { card { FlowPanel(extras: r.extras) } }
        if !r.extras.stats.isEmpty { card { StatsPanel(extras: r.extras) } }
        if sizeClass == .regular {
            HStack(alignment: .top, spacing: 16) { componentsView.frame(maxWidth: .infinity, alignment: .leading); sideInfo.frame(width: 320, alignment: .leading) }
        } else {
            componentsView; sideInfo
        }
        if !r.news.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("最新资讯").font(.headline)
                ForEach(r.news) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.time).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let url = URL(string: item.url), !item.url.isEmpty { Link(item.title, destination: url).font(.callout).lineLimit(1) }
                        else { Text(item.title).font(.callout).lineLimit(1) }
                    }
                }
            }
        }
        VStack(alignment: .leading, spacing: 3) {
            ForEach(StockAnalysisResult.notes, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(r.name).font(.title2.bold())
                Text(r.code).font(.callout.monospaced()).foregroundStyle(.secondary)
                if !r.industry.isEmpty { Text(r.industry).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("个股页") { open(r.code) }.buttonStyle(.bordered).controlSize(.small)
                Button(store.watch.codes.contains(r.code) ? "已在自选" : "加入自选") { store.toggleWatch(r.code) }
                    .buttonStyle(.bordered).controlSize(.small).disabled(store.watch.codes.contains(r.code))
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Fmt.price(r.price)).font(.system(size: 30, weight: .semibold, design: .rounded))
                Text(Fmt.pct(r.change)).font(.title3.bold())
            }
            .monospacedDigit().foregroundStyle(toneColor(r.change))
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.08), lineWidth: 10)
                    Circle().trim(from: 0, to: CGFloat(r.index) / 100).stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(r.index)").font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("推荐指数").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: 7) {
                    Text(r.verdict).font(.system(size: 26, weight: .heavy)).foregroundStyle(color)
                    advice("未持有", r.buyer, .blue)
                    advice("已持有", r.holder, .purple)
                    HStack(spacing: 6) {
                        subIndex("短线", r.shortIndex)
                        subIndex("趋势", r.trendIndex)
                    }
                    poolBadges
                    Text("分析时间 \(r.time.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !r.levels.isEmpty {
                HStack(spacing: 8) {
                    ForEach(r.levels, id: \.self) { level in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(level.label).font(.caption2).foregroundStyle(.secondary)
                            Text(Fmt.price(level.price)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(level.label == "止损参考" ? Color.green : (level.label == "支撑" ? Color.primary : Color.red))
                            Text(level.note).font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(8).frame(minWidth: 92, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    }
                }
            }
        }
    }

    private func advice(_ key: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Text(key).font(.caption.bold()).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(tint))
            Text(text).font(.callout)
        }
    }

    private func subIndex(_ title: String, _ value: Int) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text("\(value)").font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(value >= 75 ? Color.red : (value >= 60 ? Color.orange : Color.secondary))
        }
        .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    @ViewBuilder private var poolBadges: some View {
        let history = Array(store.pickHistory(r.code).prefix(3))
        if !history.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(history.enumerated()), id: \.offset) { _, record in
                    Text((record.pick.isOvernight ? "隔夜池 " : "推荐池 ") + String(record.day.suffix(5)) + (record.pick.isOvernight ? "" : " 荐\(record.pick.initialScore)"))
                        .font(.caption2.bold()).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(record.pick.isOvernight ? Color.mint : Color.orange))
                }
            }
        }
    }

    private var probabilities: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("回测概率（括号为全市场平均）").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(r.probabilities, id: \.self) { p in
                let bad = p.label.contains("跌")
                let elevated = p.value > p.baseline * 1.3
                let tint: Color = bad ? (elevated ? .green : .gray) : (elevated ? .red : .gray)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(p.label).font(.caption)
                        Spacer()
                        Text(String(format: "%.0f%%", p.value)).font(.callout.bold()).monospacedDigit().foregroundStyle(tint)
                        Text(String(format: "（%.0f%%）", p.baseline)).font(.caption2).foregroundStyle(.secondary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(tint.opacity(0.75)).frame(width: geo.size.width * CGFloat(min(p.value, 100) / 100))
                            Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 2, height: 10).offset(x: geo.size.width * CGFloat(p.baseline / 100) - 1)
                        }
                    }.frame(height: 7)
                    Text(p.note).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private var componentsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(["短线", "趋势"], id: \.self) { group in
                Text(group == "短线" ? "短线评分（与潜力股同一套策略）" : "趋势评分").font(.headline).padding(.top, group == "趋势" ? 6 : 0)
                ForEach(r.components.filter { $0.group == group }, id: \.self) { c in
                    let penalty = c.max <= 0
                    let fraction = penalty ? 0 : max(0, min(c.score / c.max, 1))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(c.name).font(.callout.bold())
                            Spacer()
                            Text(penalty ? String(format: "%.0f", c.score) : String(format: "%.0f / %.0f", c.score, c.max))
                                .font(.callout).monospacedDigit().foregroundStyle(penalty ? Color.green : Color.primary)
                        }
                        if !penalty {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.primary.opacity(0.08))
                                    Capsule().fill(fraction >= 0.7 ? Color.red.opacity(0.7) : (fraction >= 0.4 ? Color.orange.opacity(0.7) : Color.gray.opacity(0.6)))
                                        .frame(width: geo.size.width * CGFloat(fraction))
                                }
                            }.frame(height: 6)
                        }
                        Text(c.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var sideInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !r.risks.isEmpty {
                Text("风险提示").font(.headline)
                ForEach(r.risks, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange) }
            }
            if !r.signals.isEmpty {
                Text("积极信号").font(.headline).padding(.top, 4)
                ForEach(r.signals, id: \.self) { Label($0, systemImage: "checkmark.circle").font(.callout) }
            }
            if !r.strategies.isEmpty {
                Text("入选策略").font(.headline).padding(.top, 4)
                ForEach(r.strategies) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(QuantEngine.titles[s.strategy] ?? s.strategy) · \(s.score) 分（\(s.grade)）").font(.callout.bold())
                        ForEach(s.signals.prefix(3), id: \.self) { Text("· " + $0).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }
}

private struct LiveQuotePanel: View {
    @EnvironmentObject var store: PadStore
    let code: String

    var body: some View {
        if let q = store.quote(code) {
            let prev = q.prevClose ?? q.price / (1 + q.changePercent / 100)
            let speed = store.tracker.metrics(code).speed3
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("行情数据").font(.headline)
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("实时 · \(store.lastUpdate?.formatted(date: .omitted, time: .standard) ?? "—")").font(.caption2).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], alignment: .leading, spacing: 8) {
                    cell("现价", Fmt.price(q.price), q.changePercent)
                    cell("涨跌幅", Fmt.pct(q.changePercent), q.changePercent)
                    cell("涨跌额", String(format: "%+.2f", q.price - prev), q.changePercent)
                    cell("3 分钟涨速", Fmt.pct(speed), speed)
                    cell("今开", Fmt.price(q.open), q.open.map { $0 - prev })
                    cell("最高", Fmt.price(q.high), q.high.map { $0 - prev })
                    cell("最低", Fmt.price(q.low), q.low.map { $0 - prev })
                    cell("昨收", Fmt.price(prev), nil)
                    cell("涨停价", Fmt.price(q.limitUpPrice), 1)
                    cell("跌停价", Fmt.price(q.limitDownPrice), -1)
                    cell("成交量", q.volume >= 1e4 ? String(format: "%.1f 万手", q.volume / 1e4) : String(format: "%.0f 手", q.volume), nil)
                    cell("成交额", Fmt.yuan(q.amount), nil)
                    cell("量比", q.volumeRatio.map { String(format: "%.2f", $0) } ?? "—", q.volumeRatio.map { $0 - 1.5 })
                    cell("换手率", q.turnover.map { String(format: "%.2f%%", $0) } ?? "—", nil)
                    cell("总市值", Fmt.yuan(q.totalMarketCap), nil)
                    cell("流通市值", Fmt.yuan(q.floatMarketCap), nil)
                    cell("板块", q.board, nil)
                    cell("行业", q.industry.isEmpty ? "—" : q.industry, nil)
                    if q.upperLimit || q.limitStreak != nil || q.firstLimitTime != nil {
                        cell("涨停状态", q.upperLimit ? ((q.limitStreak ?? 1) > 1 ? "\(q.limitStreak!) 连板" : "封板") : "炸板", q.upperLimit ? 1 : 0)
                        cell("首次封板", q.firstLimitTime.map { String($0.prefix(5)) } ?? "—", nil)
                        cell("炸板次数", q.limitOpenCount.map(String.init) ?? "—", nil)
                        cell("封单金额", Fmt.yuan(q.sealAmount), nil)
                    }
                }
            }
        }
    }

    private func cell(_ title: String, _ value: String, _ tone: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit().lineLimit(1).foregroundStyle(toneColor(tone))
        }
    }
}

private struct ChartPanel: View {
    let r: StockAnalysisResult
    @AppStorage("pad.analysis.chart") private var mode = "daily"
    @AppStorage("pad.analysis.levels") private var showLevels = true

    private struct MAPoint: Identifiable { let id: String; let index: Int; let value: Double; let series: String }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("量化走势").font(.headline)
                Picker("", selection: $mode) { Text("日 K").tag("daily"); Text("分时").tag("intraday") }.pickerStyle(.segmented).frame(width: 150)
                if mode == "daily" { Toggle("关键价位", isOn: $showLevels).toggleStyle(.button).controlSize(.small) }
                Spacer()
                Text(mode == "daily" ? "MA5 橙 · MA10 紫 · MA20 蓝 · MA60 青" : "蓝：价格 · 橙：均价").font(.caption2).foregroundStyle(.secondary)
            }
            if mode == "daily" { daily } else { intraday }
        }
    }

    @ViewBuilder private var daily: some View {
        let all = r.daily
        let data = Array(all.suffix(90).enumerated())
        if data.isEmpty {
            Text("暂无日线数据").font(.caption).foregroundStyle(.secondary).frame(height: 240)
        } else {
            let offset = max(all.count - 90, 0)
            let ma: [MAPoint] = [("MA5", 5), ("MA10", 10), ("MA20", 20), ("MA60", 60)].flatMap { name, n in
                (offset..<all.count).compactMap { i -> MAPoint? in
                    guard i + 1 >= n else { return nil }
                    return MAPoint(id: "\(name)\(i)", index: i - offset, value: all[(i + 1 - n)...i].map(\.close).reduce(0, +) / Double(n), series: name)
                }
            }
            let levels = showLevels ? r.levels.filter { $0.label != "目标参考" } : []
            let lo = min(data.map(\.element.low).min() ?? 0, levels.map(\.price).min() ?? .infinity) * 0.98
            let hi = max(data.map(\.element.high).max() ?? 1, levels.map(\.price).max() ?? 0) * 1.02
            VStack(spacing: 2) {
                Chart {
                    ForEach(data, id: \.offset) { i, bar in
                        let up = bar.close >= bar.open
                        RuleMark(x: .value("日", i), yStart: .value("低", bar.low), yEnd: .value("高", bar.high)).foregroundStyle(up ? Color.red : Color.green)
                        RectangleMark(xStart: .value("起", Double(i) - 0.35), xEnd: .value("止", Double(i) + 0.35),
                                      yStart: .value("开", min(bar.open, bar.close)), yEnd: .value("收", max(bar.open, bar.close) + 0.0001))
                            .foregroundStyle(up ? Color.red : Color.green)
                    }
                    ForEach(ma) { p in
                        LineMark(x: .value("日", p.index), y: .value("均线", p.value), series: .value("线", p.series))
                            .foregroundStyle(by: .value("线", p.series)).lineStyle(StrokeStyle(lineWidth: 1.2))
                    }
                    ForEach(levels, id: \.self) { level in
                        RuleMark(y: .value(level.label, level.price))
                            .foregroundStyle(level.label == "止损参考" ? Color.green.opacity(0.7) : (level.label == "支撑" ? Color.gray : Color.red.opacity(0.7)))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .annotation(position: .top, alignment: .leading) { Text("\(level.label) \(Fmt.price(level.price))").font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
                }
                .chartForegroundStyleScale(["MA5": Color.orange, "MA10": Color.purple, "MA20": Color.blue, "MA60": Color.teal])
                .chartLegend(.hidden)
                .chartYScale(domain: lo...hi)
                .chartXScale(domain: -1...Double(data.count))
                .chartXAxis {
                    AxisMarks(values: stride(from: 0, to: data.count, by: max(data.count / 6, 1)).map { $0 }) { value in
                        AxisGridLine()
                        AxisValueLabel { if let i = value.as(Int.self), i < data.count { Text(String(data[i].element.date.suffix(5))).font(.caption2) } }
                    }
                }
                .frame(height: 250)
                Chart(data, id: \.offset) { i, bar in
                    BarMark(x: .value("日", i), y: .value("成交额", bar.amount / 1e8))
                        .foregroundStyle(bar.close >= bar.open ? Color.red.opacity(0.55) : Color.green.opacity(0.55))
                }
                .chartXScale(domain: -1...Double(data.count)).chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: 50)
            }
        }
    }

    @ViewBuilder private var intraday: some View {
        let points = r.extras.intraday
        if points.isEmpty {
            Text("暂无分时数据").font(.caption).foregroundStyle(.secondary).frame(height: 260)
        } else {
            let pre = r.extras.preClose
            let values = points.map(\.price) + points.compactMap(\.avg) + [pre].compactMap { $0 }
            let lo = (values.min() ?? 0) * 0.995, hi = (values.max() ?? 1) * 1.005
            Chart {
                ForEach(points, id: \.index) { p in
                    LineMark(x: .value("时", p.index), y: .value("价", p.price), series: .value("线", "价格")).foregroundStyle(Color.blue)
                    AreaMark(x: .value("时", p.index), yStart: .value("底", lo), yEnd: .value("价", p.price))
                        .foregroundStyle(LinearGradient(colors: [Color.blue.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom))
                    if let avg = p.avg { LineMark(x: .value("时", p.index), y: .value("均价", avg), series: .value("线", "均价")).foregroundStyle(Color.orange) }
                }
                if let pre {
                    RuleMark(y: .value("昨收", pre)).foregroundStyle(Color.gray.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartYScale(domain: lo...hi)
            .chartXScale(domain: 0...240)
            .chartXAxis {
                AxisMarks(values: [0, 60, 120, 180, 240]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text(["09:30", "10:30", "11:30/13:00", "14:00", "15:00"][(value.as(Int.self) ?? 0) / 60]).font(.caption2) }
                }
            }
            .frame(height: 290)
        }
    }
}

private struct FlowPanel: View {
    let extras: AnalysisExtras
    private struct Line: Identifiable { let id: String; let index: Int; let value: Double; let series: String }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("资金流向").font(.headline)
            Text("东方财富口径：超大单 ≥ 100 万元，大单 20–100 万，中单 4–20 万，小单 < 4 万；主力 = 超大单 + 大单，散户 = 中单 + 小单")
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                big("主力净流入", extras.mainNet, extras.mainRatio.map { String(format: "占成交额 %+.1f%%", $0) })
                big("散户净流入", extras.retailNet, "中单 + 小单")
            }
            if !extras.minutes.isEmpty { minuteChart }
            if !extras.flowRows.isEmpty { table }
            if !extras.days.isEmpty { dayChart }
        }
    }

    private func big(_ title: String, _ value: Double?, _ sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(signedYuan(value)).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(toneColor(value))
            if let sub { Text(sub).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private var minuteChart: some View {
        let lines = extras.minutes.flatMap { m in
            [Line(id: "m\(m.index)", index: m.index, value: m.main / 1e4, series: "主力"),
             Line(id: "r\(m.index)", index: m.index, value: m.retail / 1e4, series: "散户"),
             Line(id: "s\(m.index)", index: m.index, value: m.superLarge / 1e4, series: "超大单")]
        }
        return Chart(lines) { line in
            LineMark(x: .value("时", line.index), y: .value("万元", line.value), series: .value("类", line.series)).foregroundStyle(by: .value("类", line.series))
            RuleMark(y: .value("零", 0)).foregroundStyle(Color.gray.opacity(0.4))
        }
        .chartForegroundStyleScale(["主力": Color.red, "散户": Color.green, "超大单": Color.orange])
        .chartXScale(domain: 0...240)
        .chartXAxis {
            AxisMarks(values: [0, 60, 120, 180, 240]) { value in
                AxisGridLine()
                AxisValueLabel { Text(["09:30", "10:30", "13:00", "14:00", "15:00"][(value.as(Int.self) ?? 0) / 60]).font(.caption2) }
            }
        }
        .frame(height: 170)
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack {
                Text("类别").frame(width: 64, alignment: .leading)
                Text("流入").frame(maxWidth: .infinity, alignment: .trailing)
                Text("流出").frame(maxWidth: .infinity, alignment: .trailing)
                Text("净额").frame(maxWidth: .infinity, alignment: .trailing)
                Text("占成交额").frame(maxWidth: .infinity, alignment: .trailing)
                Text("流入占比").frame(width: 120, alignment: .leading).padding(.leading, 10)
            }
            .font(.caption.bold()).foregroundStyle(.secondary).padding(.vertical, 6).padding(.horizontal, 8).background(Color.primary.opacity(0.05))
            ForEach(extras.flowRows, id: \.self) { row in
                let group = row.name == "主力" || row.name == "散户"
                let total = (row.inflow ?? 0) + (row.outflow ?? 0)
                let share = total > 0 ? (row.inflow ?? 0) / total : 0.5
                HStack {
                    Text(group ? row.name : "  " + row.name).font(group ? .callout.bold() : .callout).frame(width: 64, alignment: .leading)
                    Text(Fmt.yuan(row.inflow)).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .trailing)
                    Text(Fmt.yuan(row.outflow)).foregroundStyle(.green).frame(maxWidth: .infinity, alignment: .trailing)
                    Text(signedYuan(row.net)).bold().foregroundStyle(toneColor(row.net)).frame(maxWidth: .infinity, alignment: .trailing)
                    Text(row.netRatio.map { String(format: "%+.2f%%", $0) } ?? "—").foregroundStyle(toneColor(row.netRatio)).frame(maxWidth: .infinity, alignment: .trailing)
                    HStack(spacing: 4) {
                        GeometryReader { geo in
                            HStack(spacing: 0) {
                                Rectangle().fill(Color.red.opacity(0.65)).frame(width: geo.size.width * CGFloat(share))
                                Rectangle().fill(Color.green.opacity(0.65))
                            }
                        }
                        .frame(height: 8).clipShape(Capsule())
                        Text(String(format: "%.0f%%", share * 100)).font(.caption2).foregroundStyle(.secondary).frame(width: 30, alignment: .trailing)
                    }
                    .frame(width: 120).padding(.leading, 10)
                }
                .font(.callout.monospacedDigit()).padding(.vertical, 5).padding(.horizontal, 8)
                .background(group ? Color.primary.opacity(0.03) : Color.clear)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var dayChart: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("近 \(extras.days.count) 日主力净流入（万元）").font(.caption.bold()).foregroundStyle(.secondary)
            Chart(extras.days, id: \.date) { day in
                BarMark(x: .value("日", String(day.date.suffix(5))), y: .value("主力", day.main / 1e4))
                    .foregroundStyle(day.main >= 0 ? Color.red.opacity(0.75) : Color.green.opacity(0.75))
            }
            .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.system(size: 8)) } }
            .frame(height: 130)
        }
    }
}

private struct StatsPanel: View {
    let extras: AnalysisExtras

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(extras.stats, id: \.self) { group in
                Text(group.title).font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(group.items, id: \.self) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label).font(.caption2).foregroundStyle(.secondary)
                            Text(item.value).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(item.tone > 0 ? Color.red : (item.tone < 0 ? Color.green : Color.primary))
                        }
                    }
                }
            }
            if !(extras.bids.isEmpty && extras.asks.isEmpty) {
                Text("五档盘口").font(.headline)
                HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: 3) { ForEach(Array(extras.asks.enumerated().reversed()), id: \.offset) { i, l in level("卖\(i + 1)", l, .green) } }
                    VStack(spacing: 3) { ForEach(Array(extras.bids.enumerated()), id: \.offset) { i, l in level("买\(i + 1)", l, .red) } }
                }
                .frame(maxWidth: 420)
            }
        }
    }

    private func level(_ name: String, _ l: BookLevel, _ tint: Color) -> some View {
        HStack {
            Text(name).font(.caption).foregroundStyle(.secondary).frame(width: 30, alignment: .leading)
            Text(Fmt.price(l.price)).font(.caption.monospacedDigit()).foregroundStyle(tint)
            Spacer()
            Text(String(format: "%.0f", l.volume)).font(.caption.monospacedDigit())
        }
    }
}
