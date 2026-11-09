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
                    leftHelp: "Tỷ số Giá / Lợi nhuận (12 tháng gần nhất). Đo lường mức định giá so với lợi nhuận kiếm được.",
                    rightLabel: "Forward P/E", rightValue: forwardPEText,
                    rightHelp: "Tỷ số Giá / Lợi nhuận dự phóng cho các quý tương lai."
                )
                rowDivider
                metricRow(
                    leftLabel: "P/B", leftValue: priceToBookText,
                    leftHelp: "Tỷ số Giá / Giá trị sổ sách. So sánh giá trị thị trường với giá trị tài sản ròng trên báo cáo.",
                    rightLabel: "Book Value", rightValue: bookValueText,
                    rightHelp: "Giá trị sổ sách trên mỗi cổ phiếu."
                )
                rowDivider
                metricRow(
                    leftLabel: "EPS (TTM)", leftValue: epsTrailingText,
                    leftHelp: "Lợi nhuận trên mỗi cổ phiếu trong 12 tháng gần nhất.",
                    rightLabel: "EPS (Forward)", rightValue: epsForwardText,
                    rightHelp: "Lợi nhuận dự phóng trên mỗi cổ phiếu cho các quý tương lai."
                )
                rowDivider
                metricRow(
                    leftLabel: "PEG", leftValue: pegText, leftLoading: isLoadingStats && keyStats == nil,
                    leftHelp: "P/E chia cho Tốc độ tăng trưởng EPS. PEG < 1 thường biểu thị cổ phiếu đang bị định giá thấp so với tiềm năng tăng trưởng.",
                    rightLabel: "EV/EBITDA", rightValue: evEbitdaText, rightLoading: isLoadingStats && keyStats == nil,
                    rightHelp: "Giá trị doanh nghiệp / Lợi nhuận trước lãi vay, thuế và khấu hao."
                )
                rowDivider
                metricRow(
                    leftLabel: "Div Yield", leftValue: dividendYieldText,
                    leftHelp: "Tỷ suất cổ tức = Cổ tức trả hàng năm / Giá cổ phiếu.",
                    rightLabel: "Market Cap", rightValue: marketCapText,
                    rightHelp: "Vốn hóa thị trường = Giá cổ phiếu × Tổng số cổ phiếu lưu hành."
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
        leftHelp: String? = nil,
        rightLabel: String,
        rightValue: String,
        rightLoading: Bool = false,
        rightHelp: String? = nil
    ) -> some View {
        HStack(spacing: 16) {
            metricCell(label: leftLabel, value: leftValue, isLoading: leftLoading, help: leftHelp)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
                .overlay(DS.hairline.opacity(0.6))
                .frame(height: 16)
            metricCell(label: rightLabel, value: rightValue, isLoading: rightLoading, help: rightHelp)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }

    private func metricCell(label: String, value: String, isLoading: Bool = false, help: String? = nil) -> some View {
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
        .contentShape(Rectangle())
        .help(help ?? "")
    }
}
