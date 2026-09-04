import SwiftUI

struct ClosedPositionsView: View {
    @EnvironmentObject var storageService: StorageService
    @EnvironmentObject var stockService: StockService

    private enum DeleteTarget {
        case group(ConsolidatedClosedTrade)
        case single(portfolioId: UUID, trade: ClosedTrade)

        var title: String {
            switch self {
            case .group(let g):
                return g.lots.count > 1 ? "Delete \(g.lots.count) Closed Trades" : "Delete Closed Trade"
            case .single:
                return "Delete Closed Trade Lot"
            }
        }

        var message: String {
            switch self {
            case .group(let g):
                if g.lots.count > 1 {
                    return "Are you sure you want to delete all \(g.lots.count) closed trade records for \(g.symbol) on this date? This will remove them from your realized P&L history."
                } else {
                    return "Are you sure you want to delete the closed trade record for \(g.symbol)? This will remove it from your realized P&L history."
                }
            case .single(_, let trade):
                return "Are you sure you want to delete this closed trade lot (\(StorageService.formatNumber(trade.quantity, decimals: -1)) sh) for \(trade.symbol)? This will remove it from your realized P&L history."
            }
        }
    }

    let portfolioId: UUID? // nil means all portfolios
    @State private var confirmDeleteTarget: DeleteTarget? = nil
    @State private var expandedTradeIds: Set<String> = []
    @State private var sortColumn: SortColumn = .date
    @State private var sortAscending: Bool = false
    @State private var currentPage: Int = 1
    @AppStorage("table_page_size") private var pageSize: Int = 20

    enum SortColumn {
        case date, symbol, account, cost, pnl, pnlPercent, proceeds
    }

    private var scopedPortfolios: [Portfolio] {
        if let pid = portfolioId {
            return storageService.portfolios.filter { $0.id == pid }
        }
        return storageService.portfolios
    }

    struct ValuedConsolidatedTrade: Identifiable {
        let trade: ConsolidatedClosedTrade
        let currency: String
        let currSymbol: String
        let fxRate: Double

        var id: String { trade.id }
        var pnlLocal: Double { trade.realizedPnl }
        var pnlPreferred: Double { trade.realizedPnl * fxRate }
        var costPreferred: Double { trade.costBasis * fxRate }
        var proceedsPreferred: Double { trade.proceeds * fxRate }
    }

    private var allTrades: [ValuedConsolidatedTrade] {
        var raw: [(trade: ClosedTrade, portfolioId: UUID, portfolioName: String)] = []
        for p in scopedPortfolios {
            for t in p.closedTrades {
                raw.append((t, p.id, p.name))
            }
        }
        let consolidated = ConsolidatedClosedTrade.consolidate(tradesWithPortfolio: raw)
        var list: [ValuedConsolidatedTrade] = []
        for ct in consolidated {
            let curr = stockService.detectedCurrency(for: ct.symbol)
            let currSym = StorageService.currencySymbol(for: curr)
            let rate = stockService.rate(from: curr)
            list.append(ValuedConsolidatedTrade(
                trade: ct,
                currency: curr,
                currSymbol: currSym,
                fxRate: rate
            ))
        }

        return list.sorted { lhs, rhs in
            switch sortColumn {
            case .date:
                let ld = lhs.trade.sellDate ?? .distantPast
                let rd = rhs.trade.sellDate ?? .distantPast
                return sortAscending ? ld < rd : ld > rd
            case .symbol:
                return sortAscending
                    ? lhs.trade.symbol < rhs.trade.symbol
                    : lhs.trade.symbol > rhs.trade.symbol
            case .account:
                let la = lhs.trade.account ?? ""
                let ra = rhs.trade.account ?? ""
                return sortAscending ? la < ra : la > ra
            case .cost:
                return sortAscending ? lhs.costPreferred < rhs.costPreferred : lhs.costPreferred > rhs.costPreferred
            case .pnl:
                return sortAscending ? lhs.pnlPreferred < rhs.pnlPreferred : lhs.pnlPreferred > rhs.pnlPreferred
            case .pnlPercent:
                return sortAscending ? lhs.trade.realizedPnlPercent < rhs.trade.realizedPnlPercent : lhs.trade.realizedPnlPercent > rhs.trade.realizedPnlPercent
            case .proceeds:
                return sortAscending ? lhs.proceedsPreferred < rhs.proceedsPreferred : lhs.proceedsPreferred > rhs.proceedsPreferred
            }
        }
    }

    private var pagedTrades: [ValuedConsolidatedTrade] {
        let total = allTrades.count
        guard total > 0 else { return [] }
        let maxPage = max(1, Int(ceil(Double(total) / Double(pageSize))))
        let validPage = min(max(1, currentPage), maxPage)
        let start = (validPage - 1) * pageSize
        let end = min(start + pageSize, total)
        guard start < end else { return [] }
        return Array(allTrades[start..<end])
    }

    private var totalRealizedPnl: Double {
        allTrades.reduce(0) { $0 + $1.pnlPreferred }
    }

    private var totalCostBasis: Double {
        allTrades.reduce(0) { $0 + $1.costPreferred }
    }

    private var totalReturnPercent: Double {
        totalCostBasis > 0 ? (totalRealizedPnl / totalCostBasis) * 100 : 0
    }

    private var winRate: Double {
        guard !allTrades.isEmpty else { return 0 }
        let wins = allTrades.filter { $0.pnlLocal > 0 }.count
        return (Double(wins) / Double(allTrades.count)) * 100
    }

    private var preferredCurrSymbol: String {
        StorageService.currencySymbol(for: storageService.preferredCurrency)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.gap) {
            // Summary Stat Cards
            summaryStatsStrip

            // Closed Positions Table Card
            Card(title: "Closed Trades (\(allTrades.count))") {
                if allTrades.isEmpty {
                    emptyState
                } else {
                    tableContent
                }
            }
        }
        .alert(
            confirmDeleteTarget?.title ?? "Delete Closed Trade",
            isPresented: Binding(get: { confirmDeleteTarget != nil }, set: { if !$0 { confirmDeleteTarget = nil } })
        ) {
            Button("Cancel", role: .cancel) { confirmDeleteTarget = nil }
            Button("Delete", role: .destructive) {
                if let target = confirmDeleteTarget {
                    switch target {
                    case .group(let g):
                        storageService.removeClosedTrades(from: g.portfolioId, tradeIds: Set(g.lots.map(\.id)))
                    case .single(let pid, let t):
                        storageService.removeClosedTrade(from: pid, tradeId: t.id)
                    }
                }
                confirmDeleteTarget = nil
            }
        } message: {
            if let target = confirmDeleteTarget {
                Text(target.message)
            }
        }
    }


    private var summaryStatsStrip: some View {
        HStack(spacing: DS.gap) {
            StatTile(
                label: "Realized P&L (Đã chốt)",
                value: StorageService.formatAmount(totalRealizedPnl, symbol: preferredCurrSymbol, decimals: storageService.amountDecimals, signed: true),
                caption: String(format: "%+.\(storageService.percentDecimals)f%% return", totalReturnPercent),
                captionTint: DS.pnlColor(totalReturnPercent),
                valueTint: DS.pnlColor(totalRealizedPnl)
            )

            StatTile(
                label: "Win Rate (Tỷ lệ thắng)",
                value: String(format: "%.1f%%", winRate),
                caption: "\(allTrades.filter { $0.pnlLocal > 0 }.count)W / \(allTrades.filter { $0.pnlLocal < 0 }.count)L",
                valueTint: winRate >= 50 ? DS.up : DS.down
            )

            StatTile(
                label: "Total Closed Trades",
                value: "\(allTrades.count)",
                caption: portfolioId == nil ? "Across all portfolios" : "In this portfolio"
            )
        }
    }

    private var tableContent: some View {
        VStack(spacing: 0) {
            // Table Header
            HStack(spacing: 0) {
                Text("Symbol")
                    .font(DS.micro)
                    .foregroundStyle(DS.inkTertiary)
                    .frame(width: 130, alignment: .leading)
                    .onTapGesture { toggleSort(.symbol) }

                Text("Account")
                    .font(DS.micro)
                    .foregroundStyle(DS.inkTertiary)
                    .frame(width: 110, alignment: .leading)
                    .onTapGesture { toggleSort(.account) }

                Text("Closed Date")
                    .font(DS.micro)
                    .foregroundStyle(DS.inkTertiary)
                    .frame(width: 105, alignment: .leading)
                    .onTapGesture { toggleSort(.date) }

                if portfolioId == nil {
                    Text("Portfolio")
                        .font(DS.micro)
                        .foregroundStyle(DS.inkTertiary)
                        .frame(width: 95, alignment: .leading)
                }

                Text("Qty")
                    .font(DS.micro)
                    .foregroundStyle(DS.inkTertiary)
                    .frame(width: 55, alignment: .trailing)

                Text("Buy Price")
                    .font(DS.micro)
                    .foregroundStyle(DS.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Text("Invested")
                    .font(DS.micro)
                    .foregroundStyle(DS.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onTapGesture { toggleSort(.cost) }

                Text("Sell Price")
                    .font(DS.micro)
                    .foregroundStyle(DS.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Text("Realized P&L")
                    .font(DS.micro)
                    .foregroundStyle(DS.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .onTapGesture { toggleSort(.pnl) }

                Text("")
                    .frame(width: 28, alignment: .trailing)
            }
            .padding(.bottom, 8)

            Divider().overlay(DS.hairline)

            // Table Rows
            ForEach(pagedTrades) { item in
                let t = item.trade
                let isExpanded = expandedTradeIds.contains(item.id)

                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        // Symbol & Logo
                        HStack(spacing: 8) {
                            SymbolLogo(symbol: t.symbol, size: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text(StockService.beautifiedSymbol(t.symbol))
                                        .font(DS.bodyStrong)
                                        .foregroundStyle(DS.ink)

                                    if t.lots.count > 1 {
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.15)) {
                                                if isExpanded {
                                                    expandedTradeIds.remove(item.id)
                                                } else {
                                                    expandedTradeIds.insert(item.id)
                                                }
                                            }
                                        } label: {
                                            HStack(spacing: 2) {
                                                Text("\(t.lots.count) lots")
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
                                        .help("Click to view \(t.lots.count) constituent lots")
                                    }
                                }
                                let fundName = StockService.codeToFundNameMap[t.symbol] ?? stockService.quotes[t.symbol]?.name
                                if let name = fundName, !name.isEmpty {
                                    Text(name)
                                        .font(DS.micro)
                                        .foregroundStyle(DS.inkTertiary)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .frame(width: 130, alignment: .leading)

                        // Account
                        Text(t.account ?? "—")
                            .font(DS.caption)
                            .foregroundStyle(DS.inkSecondary)
                            .lineLimit(1)
                            .frame(width: 110, alignment: .leading)

                        // Closed Date & Holding Days
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.sellDate.map { Self.dateFormatter.string(from: $0) } ?? "—")
                                .font(DS.caption)
                                .foregroundStyle(DS.ink)
                            if let days = t.holdingPeriodDays {
                                Text("\(days)d avg held")
                                    .font(DS.micro)
                                    .foregroundStyle(DS.inkTertiary)
                            }
                        }
                        .frame(width: 105, alignment: .leading)

                        if portfolioId == nil {
                            Text(t.portfolioName)
                                .font(DS.caption)
                                .foregroundStyle(DS.inkSecondary)
                                .lineLimit(1)
                                .frame(width: 95, alignment: .leading)
                        }

                        // Qty
                        Text(StorageService.formatNumber(t.quantity, decimals: -1))
                            .font(DS.figure)
                            .foregroundStyle(DS.ink)
                            .frame(width: 55, alignment: .trailing)

                        // Buy Price (Weighted)
                        Text(t.buyPrice > 0 ? StorageService.formatAmount(t.buyPrice, symbol: item.currSymbol, decimals: storageService.amountDecimals) : "—")
                            .font(DS.figure)
                            .foregroundStyle(DS.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)

                        // Invested (Cost Basis)
                        Text(t.costBasis > 0 ? StorageService.formatAmount(t.costBasis, symbol: item.currSymbol, decimals: storageService.amountDecimals) : "—")
                            .font(DS.figure)
                            .foregroundStyle(DS.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)

                        // Sell Price (Weighted)
                        Text(StorageService.formatAmount(t.sellPrice, symbol: item.currSymbol, decimals: storageService.amountDecimals))
                            .font(DS.figure)
                            .foregroundStyle(DS.ink)
                            .frame(maxWidth: .infinity, alignment: .trailing)

                        // Realized P&L
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(StorageService.formatAmount(t.realizedPnl, symbol: item.currSymbol, decimals: storageService.amountDecimals, signed: true))
                                .font(DS.figure)
                                .foregroundStyle(DS.pnlColor(t.realizedPnl))
                            ChangePill(
                                value: t.realizedPnlPercent,
                                text: String(format: "%+.\(storageService.percentDecimals)f%%", t.realizedPnlPercent)
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)

                        // Delete Action
                        Button {
                            confirmDeleteTarget = .group(t)
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(DS.inkTertiary)
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help(t.lots.count > 1 ? "Delete all \(t.lots.count) closed trade lots" : "Delete closed trade")
                        .frame(width: 28, alignment: .trailing)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())

                    // Expanded Sub-lots Breakdown
                    if isExpanded && t.lots.count > 1 {
                        VStack(spacing: 2) {
                            ForEach(t.lots) { lot in
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
                                    .padding(.leading, 14)
                                    .frame(width: 130, alignment: .leading)

                                    Text(lot.account ?? "—")
                                        .font(DS.micro)
                                        .foregroundStyle(DS.inkSecondary)
                                        .lineLimit(1)
                                        .frame(width: 110, alignment: .leading)

                                    Text(lot.holdingPeriodDays.map { "\($0)d held" } ?? "—")
                                        .font(DS.micro)
                                        .foregroundStyle(DS.inkTertiary)
                                        .frame(width: 105, alignment: .leading)

                                    if portfolioId == nil {
                                        Spacer().frame(width: 95)
                                    }

                                    Text(StorageService.formatNumber(lot.quantity, decimals: -1))
                                        .font(DS.micro)
                                        .foregroundStyle(DS.inkSecondary)
                                        .frame(width: 55, alignment: .trailing)

                                    Text(lot.buyPrice > 0 ? StorageService.formatAmount(lot.buyPrice, symbol: item.currSymbol, decimals: storageService.amountDecimals) : "—")
                                        .font(DS.micro)
                                        .foregroundStyle(DS.inkSecondary)
                                        .frame(maxWidth: .infinity, alignment: .trailing)

                                    Text(lot.costBasis > 0 ? StorageService.formatAmount(lot.costBasis, symbol: item.currSymbol, decimals: storageService.amountDecimals) : "—")
                                        .font(DS.micro)
                                        .foregroundStyle(DS.inkSecondary)
                                        .frame(maxWidth: .infinity, alignment: .trailing)

                                    Text(StorageService.formatAmount(lot.sellPrice, symbol: item.currSymbol, decimals: storageService.amountDecimals))
                                        .font(DS.micro)
                                        .foregroundStyle(DS.inkSecondary)
                                        .frame(maxWidth: .infinity, alignment: .trailing)

                                    VStack(alignment: .trailing, spacing: 1) {
                                        Text(StorageService.formatAmount(lot.realizedPnl, symbol: item.currSymbol, decimals: storageService.amountDecimals, signed: true))
                                            .font(DS.micro)
                                            .foregroundStyle(DS.pnlColor(lot.realizedPnl))
                                        Text(String(format: "%+.\(storageService.percentDecimals)f%%", lot.realizedPnlPercent))
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(DS.pnlColor(lot.realizedPnl))
                                    }
                                    .frame(maxWidth: .infinity, alignment: .trailing)

                                    Button {
                                        confirmDeleteTarget = .single(portfolioId: t.portfolioId, trade: lot)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 9))
                                            .foregroundStyle(DS.inkTertiary.opacity(0.8))
                                    }
                                    .buttonStyle(.plain)
                                    .pointingHandCursor()
                                    .help("Delete this individual lot")
                                    .frame(width: 28, alignment: .trailing)
                                }
                                .padding(.vertical, 4)
                                .background(DS.cardAlt.opacity(0.45))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }

                .contentShape(Rectangle())

                Divider().overlay(DS.hairline.opacity(0.5))
            }

            // Pagination Controls
            TablePaginationBar(
                currentPage: $currentPage,
                pageSize: $pageSize,
                totalItems: allTrades.count
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28))
                .foregroundStyle(DS.inkTertiary)
            Text("No Closed Trades")
                .font(DS.bodyStrong)
                .foregroundStyle(DS.ink)
            Text("When you sell or close a position, your realized profit/loss will be recorded and summarized here.")
                .font(DS.caption)
                .foregroundStyle(DS.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func toggleSort(_ col: SortColumn) {
        if sortColumn == col {
            sortAscending.toggle()
        } else {
            sortColumn = col
            sortAscending = false
        }
        currentPage = 1
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}
