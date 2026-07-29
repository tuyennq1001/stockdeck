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
    let scope: PortfolioWindowView.Scope
    let holding: Holding
    let quote: StockQuote

    @State private var showAlert = false

    private var currencySymbol: String {
        StorageService.currencySymbol(for: storageService.preferredCurrency)
    }
    private var priceSymbol: String {
        StorageService.currencySymbol(for: quote.currency)
    }
    private var scopedPortfolios: [Portfolio] {
        switch scope {
        case .all:
            return storageService.portfolios
        case .portfolio(let id):
            return storageService.portfolios.filter { $0.id == id }
        }
    }

    private var relatedNews: [NewsArticle] {
        stockService.news.filter {
            $0.sourceSymbol == holding.symbol || $0.relatedTickers.contains(holding.symbol)
        }
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PageScaffold(holding.symbol, caption: quote.name, symbol: holding.symbol) {
            HStack(spacing: 10) {
                if holding.isShort { Tag(text: "SHORT", color: DS.down) }
                if holding.effectiveLeverage != 1 {
                    Tag(text: "\(StorageService.formatNumber(holding.effectiveLeverage, decimals: holding.effectiveLeverage == holding.effectiveLeverage.rounded() ? 0 : 1))×",
                        color: DS.brand)
                }
                Button { editHoldingAction.perform(portfolioId, holding) } label: {
                    Image(systemName: "pencil").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.inkSecondary)
                }
                .buttonStyle(.plain)
                .help("Edit this holding")
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
                    fiftyTwoWeekCard.frame(maxWidth: .infinity)
                    if !relatedNews.isEmpty { newsCard }
                }
                .pageColumn()
                .padding(.top, 4)
            }
        }
        .navigationTitle(holding.symbol)
        .sheet(isPresented: $showAlert) {
            PriceAlertSheet(symbol: holding.symbol) { showAlert = false }
                .environmentObject(stockService).environmentObject(storageService)
        }
    }

    // MARK: - Related news

    private var newsCard: some View {
        Card(title: "Related news") {
            VStack(spacing: 0) {
                ForEach(relatedNews.prefix(5)) { article in
                    Button {
                        if let url = article.url { NSWorkspace.shared.open(url) }
                    } label: {
                        HStack(spacing: 10) {
                            Text(article.title).font(DS.body).foregroundStyle(DS.ink)
                                .lineLimit(2).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            if !article.publisher.isEmpty {
                                Text(article.publisher).font(DS.micro).foregroundStyle(DS.inkTertiary).lineLimit(1)
                            }
                            Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(DS.inkTertiary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if article.id != relatedNews.prefix(5).last?.id {
                        Divider().overlay(DS.hairline.opacity(0.6)).padding(.horizontal, 8)
                    }
                }
            }
        }
    }

    // MARK: - Purchase Lots

    private var showsPortfolioColumn: Bool {
        if case .all = scope { return true }
        return false
    }

    private func portfolioName(for id: UUID) -> String {
        storageService.portfolios.first { $0.id == id }?.name ?? "—"
    }

    private var allHoldingsForSymbol: [ValuedHolding] {
        let matched = scopedPortfolios.flatMap { p in
            p.holdings.filter { $0.symbol.uppercased() == holding.symbol.uppercased() }.map { h in
                let price = quote.displayPrice(extendedHours: storageService.showExtendedHours)
                let val = h.marketValue(currentPrice: price)
                let cst = h.costBasisLocal
                return ValuedHolding(id: h.id, portfolioId: p.id, holding: h, quote: quote,
                                     value: val, cost: cst, dayChangePercent: quote.changePercent,
                                     type: storageService.type(for: h.symbol))
            }
        }
        return matched
    }

    private var aggregatedHoldings: [Holding] {
        allHoldingsForSymbol.map(\.holding)
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

    private var aggregatedPnl: Double { aggregatedValue - aggregatedCost }

    private var aggregatedPnlPercent: Double {
        abs(aggregatedCost) >= 0.01 ? (aggregatedPnl / abs(aggregatedCost)) * 100 : 0
    }

    private var scopedPortfolioValue: Double {
        scopedPortfolios.flatMap(\.holdings).reduce(0) { sum, item in
            guard let itemQuote = stockService.quotes[item.symbol] else { return sum }
            let price = itemQuote.displayPrice(extendedHours: storageService.showExtendedHours)
            return sum + item.marketValue(currentPrice: price) * stockService.rate(from: itemQuote.currency)
        }
    }

    private var aggregatedValueInPreferredCurrency: Double {
        let price = quote.displayPrice(extendedHours: storageService.showExtendedHours)
        let rate = stockService.rate(from: quote.currency)
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
                    Text("P&L").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(maxWidth: .infinity, alignment: .trailing)
                    Text("Actions").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(width: 50, alignment: .trailing)
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

                        Text(StorageService.formatCompactAmount(vh.holding.avgPrice, symbol: priceSymbol))
                            .font(DS.figure)
                            .foregroundStyle(DS.ink)
                            .frame(maxWidth: .infinity, alignment: .trailing)

                        Text(StorageService.formatCompactAmount(vh.value, symbol: priceSymbol))
                            .font(DS.figure)
                            .foregroundStyle(DS.ink)
                            .frame(maxWidth: .infinity, alignment: .trailing)

                        VStack(alignment: .trailing, spacing: 1) {
                            Text(StorageService.formatCompactAmount(vh.pnl, symbol: priceSymbol, signed: true))
                                .font(DS.figure)
                            Text(String(format: "%+.\(storageService.percentDecimals)f%%", vh.pnlPercent))
                                .font(DS.micro)
                        }
                        .foregroundStyle(DS.pnlColor(vh.pnl))
                        .frame(maxWidth: .infinity, alignment: .trailing)

                        HStack(spacing: 6) {
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
                                storageService.removeHolding(from: vh.portfolioId, holdingId: vh.holding.id)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DS.down)
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                            .help("Delete lot")
                        }
                        .frame(width: 50, alignment: .trailing)
                    }
                    .padding(.vertical, 8)
                    if vh.id != allHoldingsForSymbol.last?.id {
                        Divider().overlay(DS.hairline.opacity(0.6)).padding(.horizontal, 4)
                    }
                }

                Divider().overlay(DS.hairline).padding(.top, 4)
                Button(action: {
                    addHoldingAction.perform(portfolioId)
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

    // MARK: - Stats

    private var statStrip: some View {
        HStack(spacing: 10) {
            StatTile(label: "Position", value: "\(formatQty(totalQuantity)) sh", help: "Shares across all purchase lots shown below")
            StatTile(label: "Avg price", value: StorageService.formatCompactAmount(weightedAveragePrice, symbol: priceSymbol), help: "Quantity-weighted average purchase price")
            StatTile(label: "Cost", value: StorageService.formatCompactAmount(aggregatedCost, symbol: priceSymbol), help: "Total cost basis across all purchase lots")
            StatTile(label: "Value", value: StorageService.formatCompactAmount(aggregatedValue, symbol: priceSymbol), help: "Current market value across all purchase lots")
            StatTile(label: "P&L",
                     value: StorageService.formatCompactAmount(aggregatedPnl, symbol: priceSymbol, signed: true),
                     caption: String(format: "%+.\(storageService.percentDecimals)f%%", aggregatedPnlPercent),
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
                                    .help("Your average purchase price")
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
