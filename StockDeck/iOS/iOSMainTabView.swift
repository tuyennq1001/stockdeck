#if os(iOS)
import SwiftUI

struct iOSMainTabView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @State private var selectedTab: Tab = .watchlist
    @State private var showSearch = false
    @State private var addHoldingPortfolioId: UUID?
    @State private var editHolding: (portfolioId: UUID, holding: Holding)?

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
                    .sheet(item: $addHoldingBinding) { item in
                        NavigationStack {
                            AddHoldingView(portfolioId: item.portfolioId, isPresented: Binding(
                                get: { addHoldingPortfolioId != nil },
                                set: { if !$0 { addHoldingPortfolioId = nil } }
                            ))
                        }
                        .presentationDetents([.medium, .large])
                    }
            }
            .tabItem {
                Label("Portfolios", systemImage: Tab.portfolios.icon)
            }
            .tag(Tab.portfolios)

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
        .environment(\.addHoldingAction, AddHoldingAction { portfolioId in
            addHoldingPortfolioId = portfolioId
        })
        .environment(\.editHoldingAction, EditHoldingAction { portfolioId, holding in
            editHolding = (portfolioId, holding)
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

    private var addHoldingBinding: Binding<HoldingSheetItem?> {
        Binding(
            get: { addHoldingPortfolioId.map { HoldingSheetItem(portfolioId: $0) } },
            set: { addHoldingPortfolioId = $0?.portfolioId }
        )
    }
}

private struct HoldingSheetItem: Identifiable {
    let portfolioId: UUID
    var id: UUID { portfolioId }
}
#endif
