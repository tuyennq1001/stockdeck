import SwiftUI
import UniformTypeIdentifiers

private enum PortfolioCol {
    static let symbol: CGFloat = 104
    static let avgPrice: CGFloat = 75
    static let cost: CGFloat = 82
    static let price: CGFloat = 80
    static let change: CGFloat = 78
    static let value: CGFloat = 84
    static let todayPnl: CGFloat = 92
    static let totalPnl: CGFloat = 92
    static let shares: CGFloat = 68
    static let lots: CGFloat = 55
    static let weight: CGFloat = 66
}

struct PortfolioListView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @State private var viewModel = PortfolioViewModel(scope: .all)
    @State private var showNewPortfolio = false
    @State private var showBinanceSheet = false
    @State private var newPortfolioName = ""
    @State private var searchText = ""
    @State private var importAlert: String?
    @State private var pendingImportResult: PortfolioIO.ImportResult? = nil
    @State private var confirmDeletePortfolio: Portfolio? = nil
    @State private var renamingPortfolio: Portfolio? = nil
    @State private var renamePortfolioName = ""
    @State private var confirmDeleteHolding: (holding: Holding, portfolioId: UUID)? = nil
    @State private var selectedPortfolioId: UUID? = nil
    @State private var draggingPortfolioId: UUID? = nil
    @State private var previewPortfolioIds: [UUID] = []

    static let defaultPopoverColumns: [PortfolioColumnMetric] = [.price, .change, .value, .totalPnl]

    var filteredPortfolios: [Portfolio] {
        guard !searchText.isEmpty else { return storageService.portfolios }
        let query = searchText.lowercased()
        return storageService.portfolios.filter { portfolio in
            portfolio.name.lowercased().contains(query) ||
            portfolio.holdings.contains { $0.symbol.lowercased().contains(query) }
        }
    }

    @ViewBuilder
    private func columnHeader(_ col: PortfolioColumnMetric) -> some View {
        switch col {
        case .avgPrice:
            Text("Avg Price").frame(width: PortfolioCol.avgPrice, alignment: .trailing)
        case .cost:
            Text("Cost").frame(width: PortfolioCol.cost, alignment: .trailing)
        case .price:
            Text("Price").frame(width: PortfolioCol.price, alignment: .trailing)
        case .change:
            Text("Today %").frame(width: PortfolioCol.change, alignment: .trailing)
        case .value:
            Text("Value").frame(width: PortfolioCol.value, alignment: .trailing)
        case .todayPnl:
            Text("Today PnL").frame(width: PortfolioCol.todayPnl, alignment: .trailing)
        case .totalPnl:
            Text("Total PnL").frame(width: PortfolioCol.totalPnl, alignment: .trailing)
        case .shares:
            Text("Shares").frame(width: PortfolioCol.shares, alignment: .trailing)
        case .lots:
            Text("Lots").frame(width: PortfolioCol.lots, alignment: .trailing)
        case .weight:
            Text("Weight").frame(width: PortfolioCol.weight, alignment: .trailing)
        }
    }

    private var deletePortfolioAlertBinding: Binding<Bool> {
        Binding(
            get: { confirmDeletePortfolio != nil },
            set: { if !$0 { confirmDeletePortfolio = nil } }
        )
    }

    private var deleteHoldingAlertBinding: Binding<Bool> {
        Binding(
            get: { confirmDeleteHolding != nil },
            set: { if !$0 { confirmDeleteHolding = nil } }
        )
    }

    var body: some View {
        Group {
        if storageService.portfolios.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "briefcase")
                    .font(.inter(32, relativeTo: .largeTitle))
                    .foregroundColor(.secondary)
                Text("No portfolios")
                    .foregroundColor(.secondary)
                Button("Create portfolio") {
                    newPortfolioName = ""
                    showNewPortfolio = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointingHandCursor()
                Spacer()
            }
        } else {
            VStack(spacing: 0) {
                // Horizontal Portfolio Picker Bar (All Portfolios - Portfolio 1 - Portfolio 2...)
                portfolioPickerBar

                Divider()

                // Total summary for selected tab
                if storageService.portfolios.count > 0 {
                    let currSym = StorageService.currencySymbol(for: storageService.preferredCurrency)
                    let totalVal = viewModel.valuationCache.totalValue
                    let pnl = viewModel.valuationCache.totalPnl
                    let pnlPct = viewModel.valuationCache.totalPnlPercent
                    let todayGain = viewModel.valuationCache.dayChangeValue
                    let todayPct = viewModel.valuationCache.dayChangePercent

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Total value")
                                .font(.inter(10, relativeTo: .caption))
                                .foregroundColor(.secondary)
                            Text(StorageService.formatAmount(totalVal, symbol: currSym, decimals: storageService.amountDecimals))
                                .font(.inter(13.5, relativeTo: .body).monospacedDigit())
                                .fontWeight(.bold)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("Today PnL")
                                    .font(.inter(10, relativeTo: .caption))
                                    .foregroundColor(.secondary)
                                HStack(spacing: 2) {
                                    Text(StorageService.formatAmount(todayGain, symbol: currSym, decimals: storageService.amountDecimals, signed: true))
                                    Text(String(format: "(%.\(storageService.percentDecimals)f%%)", todayPct))
                                }
                                .font(.inter(11, relativeTo: .caption).monospacedDigit())
                                .fontWeight(.semibold)
                                .foregroundColor(todayGain >= 0 ? DS.up : DS.down)
                            }

                            HStack(spacing: 6) {
                                Text("Total PnL")
                                    .font(.inter(10, relativeTo: .caption))
                                    .foregroundColor(.secondary)
                                HStack(spacing: 2) {
                                    Text(StorageService.formatAmount(pnl, symbol: currSym, decimals: storageService.amountDecimals, signed: true))
                                    Text(String(format: "(%.\(storageService.percentDecimals)f%%)", pnlPct))
                                }
                                .font(.inter(11, relativeTo: .caption).monospacedDigit())
                                .fontWeight(.bold)
                                .foregroundColor(pnl >= 0 ? DS.up : DS.down)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()
                }

                let globals = globalPositions
                if !globals.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        let activeCols = PortfolioListView.defaultPopoverColumns
                        HStack(spacing: 0) {
                            Text("Symbol")
                                .frame(width: PortfolioCol.symbol, alignment: .leading)
                            ForEach(activeCols, id: \.self) { col in
                                columnHeader(col)
                            }
                        }
                        .font(.inter(10.5, weight: .semibold, relativeTo: .caption2))
                        .foregroundColor(.secondary)
                        .tracking(0.8)
                        .textCase(.uppercase)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)

                        Divider()

                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(spacing: 0) {
                                ForEach(globals) { p in
                                    PortfolioQuoteRow(stockService: stockService, globalPos: p)
                                    if p.id != globals.last?.id {
                                        Divider().padding(.leading, PortfolioCol.symbol)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } else {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                        }
                    }
                }

                Divider()

                HStack(spacing: 12) {
                    Button(action: {
                        newPortfolioName = ""
                        showNewPortfolio = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Portfolio")
                        }
                        .font(.inter(10, relativeTo: .caption))
                    }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()

                    Button(action: { showBinanceSheet = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "circle.hexagongrid.fill")
                                .foregroundColor(.yellow)
                            Text("Connect Binance")
                        }
                        .font(.inter(10, relativeTo: .caption))
                    }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        }
        
        .onChange(of: selectedPortfolioId) { _, newValue in
            if let id = newValue {
                viewModel.scope = .portfolio(id)
            } else {
                viewModel.scope = .all
            }
        }
        .task {
            viewModel.setup(stockService: stockService, storageService: storageService)
        }
        .onChange(of: draggingPortfolioId) { _, newValue in
            if newValue == nil { previewPortfolioIds = [] }
        }
        .sheet(isPresented: $showBinanceSheet) {
            AddBinancePortfolioSheet(storageService: storageService)
        }
        .sheet(item: $pendingImportResult) { res in
            ImportPreviewSheet(
                items: res.items,
                closedTrades: res.closedTrades,
                transactions: res.transactions,
                suggestedPortfolioName: res.suggestedPortfolioName,
                isFundImport: res.isFundImport
            ) {
                pendingImportResult = nil
            }
            .environmentObject(stockService)
            .environmentObject(storageService)
        }
        .dsAlert(Binding(get: { importAlert != nil }, set: { if !$0 { importAlert = nil } }),
                 title: "Import", message: importAlert ?? "", confirmTitle: "OK", cancelTitle: nil, onConfirm: {})
        .alert("Delete Portfolio", isPresented: deletePortfolioAlertBinding) {
            Button("Cancel", role: .cancel) { confirmDeletePortfolio = nil }
            Button("Delete", role: .destructive) {
                if let p = confirmDeletePortfolio {
                    storageService.deletePortfolio(id: p.id)
                }
                confirmDeletePortfolio = nil
            }
        } message: {
            Text("Are you sure you want to delete portfolio '\(confirmDeletePortfolio?.name ?? "")'? This action cannot be undone.")
        }
        .alert("New Portfolio", isPresented: $showNewPortfolio) {
            TextField("Portfolio name", text: $newPortfolioName)
            Button("Cancel", role: .cancel) { }
            Button("Create") {
                createPortfolio()
            }
        } message: {
            Text("Enter a name for the new portfolio:")
        }
        .alert("Rename Portfolio", isPresented: Binding(
            get: { renamingPortfolio != nil },
            set: { if !$0 { renamingPortfolio = nil } }
        )) {
            TextField("Portfolio name", text: $renamePortfolioName)
            Button("Cancel", role: .cancel) { renamingPortfolio = nil }
            Button("Save") {
                if let p = renamingPortfolio {
                    storageService.renamePortfolio(id: p.id, name: renamePortfolioName)
                    renamingPortfolio = nil
                }
            }
        } message: {
            Text("Enter a new name for this portfolio:")
        }
        .alert("Delete Holding", isPresented: deleteHoldingAlertBinding) {
            Button("Cancel", role: .cancel) { confirmDeleteHolding = nil }
            Button("Delete", role: .destructive) {
                if let target = confirmDeleteHolding {
                    storageService.removeHolding(from: target.portfolioId, holdingId: target.holding.id)
                }
                confirmDeleteHolding = nil
            }
        } message: {
            Text("Are you sure you want to delete \(confirmDeleteHolding?.holding.symbol ?? "")? This action cannot be undone.")
        }
    }

    private var activePortfoliosForSummary: [Portfolio] {
        if let pId = selectedPortfolioId {
            return storageService.portfolios.filter { $0.id == pId }
        }
        return storageService.portfolios
    }

    private var portfolioPickerBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    let isAllSelected = selectedPortfolioId == nil
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedPortfolioId = nil
                            proxy.scrollTo("all_portfolios_tab", anchor: .center)
                        }
                    }) {
                        Text("All Portfolios")
                            .font(.inter(11.5, weight: isAllSelected ? .semibold : .medium, relativeTo: .caption))
                            .foregroundColor(isAllSelected ? .white : DS.ink)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(isAllSelected ? DS.brand : Color.primary.opacity(0.06))
                            )
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .id("all_portfolios_tab")

                    ForEach(displayedPortfolios) { p in
                        let selected = p.id == selectedPortfolioId
                        ReorderRow(
                            id: p.id,
                            draggingId: $draggingPortfolioId,
                            isHorizontal: true,
                            makeDragItem: {
                                if previewPortfolioIds.isEmpty { previewPortfolioIds = storageService.portfolios.map(\.id) }
                                return NSItemProvider(object: p.id.uuidString as NSString)
                            },
                            onMove: { srcId, tgtId, placement in
                                movePortfolioInPreview(srcId, relativeTo: tgtId, placement: placement)
                            },
                            onCommit: { commitPortfolioPreview() }
                        ) {
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedPortfolioId = p.id
                                    proxy.scrollTo(p.id, anchor: .center)
                                }
                            }) {
                                Text(p.name)
                                    .font(.inter(11.5, weight: selected ? .semibold : .medium, relativeTo: .caption))
                                    .foregroundColor(selected ? .white : DS.ink)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule()
                                            .fill(selected ? DS.brand : Color.primary.opacity(0.06))
                                    )
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                            .contextMenu {
                                Button("Rename…") {
                                    renamingPortfolio = p
                                    renamePortfolioName = p.name
                                }
                                if let idx = storageService.portfolios.firstIndex(where: { $0.id == p.id }) {
                                    if idx > 0 {
                                        Button("Move Left") {
                                            let prevId = storageService.portfolios[idx - 1].id
                                            storageService.movePortfolio(from: p.id, beforeOrAfter: prevId)
                                        }
                                    }
                                    if idx < storageService.portfolios.count - 1 {
                                        Button("Move Right") {
                                            let nextId = storageService.portfolios[idx + 1].id
                                            storageService.movePortfolio(from: nextId, beforeOrAfter: p.id)
                                        }
                                    }
                                }
                                Divider()
                                Button("Delete Portfolio", role: .destructive) {
                                    confirmDeletePortfolio = p
                                }
                            }
                        }
                    }

                    Button(action: {
                        newPortfolioName = ""
                        showNewPortfolio = true
                    }) {
                        Image(systemName: "plus")
                            .font(.inter(10, weight: .bold, relativeTo: .caption))
                            .foregroundColor(DS.brand)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(DS.brand.opacity(0.12)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("New portfolio")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onAppear {
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if let pId = selectedPortfolioId {
                            proxy.scrollTo(pId, anchor: .center)
                        } else {
                            proxy.scrollTo("all_portfolios_tab", anchor: .center)
                        }
                    }
                }
            }
            .onChange(of: selectedPortfolioId) { _, newId in
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if let newId {
                            proxy.scrollTo(newId, anchor: .center)
                        } else {
                            proxy.scrollTo("all_portfolios_tab", anchor: .center)
                        }
                    }
                }
            }
        }
    }

    /// The portfolio tabs in order: the local drag preview while dragging, else the
    /// persisted order.
    private var displayedPortfolios: [Portfolio] {
        if draggingPortfolioId != nil, !previewPortfolioIds.isEmpty {
            let byId = Dictionary(uniqueKeysWithValues: storageService.portfolios.map { ($0.id, $0) })
            return previewPortfolioIds.compactMap { byId[$0] }
        }
        return storageService.portfolios
    }

    /// Live, local-only reorder of the portfolio tab preview while dragging.
    private func movePortfolioInPreview(_ sourceId: UUID, relativeTo targetId: UUID, placement: InsertPlacement) {
        if previewPortfolioIds.isEmpty { previewPortfolioIds = storageService.portfolios.map(\.id) }
        guard sourceId != targetId,
              let srcIndex = previewPortfolioIds.firstIndex(of: sourceId),
              let tgtIndex = previewPortfolioIds.firstIndex(of: targetId) else { return }
        let item = previewPortfolioIds.remove(at: srcIndex)
        let newTargetIndex = previewPortfolioIds.firstIndex(of: targetId) ?? tgtIndex
        let insertIndex = placement == .before ? newTargetIndex : newTargetIndex + 1
        guard insertIndex >= 0, insertIndex <= previewPortfolioIds.count else { return }
        previewPortfolioIds.insert(item, at: insertIndex)
    }

    /// Persists the previewed portfolio order exactly once, when the tab drop
    /// lands (or the drag ends outside the picker bar).
    private func commitPortfolioPreview() {
        guard !previewPortfolioIds.isEmpty else {
            draggingPortfolioId = nil
            return
        }
        let final = previewPortfolioIds
        previewPortfolioIds = []
        draggingPortfolioId = nil
        storageService.commitPortfolioOrder(final)
    }

    private func portfolioTotals(for portfolios: [Portfolio]) -> (value: Double, cost: Double, pnl: Double) {
        let inputs = PortfolioValuation.resolveInputs(for: portfolios, stockService: stockService, storageService: storageService)
        return PortfolioValuation.totals(inputs)
    }

    private func portfolioValue(for portfolios: [Portfolio]) -> Double {
        portfolioTotals(for: portfolios).value
    }

    private func portfolioCost(for portfolios: [Portfolio]) -> Double {
        portfolioTotals(for: portfolios).cost
    }

    private func portfolioPnl(for portfolios: [Portfolio]) -> Double {
        portfolioTotals(for: portfolios).pnl
    }

    private var grandTotalValue: Double {
        portfolioValue(for: storageService.portfolios)
    }

    private var grandTotalCost: Double {
        portfolioCost(for: storageService.portfolios)
    }

    struct GlobalPosition: Identifiable {
        let id: String            // symbol
        let avgPrice: Double      // weighted avg buy price, in the price currency
        let cost: Double          // total cost in native currency
        let valueLocal: Double    // total market value in native currency
        let todayPnl: Double      // today's P&L in native currency
        let priceSymbol: String
        let hasCostBasis: Bool    // whether any holding for this symbol has a known cost basis
        let pct: Double           // price return vs. avg (position-direction aware)
        let pnl: Double           // total P&L in native currency
        let currentPrice: Double
        let priceChangePercent: Double
        let extPrice: Double?
        let extChangePercent: Double?
        let value: Double         // market value (preferred currency), for sorting
        let shares: Double
        let lotsCount: Int
        var weight: Double
        let quote: StockQuote?
        var symbol: String { id }
    }

    /// Per-symbol weighted-average buy price across ALL portfolios, with the
    /// current price return vs. that average. Sorted by market value.
    private var globalPositions: [GlobalPosition] {
        let aggDict = viewModel.symbolAggregates
        let totalVal = viewModel.valuationCache.totalValue
        
        return aggDict.values.compactMap { agg -> GlobalPosition? in
            guard abs(agg.totalQuantity) >= 1e-9 || agg.value > 0 else { return nil }
            let weight = abs(totalVal) >= 0.01 ? (abs(agg.value) / abs(totalVal) * 100) : 0
            let extPrice: Double? = (agg.quote?.isExtendedHours == true) ? agg.quote?.alertPrice : nil
            let extChangePercent: Double? = (agg.quote?.isExtendedHours == true) ? agg.extendedChangePercent : nil
            
            return GlobalPosition(
                id: agg.symbol,
                avgPrice: agg.avgPrice,
                cost: agg.nativeCost,
                valueLocal: agg.nativeValue,
                todayPnl: agg.todayPnl,
                priceSymbol: agg.nativeCurrencySymbol,
                hasCostBasis: agg.hasCostBasis,
                pct: agg.nativePnlPercent,
                pnl: agg.nativePnl,
                currentPrice: agg.quote?.price ?? agg.avgPrice,
                priceChangePercent: agg.changePercent,
                extPrice: extPrice,
                extChangePercent: extChangePercent,
                value: agg.value,
                shares: agg.totalQuantity,
                lotsCount: agg.lotsCount,
                weight: weight,
                quote: agg.quote
            )
        }
        .sorted { $0.value > $1.value }
    }

    private func exportPortfolios(_ portfolios: [Portfolio]) {
        PortfolioIO.exportAll(portfolios, storageService: storageService, restoreActivationPolicy: true)
    }

    private func importStandard() {
        PortfolioIO.pickAndParseStandard(storageService: storageService, restoreActivationPolicy: true, onParsed: { result in
            self.pendingImportResult = result
        }, onAlert: { message in
            self.importAlert = message
        })
    }

    private func importJapaneseFunds() {
        PortfolioIO.pickAndParseJapaneseFunds(restoreActivationPolicy: true, onParsed: { result in
            self.pendingImportResult = result
        }, onAlert: { message in
            self.importAlert = message
        })
    }

    private func downloadSampleFile() {
        PortfolioIO.downloadSample(storageService: storageService, restoreActivationPolicy: true) { message in
            self.importAlert = message
        }
    }

    private func downloadJapaneseFundSampleFile() {
        PortfolioIO.downloadJapaneseFundSample(restoreActivationPolicy: true) { message in
            self.importAlert = message
        }
    }

    private func createPortfolio() {
        guard !newPortfolioName.isEmpty else { return }
        storageService.addPortfolio(name: newPortfolioName)
        newPortfolioName = ""
        showNewPortfolio = false
    }
}

struct PortfolioSection: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @Environment(\.addHoldingAction) var addHoldingAction
    let portfolio: Portfolio
    @Binding var confirmDeletePortfolio: Portfolio?
    @Binding var confirmDeleteHolding: (holding: Holding, portfolioId: UUID)?
    var onBatchImport: ((UUID) -> Void)? = nil
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var showNotifications = false
    @State private var isSyncingBinance = false
    @State private var syncError: String? = nil

    private func syncBinance() {
        isSyncingBinance = true
        Task {
            do {
                try await storageService.syncBinancePortfolio(id: portfolio.id)
            } catch {
                await MainActor.run {
                    syncError = error.localizedDescription
                }
            }
            await MainActor.run {
                isSyncingBinance = false
            }
        }
    }

    private func exportSingle() {
        PortfolioIO.exportAll([portfolio], storageService: storageService, restoreActivationPolicy: true)
    }

    private func exportSingleMD() {
        PortfolioIO.exportAllMarkdown([portfolio], restoreActivationPolicy: true)
    }

    private var currSymbol: String {
        StorageService.currencySymbol(for: storageService.preferredCurrency)
    }

    private var valuationTotals: (value: Double, cost: Double, pnl: Double, pnlPercent: Double) {
        let inputs = PortfolioValuation.resolveInputs(for: [portfolio], stockService: stockService, storageService: storageService)
        let totals = PortfolioValuation.totals(inputs)
        let pct = abs(totals.cost) >= 0.01 ? (totals.pnl / abs(totals.cost)) * 100 : 0
        return (totals.value, totals.cost, totals.pnl, pct)
    }

    var body: some View {
        let totals = valuationTotals
        let totalValue = totals.value
        let totalPnl = totals.pnl
        let totalPnlPercent = totals.pnlPercent

        Section {
            // Summary row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total value")
                        .font(.inter(10, relativeTo: .caption))
                        .foregroundColor(.secondary)
                    Text(StorageService.formatAmount(totalValue, symbol: currSymbol, decimals: storageService.amountDecimals))
                        .font(.inter(13.5, relativeTo: .body).monospacedDigit())
                        .fontWeight(.bold)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Total PnL")
                        .font(.inter(10, relativeTo: .caption))
                        .foregroundColor(.secondary)
                    HStack(spacing: 2) {
                        Text(StorageService.formatAmount(totalPnl, symbol: currSymbol, decimals: storageService.amountDecimals, signed: true))
                        Text(String(format: "(%.\(storageService.percentDecimals)f%%)", totalPnlPercent))
                    }
                    .font(.inter(11.5, relativeTo: .body).monospacedDigit())
                    .fontWeight(.bold)
                    .foregroundColor(totalPnl >= 0 ? DS.up : DS.down)
                }
            }
            .padding(.vertical, 2)

            // Column headers
            if !portfolio.holdings.isEmpty {
                HStack(spacing: 0) {
                    Text("Symbol")
                        .frame(width: 120, alignment: .leading)
                    Text("Price")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Text("Value / PnL")
                        .frame(width: 120, alignment: .trailing)
                }
                .font(.inter(10, weight: .medium, relativeTo: .caption2))
                .foregroundColor(.secondary)
                .tracking(0.8)
                .textCase(.uppercase)
                .padding(.vertical, 4)
            }

            // Holdings (Grouped by symbol)
            let groupedHoldings = Dictionary(grouping: portfolio.holdings) { $0.symbol.uppercased() }
            let sortedSymbols = portfolio.holdings.map { $0.symbol.uppercased() }.reduce(into: [String]()) { res, sym in
                if !res.contains(sym) { res.append(sym) }
            }

            ForEach(sortedSymbols, id: \.self) { sym in
                if let group = groupedHoldings[sym] {
                    if group.count == 1, let singleHolding = group.first {
                        HoldingRow(holding: singleHolding, portfolioId: portfolio.id, confirmDeleteHolding: $confirmDeleteHolding)
                    } else {
                        GroupedHoldingRow(symbol: sym, holdings: group, portfolioId: portfolio.id, confirmDeleteHolding: $confirmDeleteHolding)
                    }
                }
            }

            // Add holding / Batch import / Binance Sync buttons
            if portfolio.isReadOnly {
                HStack(spacing: 12) {
                    Button(action: syncBinance) {
                        HStack(spacing: 4) {
                            if isSyncingBinance {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Sync Binance Now")
                        }
                        .font(.inter(10, relativeTo: .caption))
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()
                    .disabled(isSyncingBinance)

                    if let lastSync = portfolio.lastSyncedAt {
                        Text("Last synced: \(lastSync.formatted(.dateTime.hour().minute().second()))")
                            .font(.inter(9, relativeTo: .caption))
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Button(action: { addHoldingAction.perform(portfolio.id) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                            Text("Add holding")
                        }
                        .font(.inter(10, relativeTo: .caption))
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()

                    Button(action: { onBatchImport?(portfolio.id) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "square.and.arrow.down")
                            Text("Batch import…")
                        }
                        .font(.inter(10, relativeTo: .caption))
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()
                }
            }
        } header: {
            if isRenaming {
                HStack {
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .font(.inter(13, weight: .bold, relativeTo: .headline))
                        .onSubmit { commitRename() }
                    Button("OK") { commitRename() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(renameText.isEmpty)
                }
            } else {
                HStack(spacing: 6) {
                    Text(portfolio.name)
                        .font(.inter(13, weight: .bold, relativeTo: .headline))

                    if portfolio.isReadOnly {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                            Text("Binance")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.yellow.opacity(0.2))
                        .foregroundColor(.orange)
                        .cornerRadius(4)
                    }

                    Spacer()
                    Menu {
                        if portfolio.isReadOnly {
                            Button(action: syncBinance) {
                                Label("Sync Binance Now", systemImage: "arrow.clockwise")
                            }
                            Divider()
                        }
                        Button {
                            renameText = portfolio.name
                            isRenaming = true
                        } label: {
                            Label("Rename Portfolio", systemImage: "pencil")
                        }
                        if !portfolio.isReadOnly {
                            Button {
                                onBatchImport?(portfolio.id)
                            } label: {
                                Label("Batch Import…", systemImage: "square.and.arrow.down")
                            }
                        }
                        Button {
                            showNotifications = true
                        } label: {
                            Label("Notifications…", systemImage: "bell")
                        }
                        Button(action: exportSingle) {
                            Label("Export (XLSX)", systemImage: "square.and.arrow.up")
                        }
                        Button(action: exportSingleMD) {
                            Label("Export (Markdown)", systemImage: "doc.text")
                        }
                        Divider()
                        Button(role: .destructive) {
                            confirmDeletePortfolio = portfolio
                        } label: {
                            Label("Delete Portfolio", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 20, height: 20)
                    .pointingHandCursor()
                }
                .popover(isPresented: $showNotifications, arrowEdge: .trailing) {
                    PortfolioNotificationsView(
                        portfolioId: portfolio.id,
                        portfolioName: portfolio.name,
                        onDismiss: { showNotifications = false }
                    )
                    .environmentObject(storageService)
                    .frame(width: 340)
                }
                .alert("Binance Sync Error", isPresented: Binding(get: { syncError != nil }, set: { if !$0 { syncError = nil } })) {
                    Button("OK", role: .cancel) { syncError = nil }
                } message: {
                    Text(syncError ?? "")
                }
            }
        }
    }

    private func commitRename() {
        guard !renameText.isEmpty else { return }
        storageService.renamePortfolio(id: portfolio.id, name: renameText)
        isRenaming = false
    }
}

struct HoldingRow: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @Environment(\.showSymbolDetail) private var showSymbolDetail
    let holding: Holding
    let portfolioId: UUID
    @Binding var confirmDeleteHolding: (holding: Holding, portfolioId: UUID)?

    var quote: StockQuote? {
        stockService.quotes[holding.symbol]
    }

    private func formatQty(_ qty: Double) -> String {
        qty == qty.rounded(.down) ? String(format: "%.0f", qty) : String(format: "%.2f", qty)
    }

    private var isReadOnly: Bool {
        storageService.portfolios.first(where: { $0.id == portfolioId })?.isReadOnly ?? false
    }

    var body: some View {
        Button(action: {
            showSymbolDetail.perform(holding.symbol)
        }) {
            HStack(spacing: 0) {
                // Col 1: Ticker + Qty@Avg
                HStack(spacing: 6) {
                    SymbolLogo(symbol: holding.symbol, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            Text(StockService.beautifiedSymbol(holding.symbol))
                                .font(.inter(12.5, relativeTo: .body).monospacedDigit())
                                .fontWeight(.bold)
                            if holding.isShort {
                                Text("SHORT")
                                    .font(.inter(9, weight: .bold, relativeTo: .caption2))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 2).fill(DS.down))
                            }
                            if holding.effectiveLeverage != 1 {
                                Text("\(StorageService.formatNumber(holding.effectiveLeverage, decimals: holding.effectiveLeverage == holding.effectiveLeverage.rounded() ? 0 : 1))\u{00D7}")
                                    .font(.inter(9, weight: .bold, relativeTo: .caption2))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 2).fill(DS.brand))
                            }
                        }
                        Text("\(formatQty(holding.quantity))\u{00D7}\(StorageService.formatNumber(holding.avgPrice, decimals: storageService.resolvedPriceDecimals(symbol: holding.symbol, price: holding.avgPrice)))")
                            .font(.inter(10.5, relativeTo: .caption).monospacedDigit())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(width: 125, alignment: .leading)

                if let quote {
                    let assetCurr = stockService.detectedCurrency(for: holding.symbol)
                    let quoteCurr = (quote.currency.isEmpty || assetCurr == "JPY") ? assetCurr : quote.currency
                    let displayPrice = quote.displayPrice(extendedHours: storageService.showExtendedHours)

                    // Col 2: Price + badge
                    HStack(spacing: 3) {
                        Text("\(StorageService.formatNumber(displayPrice, decimals: storageService.resolvedPriceDecimals(symbol: quote.symbol, price: displayPrice)))")
                            .font(.inter(12.5, relativeTo: .body).monospacedDigit())
                            .fontWeight(.medium)
                        if storageService.showExtendedHours, quote.isExtendedHours, !quote.marketStateLabel.isEmpty {
                            Text(quote.marketStateLabel)
                                .font(.inter(9.5, weight: .semibold, relativeTo: .caption2))
                                .foregroundColor(.white)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(quote.marketState.hasPrefix("PRE") ? DS.gold : DS.palette[3])
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    // Col 3: Value + P&L in native currency
                    let nativeVal = holding.marketValue(currentPrice: displayPrice)
                    let nativeCost = holding.costBasisLocal
                    let pnl = nativeVal - nativeCost
                    let pnlPct = abs(nativeCost) >= 0.01 ? (pnl / abs(nativeCost)) * 100 : 0
                    let nativeSym = StorageService.currencySymbol(for: quoteCurr)

                    let dec = storageService.amountDecimals
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(StorageService.formatAmount(nativeVal, symbol: nativeSym, decimals: dec))
                            .font(.inter(12.5, relativeTo: .body).monospacedDigit())
                            .fontWeight(.medium)
                        Text("\(StorageService.formatAmount(pnl, symbol: nativeSym, decimals: dec, signed: true)) (\(String(format: "%.\(storageService.percentDecimals)f%%", pnlPct)))")
                            .font(.inter(10.5, relativeTo: .caption).monospacedDigit())
                            .foregroundColor(pnl >= 0 ? DS.up : DS.down)
                    }
                    .frame(width: 125, alignment: .trailing)
                } else {
                    Spacer()
                    VStack(alignment: .center, spacing: 1) {
                        ProgressView()
                            .scaleEffect(0.5)
                        Text(" ")
                            .font(.inter(10.5, relativeTo: .caption).monospacedDigit())
                            .lineLimit(1)
                    }
                    .frame(width: 125, alignment: .center)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .contextMenu {
            Button {
                showSymbolDetail.perform(holding.symbol)
            } label: {
                Label("View Details", systemImage: "chart.xyaxis.line")
            }
            if !isReadOnly {
                Divider()
                Button(role: .destructive) {
                    confirmDeleteHolding = (holding, portfolioId)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }
}

struct GroupedHoldingRow: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @Environment(\.addHoldingAction) var addHoldingAction
    @Environment(\.showSymbolDetail) private var showSymbolDetail

    let symbol: String
    let holdings: [Holding]
    let portfolioId: UUID
    @Binding var confirmDeleteHolding: (holding: Holding, portfolioId: UUID)?

    @State private var isExpanded: Bool = false

    var quote: StockQuote? {
        stockService.quotes[symbol]
    }

    private var totalQty: Double {
        holdings.reduce(0) { $0 + $1.quantity }
    }

    private var weightedAvgPrice: Double {
        let totalAbsQty = holdings.reduce(0) { $0 + abs($1.quantity) }
        guard totalAbsQty > 0 else { return 0 }
        let totalCostInLocal = holdings.reduce(0) { $0 + (abs($1.quantity) * $1.avgPrice) }
        return totalCostInLocal / totalAbsQty
    }

    private func formatQty(_ qty: Double) -> String {
        qty == qty.rounded(.down) ? String(format: "%.0f", qty) : String(format: "%.2f", qty)
    }

    /// Purchase lots for this symbol, newest purchase date first. Lots without a
    /// date sort last so they never obscure dated history.
    private var sortedLots: [Holding] {
        holdings.sorted { lhs, rhs in
            switch (lhs.purchaseDate, rhs.purchaseDate) {
            case let (l?, r?): return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return false
            }
        }
    }

    var body: some View {
        let isReadOnly = storageService.portfolios.first(where: { $0.id == portfolioId })?.isReadOnly ?? false
        VStack(spacing: 0) {
            // Parent Summary Row
            HStack(spacing: 0) {
                // Chevron Button (Explicit toggle only)
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                }) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(DS.brand)
                        .frame(width: 20, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()

                // Clickable content triggering Symbol Details
                Button(action: {
                    showSymbolDetail.perform(symbol)
                }) {
                    HStack(spacing: 0) {
                        // Col 1: Ticker + Lot Count
                        HStack(spacing: 6) {
                            SymbolLogo(symbol: symbol, size: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(StockService.beautifiedSymbol(symbol))
                                    .font(.inter(12.5, relativeTo: .body).monospacedDigit())
                                    .fontWeight(.bold)
                                    .lineLimit(1)
                                HStack(spacing: 4) {
                                    Text("\(formatQty(totalQty))\u{00D7}\(StorageService.formatNumber(weightedAvgPrice, decimals: storageService.resolvedPriceDecimals(symbol: symbol, price: weightedAvgPrice))) avg")
                                        .font(.inter(10.5, relativeTo: .caption).monospacedDigit())
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                    if holdings.count > 1 {
                                        Text("\(holdings.count) lots")
                                            .font(.inter(8.5, weight: .semibold, relativeTo: .caption2))
                                            .foregroundColor(DS.brand)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(RoundedRectangle(cornerRadius: 3).fill(DS.brand.opacity(0.12)))
                                    }
                                }
                            }
                        }
                        .frame(width: 120, alignment: .leading)

                        if let quote {
                            let assetCurr = stockService.detectedCurrency(for: symbol)
                            let quoteCurr = (quote.currency.isEmpty || assetCurr == "JPY") ? assetCurr : quote.currency
                            let pRate = stockService.priceRate(from: quoteCurr)

                            // Col 2: Price (regular closing price formatted as integer)
                            HStack(spacing: 3) {
                                Text("\(StorageService.formatNumber(quote.price * pRate, decimals: 0))")
                                    .font(.inter(12.5, relativeTo: .body).monospacedDigit())
                                    .fontWeight(.medium)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)

                            // Col 3: Total Market Value & Total P&L in native currency
                            let displayPrice = quote.price
                            let nativeTotals = PortfolioValuation.nativeTotals(holdings: holdings, currentPrice: displayPrice)
                            let nativeVal = nativeTotals.value
                            let nativeCost = nativeTotals.cost
                            let totalPnl = nativeTotals.pnl
                            let totalPnlPct = abs(nativeCost) >= 0.01 ? (totalPnl / abs(nativeCost)) * 100 : 0
                            let nativeSym = StorageService.currencySymbol(for: quoteCurr)

                            let dec = storageService.amountDecimals
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(StorageService.formatAmount(nativeVal, symbol: nativeSym, decimals: dec))
                                    .font(.inter(12.5, relativeTo: .body).monospacedDigit())
                                    .fontWeight(.medium)
                                Text("\(StorageService.formatAmount(totalPnl, symbol: nativeSym, decimals: dec, signed: true)) (\(String(format: "%.\(storageService.percentDecimals)f%%", totalPnlPct)))")
                                    .font(.inter(10.5, relativeTo: .caption).monospacedDigit())
                                    .foregroundColor(totalPnl >= 0 ? DS.up : DS.down)
                            }
                            .frame(width: 120, alignment: .trailing)
                        } else {
                            Spacer()
                            VStack(alignment: .center, spacing: 1) {
                                ProgressView().scaleEffect(0.5)
                                Text(" ")
                                    .font(.inter(10.5, relativeTo: .caption).monospacedDigit())
                                    .lineLimit(1)
                            }
                            .frame(width: 120, alignment: .center)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
            .contextMenu {
                Button {
                    showSymbolDetail.perform(symbol)
                } label: {
                    Label("View Details", systemImage: "chart.xyaxis.line")
                }
            }

            // Expanded Child Lots
            if isExpanded {
                VStack(spacing: 3) {
                    ForEach(sortedLots) { h in
                        HStack(spacing: 0) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 8))
                                    .foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(formatQty(h.quantity)) @ \(StorageService.formatNumber(h.avgPrice, decimals: storageService.resolvedPriceDecimals(symbol: h.symbol, price: h.avgPrice)))")
                                        .font(.inter(11, relativeTo: .caption).monospacedDigit())
                                        .fontWeight(.medium)
                                    if let date = h.purchaseDate {
                                        Text(date.formatted(date: .abbreviated, time: .omitted))
                                            .font(.inter(9.5, relativeTo: .caption2))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .frame(width: 120, alignment: .leading)

                            Spacer()

                            if let quote {
                                let curr = stockService.detectedCurrency(for: h.symbol)
                                let displayPrice = quote.displayPrice(extendedHours: storageService.showExtendedHours)
                                let val = h.marketValue(currentPrice: displayPrice)
                                let cost = h.costBasisLocal
                                let pnl = val - cost
                                let nativeSymbol = StorageService.currencySymbol(for: curr)

                                Text(StorageService.formatAmount(val, symbol: nativeSymbol, decimals: storageService.amountDecimals))
                                    .font(.inter(11, relativeTo: .caption).monospacedDigit())
                                    .foregroundColor(.secondary)
                                    .frame(width: 70, alignment: .trailing)

                                Text(StorageService.formatAmount(pnl, symbol: nativeSymbol, decimals: storageService.amountDecimals, signed: true))
                                    .font(.inter(10, relativeTo: .caption2).monospacedDigit())
                                    .foregroundColor(pnl >= 0 ? DS.up : DS.down)
                                    .frame(width: 70, alignment: .trailing)
                            }

                            let isReadOnly = storageService.portfolios.first(where: { $0.id == portfolioId })?.isReadOnly ?? false
                            if !isReadOnly {
                                HStack(spacing: 6) {
                                    Button { confirmDeleteHolding = (h, portfolioId) } label: {
                                        Image(systemName: "trash").font(.system(size: 10)).foregroundColor(.red.opacity(0.8))
                                    }
                                    .buttonStyle(.plain)
                                    .pointingHandCursor()
                                    .help("Delete lot")
                                }
                                .padding(.leading, 8)
                            }
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(DS.cardAlt.opacity(0.5)))
                    }

                    if !isReadOnly {
                        // Add another lot for this symbol
                        Button(action: {
                            addHoldingAction.perform(portfolioId)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "plus.circle")
                                Text("Add another lot for \(symbol)")
                            }
                            .font(.inter(9, weight: .semibold, relativeTo: .caption2))
                            .foregroundColor(DS.brand)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                }
                .padding(.leading, 8)
                .padding(.bottom, 4)
            }
        }
    }
}

// MARK: - Row Views

struct PortfolioQuoteRow: View {
    let stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @Environment(\.showSymbolDetail) private var showSymbolDetail
    let globalPos: PortfolioListView.GlobalPosition

    var quote: StockQuote? { globalPos.quote }

    private var priceRate: Double {
        guard let q = quote else { return 1.0 }
        return stockService.priceRate(from: q.currency)
    }

    private var symbolFont: Font { .inter(12.5, relativeTo: .body).monospacedDigit() }
    private var subtitleFont: Font { .inter(10, relativeTo: .caption2) }
    private var metricFont: Font { .inter(11.5, relativeTo: .body).monospacedDigit() }
    private var metricSubFont: Font { .inter(10.5, relativeTo: .caption).monospacedDigit() }
    private var metricCaption2Font: Font { .inter(10, relativeTo: .caption2).monospacedDigit() }
    private var extFont: Font { .inter(11.5, relativeTo: .body).monospacedDigit() }

    var body: some View {
        Button(action: {
            showSymbolDetail.perform(globalPos.symbol)
        }) {
            HStack(spacing: 0) {
                // Col 1: Logo + symbol + name
                let isJpFund = StockService.isJapaneseMutualFund(globalPos.symbol) || (quote?.isJapaneseFund ?? false)
                let isDisplayAsset = StockService.isDisplayNameAsset(globalPos.symbol)
                let titleText = (isJpFund || isDisplayAsset) ? (quote?.displayName ?? StockService.beautifiedSymbol(globalPos.symbol)) : globalPos.symbol
                let subTitleText = isDisplayAsset ? globalPos.symbol : (isJpFund ? "" : (quote?.name ?? ""))

                HStack(spacing: 4) {
                    SymbolLogo(symbol: globalPos.symbol, size: 20)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(titleText)
                            .font(symbolFont)
                            .fontWeight(.bold)
                            .lineLimit(1)
                        if storageService.showCompanyName {
                            Text(subTitleText.isEmpty ? " " : subTitleText)
                                .font(subtitleFont)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(width: PortfolioCol.symbol, alignment: .leading)

                let activeCols = PortfolioListView.defaultPopoverColumns

                ForEach(activeCols, id: \.self) { col in
                    metricCell(for: col)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .contextMenu {
            Button {
                showSymbolDetail.perform(globalPos.symbol)
            } label: {
                Label("View Details", systemImage: "chart.xyaxis.line")
            }
        }
    }

    @ViewBuilder
    private func metricCell(for col: PortfolioColumnMetric) -> some View {
        switch col {
        case .avgPrice:
            let avgPrice = globalPos.hasCostBasis ? globalPos.avgPrice : 0
            Text(globalPos.hasCostBasis ? StorageService.formatCompactNumber(avgPrice, decimals: storageService.resolvedPriceDecimals(symbol: globalPos.symbol, price: avgPrice)) : "—")
                .font(metricFont)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: PortfolioCol.avgPrice, alignment: .trailing)

        case .cost:
            if globalPos.hasCostBasis {
                Text(StorageService.formatCompactAmount(
                    globalPos.cost,
                    symbol: globalPos.priceSymbol,
                    signed: false,
                    decimals: storageService.amountDecimals
                ))
                .font(metricFont)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: PortfolioCol.cost, alignment: .trailing)
            } else {
                Text("—")
                    .font(metricFont)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: PortfolioCol.cost, alignment: .trailing)
            }

        case .price:
            VStack(alignment: .trailing, spacing: 1) {
                if let quote {
                    let displayPrice = quote.price * priceRate
                    let dec = storageService.resolvedPriceDecimals(symbol: quote.symbol, price: displayPrice)
                    let formattedChange = StorageService.formatCompactNumber(quote.change * priceRate, decimals: dec, stripTrailingZeros: true)

                    Text(StorageService.formatCompactNumber(displayPrice, decimals: dec))
                        .font(metricFont)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Text((quote.change >= 0 ? "+" : "") + formattedChange)
                        .font(metricSubFont)
                        .fontWeight(.semibold)
                        .foregroundColor(quote.isPositive ? DS.up : DS.down)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                } else {
                    ProgressView().scaleEffect(0.5)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text(" ")
                        .font(metricSubFont)
                        .lineLimit(1)
                }
            }
            .frame(width: PortfolioCol.price, alignment: .trailing)

        case .change:
            VStack(alignment: .trailing, spacing: 1) {
                if let quote {
                    let isCrypto = storageService.type(for: quote.symbol) == "CRYPTOCURRENCY" || HomeAIInsightService.cryptoBaseAsset(for: quote.symbol) != nil
                    let isMarketActive = MarketCategory.isTradingDay(symbol: quote.symbol, quote: quote, isCrypto: isCrypto)
                    let isSessionOpen = MarketCategory.isSessionOpen(symbol: quote.symbol, quote: quote, isCrypto: isCrypto)

                    let pctColor: Color = isMarketActive ? (quote.isPositive ? DS.up : DS.down) : DS.inkTertiary
                    Text(String(format: "%+.\(storageService.percentDecimals)f%%", quote.changePercent))
                        .font(metricFont)
                        .fontWeight(.medium)
                        .foregroundColor(pctColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    let extPrice: Double? = (storageService.showExtendedHours && quote.isExtendedHours) ? quote.effectivePrice : nil
                    let extPct: Double? = extPrice == nil ? nil : quote.extendedChangePercent

                    if let extPct {
                        let isPre = quote.marketState.hasPrefix("PRE")
                        HStack(spacing: 1) {
                            Image(systemName: isPre ? "sun.max.fill" : "moon.fill")
                                .font(.system(size: 8, weight: .semibold))
                            Text(String(format: "%+.\(storageService.percentDecimals)f%%", extPct))
                                .font(metricCaption2Font)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(extPct >= 0 ? DS.up : DS.down)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    } else if !isSessionOpen {
                        HStack(spacing: 1) {
                            Image(systemName: "moon.fill")
                                .font(.system(size: 7, weight: .semibold))
                            Text("Closed")
                                .font(metricCaption2Font)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(DS.inkTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    }
                } else {
                    ProgressView().scaleEffect(0.5)
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text(" ")
                        .font(metricCaption2Font)
                        .lineLimit(1)
                }
            }
            .frame(width: PortfolioCol.change, alignment: .trailing)

        case .value:
            VStack(alignment: .trailing, spacing: 1) {
                Text(StorageService.formatCompactAmount(
                    globalPos.valueLocal,
                    symbol: globalPos.priceSymbol,
                    signed: false,
                    decimals: storageService.amountDecimals
                ))
                .font(metricFont)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

                Text(StorageService.formatCompactAmount(
                    globalPos.todayPnl,
                    symbol: globalPos.priceSymbol,
                    signed: true,
                    decimals: storageService.amountDecimals
                ))
                .font(metricCaption2Font)
                .fontWeight(.semibold)
                .foregroundColor(globalPos.todayPnl > 0 ? DS.up : (globalPos.todayPnl < 0 ? DS.down : DS.inkTertiary))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            }
            .frame(width: PortfolioCol.value, alignment: .trailing)

        case .totalPnl:
            VStack(alignment: .trailing, spacing: 1) {
                if globalPos.hasCostBasis {
                    Text(StorageService.formatCompactAmount(globalPos.pnl, symbol: globalPos.priceSymbol, signed: true, decimals: storageService.amountDecimals))
                        .font(metricFont)
                        .fontWeight(.medium)
                        .foregroundColor(globalPos.pnl >= 0 ? DS.up : DS.down)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(String(format: "%+.\(storageService.percentDecimals)f%%", globalPos.pct))
                        .font(metricCaption2Font)
                        .fontWeight(.semibold)
                        .foregroundColor(globalPos.pct >= 0 ? DS.up : DS.down)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    Text("—")
                        .font(metricFont)
                        .foregroundColor(DS.inkTertiary)
                        .lineLimit(1)
                    Text("—")
                        .font(metricCaption2Font)
                        .foregroundColor(DS.inkTertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: PortfolioCol.totalPnl, alignment: .trailing)

        case .todayPnl:
            VStack(alignment: .trailing, spacing: 1) {
                Text(StorageService.formatCompactAmount(
                    globalPos.todayPnl,
                    symbol: globalPos.priceSymbol,
                    signed: true,
                    decimals: storageService.amountDecimals
                ))
                .font(metricFont)
                .fontWeight(.medium)
                .foregroundColor(globalPos.todayPnl > 0 ? DS.up : (globalPos.todayPnl < 0 ? DS.down : DS.inkTertiary))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

                if let quote {
                    let isCrypto = storageService.type(for: quote.symbol) == "CRYPTOCURRENCY" || HomeAIInsightService.cryptoBaseAsset(for: quote.symbol) != nil
                    let isMarketActive = MarketCategory.isTradingDay(symbol: quote.symbol, quote: quote, isCrypto: isCrypto)
                    Text(String(format: "%+.\(storageService.percentDecimals)f%%", quote.changePercent))
                        .font(metricSubFont)
                        .fontWeight(.semibold)
                        .foregroundColor(isMarketActive ? (quote.isPositive ? DS.up : DS.down) : DS.inkTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .frame(width: PortfolioCol.todayPnl, alignment: .trailing)

        case .shares:
            let qtyDecimals = globalPos.shares.truncatingRemainder(dividingBy: 1) == 0 ? 0 : (globalPos.shares < 1 ? 4 : 2)
            Text(StorageService.formatNumber(globalPos.shares, decimals: qtyDecimals))
                .font(metricFont)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: PortfolioCol.shares, alignment: .trailing)

        case .lots:
            Text("\(globalPos.lotsCount)")
                .font(metricFont)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(width: PortfolioCol.lots, alignment: .trailing)

        case .weight:
            Text(String(format: "%.1f%%", globalPos.weight))
                .font(metricFont)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: PortfolioCol.weight, alignment: .trailing)
        }
    }
}
