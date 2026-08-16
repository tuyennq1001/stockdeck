import SwiftUI
import UniformTypeIdentifiers

struct PortfolioListView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @State private var showNewPortfolio = false
    @State private var showBinanceSheet = false
    @State private var newPortfolioName = ""
    @State private var searchText = ""
    @State private var importAlert: String?
    @State private var pendingImportResult: PortfolioIO.ImportResult? = nil
    @State private var confirmDeletePortfolio: Portfolio? = nil
    @State private var confirmDeleteHolding: (holding: Holding, portfolioId: UUID)? = nil
    @State private var selectedPortfolioId: UUID? = nil
    @State private var draggingPortfolioId: UUID? = nil
    /// Live display order of the portfolio tabs while dragging: no storage writes
    /// during the drag — the final order is committed once on drop.
    @State private var previewPortfolioIds: [UUID] = []

    var filteredPortfolios: [Portfolio] {
        guard !searchText.isEmpty else { return storageService.portfolios }
        let query = searchText.lowercased()
        return storageService.portfolios.filter { portfolio in
            portfolio.name.lowercased().contains(query) ||
            portfolio.holdings.contains { $0.symbol.lowercased().contains(query) }
        }
    }

    var body: some View {
        Group {
        if storageService.portfolios.isEmpty && !showNewPortfolio {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "briefcase")
                    .font(.inter(32, relativeTo: .largeTitle))
                    .foregroundColor(.secondary)
                Text("No portfolios")
                    .foregroundColor(.secondary)
                Button("Create portfolio") {
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
                    let activePortfolios = activePortfoliosForSummary
                    let totals = portfolioTotals(for: activePortfolios)
                    let totalVal = totals.value
                    let totalCost = totals.cost
                    let pnl = totals.pnl
                    let pnlPct = abs(totalCost) >= 0.01 ? (pnl / abs(totalCost)) * 100 : 0

                    let todayInputs = activePortfolios.flatMap(\.holdings).compactMap { holding -> TodayPerformance.Input? in
                        guard let quote = stockService.quotes[holding.symbol] else { return nil }
                        return TodayPerformance.Input(
                            holding: holding,
                            regularPrice: quote.price,
                            previousClose: quote.previousClose,
                            rate: stockService.rate(from: quote.currency)
                        )
                    }
                    let today = TodayPerformance.totals(todayInputs)
                    let todayGain = today.gain
                    let todayPct = today.percent

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Total value")
                                .font(.inter(10, relativeTo: .caption))
                                .foregroundColor(.secondary)
                            Text(StorageService.formatAmount(totalVal, symbol: currSym, decimals: storageService.amountDecimals))
                                .font(.inter(13, relativeTo: .body).monospacedDigit())
                                .fontWeight(.bold)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("Today P&L")
                                    .font(.inter(10, relativeTo: .caption))
                                    .foregroundColor(.secondary)
                                HStack(spacing: 2) {
                                    Text(StorageService.formatAmount(todayGain, symbol: currSym, decimals: storageService.amountDecimals, signed: true))
                                    Text(String(format: "(%.\(storageService.percentDecimals)f%%)", todayPct))
                                }
                                .font(.inter(12, relativeTo: .caption).monospacedDigit())
                                .fontWeight(.semibold)
                                .foregroundColor(todayGain >= 0 ? DS.up : DS.down)
                            }

                            HStack(spacing: 6) {
                                Text("Total P&L")
                                    .font(.inter(10, relativeTo: .caption))
                                    .foregroundColor(.secondary)
                                HStack(spacing: 2) {
                                    Text(StorageService.formatAmount(pnl, symbol: currSym, decimals: storageService.amountDecimals, signed: true))
                                    Text(String(format: "(%.\(storageService.percentDecimals)f%%)", pnlPct))
                                }
                                .font(.inter(12, relativeTo: .caption).monospacedDigit())
                                .fontWeight(.bold)
                                .foregroundColor(pnl >= 0 ? DS.up : DS.down)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    Divider()
                }

                let globals = globalPositions
                if !globals.isEmpty {
                    HStack(spacing: 0) {
                        Text("Symbol")
                            .frame(width: 80, alignment: .leading)
                        Text("Avg Price")
                            .frame(width: 72, alignment: .trailing)
                        Text("Price")
                            .frame(width: 72, alignment: .trailing)
                        Text("Today %")
                            .frame(width: 70, alignment: .trailing)
                        Text("Total P&L")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .font(.inter(10, weight: .medium, relativeTo: .caption))
                    .foregroundColor(.secondary)
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)

                    Divider()

                    List {
                        if showNewPortfolio {
                            HStack {
                                TextField("Portfolio name", text: $newPortfolioName)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit {
                                        createPortfolio()
                                    }
                                Button("OK") {
                                    createPortfolio()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .pointingHandCursor()
                                .disabled(newPortfolioName.isEmpty)
                            }
                            .padding(.vertical, 4)
                        }

                        ForEach(globals) { p in
                            PortfolioQuoteRow(globalPos: p)
                        }
                    }
                    .listStyle(.plain)
                } else {
                    List {
                        if showNewPortfolio {
                            HStack {
                                TextField("Portfolio name", text: $newPortfolioName)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit {
                                        createPortfolio()
                                    }
                                Button("OK") {
                                    createPortfolio()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .pointingHandCursor()
                                .disabled(newPortfolioName.isEmpty)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .listStyle(.plain)
                }

                Divider()

                HStack(spacing: 12) {
                    Button(action: { showNewPortfolio = true }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("New portfolio")
                        }
                        .font(.inter(10, relativeTo: .caption))
                    }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()

                    Button(action: { showBinanceSheet = true }) {
                        HStack {
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
                .padding(8)
            }
        }
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
        .alert("Delete Portfolio", isPresented: Binding(get: { confirmDeletePortfolio != nil }, set: { if !$0 { confirmDeletePortfolio = nil } })) {
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
        .alert("Delete Holding", isPresented: Binding(get: { confirmDeleteHolding != nil }, set: { if !$0 { confirmDeleteHolding = nil } })) {
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
                        }
                    }) {
                        Text("All Portfolios")
                            .font(.inter(11, weight: isAllSelected ? .bold : .medium, relativeTo: .caption))
                            .foregroundColor(isAllSelected ? .white : DS.ink)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(isAllSelected ? DS.brand : Color.primary.opacity(0.06))
                            )
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
                                }
                            }) {
                                Text(p.name)
                                    .font(.inter(11, weight: selected ? .bold : .medium, relativeTo: .caption))
                                    .foregroundColor(selected ? .white : DS.ink)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(selected ? DS.brand : Color.primary.opacity(0.06))
                                    )
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                            .id(p.id)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
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
        let priceSymbol: String
        let hasCostBasis: Bool    // whether any holding for this symbol has a known cost basis
        let pct: Double           // price return vs. avg (position-direction aware)
        let pnl: Double           // total P&L in preferred currency
        let currentPrice: Double
        let priceChangePercent: Double
        let extPrice: Double?
        let extChangePercent: Double?
        let value: Double         // market value (preferred currency), for sorting
        var symbol: String { id }
    }

    /// Per-symbol weighted-average buy price across ALL portfolios, with the
    /// current price return vs. that average. Sorted by market value.
    private var globalPositions: [GlobalPosition] {
        var qty: [String: Double] = [:]
        var qtyPrice: [String: Double] = [:]
        var totalVal: [String: Double] = [:]
        var totalCost: [String: Double] = [:]
        var nativeCostMap: [String: Double] = [:]
        var nativeValMap: [String: Double] = [:]
        var hasMissingCostMap: [String: Bool] = [:]
        var orderMap: [String: Int] = [:]
        var order = 0

        for portfolio in activePortfoliosForSummary {
            for h in portfolio.holdings {
                let sym = h.symbol.uppercased()
                if orderMap[sym] == nil {
                    orderMap[sym] = order
                    order += 1
                }
                qty[sym, default: 0] += h.quantity
                if h.hasKnownCostBasis {
                    qtyPrice[sym, default: 0] += h.quantity * h.avgPrice
                }

                let quote = stockService.quotes[h.symbol] ?? stockService.quotes[sym] ?? StockQuote(
                    symbol: h.symbol, name: h.symbol, price: h.avgPrice, change: 0, changePercent: 0,
                    currency: stockService.detectedCurrency(for: h.symbol)
                )
                let currency = stockService.detectedCurrency(for: h.symbol)
                let rate = stockService.rate(from: currency)
                let costRate = stockService.rate(from: currency, for: h.purchaseDate)
                let isJpFund = quote.isJapaneseFund || stockService.isJapaneseMutualFund(h.symbol) || h.isJapaneseFund
                let scale = isJpFund ? 10000.0 : 1.0
                let lev = h.effectiveLeverage
                let q = h.quantity
                let val = (quote.price / scale) * q * lev * rate
                let cst = h.hasKnownCostBasis
                    ? (h.avgPrice / scale) * q * lev * costRate
                    : 0
                totalVal[sym, default: 0] += val
                totalCost[sym, default: 0] += cst

                let nativeCst = h.hasKnownCostBasis ? h.costBasisLocal : 0
                let nativeVal = h.marketValue(currentPrice: quote.price)
                nativeCostMap[sym, default: 0] += nativeCst
                nativeValMap[sym, default: 0] += nativeVal
                if !h.hasKnownCostBasis {
                    hasMissingCostMap[sym] = true
                }
            }
        }
        return qty.compactMap { symbol, q -> GlobalPosition? in
            guard abs(q) >= 1e-9 else { return nil }
            let quote = stockService.quotes[symbol] ?? stockService.quotes[symbol.uppercased()]
            let weightedPrice = qtyPrice[symbol, default: 0]
            let avg = abs(weightedPrice) > 0 ? weightedPrice / q : .nan
            let price = quote?.price ?? avg
            let val = totalVal[symbol, default: 0]

            let nativeCst = nativeCostMap[symbol, default: 0]
            let nativeVal = nativeValMap[symbol, default: 0]
            let hasCompleteCost = !(hasMissingCostMap[symbol] ?? false)
            let nativePnl = hasCompleteCost ? nativeVal - nativeCst : 0
            let pct = hasCompleteCost && abs(nativeCst) >= 0.01 ? (nativePnl / abs(nativeCst)) * 100 : 0
            let hasCostBasis = hasCompleteCost

            let assetCurr = stockService.detectedCurrency(for: symbol)
            let quoteCurr = (quote?.currency.isEmpty == false) ? quote!.currency : assetCurr
            let nativeSymbol = StorageService.currencySymbol(for: quoteCurr)

            let extPrice: Double? = (quote?.isExtendedHours == true) ? quote?.alertPrice : nil
            let extChangePercent: Double? = (quote?.isExtendedHours == true) ? quote?.extendedChangePercent : nil

            return GlobalPosition(id: symbol, avgPrice: avg, priceSymbol: nativeSymbol, hasCostBasis: hasCostBasis,
                                  pct: pct, pnl: nativePnl,
                                  currentPrice: price, priceChangePercent: quote?.changePercent ?? 0,
                                  extPrice: extPrice, extChangePercent: extChangePercent,
                                  value: val)
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

    private var currSymbol: String {
        StorageService.currencySymbol(for: storageService.preferredCurrency)
    }

    var totalValue: Double {
        let inputs = PortfolioValuation.resolveInputs(for: [portfolio], stockService: stockService, storageService: storageService)
        return PortfolioValuation.totals(inputs).value
    }

    var totalPnl: Double {
        // Unify with every other surface: P&L = value − cost, where cost uses the
        // historical FX rate at purchase. Holdings without a known cost basis
        // (e.g. Binance balances without order history) contribute 0 P&L — we
        // can't report a gain/loss without the purchase price.
        let inputs = PortfolioValuation.resolveInputs(for: [portfolio], stockService: stockService, storageService: storageService)
        return PortfolioValuation.totals(inputs).pnl
    }

    var totalCost: Double {
        let inputs = PortfolioValuation.resolveInputs(for: [portfolio], stockService: stockService, storageService: storageService)
        return PortfolioValuation.totals(inputs).cost
    }

    var totalPnlPercent: Double {
        guard abs(totalCost) >= 0.01 else { return 0 }
        return (totalPnl / abs(totalCost)) * 100
    }

    var body: some View {
        Section {
            // Summary row
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total value")
                        .font(.inter(10, relativeTo: .caption))
                        .foregroundColor(.secondary)
                    Text(StorageService.formatAmount(totalValue, symbol: currSymbol, decimals: storageService.amountDecimals))
                        .font(.inter(13, relativeTo: .body).monospacedDigit())
                        .fontWeight(.semibold)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Total P&L")
                        .font(.inter(10, relativeTo: .caption))
                        .foregroundColor(.secondary)
                    HStack(spacing: 2) {
                        Text(StorageService.formatAmount(totalPnl, symbol: currSymbol, decimals: storageService.amountDecimals, signed: true))
                        Text(String(format: "(%.\(storageService.percentDecimals)f%%)", totalPnlPercent))
                    }
                    .font(.inter(13, relativeTo: .body).monospacedDigit())
                    .fontWeight(.semibold)
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
                    Text("Value / P&L")
                        .frame(width: 120, alignment: .trailing)
                }
                .font(.inter(10, weight: .medium, relativeTo: .caption))
                .foregroundColor(.secondary)
                .padding(.vertical, 1)
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
        HStack(spacing: 0) {
            // Col 1: Ticker + Qty@Avg
            HStack(spacing: 6) {
                SymbolLogo(symbol: holding.symbol, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text(StockService.beautifiedSymbol(holding.symbol))
                            .font(.inter(13, relativeTo: .body).monospacedDigit())
                            .fontWeight(.bold)
                        if holding.isShort {
                            Text("SHORT")
                                .font(.inter(8, weight: .bold, relativeTo: .caption2))
                                .foregroundColor(.white)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 2).fill(DS.down))
                        }
                        if holding.effectiveLeverage != 1 {
                            Text("\(StorageService.formatNumber(holding.effectiveLeverage, decimals: holding.effectiveLeverage == holding.effectiveLeverage.rounded() ? 0 : 1))\u{00D7}")
                                .font(.inter(8, weight: .bold, relativeTo: .caption2))
                                .foregroundColor(.white)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 2).fill(DS.brand))
                        }
                    }
                    Text("\(formatQty(holding.quantity))\u{00D7}\(StorageService.formatNumber(holding.avgPrice, decimals: storageService.resolvedPriceDecimals(symbol: holding.symbol, price: holding.avgPrice)))")
                        .font(.inter(10, relativeTo: .caption).monospacedDigit())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(width: 120, alignment: .leading)

            if let quote {
                let assetCurr = stockService.detectedCurrency(for: holding.symbol)
                let quoteCurr = (quote.currency.isEmpty || assetCurr == "JPY") ? assetCurr : quote.currency
                let displayPrice = quote.displayPrice(extendedHours: storageService.showExtendedHours)

                // Col 2: Price + badge
                HStack(spacing: 3) {
                    Text("\(StorageService.formatNumber(displayPrice, decimals: storageService.resolvedPriceDecimals(symbol: quote.symbol, price: displayPrice)))")
                        .font(.inter(13, relativeTo: .body).monospacedDigit())
                        .fontWeight(.medium)
                    if storageService.showExtendedHours, quote.isExtendedHours, !quote.marketStateLabel.isEmpty {
                        Text(quote.marketStateLabel)
                            .font(.inter(9, weight: .semibold, relativeTo: .caption2))
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
                        .font(.inter(13, relativeTo: .body).monospacedDigit())
                        .fontWeight(.medium)
                    Text("\(StorageService.formatAmount(pnl, symbol: nativeSym, decimals: dec, signed: true)) (\(String(format: "%.\(storageService.percentDecimals)f%%", pnlPct)))")
                        .font(.inter(10, relativeTo: .caption).monospacedDigit())
                        .foregroundColor(pnl >= 0 ? DS.up : DS.down)
                }
                .frame(width: 120, alignment: .trailing)
            } else {
                Spacer()
                ProgressView()
                    .scaleEffect(0.5)
            }
        }
        .padding(.vertical, 2)
        .contextMenu(isReadOnly ? nil : ContextMenu {
            Button(role: .destructive) {
                confirmDeleteHolding = (holding, portfolioId)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        })
    }
}

struct GroupedHoldingRow: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @Environment(\.addHoldingAction) var addHoldingAction

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
            case (nil, _): return false
            case (_, nil): return true
            case (nil, nil): return false
            }
        }
    }

    var body: some View {
        let isReadOnly = storageService.portfolios.first(where: { $0.id == portfolioId })?.isReadOnly ?? false
        VStack(spacing: 0) {
            // Parent Summary Row
            HStack(spacing: 0) {
                // Col 1: Ticker + Lot Count + Chevron
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(DS.brand)
                    SymbolLogo(symbol: symbol, size: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(StockService.beautifiedSymbol(symbol))
                            .font(.inter(13, relativeTo: .body).monospacedDigit())
                            .fontWeight(.bold)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text("\(formatQty(totalQty))\u{00D7}\(StorageService.formatNumber(weightedAvgPrice, decimals: storageService.resolvedPriceDecimals(symbol: symbol, price: weightedAvgPrice))) avg")
                                .font(.inter(10, relativeTo: .caption).monospacedDigit())
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            if holdings.count > 1 {
                                Text("\(holdings.count) lots")
                                    .font(.inter(8, weight: .semibold, relativeTo: .caption2))
                                    .foregroundColor(DS.brand)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(DS.brand.opacity(0.12)))
                            }
                        }
                    }
                }
                .frame(width: 140, alignment: .leading)

                if let quote {
                    let assetCurr = stockService.detectedCurrency(for: symbol)
                    let quoteCurr = (quote.currency.isEmpty || assetCurr == "JPY") ? assetCurr : quote.currency
                    let pRate = stockService.priceRate(from: quoteCurr)

                    // Col 2: Price (regular closing price formatted as integer)
                    HStack(spacing: 3) {
                        Text("\(StorageService.formatNumber(quote.price * pRate, decimals: 0))")
                            .font(.inter(13, relativeTo: .body).monospacedDigit())
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
                            .font(.inter(13, relativeTo: .body).monospacedDigit())
                            .fontWeight(.medium)
                        Text("\(StorageService.formatAmount(totalPnl, symbol: nativeSym, decimals: dec, signed: true)) (\(String(format: "%.\(storageService.percentDecimals)f%%", totalPnlPct)))")
                            .font(.inter(10, relativeTo: .caption).monospacedDigit())
                            .foregroundColor(totalPnl >= 0 ? DS.up : DS.down)
                    }
                    .frame(width: 120, alignment: .trailing)
                } else {
                    Spacer()
                    ProgressView().scaleEffect(0.5)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .pointingHandCursor()
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
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
                                        .fontWeight(.semibold)
                                    if let date = h.purchaseDate {
                                        Text(date.formatted(date: .abbreviated, time: .omitted))
                                            .font(.inter(9, relativeTo: .caption2))
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

struct PortfolioQuoteRow: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService

    let globalPos: PortfolioListView.GlobalPosition

    var quote: StockQuote? {
        stockService.quotes[globalPos.symbol]
    }

    private var priceRate: Double {
        guard let q = quote else { return 1.0 }
        return stockService.priceRate(from: q.currency)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Col 1: Logo + symbol + name
            let isJpFund = stockService.isJapaneseMutualFund(globalPos.symbol) || (quote?.isJapaneseFund ?? false)
            let isDisplayAsset = StockService.isDisplayNameAsset(globalPos.symbol)
            let titleText = (isJpFund || isDisplayAsset) ? (quote?.displayName ?? StockService.beautifiedSymbol(globalPos.symbol)) : globalPos.symbol
            let subTitleText = isDisplayAsset ? globalPos.symbol : (isJpFund ? "" : (quote?.name ?? ""))

            HStack(spacing: 4) {
                SymbolLogo(symbol: globalPos.symbol, size: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(titleText)
                        .font(.inter(13, relativeTo: .body))
                        .fontWeight(.bold)
                        .lineLimit(1)
                    if storageService.showCompanyName, !subTitleText.isEmpty {
                        Text(subTitleText)
                            .font(.inter(10, relativeTo: .caption))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: 80, alignment: .leading)

            // Col 2: Avg Price (compact number for large numbers/currencies)
            Text(StorageService.formatCompactNumber(
                globalPos.avgPrice,
                decimals: storageService.resolvedPriceDecimals(symbol: globalPos.symbol, price: globalPos.avgPrice)
            ))
            .font(.inter(13, relativeTo: .body).monospacedDigit())
            .fontWeight(.medium)
            .foregroundColor(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(width: 72, alignment: .trailing)

            // Col 3: Price (regular closing price, compact number for large numbers/currencies)
            HStack(spacing: 2) {
                if let quote {
                    Text(StorageService.formatCompactNumber(quote.price * priceRate, decimals: storageService.resolvedPriceDecimals(symbol: quote.symbol, price: quote.price * priceRate)))
                        .font(.inter(13, relativeTo: .body).monospacedDigit())
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                } else {
                    ProgressView().scaleEffect(0.5)
                }
            }
            .frame(width: 72, alignment: .trailing)

            // Col 4: Chg — Today % (regular session) + Ext % (extended hours), 2 lines
            VStack(alignment: .trailing, spacing: 1) {
                if let quote {
                    Text(String(format: "%+.\(storageService.percentDecimals)f%%", quote.changePercent))
                        .font(.inter(12, relativeTo: .body).monospacedDigit())
                        .fontWeight(.medium)
                        .foregroundColor(quote.isPositive ? DS.up : DS.down)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                } else {
                    Text("—")
                        .font(.inter(12, relativeTo: .body).monospacedDigit())
                        .foregroundColor(.secondary)
                }
                if storageService.showExtendedHours, let quote, let extPct = quote.extendedChangePercent {
                    Text(String(format: "%@ %+.\(storageService.percentDecimals)f%%", quote.marketStateLabel, extPct))
                        .font(.inter(9, relativeTo: .caption2).monospacedDigit())
                        .foregroundColor(extPct >= 0 ? DS.up : DS.down)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .frame(width: 70, alignment: .trailing)

            // Col 5: Total P&L — compact amount (K/M when large) + percent, 2 lines.
            // Fixed-size fonts (not dynamic .body) so the figures never shrink
            // below the intended size regardless of system text settings.
            // Symbols without a known cost basis show "—" for both lines.
            VStack(alignment: .trailing, spacing: 1) {
                if globalPos.hasCostBasis {
                    Text(StorageService.formatCompactAmount(globalPos.pnl, symbol: globalPos.priceSymbol, signed: true, decimals: storageService.amountDecimals))
                        .font(.inter(13).monospacedDigit())
                        .fontWeight(.semibold)
                        .foregroundColor(globalPos.pnl >= 0 ? DS.up : DS.down)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(String(format: "%+.\(storageService.percentDecimals)f%%", globalPos.pct))
                        .font(.inter(11).monospacedDigit())
                        .fontWeight(.medium)
                        .foregroundColor(globalPos.pnl >= 0 ? DS.up : DS.down)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                } else {
                    Text("—")
                        .font(.inter(13).monospacedDigit())
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Text("—")
                        .font(.inter(11).monospacedDigit())
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}
