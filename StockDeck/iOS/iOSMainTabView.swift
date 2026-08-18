#if os(iOS)
import SwiftUI

struct iOSMainTabView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @State private var selectedTab: Tab = .watchlist
    @State private var showSearch = false
    @State private var addHoldingPortfolioId: UUID?

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
                                    showSearch = true
                                } label: {
                                    Image(systemName: "magnifyingglass")
                                }
                                refreshButton
                            }
                        }
                    }
                    .sheet(isPresented: $showSearch) {
                        NavigationStack {
                            SearchView(mode: .watchlist, isPresented: $showSearch)
                                .navigationTitle("Search Tickers")
                                .navigationBarTitleDisplayMode(.inline)
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
        .environment(\.addHoldingAction, AddHoldingAction { portfolioId, _ in
            addHoldingPortfolioId = portfolioId
        })
        .onAppear {
            selectedTab = Tab.resolve(stored: storageService.lastSelectedTab,
                                      showNews: storageService.showNewsTab)
        }
        .onChange(of: selectedTab) { _, newValue in
            storageService.lastSelectedTab = newValue.rawValue
        }
    }

    private var refreshButton: some View {
        Button {
            Task {
                await stockService.refreshAll(storageService: storageService)
                if selectedTab == .home {
                    await stockService.refreshNews(storageService: storageService, force: true)
                }
            }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .disabled(stockService.isLoading)
    }
}
#endif
