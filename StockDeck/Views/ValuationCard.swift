import SwiftUI

/// Displays fundamental valuation metrics for equities in a clean 2-column card layout.
/// Features P/E (TTM), Forward P/E, P/B, Book Value, EPS (TTM), EPS (Forward),
/// PEG, EV/EBITDA, Dividend Yield, and Market Cap. Missing values are shown as "—",
/// while background-loading stats show a subtle DSSpinner.
struct ValuationCard: View {
    let quote: StockQuote
    var keyStats: KeyStatistics? = nil
    var isLoadingStats: Bool = false

    private var currencySymbol: String {
        let isIndex = StockService.isIndexSymbol(quote.symbol)
        return isIndex ? "" : StorageService.currencySymbol(for: quote.currency)
    }

    private var trailingPEText: String {
        if let pe = quote.trailingPE, pe.isFinite, pe > 0 {
            return StorageService.formatNumber(pe, decimals: 2)
        }
        return "—"
    }

    private var forwardPEText: String {
        if let fpe = quote.forwardPE, fpe.isFinite, fpe > 0 {
            return StorageService.formatNumber(fpe, decimals: 2)
        }
        return "—"
    }

    private var priceToBookText: String {
        if let pb = quote.priceToBook, pb.isFinite, pb > 0 {
            return StorageService.formatNumber(pb, decimals: 2)
        }
        return "—"
    }

    private var bookValueText: String {
        if let bv = quote.bookValue, bv.isFinite {
            return StorageService.formatAmount(bv, symbol: currencySymbol, decimals: 2)
        }
        return "—"
    }

    private var epsTrailingText: String {
        if let eps = quote.epsTrailingTwelveMonths, eps.isFinite {
            return StorageService.formatAmount(eps, symbol: currencySymbol, decimals: 2)
        }
        return "—"
    }

    private var epsForwardText: String {
        if let feps = quote.epsForward, feps.isFinite {
            return StorageService.formatAmount(feps, symbol: currencySymbol, decimals: 2)
        }
        return "—"
    }

    private var pegText: String {
        if let peg = keyStats?.pegRatio, peg.isFinite {
            return StorageService.formatNumber(peg, decimals: 2)
        }
        return "—"
    }

    private var evEbitdaText: String {
        if let ev = keyStats?.enterpriseToEbitda, ev.isFinite {
            return StorageService.formatNumber(ev, decimals: 2)
        }
        return "—"
    }

    private var dividendYieldText: String {
        if let dy = quote.dividendYield, dy.isFinite, dy >= 0 {
            return "\(StorageService.formatNumber(dy, decimals: 2))%"
        }
        return "—"
    }

    private var marketCapText: String {
        if let mc = quote.marketCap, mc.isFinite, mc > 0 {
            return StorageService.formatMarketCap(mc, currency: quote.currency)
        }
        return "—"
    }

    private var isIndex: Bool {
        StockService.isIndexSymbol(quote.symbol)
    }

    private var tradingValueText: String {
        if let val = quote.regularMarketVolume, val.isFinite, val > 0 {
            let isVi = StorageService.shared.appLanguage == "vi"
            let sym = quote.symbol.uppercased()
            let curr: String
            if sym.contains("VNINDEX") || sym.contains("HNX") || sym.contains("UPINDEX") || sym.contains("UPCOM") || quote.currency.uppercased() == "PTS" || quote.currency.uppercased() == "VND" {
                curr = "VND"
            } else {
                curr = quote.currency
            }
            return StorageService.formatIndexTurnover(val, currency: curr, isVietnamese: isVi)
        }
        return "—"
    }

    var body: some View {
        if isIndex {
            indexCardContent
        } else {
            equityCardContent
        }
    }

    private var indexCardContent: some View {
        let isVi = StorageService.shared.appLanguage == "vi"
        return Card(title: isVi ? "Định giá thị trường" : "Market Valuation") {
            VStack(spacing: 0) {
                metricRow(
                    leftLabel: isVi ? "P/E Toàn sàn" : "Market P/E", leftValue: trailingPEText,
                    rightLabel: isVi ? "Giá trị giao dịch" : "Trading Value", rightValue: tradingValueText
                )
                if quote.priceToBook != nil || quote.marketCap != nil {
                    rowDivider
                    metricRow(
                        leftLabel: isVi ? "P/B Thị trường" : "Market P/B", leftValue: priceToBookText,
                        rightLabel: isVi ? "Vốn hóa thị trường" : "Market Cap", rightValue: marketCapText
                    )
                }
            }
        }
    }

    private var equityCardContent: some View {
        Card(title: "Valuation") {
            VStack(spacing: 0) {
                metricRow(
                    leftLabel: "P/E (TTM)", leftValue: trailingPEText,
                    rightLabel: "Forward P/E", rightValue: forwardPEText
                )
                rowDivider
                metricRow(
                    leftLabel: "P/B", leftValue: priceToBookText,
                    rightLabel: "Book Value", rightValue: bookValueText
                )
                rowDivider
                metricRow(
                    leftLabel: "EPS (TTM)", leftValue: epsTrailingText,
                    rightLabel: "EPS (Forward)", rightValue: epsForwardText
                )
                rowDivider
                metricRow(
                    leftLabel: "PEG", leftValue: pegText, leftLoading: isLoadingStats && keyStats == nil,
                    rightLabel: "EV/EBITDA", rightValue: evEbitdaText, rightLoading: isLoadingStats && keyStats == nil
                )
                rowDivider
                metricRow(
                    leftLabel: "Div Yield", leftValue: dividendYieldText,
                    rightLabel: "Market Cap", rightValue: marketCapText
                )
            }
        }
    }

    private var rowDivider: some View {
        Divider()
            .overlay(DS.hairline.opacity(0.6))
            .padding(.horizontal, 4)
    }

    private func metricRow(
        leftLabel: String,
        leftValue: String,
        leftLoading: Bool = false,
        rightLabel: String,
        rightValue: String,
        rightLoading: Bool = false
    ) -> some View {
        HStack(spacing: 16) {
            metricCell(label: leftLabel, value: leftValue, isLoading: leftLoading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
                .overlay(DS.hairline.opacity(0.6))
                .frame(height: 16)
            metricCell(label: rightLabel, value: rightValue, isLoading: rightLoading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }

    private func metricCell(label: String, value: String, isLoading: Bool = false) -> some View {
        HStack(alignment: .center) {
            Text(verbatim: label)
                .font(DS.caption)
                .foregroundStyle(DS.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            if isLoading {
                DSSpinner(size: 10)
                    .frame(height: 14)
            } else {
                Text(verbatim: value)
                    .font(DS.figure)
                    .foregroundStyle(value == "—" ? DS.inkTertiary : DS.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
    }
}
