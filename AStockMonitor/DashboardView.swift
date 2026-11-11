import SwiftUI
import Charts
import AppKit

private struct IntradayChartPoint: Identifiable {
    let id: UUID
    let sessionMinute: Double
    let price: Double
}

private struct FiveDayTrendChartPoint: Identifiable {
    let id: UUID
    let sessionIndex: Double
    let price: Double
}

private struct IndexedCandleChartPoint: Identifiable {
    let id: UUID
    let index: Double
    let candle: CandlePoint
}

/// Observes horizontal trackpad scroll gestures only while the pointer is over
/// the detail chart, without consuming the event or interfering with vertical scrolling.
private struct HorizontalTrackpadGesture: NSViewRepresentable {
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onSwipe = onSwipe
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) { view.onSwipe = onSwipe }

    final class TrackingView: NSView {
        var onSwipe: (Int) -> Void = { _ in }
        private var monitor: Any?
        private var accumulatedDelta: CGFloat = 0
        private var didSendSwipe = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                if event.phase.contains(.began) {
                    self.accumulatedDelta = 0
                    self.didSendSwipe = false
                }
                if event.phase.contains(.changed), !self.didSendSwipe,
                   abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.2 {
                    self.accumulatedDelta += event.scrollingDeltaX
                    if abs(self.accumulatedDelta) >= 55 {
                        self.didSendSwipe = true
                        self.onSwipe(self.accumulatedDelta < 0 ? 1 : -1)
                    }
                }
                if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                    self.accumulatedDelta = 0
                    self.didSendSwipe = false
                }
                return event
            }
        }

        deinit { removeMonitor() }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }
}

/// AppKit's NSTableView has no ten-column TableColumnBuilder limit, virtualizes
/// rows, and keeps its vertical scroller anchored to the visible viewport.
private final class ContextMenuQuoteTableView: NSTableView {
    var contextMenuProvider: ((NSEvent, Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0, let menu = contextMenuProvider?(event, row) else {
            return super.menu(for: event)
        }
        return menu
    }
}

private struct NativeQuoteTable: NSViewRepresentable {
    let quotes: [Quote]
    let availableWidth: CGFloat
    let conceptProvider: (String) -> [String]
    let conceptsRevision: Int
    let sortKey: String
    let ascending: Bool
    let onSelect: (String) -> Void
    let focusRequest: AlertJumpFocus?
    let onSort: (String, Bool) -> Void
    let isBlacklisted: (String) -> Bool
    let isInMenuBar: (String) -> Bool
    let isInWatchlist: (String) -> Bool
    let onContextAction: (String, QuoteContextAction) -> Void

    private let columns: [(id: String, title: String, min: CGFloat)] = [
        ("code", "代码", 54), ("name", "名称", 62),
        ("price", "现价", 46), ("changePercent", "涨跌幅", 58),
        ("volumeRatio", "量比", 46), ("turnover", "换手率", 58),
        ("amount", "成交额", 58), ("totalMarketCap", "总市值", 58),
        ("floatMarketCap", "流通市值", 68), ("annualNetProfit", "年度盈亏", 72),
        ("quarterlyNetProfit", "季度盈亏", 72),
        ("industry", "行业", 48), ("concept", "概念", 48)
    ]

    func makeCoordinator() -> Coordinator { Coordinator(columns: columns) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.scrollerStyle = .legacy
        scrollView.drawsBackground = false

        let tableView = ContextMenuQuoteTableView()
        tableView.headerView = NSTableHeaderView()
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 30
        tableView.gridStyleMask = [.solidHorizontalGridLineMask]
        tableView.gridColor = .separatorColor
        tableView.selectionHighlightStyle = .regular
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.contextMenuProvider = { [weak coordinator = context.coordinator] event, row in
            coordinator?.makeContextMenu(for: event, row: row)
        }

        for spec in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.minWidth = spec.min
            column.width = spec.min
            column.resizingMask = .userResizingMask
            column.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: true)
            tableView.addTableColumn(column)
        }
        tableView.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: ascending)]
        scrollView.documentView = tableView
        context.coordinator.attach(tableView: tableView, scrollView: scrollView)
        context.coordinator.update(
            quotes: quotes, conceptProvider: conceptProvider, conceptsRevision: conceptsRevision, sortKey: sortKey,
            ascending: ascending, onSelect: onSelect, onSort: onSort,
            isBlacklisted: isBlacklisted, isInMenuBar: isInMenuBar,
            isInWatchlist: isInWatchlist, onContextAction: onContextAction, focusRequest: focusRequest,
            availableWidth: availableWidth
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            quotes: quotes, conceptProvider: conceptProvider, conceptsRevision: conceptsRevision, sortKey: sortKey,
            ascending: ascending, onSelect: onSelect, onSort: onSort,
            isBlacklisted: isBlacklisted, isInMenuBar: isInMenuBar,
            isInWatchlist: isInWatchlist, onContextAction: onContextAction, focusRequest: focusRequest,
            availableWidth: availableWidth
        )
        context.coordinator.resizeColumns()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private let specs: [(id: String, title: String, min: CGFloat)]
        private weak var tableView: NSTableView?
        private weak var scrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?
        private var lastContentWidthSignature: Int?
        private var requestedContentWidthSignature: Int?
        private var preferredColumnWidths: [CGFloat]?
        private var lastAppliedViewportWidth: CGFloat = 0
        private var providedViewportWidth: CGFloat = 0
        private var quotes: [Quote] = []
        private var conceptProvider: (String) -> [String] = { _ in [] }
        private var onSelect: (String) -> Void = { _ in }
        private var onSort: (String, Bool) -> Void = { _, _ in }
        private var isBlacklisted: (String) -> Bool = { _ in false }
        private var isInMenuBar: (String) -> Bool = { _ in false }
        private var isInWatchlist: (String) -> Bool = { _ in false }
        private var onContextAction: (String, QuoteContextAction) -> Void = { _, _ in }
        private var isApplyingSort = false
        private var isApplyingProgrammaticFocus = false
        private var lastFocusedRequestID: UUID?

        init(columns: [(id: String, title: String, min: CGFloat)]) {
            specs = columns
        }

        func attach(tableView: NSTableView, scrollView: NSScrollView) {
            self.tableView = tableView
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in self?.resizeColumns() }
        }

        deinit {
            if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        }

        func update(
            quotes: [Quote], conceptProvider: @escaping (String) -> [String],
            conceptsRevision: Int,
            sortKey: String, ascending: Bool, onSelect: @escaping (String) -> Void,
            onSort: @escaping (String, Bool) -> Void,
            isBlacklisted: @escaping (String) -> Bool,
            isInMenuBar: @escaping (String) -> Bool,
            isInWatchlist: @escaping (String) -> Bool,
            onContextAction: @escaping (String, QuoteContextAction) -> Void,
            focusRequest: AlertJumpFocus?, availableWidth: CGFloat
        ) {
            self.quotes = quotes
            self.conceptProvider = conceptProvider
            var signatureHasher = Hasher()
            signatureHasher.combine(conceptsRevision)
            for quote in quotes {
                signatureHasher.combine(quote.code)
                signatureHasher.combine(quote.name)
                signatureHasher.combine(quote.isST)
                signatureHasher.combine(quote.upperLimit)
                signatureHasher.combine(quote.lowerLimit)
                signatureHasher.combine(quote.industry)
                signatureHasher.combine(quote.concept)
            }
            requestedContentWidthSignature = signatureHasher.finalize()
            self.onSelect = onSelect
            self.onSort = onSort
            self.isBlacklisted = isBlacklisted
            self.isInMenuBar = isInMenuBar
            self.isInWatchlist = isInWatchlist
            self.onContextAction = onContextAction
            providedViewportWidth = availableWidth
            guard let tableView else { return }
            if tableView.sortDescriptors.first?.key != sortKey || tableView.sortDescriptors.first?.ascending != ascending {
                isApplyingSort = true
                tableView.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: ascending)]
                isApplyingSort = false
            }
            tableView.reloadData()
            resizeColumns()
            if let focusRequest, focusRequest.id != lastFocusedRequestID,
               let row = quotes.firstIndex(where: { $0.code == focusRequest.code }) {
                lastFocusedRequestID = focusRequest.id
                isApplyingProgrammaticFocus = true
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                tableView.scrollRowToVisible(row)
                DebugLog.write("告警双击跳转行情列表：code=\(focusRequest.code), row=\(row)")
                DispatchQueue.main.async { [weak self] in self?.isApplyingProgrammaticFocus = false }
            }
        }

        func resizeColumns() {
            guard let tableView, let scrollView,
                  let signature = requestedContentWidthSignature else { return }
            let viewportWidth = providedViewportWidth > 0 ? providedViewportWidth : scrollView.contentView.bounds.width
            guard viewportWidth > 0 else { return }
            let contentChanged = signature != lastContentWidthSignature || preferredColumnWidths == nil
            guard contentChanged || abs(viewportWidth - lastAppliedViewportWidth) > 1 else { return }

            let font = NSFont.systemFont(ofSize: 13)
            let attributes: [NSAttributedString.Key: Any] = [.font: font]
            func textWidth(_ value: String) -> CGFloat {
                (value as NSString).size(withAttributes: attributes).width
            }

            if contentChanged {
                var preferred = specs.map { max($0.min, textWidth($0.title) + 10) }
                func observe(_ id: String, _ value: String, extra: CGFloat = 10, maximum: CGFloat) {
                    guard let index = specs.firstIndex(where: { $0.id == id }) else { return }
                    preferred[index] = max(preferred[index], min(maximum, textWidth(value) + extra))
                }
                for quote in quotes {
                    observe("code", quote.code, maximum: 82)
                    observe("name", quote.name + ((quote.isST || quote.upperLimit || quote.lowerLimit) ? " 涨停" : ""), maximum: 150)
                    observe("price", String(format: "%.2f", quote.price), maximum: 88)
                    observe("changePercent", String(format: "%+.2f%%", quote.changePercent), maximum: 96)
                    observe("volumeRatio", quote.volumeRatio.map { String(format: "%.2f", $0) } ?? "—", maximum: 82)
                    observe("turnover", quote.turnover.map { String(format: "%.2f%%", $0) } ?? "—", maximum: 92)
                    observe("amount", compactYuan(quote.amount), maximum: 100)
                    observe("totalMarketCap", compactYuan(quote.totalMarketCap), maximum: 100)
                    observe("floatMarketCap", compactYuan(quote.floatMarketCap), maximum: 108)
                    observe("annualNetProfit", compactYuan(quote.annualNetProfit), maximum: 108)
                    observe("quarterlyNetProfit", compactYuan(quote.quarterlyNetProfit), maximum: 108)
                    if let industry = quote.industry { observe("industry", industry, maximum: 132) }
                }
                // Full concept labels can be very long; sample only a bounded
                // number of rows and cap the preferred width so they do not
                // force every other column offscreen.
                for quote in quotes.prefix(120) {
                    let tags = conceptProvider(quote.code)
                    if !tags.isEmpty { observe("concept", tags.joined(separator: "、"), maximum: 210) }
                }
                preferredColumnWidths = preferred
                lastContentWidthSignature = signature
            }

            guard let preferred = preferredColumnWidths else { return }
            let minimums = specs.map { max($0.min, textWidth($0.title) + 10) }
            var widths = preferred
            let minimumTotal = minimums.reduce(CGFloat.zero, +)
            let targetWidth = max(viewportWidth, minimumTotal)
            var currentTotal = widths.reduce(CGFloat.zero, +)

            if currentTotal > targetWidth {
                var excess = currentTotal - targetWidth
                var shrinkable = widths.indices.filter { widths[$0] > minimums[$0] }
                while excess > 0.5, !shrinkable.isEmpty {
                    let share = excess / CGFloat(shrinkable.count)
                    var reduced: CGFloat = 0
                    for index in shrinkable {
                        let amount = min(widths[index] - minimums[index], share)
                        widths[index] -= amount
                        reduced += amount
                    }
                    if reduced < 0.5 { break }
                    excess -= reduced
                    shrinkable = widths.indices.filter { widths[$0] > minimums[$0] + 0.5 }
                }
            } else if currentTotal < targetWidth {
                let extra = targetWidth - currentTotal
                // Use spare viewport space for descriptive columns instead of
                // leaving a large blank tail after the concept column.
                let industryIndex = specs.firstIndex { $0.id == "industry" } ?? 0
                let conceptIndex = specs.firstIndex { $0.id == "concept" } ?? (widths.count - 1)
                widths[industryIndex] += extra * 0.35
                widths[conceptIndex] += extra * 0.65
            }

            currentTotal = widths.reduce(CGFloat.zero, +)
            for (index, width) in widths.enumerated() where index < tableView.tableColumns.count {
                tableView.tableColumns[index].width = ceil(width)
            }
            var frame = tableView.frame
            frame.size.width = max(viewportWidth, tableView.tableColumns.reduce(CGFloat.zero) { $0 + $1.width })
            tableView.frame = frame
            lastAppliedViewportWidth = viewportWidth
        }

        func numberOfRows(in tableView: NSTableView) -> Int { quotes.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard quotes.indices.contains(row), let key = tableColumn?.identifier.rawValue else { return nil }
            let quote = quotes[row]
            let value: String
            let color: NSColor
            switch key {
            case "code": value = quote.code; color = .labelColor
            case "name":
                var flags: [String] = []
                if quote.isST { flags.append("ST") }
                if quote.upperLimit { flags.append(quote.limitStreak.map { $0 > 1 ? "\($0)连板" : "涨停" } ?? "涨停") }
                else if let limit = quote.limitUpPrice, let high = quote.high, high >= limit - 0.005, quote.price > 0 { flags.append("炸板") }
                if quote.lowerLimit { flags.append("跌停") }
                value = flags.isEmpty ? quote.name : "\(quote.name)  \(flags.joined(separator: " "))"
                color = .labelColor
            case "price": value = String(format: "%.2f", quote.price); color = quote.changePercent >= 0 ? .systemRed : .systemGreen
            case "changePercent": value = String(format: "%+.2f%%", quote.changePercent); color = quote.changePercent >= 0 ? .systemRed : .systemGreen
            case "volumeRatio": value = quote.volumeRatio.map { String(format: "%.2f", $0) } ?? "—"; color = .labelColor
            case "turnover": value = quote.turnover.map { String(format: "%.2f%%", $0) } ?? "—"; color = .labelColor
            case "amount": value = compactYuan(quote.amount); color = .labelColor
            case "totalMarketCap": value = compactYuan(quote.totalMarketCap); color = .labelColor
            case "floatMarketCap": value = compactYuan(quote.floatMarketCap); color = .labelColor
            case "annualNetProfit": value = compactYuan(quote.annualNetProfit); color = (quote.annualNetProfit ?? 0) < 0 ? .systemGreen : .labelColor
            case "quarterlyNetProfit": value = compactYuan(quote.quarterlyNetProfit); color = (quote.quarterlyNetProfit ?? 0) < 0 ? .systemGreen : .labelColor
            case "industry": value = quote.industry ?? "—"; color = .labelColor
            case "concept":
                let tags = conceptProvider(quote.code)
                value = tags.isEmpty ? "—" : tags.joined(separator: "、")
                color = .labelColor
            default: value = "—"; color = .labelColor
            }
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: value)
            label.font = key == "code" ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 13)
            label.textColor = color
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.usesSingleLineMode = label.maximumNumberOfLines == 1
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticFocus else { return }
            guard let tableView, tableView.selectedRow >= 0, quotes.indices.contains(tableView.selectedRow) else { return }
            onSelect(quotes[tableView.selectedRow].code)
        }

        // NSTableView 的右键菜单需要覆写 NSView.menu(for:)；delegate 没有对应回调。
        func makeContextMenu(for event: NSEvent, row: Int) -> NSMenu? {
            guard quotes.indices.contains(row) else { return nil }
            let quote = quotes[row]
            let menu = NSMenu()
            addContextItem("查看分时图", action: .openDetail, code: quote.code, to: menu)
            addContextItem(isBlacklisted(quote.code) ? "移出黑名单" : "加入黑名单", action: .toggleBlacklist, code: quote.code, to: menu)
            addContextItem(isInMenuBar(quote.code) ? "从状态栏移除" : "添加到状态栏", action: .toggleMenuBar, code: quote.code, to: menu)
            addContextItem(isInWatchlist(quote.code) ? "从监控自选池移除" : "加入监控自选池", action: .toggleWatchlist, code: quote.code, to: menu)
            DebugLog.write("主行情右键菜单已构建：code=\(quote.code), 状态栏已添加=\(isInMenuBar(quote.code))")
            return menu
        }

        private func addContextItem(_ title: String, action: QuoteContextAction, code: String, to menu: NSMenu) {
            let item = NSMenuItem(title: title, action: #selector(performContextAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = action.rawValue
            item.representedObject = code
            menu.addItem(item)
        }

        @objc private func performContextAction(_ sender: NSMenuItem) {
            guard let code = sender.representedObject as? String,
                  let action = QuoteContextAction(rawValue: sender.tag) else { return }
            DebugLog.write("主行情右键操作：\(action.logName), code=\(code)")
            onContextAction(code, action)
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isApplyingSort, let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key, specs.contains(where: { $0.id == key }) else { return }
            onSort(key, descriptor.ascending)
        }

        private func compactYuan(_ value: Double?) -> String {
            guard let value else { return "—" }
            let magnitude = abs(value)
            let number = magnitude >= 100_000_000 ? String(format: "%.1f亿", magnitude / 100_000_000) : (magnitude >= 10_000 ? String(format: "%.0f万", magnitude / 10_000) : String(format: "%.0f元", magnitude))
            return value < 0 ? "-\(number)" : number
        }
    }
}

private enum QuoteContextAction: Int {
    case openDetail
    case toggleBlacklist
    case toggleMenuBar
    case toggleWatchlist

    var logName: String {
        switch self {
        case .openDetail: return "查看分时图"
        case .toggleBlacklist: return "切换黑名单"
        case .toggleMenuBar: return "切换状态栏股票"
        case .toggleWatchlist: return "切换自选股"
        }
    }
}

private struct AlertJumpFocus: Identifiable {
    let id = UUID()
    let code: String
}

struct DashboardView: View {
    @ObservedObject var store: MonitorStore
    @Environment(\.openWindow) private var openWindow
    @State private var newCode = ""
    @State private var selectedWatchGroup = "全部自选"
    @State private var showingGroupEditor = false
    @State private var showingFilterCriteria = false
    @State private var showingGainFilter = false
    @State private var showingDirectionFilter = false
    @AppStorage("dashboard.selectedTab") private var selectedTab = 0
    @AppStorage("dashboard.showSidebar") private var showSidebar = true
    @AppStorage("dashboard.alertLayout") private var alertLayout = "split"
    @AppStorage("dashboard.potentialStrategy") private var potentialStrategy = "all"
    @AppStorage("dashboard.showStrategyLogic") private var showStrategyLogic = false
    @State private var selectedTableQuote: String?
    @State private var selectedAlertIDs = Set<UUID>()
    @State private var selectedAlertLogDate: Date?
    @State private var alertJumpFocus: AlertJumpFocus?
    @State private var limitTypeFilter = "全部"
    @State private var alertIndustryFilter: String?
    @State private var alertSearch = ""
    @FocusState private var searchFocused: Bool

    private var selectedAlertRecords: [AlertRecord] {
        var records = store.alerts
        if let selectedAlertLogDate {
            records = records.filter { Calendar.current.isDate($0.time, inSameDayAs: selectedAlertLogDate) }
        }
        let keyword = alertSearch.trimmingCharacters(in: .whitespaces)
        if !keyword.isEmpty {
            records = records.filter { $0.code.contains(keyword) || $0.name.localizedCaseInsensitiveContains(keyword) || ($0.industry ?? "").localizedCaseInsensitiveContains(keyword) }
        }
        if let alertIndustryFilter {
            records = records.filter { $0.industry == alertIndustryFilter }
        }
        return records
    }
    private var dailyAlertRecords: [AlertRecord] {
        selectedAlertRecords.filter { record in
            guard record.isDailyOrLimit else { return false }
            switch limitTypeFilter {
            case "涨幅": return record.alertType == "daily" || record.alertType == nil
            case "涨停": return record.alertType == "limitUp"
            case "回封": return record.alertType == "limitReseal"
            case "炸板": return record.alertType == "limitOpen"
            case "跌停": return record.alertType == "limitDown"
            default: return true
            }
        }
    }
    private var rapidAlertRecords: [AlertRecord] {
        selectedAlertRecords.filter { $0.alertType == "rapid10" || ($0.alertType == nil && $0.changeBasis != "daily") }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                HStack(spacing: 0) {
                    if showSidebar {
                        watchSidebar
                        Divider()
                    }
                    VStack(spacing: 0) {
                        switch selectedTab {
                        case 1: alertTable
                        case 2: recommendationTable
                        default:
                            quoteToolbar
                            Divider()
                            quoteTable
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                footer
            }
            if store.quotes.isEmpty && store.status.hasPrefix("正在") {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(store.status).font(.headline).foregroundStyle(.secondary)
                }
                .padding(18)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(keyboardShortcuts)
        .overlay(alignment: .bottomLeading) {
            if let toast = store.alertToast {
                alertToastView(toast)
                    .padding(.leading, 14)
                    .padding(.bottom, 42)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: store.alertToast?.id)
        .task {
            while !Task.isCancelled {
                do {
                    store.indexQuotes = try await MarketService.shared.fetchIndexQuotes()
                    store.indexQuotesUpdatedAt = .now
                }
                catch { DebugLog.write("指数行情刷新失败：\(error.localizedDescription)") }
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .onAppear { if selectedTab == 1 { store.markAlertsSeen() } }
        .onChange(of: selectedTab) { tab in
            if tab == 1 { store.markAlertsSeen() }
            if tab == 2 { store.refreshPotential() }
        }
        .onChange(of: store.unseenAlertCount) { _ in if selectedTab == 1 { store.markAlertsSeen() } }
        .onChange(of: store.selectedCode) { code in
            guard let code else { return }
            openWindow(id: "stock-detail", value: code)
            store.selectedCode = nil
        }
        .onChange(of: selectedTableQuote) { code in
            guard let code else { return }
            openWindow(id: "stock-detail", value: code)
            selectedTableQuote = nil
        }
    }

    /// ⌘1/⌘2/⌘3 switch tabs, ⌘F focuses search, ⌘R refreshes, ⌘L toggles the watchlist.
    private var keyboardShortcuts: some View {
        ZStack {
            Button("") { selectedTab = 0 }.keyboardShortcut("1", modifiers: .command)
            Button("") { selectedTab = 1 }.keyboardShortcut("2", modifiers: .command)
            Button("") { selectedTab = 2 }.keyboardShortcut("3", modifiers: .command)
            Button("") { selectedTab = 0; searchFocused = true }.keyboardShortcut("f", modifiers: .command)
            Button("") { store.refresh(); if selectedTab == 2 { store.refreshPotential(force: true) } }.keyboardShortcut("r", modifiers: .command)
            Button("") { withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() } }.keyboardShortcut("l", modifiers: .command)
        }
        .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() } } label: {
                Image(systemName: "sidebar.left").font(.system(size: 14))
            }
            .buttonStyle(.plain).foregroundStyle(showSidebar ? Color.accentColor : Color.secondary)
            .help(showSidebar ? "隐藏自选股栏（⌘L）" : "显示自选股栏（⌘L）")
            HStack(spacing: 6) {
                Image(systemName: "chart.xyaxis.line").font(.title3).foregroundStyle(.red)
                Text("A 股盯盘").font(.headline.bold()).fixedSize()
            }
            tabSwitcher
            indexBar
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索代码 / 名称（⌘F）", text: $store.search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { selectedTab = 0 }
                if !store.search.isEmpty {
                    Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            .frame(minWidth: 150, maxWidth: 240)
            Button { store.refresh(); if selectedTab == 2 { store.refreshPotential(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                .help("立即刷新（⌘R）")
            Button { openWindow(id: "settings") } label: { Image(systemName: "gearshape") }
                .help("监控设置")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private var tabSwitcher: some View {
        HStack(spacing: 2) {
            tabButton(0, title: "行情", icon: "list.bullet.rectangle", badge: nil)
            tabButton(1, title: "告警", icon: "bell", badge: store.unseenAlertCount > 0 ? min(store.unseenAlertCount, 99) : nil)
            tabButton(2, title: "潜力股", icon: "scope", badge: store.potentialStocks(for: "all").isEmpty ? nil : store.potentialStocks(for: "all").count, badgeColor: .orange)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
        .fixedSize()
    }

    private func tabButton(_ tag: Int, title: String, icon: String, badge: Int?, badgeColor: Color = .red) -> some View {
        Button { selectedTab = tag } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 12, weight: selectedTab == tag ? .semibold : .regular))
                if let badge {
                    Text("\(badge)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(badgeColor))
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(selectedTab == tag ? Color(nsColor: .controlBackgroundColor) : .clear))
            .shadow(color: .black.opacity(selectedTab == tag ? 0.12 : 0), radius: 1, y: 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(title)（⌘\(tag + 1)）")
    }

    private var indexBar: some View {
        HStack(spacing: 4) {
            ForEach(["sh000001", "sz399001", "sz399006", "sh000680"], id: \.self) { symbol in
                let index = store.indexQuotes.first { $0.symbol == symbol }
                Button {
                    DebugLog.write("点击指数入口 symbol=\(symbol), name=\(indexTitle(symbol))")
                    openWindow(id: "stock-detail", value: "index:\(symbol)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(indexTitle(symbol)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: 4) {
                            Text(index.map { String(format: "%.2f", $0.price) } ?? "--")
                                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                            Text(index.map { String(format: "%+.2f%%", $0.changePercent) } ?? "--")
                                .font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit()
                        }
                        .foregroundStyle((index?.changePercent ?? 0) >= 0 ? Color.red : Color.green)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.045)))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
    private func indexTitle(_ symbol: String) -> String {
        switch symbol {
        case "sh000001": "上证指数"
        case "sz399001": "深证成指"
        case "sz399006": "创业板指"
        default: "科创综指"
        }
    }

    // MARK: Watchlist sidebar

    private var watchSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("自选股池").font(.headline)
                Text("\(visibleWatchCodes.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { showingGroupEditor.toggle() } label: { Image(systemName: "folder.badge.gearshape") }.buttonStyle(.plain)
                    .help("管理分组")
                    .popover(isPresented: $showingGroupEditor) { WatchGroupEditor(store: store, selectedGroup: $selectedWatchGroup).padding(14).frame(width: 280) }
            }
            Picker("分组", selection: $selectedWatchGroup) {
                Text("全部自选").tag("全部自选")
                ForEach(store.watch.groups.filter { !$0.hasPrefix(WatchData.pickGroupPrefix) }, id: \.self) { Text($0).tag($0) }
                let pickGroups = store.watch.groups.filter { $0.hasPrefix(WatchData.pickGroupPrefix) }.sorted(by: >)
                if !pickGroups.isEmpty {
                    Divider()
                    ForEach(pickGroups, id: \.self) { Text($0).tag($0) }
                }
            }.labelsHidden()
            if let summary = store.picksSummary(forGroup: selectedWatchGroup) {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath").font(.caption2)
                    Text("推荐 \(summary.count) 只 · 上涨 \(summary.winners) 只")
                    if let average = summary.average {
                        Text(String(format: "· 平均 %+.2f%%", average)).foregroundStyle(average >= 0 ? Color.red : Color.green)
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
                .help("自推荐价起算的涨跌幅，便于回溯当日推荐效果")
            }
            HStack(spacing: 6) {
                TextField("输入 6 位代码回车添加", text: $newCode).textFieldStyle(.roundedBorder).onSubmit(add)
                Button(action: add) { Image(systemName: "plus.circle.fill") }.buttonStyle(.plain)
                    .disabled(newCode.filter(\.isNumber).count != 6)
            }
            List {
                ForEach(visibleWatchCodes, id: \.self) { code in
                    watchRow(code)
                        .contextMenu {
                            Button("打开个股详情") { openWindow(id: "stock-detail", value: code) }
                            Button("在行情列表中定位") { focusQuote(code) }
                            Divider()
                            Button(store.watch.blacklist.contains(code) ? "移出黑名单" : "加入黑名单") { store.toggleBlacklist(code) }
                            Button(store.watch.menuBarCodes.contains(code) ? "从状态栏移除" : "添加到状态栏") { store.toggleMenuBarCode(code) }
                            Menu("移动到分组") { ForEach(store.watch.groups, id: \.self) { group in Button(group) { store.moveCode(code, to: group) } } }
                            Divider()
                            Button("移除自选股", role: .destructive) { store.removeCode(code) }
                        }
                        .draggable(code)
                        .dropDestination(for: String.self) { draggedCodes, _ in
                            guard let draggedCode = draggedCodes.first, draggedCode != code else { return false }
                            store.moveWatchCode(draggedCode, before: code, in: selectedWatchGroup)
                            return true
                        }
                        .onTapGesture { openWindow(id: "stock-detail", value: code) }
                }
            }.listStyle(.sidebar)
            Text("单击看详情 · 拖动排序 · 右键更多").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12).frame(width: 220).background(.quaternary.opacity(0.25))
        .transition(.move(edge: .leading))
    }

    private func watchRow(_ code: String) -> some View {
        let quote = watchQuote(code)
        let change = quote?.changePercent ?? 0
        return HStack(spacing: 8) {
            Circle().fill(quote.map { $0.changePercent >= 0 ? Color.red : Color.green } ?? .gray).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) {
                    Text(quote?.name ?? "--").lineLimit(1)
                    if quote?.upperLimit == true {
                        Text(quote?.limitStreak.map { $0 > 1 ? "\($0)板" : "涨停" } ?? "涨停")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 3).background(RoundedRectangle(cornerRadius: 3).fill(Color.red))
                    }
                }
                HStack(spacing: 3) {
                    Text(code).font(.caption.monospaced()).foregroundStyle(.secondary)
                    if let record = store.dailyPick(for: code) {
                        let since = (quote?.price).flatMap { price in record.pick.price > 0 ? (price / record.pick.price - 1) * 100 : nil }
                        Text("荐\(record.pick.initialScore)" + (since.map { String(format: " %+.1f%%", $0) } ?? ""))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle((since ?? 0) >= 0 ? Color.red : Color.green)
                            .help("\(record.day) \(record.pick.time.formatted(date: .omitted, time: .shortened)) 以 \(String(format: "%.2f", record.pick.price)) 推荐，评分 \(record.pick.initialScore)（最新 \(record.pick.score)）；后面为推荐以来涨跌幅")
                    }
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(quote.map { String(format: "%.2f", $0.price) } ?? "—").monospacedDigit()
                Text(quote.map { String(format: "%+.2f%%", $0.changePercent) } ?? "—")
                    .font(.caption).monospacedDigit()
                    .foregroundStyle(change >= 0 ? .red : .green)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: Quote tab

    private var activeFilterCount: Int {
        var count = store.filters.enabled.count
        if store.filters.direction != "全部" { count += 1 }
        if store.industryFilter != "全部行业" { count += 1 }
        if store.conceptFilter != "全部概念" { count += 1 }
        if store.boardFilter != "全部板块" { count += 1 }
        if !store.search.isEmpty { count += 1 }
        return count
    }

    private func resetQuoteFilters() {
        store.filters.enabled.removeAll(); store.filters.direction = "全部"
        store.industryFilter = "全部行业"; store.conceptFilter = "全部概念"; store.boardFilter = "全部板块"
        store.search = ""
    }

    private var quoteToolbar: some View {
        HStack(spacing: 8) {
            Picker(selection: $store.industryFilter) {
                ForEach(store.industries, id: \.self) { Text($0).tag($0) }
            } label: { Text("行业") }
                .pickerStyle(.menu).controlSize(.small).fixedSize()
            Picker(selection: $store.conceptFilter) {
                Text("全部概念").tag("全部概念")
                ForEach(store.concepts, id: \.self) { Text($0).tag($0) }
            } label: { Text("概念") }
                .pickerStyle(.menu).controlSize(.small).fixedSize()
            Picker(selection: $store.boardFilter) {
                Text("全部板块").tag("全部板块"); Text("主板").tag("主板"); Text("科创板").tag("科创板"); Text("创业板").tag("创业板")
            } label: { Text("板块") }
                .pickerStyle(.menu).controlSize(.small).fixedSize()
            Divider().frame(height: 16)
            Button { showingFilterCriteria.toggle() } label: {
                Label(store.filters.enabled.isEmpty ? "数值筛选" : "数值筛选 · \(store.filters.enabled.count)", systemImage: "line.3.horizontal.decrease.circle")
            }
            .controlSize(.small)
            .popover(isPresented: $showingFilterCriteria, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) { NumericFilterPanel(store: store).padding(14).frame(width: 330) }
            Button { showingGainFilter.toggle() } label: { Label("涨幅区间", systemImage: "arrow.up.right.circle") }
                .controlSize(.small)
                .popover(isPresented: $showingGainFilter, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) { GainFilterPanel(store: store).padding(14).frame(width: 300) }
            Button { showingDirectionFilter.toggle() } label: {
                Label(store.filters.direction == "全部" ? "涨/跌/涨停" : "只看\(store.filters.direction)", systemImage: "arrow.up.arrow.down")
            }
            .controlSize(.small)
            .popover(isPresented: $showingDirectionFilter, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                DirectionFilterPanel(store: store).padding(14).frame(width: 220)
            }
            Menu {
                Button("涨幅榜") { store.setSort("changePercent", ascending: false) }
                Button("跌幅榜") { store.setSort("changePercent", ascending: true) }
                Button("量比榜") { store.setSort("volumeRatio", ascending: false) }
                Button("换手榜") { store.setSort("turnover", ascending: false) }
                Button("成交额榜") { store.setSort("amount", ascending: false) }
            } label: { Label("快速排序", systemImage: "arrow.up.and.down.text.horizontal") }
                .menuStyle(.borderlessButton).controlSize(.small).fixedSize()
            Spacer(minLength: 4)
            if activeFilterCount > 0 {
                Button { resetQuoteFilters() } label: { Label("清除 \(activeFilterCount) 个筛选", systemImage: "xmark.circle") }
                    .controlSize(.small).foregroundStyle(.orange)
            }
            Text("\(store.visibleQuotes.count) / \(store.quotes.count) 只").font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 12).padding(.vertical, 6).background(.quaternary.opacity(0.22))
    }

    private var quoteTable: some View {
        GeometryReader { geometry in
            let quotes = store.visibleQuotes
            let quotesByCode = Dictionary(uniqueKeysWithValues: quotes.map { ($0.code, $0) })
            ZStack {
                NativeQuoteTable(
                    quotes: quotes,
                    availableWidth: geometry.size.width,
                    conceptProvider: { code in
                        guard let quote = quotesByCode[code] else { return [] }
                        return tableConcepts(for: quote)
                    },
                    conceptsRevision: store.conceptsRevision,
                    sortKey: store.sortKey,
                    ascending: store.ascending,
                    onSelect: { selectedTableQuote = $0 },
                    focusRequest: alertJumpFocus,
                    onSort: { store.setSort($0, ascending: $1) },
                    isBlacklisted: { store.watch.blacklist.contains($0) },
                    isInMenuBar: { store.watch.menuBarCodes.contains($0) },
                    isInWatchlist: { store.watch.codes.contains($0) },
                    onContextAction: { code, action in
                        switch action {
                        case .openDetail:
                            openWindow(id: "stock-detail", value: code)
                        case .toggleBlacklist:
                            store.toggleBlacklist(code)
                        case .toggleMenuBar:
                            store.toggleMenuBarCode(code)
                        case .toggleWatchlist:
                            if store.watch.codes.contains(code) { store.removeCode(code) }
                            else { store.addCode(code) }
                        }
                    }
                )
                if quotes.isEmpty && !(store.quotes.isEmpty && store.status.hasPrefix("正在")) {
                    VStack(spacing: 8) {
                        Image(systemName: store.quotes.isEmpty ? "arrow.triangle.2.circlepath" : "line.3.horizontal.decrease.circle").font(.largeTitle).foregroundStyle(.secondary)
                        Text(store.quotes.isEmpty ? store.status : "当前筛选条件没有匹配的股票").font(.headline)
                        if !store.quotes.isEmpty { Button("重置所有筛选") { resetQuoteFilters(); store.settings.filterST = false; store.settings.filterSuspended = false } }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(store.quotes.isEmpty)
                }
            }
        }
    }
    private func tableConcepts(for quote: Quote) -> [String] {
        var tags = store.concepts(for: quote.code)
        for tag in (quote.concept ?? "").split(separator: ",").map(String.init) where !tags.contains(tag) { tags.append(tag) }
        return Array(Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private func focusQuote(_ code: String) {
        selectedTab = 0
        store.search = code
        alertJumpFocus = AlertJumpFocus(code: code)
    }

    // MARK: Alert tab

    private var alertTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("布局", selection: $alertLayout) {
                    Text("分栏").tag("split"); Text("涨幅 / 涨停").tag("limit"); Text("速拉").tag("rapid")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Menu {
                    Button("全部日期") { selectedAlertLogDate = nil }
                    if !store.alertLogTradingDays.isEmpty { Divider() }
                    ForEach(store.alertLogTradingDays.reversed(), id: \.self) { day in
                        Button(day.formatted(date: .numeric, time: .omitted)) { selectedAlertLogDate = day }
                    }
                } label: {
                    Label(selectedAlertLogDate?.formatted(date: .numeric, time: .omitted) ?? "全部日期", systemImage: "calendar")
                }
                .menuStyle(.borderlessButton).fixedSize()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("代码 / 名称 / 行业", text: $alertSearch).textFieldStyle(.plain)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                .frame(width: 170)
                if let alertIndustryFilter {
                    Button { self.alertIndustryFilter = nil } label: { Label(alertIndustryFilter, systemImage: "xmark.circle.fill") }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Text("\(selectedAlertRecords.count)/\(store.alerts.count) 条 · 已选 \(selectedAlertIDs.count)").font(.caption).foregroundStyle(.secondary)
                Button(role: .destructive) {
                    store.deleteAlerts(ids: selectedAlertIDs)
                    selectedAlertIDs.removeAll()
                } label: {
                    Label("删除所选", systemImage: "trash")
                }
                .disabled(selectedAlertIDs.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Group {
                switch alertLayout {
                case "limit": limitAlertPanel
                case "rapid": rapidAlertPanel
                default:
                    HSplitView {
                        limitAlertPanel.frame(minWidth: 360)
                        rapidAlertPanel.frame(minWidth: 320)
                    }
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 8)
        }
    }

    private var limitBoardSummary: some View {
        let summary = store.limitSummary
        let emotion = store.potentialReport?.emotion
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                stat("涨停", "\(emotion?.limitUpCount ?? summary.sealed)", .red)
                stat("炸板", "\(emotion?.brokenCount ?? summary.opened)", .orange)
                if let rate = emotion?.brokenRate ?? summary.brokenRate {
                    stat("炸板率", String(format: "%.0f%%", rate), rate > 40 ? .green : .orange)
                }
                stat("跌停", "\(summary.limitDown)", .green)
                stat("最高", "\(max(emotion?.maxStreak ?? 0, summary.maxStreak)) 板", .red)
                if let premium = emotion?.previousPremium {
                    stat("昨涨停溢价", String(format: "%+.1f%%", premium), premium >= 0 ? .red : .green)
                }
                if let mood = emotion?.mood, mood != "未知" {
                    Text("情绪 \(mood)").font(.caption.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(moodColor(mood)))
                }
                Spacer(minLength: 0)
            }
            let industries: [(String, Int)] = emotion.map { $0.topIndustries.map { ($0.name, $0.count) } } ?? summary.topIndustries
            if !industries.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        Text("涨停板块").font(.caption2).foregroundStyle(.secondary)
                        ForEach(industries, id: \.0) { name, count in
                            Button { alertIndustryFilter = alertIndustryFilter == name ? nil : name } label: {
                                Text("\(name) \(count)").font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(alertIndustryFilter == name ? Color.red.opacity(0.25) : Color.red.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                            .help("按「\(name)」筛选日志（东财行业与本地行业口径可能不同）")
                        }
                    }
                }
            }
            if let ladder = emotion?.ladder, !ladder.isEmpty {
                Text("连板梯队：" + ladder.map { "\($0.streak)板×\($0.count)（\($0.names.prefix(2).joined(separator: "、"))）" }.joined(separator: "  "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 5)
    }

    private func stat(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(color).monospacedDigit()
        }
    }

    private func moodColor(_ mood: String) -> Color {
        switch mood { case "高潮": .red; case "回暖": .orange; case "退潮": .green; default: .gray }
    }

    private var limitAlertPanel: some View {
        let records = dailyAlertRecords
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("涨幅 / 涨停").font(.headline)
                Picker("类型", selection: $limitTypeFilter) {
                    ForEach(["全部", "涨幅", "涨停", "回封", "炸板", "跌停"], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                Spacer()
                Text("\(records.count) 条").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            limitBoardSummary
            Table(records, selection: $selectedAlertIDs) {
                TableColumn("时间") { alert in alertClickableCell(alert) { alertTimeCell(alert) } }.width(min: 92, ideal: 104)
                TableColumn("代码") { alert in alertClickableCell(alert) { Text(alert.code).monospaced() } }.width(min: 52, ideal: 56)
                TableColumn("名称") { alert in alertClickableCell(alert) { Text(alert.name).lineLimit(1) } }.width(min: 56, ideal: 68)
                TableColumn("类型") { alert in alertClickableCell(alert) { alertTypeBadge(alert) } }.width(min: 36, ideal: 42)
                TableColumn("连板") { alert in alertClickableCell(alert) { Text(alert.limitStreak.map { $0 > 1 ? "\($0)板" : "首板" } ?? "—").foregroundStyle((alert.limitStreak ?? 0) > 1 ? Color.red : Color.secondary) } }.width(min: 34, ideal: 40)
                TableColumn("涨幅") { alert in alertClickableCell(alert) { alertChangeCell(alert) } }.width(min: 56, ideal: 64)
                TableColumn("价格") { alert in alertClickableCell(alert) { alertSinglePriceCell(alert) } }.width(min: 48, ideal: 56)
                TableColumn("行业") { alert in alertClickableCell(alert) { Text(alert.industry ?? "—").lineLimit(1).foregroundStyle(.secondary) } }.width(min: 48, ideal: 72)
                TableColumn("说明") { alert in alertClickableCell(alert) { Text(alert.detail ?? "—").lineLimit(1).foregroundStyle(.secondary).help(alert.detail ?? "") } }.width(min: 80, ideal: 200)
            }
            .overlay { alertTableEmptyOverlay(records: records, emptyText: store.settings.limitMonitorAll ? "暂无涨幅或涨停告警；交易时段全市场涨停、炸板、回封会自动记录" : "暂无涨幅或涨停告警；当前只记录自选股涨停事件，可在设置中改为全市场") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private var rapidAlertPanel: some View {
        let records = rapidAlertRecords
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("速拉").font(.headline)
                Text("全市场 · \(store.settings.windowSeconds) 秒窗口 · 阈值 \(String(format: "%.1f", store.settings.rapidThreshold))%").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(records.count) 条").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            Table(records, selection: $selectedAlertIDs) {
                TableColumn("时间") { alert in alertClickableCell(alert) { alertTimeCell(alert) } }.width(min: 92, ideal: 104)
                TableColumn("代码") { alert in alertClickableCell(alert) { Text(alert.code).monospaced() } }.width(min: 52, ideal: 56)
                TableColumn("名称") { alert in alertClickableCell(alert) { Text(alert.name).lineLimit(1) } }.width(min: 56, ideal: 68)
                TableColumn("区间涨幅") { alert in alertClickableCell(alert) { alertChangeCell(alert) } }.width(min: 56, ideal: 66)
                TableColumn("起始") { alert in alertClickableCell(alert) { alertPriceCell(change: alert.startChangePercent, price: alert.startPrice) } }.width(min: 80, ideal: 90)
                TableColumn("触发") { alert in alertClickableCell(alert) { alertPriceCell(change: alert.triggerChangePercent, price: alert.price) } }.width(min: 80, ideal: 90)
                TableColumn("行业") { alert in alertClickableCell(alert) { Text(alert.industry ?? "—").lineLimit(1).foregroundStyle(.secondary) } }.width(min: 48, ideal: 70)
                TableColumn("说明") { alert in alertClickableCell(alert) { Text(alert.detail ?? "—").lineLimit(1).foregroundStyle(.secondary).help(alert.detail ?? "") } }.width(min: 70, ideal: 170)
            }
            .overlay { alertTableEmptyOverlay(records: records, emptyText: "暂无速拉告警") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }

    private func alertTypeBadge(_ alert: AlertRecord) -> some View {
        let label = AlertRecord.typeLabel(alert.alertType)
        let color: Color
        switch alert.alertType ?? "" {
        case "limitUp", "limitReseal": color = .red
        case "limitOpen": color = .orange
        case "limitDown": color = .green
        default: color = .secondary
        }
        return Text(label).font(.caption.bold()).foregroundStyle(color)
    }
    private func alertClickableCell<Content: View>(_ alert: AlertRecord, @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(alert.silent == true ? 0.85 : 1)
            .simultaneousGesture(TapGesture(count: 2).onEnded { jumpToAlertStock(alert) })
            .contextMenu {
                Button("打开个股详情") { openWindow(id: "stock-detail", value: alert.code) }
                Button("在行情列表中定位") { jumpToAlertStock(alert) }
                Button(store.watch.codes.contains(alert.code) ? "移出自选" : "加入自选") {
                    if store.watch.codes.contains(alert.code) { store.removeCode(alert.code) } else { store.addCode(alert.code) }
                }
                Divider()
                Button("删除此条告警", systemImage: "trash", role: .destructive) { store.deleteAlerts(ids: [alert.id]); selectedAlertIDs.remove(alert.id) }
            }
    }
    private func jumpToAlertStock(_ alert: AlertRecord) {
        focusQuote(alert.code)
        DebugLog.write("告警日志双击个股，跳转主行情：code=\(alert.code), name=\(alert.name)")
    }
    private func alertTimeCell(_ alert: AlertRecord) -> some View {
        HStack(spacing: 4) {
            if selectedAlertLogDate == nil && !Calendar.current.isDateInToday(alert.time) {
                Text(alert.time.formatted(.dateTime.month(.twoDigits).day(.twoDigits))).foregroundStyle(.secondary)
            }
            Text(alert.time.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))).monospacedDigit()
        }
    }
    private func alertChangeCell(_ alert: AlertRecord) -> some View {
        let marketChange = alert.triggerChangePercent ?? alert.change
        return HStack(spacing: 3) {
            if alert.alertType == nil && alert.changeBasis == nil {
                Text("旧").font(.caption2).foregroundStyle(.secondary)
            }
            Text(String(format: "%+.2f%%", alert.change)).foregroundStyle(marketChange >= 0 ? .red : .green).monospacedDigit()
        }
    }
    private func alertPriceCell(change: Double?, price: Double?) -> some View {
        let changeColor: Color = change.map { $0 >= 0 ? .red : .green } ?? .secondary
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(change.map { String(format: "%+.2f%%", $0) } ?? "—")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(changeColor)
            Text(price.map { String(format: "¥%.2f", $0) } ?? "—")
                .font(.system(size: 9))
                .foregroundStyle(changeColor.opacity(0.8))
                .fixedSize()
        }
        .lineLimit(1)
    }
    private func alertSinglePriceCell(_ alert: AlertRecord) -> some View {
        Text(String(format: "%.2f", alert.price)).monospacedDigit()
            .foregroundStyle(alert.change >= 0 ? Color.red : Color.green)
    }
    @ViewBuilder private func alertTableEmptyOverlay(records: [AlertRecord], emptyText: String) -> some View {
        if records.isEmpty {
            Text(emptyText).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 320).allowsHitTesting(false)
        }
    }

    // MARK: Potential tab

    private var strategies: [PotentialStrategy] {
        store.potentialReport?.strategies ?? []
    }
    private var currentStrategy: PotentialStrategy? {
        strategies.first { $0.id == potentialStrategy } ?? strategies.first
    }
    private var currentPotentialStocks: [PotentialStock] {
        store.potentialStocks(for: currentStrategy?.id ?? potentialStrategy)
    }

    private var recommendationTable: some View {
        VStack(spacing: 0) {
            strategyBar
            Divider()
            potentialHeader
            HStack(spacing: 8) {
                Text("名称 / 行业").frame(width: 138, alignment: .leading)
                Text("评分").frame(width: 58, alignment: .leading)
                Text("现价").frame(width: 66, alignment: .leading)
                Text("近3分钟").frame(width: 58, alignment: .leading)
                Text("关键指标").frame(width: 128, alignment: .leading)
                Text("观察位 / 止损").frame(width: 112, alignment: .leading)
                Text("信号 / 风险").frame(maxWidth: .infinity, alignment: .leading)
            }.font(.caption.bold()).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6).background(.quaternary.opacity(0.3))
            if currentPotentialStocks.isEmpty {
                potentialEmptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(currentPotentialStocks) { stock in
                            potentialRow(stock)
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .onAppear { store.refreshPotential() }
    }

    private var strategyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if strategies.isEmpty {
                    Text("正在加载选股策略…").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                ForEach(strategies) { strategy in
                    let selected = strategy.id == (currentStrategy?.id ?? "")
                    Button { potentialStrategy = strategy.id } label: {
                        HStack(spacing: 6) {
                            Image(systemName: strategy.icon).font(.system(size: 12))
                                .foregroundStyle(selected ? Color.white : strategyColor(strategy.id))
                            VStack(alignment: .leading, spacing: 0) {
                                HStack(spacing: 4) {
                                    Text(strategy.title).font(.system(size: 12, weight: .semibold))
                                    Text("\(strategy.count)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                                }
                                Text(strategy.summary).font(.system(size: 9)).lineLimit(1)
                                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                            }
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .frame(maxWidth: 210, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? strategyColor(strategy.id) : Color.primary.opacity(0.05)))
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(strategy.description)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
    }

    private func strategyColor(_ id: String) -> Color {
        switch id {
        case "surge": .orange
        case "limit": .red
        case "trend": .blue
        case "pullback": .teal
        case "leader": .purple
        case "tail": .indigo
        default: .pink
        }
    }

    private var potentialHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                if let market = store.potentialReport?.market {
                    Label("市场\(market.regime)", systemImage: regimeIcon(market.regime))
                        .font(.caption.bold()).foregroundStyle(regimeColor(market.regime))
                    Text("涨 \(market.upCount) / 跌 \(market.downCount) · 中位 \(String(format: "%+.2f%%", market.medianChange)) · 涨停 \(market.limitUpCount) · 跌停 \(market.limitDownCount)")
                    if !market.strongIndustries.isEmpty {
                        Text("领涨：" + market.strongIndustries.prefix(3).joined(separator: "、")).lineLimit(1)
                    }
                }
                if let emotion = store.potentialReport?.emotion, emotion.mood != "未知" {
                    Text("打板情绪 \(emotion.mood)" + (emotion.brokenRate.map { String(format: " · 炸板率 %.0f%%", $0) } ?? ""))
                        .foregroundStyle(moodColor(emotion.mood))
                }
                Spacer()
                if let report = store.potentialReport, report.scanning {
                    ProgressView(value: Double(report.progress), total: Double(max(report.total, 1))).frame(width: 80)
                    Text("\(report.phase ?? "复核日线") \(report.progress)/\(report.total)").monospacedDigit()
                } else if let updated = potentialUpdatedText {
                    Text("日线复核 \(updated)")
                }
                Button { store.refreshPotential(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("立即重新扫描全市场")
            }
            .font(.caption).foregroundStyle(.secondary)
            if let note = currentStrategy?.note {
                Label(note, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
            }
            if store.potentialReport?.market?.regime == "弱势" {
                Text("弱势市场：各策略评分已统一打折。宜轻仓、只看 A 级，或空仓观望。")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let strategy = currentStrategy {
                DisclosureGroup(isExpanded: $showStrategyLogic) {
                    Text(strategy.description + " 评分 0–100，≥ 75 为 A、≥ 60 为 B。仅为规则化选股参考，不构成买入建议。")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                } label: {
                    Text("「\(strategy.title)」选股逻辑").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
    @ViewBuilder private var potentialEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: currentStrategy?.icon ?? "scope").font(.largeTitle).foregroundStyle(.secondary)
            if let error = store.potentialReport?.error ?? store.potentialError, store.potentialReport?.stocks.isEmpty ?? true {
                Text("潜力股扫描失败").font(.headline)
                Text(error).textSelection(.enabled)
            } else if store.potentialReport == nil {
                Text(store.quotes.isEmpty ? "等待全市场行情" : "正在请求选股结果…").font(.headline)
            } else if let report = store.potentialReport, report.scanning, ["trend", "pullback"].contains(currentStrategy?.id ?? "") {
                Text("正在拉取候选股日线…").font(.headline)
                Text("首次需要逐只拉取约 200 只候选股的日 K，通常 1–3 分钟；之后当天有磁盘缓存会快很多。")
            } else {
                Text("「\(currentStrategy?.title ?? "当前策略")」暂无达标个股").font(.headline)
                Text(currentStrategy?.id == "surge"
                     ? "速拉需要盘中连续快照：交易时段保持应用运行，出现 5 分钟内拉升 ≥ 1.8% 的个股后会自动出现在这里。"
                     : "没有明确形态时空仓也是一种操作。交易时段每 5 分钟、收盘后每 30 分钟自动重扫，实时策略每 15 秒更新。")
            }
        }
        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 460)
    }
    private var potentialUpdatedText: String? {
        guard let raw = store.potentialReport?.updatedAt, let date = ISO8601DateFormatter().date(from: raw) else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }
    private func regimeIcon(_ regime: String) -> String {
        switch regime { case "强势": "flame.fill"; case "弱势": "cloud.rain.fill"; default: "arrow.left.and.right" }
    }
    private func regimeColor(_ regime: String) -> Color {
        switch regime { case "强势": .red; case "弱势": .green; default: .orange }
    }
    private func gradeColor(_ grade: String) -> Color {
        switch grade { case "A": .red; case "B": .orange; default: .gray }
    }
    private func strategyTitle(_ id: String) -> String {
        strategies.first { $0.id == id }?.title ?? id
    }
    private func potentialRow(_ stock: PotentialStock) -> some View {
        let live = store.quote(for: stock.code)
        let price = live?.price ?? stock.price
        let change = live?.changePercent ?? stock.changePercent
        let recent = store.recentChange(for: stock.code)
        let inWatchlist = store.watch.codes.contains(stock.code)
        let stopText: String = stock.stopLoss.map { stop in
            String(format: "止损 %.2f", stop) + (stock.riskPercent.map { String(format: "（-%.1f%%）", $0) } ?? "")
        } ?? "—"
        let highlights = stock.highlights ?? [
            stock.amountRatio.map { String(format: "额比 %.1f", $0) } ?? "额比 —",
            stock.ret20.map { String(format: "20日 %+.1f%%", $0) } ?? ""
        ]
        let tags = stock.tags ?? []
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Button {
                        if inWatchlist { store.removeCode(stock.code) } else { store.addCode(stock.code) }
                    } label: {
                        Image(systemName: inWatchlist ? "star.fill" : "star").font(.system(size: 10))
                            .foregroundStyle(inWatchlist ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain).help(inWatchlist ? "移出自选" : "加入自选（启用涨幅、涨停、炸板告警）")
                    Text(stock.name).lineLimit(1).font(.system(size: 12, weight: .medium))
                }
                Text("\(stock.code) · \(stock.industry ?? "—")").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: 138, alignment: .leading)
            HStack(spacing: 5) {
                Text(stock.grade).font(.caption.bold()).foregroundStyle(.white)
                    .frame(width: 18, height: 18).background(gradeColor(stock.grade), in: RoundedRectangle(cornerRadius: 4))
                Text("\(stock.score)").font(.system(.body, design: .rounded).bold())
            }.frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.2f", price)).monospacedDigit()
                Text(String(format: "%+.2f%%", change)).font(.caption).monospacedDigit().foregroundStyle(change >= 0 ? Color.red : Color.green)
            }.frame(width: 66, alignment: .leading)
            Text(recent.map { String(format: "%+.2f%%", $0) } ?? "—").monospacedDigit()
                .foregroundStyle((recent ?? 0) >= 0 ? Color.red : Color.green)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(highlights.prefix(3).enumerated()), id: \.offset) { index, text in
                    Text(text).font(index == 0 ? .system(size: 11) : .caption2)
                        .foregroundStyle(index == 0 ? Color.primary : Color.secondary).lineLimit(1)
                }
            }.frame(width: 128, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(stock.pivot.map { String(format: "观察 %.2f", $0) } ?? "—")
                Text(stopText).font(.caption2).foregroundStyle(.green)
            }.monospacedDigit().frame(width: 112, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                if !tags.isEmpty || (stock.strategies?.count ?? 0) > 1 {
                    HStack(spacing: 4) {
                        ForEach(Array(tags.prefix(5).enumerated()), id: \.offset) { _, tag in
                            Text(tag).font(.system(size: 9, weight: .medium))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(tagColor(tag).opacity(0.15)))
                                .foregroundStyle(tagColor(tag))
                        }
                    }
                }
                Text(stock.signals.joined(separator: " · ")).lineLimit(2)
                if !stock.risks.isEmpty {
                    Label(stock.risks.joined(separator: " · "), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).lineLimit(1)
                }
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { openWindow(id: "stock-detail", value: stock.code) }
        .help("单击打开个股详情，右键更多操作")
        .contextMenu {
            Button("打开个股详情") { openWindow(id: "stock-detail", value: stock.code) }
            Button("在行情列表中定位") { focusQuote(stock.code) }
            Button(inWatchlist ? "移出自选" : "加入自选（启用涨幅、涨停、炸板告警）") {
                if inWatchlist { store.removeCode(stock.code) } else { store.addCode(stock.code) }
            }
            Button(store.watch.menuBarCodes.contains(stock.code) ? "从状态栏移除" : "添加到状态栏") { store.toggleMenuBarCode(stock.code) }
            Divider()
            Button("加入黑名单（不再推荐）", role: .destructive) { store.toggleBlacklist(stock.code) }
        }
    }
    private func tagColor(_ tag: String) -> Color {
        if let strategy = strategies.first(where: { $0.title == tag }) { return strategyColor(strategy.id) }
        if tag.contains("板") || tag.contains("涨停") || tag == "回封" { return .red }
        if tag == "炸板" || tag == "预览" || tag.contains("水下") { return .orange }
        return .blue
    }

    // MARK: Footer & toast

    private var footer: some View {
        HStack(spacing: 8) {
            Circle().fill(store.status.hasPrefix("已连接") ? .green : .orange).frame(width: 7)
            if !(store.quotes.isEmpty && store.status.hasPrefix("正在")) { Text(store.status).lineLimit(1) }
            Spacer()
            Text("涨幅 ≥ \(String(format: "%.1f", store.settings.threshold))% · 速拉 \(store.settings.windowSeconds) 秒 ≥ \(String(format: "%.1f", store.settings.rapidThreshold))% · 涨停监控 \(store.settings.limitMonitorAll ? "全市场" : "自选")")
                .foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.caption).padding(.horizontal, 14).padding(.vertical, 6).background(.quaternary.opacity(0.35))
    }

    private func toastIcon(_ type: String) -> String {
        switch type {
        case "速拉": "bolt.fill"
        case "涨停", "回封": "arrow.up.to.line.compact"
        case "炸板": "exclamationmark.triangle.fill"
        case "跌停": "arrow.down.to.line.compact"
        case "当日推荐": "star.fill"
        case "推荐替换": "arrow.triangle.swap"
        default: "arrow.up.right.circle.fill"
        }
    }
    private func alertToastView(_ toast: AlertToast) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toastIcon(toast.shortType))
                .font(.title3).foregroundStyle(toast.shortType == "速拉" || toast.shortType == "炸板" ? Color.orange : (toast.shortType == "跌停" ? Color.green : Color.red))
            VStack(alignment: .leading, spacing: 4) {
                Text(toast.shortType).font(.caption.bold())
                HStack(spacing: 6) {
                    Text(toast.name).font(.subheadline.bold()).lineLimit(1)
                    Text(toast.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Text(toast.effect).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
        .frame(maxWidth: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.10)))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onTapGesture { openWindow(id: "stock-detail", value: toast.code) }
        .help("点击查看个股详情")
    }
    private var visibleWatchCodes: [String] {
        selectedWatchGroup == "全部自选" ? store.watch.codes : store.watch.codes.filter { (store.watch.groupByCode[$0] ?? store.watch.groups.first ?? "默认分组") == selectedWatchGroup }
    }
    private func add() { store.addCode(newCode, toGroup: selectedWatchGroup == "全部自选" ? (store.watch.groups.first ?? "默认分组") : selectedWatchGroup); newCode = "" }
    private func watchQuote(_ code: String) -> Quote? { store.quote(for: code) }
}

private struct WatchGroupEditor: View {
    @ObservedObject var store: MonitorStore
    @Binding var selectedGroup: String
    @State private var newName = ""
    @State private var renamingGroup = ""
    @State private var renameText = ""
    @State private var showingRename = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自选股分组").font(.headline)
            HStack {
                TextField("新分组名称", text: $newName).textFieldStyle(.roundedBorder).onSubmit(add)
                Button("添加", action: add).disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            ForEach(Array(store.watch.groups), id: \.self) { group in
                HStack {
                    Text(group).lineLimit(1)
                    Spacer()
                    Text(store.watch.codes.filter { (store.watch.groupByCode[$0] ?? store.watch.groups.first ?? "默认分组") == group }.count, format: .number)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .contextMenu {
                    Button("重命名分组") {
                        renamingGroup = group
                        renameText = group
                        showingRename = true
                    }
                    Button("删除分组", role: .destructive) { remove(group) }
                        .disabled(store.watch.groups.count <= 1)
                }
            }
            Text("右击分组可重命名或删除；删除后组内股票移入其他分组。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .alert("重命名分组", isPresented: $showingRename) {
            TextField("分组名称", text: $renameText)
            Button("保存") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                store.renameGroup(renamingGroup, to: trimmed)
                if selectedGroup == renamingGroup { selectedGroup = trimmed }
            }
            Button("取消", role: .cancel) {}
        }
    }
    private func add() {
        if let name = store.addGroup(newName) { selectedGroup = name }
        newName = ""
    }
    private func remove(_ name: String) {
        let replacement = store.watch.groups.first(where: { $0 != name }) ?? "全部自选"
        store.deleteGroup(name)
        if selectedGroup == name { selectedGroup = replacement }
    }
}

private struct QuoteRow: View {
    let quote: Quote
    @ObservedObject var store: MonitorStore
    let columnWidths: [CGFloat]
    private func compactYuan(_ value: Double?) -> String {
        guard let value else { return "—" }
        let magnitude = abs(value)
        let formatted: String
        if magnitude >= 100_000_000 { formatted = String(format: "%.1f亿", magnitude / 100_000_000) }
        else if magnitude >= 10_000 { formatted = String(format: "%.0f万", magnitude / 10_000) }
        else { formatted = String(format: "%.0f元", magnitude) }
        return value < 0 ? "-\(formatted)" : formatted
    }
    @Environment(\.openWindow) private var openWindow
    private var highlighted: Bool { store.alerts.contains { $0.code == quote.code && Date().timeIntervalSince($0.time) < 180 } }
    private var visibleConcepts: [String] {
        var tags = store.concepts(for: quote.code)
        for tag in (quote.concept ?? "").split(separator: ",").map(String.init) where !tags.contains(tag) { tags.append(tag) }
        return Array(Set(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Text(quote.code).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).fixedSize(horizontal: true, vertical: false).frame(width: columnWidths[0], alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(quote.name)
                        if quote.isST { Text("ST").font(.caption2).foregroundStyle(.orange) }
                        if quote.upperLimit { Text("涨停").font(.caption2).foregroundStyle(.red) }
                        if quote.lowerLimit { Text("跌停").font(.caption2).foregroundStyle(.green) }
                    }.lineLimit(1)
                }.frame(width: columnWidths[1], alignment: .leading)
                Text(quote.price, format: .number.precision(.fractionLength(2))).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).frame(width: columnWidths[2], alignment: .leading)
                Text(String(format: "%+.2f%%", quote.changePercent)).foregroundStyle(quote.changePercent >= 0 ? .red : .green).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).frame(width: columnWidths[3], alignment: .leading)
                Text(quote.volumeRatio.map { String(format: "%.2f", $0) } ?? "—").monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).frame(width: columnWidths[4], alignment: .leading)
                Text(quote.turnover.map { String(format: "%.2f%%", $0) } ?? "—").monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).frame(width: columnWidths[5], alignment: .leading)
                Text(quote.amount.formatted(.number.notation(.compactName))).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).frame(width: columnWidths[6], alignment: .leading)
                Text(compactYuan(quote.totalMarketCap)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).frame(width: columnWidths[7], alignment: .leading)
                Text(compactYuan(quote.floatMarketCap)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).frame(width: columnWidths[8], alignment: .leading)
                Text(compactYuan(quote.annualNetProfit)).monospacedDigit().foregroundStyle((quote.annualNetProfit ?? 0) < 0 ? .green : .primary).lineLimit(1).minimumScaleFactor(0.8).frame(width: columnWidths[9], alignment: .leading)
                Text(compactYuan(quote.quarterlyNetProfit)).monospacedDigit().foregroundStyle((quote.quarterlyNetProfit ?? 0) < 0 ? .green : .primary).lineLimit(1).minimumScaleFactor(0.8).frame(width: columnWidths[10], alignment: .leading)
                Text(quote.industry ?? "—").foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).frame(width: columnWidths[11], alignment: .leading)
                Text(visibleConcepts.isEmpty ? "—" : visibleConcepts.joined(separator: "、"))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .frame(width: columnWidths[12], alignment: .topLeading)
            }.font(.system(size: 12)).padding(.horizontal, 12).padding(.vertical, 8)
                .background(highlighted ? Color.red.opacity(0.10) : Color.clear)
                .contentShape(Rectangle()).onTapGesture { openWindow(id: "stock-detail", value: quote.code) }
                .contextMenu {
                    Button("查看分时图") { openWindow(id: "stock-detail", value: quote.code) }
                    Button(store.watch.blacklist.contains(quote.code) ? "移出黑名单" : "加入黑名单") { store.toggleBlacklist(quote.code) }
                    Button(store.watch.menuBarCodes.contains(quote.code) ? "从状态栏移除" : "添加到状态栏") { store.toggleMenuBarCode(quote.code) }
                    if store.watch.codes.contains(quote.code) {
                        Button("从监控自选池移除", role: .destructive) { store.removeCode(quote.code) }
                    } else {
                        Button("加入监控自选池") { store.addCode(quote.code) }
                    }
                }
            Divider().padding(.leading, 12)
        }
    }
}

struct StockDetailView: View {
    @ObservedObject var store: MonitorStore
    let code: String
    @State private var points: [PricePoint] = []
    @State private var fiveDayPoints: [PricePoint] = []
    @State private var candles: [CandlePoint] = []
    @State private var historyError = ""
    @State private var historyLoading = true
    @State private var historyRequestID = UUID()
    @State private var chartLoadTask: Task<Void, Never>?
    @State private var historyRange = "intraday"
    private var historyRangeTitle: String {
        switch historyRange {
        case "intraday": "分时"
        case "5d": "近 5 日"
        case "1m": "近 1 个月"
        case "3m": "近 3 个月"
        case "all": "全部历史"
        default: "近一年"
        }
    }
    private var quote: Quote? { store.quote(for: code) }
    private var displayPoints: [PricePoint] {
        let today = Calendar.current.startOfDay(for: .now)
        let source = points.isEmpty ? [] : points
        let liveSamples = store.priceHistory(for: code).filter {
            Calendar.current.startOfDay(for: $0.date) == today
        }
        // The service provides today's minute history; live market polling
        // contributes newer points while this detail window remains open.
        let samples = (source + liveSamples).filter {
            Calendar.current.startOfDay(for: $0.date) == today
        }.sorted { $0.date < $1.date }
        guard samples.count == 1, let only = samples.first else { return samples }
        return [PricePoint(date: only.date.addingTimeInterval(-60), price: only.price), only]
    }
    private var usingLocalSamples: Bool { points.isEmpty && !displayPoints.isEmpty }
    private var intradayChartPoints: [IntradayChartPoint] {
        var pointsByMinute: [Int: IntradayChartPoint] = [:]
        for point in displayPoints.sorted(by: { $0.date < $1.date }) {
            let time = Calendar.current.dateComponents([.hour, .minute], from: point.date)
            guard let hour = time.hour, let minute = time.minute else { continue }
            let minuteOfDay = hour * 60 + minute
            let sessionMinute: Double
            if (570...690).contains(minuteOfDay) {
                sessionMinute = Double(minuteOfDay - 570)
            } else if (780...900).contains(minuteOfDay) {
                // Collapse lunch. Offset the afternoon by half a chart minute
                // so 13:00 does not share the exact x coordinate of 11:30.
                sessionMinute = 120.5 + Double(minuteOfDay - 780) * 119.5 / 120
            } else {
                continue
            }
            // Poll samples and source minute bars can share an x coordinate.
            // Keep the newest value at each chart minute to avoid vertical spikes.
            pointsByMinute[Int(sessionMinute.rounded())] = IntradayChartPoint(
                id: point.id, sessionMinute: sessionMinute, price: point.price)
        }
        let points = pointsByMinute.keys.sorted().compactMap { pointsByMinute[$0] }
        guard let first = points.first, first.sessionMinute > 0 else { return points }
        // Anchor the trace at the 09:30 market open using the first available
        // quote, so the chart starts at the left edge instead of looking cropped.
        return [IntradayChartPoint(id: UUID(), sessionMinute: 0, price: first.price)] + points
    }
    // Swift Charts creates multiple marks per candle. Limit the all-history
    // rendering workload while retaining each bucket's OHLC extremes.
    private var chartCandles: [CandlePoint] {
        guard candles.count > 900 else { return candles }
        let bucketSize = Int(ceil(Double(candles.count) / 900.0))
        return stride(from: 0, to: candles.count, by: bucketSize).compactMap { start in
            let bucket = Array(candles[start..<min(start + bucketSize, candles.count)])
            guard let first = bucket.first, let last = bucket.last else { return nil }
            return CandlePoint(date: last.date, open: first.open,
                               high: bucket.map(\.high).max() ?? first.high,
                               low: bucket.map(\.low).min() ?? first.low,
                               close: last.close)
        }
    }
    private var indexedCandles: [IndexedCandleChartPoint] {
        chartCandles.enumerated().map { IndexedCandleChartPoint(id: $0.element.id, index: Double($0.offset), candle: $0.element) }
    }
    private var candleXDomain: ClosedRange<Double> {
        let lastIndex = Double(max(chartCandles.count - 1, 1))
        // Leave a little room for the first and last date labels at the edges.
        return -0.6...(lastIndex + 0.6)
    }
    private var candleAxisIndices: [Double] {
        guard !chartCandles.isEmpty else { return [] }
        guard chartCandles.count > 1 else { return [0] }
        if historyRange == "3m" {
            // Keep the first and last labels visible, with one label every
            // three trading days between them.
            var indices = Array(stride(from: 0, to: chartCandles.count, by: 3))
            let last = chartCandles.count - 1
            if indices.last != last { indices.append(last) }
            return indices.map(Double.init)
        }
        if historyRange == "1m" {
            // Give each trading day an equal-width position on the time axis.
            return chartCandles.indices.map(Double.init)
        }
        let indices = (0..<5).map { Int((Double(chartCandles.count - 1) * Double($0) / 4).rounded()) }
        return Array(Set(indices)).sorted().map(Double.init)
    }
    private var candleDateByIndex: [Int: Date] {
        Dictionary(uniqueKeysWithValues: chartCandles.enumerated().map { ($0.offset, $0.element.date) })
    }
    private var fiveDayDates: [Date] {
        Array(Set(fiveDayPoints.map { Calendar.current.startOfDay(for: $0.date) })).sorted()
    }
    private var fiveDayChartPoints: [FiveDayTrendChartPoint] {
        let days = fiveDayDates
        return fiveDayPoints.sorted { $0.date < $1.date }.compactMap { point in
            let date = Calendar.current.startOfDay(for: point.date)
            guard let dayIndex = days.firstIndex(of: date) else { return nil }
            let time = Calendar.current.dateComponents([.hour, .minute], from: point.date)
            guard let hour = time.hour, let minute = time.minute else { return nil }
            let minuteOfDay = hour * 60 + minute
            let withinSession: Double
            if (570...690).contains(minuteOfDay) {
                withinSession = Double(minuteOfDay - 570)
            } else if (780...900).contains(minuteOfDay) {
                withinSession = Double(120 + minuteOfDay - 780)
            } else {
                return nil
            }
            // Collapse lunch and keep a small, even gap between trading days.
            return FiveDayTrendChartPoint(id: point.id, sessionIndex: Double(dayIndex) * 260 + withinSession, price: point.price)
        }
    }
    private var fiveDayXDomain: ClosedRange<Double> {
        0...Double(max(fiveDayDates.count, 1) * 260)
    }
    private var fiveDayAxisPositions: [Double] {
        // Place the day divider and its label at the left edge (09:30) of
        // each session instead of centering it over the day's data.
        fiveDayDates.indices.map { Double($0) * 260 }
    }
    private var fiveDayDomain: ClosedRange<Double> {
        let values = fiveDayPoints.map(\.price) + (quote.map { [$0.price] } ?? [])
        let low = values.min() ?? 0; let high = values.max() ?? low
        let margin = max((high - low) * 0.08, max(abs(low) * 0.001, 0.01))
        let upper = high + margin
        let lower = max(0, low - max((high - low) * 0.02, abs(low) * 0.0005))
        return lower...upper
    }
    private var intradayDomain: ClosedRange<Double> {
        let values = displayPoints.map(\.price) + (quote.map { [$0.price] } ?? []) + (intradayZeroPercentPrice.map { [$0] } ?? [])
        let low = values.min() ?? 0; let high = values.max() ?? low
        let margin = max((high - low) * 0.18, max(abs(low) * 0.001, 0.01))
        let upper = high + margin
        let lower = max(0, low - max((high - low) * 0.02, abs(low) * 0.0005))
        return lower...upper
    }
    /// The quote's change is measured from the previous close. Convert that
    /// reference to a price so the intraday chart can mark the 0% level.
    private var intradayZeroPercentPrice: Double? {
        guard let quote, quote.price > 0 else { return nil }
        let divisor = 1 + quote.changePercent / 100
        guard divisor > 0 else { return nil }
        return quote.price / divisor
    }
    private var candleDomain: ClosedRange<Double> {
        let low = candles.map(\.low).min() ?? 0; let high = candles.map(\.high).max() ?? low
        let margin = max((high - low) * 0.06, max(abs(low) * 0.005, 0.01))
        let upper = high + margin
        let lower = max(0, low - max((high - low) * 0.02, abs(low) * 0.0005))
        return lower...upper
    }
    private var trendColor: Color {
        let rising = quote.map { $0.changePercent >= 0 } ?? ((displayPoints.last?.price ?? 0) >= (displayPoints.first?.price ?? 0))
        return rising ? .red : .green
    }
    var body: some View {
        GeometryReader { geometry in
        // Keep the chart proportional to the actual window height. The compact
        // floor prevents short windows from turning into a mostly-empty canvas.
        let chartHeight = min(560, max(190, geometry.size.height - 180))
        VStack(alignment: .leading, spacing: 10) {
            HStack { VStack(alignment: .leading) { Text(quote?.name ?? code).font(.title2.bold()); Text(code).foregroundStyle(.secondary) }; Spacer(); if let q = quote { VStack(alignment: .trailing) { Text(String(format: "¥%.2f", q.price)).font(.title2); Text(String(format: "%+.2f%%", q.changePercent)).foregroundStyle(q.changePercent >= 0 ? .red : .green) } } }
            HStack {
                Picker("周期", selection: $historyRange) {
                    Text("分时").tag("intraday"); Text("5日").tag("5d"); Text("一月").tag("1m")
                    Text("3月").tag("3m"); Text("一年").tag("year"); Text("全部").tag("all")
                }
                .pickerStyle(.segmented)
                .fixedSize(horizontal: true, vertical: false)
                Spacer()
            }
            if historyLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在加载行情历史…").font(.headline)
                }.frame(maxWidth: .infinity).frame(height: chartHeight)
            } else if (historyRange == "intraday" && displayPoints.isEmpty) || (historyRange == "5d" && fiveDayPoints.isEmpty) || (historyRange != "intraday" && historyRange != "5d" && candles.isEmpty) {
                VStack(spacing: 10) {
                    Image(systemName: "chart.xyaxis.line").font(.largeTitle).foregroundStyle(.secondary)
                    Text(historyError.isEmpty ? "正在加载行情历史…" : "历史行情暂不可用").font(.headline)
                    Text(historyError.isEmpty ? "首次加载可能需要一点时间。" : historyError).font(.caption).foregroundStyle(.secondary)
                    Button("重试") { Task { await loadSelectedChart() } }
                }.frame(maxWidth: .infinity).frame(height: chartHeight)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if historyRange == "intraday" {
                        Text(usingLocalSamples ? "本地实时采样 · \(intradayChartPoints.count) 个点" : "分时走势 · \(intradayChartPoints.count) 个点 · 午休时段折叠")
                            .font(.caption).foregroundStyle(.secondary)
                        Chart(intradayChartPoints) { point in
                            if let zeroPrice = intradayZeroPercentPrice {
                                RuleMark(y: .value("0%（昨收）", zeroPrice))
                                    .foregroundStyle(Color.primary.opacity(0.72))
                                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                                    .annotation(position: .trailing, alignment: .top, spacing: 5) {
                                        Text("0%")
                                            .font(.caption2.bold())
                                            .foregroundStyle(Color.primary)
                                            .padding(.horizontal, 4).padding(.vertical, 2)
                                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                                    }
                            }
                            LineMark(x: .value("交易时间", point.sessionMinute), y: .value("价格", point.price), series: .value("时段", "全天"))
                                .foregroundStyle(trendColor).lineStyle(StrokeStyle(lineWidth: 2))
                            AreaMark(x: .value("交易时间", point.sessionMinute), y: .value("价格", point.price), series: .value("时段", "全天"))
                                .foregroundStyle(trendColor.opacity(0.08))
                        }
                        .chartXScale(domain: 0...240)
                            .chartXAxis {
                                AxisMarks(values: [0.0, 60.0, 120.0, 180.0, 240.0]) { value in
                                    AxisGridLine(); AxisTick()
                                    AxisValueLabel {
                                        if let minute = value.as(Double.self) {
                                            Text(minute == 0 ? "09:30" : minute == 60 ? "10:30" : minute == 120 ? "11:30" : minute == 180 ? "14:00" : "15:00")
                                        }
                                    }
                                }
                            }
                        .chartYScale(domain: intradayDomain).chartYAxisLabel("价格").frame(height: chartHeight)
                    } else if historyRange == "5d" {
                        Text("近 5 日分时走势 · \(fiveDayChartPoints.count) 个分钟点 · 每日等宽 · 午休折叠")
                            .font(.caption).foregroundStyle(.secondary)
                        Chart(fiveDayChartPoints) { point in
                            LineMark(x: .value("交易日与时段", point.sessionIndex), y: .value("价格", point.price))
                                .foregroundStyle(trendColor).lineStyle(StrokeStyle(lineWidth: 1.7))
                            AreaMark(x: .value("交易日与时段", point.sessionIndex), y: .value("价格", point.price))
                                .foregroundStyle(trendColor.opacity(0.08))
                        }
                        .chartXScale(domain: fiveDayXDomain)
                        .chartXAxis {
                            AxisMarks(values: fiveDayAxisPositions) { value in
                                AxisGridLine(); AxisTick()
                                AxisValueLabel {
                                    if let position = value.as(Double.self) {
                                        let day = Int(position / 260)
                                        if fiveDayDates.indices.contains(day) {
                                            Text(fiveDayDates[day], format: .dateTime.month(.twoDigits).day(.twoDigits))
                                        }
                                    }
                                }
                            }
                        }
                        .chartYScale(domain: fiveDayDomain).chartYAxisLabel("价格").frame(height: chartHeight)
                    } else {
                        Text(historyRange == "all" && candles.count > chartCandles.count
                             ? "全部历史 · \(candles.count) 个交易日 · 概览压缩为 \(chartCandles.count) 根"
                             : "\(historyRangeTitle) · \(candles.count) 个交易日")
                            .font(.caption).foregroundStyle(.secondary)
                        Chart(indexedCandles) { item in
                            let candle = item.candle
                            RuleMark(x: .value("交易日", item.index), yStart: .value("最低", candle.low), yEnd: .value("最高", candle.high))
                                .foregroundStyle(candle.close >= candle.open ? Color.red : Color.green).lineStyle(StrokeStyle(lineWidth: 1))
                            RectangleMark(xStart: .value("交易日起", item.index - 0.32), xEnd: .value("交易日止", item.index + 0.32), yStart: .value("开盘", min(candle.open, candle.close)), yEnd: .value("收盘", max(candle.open, candle.close)))
                                .foregroundStyle(candle.close >= candle.open ? Color.red : Color.green)
                        }
                        .chartXScale(domain: candleXDomain)
                        .chartXAxis {
                            AxisMarks(values: candleAxisIndices) { value in
                                AxisGridLine(); AxisTick()
                                AxisValueLabel {
                                    if let index = value.as(Double.self), let date = candleDateByIndex[Int(index.rounded())] {
                                        if historyRange == "1m" || historyRange == "3m" {
                                            Text(date, format: .dateTime.month(.defaultDigits).day(.defaultDigits)).font(.system(size: historyRange == "3m" ? 8 : 10))
                                        } else {
                                            Text(date, format: .dateTime.year().month().day()).font(.system(size: 9))
                                        }
                                    }
                                }
                            }
                        }
                        .chartYScale(domain: candleDomain).chartYAxisLabel("价格").frame(height: chartHeight)
                    }
                }
                .id(historyRange)
                .transition(.opacity.combined(with: .offset(x: 12)))
                .overlay {
                    HorizontalTrackpadGesture { direction in
                        changeHistoryRange(by: direction)
                    }
                    .allowsHitTesting(false)
                }
                // Keep a native horizontal drag fallback as well as the two-finger
                // scroll monitor, so period switching still works with a mouse/trackpad.
                .simultaneousGesture(DragGesture(minimumDistance: 45).onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) * 1.25 else { return }
                    changeHistoryRange(by: value.translation.width < 0 ? 1 : -1)
                })
            }
            HStack { Text("量比：\(quote?.volumeRatio.map { String(format: "%.2f", $0) } ?? "—")"); Spacer(); Text("换手率：\(quote?.turnover.map { String(format: "%.2f%%", $0) } ?? "—")"); Spacer(); Text("成交额：\(quote.map { $0.amount >= 100_000_000 ? String(format: "%.2f亿", $0.amount / 100_000_000) : String(format: "%.0f万", $0.amount / 10_000) } ?? "—")"); Spacer(); Text("行业：\(quote?.industry ?? "—")") }.font(.caption).foregroundStyle(.secondary)
        }.padding(12).animation(.easeInOut(duration: 0.28), value: historyRange).task {
            DebugLog.write("打开个股详情 code=\(code), quoteAvailable=\(quote != nil), localSamples=\(store.priceHistory(for: code).count)")
            await loadHistory()
        }.onChange(of: historyRange) { _ in scheduleChartLoad() }
         .onDisappear { chartLoadTask?.cancel() }
        }
    }
    private func scheduleChartLoad() {
        chartLoadTask?.cancel()
        chartLoadTask = Task { await loadSelectedChart() }
    }
    private func changeHistoryRange(by direction: Int) {
        let ranges = ["intraday", "5d", "1m", "3m", "year", "all"]
        guard let index = ranges.firstIndex(of: historyRange) else { return }
        let target = min(max(index + direction, 0), ranges.count - 1)
        guard target != index else { return }
        withAnimation(.easeInOut(duration: 0.28)) { historyRange = ranges[target] }
    }
    @MainActor private func loadHistory() async {
        await loadSelectedChart()
    }
    @MainActor private func loadSelectedChart() async {
        guard !Task.isCancelled else { return }
        let requestID = UUID()
        historyRequestID = requestID
        historyLoading = true
        historyError = ""
        defer {
            if historyRequestID == requestID { historyLoading = false }
        }
        do {
            guard await store.ensureHistoryServiceAvailable() else {
                throw NSError(domain: "AStockMonitor.LocalBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "本地行情服务未启动，请重试或在设置中测试连接。"])
            }
            if historyRange == "intraday" {
                let result = try await MarketService.shared.fetchHistory(code: code)
                guard !Task.isCancelled, historyRequestID == requestID else { return }
                points = result
                if points.isEmpty { historyError = "行情源暂未返回分时记录，正在使用本地刷新采样。" }
            } else if historyRange == "5d" {
                let result = try await MarketService.shared.fetchFiveDayTrend(code: code)
                guard !Task.isCancelled, historyRequestID == requestID else { return }
                fiveDayPoints = result
                if fiveDayPoints.isEmpty { historyError = "行情源暂未返回近 5 个交易日的分钟数据。" }
            } else {
                let result = try await MarketService.shared.fetchCandles(code: code, range: historyRange)
                guard !Task.isCancelled, historyRequestID == requestID else { return }
                candles = result
                if candles.isEmpty { historyError = "行情源没有返回日线记录。" }
            }
        }
        catch {
            guard !Task.isCancelled, historyRequestID == requestID else { return }
            if historyRange == "intraday" { points = [] } else if historyRange == "5d" { fiveDayPoints = [] } else { candles = [] }
            historyError = error.localizedDescription
            DebugLog.write("历史加载异常 code=\(code), range=\(historyRange)：\(error.localizedDescription)")
        }
    }
}

struct IndexDetailView: View {
    @ObservedObject var store: MonitorStore
    let symbol: String
    @State private var index: MarketIndex?
    @State private var points: [PricePoint] = []
    @State private var errorMessage = ""
    private var title: String { index?.name ?? indexTitle }
    private var indexTitle: String {
        switch symbol {
        case "sh000001": "上证指数"
        case "sz399001": "深证成指"
        case "sz399006": "创业板指"
        default: "科创综指"
        }
    }
    private var trendColor: Color { (index?.changePercent ?? 0) >= 0 ? .red : .green }
    /// Index detail uses the same folded trading-session axis as stock detail:
    /// 09:30–11:30 followed by 13:00–15:00, with lunch removed.
    private var intradayChartPoints: [IntradayChartPoint] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        // Ignore out-of-session live snapshots before choosing the chart day.
        // Otherwise a weekend/after-hours sample can hide the last traded day.
        let sessionPoints = points.compactMap { point -> (PricePoint, Int)? in
            let time = calendar.dateComponents([.hour, .minute], from: point.date)
            guard let hour = time.hour, let minute = time.minute else { return nil }
            let minuteOfDay = hour * 60 + minute
            guard (570...690).contains(minuteOfDay) || (780...900).contains(minuteOfDay) else { return nil }
            return (point, minuteOfDay)
        }
        guard let latestDate = sessionPoints.map({ $0.0.date }).max() else { return [] }
        let latestDay = calendar.startOfDay(for: latestDate)
        var pointsByMinute: [Int: IntradayChartPoint] = [:]

        for (point, minuteOfDay) in sessionPoints where calendar.startOfDay(for: point.date) == latestDay {
            let sessionMinute: Double
            if (570...690).contains(minuteOfDay) {
                sessionMinute = Double(minuteOfDay - 570)
            } else if (780...900).contains(minuteOfDay) {
                // Keep 13:00 slightly after 11:30 so the two session edges
                // remain distinct while the lunch break itself is collapsed.
                sessionMinute = 120.5 + Double(minuteOfDay - 780) * 119.5 / 120
            } else {
                continue
            }
            // When history and live sampling overlap, retain the latest sample.
            pointsByMinute[Int(sessionMinute.rounded())] = IntradayChartPoint(
                id: point.id, sessionMinute: sessionMinute, price: point.price)
        }

        let chartPoints = pointsByMinute.keys.sorted().compactMap { pointsByMinute[$0] }
        guard let first = chartPoints.first, first.sessionMinute > 0 else { return chartPoints }
        return [IntradayChartPoint(id: UUID(), sessionMinute: 0, price: first.price)] + chartPoints
    }
    private var yDomain: ClosedRange<Double> {
        let values = intradayChartPoints.map(\.price) + (index.map { [$0.price, $0.previousClose] } ?? [])
        let low = values.min() ?? 0; let high = values.max() ?? low
        let margin = max((high - low) * 0.08, max(abs(low) * 0.001, 0.01))
        return max(0, low - margin)...(high + margin)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.bold())
                    Text(symbol.uppercased()).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                if let index {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(String(format: "%.2f", index.price)).font(.title2.monospacedDigit())
                        Text(String(format: "%+.2f%%", index.changePercent)).foregroundStyle(trendColor).monospacedDigit()
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("指数行情加载中").font(.subheadline)
                        if !errorMessage.isEmpty { Text(errorMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }
                Button { Task { await refreshIndex(); await refreshIndexHistory() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.plain)
            }
            Divider()
            HStack {
                Text("分时走势").font(.headline)
                Spacer()
                Text(!errorMessage.isEmpty ? errorMessage : "指数分时 · \(intradayChartPoints.count) 点")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if intradayChartPoints.count < 2 {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line").font(.largeTitle).foregroundStyle(trendColor)
                    if let index {
                        Text(String(format: "%.2f", index.price)).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(String(format: "%+.2f%% · 昨收 %.2f", index.changePercent, index.previousClose))
                            .font(.headline.monospacedDigit()).foregroundStyle(trendColor)
                    } else {
                        ProgressView()
                    }
                    Text(errorMessage.isEmpty ? "正在收集指数实时采样…" : errorMessage)
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("根据实时指数快照绘制；保持窗口打开即可持续累积走势。")
                        .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    if index == nil { Button("重试") { Task { await refreshIndex() } } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart {
                    if let index {
                        RuleMark(y: .value("0%（昨收）", index.previousClose))
                            .foregroundStyle(Color.primary.opacity(0.72))
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .annotation(position: .trailing, alignment: .top, spacing: 5) {
                                Text("0%")
                                    .font(.caption2.bold())
                                    .foregroundStyle(Color.primary)
                                    .padding(.horizontal, 4).padding(.vertical, 2)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                            }
                    }
                    ForEach(intradayChartPoints) { point in
                    LineMark(x: .value("交易时间", point.sessionMinute), y: .value("指数", point.price))
                        .foregroundStyle(trendColor).lineStyle(StrokeStyle(lineWidth: 2))
                    AreaMark(x: .value("交易时间", point.sessionMinute), y: .value("指数", point.price))
                        .foregroundStyle(trendColor.opacity(0.08))
                    }
                }
                .chartYScale(domain: yDomain)
                .chartXScale(domain: 0...240)
                .chartXAxis {
                    AxisMarks(values: [0.0, 60.0, 120.0, 180.0, 240.0]) { value in
                        AxisGridLine(); AxisTick()
                        AxisValueLabel {
                            if let minute = value.as(Double.self) {
                                let labels: [Double: String] = [0: "09:30", 60: "10:30", 120: "11:30", 180: "14:00", 240: "15:00"]
                                if let label = labels[minute] { Text(label) }
                            }
                        }
                    }
                }
                .chartYAxisLabel("点")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .task {
            DebugLog.write("打开指数详情窗口 symbol=\(symbol), name=\(indexTitle), sharedQuotes=\(store.indexQuotes.count)")
            if let fresh = store.indexQuotes.first(where: { $0.symbol == symbol }) {
                DebugLog.write("指数详情绑定共享实时快照 symbol=\(symbol), price=\(fresh.price), change=\(fresh.changePercent)%")
                acceptSnapshot(fresh)
            } else {
                await refreshIndex()
            }
            await refreshIndexHistory()
            // Dashboard polling feeds this detail window. If the dashboard
            // stops refreshing, keep a per-window fallback stream alive.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(12))
                if Task.isCancelled { break }
                if store.indexQuotesUpdatedAt.map({ Date().timeIntervalSince($0) > 15 }) ?? true {
                    await refreshIndex()
                }
            }
        }
        .onReceive(store.$indexQuotes) { snapshots in
            guard let fresh = snapshots.first(where: { $0.symbol == symbol }) else { return }
            acceptSnapshot(fresh)
        }
    }
    @MainActor private func acceptSnapshot(_ fresh: MarketIndex) {
        index = fresh
        if points.count < 3 || errorMessage.contains("历史") { errorMessage = "" }
        let now = Date()
        if points.isEmpty {
            points = [PricePoint(date: now.addingTimeInterval(-60), price: fresh.price)]
        }
        if let last = points.last, now.timeIntervalSince(last.date) < 2 {
            points[points.count - 1] = PricePoint(date: now, price: fresh.price)
        } else {
            points.append(PricePoint(date: now, price: fresh.price))
        }
        if points.count > 240 { points.removeFirst(points.count - 240) }
    }
    @MainActor private func refreshIndexHistory() async {
        do {
            let history = try await MarketService.shared.fetchIndexHistory(symbol: symbol)
            guard !Task.isCancelled else { return }
            // Merge cached minute bars with the live samples collected while the
            // history request was in flight. Prefer the live value within a minute.
            var pointsByMinute: [Int: PricePoint] = [:]
            for point in history.sorted(by: { $0.date < $1.date }) {
                pointsByMinute[Int(point.date.timeIntervalSince1970 / 60)] = point
            }
            for point in points {
                pointsByMinute[Int(point.date.timeIntervalSince1970 / 60)] = point
            }
            points = pointsByMinute.values.sorted { $0.date < $1.date }
            if points.isEmpty {
                errorMessage = "指数分钟历史暂不可用，正在等待实时采样。"
            } else {
                errorMessage = ""
            }
            let firstHistoryTime = history.first?.date.ISO8601Format() ?? "none"
            let lastHistoryTime = history.last?.date.ISO8601Format() ?? "none"
            let historyRange = "\(firstHistoryTime)~\(lastHistoryTime)"
            DebugLog.write("指数详情走势合并完成 symbol=\(symbol), history=\(history.count), merged=\(points.count), 交易时段点数=\(intradayChartPoints.count), historyRange=\(historyRange)")
        } catch {
            errorMessage = "指数历史暂不可用，显示实时采样：\(error.localizedDescription)"
            DebugLog.write("指数分钟历史加载失败 symbol=\(symbol), error=\(error.localizedDescription)")
        }
    }
    @MainActor private func refreshIndex() async {
        do {
            let snapshots = try await MarketService.shared.fetchIndexQuotes()
            store.indexQuotes = snapshots
            store.indexQuotesUpdatedAt = .now
            guard let fresh = snapshots.first(where: { $0.symbol == symbol }) else {
                errorMessage = "行情源没有返回该指数。"
                DebugLog.write("指数快照缺少目标标的 symbol=\(symbol), received=\(snapshots.count)")
                return
            }
            acceptSnapshot(fresh)
        } catch {
            errorMessage = "指数快照暂时连接失败：\(error.localizedDescription)"
            DebugLog.write("指数行情加载失败 symbol=\(symbol), error=\(error.localizedDescription)")
        }
    }

}

struct SettingsView: View {
    @ObservedObject var store: MonitorStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MonitorSettings
    @State private var draftProvider: String
    @State private var serviceURL: String
    @State private var testing = false
    @State private var testResult = ""

    init(store: MonitorStore) {
        self.store = store
        _draft = State(initialValue: store.settings)
        _draftProvider = State(initialValue: store.provider)
        let savedURL = UserDefaults.standard.string(forKey: "serviceURL")
        let oldBundledURLs: Set<String> = ["http://127.0.0.1:8765", "http://127.0.0.1:8766"]
        _serviceURL = State(initialValue: savedURL == nil || oldBundledURLs.contains(savedURL ?? "") ? "http://127.0.0.1:8767" : savedURL!)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("监控设置").font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("配置告警规则、行情来源和日志导出")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        thresholdControl(title: "涨幅", explanation: "当日涨到目标值", value: $draft.threshold)
                        thresholdControl(title: "速拉", explanation: "窗口内从最低点拉升幅度", value: $draft.rapidThreshold)
                        Divider()
                        HStack { settingLabel("涨幅冷却", detail: "自选股重复提醒间隔"); Spacer(); cooldownPicker(selection: $draft.cooldownSeconds) }
                        HStack { settingLabel("速拉冷却", detail: "全市场重复提醒间隔"); Spacer(); cooldownPicker(selection: $draft.rapidCooldownSeconds) }
                        HStack {
                            settingLabel("速拉窗口", detail: "回看多长时间内的最低价"); Spacer()
                            Picker("速拉窗口", selection: $draft.windowSeconds) {
                                Text("30 秒").tag(30); Text("1 分钟（推荐）").tag(60); Text("2 分钟").tag(120)
                                Text("3 分钟").tag(180); Text("5 分钟").tag(300)
                            }.labelsHidden().frame(width: 180)
                        }
                        HStack {
                            settingLabel("刷新间隔", detail: "全市场行情轮询频率"); Spacer()
                            Picker("刷新间隔", selection: $draft.refreshSeconds) {
                                Text("10 秒（推荐）").tag(10); Text("15 秒").tag(15); Text("30 秒").tag(30); Text("60 秒").tag(60)
                            }.labelsHidden().frame(width: 180)
                        }
                        if draft.refreshSeconds > 10 {
                            Text("速拉在窗口内连续快照中寻找最低价；刷新间隔越长，采样越稀疏，越可能错过短时波动。告警中会显示实际区间和起止价。")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                        Divider()
                        settingToggle("全市场涨停监控", detail: "记录所有个股封板 / 炸板 / 回封（不含 ST）", isOn: $draft.limitMonitorAll)
                        if draft.limitMonitorAll {
                            settingToggle("全市场涨停弹窗", detail: "关闭时非自选股只写入日志、不弹窗", isOn: $draft.limitToastAll)
                        }
                        settingToggle("跌停提醒", detail: "记录封跌停事件，自选股弹窗", isOn: $draft.limitDownAlerts)
                        settingToggle("每日自动推荐", detail: "综合 A 级、未涨停可买入，按日期和板块建分组「推荐 MM-dd 主板 / 创业科创」", isOn: $draft.autoAddDailyPicks)
                        if draft.autoAddDailyPicks {
                            HStack {
                                settingLabel("每板块每日推荐", detail: "主板、创业科创各自计数；满额后更高分（至少 +3）替换最低分")
                                Spacer()
                                Stepper("\(draft.dailyPickLimit) 只", value: $draft.dailyPickLimit, in: 3...30)
                            }
                        }
                        Text("告警只在交易时段（9:30–11:30、13:00–15:00）触发。涨幅监控自选池，且涨跌幅相对本交易日上一条行情变化至少 0.01 个百分点才告警；涨停事件按「首次封板 → 炸板 → 回封」记录，同一只股票每天只记一次首封，应用重启不会重复；日志附连板数、首封时间、封单和行业，并在日志页汇总涨停 / 炸板 / 连板梯队和涨停板块。速拉监控全市场，比较速拉窗口内的最低价与现价，并标注同行业 10 分钟内的联动只数。均过滤黑名单和停牌股，并分别应用冷却时间。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        settingToggle("过滤 ST", detail: "不监控 ST 和 *ST 股票", isOn: $draft.filterST)
                        settingToggle("过滤停牌", detail: "跳过当前停牌股票", isOn: $draft.filterSuspended)
                        settingToggle("要求成交量放大", detail: "成交量需达到下方均量倍数", isOn: $draft.requireVolume)
                        if draft.requireVolume {
                            HStack { settingLabel("相对 5 日均量", detail: "放量触发倍数"); Spacer(); Stepper("\(draft.volumeMultiple, specifier: "%.1f") ×", value: $draft.volumeMultiple, in: 1...10, step: 0.5) }
                            Text("使用行情接口的量比估算成交量是否达到设定倍数；不同数据源口径可能略有差异。")
                                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    settingLabel("监控规则", detail: "设置阈值、冷却和股票过滤")
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            settingLabel("数据源", detail: "选择行情接口及回退顺序"); Spacer()
                            Picker("数据源", selection: $draftProvider) {
                                Text("自动切换（腾讯 → 东财 → 新浪）").tag("auto")
                                Text("东方财富").tag("eastmoney")
                                Text("腾讯").tag("tencent")
                                Text("新浪").tag("sina")
                            }.labelsHidden().frame(width: 260)
                        }
                        HStack(spacing: 10) { settingLabel("服务地址", detail: "本机行情桥接服务"); TextField("http://127.0.0.1:8767", text: $serviceURL).textFieldStyle(.roundedBorder) }
                        HStack(spacing: 10) {
                            Button(testing ? "正在测试…" : "测试连接") {
                                testing = true; testResult = "正在连接所选数据源…"
                                Task { testResult = await store.testConnection(provider: draftProvider, serviceURL: serviceURL); testing = false }
                            }.disabled(testing)
                            if !testResult.isEmpty { Text(testResult).font(.caption).foregroundStyle(testResult.hasPrefix("连接成功") ? .green : .secondary).textSelection(.enabled) }
                        }
                        Text("全市场默认每 10 秒刷新。实测腾讯完整快照约需 7 秒，本机仅缓存 2 秒，让下一轮按时获取新快照；更短的设置会产生跳过或重复数据。自动模式优先腾讯，失败后再回退东方财富和新浪；公开接口不是交易所逐笔推送。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    settingLabel("行情连接", detail: "配置行情提供方和本地服务")
                }

                GroupBox {
                    HStack(alignment: .top, spacing: 10) {
                        Button("导出调试日志到 Finder") {
                            let url = DebugLog.export()
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        Text("包含应用请求和行情服务日志，可将 AStockMonitor-debug.txt 发回排查。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    settingLabel("调试", detail: "导出连接和行情日志用于排查")
                }

                HStack {
                    Spacer()
                    Button("取消") { dismiss() }
                    Button("保存并应用") { store.applySettings(draft, provider: draftProvider, serviceURL: serviceURL); dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 696, height: 820)
    }

    private func thresholdControl(title: String, explanation: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.caption.bold())
                Text("\(explanation) · 范围 0–30%")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Slider(value: value, in: 0...30, step: 0.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                HStack(spacing: 3) {
                    TextField("", value: value, format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 68)
                        .accessibilityLabel("\(title)阈值百分比")
                        .onChange(of: value.wrappedValue) { entered in
                            let bounded = min(max(entered, 0), 30)
                            if bounded != entered { value.wrappedValue = bounded }
                        }
                    Text("%").foregroundStyle(.secondary)
                }
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func cooldownPicker(selection: Binding<Int>) -> some View {
        Picker("冷却时间", selection: selection) {
            Text("10 秒").tag(10); Text("30 秒").tag(30)
            Text("1 分钟").tag(60); Text("3 分钟").tag(180)
            Text("5 分钟").tag(300); Text("10 分钟").tag(600)
        }
        .labelsHidden()
        .frame(width: 180)
    }

    private func settingLabel(_ title: String, detail: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text(detail).font(.caption2).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .layoutPriority(1)
    }

    private func settingToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack {
            settingLabel(title, detail: detail)
            Spacer()
            Toggle(title, isOn: isOn).labelsHidden()
        }
    }
}

private struct NumericFilterPanel: View {
    @ObservedObject var store: MonitorStore
    private let rows: [(String, String, String)] = [
        ("price", "现价", "元"), ("changePercent", "涨跌幅", "%"), ("volumeRatio", "量比", "倍"),
        ("turnover", "换手率", "%"), ("amount", "成交额", "元"), ("floatMarketCap", "流通市值", "元")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("多条件数值筛选").font(.headline)
            Text("可同时设置每项的最小值和最大值").font(.caption).foregroundStyle(.secondary)
            ForEach(rows.indices, id: \.self) { index in
                let key = rows[index].0
                let title = rows[index].1
                let unit = rows[index].2
                HStack {
                    Toggle(title, isOn: enabledBinding(key)).toggleStyle(.checkbox).frame(width: 100, alignment: .leading)
                    TextField("最小", value: minimumBinding(key), format: .number.precision(.fractionLength(0...2))).textFieldStyle(.roundedBorder).disabled(!store.filters.enabled.contains(key))
                    TextField("最大", value: maximumBinding(key), format: .number.precision(.fractionLength(0...2))).textFieldStyle(.roundedBorder).disabled(!store.filters.enabled.contains(key))
                    Text(unit).font(.caption).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
                }
            }
            HStack { Spacer(); Button("清除条件") { store.filters.enabled.removeAll() } }
        }
    }
    private func enabledBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { store.filters.enabled.contains(key) }, set: { enabled in if enabled { store.filters.enabled.insert(key) } else { store.filters.enabled.remove(key) } })
    }
    private func minimumBinding(_ key: String) -> Binding<Double> {
        Binding(get: { store.filters.minimums[key, default: 0] }, set: { store.filters.minimums[key] = $0 })
    }
    private func maximumBinding(_ key: String) -> Binding<Double> {
        Binding(get: { store.filters.maximums[key, default: 0] }, set: { store.filters.maximums[key] = $0 })
    }
}

private struct GainFilterPanel: View {
    @ObservedObject var store: MonitorStore
    private var enabled: Binding<Bool> {
        Binding(get: { store.filters.enabled.contains("changePercent") }, set: { value in
            if value { store.filters.enabled.insert("changePercent") } else { store.filters.enabled.remove("changePercent") }
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("涨跌幅区间").font(.headline)
            Toggle("启用涨幅筛选", isOn: enabled).toggleStyle(.checkbox)
            HStack {
                TextField("最小 %", value: Binding(get: { store.filters.minimums["changePercent", default: 0] }, set: { store.filters.minimums["changePercent"] = $0 }), format: .number.precision(.fractionLength(0...2))).textFieldStyle(.roundedBorder)
                Text("至")
                TextField("最大 %", value: Binding(get: { store.filters.maximums["changePercent", default: 0] }, set: { store.filters.maximums["changePercent"] = $0 }), format: .number.precision(.fractionLength(0...2))).textFieldStyle(.roundedBorder)
            }.disabled(!enabled.wrappedValue)
            Text("最大值设为 0 时不限制上限。表头也可切换排序方向。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct DirectionFilterPanel: View {
    @ObservedObject var store: MonitorStore
    private let choices = [("全部", "全部股票", "line.3.horizontal"), ("上涨", "只看上涨", "arrow.up.right"), ("下跌", "只看下跌", "arrow.down.right"), ("涨停", "只看涨停 / 炸板", "arrow.up.to.line")]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("涨/跌筛选").font(.headline)
            ForEach(choices, id: \.0) { value, title, symbol in
                Button {
                    store.filters.direction = value
                } label: {
                    HStack {
                        Label(title, systemImage: symbol)
                        Spacer()
                        if store.filters.direction == value { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
            }
        }
    }
}

