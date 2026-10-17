import SwiftUI
import UniformTypeIdentifiers

private enum PortfolioCol {
    static let symbol: CGFloat = 124
    static let pinnedWidth: CGFloat = 148
    static let headerHeight: CGFloat = 28
    static let rowHeight: CGFloat = 38
    static let avgPrice: CGFloat = 78
    static let cost: CGFloat = 84
    static let price: CGFloat = 82
    static let change: CGFloat = 80
    static let value: CGFloat = 86
    static let todayPnl: CGFloat = 92
    static let totalPnl: CGFloat = 92
    static let shares: CGFloat = 70
    static let lots: CGFloat = 56
    static let weight: CGFloat = 68
    static let marketCap: CGFloat = 88
    static let valuation: CGFloat = 72
    static let volume: CGFloat = 76

    static func width(for metric: PortfolioColumnMetric) -> CGFloat {
        switch metric {
        case .avgPrice: return avgPrice
        case .cost: return cost
        case .price: return price
        case .change: return change
        case .value: return value
        case .todayPnl: return todayPnl
        case .totalPnl: return totalPnl
        case .shares: return shares
        case .lots: return lots
        case .weight: return weight
        case .marketCap: return marketCap
        case .pe, .forwardPe, .pb, .divYield, .eps: return valuation
        case .volume50d, .volume50w: return volume
        }
    }
}

private struct PortfolioAddItem: Identifiable {
    let symbol: String
    let portfolioId: UUID
    var id: String { "\(symbol)-\(portfolioId)" }
}

struct PortfolioListView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @Environment(\.showSymbolDetail) private var showSymbolDetail
    @Environment(\.addHoldingAction) private var addHoldingAction
    @State private var viewModel = PortfolioViewModel(scope: .all)
    @StateObject private var scrollCoordinator = ScrollSyncCoordinator()

    @State private var sortColumn: PortfolioOverview.PositionSortColumn = .weight
    @State private var sortAscending: Bool = false

    @State private var showNewPortfolio = false
    @State private var showBinanceSheet = false
    @State private var newPortfolioName = ""
    @State private var importAlert: String?
    @State private var pendingImportResult: PortfolioIO.ImportResult? = nil
    @State private var confirmDeletePortfolio: Portfolio? = nil
    @State private var renamingPortfolio: Portfolio? = nil
    @State private var renamePortfolioName = ""
    @State private var selectedPortfolioId: UUID? = nil
    @State private var draggingPortfolioId: UUID? = nil
    @State private var previewPortfolioIds: [UUID] = []

    @State private var addToPortfolio: (symbol: String, portfolioId: UUID)? = nil
    struct TargetSheetItem: Identifiable { let symbol: String; var id: String { symbol } }
    @State private var targetSymbol: TargetSheetItem? = nil
    @State private var alertTarget: TargetSheetItem? = nil
    @State private var targetCloseHolding: PortfolioOverview.TargetCloseHolding? = nil
    @State private var isSyncingBinance = false
    @State private var syncError: String? = nil

    static let defaultPopoverColumns: [PortfolioColumnMetric] = [.price, .change, .value, .totalPnl]

    private var activeColumns: [PortfolioColumnMetric] {
        storageService.resolvedPortfolioColumns
    }

    private var metricsTableWidth: CGFloat {
        let colsWidth = activeColumns.reduce(CGFloat.zero) { $0 + PortfolioCol.width(for: $1) }
        return max(462 - PortfolioCol.pinnedWidth, colsWidth + 24)
    }

    private func hoverBox(for symbol: String) -> RowHoverBox {
        scrollCoordinator.hoverBox(for: symbol)
    }

    private var insertionOrderedSymbols: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for p in viewModel.portfolios {
            for h in p.holdings {
                let sym = h.symbol.uppercased()
                if !seen.contains(sym) {
                    seen.insert(sym)
                    result.append(sym)
                }
            }
        }
        return result
    }

    private var displaySymbols: [String] {
        viewModel.sortedSymbols(
            column: sortColumn,
            ascending: sortAscending,
            manualOrder: insertionOrderedSymbols
        )
    }

    private func loadPositionSort(for key: String) {
        if let saved = storageService.positionSort(for: key),
           let col = PortfolioOverview.PositionSortColumn(rawValue: saved.column) {
            sortColumn = col
            sortAscending = saved.ascending
        } else {
            sortColumn = .weight
            sortAscending = false
        }
    }

    private func setPositionSort(_ column: PortfolioOverview.PositionSortColumn, ascending: Bool) {
        sortColumn = column
        sortAscending = ascending
        storageService.setPositionSort(column: column.rawValue, ascending: ascending, for: viewModel.scopeKey)
    }

    private func toggleSort(_ column: PortfolioOverview.PositionSortColumn) {
        if sortColumn == column {
            setPositionSort(column, ascending: !sortAscending)
        } else {
            setPositionSort(column, ascending: (column == .symbol))
        }
    }

    private func sortColumn(for metric: PortfolioColumnMetric) -> PortfolioOverview.PositionSortColumn {
        switch metric {
        case .avgPrice: return .avgPrice
        case .price, .change: return .price
        case .cost: return .cost
        case .value: return .value
        case .todayPnl: return .todayPnl
        case .totalPnl: return .pnl
        case .shares, .lots: return .shares
        case .weight, .volume50d, .volume50w: return .weight
        case .marketCap: return .marketCap
        case .pe: return .pe
        case .forwardPe: return .forwardPe
        case .pb: return .pb
        case .divYield: return .divYield
        case .eps: return .eps
        }
    }

    @ViewBuilder
    private func sortHeader(
        _ title: LocalizedStringKey,
        column: PortfolioOverview.PositionSortColumn,
        align: Alignment = .trailing,
        leadingIndent: CGFloat = 0
    ) -> some View {
        Button(action: {
            toggleSort(column)
        }) {
            HStack(spacing: 2) {
                if align == .trailing { Spacer(minLength: 0) }
                Text(title)
                if sortColumn == column {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.inter(8, relativeTo: .caption2))
                }
                if align == .leading { Spacer(minLength: 0) }
            }
            .padding(.leading, leadingIndent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    @ViewBuilder
    private func columnHeader(_ col: PortfolioColumnMetric) -> some View {
        let width = PortfolioCol.width(for: col)
        switch col {
        case .volume50d:
            Text("50D Vol")
                .frame(width: width, alignment: .trailing)
        case .volume50w:
            Text("50W Vol")
                .frame(width: width, alignment: .trailing)
        case .cost:
            sortHeader("Cost", column: sortColumn(for: col), align: .trailing)
                .frame(width: width, alignment: .trailing)
        case .value:
            sortHeader("Value", column: sortColumn(for: col), align: .trailing)
                .frame(width: width, alignment: .trailing)
        default:
            sortHeader(LocalizedStringKey(col.title), column: sortColumn(for: col), align: .trailing)
                .frame(width: width, alignment: .trailing)
        }
    }

    private var frozenHeaderRow: some View {
        HStack(spacing: 0) {
            sortHeader("Symbol", column: .symbol, align: .leading, leadingIndent: 25)
                .frame(width: PortfolioCol.symbol, alignment: .leading)
        }
        .font(.inter(10.5, weight: .semibold, relativeTo: .caption2))
        .foregroundColor(.secondary)
        .tracking(0.8)
        .textCase(.uppercase)
        .padding(.horizontal, 12)
        .frame(width: PortfolioCol.pinnedWidth, height: PortfolioCol.headerHeight, alignment: .leading)
    }

    private var metricsHeaderRow: some View {
        HStack(spacing: 0) {
            ForEach(activeColumns, id: \.self) { col in
                columnHeader(col)
            }
        }
        .font(.inter(10.5, weight: .semibold, relativeTo: .caption2))
        .foregroundColor(.secondary)
        .tracking(0.8)
        .textCase(.uppercase)
        .padding(.horizontal, 12)
        .frame(height: PortfolioCol.headerHeight, alignment: .leading)
    }

    @ViewBuilder
    private func frozenRowContent(_ symbol: String, hoverBox: RowHoverBox) -> some View {
        PortfolioFrozenRow(
            symbol: symbol,
            aggregate: viewModel.symbolAggregates[symbol],
            buyTarget: storageService.buyTarget(for: symbol),
            showCompanyName: storageService.showCompanyName,
            valueDecimals: storageService.valueDecimals,
            hoverBox: hoverBox,
            onOpen: { showSymbolDetail.perform(symbol) },
            menu: { portfolioContextMenu(symbol: symbol) }
        )
    }

    @ViewBuilder
    private func metricsRowContent(_ symbol: String, hoverBox: RowHoverBox) -> some View {
        if let agg = viewModel.symbolAggregates[symbol] {
            let totalVal = viewModel.valuationCache.totalValue
            let weight = abs(totalVal) >= 0.01 ? (abs(agg.value) / abs(totalVal) * 100) : 0
            PortfolioMetricsRow(
                stockService: stockService,
                symbol: symbol,
                aggregate: agg,
                weight: weight,
                columns: activeColumns,
                hoverBox: hoverBox,
                onOpen: { showSymbolDetail.perform(symbol) },
                menu: { portfolioContextMenu(symbol: symbol) }
            )
        } else {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: PortfolioCol.price, height: PortfolioCol.rowHeight, alignment: .center)
                .padding(.horizontal, 12)
                .background(hoverBox.isHovered ? DS.cardAlt.opacity(0.6) : Color.clear)
                .contentShape(Rectangle())
                .onTapGesture { showSymbolDetail.perform(symbol) }
                .pointingHandCursor()
                .onHover { hoverBox.isHovered = $0 }
                .contextMenu { portfolioContextMenu(symbol: symbol) }
        }
    }

    private var deletePortfolioAlertBinding: Binding<Bool> {
        Binding(
            get: { confirmDeletePortfolio != nil },
            set: { if !$0 { confirmDeletePortfolio = nil } }
        )
    }

    private var selectedPortfolio: Portfolio? {
        guard let id = selectedPortfolioId else { return nil }
        return storageService.portfolios.first(where: { $0.id == id })
    }

    private var editablePortfolios: [Portfolio] {
        storageService.portfolios.filter { !$0.isReadOnly }
    }

    private func syncBinance(portfolioId: UUID) {
        isSyncingBinance = true
        Task {
            do {
                try await storageService.syncBinancePortfolio(id: portfolioId)
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
                    portfolioPickerBar

                    Divider().overlay(DS.hairline)

                    summaryHeaderBar

                    Divider().overlay(DS.hairline)

                    let symbols = displaySymbols
                    if symbols.isEmpty {
                        emptyHoldingsView
                    } else {
                        HStack(spacing: 0) {
                            // LEFT FROZEN PANE: Symbol
                            VStack(spacing: 0) {
                                frozenHeaderRow
                                Divider().overlay(DS.hairline)
                                ScrollView(.vertical, showsIndicators: false) {
                                    LazyVStack(spacing: 0) {
                                        ForEach(symbols, id: \.self) { symbol in
                                            let box = hoverBox(for: symbol)
                                            frozenRowContent(symbol, hoverBox: box)
                                            if symbol != symbols.last {
                                                Divider().padding(.leading, 12)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .background(ScrollViewSyncAttachment { scrollCoordinator.registerVerticalFrozen($0) })
                                }
                                .frame(width: PortfolioCol.pinnedWidth)
                            }
                            .frame(width: PortfolioCol.pinnedWidth)
                            .overlay(alignment: .trailing) {
                                HStack(spacing: 0) {
                                    Spacer()
                                    Divider()
                                }
                            }
                            .background(DS.card)

                            // RIGHT METRICS PANE
                            VStack(spacing: 0) {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    metricsHeaderRow
                                        .frame(minWidth: metricsTableWidth, alignment: .leading)
                                        .background(ScrollViewSyncAttachment { scrollCoordinator.registerHorizontalHeader($0) })
                                }
                                .frame(height: PortfolioCol.headerHeight)
                                Divider().overlay(DS.hairline)
                                ScrollView([.horizontal, .vertical], showsIndicators: true) {
                                    LazyVStack(spacing: 0) {
                                        ForEach(symbols, id: \.self) { symbol in
                                            let box = hoverBox(for: symbol)
                                            metricsRowContent(symbol, hoverBox: box)
                                            if symbol != symbols.last {
                                                Divider().padding(.horizontal, 12)
                                            }
                                        }
                                    }
                                    .padding(.vertical, 4)
                                    .frame(minWidth: metricsTableWidth, alignment: .leading)
                                    .background(ScrollViewSyncAttachment { scrollCoordinator.register2DBody($0) })
                                }
                                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                            }
                        }
                        .id(viewModel.scopeKey)
                        .background(DS.card)
                        .frame(maxHeight: .infinity)
                        .refreshable {
                            if storageService.iCloudSyncEnabled {
                                iCloudSyncService.shared.pullAndMerge(force: false)
                            }
                            await stockService.refreshAll(storageService: storageService)
                        }
                    }

                    Divider().overlay(DS.hairline)

                    bottomActionBar
                }
            }
        }
        .onChange(of: selectedPortfolioId) { _, newValue in
            scrollCoordinator.reset()
            if let id = newValue {
                viewModel.scope = .portfolio(id)
            } else {
                viewModel.scope = .all
            }
            loadPositionSort(for: viewModel.scopeKey)
        }
        .onAppear {
            viewModel.setup(stockService: stockService, storageService: storageService)
            loadPositionSort(for: viewModel.scopeKey)
        }
        .task(id: "\(viewModel.symbols.joined())-\(activeColumns.map(\.rawValue).joined())") {
            let needsSparklines = activeColumns.contains(.volume50d) || activeColumns.contains(.volume50w)
            if needsSparklines {
                await stockService.ensureSparklines(for: viewModel.symbols)
            }
            let needsValuation = activeColumns.contains { $0.category == .valuation }
            if needsValuation {
                for sym in viewModel.symbols where stockService.quotes[sym]?.hasValuationData != true {
                    await stockService.ensureQuoteValuation(for: sym)
                }
            }
        }
        .onChange(of: draggingPortfolioId) { _, newValue in
            if newValue == nil { previewPortfolioIds = [] }
        }
        .sheet(isPresented: $showBinanceSheet) {
            AddBinancePortfolioSheet(storageService: storageService)
        }
        .sheet(item: Binding<PortfolioAddItem?>(
            get: {
                if let atp = addToPortfolio {
                    return PortfolioAddItem(symbol: atp.symbol, portfolioId: atp.portfolioId)
                }
                return nil
            },
            set: { addToPortfolio = $0.map { ($0.symbol, $0.portfolioId) } }
        )) { item in
            QuickAddHoldingView(symbol: item.symbol, portfolioId: item.portfolioId) {
                addToPortfolio = nil
            }
            .environmentObject(stockService)
            .environmentObject(storageService)
            .frame(width: 300, height: storageService.advancedPositions ? 290 : 220)
        }
        .sheet(item: $alertTarget) { item in
            PriceAlertSheet(symbol: item.symbol) { alertTarget = nil }
                .environmentObject(stockService)
                .environmentObject(storageService)
        }
        .sheet(item: $targetCloseHolding) { target in
            CloseHoldingSheet(
                portfolioId: target.portfolioId,
                holding: target.holding,
                quote: target.quote,
                onDismiss: {
                    targetCloseHolding = nil
                    viewModel.recomputeAll()
                }
            )
            .environmentObject(storageService)
            .environmentObject(stockService)
        }
        .overlay {
            if let item = targetSymbol {
                ZStack {
                    Color.black.opacity(0.25)
                        .contentShape(Rectangle())
                        .onTapGesture { targetSymbol = nil }
                    ScrollView(.vertical, showsIndicators: false) {
                        StockTargetSheet(symbol: item.symbol) { targetSymbol = nil }
                            .environmentObject(stockService)
                            .environmentObject(storageService)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
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
        .alert("Binance Sync Error", isPresented: Binding(get: { syncError != nil }, set: { if !$0 { syncError = nil } })) {
            Button("OK", role: .cancel) { syncError = nil }
        } message: {
            Text(syncError ?? "")
        }
        .alert("Delete Portfolio", isPresented: deletePortfolioAlertBinding) {
            Button("Cancel", role: .cancel) { confirmDeletePortfolio = nil }
            Button("Delete", role: .destructive) {
                if let p = confirmDeletePortfolio {
                    if selectedPortfolioId == p.id {
                        selectedPortfolioId = nil
                    }
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
    }

    // MARK: - Subviews

    private var summaryHeaderBar: some View {
        let currSym = StorageService.currencySymbol(for: storageService.preferredCurrency)
        let totalVal = viewModel.valuationCache.totalValue
        let pnl = viewModel.valuationCache.totalPnl
        let pnlPct = viewModel.valuationCache.totalPnlPercent
        let todayGain = viewModel.valuationCache.dayChangeValue
        let todayPct = viewModel.valuationCache.dayChangePercent

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Total value")
                    .font(.inter(10, relativeTo: .caption))
                    .foregroundColor(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(StorageService.formatAmount(totalVal, symbol: currSym, decimals: storageService.amountDecimals))
                        .font(.inter(13.5, relativeTo: .body).monospacedDigit())
                        .fontWeight(.bold)
                    if let secVal = viewModel.secondaryTotalValue, let secSym = viewModel.secondaryCurrencySymbol {
                        Text("≈ \(StorageService.formatAmount(secVal, symbol: secSym, decimals: viewModel.secondaryDecimals))")
                            .font(.inter(10.5, relativeTo: .caption).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
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
    }

    @ViewBuilder
    private var emptyHoldingsView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "briefcase")
                .font(.inter(32, relativeTo: .largeTitle))
                .foregroundColor(.secondary)
            if let p = selectedPortfolio {
                Text("No symbols in \(p.name)")
                    .foregroundColor(.secondary)
                if p.isReadOnly {
                    Button(action: { syncBinance(portfolioId: p.id) }) {
                        HStack(spacing: 4) {
                            if isSyncingBinance {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text("Sync Binance Now")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .pointingHandCursor()
                    .disabled(isSyncingBinance)
                } else {
                    Button("Add holding") {
                        addHoldingAction.perform(p.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .pointingHandCursor()
                }
            } else {
                Text("No holdings yet")
                    .foregroundColor(.secondary)
                if editablePortfolios.count == 1, let first = editablePortfolios.first {
                    Button("Add holding") {
                        addHoldingAction.perform(first.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .pointingHandCursor()
                } else if editablePortfolios.count > 1 {
                    Menu {
                        ForEach(editablePortfolios) { p in
                            Button(p.name) {
                                addHoldingAction.perform(p.id)
                            }
                        }
                    } label: {
                        Text("Add holding")
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.small)
                    .fixedSize()
                    .pointingHandCursor()
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomActionBar: some View {
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

    @ViewBuilder
    private func portfolioContextMenu(symbol: String) -> some View {
        Button {
            showSymbolDetail.perform(symbol)
        } label: {
            Label("View Details", systemImage: "chart.xyaxis.line")
        }
        Divider()

        Menu {
            ForEach(storageService.watchlists) { wl in
                Button {
                    storageService.addToWatchlist(symbol, targetWatchlistId: wl.id)
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

        if !editablePortfolios.isEmpty {
            Menu {
                ForEach(editablePortfolios) { portfolio in
                    Button(portfolio.name) {
                        addToPortfolio = (symbol, portfolio.id)
                    }
                }
            } label: {
                Label("Add to Portfolio", systemImage: "plus.rectangle.on.folder")
            }
        }
        Divider()

        Button {
            alertTarget = TargetSheetItem(symbol: symbol)
        } label: {
            Label("Set Price Alert…", systemImage: "bell")
        }

        Button {
            targetSymbol = TargetSheetItem(symbol: symbol)
        } label: {
            Label(
                storageService.buyTarget(for: symbol) != nil
                    ? LocalizedStringKey("Edit Buy Target…")
                    : LocalizedStringKey("Set Buy Target…"),
                systemImage: "target"
            )
        }
        if storageService.buyTarget(for: symbol) != nil {
            Button(role: .destructive) {
                storageService.removeBuyTarget(for: symbol)
            } label: {
                Label("Remove Buy Target", systemImage: "trash")
            }
        }

        let modifiableHoldings = (viewModel.groupedHoldings[symbol] ?? []).filter { vh in
            !(storageService.portfolios.first(where: { $0.id == vh.portfolioId })?.isReadOnly ?? false)
        }
        if !modifiableHoldings.isEmpty {
            Divider()
            if modifiableHoldings.count == 1, let first = modifiableHoldings.first {
                Button {
                    targetCloseHolding = PortfolioOverview.TargetCloseHolding(
                        portfolioId: first.portfolioId,
                        holding: first.holding,
                        quote: first.quote
                    )
                } label: {
                    Label("Sell / Close Position…", systemImage: "arrow.down.right.circle")
                }

                Button(role: .destructive) {
                    storageService.removeHolding(from: first.portfolioId, holdingId: first.holding.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } else {
                Menu {
                    ForEach(modifiableHoldings) { vh in
                        let dec = storageService.resolvedPriceDecimals(symbol: vh.symbol, price: vh.holding.avgPrice)
                        let qtyStr = StorageService.formatNumber(vh.holding.quantity, decimals: vh.holding.quantity.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2)
                        let priceStr = StorageService.formatNumber(vh.holding.avgPrice, decimals: dec)
                        Button("\(qtyStr) @ \(priceStr)") {
                            targetCloseHolding = PortfolioOverview.TargetCloseHolding(
                                portfolioId: vh.portfolioId,
                                holding: vh.holding,
                                quote: vh.quote
                            )
                        }
                    }
                } label: {
                    Label("Sell / Close Position…", systemImage: "arrow.down.right.circle")
                }

                Button(role: .destructive) {
                    for vh in modifiableHoldings {
                        storageService.removeHolding(from: vh.portfolioId, holdingId: vh.holding.id)
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
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
                                if !p.isReadOnly {
                                    Button("Add Holding…") {
                                        addHoldingAction.perform(p.id)
                                    }
                                    Divider()
                                }
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

    private var displayedPortfolios: [Portfolio] {
        if draggingPortfolioId != nil, !previewPortfolioIds.isEmpty {
            let byId = Dictionary(uniqueKeysWithValues: storageService.portfolios.map { ($0.id, $0) })
            return previewPortfolioIds.compactMap { byId[$0] }
        }
        return storageService.portfolios
    }

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

    private func createPortfolio() {
        guard !newPortfolioName.isEmpty else { return }
        storageService.addPortfolio(name: newPortfolioName)
        newPortfolioName = ""
        showNewPortfolio = false
    }
}

// MARK: - Split Row Views (Frozen Symbol + Scrollable Metrics)

private struct PortfolioFrozenRow<Menu: View>: View {
    let symbol: String
    let aggregate: PortfolioViewModel.SymbolAggregate?
    let buyTarget: StockTarget?
    let showCompanyName: Bool
    let valueDecimals: Int
    @ObservedObject var hoverBox: RowHoverBox
    let onOpen: () -> Void
    @ViewBuilder let menu: () -> Menu

    private var quote: StockQuote? { aggregate?.quote }

    private var symbolCell: some View {
        let isJpFund = StockService.isJapaneseMutualFund(symbol) || (quote?.isJapaneseFund ?? false)
        let isDisplayAsset = StockService.isDisplayNameAsset(symbol)
        let titleText = (isJpFund || isDisplayAsset) ? (quote?.displayName ?? StockService.beautifiedSymbol(symbol)) : symbol
        let subTitleText = isDisplayAsset ? symbol : (isJpFund ? "" : (quote?.name ?? ""))
        let regularPrice = quote?.price ?? aggregate?.avgPrice ?? 0
        let isBuyZone = buyTarget?.isInBuyZone(currentPrice: regularPrice) ?? false
        let toBuyTargetPercent = buyTarget?.percentDistance(from: regularPrice)
        let currSym = aggregate?.nativeCurrencySymbol ?? (quote.map { StorageService.currencySymbol(for: $0.currency) } ?? "")

        return HStack(spacing: 5) {
            SymbolLogo(symbol: symbol, size: 20)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 3) {
                    Text(titleText)
                        .font(.inter(12.5, relativeTo: .body).monospacedDigit())
                        .fontWeight(.bold)
                        .lineLimit(1)
                    UpcomingEarningsBadge(symbol: symbol)
                    if isBuyZone {
                        Text("🎯 MUA")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(DS.up)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background(DS.up.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                if let target = buyTarget {
                    let dec = valueDecimals >= 0 ? valueDecimals : StorageService.priceDecimals(symbol: symbol, price: target.targetPrice)
                    let priceStr = StorageService.formatCompactNumber(target.targetPrice, decimals: dec, stripTrailingZeros: true)
                    if isBuyZone {
                        Text("🎯 \(currSym)\(priceStr)")
                            .font(.inter(10, relativeTo: .caption2).monospacedDigit())
                            .fontWeight(.medium)
                            .foregroundStyle(DS.up)
                            .lineLimit(1)
                    } else if let dist = toBuyTargetPercent {
                        Text(String(format: "🎯 %@%@ (%+.1f%%)", currSym, priceStr, dist))
                            .font(.inter(9.5, relativeTo: .caption2).monospacedDigit())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("🎯 \(currSym)\(priceStr)")
                            .font(.inter(10, relativeTo: .caption2).monospacedDigit())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } else if showCompanyName {
                    Text(subTitleText.isEmpty ? " " : subTitleText)
                        .font(.inter(10, relativeTo: .caption2))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: PortfolioCol.symbol, alignment: .leading)
    }

    var body: some View {
        symbolCell
            .padding(.horizontal, 12)
            .frame(width: PortfolioCol.pinnedWidth, height: PortfolioCol.rowHeight, alignment: .leading)
            .background(hoverBox.isHovered ? DS.cardAlt.opacity(0.6) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture { onOpen() }
            .pointingHandCursor()
            .onHover { hoverBox.isHovered = $0 }
            .contextMenu { menu() }
    }
}

private struct PortfolioMetricsRow<Menu: View>: View {
    let stockService: StockService
    @EnvironmentObject var storageService: StorageService
    let symbol: String
    let aggregate: PortfolioViewModel.SymbolAggregate
    let weight: Double
    let columns: [PortfolioColumnMetric]
    @ObservedObject var hoverBox: RowHoverBox
    let onOpen: () -> Void
    @ViewBuilder let menu: () -> Menu

    private var quote: StockQuote? { aggregate.quote }

    private var priceRate: Double {
        guard let q = quote else { return 1.0 }
        return stockService.priceRate(from: q.currency)
    }

    private var metricFont: Font { .inter(11.5, relativeTo: .body).monospacedDigit() }
    private var metricSubFont: Font { .inter(10.5, relativeTo: .caption).monospacedDigit() }
    private var metricCaption2Font: Font { .inter(10, relativeTo: .caption2).monospacedDigit() }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { col in
                metricCell(for: col)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: PortfolioCol.rowHeight, alignment: .leading)
        .background(hoverBox.isHovered ? DS.cardAlt.opacity(0.6) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
        .pointingHandCursor()
        .onHover { hoverBox.isHovered = $0 }
        .contextMenu { menu() }
    }

    @ViewBuilder
    private func metricCell(for col: PortfolioColumnMetric) -> some View {
        switch col {
        case .avgPrice:
            let avgPrice = aggregate.hasCostBasis ? aggregate.avgPrice : 0
            Text(aggregate.hasCostBasis ? StorageService.formatCompactNumber(avgPrice, decimals: storageService.resolvedPriceDecimals(symbol: symbol, price: avgPrice)) : "—")
                .font(metricFont)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: PortfolioCol.avgPrice, alignment: .trailing)

        case .cost:
            if aggregate.hasCostBasis {
                Text(StorageService.formatCompactAmount(
                    aggregate.nativeCost,
                    symbol: aggregate.nativeCurrencySymbol,
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
            Text(StorageService.formatCompactAmount(
                aggregate.nativeValue,
                symbol: aggregate.nativeCurrencySymbol,
                signed: false,
                decimals: storageService.amountDecimals
            ))
            .font(metricFont)
            .fontWeight(.medium)
            .foregroundColor(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(width: PortfolioCol.value, alignment: .trailing)

        case .totalPnl:
            VStack(alignment: .trailing, spacing: 1) {
                if aggregate.hasCostBasis {
                    Text(StorageService.formatCompactAmount(aggregate.nativePnl, symbol: aggregate.nativeCurrencySymbol, signed: true, decimals: storageService.amountDecimals))
                        .font(metricFont)
                        .fontWeight(.medium)
                        .foregroundColor(aggregate.nativePnl >= 0 ? DS.up : DS.down)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(String(format: "%+.\(storageService.percentDecimals)f%%", aggregate.nativePnlPercent))
                        .font(metricCaption2Font)
                        .fontWeight(.semibold)
                        .foregroundColor(aggregate.nativePnlPercent >= 0 ? DS.up : DS.down)
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
            Text(StorageService.formatCompactAmount(
                aggregate.todayPnl,
                symbol: aggregate.nativeCurrencySymbol,
                signed: true,
                decimals: storageService.amountDecimals
            ))
            .font(metricFont)
            .fontWeight(.medium)
            .foregroundColor(aggregate.todayPnl > 0 ? DS.up : (aggregate.todayPnl < 0 ? DS.down : DS.inkTertiary))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: PortfolioCol.todayPnl, alignment: .trailing)

        case .shares:
            let qty = aggregate.totalQuantity
            let qtyDecimals = qty.truncatingRemainder(dividingBy: 1) == 0 ? 0 : (abs(qty) < 1 ? 4 : 2)
            Text(StorageService.formatNumber(qty, decimals: qtyDecimals))
                .font(metricFont)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: PortfolioCol.shares, alignment: .trailing)

        case .lots:
            Text("\(aggregate.lotsCount)")
                .font(metricFont)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(1)
                .frame(width: PortfolioCol.lots, alignment: .trailing)

        case .weight:
            Text(String(format: "%.1f%%", weight))
                .font(metricFont)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: PortfolioCol.weight, alignment: .trailing)

        case .marketCap:
            if let mc = quote?.marketCap, mc > 0 {
                Text(StorageService.formatMarketCap(mc, currency: quote?.currency ?? ""))
                    .font(metricFont)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: PortfolioCol.marketCap, alignment: .trailing)
            } else {
                Text("—")
                    .font(metricFont)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .frame(width: PortfolioCol.marketCap, alignment: .trailing)
            }

        case .pe:
            valuationText(quote?.trailingPE, isPercent: false)

        case .forwardPe:
            valuationText(quote?.forwardPE, isPercent: false)

        case .pb:
            valuationText(quote?.priceToBook, isPercent: false)

        case .divYield:
            valuationText(quote?.dividendYield, isPercent: true)

        case .eps:
            if let eps = quote?.epsTrailingTwelveMonths, eps.isFinite {
                let sym = StorageService.currencySymbol(for: quote?.currency ?? "")
                let dec = (quote?.currency == "VND" || quote?.currency == "JPY") ? 0 : 2
                Text(StorageService.formatCompactAmount(eps, symbol: sym, signed: false, decimals: dec))
                    .font(metricFont)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: PortfolioCol.valuation, alignment: .trailing)
            } else {
                Text("—")
                    .font(metricFont)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .frame(width: PortfolioCol.valuation, alignment: .trailing)
            }

        case .volume50d:
            VolumeSparkline(symbol: symbol, mode: .days50)
                .frame(width: PortfolioCol.volume, alignment: .trailing)

        case .volume50w:
            VolumeSparkline(symbol: symbol, mode: .weeks50)
                .frame(width: PortfolioCol.volume, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func valuationText(_ value: Double?, isPercent: Bool) -> some View {
        if let value, value.isFinite, (isPercent ? value >= 0 : value > 0) {
            let str = isPercent ? "\(StorageService.formatNumber(value, decimals: 2))%" : StorageService.formatNumber(value, decimals: 2)
            Text(str)
                .font(metricFont)
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: PortfolioCol.valuation, alignment: .trailing)
        } else {
            Text("—")
                .font(metricFont)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .frame(width: PortfolioCol.valuation, alignment: .trailing)
        }
    }
}
