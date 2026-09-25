import SwiftUI

struct StockTargetSheet: View {
    @EnvironmentObject var storageService: StorageService
    @EnvironmentObject var stockService: StockService

    let symbol: String?
    let onDismiss: () -> Void

    @State private var selectedSymbol: String? = nil
    @State private var targetPriceText: String = ""
    @State private var note: String = ""
    @State private var notifyWhenReached: Bool = true
    @State private var showDeleteConfirmation: Bool = false
    @State private var searchText: String = ""
    @State private var searchResults: [SearchResult] = []
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    init(symbol: String? = nil, onDismiss: @escaping () -> Void) {
        self.symbol = (symbol?.isEmpty == false) ? symbol : nil
        self.onDismiss = onDismiss
    }

    private var fixedSymbol: String? {
        if let symbol, !symbol.isEmpty { return symbol }
        return nil
    }

    private var effectiveSymbol: String? {
        fixedSymbol ?? selectedSymbol
    }

    private var quote: StockQuote? {
        guard let sym = effectiveSymbol else { return nil }
        return stockService.quotes[sym]
    }

    private var currentPrice: Double {
        quote?.effectivePrice ?? quote?.price ?? 0
    }

    private var currencySymbol: String {
        StorageService.currencySymbol(for: quote?.currency ?? storageService.preferredCurrency)
    }

    private var existingTarget: StockTarget? {
        guard let sym = effectiveSymbol else { return nil }
        return storageService.buyTarget(for: sym)
    }

    private var parsedTargetPrice: Double? {
        let clean = targetPriceText.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let val = Double(clean), val > 0 else { return nil }
        return val
    }

    private var distancePercent: Double? {
        guard let target = parsedTargetPrice, currentPrice > 0 else { return nil }
        return ((target - currentPrice) / currentPrice) * 100.0
    }

    private var isInBuyZone: Bool {
        guard let target = parsedTargetPrice, currentPrice > 0 else { return false }
        return currentPrice <= target
    }

    private var availableWatchlistSymbols: [String] {
        var seen = Set<String>()
        var list: [String] = []
        for wl in storageService.watchlists {
            for s in wl.symbols {
                if seen.insert(s).inserted {
                    list.append(s)
                }
            }
        }
        for p in storageService.portfolios {
            for h in p.holdings {
                if seen.insert(h.symbol).inserted {
                    list.append(h.symbol)
                }
            }
        }
        return list
    }

    var body: some View {
        let titleStr = effectiveSymbol.map { "Buy Target · \($0)" } ?? "Set Buy Target"
        SheetShell(title: titleStr, onCancel: onDismiss, width: 440) {
            VStack(alignment: .leading, spacing: 16) {
                if let sym = effectiveSymbol {
                    // Symbol & Current Price Header
                    HStack(alignment: .center, spacing: 12) {
                        SymbolLogo(symbol: sym, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(StockService.beautifiedSymbol(sym))
                                    .font(DS.title)
                                    .foregroundStyle(DS.ink)
                                Text("Buy Target")
                                    .font(DS.micro)
                                    .fontWeight(.bold)
                                    .foregroundStyle(DS.brand)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(DS.brand.opacity(0.12)))
                            }
                            if let name = quote?.name, !name.isEmpty {
                                Text(name)
                                    .font(DS.caption)
                                    .foregroundStyle(DS.inkTertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Current Price")
                                .font(DS.micro)
                                .foregroundStyle(DS.inkTertiary)
                            let dec = storageService.resolvedPriceDecimals(symbol: sym, price: currentPrice)
                            Text(StorageService.formatAmount(currentPrice, symbol: currencySymbol, decimals: dec))
                                .font(DS.figure.monospacedDigit())
                                .fontWeight(.bold)
                                .foregroundStyle(DS.ink)
                        }

                        if fixedSymbol == nil {
                            Button {
                                selectedSymbol = nil
                                targetPriceText = ""
                                note = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(DS.inkTertiary)
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                            .help("Choose another ticker")
                        }
                    }
                    .padding(.bottom, 4)

                    Divider().overlay(DS.hairline)

                    // Target Price Input Field
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Target Price to Buy")
                            .font(DS.label)
                            .foregroundStyle(DS.inkSecondary)

                        HStack(spacing: 8) {
                            Text(currencySymbol)
                                .font(.inter(18, weight: .bold, relativeTo: .title3))
                                .foregroundStyle(DS.inkSecondary)
                                .frame(width: 20)

                            TextField("0.00", text: $targetPriceText)
                                .font(.inter(18, weight: .bold, relativeTo: .title3).monospacedDigit())
                                .textFieldStyle(.plain)
                                .foregroundStyle(DS.ink)

                            if let q = quote, !q.currency.isEmpty {
                                Text(q.currency)
                                    .font(DS.micro)
                                    .foregroundStyle(DS.inkTertiary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.cardAlt))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.brand.opacity(0.35), lineWidth: 1.5))
                    }

                    // Quick Presets
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Quick Presets")
                                .font(DS.label)
                                .foregroundStyle(DS.inkSecondary)
                            Spacer()
                            Text("Calculated from current price")
                                .font(DS.micro)
                                .foregroundStyle(DS.inkTertiary)
                        }

                        HStack(spacing: 6) {
                            presetButton("Market", percent: 0)
                            presetButton("-3%", percent: -3)
                            presetButton("-5%", percent: -5)
                            presetButton("-10%", percent: -10)
                            presetButton("-15%", percent: -15)
                            presetButton("-20%", percent: -20)
                            if let low = quote?.fiftyTwoWeekLow, low > 0 {
                                Button {
                                    applyExactPrice(low)
                                } label: {
                                    Text("52W Low")
                                        .font(DS.micro)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(DS.ink)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 5)
                                        .background(Capsule().fill(DS.cardAlt))
                                }
                                .buttonStyle(.plain)
                                .pointingHandCursor()
                            }
                        }
                    }

                    // Live Distance & Status Box
                    if let dist = distancePercent, currentPrice > 0 {
                        HStack(alignment: .center, spacing: 10) {
                            if isInBuyZone {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(DS.up)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("In Buy Zone")
                                        .font(DS.bodyStrong)
                                        .foregroundStyle(DS.up)
                                    let diff = currentPrice - (parsedTargetPrice ?? currentPrice)
                                    Text("Current price is \(StorageService.formatAmount(abs(diff), symbol: currencySymbol)) below your target")
                                        .font(DS.micro)
                                        .foregroundStyle(DS.inkSecondary)
                                }
                            } else {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 16))
                                    .foregroundStyle(DS.brand)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(String(format: "Needs %.1f%% drop to reach target", abs(dist)))
                                        .font(DS.bodyStrong)
                                        .foregroundStyle(DS.ink)
                                    let diff = (parsedTargetPrice ?? currentPrice) - currentPrice
                                    Text("Distance: \(StorageService.formatAmount(diff, symbol: currencySymbol, signed: true))")
                                        .font(DS.micro)
                                        .foregroundStyle(DS.inkSecondary)
                                }
                            }
                            Spacer()
                            if isInBuyZone {
                                Text("BUY ZONE")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(DS.up))
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isInBuyZone ? DS.upSoft : DS.cardAlt))
                    }

                    // Notification Setting
                    Toggle(isOn: $notifyWhenReached) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Notify when price reaches target")
                                .font(DS.bodyStrong)
                                .foregroundStyle(DS.ink)
                            Text("Send macOS Notification when market price drops to or below target")
                                .font(DS.caption)
                                .foregroundStyle(DS.inkTertiary)
                        }
                    }
                    .toggleStyle(.checkbox)

                    // Optional Note
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Purchase Plan / Reason (Optional)")
                            .font(DS.label)
                            .foregroundStyle(DS.inkSecondary)
                        TextField("e.g. Support level, P/E < 15, allocate 20%...", text: $note)
                            .font(DS.body)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Action Buttons
                    HStack(spacing: 10) {
                        if existingTarget != nil {
                            Button(role: .destructive) {
                                showDeleteConfirmation = true
                            } label: {
                                Text("Delete Target")
                                    .font(DS.caption)
                                    .foregroundStyle(DS.down)
                            }
                            .buttonStyle(.plain)
                            .pointingHandCursor()
                        }

                        Spacer()

                        Button("Cancel") {
                            onDismiss()
                        }
                        .buttonStyle(.plain)
                        .font(DS.body)
                        .foregroundStyle(DS.inkSecondary)
                        .pointingHandCursor()

                        PrimaryButton(title: "Save Target", enabled: parsedTargetPrice != nil) {
                            saveTarget()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                    .padding(.top, 4)
                } else {
                    // Search & Picker mode when symbol was not specified
                    searchField
                }
            }
        }
        .onAppear {
            if let sym = effectiveSymbol {
                prefillFor(sym)
            }
        }
        .confirmationDialog("Delete Buy Target?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            if let sym = effectiveSymbol {
                Button("Delete Target", role: .destructive) {
                    storageService.removeBuyTarget(for: sym)
                    onDismiss()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete the buy target for \(effectiveSymbol ?? "")?")
        }
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 10) {
            FieldBlock("Select Ticker") {
                DSTextField(placeholder: "Search symbol, name or crypto (e.g. AAPL, BTC-USD)",
                            text: $searchText,
                            isFocusedBinding: $searchFocused)
                    .onChange(of: searchText) { _, new in runSearch(new) }
            }

            if !searchResults.isEmpty {
                VStack(spacing: 0) {
                    ForEach(searchResults.prefix(6)) { r in
                        Button { select(result: r) } label: {
                            HStack(spacing: 8) {
                                SymbolLogo(symbol: r.symbol, size: 24)
                                Text(r.symbol).font(DS.figure).foregroundStyle(DS.ink)
                                Text(r.name).font(DS.caption).foregroundStyle(DS.inkTertiary).lineLimit(1)
                                Spacer()
                                Text(r.exchange).font(DS.micro).foregroundStyle(DS.inkTertiary)
                            }
                            .padding(.vertical, 7).padding(.horizontal, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        if r.id != searchResults.prefix(6).last?.id {
                            Divider().overlay(DS.hairline.opacity(0.6)).padding(.horizontal, 8)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.card))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.hairline))
            } else if searchText.isEmpty && !availableWatchlistSymbols.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("From your watchlist")
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(availableWatchlistSymbols, id: \.self) { sym in
                                Button { select(symbol: sym) } label: {
                                    HStack(spacing: 8) {
                                        SymbolLogo(symbol: sym, size: 22)
                                        Text(StockService.beautifiedSymbol(sym))
                                            .font(DS.figure)
                                            .foregroundStyle(DS.ink)
                                        if let name = stockService.quotes[sym]?.name, !name.isEmpty {
                                            Text(name)
                                                .font(DS.caption)
                                                .foregroundStyle(DS.inkTertiary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        if let q = stockService.quotes[sym] {
                                            let curr = StorageService.currencySymbol(for: q.currency)
                                            Text("\(curr)\(StorageService.formatNumber(q.effectivePrice, decimals: 2))")
                                                .font(DS.caption.monospacedDigit())
                                                .foregroundStyle(DS.inkSecondary)
                                        }
                                    }
                                    .padding(.vertical, 6)
                                    .padding(.horizontal, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .pointingHandCursor()
                                if sym != availableWatchlistSymbols.last {
                                    Divider().overlay(DS.hairline.opacity(0.6)).padding(.horizontal, 8)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DS.card))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.hairline))
                }
            }
        }
    }

    private func runSearch(_ q: String) {
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 1 else { searchResults = []; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            searchResults = await stockService.search(query: trimmed)
        }
    }

    private func select(result: SearchResult) {
        select(symbol: result.symbol)
    }

    private func select(symbol sym: String) {
        searchTask?.cancel()
        selectedSymbol = sym
        searchResults = []
        searchText = ""
        if stockService.quotes[sym] == nil {
            Task {
                await stockService.fetchQuotes(symbols: [sym])
                prefillFor(sym)
            }
        } else {
            prefillFor(sym)
        }
    }

    private func prefillFor(_ sym: String) {
        if let existing = storageService.buyTarget(for: sym) {
            let dec = storageService.resolvedPriceDecimals(symbol: sym, price: existing.targetPrice)
            targetPriceText = StorageService.formatNumber(existing.targetPrice, decimals: dec)
            note = existing.note ?? ""
            notifyWhenReached = existing.notifyWhenReached
        } else if currentPrice > 0 {
            let suggested = currentPrice * 0.95
            let dec = storageService.resolvedPriceDecimals(symbol: sym, price: suggested)
            targetPriceText = StorageService.formatNumber(suggested, decimals: dec)
        }
    }

    @ViewBuilder
    private func presetButton(_ label: String, percent: Double) -> some View {
        Button {
            applyPercent(percent)
        } label: {
            Text(label)
                .font(DS.micro)
                .fontWeight(.semibold)
                .foregroundStyle(DS.ink)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(Capsule().fill(DS.cardAlt))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private func applyPercent(_ percent: Double) {
        guard currentPrice > 0 else { return }
        let calculated = currentPrice * (1.0 + percent / 100.0)
        applyExactPrice(calculated)
    }

    private func applyExactPrice(_ price: Double) {
        guard let sym = effectiveSymbol else { return }
        let dec = storageService.resolvedPriceDecimals(symbol: sym, price: price)
        targetPriceText = StorageService.formatNumber(price, decimals: dec)
    }

    private func saveTarget() {
        guard let sym = effectiveSymbol, let price = parsedTargetPrice else { return }
        storageService.setBuyTarget(
            symbol: sym,
            targetPrice: price,
            note: note.isEmpty ? nil : note,
            notifyWhenReached: notifyWhenReached
        )
        onDismiss()
    }
}
