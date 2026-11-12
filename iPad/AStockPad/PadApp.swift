import SwiftUI

/// 外观皮肤：跟随系统 / 日间 / 夜间。
enum PadAppearance {
    static let key = "pad.appearance"
    static let modes: [(id: String, title: String, icon: String)] = [("system", "跟随系统", "circle.lefthalf.filled"), ("light", "日间", "sun.max"), ("dark", "夜间", "moon.stars")]
    static func scheme(_ mode: String) -> ColorScheme? { mode == "dark" ? .dark : (mode == "light" ? .light : nil) }
}

@main
struct AStockPadApp: App {
    @StateObject private var store = PadStore()
    @AppStorage(PadAppearance.key) private var appearance = "system"
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(PadAppearance.scheme(appearance))
                .onChange(of: scenePhase) { phase in
                    if phase == .active { store.start() } else if phase == .background { store.stop() }
                }
                .onAppear { store.start() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: PadStore
    @State private var path: [String] = []
    @State private var tab = 0
    @State private var showSettings = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @AppStorage(PadAppearance.key) private var appearance = "system"

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WatchSidebar(open: { path = [$0] })
                .navigationTitle("自选股池")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            let ids = PadAppearance.modes.map(\.id)
                            appearance = ids[((ids.firstIndex(of: appearance) ?? 0) + 1) % ids.count]
                        } label: { Image(systemName: PadAppearance.modes.first { $0.id == appearance }?.icon ?? "circle.lefthalf.filled") }
                    }
                }
        } detail: {
            NavigationStack(path: $path) {
                MainTabs(tab: $tab, open: { path.append($0) })
                    .navigationDestination(for: String.self) { code in StockDetailView(code: code) }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store).preferredColorScheme(PadAppearance.scheme(appearance)) }
        .onChange(of: store.analysisJump) { code in
            guard let code else { return }
            path = []; tab = 3
            store.analyze(code)
            store.analysisJump = nil
        }
        .overlay(alignment: .bottom) {
            if let banner = store.banner {
                BannerView(banner: banner)
                    .onTapGesture { path = [banner.code]; store.dismissBanner() }
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) { SellAlertOverlay() }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.banner)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.pendingSellSignals.count)
    }
}

/// 与 Mac 版一致的分页切换：图标 + 标题 + 角标，选中项为浮起的圆角块。
struct PadTabSwitcher: View {
    @EnvironmentObject var store: PadStore
    @Binding var tab: Int

    var body: some View {
        HStack(spacing: 2) {
            item(0, "行情", "list.bullet.rectangle", nil)
            item(1, "告警", "bell", store.unseenAlerts > 0 ? min(store.unseenAlerts, 99) : nil)
            item(2, "潜力股", "scope", (store.lists["all"] ?? []).isEmpty ? nil : (store.lists["all"] ?? []).count, color: .orange)
            item(3, "个股分析", "stethoscope", nil)
            item(4, "持仓", "briefcase", store.pendingSellSignals.isEmpty ? (store.holdings.isEmpty ? nil : store.holdings.count) : store.pendingSellSignals.count,
                 color: store.pendingSellSignals.isEmpty ? .blue : .orange)
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
    }

    private func item(_ tag: Int, _ title: String, _ icon: String, _ badge: Int?, color: Color = .red) -> some View {
        Button { tab = tag } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 12))
                Text(title).font(.system(size: 14, weight: tab == tag ? .semibold : .regular))
                if let badge {
                    Text("\(badge)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(color))
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 5)
            .foregroundStyle(tab == tag ? Color.primary : Color.secondary)
            .background(RoundedRectangle(cornerRadius: 8).fill(tab == tag ? Color(uiColor: .secondarySystemGroupedBackground) : .clear))
            .shadow(color: .black.opacity(tab == tag ? 0.12 : 0), radius: 1.5, y: 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct BannerView: View {
    let banner: Banner
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(banner.kind).font(.caption.bold()).foregroundStyle(color)
                    Text(banner.name).font(.subheadline.bold())
                    Text(banner.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Text(banner.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 460, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
    private var icon: String {
        switch banner.kind {
        case "速拉": "bolt.fill"
        case "涨停", "回封": "arrow.up.to.line"
        case "炸板": "exclamationmark.triangle.fill"
        case "跌停": "arrow.down.to.line"
        case "当日推荐": "star.fill"
        case "推荐替换": "arrow.triangle.swap"
        default: "arrow.up.right.circle.fill"
        }
    }
    private var color: Color {
        switch banner.kind {
        case "速拉", "炸板", "推荐替换": .orange
        case "跌停": .green
        default: .red
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject var store: PadStore
    @Binding var tab: Int
    let open: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            IndexStrip()
            Divider()
            switch tab {
            case 1: AlertsView(open: open)
            case 2: PicksView(open: open)
            case 3: AnalysisView(open: open)
            case 4: HoldingsView(open: open)
            default: QuoteListView(open: open)
            }
            Divider()
            HStack {
                Circle().fill(store.status.hasPrefix("已连接") ? Color.green : Color.orange).frame(width: 7, height: 7)
                Text(store.status).lineLimit(1)
                Spacer()
                if let date = store.lastUpdate { Text("更新 \(date.formatted(date: .omitted, time: .standard))") }
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 6)
        }
        .toolbar {
            ToolbarItem(placement: .principal) { PadTabSwitcher(tab: $tab) }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { store.refreshNow() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: tab) { value in if value == 1 { store.markAlertsSeen() } }
    }
}

struct IndexStrip: View {
    @EnvironmentObject var store: PadStore
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.indexes) { index in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(index.name).font(.caption2).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            Text(String(format: "%.2f", index.price)).font(.system(size: 15, weight: .semibold, design: .rounded))
                            Text(Fmt.pct(index.changePercent)).font(.caption.bold())
                        }
                        .monospacedDigit()
                        .foregroundStyle(index.changePercent >= 0 ? Color.red : Color.green)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.045)))
                    .overlay(alignment: .leading) {
                        Capsule().fill(index.changePercent >= 0 ? Color.red : Color.green).frame(width: 3).padding(.vertical, 7)
                    }
                }
                if let b = store.breadth {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("市场\(b.regime)").font(.caption2.bold()).foregroundStyle(b.regime == "强势" ? .red : (b.regime == "弱势" ? .green : .orange))
                        Text("涨 \(b.upCount) / 跌 \(b.downCount) · 中位 \(Fmt.pct(b.medianChange)) · 涨停 \(b.limitUpCount)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}
