import SwiftUI

@main
struct AStockPadApp: App {
    @StateObject private var store = PadStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
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

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            WatchSidebar(open: { path = [$0] })
                .navigationTitle("自选股池")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    }
                }
        } detail: {
            NavigationStack(path: $path) {
                MainTabs(tab: $tab, open: { path.append($0) })
                    .navigationDestination(for: String.self) { code in StockDetailView(code: code) }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(store) }
        .overlay(alignment: .bottom) {
            if let banner = store.banner {
                BannerView(banner: banner)
                    .onTapGesture { path = [banner.code]; store.dismissBanner() }
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.banner)
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
            ToolbarItem(placement: .principal) {
                Picker("页面", selection: $tab) {
                    Text("行情").tag(0)
                    Text(store.unseenAlerts > 0 ? "告警 \(min(store.unseenAlerts, 99))" : "告警").tag(1)
                    Text("潜力股 \((store.lists["all"] ?? []).count)").tag(2)
                }
                .pickerStyle(.segmented).frame(width: 360)
            }
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
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
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
