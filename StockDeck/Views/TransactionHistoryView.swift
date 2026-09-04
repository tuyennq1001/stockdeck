import SwiftUI

struct TransactionHistoryView: View {
    @EnvironmentObject private var storageService: StorageService
    @EnvironmentObject private var stockService: StockService

    let portfolioId: UUID?

    private enum DeleteTarget {
        case group(ConsolidatedTransaction)
        case single(portfolioId: UUID, tx: Transaction)

        var title: String {
            switch self {
            case .group(let g):
                return g.transactions.count > 1 ? "Delete \(g.transactions.count) Transactions" : "Delete Transaction"
            case .single:
                return "Delete Transaction Fill"
            }
        }

        var message: String {
            switch self {
            case .group(let g):
                if g.transactions.count > 1 {
                    return "Are you sure you want to delete all \(g.transactions.count) \(g.type.displayName) transaction records for \(g.symbol) on this date? This action cannot be undone."
                } else {
                    return "Are you sure you want to delete the \(g.type.displayName) transaction for \(g.symbol)? This action cannot be undone."
                }
            case .single(_, let tx):
                return "Are you sure you want to delete this \(tx.type.displayName) transaction fill (\(StorageService.formatNumber(tx.quantity, decimals: -1)) sh) for \(tx.symbol)? This action cannot be undone."
            }
        }
    }

    @State private var selectedType: TransactionType? = nil
    @State private var searchQuery: String = ""
    @State private var confirmDeleteTarget: DeleteTarget? = nil
    @State private var expandedTxIds: Set<String> = []
    @State private var showAddSheet: Bool = false
    @State private var currentPage: Int = 1
    @AppStorage("table_page_size") private var pageSize: Int = 20

    private var targetPortfolios: [Portfolio] {
        if let pid = portfolioId {
            return storageService.portfolios.filter { $0.id == pid }
        }
        return storageService.portfolios
    }

    private var allTransactionsWithPortfolio: [(tx: Transaction, portfolioId: UUID, portfolioName: String)] {
        var results: [(tx: Transaction, portfolioId: UUID, portfolioName: String)] = []
        for p in targetPortfolios {
            for tx in p.transactions {
                results.append((tx, p.id, p.name))
            }
        }
        return results.sorted { $0.tx.date > $1.tx.date }
    }

    private var allConsolidatedTransactions: [ConsolidatedTransaction] {
        ConsolidatedTransaction.consolidate(transactionsWithPortfolio: allTransactionsWithPortfolio)
            .sorted { $0.date > $1.date }
    }

    private var filteredTransactions: [ConsolidatedTransaction] {
        allConsolidatedTransactions.filter { item in
            if let type = selectedType, item.type != type {
                return false
            }
            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let matchSym = item.symbol.lowercased().contains(q)
                let matchAcct = item.account?.lowercased().contains(q) ?? false
                let matchNotes = item.transactions.contains { $0.notes?.lowercased().contains(q) ?? false }
                if !matchSym && !matchAcct && !matchNotes { return false }
            }
            return true
        }
    }

    private var pagedTransactions: [ConsolidatedTransaction] {
        let total = filteredTransactions.count
        guard total > 0 else { return [] }
        let maxPage = max(1, Int(ceil(Double(total) / Double(pageSize))))
        let validPage = min(max(1, currentPage), maxPage)
        let start = (validPage - 1) * pageSize
        let end = min(start + pageSize, total)
        guard start < end else { return [] }
        return Array(filteredTransactions[start..<end])
    }

    private var rawFilteredCount: Int {
        filteredTransactions.reduce(0) { $0 + $1.transactions.count }
    }

    private var totalBuyAmount: Double {
        filteredTransactions.filter { $0.type == .buy }.reduce(0) { total, item in
            let curr = item.effectiveCurrency
            let rate = stockService.rate(from: curr)
            return total + (item.effectiveAmount * rate)
        }
    }

    private var totalSellAmount: Double {
        filteredTransactions.filter { $0.type == .sell }.reduce(0) { total, item in
            let curr = item.effectiveCurrency
            let rate = stockService.rate(from: curr)
            return total + (item.effectiveAmount * rate)
        }
    }

    private var currencySymbol: String {
        StorageService.currencySymbol(for: storageService.preferredCurrency)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Stats & Actions Strip
            HStack(spacing: 12) {
                StatTile(
                    label: "Orders",
                    value: "\(filteredTransactions.count)",
                    caption: rawFilteredCount > filteredTransactions.count ? "\(rawFilteredCount) total executions" : "Logged orders",
                    captionTint: DS.inkSecondary
                )
                .frame(maxWidth: 220)

                StatTile(
                    label: "Total Buys",
                    value: StorageService.formatAmount(totalBuyAmount, symbol: currencySymbol, decimals: 0),
                    caption: "\(filteredTransactions.filter { $0.type == .buy }.count) buy orders",
                    captionTint: DS.inkSecondary,
                    valueTint: DS.ink
                )
                .frame(maxWidth: 220)

                StatTile(
                    label: "Total Sells",
                    value: StorageService.formatAmount(totalSellAmount, symbol: currencySymbol, decimals: 0),
                    caption: "\(filteredTransactions.filter { $0.type == .sell }.count) sell orders",
                    captionTint: DS.inkSecondary,
                    valueTint: DS.ink
                )
                .frame(maxWidth: 220)

                Spacer()

                if let pid = portfolioId, let port = storageService.portfolios.first(where: { $0.id == pid }), !port.isReadOnly {
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("Add Transaction", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.brand)
                }
            }

            // Filter Bar
            HStack(spacing: 10) {
                Menu {
                    Button("All Types") { selectedType = nil }
                    Divider()
                    ForEach(TransactionType.allCases, id: \.self) { t in
                        Button(t.displayName) { selectedType = t }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                        Text(selectedType?.displayName ?? "All Types")
                    }
                    .font(DS.body)
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DS.cardAlt)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(DS.inkTertiary)
                    TextField("Search symbol, account...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(DS.body)
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(DS.inkTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(DS.cardAlt)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 280)

                Spacer()
            }

            // Transactions Table Card
            Card(title: "Transactions (\(filteredTransactions.count))") {
                if filteredTransactions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(DS.inkTertiary)
                        Text("No transactions found")
                            .font(DS.bodyStrong)
                            .foregroundStyle(DS.ink)
                        Text("Transactions imported from broker trade history or manually logged will appear here.")
                            .font(DS.caption)
                            .foregroundStyle(DS.inkSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                } else {
                    VStack(spacing: 0) {
                        // Header
                        HStack(spacing: 0) {
                            Text("Date").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(width: 95, alignment: .leading)
                            Text("Type").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(width: 85, alignment: .leading)
                            Text("Symbol").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(width: 130, alignment: .leading)
                            Text("Account").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(width: 120, alignment: .leading)
                            Text("Quantity").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(width: 80, alignment: .trailing)
                            Text("Price").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(maxWidth: .infinity, alignment: .trailing)
                            Text("Total Amount").font(DS.micro).foregroundStyle(DS.inkTertiary).frame(maxWidth: .infinity, alignment: .trailing)
                            Text("").frame(width: 28, alignment: .trailing)
                        }
                        .padding(.bottom, 8)
                        Divider().overlay(DS.hairline)

                        // Rows
                        ForEach(pagedTransactions) { item in
                            let isExpanded = expandedTxIds.contains(item.id)
                            VStack(spacing: 0) {
                                ConsolidatedTransactionRowView(
                                    item: item,
                                    isExpanded: isExpanded,
                                    onToggleExpand: {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            if isExpanded {
                                                expandedTxIds.remove(item.id)
                                            } else {
                                                expandedTxIds.insert(item.id)
                                            }
                                        }
                                    },
                                    onDelete: {
                                        confirmDeleteTarget = .group(item)
                                    }
                                )

                                if isExpanded && item.transactions.count > 1 {
                                    VStack(spacing: 2) {
                                        ForEach(Array(item.transactions.enumerated()), id: \.element.id) { index, tx in
                                            SubTransactionRowView(
                                                tx: tx,
                                                index: index + 1,
                                                onDelete: {
                                                    confirmDeleteTarget = .single(portfolioId: item.portfolioId, tx: tx)
                                                }
                                            )
                                        }
                                    }
                                    .padding(.vertical, 3)
                                }
                            }

                            Divider().overlay(DS.hairline.opacity(0.5))
                        }

                        // Pagination Controls
                        TablePaginationBar(
                            currentPage: $currentPage,
                            pageSize: $pageSize,
                            totalItems: filteredTransactions.count
                        )
                    }
                }
            }
        }
        .onChange(of: searchQuery) { _, _ in currentPage = 1 }
        .onChange(of: selectedType) { _, _ in currentPage = 1 }
        .sheet(isPresented: $showAddSheet) {
            if let pid = portfolioId {
                AddTransactionSheet(portfolioId: pid)
            }
        }
        .alert(
            confirmDeleteTarget?.title ?? "Delete Transaction",
            isPresented: Binding(
                get: { confirmDeleteTarget != nil },
                set: { if !$0 { confirmDeleteTarget = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { confirmDeleteTarget = nil }
            Button("Delete", role: .destructive) {
                if let target = confirmDeleteTarget {
                    switch target {
                    case .group(let g):
                        storageService.removeTransactions(from: g.portfolioId, transactionIds: Set(g.transactions.map(\.id)))
                    case .single(let pid, let tx):
                        storageService.removeTransaction(from: pid, transactionId: tx.id)
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
}

private struct ConsolidatedTransactionRowView: View {
    let item: ConsolidatedTransaction
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onDelete: () -> Void

    private var itemCurrencySymbol: String {
        StorageService.currencySymbol(for: item.effectiveCurrency)
    }

    private var badgeColor: Color {
        switch item.type {
        case .buy: return DS.up
        case .sell: return DS.down
        case .transferIn: return Color.blue
        case .transferOut: return Color.orange
        case .dividend: return Color.purple
        case .spinOff: return Color.teal
        case .split: return Color.indigo
        case .cashDeposit: return DS.up
        case .cashWithdrawal: return DS.down
        }
    }

    private var dateString: String {
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd"
        return df.string(from: item.date)
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(dateString)
                .font(DS.figure)
                .foregroundStyle(DS.inkSecondary)
                .frame(width: 90, alignment: .leading)

            HStack(spacing: 4) {
                Text(item.type.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(badgeColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(width: 85, alignment: .leading)

            HStack(spacing: 6) {
                SymbolLogo(symbol: item.symbol, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(StockService.beautifiedSymbol(item.symbol))
                            .font(DS.bodyStrong)
                            .foregroundStyle(DS.ink)

                        if item.transactions.count > 1 {
                            Button(action: onToggleExpand) {
                                HStack(spacing: 2) {
                                    Text("\(item.transactions.count) fills")
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
                            .help("Click to view \(item.transactions.count) partial executions")
                        }
                    }

                    let fundName = StockService.codeToFundNameMap[item.symbol]
                    if let name = fundName, !name.isEmpty {
                        Text(name)
                            .font(DS.micro)
                            .foregroundStyle(DS.inkTertiary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: 130, alignment: .leading)

            Text(item.account ?? "—")
                .font(DS.caption)
                .foregroundStyle(DS.inkSecondary)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            Text(StorageService.formatNumber(item.quantity, decimals: -1))
                .font(DS.figure)
                .foregroundStyle(DS.ink)
                .frame(width: 80, alignment: .trailing)

            Text(StorageService.formatAmount(item.price, symbol: itemCurrencySymbol, decimals: 2))
                .font(DS.figure)
                .foregroundStyle(DS.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Text(StorageService.formatAmount(item.effectiveAmount, symbol: itemCurrencySymbol, decimals: 2))
                .font(DS.figure)
                .foregroundStyle(DS.ink)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.inkTertiary)
            }
            .buttonStyle(.plain)
            .help(item.transactions.count > 1 ? "Delete all \(item.transactions.count) transaction fills" : "Delete transaction")
            .frame(width: 28, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label(item.transactions.count > 1 ? "Delete All \(item.transactions.count) Fills" : "Delete Transaction", systemImage: "trash")
            }
        }
    }
}

private struct SubTransactionRowView: View {
    let tx: Transaction
    let index: Int
    let onDelete: () -> Void

    private var itemCurrencySymbol: String {
        StorageService.currencySymbol(for: tx.effectiveCurrency)
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9))
                    .foregroundStyle(DS.inkTertiary)
                Text("Fill #\(index)")
                    .font(DS.micro)
                    .foregroundStyle(DS.inkSecondary)
            }
            .padding(.leading, 14)
            .frame(width: 90, alignment: .leading)

            Spacer().frame(width: 85)

            if let notes = tx.notes, !notes.isEmpty {
                Text(notes)
                    .font(DS.micro)
                    .foregroundStyle(DS.inkTertiary)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
            } else {
                Spacer().frame(width: 130)
            }

            Text(tx.account ?? "—")
                .font(DS.micro)
                .foregroundStyle(DS.inkSecondary)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            Text(StorageService.formatNumber(tx.quantity, decimals: -1))
                .font(DS.micro)
                .foregroundStyle(DS.inkSecondary)
                .frame(width: 80, alignment: .trailing)

            Text(StorageService.formatAmount(tx.price, symbol: itemCurrencySymbol, decimals: 2))
                .font(DS.micro)
                .foregroundStyle(DS.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Text(StorageService.formatAmount(tx.effectiveAmount, symbol: itemCurrencySymbol, decimals: 2))
                .font(DS.micro)
                .foregroundStyle(DS.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 9))
                    .foregroundStyle(DS.inkTertiary.opacity(0.8))
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help("Delete this individual fill")
            .frame(width: 28, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .background(DS.cardAlt.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

