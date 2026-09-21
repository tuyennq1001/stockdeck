import SwiftUI

struct AddHoldingView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService

    let portfolioId: UUID
    @Binding var isPresented: UUID?

    @State private var searchText = ""
    @State private var quantityText = ""
    @State private var avgPriceText = ""
    @State private var leverageText = ""
    @State private var isShort = false
    @State private var purchaseDate = Date()
    @State private var searchResults: [SearchResult] = []
    @State private var selectedSymbol: String?
    @State private var searchTask: Task<Void, Never>?

    @FocusState private var searchFocused: Bool
    @FocusState private var quantityFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Add holding")
                    .font(.inter(13, weight: .bold, relativeTo: .headline))
                Spacer()
                Button("Close") { isPresented = nil }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()
            }
            .padding(.horizontal)
            .padding(.top)

            // Symbol search
            if let selected = selectedSymbol {
                HStack {
                    Text(selected)
                        .font(.inter(13, relativeTo: .body).monospacedDigit())
                        .fontWeight(.semibold)
                    Spacer()
                    Button(action: {
                        selectedSymbol = nil
                        searchText = ""
                        searchResults = []
                        searchFocused = true
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .pointingHandCursor()
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(8)
                .padding(.horizontal)

                if let exch = providerExchange(for: selected) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                            .padding(.top, 1)
                        if exch.contains("HOSE") || exch.contains("HNX") || exch.contains("UPCOM") {
                            Text("Nguồn dữ liệu: **VNDirect API** (Hỗ trợ: Giá đóng cửa VND, 1M/3M/1Y%, ATH, Biên độ 52W & Biểu đồ lịch sử)")
                        } else if exch.contains("BINANCE") {
                            Text("Nguồn dữ liệu: **Binance API** (Hỗ trợ: Realtime Crypto 24/7, Cặp giao dịch gốc, Biến động 24h)")
                        } else {
                            Text("Nguồn dữ liệu: **Yahoo Finance API** (Hỗ trợ: Realtime USD, 1M/3M/1Y%, ATH, Giao dịch ngoài giờ Ext)")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                    .padding(.horizontal)
                }
            } else {
                TextField("Symbol, name or ISIN (e.g. AAPL, IE00B4L5Y983)", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .padding(.horizontal)
                    .onChange(of: searchText) { _, newValue in
                        searchTask?.cancel()
                        guard newValue.count >= 1 else {
                            searchResults = []
                            return
                        }
                        searchTask = Task {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            guard !Task.isCancelled else { return }
                            searchResults = await stockService.search(query: newValue)
                        }
                    }

                if !searchResults.isEmpty {
                    List(searchResults.prefix(5)) { result in
                        Button(action: {
                            searchTask?.cancel()
                            selectedSymbol = result.symbol
                            storageService.setExchange(result.exchange, for: result.symbol)
                            storageService.setType(result.type, for: result.symbol)
                            searchResults = []
                            if let quote = stockService.quotes[result.symbol] {
                                avgPriceText = String(format: "%.2f", quote.price)
                            }
                            quantityFocused = true
                        }) {
                            HStack(spacing: 8) {
                                SymbolLogo(symbol: result.symbol, size: 24)
                                Text(result.displayTitle)
                                    .fontWeight(.semibold)
                                if !result.displaySubtitle.isEmpty {
                                    Text(result.displaySubtitle)
                                        .font(.inter(10, relativeTo: .caption))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if !result.exchange.isEmpty {
                                    Text(result.exchange.uppercased())
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(exchangeBadgeColor(result.exchange).opacity(0.15))
                                        .foregroundColor(exchangeBadgeColor(result.exchange))
                                        .cornerRadius(4)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                    }
                    .listStyle(.plain)
                    .frame(height: min(CGFloat(searchResults.prefix(5).count) * 30, 150))
                }
            }

            // Position type (Advanced)
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

            // Quantity & price
            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Quantity")
                        .font(.inter(10, relativeTo: .caption))
                        .foregroundColor(.secondary)
                    TextField("0", text: $quantityText)
                        .textFieldStyle(.roundedBorder)
                        .focused($quantityFocused)
                }
                VStack(alignment: .leading) {
                    Text("Avg cost")
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
                Text("Pick Long or Short. Leverage multiplies PnL and exposure (empty = 1\u{00D7}).")
                    .font(.inter(10, relativeTo: .caption))
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            }

            VStack(alignment: .leading) {
                Text("Purchase date")
                    .font(.inter(10, relativeTo: .caption))
                    .foregroundColor(.secondary)
                DatePicker("", selection: $purchaseDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
            }
            .padding(.horizontal)

            Spacer()

            Button("Add") {
                addHolding()
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedSymbol == nil || quantityText.isEmpty || avgPriceText.isEmpty)
            .pointingHandCursor()
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if selectedSymbol == nil {
                searchFocused = true
            } else {
                quantityFocused = true
            }
        }
    }

    private func addHolding() {
        let advanced = storageService.advancedPositions
        guard let sym = selectedSymbol,
              let qty = Double(quantityText.replacingOccurrences(of: ",", with: ".")),
              let price = Double(avgPriceText.replacingOccurrences(of: ",", with: ".")),
              price > 0, abs(qty) > 0
        else { return }

        // Quantity is entered as a positive magnitude; the Long/Short picker
        // (Advanced only) decides the sign.
        let signedQty = (advanced && isShort) ? -abs(qty) : abs(qty)
        let leverage = parsedLeverage()
        storageService.addHolding(to: portfolioId, symbol: sym, quantity: signedQty, avgPrice: price, purchaseDate: purchaseDate, leverage: leverage)
        Task {
            await stockService.refreshAll(storageService: storageService)
        }
        isPresented = nil
    }

    /// Parsed leverage, or nil when advanced mode is off, the field is empty, or
    /// the value is an unlevered 1× — so unlevered holdings stay clean in storage.
    private func parsedLeverage() -> Double? {
        guard storageService.advancedPositions,
              let l = Double(leverageText.replacingOccurrences(of: ",", with: ".")),
              l > 0, l != 1
        else { return nil }
        return l
    }

    private func exchangeBadgeColor(_ exchange: String) -> Color {
        let upper = exchange.uppercased()
        if upper.contains("HOSE") || upper.contains("HNX") || upper.contains("UPCOM") {
            return .red
        } else if upper.contains("NASDAQ") || upper.contains("NYSE") {
            return .blue
        } else if upper.contains("BINANCE") {
            return .orange
        } else if upper.contains("TSE") || upper.contains("JP") {
            return .purple
        }
        return .secondary
    }

    private func providerExchange(for symbol: String) -> String? {
        let stored = storageService.exchange(for: symbol)
        if !stored.isEmpty {
            return stored.uppercased()
        }
        if StockService.isVietnameseStock(symbol) {
            return "HOSE"
        }
        if StorageService.isBinanceNativePair(symbol) || StorageService.isStandardCryptoSymbol(symbol) {
            return "BINANCE"
        }
        return "NASDAQ"
    }
}
