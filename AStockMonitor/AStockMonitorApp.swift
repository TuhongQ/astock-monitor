import SwiftUI
import AppKit

/// 外观皮肤：跟随系统 / 日间 / 夜间。作用于所有窗口、菜单栏面板和表格。
enum AppAppearance {
    static let key = "appearanceMode"
    static let modes: [(id: String, title: String, icon: String)] = [("system", "跟随系统", "circle.lefthalf.filled"), ("light", "日间", "sun.max"), ("dark", "夜间", "moon.stars")]
    static var current: String { UserDefaults.standard.string(forKey: key) ?? "system" }
    static func apply(_ mode: String) {
        UserDefaults.standard.set(mode, forKey: key)
        NSApp.appearance = mode == "dark" ? NSAppearance(named: .darkAqua) : (mode == "light" ? NSAppearance(named: .aqua) : nil)
        DebugLog.write("外观切换为 \(mode)")
    }
    static func next(after mode: String) -> String {
        let ids = modes.map(\.id)
        return ids[((ids.firstIndex(of: mode) ?? 0) + 1) % ids.count]
    }
}

@main
struct AStockMonitorApp: App {
    @StateObject private var store = MonitorStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("A 股盯盘", id: "dashboard") {
            DashboardView(store: store)
                .frame(minWidth: 1050, minHeight: 680)
                .environmentObject(store)
                .onAppear {
                    AppAppearance.apply(AppAppearance.current)
                    appDelegate.store = store
                    store.start()
                    // SwiftUI 可能在 Space/窗口重新挂载时再次调用 onAppear。
                    // 自动置前只能发生于本次启动首次展示，之后由用户点击菜单栏入口时显式置前。
                    appDelegate.presentDashboardOnFirstAppearance()
                }
        }
        .commands { CommandGroup(replacing: .newItem) {} }

        // SwiftUI/macOS 13+ 托管状态栏 extra 的创建、展示和 Space 生命周期；
        // 不再手动注册 NSStatusItem 或调整系统菜单栏窗口位置。
        MenuBarExtra {
            StatusBarExtraContent(store: store)
        } label: {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .accessibilityLabel("A 股盯盘")
                .onAppear {
                    DebugLog.write("MenuBarExtra 图标已呈现：bundle=\(Bundle.main.bundleURL.path), selected=\(store.watch.menuBarCodes.joined(separator: ","))")
                }
        }
        .menuBarExtraStyle(.window)

        Window("监控设置", id: "settings") {
            SettingsView(store: store).frame(width: 696, height: 820)
        }
        .defaultSize(width: 696, height: 820)
        .windowResizability(.contentSize)

        WindowGroup("个股详情", id: "stock-detail", for: String.self) { $code in
            if let code {
                if code.hasPrefix("index:") {
                    IndexDetailView(store: store, symbol: String(code.dropFirst("index:".count))).frame(minWidth: 700, minHeight: 460)
                } else {
                    StockDetailView(store: store, code: code).frame(minWidth: 900, minHeight: 520)
                }
            }
        }
        .defaultSize(width: 1300, height: 680)

    }
}

/// 菜单栏内容由 SwiftUI MenuBarExtra 场景托管，窗口开合交给系统处理。
private struct StatusBarExtraContent: View {
    @ObservedObject var store: MonitorStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        StatusBarPanelView(
            store: store,
            openDashboard: {
                dismiss()
                openWindow(id: "dashboard")
                AppDelegate.activateDashboardWindow()
            },
            openDetail: { code in
                dismiss()
                openWindow(id: "stock-detail", value: code)
                NSApp.activate(ignoringOtherApps: true)
            }
        )
    }
}

private struct StatusBarPanelView: View {
    @ObservedObject var store: MonitorStore
    let openDashboard: () -> Void
    let openDetail: (String) -> Void

    /// Measure the widest row so short names and values do not stretch across a fixed-width panel.
    private var panelWidth: CGFloat {
        let valueFont = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
        let codeFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        func width(_ text: String, font: NSFont) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }

        let rowWidth = store.watch.menuBarCodes.map { code -> CGFloat in
            let quote = store.quote(for: code) ?? store.menuBarQuoteCache[code]
            let name = quote?.name ?? code
            let subtitle = quote == nil ? "等待行情…" : (store.isLiveQuote(code) ? code : "\(code) · 上次行情")
            let price = quote.map { $0.price > 0 ? String(format: "%.2f", $0.price) : "--" } ?? "--"
            let change = quote.map { String(format: "%+.2f%%", $0.changePercent) } ?? "--"
            let left = max(width(name, font: valueFont), width(subtitle, font: codeFont))
            return 7 + 5 + left + 5 + width(price, font: valueFont) + 5 + width(change, font: valueFont) + 14
        }.max() ?? 0

        // Keep enough room for the title and footer controls while letting the
        // stock rows determine the rest of the panel width.
        return min(360, max(220, rowWidth))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("A 股盯盘", systemImage: "chart.line.uptrend.xyaxis").font(.headline)
                Spacer()
                Text("\(store.watch.menuBarCodes.count) 只")
                    .font(.caption).foregroundStyle(.secondary)
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
            }
            Text(store.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)

            if store.watch.menuBarCodes.isEmpty {
                Text("尚未添加状态栏个股。可在主行情列表右键添加。")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(store.watch.menuBarCodes, id: \.self) { code in
                            let liveQuote = store.quote(for: code)
                            let quote = liveQuote ?? store.menuBarQuoteCache[code]
                            if let quote {
                                let index = store.watch.menuBarCodes.firstIndex(of: code) ?? 0
                                Button { openDetail(code) } label: {
                                    HStack(spacing: 5) {
                                        Circle().fill(quote.changePercent >= 0 ? Color.red : Color.green).frame(width: 7, height: 7)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(quote.name).lineLimit(1)
                                            Text(liveQuote == nil ? "\(code) · 上次行情" : code)
                                                .font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 3)
                                        Text(quote.price > 0 ? String(format: "%.2f", quote.price) : "--")
                                        Text(String(format: "%+.2f%%", quote.changePercent))
                                            .foregroundStyle(quote.changePercent >= 0 ? Color.red : Color.green)
                                    }
                                    .font(.caption)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 7)
                                .frame(height: 42)
                                .contextMenu {
                                    Button("上移") { store.moveMenuBarCode(code, by: -1) }.disabled(index == 0)
                                    Button("下移") { store.moveMenuBarCode(code, by: 1) }.disabled(index == store.watch.menuBarCodes.count - 1)
                                    Divider()
                                    Button("从状态栏移除", role: .destructive) { store.toggleMenuBarCode(code) }
                                }
                                .accessibilityIdentifier("statusbar-stock-\(code)")
                                .onAppear { DebugLog.write("状态栏股票行已布局：code=\(code), source=\(liveQuote == nil ? "cache" : "live")") }
                            } else {
                                HStack {
                                    Text(code); Spacer(); Text("等待行情…").foregroundStyle(.secondary)
                                }.font(.caption).frame(height: 42)
                                    .accessibilityIdentifier("statusbar-stock-\(code)")
                                    .onAppear { DebugLog.write("状态栏股票行已布局：code=\(code), source=missing") }
                            }
                        }
                    }
                }
                // MenuBarExtra cannot reliably infer a ScrollView's intrinsic height.
                // Match the viewport to the row height so short lists do not leave
                // unused space; cap long lists and let them scroll.
                .frame(height: min(330, max(42, CGFloat(store.watch.menuBarCodes.count) * 44 - 2)))
            }

            Divider()
            Button(action: openDashboard) { Label("打开盯盘窗口", systemImage: "macwindow") }
                .buttonStyle(.plain).keyboardShortcut("o", modifiers: [.command])
            Button(role: .destructive, action: {
                store.stop()
                NSApp.terminate(nil)
            }) { Label("退出 A 股盯盘", systemImage: "power") }
                .buttonStyle(.plain).keyboardShortcut("q", modifiers: [.command])
        }
        .padding(14)
        .frame(width: panelWidth)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear {
            let codes = store.watch.menuBarCodes
            DebugLog.write("状态栏弹层打开：选中股票=\(codes.joined(separator: ",")), liveQuotes=\(store.quotes.count), cacheQuotes=\(store.menuBarQuoteCache.count), width=\(Int(panelWidth))")
            for code in codes {
                let source = store.isLiveQuote(code) ? "live" : (store.menuBarQuoteCache[code] == nil ? "missing" : "cache")
                DebugLog.write("状态栏弹层行：code=\(code), quoteSource=\(source)")
            }
        }
        .onChange(of: store.watch.menuBarCodes) { codes in
            DebugLog.write("状态栏弹层列表更新：\(codes.joined(separator: ","))")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: MonitorStore?

    private var windowLifecycleObservers: [NSObjectProtocol] = []
    private var spaceObserver: NSObjectProtocol?
    private var didPresentInitialDashboard = false

    func presentDashboardOnFirstAppearance() {
        guard !didPresentInitialDashboard else {
            DebugLog.write("主窗口 onAppear：已完成首次展示，不重新激活，避免 Space 切换时跳桌面")
            return
        }
        didPresentInitialDashboard = true
        DebugLog.write("主窗口首次 onAppear：执行一次初始激活")
        Self.activateDashboardWindow()
    }

    static func activateDashboardWindow() {
        // LSUIElement 启动为 accessory 是为了无窗口时常驻菜单栏；有普通窗口时
        // 切到 regular，使应用自己成为正常前台应用，避免状态栏弹层关闭时系统
        // 把激活权错误地还给更早的 Finder/其他应用。
        let changed = NSApp.setActivationPolicy(.regular)
        DebugLog.write("打开盯盘窗口：切换 regular activation policy 成功=\(changed)")
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.windows.first(where: { $0.title == "A 股盯盘" })?.makeKeyAndOrderFront(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.write("应用启动完成：activationPolicy=\(NSApp.activationPolicy().rawValue), bundle=\(Bundle.main.bundleIdentifier ?? "unknown"), path=\(Bundle.main.bundleURL.path)")

        // 只在窗口真正关闭时调整激活策略。不能监听 didBecomeKey：桌面切换、
        // SwiftUI 场景重挂载和菜单栏窗口焦点变化都可能触发它，并造成不必要的策略切换。
        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let title = (notification.object as? NSWindow)?.title ?? "未知窗口"
            DebugLog.write("窗口关闭通知：\(title)；Space 变化本身不调整 activation policy")
            DispatchQueue.main.async { [weak self] in
                Task { @MainActor [weak self] in self?.synchronizeActivationPolicyAfterWindowClose() }
            }
        }
        windowLifecycleObservers.append(closeObserver)
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.logSpaceChange() }
        }
    }

    @MainActor private func synchronizeActivationPolicyAfterWindowClose() {
        let hasVisibleAppWindow = NSApp.windows.contains { !($0 is NSPanel) && $0.isVisible }
        let desiredPolicy: NSApplication.ActivationPolicy = hasVisibleAppWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != desiredPolicy else { return }
        let changed = NSApp.setActivationPolicy(desiredPolicy)
        DebugLog.write("窗口关闭后切换 activation policy：仍有可见普通窗口=\(hasVisibleAppWindow), 目标=\(desiredPolicy.rawValue), 成功=\(changed)")
    }

    @MainActor private func logSpaceChange() {
        let windows = NSApp.windows
            .filter { !($0 is NSPanel) && $0.isVisible }
            .map { "\($0.title):activeSpace=\($0.isOnActiveSpace)" }
            .joined(separator: ",")
        DebugLog.write("Space 切换诊断：appActive=\(NSApp.isActive), activationPolicy=\(NSApp.activationPolicy().rawValue), frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"), visibleWindows=[\(windows)]；MenuBarExtra 由系统管理，不强制显示菜单栏")
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let store {
            let saved = AppFiles.write(store.watch, name: "watchlist.json")
            UserDefaults.standard.set(store.watch.menuBarCodes, forKey: "menuBarCodes.v1")
            DebugLog.write("应用退出保存状态栏列表：saved=\(saved), codes=\(store.watch.menuBarCodes.joined(separator: ","))")
        } else {
            DebugLog.write("应用退出：MonitorStore 尚未初始化")
        }
        windowLifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowLifecycleObservers.removeAll()
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        store?.stop()
    }
}

// MARK: - 卖点提醒弹窗

/// 置顶浮动面板：在其他 App 前面弹出，所有桌面空间可见，直到逐条确认或全部确认。
@MainActor final class SellAlertPanelController {
    static let shared = SellAlertPanelController()
    private var panel: NSPanel?

    func show(store: MonitorStore) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.title = "卖点提醒"
            p.level = .floating
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: SellAlertPanelView(store: store, close: { [weak self] in self?.close() }))
            if let screen = NSScreen.main?.visibleFrame {
                p.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 440, y: screen.maxY - 20))
            }
            panel = p
        }
        panel?.orderFrontRegardless()
    }

    func close() { panel?.orderOut(nil) }
}

private struct SellAlertPanelView: View {
    @ObservedObject var store: MonitorStore
    let close: () -> Void

    var body: some View {
        let pending = store.pendingSellSignals
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "bell.badge.fill").foregroundStyle(.orange)
                Text(pending.isEmpty ? "没有待处理的卖点提醒" : "\(pending.count) 条卖点提醒").font(.headline)
                Spacer()
                if !pending.isEmpty {
                    Button("全部知道了") { store.acknowledgeAllSellSignals(); close() }.controlSize(.small)
                }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(pending) { signal in card(signal) }
                }
            }
            Text("规则提醒仅供参考，是否卖出由你决定。").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(minWidth: 380, minHeight: 200)
        .onChange(of: pending.isEmpty) { empty in if empty { close() } }
    }

    private func card(_ s: SellSignal) -> some View {
        let color: Color = s.critical ? .green : .red
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(s.title).font(.caption.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(color))
                Text(s.name).font(.headline)
                Text(s.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%+.2f%%", s.pnl)).font(.headline.monospacedDigit()).foregroundStyle(s.pnl >= 0 ? .red : .green)
            }
            Text(s.detail).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(s.time.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("已卖出，移出持仓") { store.removeHolding(s.holdingID); store.acknowledgeSellSignal(s.id) }.controlSize(.small)
                Button("知道了") { store.acknowledgeSellSignal(s.id) }.controlSize(.small).keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.35)))
    }
}
