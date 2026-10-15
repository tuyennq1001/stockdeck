import SwiftUI

/// Displays fundamental valuation metrics for equities in a clean 2-column card layout.
/// Features P/E (TTM), Forward P/E, P/B, Book Value, EPS (TTM), EPS (Forward),
/// Dividend Yield, and Market Cap. Missing or non-applicable values are shown as "—".
struct ValuationCard: View {
    let quote: StockQuote

    private var currencySymbol: String {
        StorageService.currencySymbol(for: quote.currency)
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

    var body: some View {
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
        rightLabel: String,
        rightValue: String
    ) -> some View {
        HStack(spacing: 16) {
            metricCell(label: leftLabel, value: leftValue)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
                .overlay(DS.hairline.opacity(0.6))
                .frame(height: 16)
            metricCell(label: rightLabel, value: rightValue)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }

    private func metricCell(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: label)
                .font(DS.caption)
                .foregroundStyle(DS.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(verbatim: value)
                .font(DS.figure)
                .foregroundStyle(value == "—" ? DS.inkTertiary : DS.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }
}
