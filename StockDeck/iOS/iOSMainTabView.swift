#if os(iOS)
import SwiftUI

struct iOSMainTabView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @State private var selectedTab: Tab = .watchlist
    @State private var showSearch = false
    @State private var showWatchlistCustomizer = false
    @State private var showPortfolioColumnCustomizer = false
    @State private var addHoldingPortfolioId: UUID?
    @State private var selectedDetailSymbol: String?

    var body: some View {
        TabView(selection: $selectedTab) {
            if storageService.showNewsTab {
                NavigationStack {
                    HomeView()
                        .navigationTitle("Home / News")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                refreshButton
                            }
                        }
                }
                .tabItem {
                    Label("Home", systemImage: Tab.home.icon)
                }
                .tag(Tab.home)
            }

            NavigationStack {
                WatchlistView(showSearch: $showSearch)
                    .navigationTitle("Watchlist")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            HStack(spacing: 12) {
                                Button {
                                    showWatchlistCustomizer = true
                                } label: {
                                    Image(systemName: "slider.horizontal.3")
                                }
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showSearch = true
                                    }
                                } label: {
                                    Image(systemName: "magnifyingglass")
                                }
                                refreshButton
                            }
                        }
                    }
                    .sheet(isPresented: $showWatchlistCustomizer) {
                        WatchlistMetricCustomizer(initialMetrics: storageService.resolvedIOSWatchlistMetrics) { newMetrics in
                            storageService.setIOSWatchlistMetrics(newMetrics)
                        }
                    }
            }
            .tabItem {
                Label("Watchlist", systemImage: Tab.watchlist.icon)
            }
            .tag(Tab.watchlist)

            NavigationStack {
                PortfolioListView()
                    .navigationTitle("Portfolios")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                showPortfolioColumnCustomizer = true
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            refreshButton
                        }
                    }
                    .sheet(isPresented: Binding(
                        get: { addHoldingPortfolioId != nil },
                        set: { if !$0 { addHoldingPortfolioId = nil } }
                    )) {
                        if let portfolioId = addHoldingPortfolioId {
                            NavigationStack {
                                AddHoldingView(portfolioId: portfolioId, isPresented: $addHoldingPortfolioId)
                            }
                            .presentationDetents([.medium, .large])
                        }
                    }
                    .sheet(isPresented: $showPortfolioColumnCustomizer) {
                        PortfolioColumnCustomizer(initialColumns: storageService.resolvedIOSPortfolioColumns) { newColumns in
                            storageService.setIOSPortfolioColumns(newColumns)
                        }
                    }
            }
            .tabItem {
                Label("Portfolios", systemImage: Tab.portfolios.icon)
            }
            .tag(Tab.portfolios)

            NavigationStack {
                UtilitiesView()
                    .navigationTitle("Utilities")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem {
                Label("Utilities", systemImage: Tab.utilities.icon)
            }
            .tag(Tab.utilities)

            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem {
                Label("Settings", systemImage: Tab.settings.icon)
            }
            .tag(Tab.settings)
        }
        .tint(DS.brand)
        .environment(\.showSymbolDetail, ShowSymbolDetailAction { symbol in
            selectedDetailSymbol = symbol
        })
        .environment(\.addHoldingAction, AddHoldingAction { portfolioId, _ in
            addHoldingPortfolioId = portfolioId
        })
        .sheet(isPresented: Binding(
            get: { selectedDetailSymbol != nil },
            set: { if !$0 { selectedDetailSymbol = nil } }
        )) {
            if let sym = selectedDetailSymbol {
                SymbolDetailView(
                    symbol: sym,
                    onAddToPortfolio: { portfolioId in
                        addHoldingPortfolioId = portfolioId
                    },
                    onDismiss: {
                        selectedDetailSymbol = nil
                    }
                )
            }
        }
        .onAppear {
            selectedTab = Tab.resolve(stored: storageService.lastSelectedTab,
                                      showNews: storageService.showNewsTab)
            if storageService.iCloudSyncEnabled {
                iCloudSyncService.shared.pullAndMerge(force: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            if storageService.iCloudSyncEnabled {
                iCloudSyncService.shared.pullAndMerge(force: false)
            }
        }
        .onChange(of: selectedTab) { _, newValue in
            storageService.lastSelectedTab = newValue.rawValue
        }
    }

    private var refreshButton: some View {
        Button {
            Task {
                if storageService.iCloudSyncEnabled {
                    iCloudSyncService.shared.pullAndMerge(force: false)
                }
                await stockService.refreshAll(storageService: storageService)
                if selectedTab == .home {
                    await stockService.refreshNews(storageService: storageService, force: true)
                }
            }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .disabled(stockService.isLoading || iCloudSyncService.shared.isSyncing)
    }
}
#endif

