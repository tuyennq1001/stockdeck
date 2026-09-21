import SwiftUI
import Charts

/// Per-holding detail reached from the positions table. Same page scaffold as
/// every tab (symbol + company in the fixed header), then: hero with the live
/// price and the real Yahoo price history chart, stat strip, 52-week range with
/// the purchase-price tick, and a position facts card.
struct HoldingDetailView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @Environment(\.addHoldingAction) private var addHoldingAction
    @Environment(\.editHoldingAction) private var editHoldingAction
    let portfolioId: UUID
    let scope: PortfolioScope
    let holding: Holding
    let quote: StockQuote

    struct TargetCloseLot: Identifiable {
        let id = UUID()
        let portfolioId: UUID
        let holding: Holding
    }

    @State private var showAlert = false
    @State private var confirmDeleteLot: ValuedHolding? = nil
    @State private var targetCloseLot: TargetCloseLot? = nil
    @State private var selectedNewsArticle: NewsArticle? = nil
    @State private var expandedClosedTradeIds: Set<String> = []
    @State private var expandedTxIds: Set<String> = []

    private var currencySymbol: String {
        StorageService.currencySymbol(for: storageService.preferredCurrency)
    }
    private var priceSymbol: String {
        let isIndex = StorageService.isIndex(symbol: quote.symbol, type: storageService.type(for: quote.symbol))
        return isIndex ? "" : StorageService.currencySymbol(for: quote.currency)
    }
    private var scopedPortfolios: [Portfolio] {
        switch scope {
        case .all:
            return storageService.portfolios
        case .portfolio(let id):
            return storageService.portfolios.filter { $0.id == id }
        }
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let article = selectedNewsArticle {
                NewsDetailView(
                    article: article,
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedNewsArticle = nil
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            } else {
                holdingContent
            }
        }
    }

    private var holdingContent: some View {
        let isJpFund = quote.isJapaneseFund || stockService.isJapaneseMutualFund(holding.symbol)
        let isDisplayAsset = StockService.isDisplayNameAsset(holding.symbol)
        let mainTitle = (isJpFund || isDisplayAsset) ? quote.displayName : holding.symbol
        let subTitle = isDisplayAsset ? holding.symbol : (isJpFund ? "" : quote.name)

        return PageScaffold(mainTitle, caption: subTitle, symbol: holding.symbol, onBack: { dismiss() }) {
            HStack(spacing: 10) {
                if holding.isShort { Tag(text: "SHORT", color: DS.down) }
                if holding.effectiveLeverage != 1 {
                    Tag(text: "\(StorageService.formatNumber(holding.effectiveLeverage, decimals: holding.effectiveLeverage == holding.effectiveLeverage.rounded() ? 0 : 1))×",
                        color: DS.brand)
                }
                if isEditableScope && !isPortfolioReadOnly {
                    Button { editHoldingAction.perform(portfolioId, holding) } label: {
                        Image(systemName: "pencil").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.inkSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Edit this holding")
                }
                Button { showAlert = true } label: {
                    Image(systemName: "bell").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.inkSecondary)
                }
                .buttonStyle(.plain)
                .help("Set a price alert")
                RefreshButton(isLoading: stockService.isLoading) {
                    Task { await stockService.refreshAll(storageService: storageService) }
                }
            }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.gap) {
                    PriceChartCard(symbol: holding.symbol, quote: quote)
                    statStrip
                    purchaseLotsCard
                    closedTradesForSymbolCard
                    transactionsForSymbolCard
                    if storageService.show52WeekBar { fiftyTwoWeekCard.frame(maxWidth: .infinity) }
                    InsiderTradingCard(symbol: holding.symbol)
                    SymbolNotesCard(storageService: storageService, symbol: holding.symbol)
                    SymbolNewsCard(
                        stockService: stockService,
                        symbol: holding.symbol,
                        onSelectArticle: { article in
                            withAnimation(.easeInOut(duration: 0.18)) {
                                selectedNewsArticle = article
                            }
                        }
                    )
                }
                .pageColumn()
                .padding(.top, 4)
            }
        }
        .navigationTitle(mainTitle)
        .sheet(item: $targetCloseLot) { target in
            CloseHoldingSheet(
                portfolioId: target.portfolioId,
                holding: target.holding,
                quote: quote,
                onDismiss: { targetCloseLot = nil }
            )
            .environmentObject(storageService)
            .environmentObject(stockService)
        }
        .sheet(isPresented: $showAlert) {
            PriceAlertSheet(symbol: holding.symbol) { showAlert = false }
                .environmentObject(stockService).environmentObject(storageService)
        }
        .alert("Delete Purchase Lot", isPresented: Binding(get: { confirmDeleteLot != nil }, set: { if !$0 { confirmDeleteLot = nil } })) {
            Button("Cancel", role: .cancel) { confirmDeleteLot = nil }
            Button("Delete", role: .destructive) {
                if let target = confirmDeleteLot {
                    let isLastLot = allHoldingsForSymbol.count <= 1
                    storageService.removeHolding(from: target.portfolioId, holdingId: target.holding.id)
                    if isLastLot {
                        dismiss()
                    }
                }
                confirmDeleteLot = nil
            }
        } message: {
            if let target = confirmDeleteLot {
                let dateStr = target.holding.purchaseDate.map { Self.dateFormatter.string(from: $0) } ?? "no date"
                let qtyStr = formatQty(target.holding.quantity)
                Text("Are you sure you want to delete this lot of \(qtyStr) shares (\(dateStr))? This action cannot be undone.")
            }
        }
    }


    // MARK: - Purchase Lots

    private var isEditableScope: Bool {
        if case .portfolio = scope { return true }
        return false
    }

    /// Read-only (Binance) portfolios can't be edited or deleted manually — the
    /// Edit/Delete buttons are hidden because their update/remove paths are
    /// no-ops for read-only holdings.
    private var isPortfolioReadOnly: Bool {
        storageService.portfolios.first(where: { $0.id == portfolioId })?.isReadOnly ?? false
    }

    private var showsPortfolioColumn: Bool {
        if case .all = scope { return true }
        return false
    }

    private func portfolioName(for id: UUID) -> String {
        storageService.portfolios.first { $0.id == id }?.name ?? "—"
    }

    private var allHoldingsForSymbol: [ValuedHolding] {
        let matched = scopedPortfolios.flatMap { p in
            p.holdings.filter { StockService.canonicalSymbol(for: $0.symbol) == StockService.canonicalSymbol(for: holding.symbol) }.map { h in
                let price = quote.displayPrice(extendedHours: storageService.showExtendedHours)
                let val = h.marketValue(currentPrice: price)
                let cst = h.costBasisLocal
                return ValuedHolding(id: h.id, portfolioId: p.id, holding: h, quote: quote,
                                     value: val, cost: cst, dayChangePercent: quote.changePercent,
                                     type: storageService.type(for: h.symbol))
            }
        }
        // Purchase lots, newest purchase date first; lots without a date last.
        return matched.sorted { lhs, rhs in
            switch (lhs.holding.purchaseDate, rhs.holding.purchaseDate) {
            case let (l?, r?): return l > r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return false
            }
        }
    }

    private var aggregatedHoldings: [Holding] {
        allHoldingsForSymbol.map(\.holding)
    }

    /// True when at least one lot has no known cost basis (e.g. Binance balances
    /// without order history). While market value is still real, the average
    /// price, cost basis, and P&L are unknowable — we show "—" instead of
    /// fabricating numbers.
    private var hasAnyMissingCostBasis: Bool {
        allHoldingsForSymbol.contains { !$0.holding.hasKnownCostBasis }
    }

    private var totalQuantity: Double {
        HoldingLotAggregation.totalQuantity(aggregatedHoldings)
    }

    private var weightedAveragePrice: Double {
        HoldingLotAggregation.weightedAveragePrice(aggregatedHoldings)
    }

    private var aggregatedValue: Double {
        allHoldingsForSymbol.reduce(0) { $0 + $1.value }
    }

    private var aggregatedCost: Double {
        allHoldingsForSymbol.reduce(0) { $0 + $1.cost }
    }

    /// P&L only counts lots WITH a known cost basis. A Binance balance without
    /// order history has cost 0, so `value - cost` would report the entire
    /// market value as profit.
    private var aggregatedPnl: Double {
        allHoldingsForSymbol.reduce(0) { $1.holding.hasKnownCostBasis ? $0 + $1.pnl : $0 }
    }

    private var aggregatedPnlPercent: Double {
        abs(aggregatedCost) >= 0.01 ? (aggregatedPnl / abs(aggregatedCost)) * 100 : 0
    }

    private var scopedPortfolioValue: Double {
        scopedPortfolios.flatMap(\.holdings).reduce(0) { sum, item in
            guard let itemQuote = stockService.quotes[item.symbol] else { return sum }
            let price = itemQuote.displayPrice(extendedHours: storageService.showExtendedHours)
            let curr = stockService.detectedCurrency(for: item.symbol)
            return sum + item.marketValue(currentPrice: price) * stockService.rate(from: curr)
        }
    }

    private var aggregatedValueInPreferredCurrency: Double {
        let price = quote.displayPrice(extendedHours: storageService.showExtendedHours)
        let curr = stockService.detectedCurrency(for: holding.symbol)
        let rate = stockService.rate(from: curr)
        return aggregatedHoldings.reduce(0) { $0 + $1.marketValue(currentPrice: price) } * rate
    }

    private var aggregatedWeight: Double {
        abs(scopedPortfolioValue) >= 0.01
            ? abs(aggregatedValueInPreferredCurrency) / abs(scopedPortfolioValue) * 100
            : 0
    }

    private var purchaseLotsCard: some View {
        Card(title: "Purchase Lots (\(allHoldingsForSymbol.count))") {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Date").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(width: 90, alignment: .leading)
                    if showsPortfolioColumn {
                        Text("Portfolio").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(width: 130, alignment: .leading)
                    }
                    Text("Qty").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(width: 60, alignment: .trailing)
                    Text("Cost / sh").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(maxWidth: .infinity, alignment: .trailing)
                    Text("Value").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(maxWidth: .infinity, alignment: .trailing)
                    Text("PnL").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(maxWidth: .infinity, alignment: .trailing)
                    if isEditableScope && !isPortfolioReadOnly {
                        Text("Actions").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(width: 75, alignment: .trailing)
                    }
                }
                .padding(.bottom, 8)
                Divider().overlay(DS.hairline)

                ForEach(allHoldingsForSymbol) { vh in
                    HStack(spacing: 0) {
                        Text(vh.holding.purchaseDate.map { Self.dateFormatter.string(from: $0) } ?? "—")
                            .font(DS.caption)
                            .foregroundStyle(DS.ink)
                            .frame(width: 90, alignment: .leading)

                        if showsPortfolioColumn {
                            Text(portfolioName(for: vh.portfolioId))
                                .font(DS.caption)
                                .foregroundStyle(DS.inkSecondary)
                                .lineLimit(1)
                                .help(portfolioName(for: vh.portfolioId))
                                .frame(width: 130, alignment: .leading)
                        }

                        Text("\(formatQty(vh.holding.quantity))")
                            .font(DS.figure)
                            .foregroundStyle(DS.ink)
                            .frame(width: 60, alignment: .trailing)

                        Group {
                            if vh.holding.hasKnownCostBasis {
                                Text(StorageService.formatAmount(vh.holding.avgPrice, symbol: priceSymbol, decimals: storageService.amountDecimals))
                            } else {
                                Text("—")
                            }
                        }
                        .font(DS.figure)
                        .foregroundStyle(DS.ink)
                        .frame(maxWidth: .infinity, alignment: .trailing)

                        Text(StorageService.formatAmount(vh.value, symbol: priceSymbol, decimals: storageService.amountDecimals))
                            .font(DS.figure)
                            .foregroundStyle(DS.ink)
                            .frame(maxWidth: .infinity, alignment: .trailing)

                        Group {
                            if vh.holding.hasKnownCostBasis {
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(StorageService.formatAmount(vh.pnl, symbol: priceSymbol, decimals: storageService.amountDecimals, signed: true))
                                        .font(DS.figure)
                                        .foregroundStyle(DS.pnlColor(vh.pnl))
                                    ChangePill(
                                        value: vh.pnlPercent,
                                        text: String(format: "%+.\(storageService.percentDecimals)f%%", vh.pnlPercent)
                                    )
                                }
                            } else {
                                Text("—")
                                    .font(DS.figure)
                                    .foregroundStyle(DS.inkTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)

                        if isEditableScope && !isPortfolioReadOnly {
                            HStack(spacing: 6) {
                                Button {
                                    targetCloseLot = TargetCloseLot(portfolioId: vh.portfolioId, holding: vh.holding)
                                } label: {
                                    Image(systemName: "arrow.down.right.circle")
                                        .font(.system(size: 11))
                                        .foregroundStyle(DS.brand)
                                }
                                .buttonStyle(.plain)
                                .pointingHandCursor()
                                .help("Sell / Close lot")

                                Button {
                                    editHoldingAction.perform(vh.portfolioId, vh.holding)
                                } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 11))
                                        .foregroundStyle(DS.inkSecondary)
                                }
                                .buttonStyle(.plain)
                                .pointingHandCursor()
                                .help("Edit lot")

                                Button {
                                    confirmDeleteLot = vh
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundStyle(DS.down)
                                }
                                .buttonStyle(.plain)
                                .pointingHandCursor()
                                .help("Delete lot")
                            }
                            .frame(width: 75, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 8)
                    if vh.id != allHoldingsForSymbol.last?.id {
                        Divider().overlay(DS.hairline.opacity(0.6)).padding(.horizontal, 4)
                    }
                }

                if isEditableScope && !isPortfolioReadOnly {
                    Divider().overlay(DS.hairline).padding(.top, 4)
                    Button(action: {
                        addHoldingAction.perform(portfolioId, holding.symbol)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle")
                            Text("Add another lot for \(holding.symbol)")
                        }
                        .font(.inter(11, weight: .semibold, relativeTo: .caption))
                        .foregroundStyle(DS.brand)
                        .padding(.top, 8)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
            }
        }
    }

    private var rawSymbolClosedTrades: [ClosedTrade] {
        scopedPortfolios.flatMap(\.closedTrades).filter {
            StockService.canonicalSymbol(for: $0.symbol) == StockService.canonicalSymbol(for: holding.symbol)
        }.sorted { ($0.sellDate ?? .distantPast) > ($1.sellDate ?? .distantPast) }
    }

    private var symbolClosedTrades: [ConsolidatedClosedTrade] {
        ConsolidatedClosedTrade.consolidate(trades: rawSymbolClosedTrades)
            .sorted { ($0.sellDate ?? .distantPast) > ($1.sellDate ?? .distantPast) }
    }

    private var closedTradesForSymbolCard: some View {
        Group {
            if !symbolClosedTrades.isEmpty {
                Card(title: "Closed Trades History (\(symbolClosedTrades.count))") {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Text("Sell Date").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(width: 105, alignment: .leading)
                            Text("Account").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(width: 80, alignment: .leading)
                            Text("Qty").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(width: 55, alignment: .trailing)
                            Text("Buy Price").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(maxWidth: .infinity, alignment: .trailing)
                            Text("Invested").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(maxWidth: .infinity, alignment: .trailing)
                            Text("Sell Price").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(maxWidth: .infinity, alignment: .trailing)
                            Text("Realized PnL").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(.bottom, 8)
                        Divider().overlay(DS.hairline)

                        ForEach(symbolClosedTrades) { trade in
                            let isExpanded = expandedClosedTradeIds.contains(trade.id)
                            VStack(spacing: 0) {
                                HStack(spacing: 0) {
                                    HStack(spacing: 4) {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(trade.sellDate.map { Self.dateFormatter.string(from: $0) } ?? "—")
                                                .font(DS.caption)
                                                .foregroundStyle(DS.ink)
                                            if let days = trade.holdingPeriodDays {
                                                Text("\(days)d held")
                                                    .font(DS.micro)
                                                    .foregroundStyle(DS.inkTertiary)
                                            }
                                        }

                                        if trade.lots.count > 1 {
                                            Button {
                                                withAnimation(.easeInOut(duration: 0.15)) {
                                                    if isExpanded {
                                                        expandedClosedTradeIds.remove(trade.id)
                                                    } else {
                                                        expandedClosedTradeIds.insert(trade.id)
                                                    }
                                                }
                                            } label: {
                                                HStack(spacing: 2) {
                                                    Text("\(trade.lots.count) lots")
                                                        .font(.system(size: 9, weight: .bold))
                                                        .foregroundStyle(DS.brand)
                                                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                                        .font(.system(size: 8, weight: .bold))
                                                        .foregroundStyle(DS.brand)
                                                }
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1.5)
                                                .background(DS.brand.opacity(0.1))
                                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                            }
                                            .buttonStyle(.plain)
                                            .pointingHandCursor()
                                        }
                                    }
                                    .frame(width: 105, alignment: .leading)

                                    Text(trade.account ?? "—")
                                        .font(DS.caption)
                                        .foregroundStyle(DS.inkSecondary)
                                        .lineLimit(1)
                                        .frame(width: 80, alignment: .leading)

                                    Text("\(formatQty(trade.quantity))")
                                        .font(DS.figure)
                                        .foregroundStyle(DS.ink)
                                        .frame(width: 55, alignment: .trailing)

                                    Text(trade.buyPrice > 0 ? StorageService.formatAmount(trade.buyPrice, symbol: priceSymbol, decimals: storageService.amountDecimals) : "—")
                                        .font(DS.figure)
                                        .foregroundStyle(DS.inkSecondary)
                                        .frame(maxWidth: .infinity, alignment: .trailing)

                                    Text(trade.costBasis > 0 ? StorageService.formatAmount(trade.costBasis, symbol: priceSymbol, decimals: storageService.amountDecimals) : "—")
                                        .font(DS.figure)
                                        .foregroundStyle(DS.inkSecondary)
                                        .frame(maxWidth: .infinity, alignment: .trailing)

                                    Text(StorageService.formatAmount(trade.sellPrice, symbol: priceSymbol, decimals: storageService.amountDecimals))
                                        .font(DS.figure)
                                        .foregroundStyle(DS.ink)
                                        .frame(maxWidth: .infinity, alignment: .trailing)

                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text(StorageService.formatAmount(trade.realizedPnl, symbol: priceSymbol, decimals: storageService.amountDecimals, signed: true))
                                            .font(DS.figure)
                                            .foregroundStyle(DS.pnlColor(trade.realizedPnl))
                                        ChangePill(
                                            value: trade.realizedPnlPercent,
                                            text: String(format: "%+.\(storageService.percentDecimals)f%%", trade.realizedPnlPercent)
                                        )
                                    }
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                                .padding(.vertical, 8)

                                if isExpanded && trade.lots.count > 1 {
                                    VStack(spacing: 2) {
                                        ForEach(trade.lots) { lot in
                                            HStack(spacing: 0) {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "arrow.turn.down.right")
                                                        .font(.system(size: 9))
                                                        .foregroundStyle(DS.inkTertiary)
                                                    Text(lot.buyDate.map { "Bought " + Self.dateFormatter.string(from: $0) } ?? "Lot")
                                                        .font(DS.micro)
                                                        .foregroundStyle(DS.inkSecondary)
                                                        .lineLimit(1)
                                                }
                                                .padding(.leading, 12)
                                                .frame(width: 105, alignment: .leading)

                                                Text(lot.account ?? "—")
                                                    .font(DS.micro)
                                                    .foregroundStyle(DS.inkSecondary)
                                                    .lineLimit(1)
                                                    .frame(width: 80, alignment: .leading)

                                                Text("\(formatQty(lot.quantity))")
                                                    .font(DS.micro)
                                                    .foregroundStyle(DS.inkSecondary)
                                                    .frame(width: 55, alignment: .trailing)

                                                Text(lot.buyPrice > 0 ? StorageService.formatAmount(lot.buyPrice, symbol: priceSymbol, decimals: storageService.amountDecimals) : "—")
                                                    .font(DS.micro)
                                                    .foregroundStyle(DS.inkSecondary)
                                                    .frame(maxWidth: .infinity, alignment: .trailing)

                                                Text(lot.costBasis > 0 ? StorageService.formatAmount(lot.costBasis, symbol: priceSymbol, decimals: storageService.amountDecimals) : "—")
                                                    .font(DS.micro)
                                                    .foregroundStyle(DS.inkSecondary)
                                                    .frame(maxWidth: .infinity, alignment: .trailing)

                                                Text(StorageService.formatAmount(lot.sellPrice, symbol: priceSymbol, decimals: storageService.amountDecimals))
                                                    .font(DS.micro)
                                                    .foregroundStyle(DS.inkSecondary)
                                                    .frame(maxWidth: .infinity, alignment: .trailing)

                                                VStack(alignment: .trailing, spacing: 1) {
                                                    Text(StorageService.formatAmount(lot.realizedPnl, symbol: priceSymbol, decimals: storageService.amountDecimals, signed: true))
                                                        .font(DS.micro)
                                                        .foregroundStyle(DS.pnlColor(lot.realizedPnl))
                                                    Text(String(format: "%+.\(storageService.percentDecimals)f%%", lot.realizedPnlPercent))
                                                        .font(.system(size: 9, weight: .medium))
                                                        .foregroundStyle(DS.pnlColor(lot.realizedPnl))
                                                }
                                                .frame(maxWidth: .infinity, alignment: .trailing)
                                            }
                                            .padding(.vertical, 4)
                                            .background(DS.cardAlt.opacity(0.45))
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                        }
                                    }
                                    .padding(.vertical, 3)
                                }
                            }

                            if trade.id != symbolClosedTrades.last?.id {
                                Divider().overlay(DS.hairline.opacity(0.6)).padding(.horizontal, 4)
                            }
                        }
                    }
                }
            }
        }
    }

    private var rawSymbolTransactions: [Transaction] {
        scopedPortfolios.flatMap(\.transactions).filter {
            StockService.canonicalSymbol(for: $0.symbol) == StockService.canonicalSymbol(for: holding.symbol)
        }.sorted { $0.date > $1.date }
    }

    private var symbolTransactions: [ConsolidatedTransaction] {
        ConsolidatedTransaction.consolidate(transactions: rawSymbolTransactions)
            .sorted { $0.date > $1.date }
    }

    private var transactionsForSymbolCard: some View {
        Group {
            if !symbolTransactions.isEmpty {
                Card(title: "Transaction History (\(symbolTransactions.count))") {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            Text("Date").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(width: 80, alignment: .leading)
                            Text("Type").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(width: 90, alignment: .leading)
                            Text("Account").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(width: 70, alignment: .leading)
                            Text("Qty").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(width: 60, alignment: .trailing)
                            Text("Price").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(maxWidth: .infinity, alignment: .trailing)
                            Text("Amount").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .padding(.bottom, 8)
                        Divider().overlay(DS.hairline)

                        ForEach(symbolTransactions) { tx in
                            let isExpanded = expandedTxIds.contains(tx.id)
                            VStack(spacing: 0) {
                                HStack(spacing: 0) {
                                    Text(Self.dateFormatter.string(from: tx.date))
                                        .font(DS.caption)
                                        .foregroundStyle(DS.ink)
                                        .frame(width: 80, alignment: .leading)

                                    HStack(spacing: 4) {
                                        Text(tx.type.displayName)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(tx.type == .buy ? DS.up : (tx.type == .sell ? DS.down : DS.brand))
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1.5)
                                            .background((tx.type == .buy ? DS.up : (tx.type == .sell ? DS.down : DS.brand)).opacity(0.12))
                                            .clipShape(RoundedRectangle(cornerRadius: 3))

                                        if tx.transactions.count > 1 {
                                            Button {
                                                withAnimation(.easeInOut(duration: 0.15)) {
                                                    if isExpanded {
                                                        expandedTxIds.remove(tx.id)
                                                    } else {
                                                        expandedTxIds.insert(tx.id)
                                                    }
                                                }
                                            } label: {
                                                HStack(spacing: 2) {
                                                    Text("\(tx.transactions.count) fills")
                                                        .font(.system(size: 8, weight: .bold))
                                                        .foregroundStyle(DS.brand)
                                                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                                        .font(.system(size: 7, weight: .bold))
                                                        .foregroundStyle(DS.brand)
                                                }
                                                .padding(.horizontal, 3)
                                                .padding(.vertical, 1)
                                                .background(DS.brand.opacity(0.1))
                                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                            }
                                            .buttonStyle(.plain)
                                            .pointingHandCursor()
                                        }
                                    }
                                    .frame(width: 90, alignment: .leading)

                                    Text(tx.account ?? "—")
                                        .font(DS.caption)
                                        .foregroundStyle(DS.inkSecondary)
                                        .frame(width: 70, alignment: .leading)

                                    Text("\(formatQty(tx.quantity))")
                                        .font(DS.figure)
                                        .foregroundStyle(DS.ink)
                                        .frame(width: 60, alignment: .trailing)

                                    Text(StorageService.formatAmount(tx.price, symbol: priceSymbol, decimals: storageService.amountDecimals))
                                        .font(DS.figure)
                                        .foregroundStyle(DS.inkSecondary)
                                        .frame(maxWidth: .infinity, alignment: .trailing)

                                    Text(StorageService.formatAmount(tx.effectiveAmount, symbol: priceSymbol, decimals: storageService.amountDecimals))
                                        .font(DS.figure)
                                        .foregroundStyle(DS.ink)
                                        .frame(maxWidth: .infinity, alignment: .trailing)
                                }
                                .padding(.vertical, 7)

                                if isExpanded && tx.transactions.count > 1 {
                                    VStack(spacing: 2) {
                                        ForEach(Array(tx.transactions.enumerated()), id: \.element.id) { index, subTx in
                                            HStack(spacing: 0) {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "arrow.turn.down.right")
                                                        .font(.system(size: 9))
                                                        .foregroundStyle(DS.inkTertiary)
                                                    Text("Fill #\(index + 1)")
                                                        .font(DS.micro)
                                                        .foregroundStyle(DS.inkSecondary)
                                                }
                                                .padding(.leading, 12)
                                                .frame(width: 80, alignment: .leading)

                                                Spacer().frame(width: 90)

                                                Text(subTx.account ?? "—")
                                                    .font(DS.micro)
                                                    .foregroundStyle(DS.inkSecondary)
                                                    .frame(width: 70, alignment: .leading)

                                                Text("\(formatQty(subTx.quantity))")
                                                    .font(DS.micro)
                                                    .foregroundStyle(DS.inkSecondary)
                                                    .frame(width: 60, alignment: .trailing)

                                                Text(StorageService.formatAmount(subTx.price, symbol: priceSymbol, decimals: storageService.amountDecimals))
                                                    .font(DS.micro)
                                                    .foregroundStyle(DS.inkSecondary)
                                                    .frame(maxWidth: .infinity, alignment: .trailing)

                                                Text(StorageService.formatAmount(subTx.effectiveAmount, symbol: priceSymbol, decimals: storageService.amountDecimals))
                                                    .font(DS.micro)
                                                    .foregroundStyle(DS.inkSecondary)
                                                    .frame(maxWidth: .infinity, alignment: .trailing)
                                            }
                                            .padding(.vertical, 4)
                                            .background(DS.cardAlt.opacity(0.45))
                                            .clipShape(RoundedRectangle(cornerRadius: 3))
                                        }
                                    }
                                    .padding(.vertical, 3)
                                }
                            }

                            if tx.id != symbolTransactions.last?.id {
                                Divider().overlay(DS.hairline.opacity(0.6)).padding(.horizontal, 4)
                            }
                        }
                    }
                }
            }
        }
    }


    // MARK: - Stats

    private var statStrip: some View {
        HStack(spacing: 10) {
            StatTile(label: "Position", value: "\(formatQty(totalQuantity)) sh", help: "Shares across all purchase lots shown below")
            StatTile(label: "Avg price",
                     value: hasAnyMissingCostBasis || !weightedAveragePrice.isFinite
                        ? "—"
                        : StorageService.formatAmount(weightedAveragePrice, symbol: priceSymbol, decimals: storageService.amountDecimals),
                     help: "Quantity-weighted average price. Shown as — when a lot has no known cost basis.")
            StatTile(label: "Cost",
                     value: hasAnyMissingCostBasis
                        ? "—"
                        : StorageService.formatAmount(aggregatedCost, symbol: priceSymbol, decimals: storageService.amountDecimals),
                     help: "Total cost basis across all purchase lots. Shown as — when a lot has no known cost basis.")
            StatTile(label: "Value", value: StorageService.formatAmount(aggregatedValue, symbol: priceSymbol, decimals: storageService.amountDecimals), help: "Current market value across all purchase lots")
            StatTile(label: "PnL",
                     value: hasAnyMissingCostBasis
                        ? "—"
                        : StorageService.formatAmount(aggregatedPnl, symbol: priceSymbol, decimals: storageService.amountDecimals, signed: true),
                     caption: hasAnyMissingCostBasis ? nil : String(format: "%+.\(storageService.percentDecimals)f%%", aggregatedPnlPercent),
                     captionTint: DS.pnlColor(aggregatedPnl), valueTint: DS.pnlColor(aggregatedPnl))
            StatTile(label: "Weight", value: String(format: "%.1f%%", aggregatedWeight), help: "Share of the selected portfolio scope")
        }
    }

    // MARK: - 52-week range

    @ViewBuilder private var fiftyTwoWeekCard: some View {
        if let pos = quote.fiftyTwoWeekPosition,
           let low = quote.fiftyTwoWeekLow, let high = quote.fiftyTwoWeekHigh {
            Card(title: "52-week range") {
                VStack(spacing: 10) {
                    GeometryReader { geo in
                        let x = CGFloat(pos) * (geo.size.width - 10)
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.cardAlt).frame(height: 6)
                            // Tick where the average purchase price sits ("you bought here").
                            if high > low {
                                let buyPos = min(max((weightedAveragePrice - low) / (high - low), 0), 1)
                                Rectangle().fill(DS.inkTertiary)
                                    .frame(width: 1.5, height: 12)
                                    .offset(x: CGFloat(buyPos) * (geo.size.width - 10) + 4)
                                    .help("Your average cost")
                            }
                            Circle()
                                .fill(.white)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().strokeBorder(DS.brand, lineWidth: 2))
                                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                                .offset(x: x)
                        }
                        .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 16)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            SectionLabel("Low")
                            Text(StorageService.formatAmount(low, symbol: priceSymbol))
                                .font(DS.figure).foregroundStyle(DS.ink)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            SectionLabel("High")
                            Text(StorageService.formatAmount(high, symbol: priceSymbol))
                                .font(DS.figure).foregroundStyle(DS.ink)
                        }
                    }
                }
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f
    }()

    private func formatQty(_ qty: Double) -> String {
        qty == qty.rounded(.down) ? String(format: "%.0f", qty) : String(format: "%.2f", qty)
    }
}
