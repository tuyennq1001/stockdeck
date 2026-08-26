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
    @FocusState private var isFieldFocused: Bool
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Search")
                    .font(.inter(13, weight: .bold, relativeTo: .headline))
                Spacer()
                Button("Close") { isPresented = false }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()
            }
            .padding()

            TextField("Symbol, name or ISIN (e.g. AAPL, Tesla, IE00B4L5Y983)", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .padding(.horizontal)
                .onAppear {
                    isFieldFocused = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isFieldFocused = true
                    }
                }
                .onChange(of: query) { _, newValue in
                    searchTask?.cancel()
                    guard newValue.count >= 2 else {
                        results = []
                        return
                    }
                    searchTask = Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !Task.isCancelled else { return }
                        isSearching = true
                        let searchResults = await stockService.search(query: newValue)
                        guard !Task.isCancelled else { return }
                        results = searchResults
                        isSearching = false
                    }
                }

            // Asset Filter tabs
            HStack(spacing: 4) {
                ForEach(WatchlistSearchSheet.AssetFilter.allCases, id: \.self) { f in
                    Button(f.label) { filter = f }
                        .font(.inter(9, weight: .semibold, relativeTo: .caption2))
                        .foregroundStyle(filter == f ? DS.ink : DS.inkTertiary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(filter == f ? DS.cardAlt : Color.clear)
                        )
                }
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .padding(.horizontal, 12).padding(.top, 6)

            Divider()
                .padding(.top, 6)

            if isSearching {
                Spacer()
                ProgressView("Searching...")
                Spacer()
            } else if filteredResults.isEmpty && query.count >= 2 {
                Spacer()
                Text("No results")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                List(filteredResults) { result in
                    Button(action: { addResult(result) }) {
                        HStack(spacing: 8) {
                            SymbolLogo(symbol: result.symbol, size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(StockService.beautifiedSymbol(result.symbol))
                                    .font(.inter(13, relativeTo: .body).monospacedDigit())
                                    .fontWeight(.semibold)
                                Text(result.name)
                                    .font(.inter(10, relativeTo: .caption))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()

                            if !result.exchange.isEmpty {
                                Text(WatchlistSearchSheet.friendlyExchange(result.exchange))
                                    .font(.inter(9, relativeTo: .caption2))
                                    .foregroundColor(.secondary)
                            }

                            if isAlreadyAdded(result.symbol) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.inter(10, relativeTo: .caption))
                            }
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .onHover { inside in
                        hoveredSymbol = inside ? result.id : nil
                    }
                    .listRowBackground(
                        hoveredSymbol == result.id
                            ? DS.brand.opacity(0.06)
                            : Color.clear
                    )
                }
                .listStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var queryLooksLikeISIN: Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.count == 12 && q.prefix(2).allSatisfy(\.isLetter) && q.dropFirst(2).allSatisfy { $0.isLetter || $0.isNumber }
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
