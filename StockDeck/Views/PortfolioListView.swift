import SwiftUI
import UniformTypeIdentifiers

struct PortfolioListView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @State private var showNewPortfolio = false
    @State private var newPortfolioName = ""
    @State private var searchText = ""
    @State private var importAlert: String?
    @State private var showBatchSheet = false
    @State private var batchImportTargetId: UUID? = nil
    @State private var confirmDeletePortfolio: Portfolio? = nil
    @State private var confirmDeleteHolding: (holding: Holding, portfolioId: UUID)? = nil

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
                Button(action: importPortfolios) {
                    HStack(spacing: 3) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import")
                    }
                    .font(.inter(10, relativeTo: .caption))
                }
                .buttonStyle(.borderless)
                .pointingHandCursor()
                Button(action: downloadSampleFile) {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.badge.plus")
                        Text("Sample")
                    }
                    .font(.inter(10, relativeTo: .caption))
                }
                .buttonStyle(.borderless)
                .pointingHandCursor()
                Spacer()
            }
        } else {
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.inter(10, relativeTo: .caption))
                    TextField("Filter portfolios…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.inter(10, relativeTo: .caption))
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.inter(10, relativeTo: .caption))
                        }
                        .buttonStyle(.borderless)
                        .pointingHandCursor()
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                Divider()

                // Grand total
                if storageService.portfolios.count > 0 {
                    let currSym = StorageService.currencySymbol(for: storageService.preferredCurrency)
                    let grandTotal = grandTotalValue
                    let grandCost = grandTotalCost
                    let grandPnl = grandTotal - grandCost
                    // Use the magnitude of the cost basis so long/short baskets
                    // (where the signed cost can be near zero) still report a %.
                    let grandPnlPct = abs(grandCost) >= 0.01 ? (grandPnl / abs(grandCost)) * 100 : 0

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Total value")
                                .font(.inter(10, relativeTo: .caption))
                                .foregroundColor(.secondary)
                            Text(StorageService.formatAmount(grandTotal, symbol: currSym, decimals: storageService.amountDecimals))
                                .font(.inter(13, relativeTo: .body).monospacedDigit())
                                .fontWeight(.bold)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("P&L")
                                .font(.inter(10, relativeTo: .caption))
                                .foregroundColor(.secondary)
                            HStack(spacing: 2) {
                                Text(StorageService.formatAmount(grandPnl, symbol: currSym, decimals: storageService.amountDecimals, signed: true))
                                Text(String(format: "(%.\(storageService.percentDecimals)f%%)", grandPnlPct))
                            }
                            .font(.inter(13, relativeTo: .body).monospacedDigit())
                            .fontWeight(.bold)
                            .foregroundColor(grandPnl >= 0 ? DS.up : DS.down)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                    Divider()
                }

                List {
                    // The all-portfolio symbol table belongs to the scrollable
                    // content. Only the grand Total value / P&L summary above
                    // remains fixed when there are many symbols.
                    let globals = globalPositions
                    if !globals.isEmpty {
                        VStack(spacing: 0) {
                            HStack(spacing: 0) {
                                Text("#")
                                    .frame(width: 16, alignment: .leading)
                                Text("Symbol")
                                    .frame(width: 90, alignment: .leading)
                                Text("Avg Price")
                                    .frame(width: 65, alignment: .trailing)
                                Text("Price")
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                Text("P&L")
                                    .frame(width: 95, alignment: .trailing)
                            }
                            .font(.inter(10, weight: .medium, relativeTo: .caption))
                            .foregroundColor(.secondary)
                            .tracking(0.8)
                            .textCase(.uppercase)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)

                            Divider()

                            ForEach(Array(globals.enumerated()), id: \.element.id) { index, p in
                                PortfolioQuoteRow(position: index + 1, globalPos: p)
                                if index < globals.count - 1 {
                                    Divider().padding(.leading, 36)
                                }
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    }

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

                    ForEach(filteredPortfolios) { portfolio in
                        PortfolioSection(
                            portfolio: portfolio,
                            confirmDeletePortfolio: $confirmDeletePortfolio,
                            confirmDeleteHolding: $confirmDeleteHolding,
                            onBatchImport: { targetId in
                                batchImportTargetId = targetId
                                showBatchSheet = true
                            }
                        )
                    }
                    .onDelete { offsets in
                        let currentList = filteredPortfolios
                        let ids = offsets.compactMap { idx in
                            idx < currentList.count ? currentList[idx].id : nil
                        }
                        if let firstId = ids.first, let p = currentList.first(where: { $0.id == firstId }) {
                            confirmDeletePortfolio = p
                        }
                    }
                }
                .listStyle(.plain)

                Divider()

                HStack {
                    Button(action: { showNewPortfolio = true }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("New portfolio")
                        }
                        .font(.inter(10, relativeTo: .caption))
                    }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()

                    Spacer()

                    Button(action: importPortfolios) {
                        HStack(spacing: 3) {
                            Image(systemName: "square.and.arrow.down")
                            Text("Import")
                        }
                        .font(.inter(10, relativeTo: .caption))
                    }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()

                    Button(action: downloadSampleFile) {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.badge.plus")
                            Text("Sample")
                        }
                        .font(.inter(10, relativeTo: .caption))
                    }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()

                    Button(action: { exportPortfolios(storageService.portfolios) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Export All")
                        }
                        .font(.inter(10, relativeTo: .caption))
                    }
                    .buttonStyle(.borderless)
                    .disabled(storageService.portfolios.isEmpty)
                    .pointingHandCursor()
                }
                .padding(8)
            }
        }
        }
        .sheet(isPresented: $showBatchSheet) {
            BatchImportSheet(targetPortfolioId: batchImportTargetId) {
                showBatchSheet = false
                batchImportTargetId = nil
            }
            .environmentObject(stockService)
            .environmentObject(storageService)
        }
        .alert("Import", isPresented: Binding(get: { importAlert != nil }, set: { if !$0 { importAlert = nil } })) {
            Button("OK") { importAlert = nil }
        } message: {
            Text(importAlert ?? "")
        }
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

    private var grandTotalValue: Double {
        storageService.portfolios.reduce(0) { total, portfolio in
            total + portfolio.holdings.reduce(0) { sum, holding in
                guard let quote = stockService.quotes[holding.symbol] else { return sum }
                let rate = stockService.rate(from: quote.currency)
                return sum + holding.marketValue(currentPrice: quote.price) * rate
            }
        }
    }

    private var grandTotalCost: Double {
        storageService.portfolios.reduce(0) { total, portfolio in
            total + portfolio.holdings.reduce(0) { sum, holding in
                guard let quote = stockService.quotes[holding.symbol] else { return sum }
                let rate = stockService.rate(from: quote.currency, for: holding.purchaseDate)
                return sum + holding.costBasisLocal * rate
            }
        }
    }

    struct GlobalPosition: Identifiable {
        let id: String            // symbol
        let avgPrice: Double      // weighted avg buy price, in the price currency
        let priceSymbol: String
        let pct: Double           // price return vs. avg (position-direction aware)
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
        for portfolio in storageService.portfolios {
            for h in portfolio.holdings {
                qty[h.symbol, default: 0] += h.quantity
                qtyPrice[h.symbol, default: 0] += h.quantity * h.avgPrice
            }
        }
        return qty.compactMap { symbol, q -> GlobalPosition? in
            guard abs(q) >= 1e-9, let quote = stockService.quotes[symbol] else { return nil }
            let avg = qtyPrice[symbol, default: 0] / q
            // Regular session price for P&L computation
            let price = quote.price
            let rawPct = abs(avg) >= 1e-6 ? (price / avg - 1) * 100 : 0
            // A short position gains when the price falls, so flip the sign.
            let pct = q >= 0 ? rawPct : -rawPct
            let priceCurr = storageService.stockPriceCurrency
            let priceSymbol = StorageService.currencySymbol(for: priceCurr.isEmpty ? quote.currency : priceCurr)
            let value = abs(price * q) * stockService.rate(from: quote.currency)

            let extPrice: Double? = quote.isExtendedHours ? quote.alertPrice : nil
            let extChangePercent: Double? = quote.isExtendedHours ? quote.extendedChangePercent : nil

            return GlobalPosition(id: symbol, avgPrice: avg, priceSymbol: priceSymbol, pct: pct,
                                  currentPrice: price, priceChangePercent: quote.changePercent,
                                  extPrice: extPrice, extChangePercent: extChangePercent,
                                  value: value)
        }
        .sorted { $0.value > $1.value }
    }

    private func exportPortfolios(_ portfolios: [Portfolio]) {
        PortfolioIO.exportAll(portfolios, storageService: storageService, restoreActivationPolicy: true)
    }

    private func importPortfolios() {
        PortfolioIO.importInto(storageService, restoreActivationPolicy: true) { message in
            self.importAlert = message
        }
    }

    private func downloadSampleFile() {
        PortfolioIO.downloadSample(storageService: storageService, restoreActivationPolicy: true) { message in
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

    private func exportSingle() {
        PortfolioIO.exportAll([portfolio], storageService: storageService, restoreActivationPolicy: true)
    }

    private var currSymbol: String {
        StorageService.currencySymbol(for: storageService.preferredCurrency)
    }

    var totalValue: Double {
        portfolio.holdings.reduce(0) { sum, holding in
            guard let quote = stockService.quotes[holding.symbol] else { return sum }
            let rate = stockService.rate(from: quote.currency)
            return sum + holding.marketValue(currentPrice: quote.displayPrice(extendedHours: storageService.showExtendedHours)) * rate
        }
    }

    var totalPnl: Double {
        totalValue - totalCost
    }

    var totalCost: Double {
        portfolio.holdings.reduce(0) { sum, holding in
            guard let quote = stockService.quotes[holding.symbol] else { return sum }
            let rate = stockService.rate(from: quote.currency, for: holding.purchaseDate)
            return sum + holding.costBasisLocal * rate
        }
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
                    Text("P&L")
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
                        .frame(width: 80, alignment: .leading)
                    Text("Price")
                        .frame(maxWidth: .infinity)
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

            // Add holding / Batch import buttons
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
                HStack {
                    Text(portfolio.name)
                        .font(.inter(13, weight: .bold, relativeTo: .headline))
                    Spacer()
                    Menu {
                        Button {
                            renameText = portfolio.name
                            isRenaming = true
                        } label: {
                            Label("Rename Portfolio", systemImage: "pencil")
                        }
                        Button {
                            onBatchImport?(portfolio.id)
                        } label: {
                            Label("Batch Import…", systemImage: "square.and.arrow.down")
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
    @Environment(\.editHoldingAction) var editHoldingAction
    let holding: Holding
    let portfolioId: UUID
    @Binding var confirmDeleteHolding: (holding: Holding, portfolioId: UUID)?

    var quote: StockQuote? {
        stockService.quotes[holding.symbol]
    }

    private func formatQty(_ qty: Double) -> String {
        qty == qty.rounded(.down) ? String(format: "%.0f", qty) : String(format: "%.2f", qty)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Col 1: Ticker + Qty@Avg
            HStack(spacing: 6) {
                SymbolLogo(symbol: holding.symbol, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text(holding.symbol)
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
                    Text("\(formatQty(holding.quantity))\u{00D7}\(StorageService.formatNumber(holding.avgPrice, decimals: 2))")
                        .font(.inter(10, relativeTo: .caption).monospacedDigit())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(width: 120, alignment: .leading)

            if let quote {
                let rate = stockService.rate(from: quote.currency)
                let pRate = stockService.priceRate(from: quote.currency)
                let priceCurr = storageService.stockPriceCurrency
                let priceSymbol = StorageService.currencySymbol(for: priceCurr.isEmpty ? quote.currency : priceCurr)
                let prefSymbol = StorageService.currencySymbol(for: storageService.preferredCurrency)

                // Col 2: Price + badge
                HStack(spacing: 3) {
                    Text("\(priceSymbol)\(StorageService.formatNumber(quote.displayPrice(extendedHours: storageService.showExtendedHours) * pRate, decimals: storageService.resolvedPriceDecimals(symbol: quote.symbol, price: quote.displayPrice(extendedHours: storageService.showExtendedHours) * pRate)))")
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
                .frame(maxWidth: .infinity)

                // Col 3: Controvalore + P&L in preferred currency
                let displayPrice = quote.displayPrice(extendedHours: storageService.showExtendedHours)
                let marketVal = holding.marketValue(currentPrice: displayPrice) * rate
                let costRate = stockService.rate(from: quote.currency, for: holding.purchaseDate)
                let costBasis = holding.costBasisLocal * costRate
                let pnl = marketVal - costBasis
                let pnlPct = abs(costBasis) >= 0.01 ? (pnl / abs(costBasis)) * 100 : 0

                VStack(alignment: .trailing, spacing: 1) {
                    Text(StorageService.formatAmount(marketVal, symbol: prefSymbol, decimals: storageService.amountDecimals))
                        .font(.inter(13, relativeTo: .body).monospacedDigit())
                        .fontWeight(.medium)
                    Text("\(StorageService.formatAmount(pnl, symbol: prefSymbol, decimals: storageService.amountDecimals, signed: true)) (\(String(format: "%.\(storageService.percentDecimals)f%%", pnlPct)))")
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
        .contextMenu {
            Button {
                editHoldingAction.perform(portfolioId, holding)
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) {
                confirmDeleteHolding = (holding, portfolioId)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

struct EditHoldingView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService

    let portfolioId: UUID
    let holding: Holding
    @Binding var isPresented: (portfolioId: UUID, holding: Holding)?

    @State private var symbolText: String
    @State private var quantityText: String
    @State private var avgPriceText: String
    @State private var leverageText: String
    @State private var isShort: Bool
    @State private var purchaseDate: Date
    @State private var dateText: String = ""

    init(portfolioId: UUID, holding: Holding, isPresented: Binding<(portfolioId: UUID, holding: Holding)?>) {
        self.portfolioId = portfolioId
        self.holding = holding
        self._isPresented = isPresented
        _symbolText = State(initialValue: holding.symbol)
        // Quantity is edited as a positive magnitude; the Long/Short picker holds the sign.
        _quantityText = State(initialValue: String(format: "%.2f", abs(holding.quantity)))
        _avgPriceText = State(initialValue: String(format: "%.2f", holding.avgPrice))
        _leverageText = State(initialValue: (holding.leverage.map { $0 != 1 ? String(format: "%g", $0) : "" }) ?? "")
        _isShort = State(initialValue: holding.quantity < 0)
        _purchaseDate = State(initialValue: holding.purchaseDate ?? Date())
        _dateText = State(initialValue: Self.dateInputFormatter.string(from: holding.purchaseDate ?? Date()))
    }

    private var costBasisInfo: (costInStock: Double, rate: Double, costInPreferred: Double)? {
        guard let qty = Double(quantityText.replacingOccurrences(of: ",", with: ".")),
              let price = Double(avgPriceText.replacingOccurrences(of: ",", with: ".")),
              let quote = stockService.quotes[symbolText.uppercased().trimmingCharacters(in: .whitespaces)] ?? stockService.quotes[holding.symbol],
              qty != 0, price > 0
        else { return nil }
        let costInStock = price * qty
        let rate = stockService.rate(from: quote.currency, for: purchaseDate)
        return (costInStock, rate, costInStock * rate)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Edit \(symbolText.isEmpty ? holding.symbol : symbolText.uppercased())")
                    .font(.inter(13, weight: .bold, relativeTo: .headline))
                Spacer()
                Button("Close") { isPresented = nil }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.top)

            VStack(alignment: .leading) {
                Text("Symbol")
                    .font(.inter(10, relativeTo: .caption))
                    .foregroundColor(.secondary)
                TextField("Symbol (e.g. AAPL)", text: $symbolText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)

            if storageService.advancedPositions {
                VStack(alignment: .leading) {
                    Text("Position")
                        .font(.inter(10, relativeTo: .caption))
                        .foregroundColor(.secondary)
                    Picker("Position", selection: $isShort) {
                        Text("Long").tag(false)
                        Text("Short").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.horizontal)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Quantity")
                        .font(.inter(10, relativeTo: .caption))
                        .foregroundColor(.secondary)
                    TextField("0", text: $quantityText)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading) {
                    Text("Avg price")
                        .font(.inter(10, relativeTo: .caption))
                        .foregroundColor(.secondary)
                    TextField("0.00", text: $avgPriceText)
                        .textFieldStyle(.roundedBorder)
                }
                if storageService.advancedPositions {
                    VStack(alignment: .leading) {
                        Text("Leverage")
                            .font(.inter(10, relativeTo: .caption))
                            .foregroundColor(.secondary)
                        TextField("1\u{00D7}", text: $leverageText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                    }
                }
            }
            .padding(.horizontal)

            if storageService.advancedPositions {
                Text("Pick Long or Short. Leverage multiplies P&L and exposure (empty = 1\u{00D7}).")
                    .font(.inter(10, relativeTo: .caption))
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }

            VStack(alignment: .leading) {
                Text("Purchase date")
                    .font(.inter(10, relativeTo: .caption))
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    TextField("YYYY-MM-DD", text: $dateText)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: dateText) { _, new in
                            if let parsed = parseDateString(new) {
                                purchaseDate = parsed
                            }
                        }
                    DatePicker("", selection: $purchaseDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .onChange(of: purchaseDate) { _, new in
                            dateText = Self.dateInputFormatter.string(from: new)
                        }
                }
            }
            .padding(.horizontal)

            if let quote = stockService.quotes[symbolText.uppercased().trimmingCharacters(in: .whitespaces)] ?? stockService.quotes[holding.symbol], quote.currency != storageService.preferredCurrency, let info = costBasisInfo {
                let stockSym = StorageService.currencySymbol(for: quote.currency)
                let prefSym = StorageService.currencySymbol(for: storageService.preferredCurrency)
                let dateStr = Self.dateFormatter.string(from: purchaseDate)
                Text("Cost basis: \(prefSym)\(String(format: "%.2f", info.costInPreferred)) (\(stockSym)\(String(format: "%.2f", info.costInStock)) × \(String(format: "%.4f", info.rate)) on \(dateStr))")
                    .font(.inter(10, relativeTo: .caption))
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }

            Spacer()

            Button("Save") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .disabled(quantityText.isEmpty || avgPriceText.isEmpty || symbolText.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            Task {
                await stockService.ensureHistoricalRate(for: Holding(id: holding.id, symbol: symbolText, quantity: holding.quantity, avgPrice: holding.avgPrice, purchaseDate: purchaseDate))
            }
        }
        .onChange(of: purchaseDate) { _, _ in
            Task {
                await stockService.ensureHistoricalRate(for: Holding(id: holding.id, symbol: symbolText, quantity: Double(quantityText.replacingOccurrences(of: ",", with: ".")) ?? 0, avgPrice: Double(avgPriceText.replacingOccurrences(of: ",", with: ".")) ?? 0, purchaseDate: purchaseDate))
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private static let dateInputFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func parseDateString(_ str: String) -> Date? {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let isoFormatter = ISO8601DateFormatter()
        if let d = isoFormatter.date(from: trimmed) { return d }
        let formats = ["yyyy-MM-dd", "yyyy/MM/dd", "dd/MM/yyyy", "MM/dd/yyyy", "dd-MMM-yyyy", "dd-MMM"]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in formats {
            df.dateFormat = fmt
            if let d = df.date(from: trimmed) { return d }
        }
        return nil
    }

    private func save() {
        let advanced = storageService.advancedPositions
        guard let qty = Double(quantityText.replacingOccurrences(of: ",", with: ".")),
              let price = Double(avgPriceText.replacingOccurrences(of: ",", with: ".")),
              price > 0, abs(qty) > 0
        else { return }
        let short = advanced ? isShort : (holding.quantity < 0)
        let signedQty = short ? -abs(qty) : abs(qty)
        let leverage: Double? = {
            guard advanced else { return holding.leverage }
            guard let l = Double(leverageText.replacingOccurrences(of: ",", with: ".")),
                  l > 0, l != 1
            else { return nil }
            return l
        }()
        storageService.updateHolding(in: portfolioId, holdingId: holding.id, symbol: symbolText, quantity: signedQty, avgPrice: price, purchaseDate: purchaseDate, leverage: leverage)
        Task {
            await stockService.refreshAll(storageService: storageService)
        }
        isPresented = nil
    }
}

struct GroupedHoldingRow: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @Environment(\.editHoldingAction) var editHoldingAction
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

    var body: some View {
        VStack(spacing: 0) {
            // Parent Summary Row
            HStack(spacing: 0) {
                // Col 1: Ticker + Lot Count + Chevron
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(DS.brand)
                    SymbolLogo(symbol: symbol, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(symbol)
                                .font(.inter(13, relativeTo: .body).monospacedDigit())
                                .fontWeight(.bold)
                            Text("\(holdings.count) lots")
                                .font(.inter(8, weight: .semibold, relativeTo: .caption2))
                                .foregroundColor(DS.brand)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 3).fill(DS.brand.opacity(0.12)))
                        }
                        Text("\(formatQty(totalQty))\u{00D7}\(StorageService.formatNumber(weightedAvgPrice, decimals: 2)) avg")
                            .font(.inter(10, relativeTo: .caption).monospacedDigit())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .frame(width: 140, alignment: .leading)

                if let quote {
                    let rate = stockService.rate(from: quote.currency)
                    let pRate = stockService.priceRate(from: quote.currency)
                    let priceCurr = storageService.stockPriceCurrency
                    let priceSymbol = StorageService.currencySymbol(for: priceCurr.isEmpty ? quote.currency : priceCurr)
                    let prefSymbol = StorageService.currencySymbol(for: storageService.preferredCurrency)

                    // Col 2: Price
                    HStack(spacing: 3) {
                        Text("\(priceSymbol)\(StorageService.formatNumber(quote.displayPrice(extendedHours: storageService.showExtendedHours) * pRate, decimals: storageService.resolvedPriceDecimals(symbol: quote.symbol, price: quote.displayPrice(extendedHours: storageService.showExtendedHours) * pRate)))")
                            .font(.inter(13, relativeTo: .body).monospacedDigit())
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)

                    // Col 3: Total Market Value & Total P&L
                    let displayPrice = quote.displayPrice(extendedHours: storageService.showExtendedHours)
                    let totalMarketVal = holdings.reduce(0) { $0 + ($1.marketValue(currentPrice: displayPrice) * rate) }
                    let totalCostBasis = holdings.reduce(0) { sum, h in
                        let costRate = stockService.rate(from: quote.currency, for: h.purchaseDate)
                        return sum + (h.costBasisLocal * costRate)
                    }
                    let totalPnl = totalMarketVal - totalCostBasis
                    let totalPnlPct = abs(totalCostBasis) >= 0.01 ? (totalPnl / abs(totalCostBasis)) * 100 : 0

                    VStack(alignment: .trailing, spacing: 1) {
                        Text(StorageService.formatAmount(totalMarketVal, symbol: prefSymbol, decimals: storageService.amountDecimals))
                            .font(.inter(13, relativeTo: .body).monospacedDigit())
                            .fontWeight(.medium)
                        Text("\(StorageService.formatAmount(totalPnl, symbol: prefSymbol, decimals: storageService.amountDecimals, signed: true)) (\(String(format: "%.\(storageService.percentDecimals)f%%", totalPnlPct)))")
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
                    ForEach(holdings) { h in
                        HStack(spacing: 0) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 8))
                                    .foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(formatQty(h.quantity)) @ \(StorageService.formatNumber(h.avgPrice, decimals: 2))")
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
                                let rate = stockService.rate(from: quote.currency)
                                let displayPrice = quote.displayPrice(extendedHours: storageService.showExtendedHours)
                                let val = h.marketValue(currentPrice: displayPrice) * rate
                                let costRate = stockService.rate(from: quote.currency, for: h.purchaseDate)
                                let cost = h.costBasisLocal * costRate
                                let pnl = val - cost
                                let prefSymbol = StorageService.currencySymbol(for: storageService.preferredCurrency)

                                Text(StorageService.formatAmount(val, symbol: prefSymbol, decimals: storageService.amountDecimals))
                                    .font(.inter(11, relativeTo: .caption).monospacedDigit())
                                    .foregroundColor(.secondary)
                                    .frame(width: 70, alignment: .trailing)

                                Text(StorageService.formatAmount(pnl, symbol: prefSymbol, decimals: storageService.amountDecimals, signed: true))
                                    .font(.inter(10, relativeTo: .caption2).monospacedDigit())
                                    .foregroundColor(pnl >= 0 ? DS.up : DS.down)
                                    .frame(width: 70, alignment: .trailing)
                            }

                            HStack(spacing: 6) {
                                Button { editHoldingAction.perform(portfolioId, h) } label: {
                                    Image(systemName: "pencil").font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                                .pointingHandCursor()
                                .help("Edit lot")

                                Button { confirmDeleteHolding = (h, portfolioId) } label: {
                                    Image(systemName: "trash").font(.system(size: 10)).foregroundColor(.red.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                                .pointingHandCursor()
                                .help("Delete lot")
                            }
                            .padding(.leading, 8)
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(DS.cardAlt.opacity(0.5)))
                    }

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
                .padding(.leading, 8)
                .padding(.bottom, 4)
            }
        }
    }
}

struct PortfolioQuoteRow: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService

    let position: Int
    let globalPos: PortfolioListView.GlobalPosition

    var quote: StockQuote? {
        stockService.quotes[globalPos.symbol]
    }

    private var displayCurrency: String {
        let pref = storageService.stockPriceCurrency
        guard let q = quote else { return pref }
        return pref.isEmpty ? q.currency : pref
    }

    private var priceRate: Double {
        guard let q = quote else { return 1.0 }
        return stockService.priceRate(from: q.currency)
    }

    private var currSymbol: String {
        StorageService.currencySymbol(for: displayCurrency)
    }

    var body: some View {
        HStack(spacing: 0) {
            Text("\(position)")
                .font(.inter(10, relativeTo: .caption).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 16, alignment: .leading)

            // Col 1: Logo + symbol + name
            HStack(spacing: 5) {
                SymbolLogo(symbol: globalPos.symbol, size: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(globalPos.symbol)
                        .font(.inter(12, relativeTo: .body).monospacedDigit())
                        .fontWeight(.bold)
                        .lineLimit(1)
                    if storageService.showCompanyName, let q = quote {
                        Text(q.name)
                            .font(.inter(9, relativeTo: .caption))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: 90, alignment: .leading)

            // Col 2: Avg Price
            Text(StorageService.formatAmount(
                globalPos.avgPrice,
                symbol: globalPos.priceSymbol,
                decimals: StorageService.priceDecimals(symbol: globalPos.symbol, price: globalPos.avgPrice)
            ))
            .font(.inter(12, relativeTo: .body).monospacedDigit())
            .foregroundColor(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: 65, alignment: .trailing)

            // Col 3: Price + Pre/Post badge
            VStack(alignment: .trailing, spacing: 0) {
                if let quote {
                    HStack(spacing: 2) {
                        Text("\(currSymbol)\(StorageService.formatNumber(quote.displayPrice(extendedHours: storageService.showExtendedHours) * priceRate, decimals: storageService.resolvedPriceDecimals(symbol: quote.symbol, price: quote.displayPrice(extendedHours: storageService.showExtendedHours) * priceRate)))")
                            .font(.inter(12, relativeTo: .body).monospacedDigit())
                            .fontWeight(.medium)
                        if storageService.showExtendedHours, quote.isExtendedHours, !quote.marketStateLabel.isEmpty {
                            Text(quote.marketStateLabel)
                                .font(.inter(8, weight: .semibold, relativeTo: .caption2))
                                .foregroundColor(.white)
                                .padding(.horizontal, 2)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(quote.marketState.hasPrefix("PRE") ? DS.gold : DS.palette[3])
                                )
                        }
                    }
                    if storageService.showDayRange, let high = quote.dayHigh, let low = quote.dayLow {
                        let rangeDecimals = storageService.resolvedPriceDecimals(symbol: quote.symbol, price: low * priceRate)
                        Text("\(StorageService.formatNumber(low * priceRate, decimals: rangeDecimals)) – \(StorageService.formatNumber(high * priceRate, decimals: rangeDecimals))")
                            .font(.inter(9, relativeTo: .caption).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                } else {
                    ProgressView().scaleEffect(0.5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            // Col 4: P&L % + daily change %
            VStack(alignment: .trailing, spacing: 0) {
                Text(String(format: "%+.\(storageService.percentDecimals)f%%", globalPos.pct))
                    .font(.inter(12, relativeTo: .body).monospacedDigit())
                    .fontWeight(.bold)
                    .foregroundColor(globalPos.pct >= 0 ? DS.up : DS.down)
                if let quote {
                    Text(String(format: "%+.\(storageService.percentDecimals)f%%", quote.changePercent))
                        .font(.inter(9, relativeTo: .caption).monospacedDigit())
                        .foregroundColor(quote.isPositive ? DS.up : DS.down)
                }
            }
            .frame(width: 95, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}
