import SwiftUI

/// Displays profitability and risk metrics (ROE, ROA, ROIC, Profit Margin, D/E, Beta)
/// in a clean 2-column card layout matching ValuationCard.
struct ProfitabilityRiskCard: View {
    let keyStats: KeyStatistics?
    let isLoadingStats: Bool

    var body: some View {
        Card(title: "Profitability & Risk") {
            VStack(spacing: 0) {
                metricRow(
                    leftLabel: "ROE",
                    leftValue: roeText,
                    leftLoading: isLoadingStats && keyStats == nil,
                    leftHelp: "Tỷ suất sinh lời trên vốn chủ sở hữu = Lợi nhuận ròng / Vốn chủ sở hữu.",
                    rightLabel: "ROA",
                    rightValue: roaText,
                    rightLoading: isLoadingStats && keyStats == nil,
                    rightHelp: "Tỷ suất sinh lời trên tổng tài sản = Lợi nhuận ròng / Tổng tài sản."
                )
                rowDivider
                metricRow(
                    leftLabel: "ROIC",
                    leftValue: roicText,
                    leftLoading: isLoadingStats && keyStats == nil,
                    leftHelp: "Tỷ suất sinh lời trên vốn đầu tư.",
                    rightLabel: "Profit Margin",
                    rightValue: marginText,
                    rightLoading: isLoadingStats && keyStats == nil,
                    rightHelp: "Biên lợi nhuận ròng = Lợi nhuận sau thuế / Doanh thu."
                )
                rowDivider
                metricRow(
                    leftLabel: "D/E",
                    leftValue: debtToEquityText,
                    leftLoading: isLoadingStats && keyStats == nil,
                    leftHelp: "Tỷ lệ Nợ / Vốn chủ sở hữu, thể hiện mức độ đòn bẩy tài chính.",
                    rightLabel: "Beta",
                    rightValue: betaText,
                    rightLoading: isLoadingStats && keyStats == nil,
                    rightHelp: "Hệ số biến động giá so với thị trường chung (S&P 500 = 1.0). Beta > 1: biến động mạnh hơn; Beta < 1: ít biến động hơn."
                )
            }
        }
    }

    private var roeText: String {
        if let roe = keyStats?.returnOnEquity, roe.isFinite {
            return "\(StorageService.formatNumber(roe, decimals: 2))%"
        }
        return "—"
    }

    private var roaText: String {
        if let roa = keyStats?.returnOnAssets, roa.isFinite {
            return "\(StorageService.formatNumber(roa, decimals: 2))%"
        }
        return "—"
    }

    private var roicText: String {
        if let roic = keyStats?.roic, roic.isFinite {
            return "\(StorageService.formatNumber(roic, decimals: 2))%"
        }
        return "—"
    }

    private var marginText: String {
        if let pm = keyStats?.profitMargins, pm.isFinite {
            return "\(StorageService.formatNumber(pm, decimals: 2))%"
        }
        return "—"
    }

    private var debtToEquityText: String {
        if let de = keyStats?.debtToEquity, de.isFinite, de >= 0 {
            return "\(StorageService.formatNumber(de, decimals: 2))%"
        }
        return "—"
    }

    private var betaText: String {
        if let b = keyStats?.beta, b.isFinite {
            return StorageService.formatNumber(b, decimals: 2)
        }
        return "—"
    }

    private var rowDivider: some View {
        Divider()
            .overlay(DS.hairline.opacity(0.6))
            .padding(.horizontal, 4)
    }

    private func metricRow(
        leftLabel: String,
        leftValue: String,
        leftLoading: Bool,
        leftHelp: String? = nil,
        rightLabel: String,
        rightValue: String,
        rightLoading: Bool,
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

    private func metricCell(label: String, value: String, isLoading: Bool, help: String? = nil) -> some View {
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
