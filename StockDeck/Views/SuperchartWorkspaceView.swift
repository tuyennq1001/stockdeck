import SwiftUI

enum SuperchartSource: Hashable, Identifiable {
    case watchlist(UUID)
    case portfolio(UUID)
    case allPortfolios

    var id: String {
        switch self {
        case .watchlist(let id): "watchlist:\(id.uuidString)"
        case .portfolio(let id): "portfolio:\(id.uuidString)"
        case .allPortfolios: "all-portfolios"
        }
    }
}

enum SuperchartPortfolioSymbolOrdering {
    struct Entry {
        let symbol: String
        let marketValue: Double?
    }

    static func orderedSymbols(from entries: [Entry]) -> [String] {
        struct Aggregate {
            let symbol: String
            let firstIndex: Int
            var marketValue: Double?
        }

        var aggregates: [String: Aggregate] = [:]
        for (index, entry) in entries.enumerated() {
            let key = StockService.canonicalSymbol(for: entry.symbol)
            guard !key.isEmpty else { continue }
            if var aggregate = aggregates[key] {
                if let current = aggregate.marketValue, let added = entry.marketValue,
                   current.isFinite, added.isFinite {
                    aggregate.marketValue = current + added
                } else {
                    aggregate.marketValue = nil
                }
                aggregates[key] = aggregate
            } else {
                let value = entry.marketValue.flatMap { $0.isFinite ? $0 : nil }
                aggregates[key] = Aggregate(symbol: entry.symbol, firstIndex: index, marketValue: value)
            }
        }

        return aggregates.values.sorted { lhs, rhs in
            switch (lhs.marketValue, rhs.marketValue) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.firstIndex < rhs.firstIndex
            }
        }.map(\.symbol)
    }
}

enum SuperchartDetailTab: String, CaseIterable {
    case overview = "Tổng quan"
    case news = "Tin tức"
    case notes = "Ghi chú"
}

enum SuperchartSubViewMode: String, CaseIterable {
    case chart = "Biểu đồ"
    case table = "Bảng chi tiết"
}

@MainActor
struct SuperchartWorkspaceView: View {
    @EnvironmentObject private var storageService: StorageService
    @Binding var selectedSymbol: String?
    @ObservedObject var stockService: StockService
    let initialSource: SuperchartSource
    let onSelectSource: (SuperchartSource) -> Void
    var watchlistViewModel: WatchlistViewModel? = nil
    var isSidebarCollapsed: Bool = false
    var onToggleSidebar: (() -> Void)? = nil
    var onSwitchToTable: (() -> Void)? = nil
    @ObservedObject private var insiderService = InsiderTradingService.shared

    @State private var source: SuperchartSource
    @State private var query = ""
    @State private var sourceQuery = ""
    @State private var isSourcePickerPresented = false
    @State private var sourcePickerShowsPortfolios = false
    @State private var chartRange = "3M"
    @State private var listWidth = UserDefaults.standard.object(forKey: "stockdeck.superchart.listWidth") as? CGFloat ?? 300
    @State private var isListCollapsed = UserDefaults.standard.bool(forKey: "stockdeck.superchart.listCollapsed")
    @State private var listDragOrigin: CGFloat?
    @State private var favoriteSourceIDs: [String] = []
    @State private var sourceShortcuts: [String: String] = [:]
    @State private var editingShortcutID: String? = nil
    @State private var editingShortcutText = ""
    @State private var isShortcutEditorPresented = false
    @StateObject private var pineWorkspace = PineScriptWorkspace()
    @State private var showsPineScripts = false
    @State private var selectedPineSettings: CustomPineIndicator?

    // Detail pane state
    @State private var detailTab: SuperchartDetailTab = .overview
    @State private var detailHeight = UserDefaults.standard.object(forKey: "stockdeck.superchart.detailHeight") as? CGFloat ?? 320
    @State private var isDetailCollapsed = false
    @State private var detailDragOrigin: CGFloat?
    @AppStorage("stockdeck.superchart.subViewMode") var subViewMode: SuperchartSubViewMode = .chart

    // Multi-selection & Drag reordering state
    @State private var selectedSymbols: Set<String> = []
    @State private var multiAlertSymbols: [String] = []
    @State private var draggingSymbol: String? = nil
    @State private var draggingSymbols: Set<String> = []
    @State private var dropIndicator: DropIndicator<String>? = nil

    // Watchlist management state
    @State private var isNewWatchlistAlertPresented = false
    @State private var newWatchlistName = ""
    @State private var isRenameWatchlistPresented = false
    @State private var renameWatchlistName = ""
    @State private var isDeleteWatchlistPresented = false
    @State private var watchlistToDelete: Watchlist? = nil

    // Sheets
    struct AddTarget: Identifiable { let symbol: String; let portfolioId: UUID; var id: String { "\(symbol)-\(portfolioId)" } }
    @State private var alertSheetSymbol: String? = nil
    @State private var targetSheetSymbol: String? = nil
    @State private var addToPortfolioTarget: AddTarget? = nil
    @State private var isSearchSheetPresented = false

    init(stockService: StockService,
         selectedSymbol: Binding<String?>,
         initialSource: SuperchartSource,
         watchlistViewModel: WatchlistViewModel? = nil,
         isSidebarCollapsed: Bool = false,
         onToggleSidebar: (() -> Void)? = nil,
         onSwitchToTable: (() -> Void)? = nil,
         onSelectSource: @escaping (SuperchartSource) -> Void) {
        self.stockService = stockService
        self._selectedSymbol = selectedSymbol
        self.initialSource = initialSource
        self.watchlistViewModel = watchlistViewModel
        self.isSidebarCollapsed = isSidebarCollapsed
        self.onToggleSidebar = onToggleSidebar
        self.onSwitchToTable = onSwitchToTable
        self.onSelectSource = onSelectSource
        self._source = State(initialValue: initialSource)
    }

    private var sourceSymbols: [String] {
        symbols(for: source)
    }

    private func sortedWatchlistSymbols(for wl: Watchlist) -> [String] {
        let sortKey = WatchlistSortKey.from(rawString: wl.sortKey)
        let sortAsc = wl.sortAsc ?? true
        guard sortKey != .order else {
            return sortAsc ? wl.symbols : Array(wl.symbols.reversed())
        }
        return wl.symbols.sorted { (a: String, b: String) -> Bool in
            let qA = lookupQuote(for: a)
            let qB = lookupQuote(for: b)
            switch sortKey {
            case .symbol:
                return sortAsc ? a < b : a > b
            case .price:
                let pA = qA?.price ?? -Double.infinity
                let pB = qB?.price ?? -Double.infinity
                return sortAsc ? pA < pB : pA > pB
            case .changePercent, .metric(.today):
                let cA = qA?.changePercent ?? -Double.infinity
                let cB = qB?.changePercent ?? -Double.infinity
                return sortAsc ? cA < cB : cA > cB
            case .metric(.marketCap):
                let mA = qA?.marketCap ?? -Double.infinity
                let mB = qB?.marketCap ?? -Double.infinity
                return sortAsc ? mA < mB : mA > mB
            default:
                return sortAsc ? a < b : a > b
            }
        }
    }

    private func orderedPortfolioSymbols(in portfolios: [Portfolio]) -> [String] {
        let entries = portfolios.flatMap(\.holdings).filter { $0.quantity != 0 }.map { holding in
            let quote = lookupQuote(for: holding.symbol)
            guard let quote, quote.price.isFinite else {
                return SuperchartPortfolioSymbolOrdering.Entry(symbol: holding.symbol, marketValue: nil)
            }
            let currency = stockService.detectedCurrency(for: holding.symbol)
            let fxRate = stockService.rate(from: currency, to: storageService.preferredCurrency)
            return SuperchartPortfolioSymbolOrdering.Entry(
                symbol: holding.symbol,
                marketValue: holding.marketValue(currentPrice: quote.price) * fxRate
            )
        }
        return SuperchartPortfolioSymbolOrdering.orderedSymbols(from: entries)
    }

    private var filteredSymbols: [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return sourceSymbols }
        return sourceSymbols.filter { $0.localizedCaseInsensitiveContains(needle) }
    }

    private func lookupQuote(for symbol: String) -> StockQuote? {
        if let direct = stockService.quotes[symbol] { return direct }
        let canonical = StockService.canonicalSymbol(for: symbol)
        if let byCanonical = stockService.quotes[canonical] { return byCanonical }
        return stockService.quotes.values.first { StockService.canonicalSymbol(for: $0.symbol) == canonical }
    }

    private var selectedQuote: StockQuote? {
        guard let symbol = selectedSymbol else { return nil }
        return lookupQuote(for: symbol)
    }

    private var selectedHistory: [PricePoint] {
        guard let symbol = selectedSymbol else { return [] }
        let canonical = StockService.canonicalSymbol(for: symbol)
        return stockService.priceHistory[symbol] ?? stockService.priceHistory[canonical] ?? []
    }

    private var selectedMaxHistory: [PricePoint] {
        guard let symbol = selectedSymbol else { return [] }
        let canonical = StockService.canonicalSymbol(for: symbol)
        return stockService.priceHistoryMax[symbol] ?? stockService.priceHistoryMax[canonical] ?? []
    }

    private var selectedTargetPrice: Double? {
        guard let symbol = selectedSymbol else { return nil }
        return storageService.buyTarget(for: symbol)?.targetPrice
    }

    private var selectedAlertLines: [LightweightChartAlertLine] {
        guard let symbol = selectedSymbol else { return [] }
        let canonical = StockService.canonicalSymbol(for: symbol)
        return storageService.alerts.filter {
            $0.isEnabled && StockService.canonicalSymbol(for: $0.symbol) == canonical &&
            ($0.condition == .priceAbove || $0.condition == .priceBelow) &&
            $0.threshold > 0
        }.map {
            let condPrefix = $0.condition == .priceAbove ? "≥" : "≤"
            let dec = StorageService.priceDecimals(symbol: symbol, price: $0.threshold)
            let formatted = StorageService.formatNumber($0.threshold, decimals: dec)
            return LightweightChartAlertLine(
                price: $0.threshold,
                title: "🔔 \(condPrefix) \(formatted)",
                color: "#e67e22"
            )
        }
    }

    private var selectedInsiderMarkers: [LightweightChartMarker] {
        guard storageService.showInsiderMarkers, let symbol = selectedSymbol,
              insiderService.hasExecutedChartTrades(for: symbol) else { return [] }
        let cal = LightweightChartMath.calendar(for: symbol)
        let history = selectedMaxHistory.isEmpty ? selectedHistory : selectedMaxHistory
        let transactions = insiderService.getTransactions(for: symbol,
            startDate: history.first?.date, endDate: history.last?.date,
            openMarketOnly: storageService.insiderOpenMarketOnly)
            .filter { $0.isOpenMarket && !$0.isPendingPlan && $0.shares > 0 }
            .filter { !storageService.excludeInsider10b51 || !$0.isRule10b51 }
        let groups = Dictionary(grouping: transactions) { transaction in
            "\(LightweightChartMath.tradingDay(transaction.transactionDate, using: cal))_\(transaction.isBuy)"
        }
        return groups.keys.sorted().compactMap { key in
            guard let group = groups[key], let trade = group.first else { return nil }
            return LightweightChartMarker(time: LightweightChartMath.tradingDay(trade.transactionDate, using: cal),
                position: trade.isBuy ? "belowBar" : "aboveBar",
                color: trade.isBuy ? "#1a9b82" : "#d94b59",
                shape: trade.isBuy ? "arrowUp" : "arrowDown",
                text: "\(trade.isBuy ? "BUY" : "SELL")\(group.count > 1 ? " \(group.count)x" : "")")
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            symbolList
                .frame(width: isListCollapsed ? 0 : listWidth)
                .clipped()
                .opacity(isListCollapsed ? 0 : 1)
            if !isListCollapsed {
                Rectangle()
                    .fill(DS.hairline)
                    .frame(width: 4)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                        if listDragOrigin == nil { listDragOrigin = listWidth }
                        listWidth = min(420, max(280, (listDragOrigin ?? listWidth) + value.translation.width))
                    }.onEnded { _ in listDragOrigin = nil; UserDefaults.standard.set(listWidth, forKey: "stockdeck.superchart.listWidth") })
                    .help("Kéo để đổi độ rộng danh sách")
            }

            VStack(spacing: 0) {
                chartHeader
                Divider()
                if let symbol = selectedSymbol {
                    if subViewMode == .chart {
                        LightweightPriceChartView(symbol: symbol, points: selectedHistory, maxPoints: selectedMaxHistory,
                            currency: selectedQuote?.currency ?? StockService.detectedCurrency(for: symbol),
                            visibleFrom: nil, markers: selectedInsiderMarkers, targetPrice: selectedTargetPrice,
                            alertLines: selectedAlertLines,
                            isLoading: stockService.isLoading, retry: {
                                Task {
                                    await stockService.ensurePriceHistory(for: symbol)
                                    await stockService.ensurePriceHistoryMax(for: symbol)
                                }
                            }, selectedRange: $chartRange, showsRangePicker: true, surface: .superchart,
                            pineIndicators: pineWorkspace.indicators, pineMenuItems: pineWorkspace.menuItems,
                            onManagePineScripts: { showsPineScripts = true },
                            onCustomPineAction: { id, action in
                                switch action {
                                case "attach": pineWorkspace.attach(id)
                                case "remove": pineWorkspace.remove(id)
                                case "retry": pineWorkspace.retry(id)
                                default: selectedPineSettings = pineWorkspace.indicators.first { $0.id == id }
                                }
                            }, onPineInput: { input in
                                guard selectedSymbol == input.symbol else { return }
                                pineWorkspace.setInput(input)
                            })
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .sheet(item: $selectedPineSettings) { indicator in
                                PineScriptStyleSettingsView(title: indicator.title,
                                    initialPlots: indicator.plots.reduce(into: [:]) { $0[$1.id] = $1 }) { updated in
                                    pineWorkspace.saveStyle(updated, for: indicator.id)
                                }
                            }
                    } else {
                        SymbolDeepDiveView(symbol: symbol, stockService: stockService, storageService: storageService)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    VStack {
                        ContentUnavailableView("Chọn một mã", systemImage: "chart.xyaxis.line",
                            description: Text("Chọn mã từ Watchlist hoặc Portfolio để xem biểu đồ hoặc bảng chi tiết."))
                        Button("Quản lý scripts…") { showsPineScripts = true }.padding(.bottom, 24)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .background(DS.ground)
        .alert("Đổi tên Shortcut", isPresented: $isShortcutEditorPresented) {
            TextField("Tên hiển thị trên thanh Shortcut", text: $editingShortcutText)
            Button("Lưu") {
                if let id = editingShortcutID {
                    saveShortcutAlias(id, alias: editingShortcutText)
                }
                editingShortcutID = nil
            }
            Button("Hủy", role: .cancel) {
                editingShortcutID = nil
            }
        } message: {
            Text("Nhập tên ngắn gọn hiển thị trên thanh nút Shortcut của Superchart:")
        }
        .sheet(isPresented: $showsPineScripts) {
            CustomPineScriptsView(library: pineWorkspace.library)
        }
        .sheet(item: $addToPortfolioTarget) { t in
            HoldingFormSheet(mode: .addSymbol(symbol: t.symbol, portfolioId: t.portfolioId)) { addToPortfolioTarget = nil }
                .environmentObject(stockService).environmentObject(storageService)
        }
        .sheet(isPresented: Binding(
            get: { alertSheetSymbol != nil || !multiAlertSymbols.isEmpty },
            set: { if !$0 { alertSheetSymbol = nil; multiAlertSymbols = [] } }
        )) {
            if let sym = alertSheetSymbol ?? multiAlertSymbols.first {
                PriceAlertSheet(symbol: sym, suggestedSymbols: multiAlertSymbols) {
                    alertSheetSymbol = nil
                    multiAlertSymbols = []
                }
                .environmentObject(stockService).environmentObject(storageService)
            }
        }
        .sheet(isPresented: Binding(
            get: { targetSheetSymbol != nil },
            set: { if !$0 { targetSheetSymbol = nil } }
        )) {
            if let sym = targetSheetSymbol {
                StockTargetSheet(symbol: sym) { targetSheetSymbol = nil }
                    .environmentObject(stockService).environmentObject(storageService)
            }
        }
        .sheet(isPresented: $isSearchSheetPresented) {
            WatchlistSearchSheet { isSearchSheetPresented = false }
                .environmentObject(stockService).environmentObject(storageService)
        }
        .alert("Tạo Watchlist mới", isPresented: $isNewWatchlistAlertPresented) {
            TextField("Tên danh sách theo dõi", text: $newWatchlistName)
            Button("Tạo") {
                let trimmed = newWatchlistName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let wl = storageService.createWatchlist(name: trimmed)
                    selectSource(.watchlist(wl.id))
                }
            }
            Button("Hủy", role: .cancel) {}
        }
        .alert("Đổi tên Watchlist", isPresented: $isRenameWatchlistPresented) {
            TextField("Tên mới", text: $renameWatchlistName)
            Button("Lưu") {
                let trimmed = renameWatchlistName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, case .watchlist(let id) = source {
                    storageService.renameWatchlist(id: id, newName: trimmed)
                }
            }
            Button("Hủy", role: .cancel) {}
        }
        .alert("Xóa Watchlist?", isPresented: $isDeleteWatchlistPresented) {
            Button("Xóa", role: .destructive) {
                if let wl = watchlistToDelete {
                    storageService.deleteWatchlist(id: wl.id)
                    if let next = storageService.watchlists.first {
                        selectSource(.watchlist(next.id))
                    }
                }
                watchlistToDelete = nil
            }
            Button("Hủy", role: .cancel) {
                watchlistToDelete = nil
            }
        } message: {
            Text("Bạn có chắc chắn muốn xóa danh sách \"\(watchlistToDelete?.name ?? "")\"? Các mã trong danh sách sẽ bị xóa.")
        }
        .onChange(of: source) { _, newSource in
            UserDefaults.standard.set(newSource.id, forKey: "stockdeck.superchart.source")
            onSelectSource(newSource)
            let symbols = symbols(for: newSource)
            if let selectedSymbol, symbols.contains(where: {
                StockService.canonicalSymbol(for: $0) == StockService.canonicalSymbol(for: selectedSymbol)
            }) { return }
            self.selectedSymbol = symbols.first
        }
        .onChange(of: sourceSymbols) { _, symbols in
            if let selectedSymbol, symbols.contains(where: {
                StockService.canonicalSymbol(for: $0) == StockService.canonicalSymbol(for: selectedSymbol)
            }) { return }
            self.selectedSymbol = symbols.first
        }
        .onChange(of: initialSource) { _, newSource in source = newSource }
        .onChange(of: selectedSymbol) { _, symbol in
            guard let symbol else { return }
            UserDefaults.standard.set(symbol, forKey: "stockdeck.superchart.symbol")
            Task {
                await stockService.ensurePriceHistory(for: symbol)
                await stockService.ensurePriceHistoryMax(for: symbol)
                if insiderService.isEligibleSymbol(symbol) { await insiderService.ensureTransactions(for: symbol) }
                await EarningsService.shared.ensureEarnings(for: symbol)
                await stockService.ensureQuoteValuation(for: symbol)
                await stockService.ensureKeyStatistics(for: symbol)
            }
        }
        .task(id: source.id) {
            try? await Task.sleep(nanoseconds: 350_000_000)
            let symbolsToWarm = Array(sourceSymbols.prefix(24))
            for sym in symbolsToWarm {
                guard !Task.isCancelled else { break }
                if sym == selectedSymbol { continue }
                await stockService.ensurePriceHistory(for: sym)
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        .task {
            loadFavoritesAndShortcuts()
            if let sourceID = UserDefaults.standard.string(forKey: "stockdeck.superchart.source"),
               let savedSource = source(from: sourceID) { source = savedSource }
            if let saved = UserDefaults.standard.string(forKey: "stockdeck.superchart.symbol"),
               sourceSymbols.contains(where: { StockService.canonicalSymbol(for: $0) == StockService.canonicalSymbol(for: saved) }) {
                selectedSymbol = saved
            }
            if selectedSymbol == nil { selectedSymbol = sourceSymbols.first }
            if let selectedSymbol {
                await stockService.ensurePriceHistory(for: selectedSymbol)
                await stockService.ensurePriceHistoryMax(for: selectedSymbol)
                if insiderService.isEligibleSymbol(selectedSymbol) { await insiderService.ensureTransactions(for: selectedSymbol) }
                await EarningsService.shared.ensureEarnings(for: selectedSymbol)
                await stockService.ensureQuoteValuation(for: selectedSymbol)
                await stockService.ensureKeyStatistics(for: selectedSymbol)
            }
        }
    }

    private var chartHeader: some View {
        HStack(spacing: 10) {
            if let onToggleSidebar {
                Button {
                    onToggleSidebar()
                } label: {
                    Image(systemName: isSidebarCollapsed ? "sidebar.leading" : "sidebar.left")
                        .foregroundStyle(DS.inkSecondary)
                }
                .buttonStyle(.plain)
                .help(isSidebarCollapsed ? "Mở rộng thanh bên Index" : "Thu gọn thanh bên Index")
            }

            Button {
                isListCollapsed.toggle()
                UserDefaults.standard.set(isListCollapsed, forKey: "stockdeck.superchart.listCollapsed")
            } label: {
                Image(systemName: isListCollapsed ? "sidebar.right" : "sidebar.left")
                    .foregroundStyle(DS.inkSecondary)
            }
            .buttonStyle(.plain)
            .help(isListCollapsed ? "Hiện danh sách mã" : "Thu gọn danh sách mã")

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: selectedSymbol ?? "—")
                    .font(.inter(20, weight: .bold, relativeTo: .title2))
                    .foregroundStyle(DS.ink)
                Text(selectedQuote?.name ?? "")
                    .font(DS.micro)
                    .foregroundStyle(DS.inkSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let quote = selectedQuote {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(quote.price, format: .number.precision(.fractionLength(0...4)))
                        .font(.inter(17, weight: .bold, relativeTo: .headline).monospacedDigit())
                        .foregroundStyle(DS.ink)
                    Text(quote.changePercent / 100, format: .percent.precision(.fractionLength(2)))
                        .font(DS.micro.monospacedDigit())
                        .foregroundStyle(DS.pnlColor(quote.changePercent))
                }
            }

            HStack(spacing: 6) {
                Button {
                    if let sym = selectedSymbol { alertSheetSymbol = sym }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bell").font(.system(size: 10, weight: .semibold))
                        Text("Alert").font(.inter(11, weight: .semibold, relativeTo: .caption))
                    }
                    .foregroundStyle(DS.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(DS.cardAlt))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.hairline))
                }
                .buttonStyle(.plain)
                .help("Đặt cảnh báo giá")

                Button {
                    if let sym = selectedSymbol { targetSheetSymbol = sym }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "target").font(.system(size: 10, weight: .semibold))
                        if let t = selectedSymbol.flatMap({ storageService.buyTarget(for: $0) }) {
                            let dec = StorageService.priceDecimals(symbol: selectedSymbol ?? "", price: t.targetPrice)
                            Text("Target: \(StorageService.formatNumber(t.targetPrice, decimals: dec))")
                                .font(.inter(11, weight: .semibold, relativeTo: .caption))
                        } else {
                            Text("Target").font(.inter(11, weight: .semibold, relativeTo: .caption))
                        }
                    }
                    .foregroundStyle(DS.ink)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(DS.cardAlt))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.hairline))
                }
                .buttonStyle(.plain)
                .help("Đặt giá mua mục tiêu")

                if !storageService.portfolios.isEmpty {
                    DSMenu(width: 180, sections: [storageService.portfolios.map { p in
                        DSMenuAction(title: p.name, icon: "briefcase") {
                            if let sym = selectedSymbol {
                                addToPortfolioTarget = AddTarget(symbol: sym, portfolioId: p.id)
                            }
                        }
                    }]) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                            Text("Portfolio").font(.inter(11, weight: .semibold, relativeTo: .caption))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(DS.brand))
                    }
                    .pointingHandCursor()
                    .help("Thêm mã này vào danh mục đầu tư")
                }

                Picker("", selection: $subViewMode) {
                    Label("Biểu đồ", systemImage: "chart.xyaxis.line").tag(SuperchartSubViewMode.chart)
                    Label("Bảng chi tiết", systemImage: "tablecells").tag(SuperchartSubViewMode.table)
                }
                .pickerStyle(.segmented)
                .frame(width: 195)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .background(WindowDragArea())
    }

    private var symbolList: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 28)
                .background(WindowDragArea())

            Button {
                if case .portfolio = source { sourcePickerShowsPortfolios = true }
                else if source == .allPortfolios { sourcePickerShowsPortfolios = true }
                else { sourcePickerShowsPortfolios = false }
                sourceQuery = ""
                isSourcePickerPresented = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: sourceIcon)
                        .foregroundStyle(DS.brand)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sourceTitle)
                            .font(.inter(13, weight: .semibold, relativeTo: .body))
                            .foregroundStyle(DS.ink)
                            .lineLimit(1)
                        Text(sourceKindTitle)
                            .font(.inter(10, weight: .medium, relativeTo: .caption))
                            .foregroundStyle(DS.inkTertiary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: isSourcePickerPresented ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.inkTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(12)
            }
            .buttonStyle(.plain)
            .help("Chọn Watchlist hoặc Portfolio")
            .accessibilityLabel("Nguồn: \(sourceTitle), \(sourceKindTitle)")
            .popover(isPresented: $isSourcePickerPresented, arrowEdge: .top) {
                sourcePicker
            }

            if !favoriteShortcutItems.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(favoriteShortcutItems) { item in
                            Button {
                                selectSource(item.source)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: item.icon)
                                        .font(.system(size: 9, weight: .semibold))
                                    Text(verbatim: item.displayName)
                                        .font(.inter(11, weight: item.isSelected ? .bold : .medium, relativeTo: .caption))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(item.isSelected ? DS.brand : DS.hairline.opacity(0.6))
                                .foregroundStyle(item.isSelected ? Color.white : DS.ink)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .help(item.fullName)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }
            }

            HStack(spacing: 6) {
                TextField("Tìm trong nguồn…", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button {
                    isSearchSheetPresented = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DS.brand)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(DS.brand.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Thêm mã vào nguồn…")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            HStack(spacing: 4) {
                Text("Symbol").frame(maxWidth: .infinity, alignment: .leading)
                Text("Last").frame(width: 76, alignment: .trailing)
                Text("Chg%").frame(width: 60, alignment: .trailing)
                Text("Ext%").frame(width: 56, alignment: .trailing)
            }
            .font(.inter(10, weight: .medium, relativeTo: .caption))
            .foregroundStyle(DS.inkTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if selectedSymbols.count > 1 {
                HStack(spacing: 8) {
                    Text("\(selectedSymbols.count) mã đã chọn")
                        .font(.inter(10.5, weight: .semibold, relativeTo: .caption))
                        .foregroundStyle(DS.ink)
                    Spacer()
                    Button {
                        multiAlertSymbols = Array(selectedSymbols)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "bell.fill").font(.system(size: 9))
                            Text("Alert (\(selectedSymbols.count))")
                                .font(.inter(10, weight: .semibold, relativeTo: .caption))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.brand)

                    if case .watchlist(let wlId) = source {
                        Button {
                            let toRemove = selectedSymbols
                            storageService.removeMultipleFromWatchlist(toRemove, watchlistId: wlId)
                            selectedSymbols.removeAll()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "trash").font(.system(size: 9))
                                Text("Xóa")
                                    .font(.inter(10, weight: .semibold, relativeTo: .caption))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DS.down)
                    }

                    Button {
                        selectedSymbols.removeAll()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(DS.inkTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(DS.brand.opacity(0.08))
                .overlay(Divider().overlay(DS.hairline), alignment: .bottom)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredSymbols, id: \.self) { symbol in
                        if case .watchlist = source {
                            ReorderRow(
                                id: symbol,
                                draggingId: $draggingSymbol,
                                excludedTargets: draggingSymbols,
                                dropIndicator: $dropIndicator,
                                isHorizontal: false,
                                attachDragToContent: false,
                                makeDragItem: {
                                    startDrag(for: symbol)
                                },
                                onMove: { src, tgt, placement in
                                    commitSymbolGroupDrop(sourceSymbol: src, targetSymbol: tgt, placement: placement)
                                },
                                onCommit: {}
                            ) {
                                row(symbol)
                            }
                        } else {
                            row(symbol)
                        }
                    }
                }
            }
            if filteredSymbols.isEmpty {
                ContentUnavailableView(query.isEmpty ? "Nguồn đang trống" : "Không tìm thấy mã",
                    systemImage: query.isEmpty ? "tray" : "magnifyingglass",
                    description: Text(query.isEmpty ? "Thêm mã vào nguồn." : "Thử mã khác trong nguồn này."))
            }

            if selectedSymbol != nil && !isDetailCollapsed {
                Rectangle()
                    .fill(DS.hairline)
                    .frame(height: 4)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                        if detailDragOrigin == nil { detailDragOrigin = detailHeight }
                        detailHeight = min(500, max(160, (detailDragOrigin ?? detailHeight) - value.translation.height))
                    }.onEnded { _ in
                        detailDragOrigin = nil
                        UserDefaults.standard.set(detailHeight, forKey: "stockdeck.superchart.detailHeight")
                    })
                    .help("Kéo để chỉnh chiều cao thông tin mã")
            }

            if let symbol = selectedSymbol {
                detailPane(symbol)
                    .frame(height: isDetailCollapsed ? 28 : detailHeight)
            }
        }
        .background(DS.ground)
    }

    private func detailPane(_ symbol: String) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 4) {
                Text("TỔNG QUAN")
                    .font(.inter(10, weight: .bold, relativeTo: .caption))
                    .foregroundStyle(DS.brand)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(DS.brand.opacity(0.12), in: Capsule())

                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isDetailCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: isDetailCollapsed ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DS.inkTertiary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help(isDetailCollapsed ? "Mở rộng thông tin mã" : "Thu gọn thông tin mã")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(DS.cardAlt.opacity(0.5))

            if !isDetailCollapsed {
                Divider().overlay(DS.hairline)
                detailOverviewContent(symbol)
            }
        }
        .background(DS.ground)
    }

    private func detailOverviewContent(_ symbol: String) -> some View {
        let quote = lookupQuote(for: symbol)

        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // Khối 1: Giá & Trạng thái phiên
                if let quote = quote {
                    let dec = StorageService.priceDecimals(symbol: symbol, price: quote.price)
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(StorageService.currencySymbol(for: quote.currency))\(StorageService.formatNumber(quote.price, decimals: dec))")
                            .font(.inter(15, weight: .bold, relativeTo: .title3).monospacedDigit())
                            .foregroundStyle(DS.ink)
                        let chgSign = quote.change >= 0 ? "+" : ""
                        Text("\(chgSign)\(StorageService.formatNumber(quote.change, decimals: dec)) (\(String(format: "%+.2f%%", quote.changePercent)))")
                            .font(.inter(10.5, weight: .semibold, relativeTo: .caption).monospacedDigit())
                            .foregroundStyle(DS.pnlColor(quote.change))
                        Spacer()
                        Text(quote.marketStateLabel)
                            .font(.inter(9.5, weight: .medium, relativeTo: .caption2))
                            .foregroundStyle(DS.inkSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(DS.cardAlt, in: RoundedRectangle(cornerRadius: 4))
                    }

                    if quote.isExtendedHours, let extPct = quote.extendedChangePercent {
                        let isPre = quote.marketState.hasPrefix("PRE")
                        let extPrice = quote.effectivePrice
                        HStack(spacing: 3) {
                            Image(systemName: isPre ? "sun.max.fill" : "moon.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(DS.inkTertiary)
                            let extDec = StorageService.priceDecimals(symbol: symbol, price: extPrice)
                            Text("\(isPre ? "Pre" : "Post"): \(StorageService.formatNumber(extPrice, decimals: extDec)) (\(String(format: "%+.2f%%", extPct)))")
                                .font(DS.micro.monospacedDigit())
                                .foregroundStyle(DS.pnlColor(extPct))
                        }
                    }
                }

                // Khối 2: Range bars (Day range & 52-week range - kiểu TradingView)
                if let quote = quote {
                    VStack(spacing: 6) {
                        if let low = quote.dayLow, let high = quote.dayHigh, high > low {
                            let pos = max(0, min(1, (quote.price - low) / (high - low)))
                            rangeBar(label: "DAY RANGE", low: low, high: high, pos: pos, symbol: symbol)
                        }
                        if let low = quote.fiftyTwoWeekLow, let high = quote.fiftyTwoWeekHigh, high > low, let pos = quote.fiftyTwoWeekPosition {
                            rangeBar(label: "52-WEEK RANGE", low: low, high: high, pos: pos, symbol: symbol)
                        }
                    }
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(DS.cardAlt.opacity(0.5)))
                }

                // Khối 3: Key stats (Volume, Next Earnings countdown, Market Cap)
                if let quote = quote {
                    let earningsItem = EarningsService.shared.getEarnings(for: symbol)
                    let daysUntil = earningsItem?.daysUntilNextEarnings
                    HStack(spacing: 6) {
                        statBlockSmall(
                            label: "Volume",
                            value: quote.regularMarketVolume.map { StorageService.formatMarketCap($0, currency: "") } ?? "—"
                        )
                        Divider().frame(height: 20)
                        statBlockSmall(
                            label: "Earnings",
                            value: {
                                if let days = daysUntil {
                                    if days == 0 { return "Hôm nay" }
                                    if days > 0 { return "còn \(days) ngày" }
                                    return "đã qua"
                                }
                                return "—"
                            }()
                        )
                        Divider().frame(height: 20)
                        statBlockSmall(
                            label: "Vốn hóa",
                            value: quote.marketCap.map { StorageService.formatMarketCap($0, currency: quote.currency) } ?? "—"
                        )
                    }
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(DS.cardAlt.opacity(0.5)))
                }

                // Khối 4: Vị thế của bạn (nếu có trong Portfolio) - Dùng Native Currency theo AGENTS.md Phần 2 Quy tắc 2
                let canonical = StockService.canonicalSymbol(for: symbol)
                let holdings = storageService.portfolios.flatMap(\.holdings).filter {
                    StockService.canonicalSymbol(for: $0.symbol) == canonical
                }
                if !holdings.isEmpty, let quote = quote {
                    let totalQty = HoldingLotAggregation.totalQuantity(holdings)
                    let avgCost = HoldingLotAggregation.weightedAveragePrice(holdings)
                    let totalVal = holdings.reduce(0) { $0 + $1.marketValue(currentPrice: quote.price) }
                    let totalPnl = holdings.reduce(0) { $1.hasKnownCostBasis ? $0 + $1.pnl(currentPrice: quote.price) : $0 }
                    let totalCost = holdings.reduce(0) { $1.hasKnownCostBasis ? $0 + ($1.avgPrice * $1.quantity / ($1.isJapaneseFund ? 10000.0 : 1.0)) : $0 }
                    let pnlPct = abs(totalCost) >= 0.01 ? (totalPnl / abs(totalCost)) * 100 : 0
                    let currSym = StorageService.currencySymbol(for: quote.currency)
                    let dec = StorageService.priceDecimals(symbol: symbol, price: quote.price)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("VỊ THẾ CỦA BẠN")
                                .font(.inter(9.5, weight: .bold, relativeTo: .caption2))
                                .foregroundStyle(DS.brand)
                            Spacer()
                            Text("\(StorageService.formatNumber(totalQty, decimals: totalQty.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2)) cp")
                                .font(DS.micro.monospacedDigit())
                                .foregroundStyle(DS.inkSecondary)
                        }
                        HStack {
                            statRow("Giá vốn TB", value: "\(currSym)\(StorageService.formatNumber(avgCost, decimals: dec))")
                        }
                        HStack {
                            statRow("Giá trị", value: "\(currSym)\(StorageService.formatNumber(totalVal, decimals: dec))")
                        }
                        HStack {
                            Text("Lãi/Lỗ")
                                .font(DS.micro)
                                .foregroundStyle(DS.inkSecondary)
                            Spacer()
                            let sign = totalPnl >= 0 ? "+" : ""
                            Text("\(sign)\(currSym)\(StorageService.formatNumber(totalPnl, decimals: dec)) (\(String(format: "%+.2f%%", pnlPct)))")
                                .font(DS.micro.monospacedDigit())
                                .foregroundStyle(DS.pnlColor(totalPnl))
                        }
                    }
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(DS.brand.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(DS.brand.opacity(0.2), lineWidth: 1))
                }

                // Khối 5: Hiệu suất & Định giá gọn
                let row = watchlistViewModel?.rowsBySymbol[symbol]
                let m1 = row?.oneMonthChangePercent ?? PriceHistory.percentChange(points: selectedHistory, currentPrice: quote?.price ?? 0, since: Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date())
                let m3 = row?.threeMonthChangePercent ?? PriceHistory.percentChange(points: selectedHistory, currentPrice: quote?.price ?? 0, since: Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date())
                let m6 = row?.sixMonthChangePercent ?? PriceHistory.percentChange(points: selectedHistory, currentPrice: quote?.price ?? 0, since: Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? Date())
                let ytd = row?.ytdChangePercent ?? PriceHistory.percentChange(points: selectedHistory, currentPrice: quote?.price ?? 0, since: Calendar.current.date(from: Calendar.current.dateComponents([.year], from: Date())) ?? Date())
                let y1 = row?.oneYearChangePercent ?? PriceHistory.percentChange(points: selectedMaxHistory.isEmpty ? selectedHistory : selectedMaxHistory, currentPrice: quote?.price ?? 0, since: Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date())
                let y3 = row?.threeYearChangePercent ?? PriceHistory.percentChange(points: selectedMaxHistory.isEmpty ? selectedHistory : selectedMaxHistory, currentPrice: quote?.price ?? 0, since: Calendar.current.date(byAdding: .year, value: -3, to: Date()) ?? Date())

                VStack(alignment: .leading, spacing: 3) {
                    Text("HIỆU SUẤT")
                        .font(.inter(9.5, weight: .bold, relativeTo: .caption2))
                        .foregroundStyle(DS.inkTertiary)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                        performanceCell(label: "1M", value: m1)
                        performanceCell(label: "3M", value: m3)
                        performanceCell(label: "6M", value: m6)
                        performanceCell(label: "YTD", value: ytd)
                        performanceCell(label: "1Y", value: y1)
                        performanceCell(label: "3Y", value: y3)
                    }
                }

                if let quote = quote {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ĐỊNH GIÁ GỌN")
                            .font(.inter(9.5, weight: .bold, relativeTo: .caption2))
                            .foregroundStyle(DS.inkTertiary)

                        VStack(spacing: 3) {
                            if let pe = quote.trailingPE, pe > 0 {
                                statRow("P/E (TTM)", value: String(format: "%.2f", pe))
                            }
                            if let fpe = quote.forwardPE, fpe > 0 {
                                statRow("Forward P/E", value: String(format: "%.2f", fpe))
                            }
                            if let pb = quote.priceToBook, pb > 0 {
                                statRow("P/B", value: String(format: "%.2f", pb))
                            }
                            if let eps = quote.epsTrailingTwelveMonths {
                                statRow("EPS (TTM)", value: String(format: "%.2f", eps))
                            }
                            if let div = quote.dividendYield, div > 0 {
                                statRow("Cổ tức", value: String(format: "%.2f%%", div))
                            }
                        }
                        .padding(7)
                        .background(RoundedRectangle(cornerRadius: 7).fill(DS.cardAlt.opacity(0.5)))
                    }
                }
            }
            .padding(8)
        }
    }

    private func rangeBar(label: String, low: Double, high: Double, pos: Double, symbol: String) -> some View {
        let dec = StorageService.priceDecimals(symbol: symbol, price: low)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.inter(8.5, weight: .bold, relativeTo: .caption2))
                    .foregroundStyle(DS.inkTertiary)
                Spacer()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.cardAlt).frame(height: 4)
                    Circle()
                        .fill(DS.brand)
                        .frame(width: 8, height: 8)
                        .offset(x: CGFloat(pos) * max(0, geo.size.width - 8))
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 8)
            HStack {
                Text(StorageService.formatNumber(low, decimals: dec))
                    .font(DS.micro.monospacedDigit())
                    .foregroundStyle(DS.inkSecondary)
                Spacer()
                Text(StorageService.formatNumber(high, decimals: dec))
                    .font(DS.micro.monospacedDigit())
                    .foregroundStyle(DS.inkSecondary)
            }
        }
    }

    private func statBlockSmall(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.inter(8.5, weight: .bold, relativeTo: .caption2))
                .foregroundStyle(DS.inkTertiary)
            Text(verbatim: value)
                .font(.inter(10, weight: .semibold, relativeTo: .caption).monospacedDigit())
                .foregroundStyle(DS.ink)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func performanceCell(label: String, value: Double?) -> some View {
        VStack(spacing: 1) {
            Text(label).font(DS.micro).foregroundStyle(DS.inkTertiary)
            Text(value.map { String(format: "%+.2f%%", $0) } ?? "—")
                .font(.inter(10, weight: .semibold, relativeTo: .caption).monospacedDigit())
                .foregroundStyle(value.map { DS.pnlColor($0) } ?? DS.inkSecondary)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 6).fill(DS.cardAlt))
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).font(DS.micro).foregroundStyle(DS.inkSecondary)
            Spacer()
            Text(verbatim: value).font(DS.micro.monospacedDigit()).foregroundStyle(DS.ink)
        }
    }

    private func handleRowSelection(symbol: String) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) || flags.contains(.shift) {
            if selectedSymbols.contains(symbol) {
                selectedSymbols.remove(symbol)
            } else {
                selectedSymbols.insert(symbol)
            }
            if selectedSymbols.contains(symbol) {
                selectedSymbol = symbol
            }
        } else {
            selectedSymbol = symbol
            if !selectedSymbols.contains(symbol) {
                selectedSymbols = [symbol]
            }
        }
    }

    private func startDrag(for symbol: String) -> NSItemProvider {
        let group: Set<String> = selectedSymbols.contains(symbol) ? selectedSymbols : [symbol]
        DispatchQueue.main.async {
            draggingSymbol = symbol
            draggingSymbols = group
        }
        return NSItemProvider(object: symbol as NSString)
    }

    private func commitSymbolGroupDrop(sourceSymbol: String, targetSymbol: String, placement: InsertPlacement) {
        guard case .watchlist(let wlId) = source else { return }
        let group = draggingSymbols.isEmpty ? Set([sourceSymbol]) : draggingSymbols
        guard !group.contains(targetSymbol) else { return }
        let currentVisible = filteredSymbols
        if let updated = storageService.moveWatchlistSymbols(
            group,
            relativeTo: targetSymbol,
            placement: placement,
            in: currentVisible,
            watchlistId: wlId
        ) {
            watchlistViewModel?.applyManualOrder(updated)
        }
    }

    private func row(_ symbol: String) -> some View {
        let canonical = StockService.canonicalSymbol(for: symbol)
        let quote = lookupQuote(for: symbol)
        let isPrimarySelected = StockService.canonicalSymbol(for: selectedSymbol ?? "") == canonical
        let isMulti = selectedSymbols.contains(symbol)
        let hasAlert = storageService.alerts.contains { $0.isEnabled && StockService.canonicalSymbol(for: $0.symbol) == canonical }
        let hasTarget = storageService.buyTarget(for: symbol) != nil

        return SuperchartSymbolRowView(
            symbol: symbol,
            name: quote?.name,
            currency: quote?.currency,
            price: quote?.price,
            changePercent: quote?.changePercent,
            extendedChangePercent: quote?.extendedChangePercent,
            isSelected: isPrimarySelected || isMulti,
            hasAlert: hasAlert,
            hasTarget: hasTarget,
            onSelect: { handleRowSelection(symbol: symbol) },
            onSetAlert: {
                if selectedSymbols.count > 1 && selectedSymbols.contains(symbol) {
                    multiAlertSymbols = Array(selectedSymbols)
                } else {
                    alertSheetSymbol = symbol
                }
            },
            onSetTarget: { targetSheetSymbol = symbol },
            onAddToWatchlist: { wlId in
                if selectedSymbols.count > 1 && selectedSymbols.contains(symbol) {
                    storageService.addMultipleToWatchlist(selectedSymbols, targetWatchlistId: wlId)
                } else {
                    storageService.addToWatchlist(symbol, targetWatchlistId: wlId)
                }
            },
            onAddToPortfolio: { pId in
                addToPortfolioTarget = AddTarget(symbol: symbol, portfolioId: pId)
            },
            onRemove: {
                if case .watchlist(let wlId) = source {
                    if selectedSymbols.count > 1 && selectedSymbols.contains(symbol) {
                        let toRemove = selectedSymbols
                        storageService.removeMultipleFromWatchlist(toRemove, watchlistId: wlId)
                        selectedSymbols.removeAll()
                    } else {
                        storageService.removeFromWatchlist(symbol, watchlistId: wlId)
                    }
                }
            },
            watchlists: storageService.watchlists,
            portfolios: storageService.portfolios,
            selectedCount: selectedSymbols.contains(symbol) ? selectedSymbols.count : 0
        )
        .equatable()
    }

    private var sourceTitle: String {
        switch source {
        case .watchlist(let id): return storageService.watchlists.first(where: { $0.id == id })?.name ?? "Watchlist"
        case .portfolio(let id): return storageService.portfolios.first(where: { $0.id == id })?.name ?? "Portfolio"
        case .allPortfolios: return "Tất cả danh mục"
        }
    }

    private var sourceKindTitle: String {
        switch source {
        case .watchlist: "Theo dõi"
        case .portfolio, .allPortfolios: "Danh mục"
        }
    }

    private var sourcePicker: some View {
        VStack(spacing: 10) {
            Picker("Loại nguồn", selection: $sourcePickerShowsPortfolios) {
                Text("Theo dõi").tag(false)
                Text("Danh mục").tag(true)
            }
            .pickerStyle(.segmented)

            TextField("Tìm danh sách…", text: $sourceQuery)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(spacing: 2) {
                    if sourcePickerShowsPortfolios {
                        if matchesSourceQuery("Tất cả danh mục") {
                            sourcePickerRow("Tất cả danh mục", icon: "briefcase",
                                            sourceID: "all-portfolios",
                                            selected: source == .allPortfolios) {
                                selectSource(.allPortfolios)
                            }
                        }
                        if storageService.portfolios.filter({ matchesSourceQuery($0.name) }).isEmpty,
                           !matchesSourceQuery("Tất cả danh mục") {
                            ContentUnavailableView("Không tìm thấy danh mục", systemImage: "magnifyingglass")
                        }
                        ForEach(storageService.portfolios.filter { matchesSourceQuery($0.name) }) { portfolio in
                            let idStr = "portfolio:\(portfolio.id.uuidString)"
                            sourcePickerRow(portfolio.name, icon: "briefcase",
                                            sourceID: idStr,
                                            selected: source == .portfolio(portfolio.id)) {
                                selectSource(.portfolio(portfolio.id))
                            }
                        }
                    } else {
                        if storageService.watchlists.filter({ matchesSourceQuery($0.name) }).isEmpty {
                            ContentUnavailableView("Không tìm thấy danh sách", systemImage: "magnifyingglass")
                        }
                        ForEach(storageService.watchlists.filter { matchesSourceQuery($0.name) }) { watchlist in
                            let idStr = "watchlist:\(watchlist.id.uuidString)"
                            sourcePickerRow(watchlist.name, icon: "star",
                                            sourceID: idStr,
                                            selected: source == .watchlist(watchlist.id)) {
                                selectSource(.watchlist(watchlist.id))
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 300)

            Divider().overlay(DS.hairline)

            HStack(spacing: 8) {
                Button {
                    newWatchlistName = ""
                    isSourcePickerPresented = false
                    isNewWatchlistAlertPresented = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 11))
                        Text("Tạo Watchlist mới").font(.inter(11, weight: .medium, relativeTo: .caption))
                    }
                    .foregroundStyle(DS.brand)
                }
                .buttonStyle(.plain)

                Spacer()

                if case .watchlist(let id) = source, let wl = storageService.watchlists.first(where: { $0.id == id }) {
                    Button {
                        renameWatchlistName = wl.name
                        isSourcePickerPresented = false
                        isRenameWatchlistPresented = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.inkSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Đổi tên Watchlist này")

                    Button {
                        watchlistToDelete = wl
                        isSourcePickerPresented = false
                        isDeleteWatchlistPresented = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.down)
                    }
                    .buttonStyle(.plain)
                    .help("Xóa Watchlist này")
                }
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(width: 320)
    }

    private func matchesSourceQuery(_ name: String) -> Bool {
        let needle = sourceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || name.localizedCaseInsensitiveContains(needle)
    }

    private func selectSource(_ newSource: SuperchartSource) {
        source = newSource
        isSourcePickerPresented = false
        sourceQuery = ""
    }

    private func sourcePickerRow(_ title: String, icon: String, sourceID: String, selected: Bool,
                                 action: @escaping () -> Void) -> some View {
        let isFav = favoriteSourceIDs.contains(sourceID)
        let alias = sourceShortcuts[sourceID]
        return HStack(spacing: 6) {
            Button {
                toggleFavoriteSource(sourceID)
            } label: {
                Image(systemName: isFav ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(isFav ? Color.orange : DS.inkTertiary)
                    .frame(width: 20, height: 28)
            }
            .buttonStyle(.plain)
            .help(isFav ? "Bỏ ghim khỏi thanh Shortcut" : "Ghim lên thanh Shortcut")

            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? DS.brand : DS.inkTertiary)
                        .frame(width: 16)
                    Text(title)
                        .font(.inter(12, weight: selected ? .semibold : .regular, relativeTo: .body))
                        .foregroundStyle(selected ? DS.brand : DS.ink)
                        .lineLimit(1)
                    if let alias, alias != title {
                        Text(verbatim: "→ \(alias)")
                            .font(DS.micro)
                            .foregroundStyle(DS.inkTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DS.brand)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                editingShortcutID = sourceID
                editingShortcutText = sourceShortcuts[sourceID] ?? title
                isShortcutEditorPresented = true
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.inkTertiary)
                    .frame(width: 20, height: 28)
            }
            .buttonStyle(.plain)
            .help("Đổi tên hiển thị trên thanh Shortcut")
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? DS.brand.opacity(0.10) : .clear)
    }

    private struct SuperchartShortcutItem: Identifiable {
        let id: String
        let source: SuperchartSource
        let displayName: String
        let fullName: String
        let icon: String
        let isSelected: Bool
    }

    private var favoriteShortcutItems: [SuperchartShortcutItem] {
        favoriteSourceIDs.compactMap { id -> SuperchartShortcutItem? in
            guard let src = source(from: id) else { return nil }
            let isSelected = src.id == source.id
            let fullName: String
            let icon: String
            switch src {
            case .watchlist(let uuid):
                guard let wl = storageService.watchlists.first(where: { $0.id == uuid }) else { return nil }
                fullName = wl.name
                icon = "star.fill"
            case .portfolio(let uuid):
                guard let pf = storageService.portfolios.first(where: { $0.id == uuid }) else { return nil }
                fullName = pf.name
                icon = "briefcase.fill"
            case .allPortfolios:
                fullName = "Tất cả danh mục"
                icon = "briefcase.fill"
            }
            let alias = sourceShortcuts[id] ?? fullName
            return SuperchartShortcutItem(id: id, source: src, displayName: alias, fullName: fullName, icon: icon, isSelected: isSelected)
        }
    }

    private func loadFavoritesAndShortcuts() {
        if let savedFavs = UserDefaults.standard.stringArray(forKey: "stockdeck.superchart.favoriteSources.v1") {
            favoriteSourceIDs = savedFavs
        } else {
            let defaults = storageService.watchlists.prefix(2).map { "watchlist:\($0.id.uuidString)" }
            favoriteSourceIDs = defaults
            UserDefaults.standard.set(defaults, forKey: "stockdeck.superchart.favoriteSources.v1")
        }
        if let savedShortcuts = UserDefaults.standard.dictionary(forKey: "stockdeck.superchart.sourceShortcuts.v1") as? [String: String] {
            sourceShortcuts = savedShortcuts
        }
    }

    private func toggleFavoriteSource(_ id: String) {
        if favoriteSourceIDs.contains(id) {
            favoriteSourceIDs.removeAll { $0 == id }
        } else {
            favoriteSourceIDs.append(id)
        }
        UserDefaults.standard.set(favoriteSourceIDs, forKey: "stockdeck.superchart.favoriteSources.v1")
    }

    private func saveShortcutAlias(_ id: String, alias: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            sourceShortcuts.removeValue(forKey: id)
        } else {
            sourceShortcuts[id] = trimmed
        }
        UserDefaults.standard.set(sourceShortcuts, forKey: "stockdeck.superchart.sourceShortcuts.v1")
    }

    private var sourceIcon: String {
        switch source {
        case .watchlist: "star"
        case .portfolio, .allPortfolios: "briefcase"
        }
    }

    private func symbols(for source: SuperchartSource) -> [String] {
        switch source {
        case .watchlist(let id):
            guard let wl = storageService.watchlists.first(where: { $0.id == id }) else { return [] }
            if let vm = watchlistViewModel, id == storageService.selectedWatchlistId, !vm.displaySymbols.isEmpty {
                return vm.displaySymbols
            }
            return sortedWatchlistSymbols(for: wl)
        case .portfolio(let id):
            guard let portfolio = storageService.portfolios.first(where: { $0.id == id }) else { return [] }
            return orderedPortfolioSymbols(in: [portfolio])
        case .allPortfolios:
            return orderedPortfolioSymbols(in: storageService.portfolios)
        }
    }

    private func source(from id: String) -> SuperchartSource? {
        if id == "all-portfolios" { return .allPortfolios }
        let parts = id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let uuid = UUID(uuidString: String(parts[1])) else { return nil }
        switch parts[0] {
        case "watchlist" where storageService.watchlists.contains(where: { $0.id == uuid }): return .watchlist(uuid)
        case "portfolio" where storageService.portfolios.contains(where: { $0.id == uuid }): return .portfolio(uuid)
        default: return nil
        }
    }
}

struct SuperchartSymbolRowView: View, Equatable {
    let symbol: String
    let name: String?
    let currency: String?
    let price: Double?
    let changePercent: Double?
    let extendedChangePercent: Double?
    let isSelected: Bool
    let hasAlert: Bool
    let hasTarget: Bool
    let onSelect: () -> Void
    var onSetAlert: (() -> Void)? = nil
    var onSetTarget: (() -> Void)? = nil
    var onAddToWatchlist: ((UUID) -> Void)? = nil
    var onAddToPortfolio: ((UUID) -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    var watchlists: [Watchlist] = []
    var portfolios: [Portfolio] = []
    var selectedCount: Int = 0

    static func == (lhs: SuperchartSymbolRowView, rhs: SuperchartSymbolRowView) -> Bool {
        lhs.symbol == rhs.symbol &&
        lhs.name == rhs.name &&
        lhs.currency == rhs.currency &&
        lhs.price == rhs.price &&
        lhs.changePercent == rhs.changePercent &&
        lhs.extendedChangePercent == rhs.extendedChangePercent &&
        lhs.isSelected == rhs.isSelected &&
        lhs.hasAlert == rhs.hasAlert &&
        lhs.hasTarget == rhs.hasTarget &&
        lhs.selectedCount == rhs.selectedCount
    }

    var body: some View {
        let priceText: String = {
            guard let price, let currency else { return "—" }
            return "\(StorageService.currencySymbol(for: currency))\(StorageService.formatNumber(price, decimals: StorageService.defaultDecimals(for: currency)))"
        }()
        let changeText = changePercent.map { String(format: "%.2f%%", $0) } ?? "—"
        let changeColor = changePercent.map { DS.pnlColor($0) } ?? DS.inkTertiary
        let extText = extendedChangePercent.map { String(format: "%.2f%%", $0) } ?? "—"

        Button(action: onSelect) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        Text(verbatim: symbol).font(.inter(12, weight: .semibold, relativeTo: .body)).foregroundStyle(DS.ink)
                        if hasAlert {
                            Image(systemName: "bell.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Color.orange)
                        }
                        if hasTarget {
                            Text("🎯")
                                .font(.system(size: 8))
                        }
                    }
                    if let name, name != symbol {
                        Text(name).font(DS.micro).foregroundStyle(DS.inkTertiary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: priceText)
                    .font(.inter(11, weight: .medium, relativeTo: .caption).monospacedDigit())
                    .foregroundStyle(DS.ink).frame(width: 76, alignment: .trailing)
                Text(verbatim: changeText)
                    .font(.inter(10, weight: .medium, relativeTo: .caption).monospacedDigit())
                    .foregroundStyle(changeColor)
                    .frame(width: 60, alignment: .trailing)
                Text(verbatim: extText)
                    .font(.inter(10, weight: .medium, relativeTo: .caption).monospacedDigit())
                    .foregroundStyle(DS.inkSecondary).frame(width: 56, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? DS.brand.opacity(0.10) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if selectedCount > 1 {
                if let onSetAlert {
                    Button { onSetAlert() } label: { Label("Set Price Alert (\(selectedCount) symbols)…", systemImage: "bell") }
                }
                if !watchlists.isEmpty, let onAddToWatchlist {
                    Menu {
                        ForEach(watchlists) { wl in
                            Button(wl.name) {
                                onAddToWatchlist(wl.id)
                            }
                        }
                    } label: {
                        Label("Add (\(selectedCount) symbols) to Watchlist", systemImage: "star.bubble")
                    }
                }
                if let onRemove {
                    Divider()
                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Label("Remove (\(selectedCount) symbols) from Watchlist", systemImage: "trash")
                    }
                }
            } else {
                if let onSetAlert {
                    Button { onSetAlert() } label: { Label("Set Price Alert…", systemImage: "bell") }
                }
                if let onSetTarget {
                    Button { onSetTarget() } label: { Label("Set Buy Target…", systemImage: "target") }
                }
                if !watchlists.isEmpty, let onAddToWatchlist {
                    Menu {
                        ForEach(watchlists) { wl in
                            Button {
                                onAddToWatchlist(wl.id)
                            } label: {
                                if wl.symbols.contains(symbol) {
                                    Label(wl.name, systemImage: "checkmark")
                                } else {
                                    Text(wl.name)
                                }
                            }
                        }
                    } label: {
                        Label("Add to Watchlist", systemImage: "star.bubble")
                    }
                }
                if !portfolios.isEmpty, let onAddToPortfolio {
                    Menu {
                        ForEach(portfolios) { p in
                            Button(p.name) {
                                onAddToPortfolio(p.id)
                            }
                        }
                    } label: {
                        Label("Add to Portfolio", systemImage: "plus.rectangle.on.folder")
                    }
                }
                if let onRemove {
                    Divider()
                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Label("Remove from Watchlist", systemImage: "trash")
                    }
                }
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(DS.hairline).frame(height: 1) }
    }
}
