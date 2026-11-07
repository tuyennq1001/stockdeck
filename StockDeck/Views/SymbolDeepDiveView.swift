import SwiftUI

/// Comprehensive financial and fundamental deep-dive view for a symbol in Superchart / Watchlist.
/// Displays valuation multiples, profitability & risk, historical alpha vs S&P 500 benchmark,
/// upcoming earnings, insider transactions, news, and notes.
struct SymbolDeepDiveView: View {
    let symbol: String
    @ObservedObject var stockService: StockService
    @ObservedObject var storageService: StorageService

    @State private var selectedCategory: Category = .all

    enum Category: String, CaseIterable, Identifiable {
        case all = "Tất cả"
        case valuation = "Định giá"
        case profitability = "Sinh lời & Rủi ro"
        case alpha = "Hiệu suất & Alpha"
        case highLowTarget = "Đỉnh/Đáy & Mục tiêu"
        case earnings = "Earnings"
        case insider = "Giao dịch nội bộ"
        case news = "Tin tức"
        case notes = "Ghi chú"

        var id: String { rawValue }
    }

    private var quote: StockQuote? {
        stockService.quotes[symbol]
    }

    private var keyStats: KeyStatistics? {
        stockService.keyStatistics[symbol]
    }

    private var isLoadingStats: Bool {
        stockService.loadingKeyStatsSymbols.contains(symbol)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                categoryPicker

                if let quote = quote {
                    if selectedCategory == .all || selectedCategory == .valuation {
                        if quote.hasValuationData {
                            ValuationCard(quote: quote, keyStats: keyStats, isLoadingStats: isLoadingStats)
                        }
                    }

                    if selectedCategory == .all || selectedCategory == .profitability {
                        if quote.hasValuationData && !StockService.isIndexSymbol(symbol) {
                            ProfitabilityRiskCard(keyStats: keyStats, isLoadingStats: isLoadingStats)
                        }
                    }

                    if selectedCategory == .all || selectedCategory == .alpha {
                        PerformanceAlphaMatrixCard(symbol: symbol, stockService: stockService)
                    }

                    if selectedCategory == .all || selectedCategory == .highLowTarget {
                        SymbolHighLowTargetCard(symbol: symbol, stockService: stockService, storageService: storageService)
                    }

                    if selectedCategory == .all || selectedCategory == .earnings {
                        EarningsCard(symbol: symbol)
                            .environmentObject(storageService)
                    }

                    if selectedCategory == .all || selectedCategory == .insider {
                        if InsiderTradingService.shared.shouldShowCard(for: symbol) {
                            InsiderTradingCard(symbol: symbol)
                                .environmentObject(storageService)
                        }
                    }

                    if selectedCategory == .all || selectedCategory == .news {
                        Card(title: "Tin tức liên quan") {
                            SymbolNewsCard(stockService: stockService, symbol: symbol)
                        }
                    }

                    if selectedCategory == .all || selectedCategory == .notes {
                        Card(title: "Ghi chú phân tích") {
                            SymbolNotesCard(storageService: storageService, symbol: symbol)
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Đang tải dữ liệu phân tích…")
                            .font(DS.caption)
                            .foregroundStyle(DS.inkSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(16)
        }
        .background(DS.ground)
        .task(id: symbol) {
            await stockService.ensurePriceHistory(for: symbol)
            await stockService.ensurePriceHistoryMax(for: symbol)
            await stockService.ensurePriceHistory(for: "^GSPC")
            await stockService.ensurePriceHistoryMax(for: "^GSPC")
            if quote?.hasValuationData != true {
                await stockService.ensureQuoteValuation(for: symbol)
            }
            await stockService.ensureKeyStatistics(for: symbol)
            if InsiderTradingService.shared.isEligibleSymbol(symbol) {
                await InsiderTradingService.shared.ensureTransactions(for: symbol)
            }
            await EarningsService.shared.ensureEarnings(for: symbol)
        }
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Category.allCases) { cat in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedCategory = cat
                        }
                    } label: {
                        Text(cat.rawValue)
                            .font(.inter(11, weight: selectedCategory == cat ? .semibold : .medium, relativeTo: .caption))
                            .foregroundStyle(selectedCategory == cat ? .white : DS.inkSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedCategory == cat ? DS.brand : DS.cardAlt)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// A card displaying a performance comparison matrix between the symbol and its natural market benchmark
/// (VN-Index for Vietnamese stocks, Nikkei 225 for Japanese stocks/funds, S&P 500 for US/global),
/// displaying Symbol, Benchmark, and Alpha as horizontal rows across 10 time periods.
struct PerformanceAlphaMatrixCard: View {
    let symbol: String
    @ObservedObject var stockService: StockService

    var body: some View {
        let benchmark = StockService.benchmarkSymbol(for: symbol)
        let symMetrics = SymbolPerformanceMetrics.compute(symbol: symbol, stockService: stockService)
        let benchMetrics = SymbolPerformanceMetrics.compute(symbol: benchmark.symbol, stockService: stockService)
        let periods = MetricPeriod.allCases

        Card(title: "So Sánh Hiệu Suất & Alpha vs \(benchmark.name)") {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // Header Row
                    HStack(spacing: 4) {
                        Text("Chỉ số")
                            .frame(width: 90, alignment: .leading)
                        ForEach(periods) { p in
                            Text(p.rawValue)
                                .frame(width: 62, alignment: .trailing)
                                .help(p.tooltip)
                        }
                    }
                    .font(.inter(10, weight: .bold, relativeTo: .caption2))
                    .foregroundStyle(DS.inkTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(DS.cardAlt.opacity(0.5))

                    Divider().overlay(DS.hairline)

                    // Row 1: Symbol
                    HStack(spacing: 4) {
                        Text(verbatim: symbol)
                            .font(.inter(11.5, weight: .bold, relativeTo: .caption))
                            .foregroundStyle(DS.ink)
                            .frame(width: 90, alignment: .leading)
                        ForEach(periods) { p in
                            let val = symMetrics.value(for: p)
                            cell(val)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)

                    Divider().overlay(DS.hairline.opacity(0.6))

                    // Row 2: Benchmark
                    HStack(spacing: 4) {
                        Text(verbatim: benchmark.name)
                            .font(.inter(11.5, weight: .medium, relativeTo: .caption))
                            .foregroundStyle(DS.inkSecondary)
                            .frame(width: 90, alignment: .leading)
                        ForEach(periods) { p in
                            let val = benchMetrics.value(for: p)
                            cell(val)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)

                    Divider().overlay(DS.hairline.opacity(0.6))

                    // Row 3: Alpha
                    HStack(spacing: 4) {
                        HStack(spacing: 3) {
                            Text(verbatim: "Alpha")
                                .font(.inter(11.5, weight: .bold, relativeTo: .caption))
                                .foregroundStyle(DS.brand)
                            Image(systemName: "info.circle")
                                .font(.system(size: 9))
                                .foregroundStyle(DS.inkTertiary)
                        }
                        .frame(width: 90, alignment: .leading)
                        .help("Alpha = % thay đổi của mã − % thay đổi của \(benchmark.name) trong cùng kỳ. Dương: tốt hơn thị trường; Âm: kém thị trường. Không điều chỉnh theo rủi ro (Beta).")

                        ForEach(periods) { p in
                            let symVal = symMetrics.value(for: p)
                            let benchVal = benchMetrics.value(for: p)
                            let alpha: Double? = {
                                guard let s = symVal, let b = benchVal else { return nil }
                                return s - b
                            }()
                            cell(alpha, isBold: true)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(DS.brand.opacity(0.04))
                }
                .frame(minWidth: 720)
            }
        }
        .task(id: benchmark.symbol) {
            await stockService.fetchQuotes(symbols: [benchmark.symbol])
            await stockService.ensurePriceHistory(for: benchmark.symbol)
            await stockService.ensureSparklines(for: [benchmark.symbol])
        }
    }

    private func cell(_ val: Double?, isBold: Bool = false) -> some View {
        Group {
            if let val = val, val.isFinite {
                let sign = val > 0 ? "+" : ""
                Text("\(sign)\(String(format: "%.2f", val))%")
                    .font(.inter(11, weight: isBold ? .bold : .medium, relativeTo: .caption).monospacedDigit())
                    .foregroundStyle(pnlColor(val))
            } else {
                Text("—")
                    .font(.inter(11, relativeTo: .caption))
                    .foregroundStyle(DS.inkTertiary)
                    .help("Chưa đủ dữ liệu lịch sử cho kỳ này")
            }
        }
        .frame(width: 62, alignment: .trailing)
    }

    private func pnlColor(_ val: Double?) -> Color {
        guard let val = val, val.isFinite else { return DS.inkTertiary }
        if val > 0 { return DS.up }
        if val < 0 { return DS.down }
        return DS.inkSecondary
    }
}

/// A card displaying historical High / Low prices (ATH, ATL, 52-Week range) and Buy Target metrics.
struct SymbolHighLowTargetCard: View {
    let symbol: String
    @ObservedObject var stockService: StockService
    @ObservedObject var storageService: StorageService

    var body: some View {
        let metrics = SymbolPerformanceMetrics.compute(symbol: symbol, stockService: stockService)
        let quote = stockService.quotes[symbol]
        let buyTarget = storageService.buyTarget(for: symbol)
        let currSym = quote.map { StockService.isIndexSymbol($0.symbol) ? "" : StorageService.currencySymbol(for: $0.currency) } ?? ""
        let priceDec = StorageService.priceDecimals(symbol: symbol, price: quote?.price ?? 0)

        Card(title: "Đỉnh / Đáy & Giá mục tiêu") {
            VStack(spacing: 12) {
                // ATH & ATL Row
                HStack(spacing: 12) {
                    // ATH block
                    statBlock(
                        title: "All-Time High (ATH)",
                        value: metrics.ath.map { "\(currSym)\(StorageService.formatNumber($0, decimals: priceDec))" } ?? "—",
                        subValue: metrics.fromAth.map { String(format: "%+.2f%%", $0) },
                        subColor: metrics.fromAth.map { DS.pnlColor($0) } ?? DS.inkTertiary,
                        help: "Mức giá cao nhất lịch sử. Phần trăm bên dưới thể hiện khoảng cách % từ ATH tới giá hiện tại (From ATH)."
                    )
                    Divider().frame(height: 36)
                    // ATL block
                    statBlock(
                        title: "All-Time Low (ATL)",
                        value: metrics.atl.map { "\(currSym)\(StorageService.formatNumber($0, decimals: priceDec))" } ?? "—",
                        subValue: metrics.fromAtl.map { String(format: "%+.2f%%", $0) },
                        subColor: metrics.fromAtl.map { DS.pnlColor($0) } ?? DS.inkTertiary,
                        help: "Mức giá thấp nhất lịch sử. Phần trăm bên dưới thể hiện mức tăng % từ ATL tới giá hiện tại (From ATL)."
                    )
                }

                Divider().overlay(DS.hairline.opacity(0.6))

                // 52-Week Range
                if let quote = quote, let low = quote.fiftyTwoWeekLow, let high = quote.fiftyTwoWeekHigh, let pos = quote.fiftyTwoWeekPosition {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Vùng giá 52 tuần (52-Week Range)")
                                .font(DS.caption)
                                .foregroundStyle(DS.inkSecondary)
                            Spacer()
                            Text("Vị trí: \(Int(pos * 100))%")
                                .font(DS.micro.monospacedDigit())
                                .foregroundStyle(DS.inkTertiary)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(DS.cardAlt).frame(height: 6)
                                Circle()
                                    .fill(DS.brand)
                                    .frame(width: 10, height: 10)
                                    .offset(x: CGFloat(pos) * max(0, geo.size.width - 10))
                            }
                            .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 12)

                        HStack {
                            Text("\(currSym)\(StorageService.formatNumber(low, decimals: priceDec))")
                                .font(DS.micro.monospacedDigit()).foregroundStyle(DS.inkSecondary)
                            Spacer()
                            Text("\(currSym)\(StorageService.formatNumber(high, decimals: priceDec))")
                                .font(DS.micro.monospacedDigit()).foregroundStyle(DS.inkSecondary)
                        }
                    }
                    .help("Biên độ dao động giá thấp nhất và cao nhất trong 52 tuần gần nhất. Chấm màu thể hiện vị trí của giá hiện tại trong vùng giá.")
                }

                Divider().overlay(DS.hairline.opacity(0.6))

                // Buy Target
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Giá mua mục tiêu (Buy Target)")
                            .font(DS.caption)
                            .foregroundStyle(DS.inkSecondary)
                        if let target = buyTarget {
                            let inZone = quote.map { target.isInBuyZone(currentPrice: $0.price) } ?? false
                            let dist = quote.flatMap { target.percentDistance(from: $0.price) }
                            HStack(spacing: 6) {
                                Text("\(currSym)\(StorageService.formatNumber(target.targetPrice, decimals: priceDec))")
                                    .font(DS.figure.monospacedDigit())
                                    .foregroundStyle(DS.ink)
                                if inZone {
                                    Text("🎯 Trong vùng mua")
                                        .font(.inter(10, weight: .bold, relativeTo: .caption))
                                        .foregroundStyle(DS.up)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(DS.up.opacity(0.12), in: Capsule())
                                } else if let d = dist {
                                    Text(String(format: "%+.2f%%", d))
                                        .font(.inter(10.5, weight: .medium, relativeTo: .caption).monospacedDigit())
                                        .foregroundStyle(DS.inkSecondary)
                                }
                            }
                        } else {
                            Text("Chưa cài đặt giá mục tiêu")
                                .font(DS.caption)
                                .foregroundStyle(DS.inkTertiary)
                        }
                    }
                    Spacer()
                }
                .help("Mức giá mua mục tiêu do bạn cài đặt. Đang trong vùng mua khi giá hiện tại ≤ giá mục tiêu.")
            }
        }
    }

    private func statBlock(title: String, value: String, subValue: String?, subColor: Color, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DS.caption)
                .foregroundStyle(DS.inkSecondary)
            HStack(spacing: 6) {
                Text(verbatim: value)
                    .font(DS.figure.monospacedDigit())
                    .foregroundStyle(DS.ink)
                if let sub = subValue {
                    Text(verbatim: sub)
                        .font(.inter(11, weight: .semibold, relativeTo: .caption).monospacedDigit())
                        .foregroundStyle(subColor)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help)
    }
}
