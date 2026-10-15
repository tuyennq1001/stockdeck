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
                    rightLabel: "ROA",
                    rightValue: roaText,
                    rightLoading: isLoadingStats && keyStats == nil
                )
                rowDivider
                metricRow(
                    leftLabel: "ROIC",
                    leftValue: roicText,
                    leftLoading: isLoadingStats && keyStats == nil,
                    rightLabel: "Profit Margin",
                    rightValue: marginText,
                    rightLoading: isLoadingStats && keyStats == nil
                )
                rowDivider
                metricRow(
                    leftLabel: "D/E",
                    leftValue: debtToEquityText,
                    leftLoading: isLoadingStats && keyStats == nil,
                    rightLabel: "Beta",
                    rightValue: betaText,
                    rightLoading: isLoadingStats && keyStats == nil
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
        rightLabel: String,
        rightValue: String,
        rightLoading: Bool
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

    private func metricCell(label: String, value: String, isLoading: Bool) -> some View {
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
