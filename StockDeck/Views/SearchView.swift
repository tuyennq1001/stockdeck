import SwiftUI

enum SearchMode {
    case watchlist
    case holding(portfolioId: UUID)
}

struct SearchView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService

    let mode: SearchMode
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var filter: WatchlistSearchSheet.AssetFilter = .all
    @State private var hoveredSymbol: String? = nil

    private var filteredResults: [SearchResult] {
        switch filter {
        case .all: return results
        case .stocks: return results.filter { r in
            let t = r.type.uppercased()
            return t == "EQUITY" || t == "ETF" || t == "INDEX" || t == "STOCK"
        }
        case .funds: return results.filter { r in
            let t = r.type.uppercased()
            return t == "MUTUALFUND" || t == "MONEYMARKET" || t == "BOND"
        }
        case .crypto: return results.filter { r in
            r.type.uppercased() == "CRYPTOCURRENCY"
        }
        }
    }

    private var queryLooksLikeISIN: Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.count == 12 && q.prefix(2).allSatisfy(\.isLetter) && q.dropFirst(2).allSatisfy { $0.isLetter || $0.isNumber }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Add to watchlist")
                    .font(DS.titleXL)
                    .tracking(-0.3)
                    .foregroundStyle(DS.ink)
                Spacer()
                Button("Done") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPresented = false
                    }
                }
                .buttonStyle(.plain)
                .font(.inter(12, weight: .medium, relativeTo: .body))
                .foregroundStyle(DS.brand)
                .pointingHandCursor()
                .keyboardShortcut(.cancelAction)
            }

            DSTextField(placeholder: "Symbol, name or ISIN (e.g. AAPL, Tesla)", text: $query)
                .onChange(of: query) { _, new in runSearch(new) }

            // Filter tabs
            HStack(spacing: 4) {
                ForEach(WatchlistSearchSheet.AssetFilter.allCases, id: \.self) { f in
                    Button(f.label) { filter = f }
                        .font(.inter(11, weight: .semibold, relativeTo: .caption))
                        .foregroundStyle(filter == f ? DS.ink : DS.inkTertiary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(filter == f ? DS.cardAlt : Color.clear)
                        )
                }
            }
            .buttonStyle(.plain)
            .pointingHandCursor()

            if isSearching {
                HStack { Spacer(); DSSpinner(size: 20); Spacer() }.frame(maxHeight: .infinity)
            } else if filteredResults.isEmpty && query.count >= 2 {
                VStack {
                    Spacer()
                    Text("No results")
                        .font(DS.caption)
                        .foregroundStyle(DS.inkSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredResults) { r in
                            Button { addResult(r) } label: { resultRow(r) }
                                .buttonStyle(.plain)
                                .pointingHandCursor()
                                .onHover { inside in hoveredSymbol = inside ? r.id : nil }
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(hoveredSymbol == r.id ? DS.brand.opacity(0.06) : Color.clear)
                                )
                            if r.id != filteredResults.last?.id {
                                Divider().overlay(DS.hairline.opacity(0.6)).padding(.horizontal, 8)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(18)
        .background(DS.ground)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultRow(_ r: SearchResult) -> some View {
        HStack(spacing: 10) {
            SymbolLogo(symbol: r.symbol, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(StockService.beautifiedSymbol(r.symbol))
                    .font(DS.figure)
                    .foregroundStyle(DS.ink)
                Text(r.name)
                    .font(DS.micro)
                    .foregroundStyle(DS.inkTertiary)
                    .lineLimit(1)
            }
            Spacer()
            if !r.exchange.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "building.columns")
                        .font(.system(size: 9))
                        .foregroundStyle(DS.inkTertiary)
                    Text(WatchlistSearchSheet.friendlyExchange(r.exchange))
                        .font(DS.micro)
                        .foregroundStyle(DS.inkTertiary)
                }
            }
            if isAlreadyAdded(r.symbol) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DS.up)
                    .font(.system(size: 12))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    private func runSearch(_ q: String) {
        searchTask?.cancel()
        guard q.count >= 2 else {
            results = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            isSearching = true
            let searchResults = await stockService.search(query: q)
            guard !Task.isCancelled else { return }
            results = searchResults
            isSearching = false
        }
    }

    private func addResult(_ result: SearchResult) {
        switch mode {
        case .watchlist:
            storageService.addToWatchlist(result.symbol)
            if !result.type.isEmpty { storageService.setType(result.type, for: result.symbol) }
            if !result.exchange.isEmpty { storageService.setExchange(result.exchange, for: result.symbol) }
            if queryLooksLikeISIN {
                storageService.setISIN(query.trimmingCharacters(in: .whitespaces).uppercased(), for: result.symbol)
            }
            Task {
                await stockService.fetchQuotes(symbols: [result.symbol])
            }
        case .holding:
            break
        }
    }

    private func isAlreadyAdded(_ symbol: String) -> Bool {
        switch mode {
        case .watchlist:
            return storageService.watchlist.contains(symbol)
        case .holding:
            return false
        }
    }
}
