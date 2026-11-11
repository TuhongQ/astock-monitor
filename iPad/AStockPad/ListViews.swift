import SwiftUI

private func changeColor(_ value: Double) -> Color { value > 0 ? .red : (value < 0 ? .green : .primary) }

// MARK: Watchlist sidebar

struct WatchSidebar: View {
    @EnvironmentObject var store: PadStore
    let open: (String) -> Void
    @State private var group = "全部自选"
    @State private var newCode = ""

    private var groups: [String] {
        store.watch.groups.filter { !WatchData.isAutoGroup($0) }
            + store.watch.groups.filter { $0.hasPrefix(WatchData.pickGroupPrefix) }.sorted(by: >)
            + store.watch.groups.filter { $0.hasPrefix(WatchData.overnightGroupPrefix) }.sorted(by: >)
    }
    private var codes: [String] {
        group == "全部自选" ? store.watch.codes : store.watch.codes.filter { (store.watch.groupByCode[$0] ?? store.watch.groups.first) == group }
    }

    var body: some View {
        List {
            Section {
                Picker("分组", selection: $group) {
                    Text("全部自选").tag("全部自选")
                    ForEach(groups, id: \.self) { Text($0).tag($0) }
                }
                if let summary = store.picksSummary(group: group) {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("推荐 \(summary.count) 只" + (summary.sealed > 0 ? " · 涨停 \(summary.sealed)" : "") + " · 上涨 \(summary.winners) 只")
                        if let avg = summary.average { Text("· 平均 \(Fmt.pct(avg))").foregroundStyle(changeColor(avg)) }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let s = store.overnightSummary(group: group) {
                    VStack(alignment: .leading, spacing: 2) {
                        if s.tracked == 0 {
                            Text("\(String(s.day.suffix(5))) 14:50 锁定 \(s.count) 只 · 次日挂 +3% 止盈")
                        } else {
                            Text("次日冲高 ≥3%：\(s.hit3)/\(s.tracked) · ≥5%：\(s.hit5)/\(s.tracked)")
                            HStack(spacing: 8) {
                                if let o = s.avgOpen { Text("开盘均 \(Fmt.pct(o))").foregroundStyle(changeColor(o)) }
                                if let h = s.avgHigh { Text("最高均 \(Fmt.pct(h))").foregroundStyle(changeColor(h)) }
                            }
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("输入 6 位代码添加", text: $newCode).keyboardType(.numberPad)
                        .onSubmit { store.addCode(newCode); newCode = "" }
                    Button { store.addCode(newCode); newCode = "" } label: { Image(systemName: "plus.circle.fill") }
                        .disabled(newCode.filter(\.isNumber).count != 6)
                }
            }
            Section("\(codes.count) 只") {
                ForEach(codes, id: \.self) { code in
                    Button { open(code) } label: { row(code) }
                        .swipeActions {
                            Button(role: .destructive) { store.toggleWatch(code) } label: { Label("移除", systemImage: "trash") }
                        }
                }
                .onMove { store.moveWatch(from: $0, to: $1, in: codes) }
            }
        }
        .listStyle(.sidebar)
        .toolbar { EditButton() }
    }

    private func row(_ code: String) -> some View {
        let q = store.quote(code)
        let pick = store.pickHistory(code).first
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(q?.name ?? code).foregroundStyle(.primary)
                    if q?.upperLimit == true {
                        Text(q?.limitStreak.map { $0 > 1 ? "\($0)板" : "涨停" } ?? "涨停").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 3).background(RoundedRectangle(cornerRadius: 3).fill(Color.red))
                    }
                }
                HStack(spacing: 4) {
                    Text(code).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let pick, store.watch.groupByCode[code]?.hasPrefix(WatchData.pickGroupPrefix) == true {
                        let since = q.map { pick.pick.price > 0 ? ($0.price / pick.pick.price - 1) * 100 : 0 }
                        Text("荐\(pick.pick.initialScore) \(Fmt.pct(since, 1))").font(.system(size: 10, weight: .medium))
                            .foregroundStyle(changeColor(since ?? 0))
                    } else if let record = store.overnightPick(code) {
                        let high = record.pick.nextHighReturn
                        Text(high.map { "隔夜高 " + Fmt.pct($0, 1) } ?? String(format: "隔夜 ≥5%% %.0f%%", record.pick.pHi5 ?? 0))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(high.map { $0 >= 3 ? Color.red : Color.green } ?? Color.mint)
                    }
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.price(q?.price)).monospacedDigit().foregroundStyle(.primary)
                Text(Fmt.pct(q?.changePercent)).font(.caption).monospacedDigit().foregroundStyle(changeColor(q?.changePercent ?? 0))
            }
        }
    }
}

// MARK: Quote list

struct QuoteListView: View {
    @EnvironmentObject var store: PadStore
    let open: (String) -> Void
    @State private var search = ""
    @State private var board = "全部"
    @State private var industry = "全部行业"
    @State private var direction = "全部"
    @State private var sortKey = "change"
    @State private var ascending = false

    private var industries: [String] { ["全部行业"] + Array(Set(store.quotes.map(\.industry).filter { !$0.isEmpty })).sorted() }

    private var rows: [Quote] {
        let keyword = search.trimmingCharacters(in: .whitespaces)
        let filtered = store.quotes.filter { q in
            if !keyword.isEmpty { return q.code.contains(keyword) || q.name.localizedCaseInsensitiveContains(keyword) }
            if store.settings.filterST && q.isST { return false }
            if q.suspended { return false }
            if board != "全部" && q.board != board { return false }
            if industry != "全部行业" && q.industry != industry { return false }
            switch direction {
            case "上涨": return q.changePercent > 0
            case "下跌": return q.changePercent < 0
            case "涨停": return q.upperLimit || q.openedLimit
            default: return true
            }
        }
        func value(_ q: Quote) -> Double {
            switch sortKey {
            case "price": q.price
            case "volumeRatio": q.volumeRatio ?? 0
            case "turnover": q.turnover ?? 0
            case "amount": q.amount
            case "cap": q.floatMarketCap ?? 0
            default: q.changePercent
            }
        }
        return filtered.sorted { ascending ? value($0) < value($1) : value($0) > value($1) }
    }

    var body: some View {
        let data = rows
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("代码 / 名称", text: $search).textInputAutocapitalization(.never)
                }
                .padding(7).background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06))).frame(maxWidth: 220)
                Picker("板块", selection: $board) { ForEach(["全部", "主板", "创业板", "科创板", "北交所"], id: \.self) { Text($0) } }
                Picker("行业", selection: $industry) { ForEach(industries, id: \.self) { Text($0) } }
                Picker("方向", selection: $direction) { ForEach(["全部", "上涨", "下跌", "涨停"], id: \.self) { Text($0) } }
                    .pickerStyle(.segmented).frame(width: 240)
                Spacer()
                Text("\(data.count) / \(store.quotes.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            HStack(spacing: 0) {
                Text("名称 / 代码").frame(width: 150, alignment: .leading)
                header("现价", "price", width: 80)
                header("涨跌幅", "change", width: 90)
                header("量比", "volumeRatio", width: 70)
                header("换手", "turnover", width: 75)
                header("成交额", "amount", width: 90)
                header("流通市值", "cap", width: 95)
                Text("行业").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.bold()).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 6)
            .background(Color.primary.opacity(0.04))
            if data.isEmpty {
                VStack(spacing: 8) {
                    if store.quotes.isEmpty { ProgressView() }
                    Text(store.quotes.isEmpty ? store.status : "没有符合条件的股票").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(data) { q in
                            Button { open(q.code) } label: { quoteRow(q) }.buttonStyle(.plain)
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
        }
    }

    private func header(_ title: String, _ key: String, width: CGFloat) -> some View {
        Button {
            if sortKey == key { ascending.toggle() } else { sortKey = key; ascending = false }
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if sortKey == key { Image(systemName: ascending ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.system(size: 7)) }
            }
        }
        .buttonStyle(.plain).frame(width: width, alignment: .leading)
    }

    private func quoteRow(_ q: Quote) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(q.name).font(.system(size: 15, weight: .medium))
                    if store.watch.codes.contains(q.code) { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.yellow) }
                    if q.upperLimit { Text(q.limitStreak.map { $0 > 1 ? "\($0)连板" : "涨停" } ?? "涨停").font(.system(size: 10, weight: .bold)).foregroundStyle(.red) }
                    else if q.openedLimit { Text("炸板").font(.system(size: 10, weight: .bold)).foregroundStyle(.orange) }
                }
                Text(q.code).font(.caption.monospaced()).foregroundStyle(.secondary)
            }.frame(width: 150, alignment: .leading)
            Text(Fmt.price(q.price)).frame(width: 80, alignment: .leading).foregroundStyle(changeColor(q.changePercent))
            Text(Fmt.pct(q.changePercent)).frame(width: 90, alignment: .leading).foregroundStyle(changeColor(q.changePercent))
            Text(q.volumeRatio.map { String(format: "%.2f", $0) } ?? "—").frame(width: 70, alignment: .leading)
            Text(q.turnover.map { String(format: "%.2f%%", $0) } ?? "—").frame(width: 75, alignment: .leading)
            Text(Fmt.yuan(q.amount)).frame(width: 90, alignment: .leading)
            Text(Fmt.yuan(q.floatMarketCap)).frame(width: 95, alignment: .leading)
            Text(q.industry.isEmpty ? "—" : q.industry).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 14)).monospacedDigit()
        .padding(.horizontal, 14).padding(.vertical, 7)
        .contentShape(Rectangle())
        .contextMenu {
            Button(store.watch.codes.contains(q.code) ? "移出自选" : "加入自选") { store.toggleWatch(q.code) }
            Button(store.watch.blacklist.contains(q.code) ? "移出黑名单" : "加入黑名单") { store.toggleBlacklist(q.code) }
        }
    }
}

// MARK: Alerts

struct AlertsView: View {
    @EnvironmentObject var store: PadStore
    let open: (String) -> Void
    @State private var typeFilter = "全部"
    @State private var industryFilter: String?
    @State private var onlyToday = true

    private var base: [AlertRecord] {
        store.alerts.filter { (!onlyToday || Market.dayKey($0.time) == Market.dayKey()) && (industryFilter == nil || $0.industry == industryFilter) }
    }
    private var limitSide: [AlertRecord] {
        base.filter { $0.isLimitSide }.filter { r in
            switch typeFilter {
            case "涨幅": r.type == "daily"
            case "涨停": r.type == "limitUp"
            case "回封": r.type == "limitReseal"
            case "炸板": r.type == "limitOpen"
            case "跌停": r.type == "limitDown"
            default: true
            }
        }
    }
    private var rapidSide: [AlertRecord] { base.filter { !$0.isLimitSide } }

    var body: some View {
        VStack(spacing: 0) {
            emotionBar
            HStack(spacing: 10) {
                Picker("类型", selection: $typeFilter) { ForEach(["全部", "涨幅", "涨停", "回封", "炸板", "跌停"], id: \.self) { Text($0) } }
                    .pickerStyle(.segmented).frame(maxWidth: 420)
                Toggle("仅今日", isOn: $onlyToday).toggleStyle(.button)
                if let industryFilter {
                    Button { self.industryFilter = nil } label: { Label(industryFilter, systemImage: "xmark.circle.fill") }.foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            HStack(alignment: .top, spacing: 10) {
                column("涨幅 / 涨停", limitSide, rapid: false)
                column("速拉", rapidSide, rapid: true)
            }
            .padding(.horizontal, 10).padding(.bottom, 8)
        }
    }

    private var emotionBar: some View {
        let emotion = store.emotion
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                stat("涨停", "\(emotion?.limitUpCount ?? store.breadth?.limitUpCount ?? 0)", .red)
                stat("炸板", "\(emotion?.brokenCount ?? 0)", .orange)
                if let rate = emotion?.brokenRate { stat("炸板率", String(format: "%.0f%%", rate), rate > 40 ? .green : .orange) }
                stat("跌停", "\(store.breadth?.limitDownCount ?? 0)", .green)
                stat("最高", "\(emotion?.maxStreak ?? 0) 板", .red)
                if let premium = emotion?.previousPremium { stat("昨涨停溢价", Fmt.pct(premium, 1), changeColor(premium)) }
                if let mood = emotion?.mood, mood != "未知" {
                    Text("情绪 \(mood)").font(.caption.bold()).foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(mood == "高潮" ? Color.red : (mood == "回暖" ? .orange : (mood == "退潮" ? .green : .gray))))
                }
                Spacer()
            }
            if let emotion {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("涨停板块").font(.caption2).foregroundStyle(.secondary)
                        ForEach(emotion.topIndustries, id: \.0) { name, count in
                            Button { industryFilter = industryFilter == name ? nil : name } label: {
                                Text("\(name) \(count)").font(.caption).padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Capsule().fill(Color.red.opacity(industryFilter == name ? 0.25 : 0.1)))
                            }.buttonStyle(.plain)
                        }
                        if !emotion.ladder.isEmpty {
                            Text("连板梯队：" + emotion.ladder.map { "\($0.streak)板×\($0.count)（\($0.names.prefix(2).joined(separator: "、"))）" }.joined(separator: "  "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(color)
        }
    }

    private func column(_ title: String, _ records: [AlertRecord], rapid: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(title).font(.headline); Spacer(); Text("\(records.count) 条").font(.caption).foregroundStyle(.secondary) }
                .padding(10)
            if records.isEmpty {
                Text(rapid ? "暂无速拉告警（全市场，交易时段）" : "暂无涨幅 / 涨停告警；交易时段全市场封板、炸板、回封自动记录")
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(records) { record in
                        Button { open(record.code) } label: { alertRow(record, rapid: rapid) }
                    }
                    .onDelete { offsets in store.deleteAlerts(Set(offsets.map { records[$0].id })) }
                }
                .listStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
    }

    private func alertRow(_ r: AlertRecord, rapid: Bool) -> some View {
        let typeColor: Color = ["limitUp", "limitReseal"].contains(r.type) ? .red : (r.type == "limitOpen" || r.type == "rapid" ? .orange : (r.type == "limitDown" ? .green : .secondary))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(r.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(r.typeLabel).font(.caption.bold()).foregroundStyle(typeColor)
                Text(r.name).font(.system(size: 14, weight: .medium)).foregroundStyle(.primary)
                Text(r.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                if let streak = r.limitStreak, streak > 1 { Text("\(streak)板").font(.caption2.bold()).foregroundStyle(.red) }
                Spacer()
                Text(Fmt.pct(r.change)).font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(changeColor(r.change))
                Text(Fmt.price(r.price)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if let industry = r.industry { Text(industry).font(.caption2).foregroundStyle(.secondary) }
                if rapid, let start = r.startPrice {
                    Text("起 \(Fmt.price(start)) \(Fmt.pct(r.startChangePercent))").font(.caption2).foregroundStyle(.secondary)
                }
                if let detail = r.detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .opacity(r.silent == true ? 0.85 : 1)
    }
}

// MARK: Potential picks

struct PicksView: View {
    @EnvironmentObject var store: PadStore
    let open: (String) -> Void
    @AppStorage("pad.strategy") private var strategy = "all"
    @State private var showLogic = false
    @AppStorage("pad.overnightBoard") private var overnightBoard = "全部"

    private var meta: StrategyMeta { QuantEngine.strategies.first { $0.id == strategy } ?? QuantEngine.strategies[0] }
    private var picks: [StockPick] {
        let all = (store.lists[strategy] ?? []).filter { !store.watch.blacklist.contains($0.code) }
        guard strategy == "overnight", overnightBoard != "全部" else { return all }
        return all.filter { ($0.board ?? WatchData.pickBoard(code: $0.code)) == overnightBoard }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(QuantEngine.strategies) { item in
                        let selected = item.id == strategy
                        Button { strategy = item.id } label: {
                            HStack(spacing: 6) {
                                Image(systemName: item.icon)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("\(item.title) \((store.lists[item.id] ?? []).count)").font(.system(size: 13, weight: .semibold))
                                    Text(item.summary).font(.system(size: 10)).lineLimit(1).opacity(0.8)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(maxWidth: 230, alignment: .leading)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor : Color.primary.opacity(0.06)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            HStack(spacing: 10) {
                DisclosureGroup(isExpanded: $showLogic) {
                    Text(meta.description + " 评分 0–100，≥ 75 为 A、≥ 60 为 B。仅为规则化选股参考，不构成投资建议。")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } label: { Text("「\(meta.title)」选股逻辑").font(.caption) }
                Spacer()
                if let progress = store.scanProgress {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1))).frame(width: 90)
                    Text("拉取日线 \(progress.done)/\(progress.total)").font(.caption).monospacedDigit()
                } else if let last = store.lastScan {
                    Text("日线复核 \(last.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
            if strategy == "overnight" { overnightHeader }
            if picks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: meta.icon).font(.largeTitle).foregroundStyle(.secondary)
                    Text(emptyText).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(picks) { pick in
                    Button { open(pick.code) } label: { pickRow(pick) }
                        .contextMenu {
                            Button(store.watch.codes.contains(pick.code) ? "移出自选" : "加入自选") { store.toggleWatch(pick.code) }
                            Button("加入黑名单（不再推荐）", role: .destructive) { store.toggleBlacklist(pick.code) }
                        }
                }
                .listStyle(.plain)
            }
        }
    }

    private var overnightHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Picker("板块", selection: $overnightBoard) {
                    Text("全部").tag("全部"); Text("主板").tag("主板"); Text("创业科创").tag("创业科创")
                }.pickerStyle(.segmented).frame(width: 260)
                if let r = store.overnightTrackRecord() {
                    Text("实盘跟踪 \(r.picks) 只：冲高 ≥3% \(r.hit3) 只（\(Int((Double(r.hit3) / Double(r.picks) * 100).rounded()))%）· ≥5% \(r.hit5) 只"
                         + (r.avgOpen.map { " · 开盘均 " + Fmt.pct($0) } ?? "") + (r.avgHigh.map { " · 最高均 " + Fmt.pct($0) } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(Market.isSession() && Market.minuteOfDay() < 890 ? "14:50 自动锁定，此前为预览" : "14:50 锁定后，次日记录开盘 / 最高检验命中率")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("买点 14:50–14:57；卖点：次日挂「止盈」价单，10:30 前未成交或跌破「止损」就卖出。这类高波动股次日开盘平均低开约 1%，开盘直接卖不划算。")
                .font(.caption2).foregroundStyle(.orange)
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyText: String {
        if store.quotes.isEmpty { return "等待全市场行情…" }
        switch strategy {
        case "surge": return "速拉需要盘中连续快照：交易时段保持应用在前台，出现 5 分钟内拉升 ≥ 1.8% 的个股后会自动出现。"
        case "trend", "pullback": return store.scanProgress != nil ? "正在拉取候选股日线…" : "暂无达标个股（强势回踩需要近 15 日涨停名单，首次启动会自动回补）。"
        case "tail": return "尾盘潜伏在 14:30 后结果更有效。"
        default: return "暂无达标个股。没有明确形态时空仓也是一种操作。"
        }
    }

    private func pickRow(_ p: StockPick) -> some View {
        let live = store.quote(p.code)
        let price = live?.price ?? p.price, change = live?.changePercent ?? p.changePercent
        let inWatch = store.watch.codes.contains(p.code)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Button { store.toggleWatch(p.code) } label: {
                        Image(systemName: inWatch ? "star.fill" : "star").foregroundStyle(inWatch ? Color.yellow : Color.secondary)
                    }.buttonStyle(.borderless)
                    Text(p.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                }
                Text("\(p.code) · \(p.industry.isEmpty ? "—" : p.industry)").font(.caption).foregroundStyle(.secondary)
            }.frame(width: 150, alignment: .leading)
            HStack(spacing: 5) {
                Text(p.grade).font(.caption.bold()).foregroundStyle(.white).frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 4).fill(p.grade == "A" ? Color.red : (p.grade == "B" ? .orange : .gray)))
                Text("\(p.score)").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(.primary)
            }.frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(Fmt.price(price)).foregroundStyle(.primary)
                Text(Fmt.pct(change)).font(.caption).foregroundStyle(changeColor(change))
            }.monospacedDigit().frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(p.highlights.prefix(3).enumerated()), id: \.offset) { i, text in
                    Text(text).font(i == 0 ? .caption : .caption2).foregroundStyle(i == 0 ? Color.primary : Color.secondary).lineLimit(1)
                }
            }.frame(width: 140, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.pivot.map { String(format: p.strategy == "overnight" ? "止盈 %.2f" : "观察 %.2f", $0) } ?? "—").foregroundStyle(.primary)
                Text(p.stopLoss.map { String(format: "止损 %.2f", $0) + (p.riskPercent.map { String(format: "（-%.1f%%）", $0) } ?? "") } ?? "—")
                    .font(.caption2).foregroundStyle(.green)
            }.font(.caption).monospacedDigit().frame(width: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                if !p.tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(p.tags.prefix(5).enumerated()), id: \.offset) { _, tag in
                            Text(tag).font(.system(size: 10, weight: .medium)).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        }
                    }
                }
                Text(p.signals.joined(separator: " · ")).font(.caption).foregroundStyle(.primary).lineLimit(2)
                if !p.risks.isEmpty {
                    Label(p.risks.joined(separator: " · "), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

// MARK: Settings

struct SettingsView: View {
    @EnvironmentObject var store: PadStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("告警") {
                    Stepper(String(format: "涨幅阈值 %.1f%%（自选股）", store.settings.threshold), value: $store.settings.threshold, in: 0...20, step: 0.5)
                    Stepper(String(format: "速拉阈值 %.1f%%（全市场）", store.settings.rapidThreshold), value: $store.settings.rapidThreshold, in: 0.5...10, step: 0.5)
                    Picker("速拉窗口", selection: $store.settings.windowSeconds) {
                        Text("30 秒").tag(30); Text("1 分钟").tag(60); Text("2 分钟").tag(120); Text("3 分钟").tag(180); Text("5 分钟").tag(300)
                    }
                    Picker("涨幅 / 涨停冷却", selection: $store.settings.cooldownSeconds) {
                        Text("30 秒").tag(30); Text("1 分钟").tag(60); Text("3 分钟").tag(180); Text("10 分钟").tag(600)
                    }
                    Picker("速拉冷却", selection: $store.settings.rapidCooldownSeconds) {
                        Text("30 秒").tag(30); Text("1 分钟").tag(60); Text("3 分钟").tag(180); Text("10 分钟").tag(600)
                    }
                    Toggle("全市场涨停监控（封板 / 炸板 / 回封 / 跌停）", isOn: $store.settings.limitMonitorAll)
                    Toggle("非自选股涨停也弹出横幅", isOn: $store.settings.limitBannerAll)
                    Toggle("过滤 ST", isOn: $store.settings.filterST)
                }
                Section {
                    Toggle("每日自动推荐", isOn: $store.settings.autoPicks)
                    Stepper("每板块每日 \(store.settings.dailyPickLimit) 只", value: $store.settings.dailyPickLimit, in: 3...30)
                    Toggle("尾盘隔夜推荐（14:50 锁定，建「隔夜 MM-dd」分组）", isOn: $store.settings.autoOvernight)
                    Stepper("隔夜每板块 \(store.settings.overnightLimit) 只", value: $store.settings.overnightLimit, in: 3...15)
                } header: { Text("每日推荐") } footer: {
                    Text("综合 A 级、未涨停可买入的股票按日期和板块（主板 / 创业科创）加入「推荐 MM-dd」分组；每板块保持设定数量的可买入股票，已涨停的不占名额、自动补入新股；满额后评分高至少 3 分才替换最低分，每只至少保留 10 分钟。")
                }
                Section {
                    Picker("刷新间隔", selection: $store.settings.refreshSeconds) {
                        Text("3 秒（推荐）").tag(3); Text("5 秒").tag(5); Text("10 秒").tag(10); Text("15 秒").tag(15); Text("30 秒").tag(30); Text("60 秒").tag(60)
                    }
                } header: { Text("行情") } footer: {
                    Text("iPad 版直接请求东方财富公开接口，全市场约 60 页并发获取（约 0.3 秒）；交易所一档快照约 3 秒更新一次，更短的间隔没有意义。iPadOS 不允许后台持续联网，应用需保持在前台才会刷新和告警；运行时会保持屏幕常亮。数据仅供参考，不构成投资建议。")
                }
            }
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
