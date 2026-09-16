import SwiftUI

/// Full chart view for any symbol inside the menu bar popover and desktop windows:
/// compact header (< Back, SymbolLogo, Ticker, Name, Add to Portfolio, Refresh),
/// native price chart card without style picker, 52-week range, day facts, notes, and news.
struct SymbolDetailView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    let symbol: String
    var onAddToPortfolio: (UUID) -> Void = { _ in }
    let onDismiss: () -> Void

    @State private var selectedNewsArticle: NewsArticle?

    private var quote: StockQuote? { stockService.quotes[symbol] }

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
                detailContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.ground)
        .task(id: symbol) {
            await stockService.ensurePriceHistory(for: symbol)
        }
    }

    private var detailContent: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if let quote {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.gap) {
                        PriceChartCard(symbol: symbol, quote: quote, chartHeight: 240, showStylePicker: false)
                        if storageService.show52WeekBar {
                            fiftyTwoWeekCard(quote)
                        }
                        factsCard(quote)
                        SymbolNotesCard(storageService: storageService, symbol: symbol)
                        SymbolNewsCard(
                            stockService: stockService,
                            symbol: symbol,
                            onSelectArticle: { article in
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    selectedNewsArticle = article
                                }
                            }
                        )
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                }
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView()
                    Text("Đang tải dữ liệu...")
                        .font(DS.caption)
                        .foregroundStyle(DS.inkSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onDismiss) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                    Text("Back")
                        .font(.inter(12, weight: .medium, relativeTo: .body))
                }
                .foregroundStyle(DS.brand)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .keyboardShortcut(.cancelAction)

            Divider().frame(height: 14)

            SymbolLogo(symbol: symbol, size: 22)

            let isJpFund = (quote?.isJapaneseFund ?? false) || stockService.isJapaneseMutualFund(symbol)
            let isDisplayAsset = StockService.isDisplayNameAsset(symbol)
            let titleText = (isJpFund || isDisplayAsset) ? (quote?.displayName ?? StockService.beautifiedSymbol(symbol)) : (StockService.codeToFundNameMap[symbol] ?? StockService.beautifiedSymbol(symbol))
            let subTitleText = isDisplayAsset ? symbol : (quote?.name ?? "")

            VStack(alignment: .leading, spacing: 0) {
                Text(titleText)
                    .font(.inter(13, weight: .bold, relativeTo: .headline))
                    .tracking(-0.2)
                    .foregroundStyle(DS.ink)
                    .lineLimit(1)
                if !subTitleText.isEmpty {
                    Text(subTitleText)
                        .font(.inter(10, weight: .regular, relativeTo: .caption2))
                        .foregroundStyle(DS.inkTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if !storageService.portfolios.isEmpty {
                DSMenu(width: 200, sections: [storageService.portfolios.map { p in
                    DSMenuAction(title: p.name, icon: "briefcase") { onAddToPortfolio(p.id) }
                }]) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                        Text("Portfolio").font(.inter(11, weight: .semibold, relativeTo: .caption))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(DS.brand))
                }
                .pointingHandCursor()
                .help("Add this stock as a position in a portfolio")
            }

            Button(action: {
                Task {
                    await stockService.refreshAll(storageService: storageService)
                    await stockService.ensurePriceHistory(for: symbol)
                }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.inter(12, relativeTo: .callout))
                    .foregroundStyle(DS.inkSecondary)
            }
            .buttonStyle(.plain)
            .disabled(stockService.isLoading)
            .pointingHandCursor()
            .help("Refresh quotes")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder private func fiftyTwoWeekCard(_ quote: StockQuote) -> some View {
        if let pos = quote.fiftyTwoWeekPosition,
           let low = quote.fiftyTwoWeekLow, let high = quote.fiftyTwoWeekHigh {
            let priceSymbol = StorageService.currencySymbol(for: quote.currency)
            Card(title: "52-week range") {
                VStack(spacing: 10) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.cardAlt).frame(height: 6)
                            Circle()
                                .fill(.white)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().strokeBorder(DS.brand, lineWidth: 2))
                                .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                                .offset(x: CGFloat(pos) * (geo.size.width - 10))
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

    private func factsCard(_ quote: StockQuote) -> some View {
        Card(title: "Today") {
            VStack(spacing: 0) {
                if let low = quote.dayLow, let high = quote.dayHigh {
                    factRow("Day range", "\(StorageService.formatNumber(low, decimals: 2)) – \(StorageService.formatNumber(high, decimals: 2))")
                    divider
                }
                factRow("Currency", quote.currency)
                if quote.isExtendedHours, !quote.marketStateLabel.isEmpty {
                    divider
                    factRow("Session", quote.marketStateLabel)
                }
            }
        }
    }

    private var divider: some View {
        Divider().overlay(DS.hairline.opacity(0.6)).padding(.horizontal, 8)
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(label)).font(DS.caption).foregroundStyle(DS.inkSecondary)
            Spacer()
            Text(value).font(DS.figure).foregroundStyle(DS.ink)
        }
        .padding(.vertical, 8)
    }
}

/// Backwards compatibility alias if referenced anywhere
typealias SymbolDetailSheet = SymbolDetailView
