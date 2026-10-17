import SwiftUI

/// A card displaying upcoming earnings date, consensus EPS/revenue estimates,
/// session indicator (BMO / AMC), and a 4-quarter historical Beat/Miss track record.
struct EarningsCard: View {
    @ObservedObject var earningsService = EarningsService.shared
    @EnvironmentObject var storageService: StorageService
    let symbol: String

    private var cleanSym: String {
        EarningsService.cleanSymbol(symbol)
    }

    private var earningsItem: EarningsReportItem? {
        earningsService.getEarnings(for: cleanSym)
    }

    private var isLoading: Bool {
        earningsService.loadingSymbols.contains(cleanSym)
    }

    private var isVi: Bool {
        storageService.appLanguage.lowercased() == "vi"
    }

    var body: some View {
        if EarningsService.isEligible(symbol: symbol) {
            Card(title: isVi ? "Báo cáo tài chính (Earnings)" : "Earnings Report") {
                VStack(alignment: .leading, spacing: 12) {
                    if let item = earningsItem, item.hasData {
                        upcomingSection(item: item)

                        if !item.history.isEmpty {
                            Divider()
                                .opacity(0.6)
                            historySection(history: item.history)
                        }
                    } else if isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(isVi ? "Đang tải dữ liệu BCTC..." : "Loading earnings data...")
                                .font(DS.caption)
                                .foregroundStyle(DS.inkSecondary)
                        }
                        .padding(.vertical, 8)
                    } else {
                        HStack {
                            Text(isVi ? "Chưa có thông tin lịch công bố BCTC." : "No upcoming earnings date announced.")
                                .font(DS.caption)
                                .foregroundStyle(DS.inkTertiary)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
                .padding(.top, 2)
            }
            .task(id: symbol) {
                await earningsService.ensureEarnings(for: cleanSym)
            }
        }
    }

    // MARK: - Upcoming Section

    @ViewBuilder
    private func upcomingSection(item: EarningsReportItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                // Next Date Badge
                HStack(spacing: 5) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11, weight: .semibold))
                    Text(item.formattedDateRange(isVi: isVi))
                        .font(.inter(12, weight: .bold, relativeTo: .subheadline))
                }
                .foregroundStyle(DS.ink)

                // Countdown Pill
                if let days = item.daysUntilNextEarnings {
                    Text(item.countdownText(isVi: isVi))
                        .font(.inter(10, weight: .bold, relativeTo: .caption2))
                        .foregroundStyle(countdownForegroundColor(days: days))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(countdownBackgroundColor(days: days))
                        )
                }

                // Session Badge (BMO / AMC)
                if item.session != .unspecified {
                    Text(item.session.title(isVi: isVi))
                        .font(.inter(10, weight: .semibold, relativeTo: .caption2))
                        .foregroundStyle(item.session == .bmo ? Color.orange : Color.indigo)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill((item.session == .bmo ? Color.orange : Color.indigo).opacity(0.12))
                        )
                        .help(item.session == .bmo
                              ? (isVi ? "Công bố trước giờ mở cửa phiên chính (Before Market Open)" : "Reports Before Market Open")
                              : (isVi ? "Công bố sau giờ đóng cửa phiên chính (After Market Close)" : "Reports After Market Close"))
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            // Estimate Metrics Grid
            HStack(spacing: 16) {
                // EPS Consensus
                VStack(alignment: .leading, spacing: 2) {
                    Text(isVi ? "Dự báo EPS" : "EPS Estimate")
                        .font(.inter(10.5, weight: .medium, relativeTo: .caption2))
                        .foregroundStyle(DS.inkTertiary)
                    if let eps = item.epsEstimate {
                        Text(String(format: "$%.2f", eps))
                            .font(.inter(13, weight: .bold, relativeTo: .body))
                            .foregroundStyle(DS.ink)
                    } else {
                        Text("—")
                            .font(.inter(13, weight: .bold, relativeTo: .body))
                            .foregroundStyle(DS.inkTertiary)
                    }
                }
                .help(isVi ? "Lợi nhuận trên mỗi cổ phiếu (EPS) dự báo trung bình của các nhà phân tích cho kỳ tới" : "Average consensus EPS estimate from Wall Street analysts")

                Divider().frame(height: 24)

                // Revenue Consensus
                VStack(alignment: .leading, spacing: 2) {
                    Text(isVi ? "Dự báo Doanh thu" : "Revenue Estimate")
                        .font(.inter(10.5, weight: .medium, relativeTo: .caption2))
                        .foregroundStyle(DS.inkTertiary)
                    if let rev = item.revenueEstimate {
                        Text(formatRevenue(rev))
                            .font(.inter(13, weight: .bold, relativeTo: .body))
                            .foregroundStyle(DS.ink)
                    } else {
                        Text("—")
                            .font(.inter(13, weight: .bold, relativeTo: .body))
                            .foregroundStyle(DS.inkTertiary)
                    }
                }
                .help(isVi ? "Doanh thu dự báo trung bình của các nhà phân tích cho kỳ tới" : "Average consensus revenue estimate from Wall Street analysts")

                if let low = item.epsLow, let high = item.epsHigh, low != high {
                    Divider().frame(height: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(isVi ? "Khoảng dự báo EPS" : "EPS Range")
                            .font(.inter(10.5, weight: .medium, relativeTo: .caption2))
                            .foregroundStyle(DS.inkTertiary)
                        Text(String(format: "$%.2f – $%.2f", low, high))
                            .font(.inter(12, weight: .medium, relativeTo: .caption))
                            .foregroundStyle(DS.inkSecondary)
                    }
                    .help(isVi ? "Khoảng dự báo EPS thấp nhất đến cao nhất từ các nhà phân tích" : "Lowest to highest analyst EPS estimate range")
                }

                Spacer()
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Historical Track Record Section

    @ViewBuilder
    private func historySection(history: [EarningsQuarterResult]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(isVi ? "Lịch sử 4 quý gần nhất" : "Recent Quarters Performance")
                    .font(.inter(11, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(DS.inkSecondary)
                Spacer()
            }

            VStack(spacing: 0) {
                // Table Header (5 distinct columns)
                HStack(spacing: 4) {
                    Text(isVi ? "Quý" : "Quarter")
                        .frame(width: 48, alignment: .leading)
                    Text(isVi ? "Doanh thu" : "Revenue")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(isVi ? "Tổng doanh thu trong quý" : "Quarterly total revenue")
                    Text(isVi ? "Lợi nhuận" : "Net Income")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(isVi ? "Lợi nhuận ròng & Biên lợi nhuận ròng (%)" : "Net Income & Net Profit Margin (%)")
                    Text(verbatim: "EPS")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(isVi ? "Lợi nhuận trên mỗi cổ phiếu (Thực tế so với Dự báo)" : "Earnings Per Share (Actual vs Estimate)")
                    Text(isVi ? "So với dự báo" : "vs Est.")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(isVi ? "Mức vượt hoặc thấp hơn so với dự báo EPS của giới phân tích" : "EPS Actual vs Consensus Estimate Surprise %")
                }
                .font(.inter(9.5, weight: .semibold, relativeTo: .caption2))
                .foregroundStyle(DS.inkTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(DS.cardAlt.opacity(0.5))

                Divider().opacity(0.5)

                // Table Rows
                ForEach(history) { quarter in
                    quarterRow(quarter)
                    if quarter.id != history.last?.id {
                        Divider().opacity(0.3)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(DS.hairline, lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func quarterRow(_ q: EarningsQuarterResult) -> some View {
        HStack(spacing: 4) {
            // 1. Quarter
            Text(q.quarterFormatted)
                .font(.inter(10.5, weight: .bold, relativeTo: .caption2))
                .foregroundStyle(DS.ink)
                .lineLimit(1)
                .frame(width: 48, alignment: .leading)

            // 2. Revenue
            Text(q.revenue.map { formatRevenue($0) } ?? "—")
                .font(.inter(10, weight: .semibold, relativeTo: .caption2))
                .foregroundStyle(q.revenue != nil ? DS.ink : DS.inkTertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)

            // 3. Net Income & Margin
            VStack(alignment: .trailing, spacing: 1) {
                if let net = q.netIncome {
                    Text(formatRevenue(net))
                        .font(.inter(10, weight: .semibold, relativeTo: .caption2))
                        .foregroundStyle(net >= 0 ? DS.ink : DS.down)
                        .lineLimit(1)
                    if let margin = q.profitMarginFormatted {
                        Text(isVi ? "Biên \(margin)" : "Margin \(margin)")
                            .font(.inter(8, weight: .medium, relativeTo: .caption2))
                            .foregroundStyle(DS.inkTertiary)
                            .lineLimit(1)
                    }
                } else {
                    Text("—")
                        .font(.inter(10, weight: .regular, relativeTo: .caption2))
                        .foregroundStyle(DS.inkTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            // 4. EPS Actual vs Estimate
            VStack(alignment: .trailing, spacing: 1) {
                Text(q.epsActual.map { String(format: "$%.2f", $0) } ?? "—")
                    .font(.inter(10.5, weight: .bold, relativeTo: .caption2))
                    .foregroundStyle(DS.ink)
                    .lineLimit(1)
                if let est = q.epsEstimate {
                    Text(isVi ? String(format: "Dự báo: $%.2f", est) : String(format: "Est: $%.2f", est))
                        .font(.inter(8, weight: .medium, relativeTo: .caption2))
                        .foregroundStyle(DS.inkTertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

            // 5. Beat / Miss Badge with tooltip
            beatMissBadge(q)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func beatMissBadge(_ q: EarningsQuarterResult) -> some View {
        let tooltip: String = {
            let actStr = q.epsActual.map { String(format: "$%.2f", $0) } ?? "—"
            let estStr = q.epsEstimate.map { String(format: "$%.2f", $0) } ?? "—"
            switch q.beatMiss {
            case .beat:
                return isVi
                    ? "Vượt kỳ vọng \(q.surprisePercentFormatted) (Thực tế: \(actStr) so với Dự báo: \(estStr))"
                    : "Beat consensus by \(q.surprisePercentFormatted) (Actual: \(actStr) vs Est: \(estStr))"
            case .miss:
                return isVi
                    ? "Hụt kỳ vọng \(q.surprisePercentFormatted) (Thực tế: \(actStr) so với Dự báo: \(estStr))"
                    : "Missed consensus by \(q.surprisePercentFormatted) (Actual: \(actStr) vs Est: \(estStr))"
            case .inLine:
                return isVi
                    ? "Đạt đúng kỳ vọng (Thực tế: \(actStr) vs Dự báo: \(estStr))"
                    : "Matched consensus (Actual: \(actStr) vs Est: \(estStr))"
            case .unknown:
                return isVi ? "Chưa có dữ liệu so sánh" : "No consensus estimate data"
            }
        }()

        Group {
            switch q.beatMiss {
            case .beat:
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 7.5, weight: .bold))
                    Text(q.surprisePercentFormatted)
                        .font(.inter(9, weight: .bold, relativeTo: .caption2))
                        .lineLimit(1)
                }
                .foregroundStyle(DS.up)
                .padding(.horizontal, 4.5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(DS.up.opacity(0.12)))

            case .miss:
                HStack(spacing: 2) {
                    Image(systemName: "arrow.down.right")
                        .font(.system(size: 7.5, weight: .bold))
                    Text(q.surprisePercentFormatted)
                        .font(.inter(9, weight: .bold, relativeTo: .caption2))
                        .lineLimit(1)
                }
                .foregroundStyle(DS.down)
                .padding(.horizontal, 4.5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(DS.down.opacity(0.12)))

            case .inLine:
                Text(q.beatMiss.title(isVi: isVi))
                    .font(.inter(8.5, weight: .medium, relativeTo: .caption2))
                    .foregroundStyle(DS.inkSecondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(DS.cardAlt))

            case .unknown:
                Text("—")
                    .font(.inter(9, weight: .regular, relativeTo: .caption2))
                    .foregroundStyle(DS.inkTertiary)
            }
        }
        .help(tooltip)
    }

    // MARK: - Helpers

    private func formatRevenue(_ val: Double) -> String {
        if val >= 1_000_000_000_000 {
            return String(format: "$%.2fT", val / 1_000_000_000_000.0)
        } else if val >= 1_000_000_000 {
            return String(format: "$%.2fB", val / 1_000_000_000.0)
        } else if val >= 1_000_000 {
            return String(format: "$%.2fM", val / 1_000_000.0)
        } else if val >= -1_000_000 && val < 0 {
            return String(format: "-$%.0f", abs(val))
        } else if val <= -1_000_000_000 {
            return String(format: "-$%.2fB", abs(val) / 1_000_000_000.0)
        } else if val <= -1_000_000 {
            return String(format: "-$%.2fM", abs(val) / 1_000_000.0)
        } else {
            return String(format: "$%.0f", val)
        }
    }

    private func countdownForegroundColor(days: Int) -> Color {
        if days == 0 {
            return Color.red
        } else if days == 1 || days == 2 {
            return Color.orange
        } else {
            return DS.brand
        }
    }

    private func countdownBackgroundColor(days: Int) -> Color {
        if days == 0 {
            return Color.red.opacity(0.12)
        } else if days == 1 || days == 2 {
            return Color.orange.opacity(0.12)
        } else {
            return DS.brand.opacity(0.10)
        }
    }
}

/// A compact pill badge displayed next to symbols in tables when an earnings report is approaching.
struct UpcomingEarningsBadge: View {
    @State private var item: EarningsReportItem?
    @EnvironmentObject var storageService: StorageService
    let symbol: String

    private var cleanSym: String {
        EarningsService.cleanSymbol(symbol)
    }

    private var isVi: Bool {
        storageService.appLanguage.lowercased() == "vi"
    }

    var body: some View {
        Group {
            if let item = item, item.isUpcoming(withinDays: 5) {
                HStack(spacing: 2.5) {
                    Image(systemName: "calendar")
                        .font(.system(size: 7.5, weight: .bold))
                    Text(item.countdownText(isVi: isVi).uppercased())
                        .font(.inter(7.5, weight: .bold, relativeTo: .caption2))
                }
                .foregroundStyle(item.isToday ? Color.red : Color.orange)
                .padding(.horizontal, 3.5)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill((item.isToday ? Color.red : Color.orange).opacity(0.12))
                )
                .help(isVi ? "Công bố BCTC: \(item.shortDateFormatted(isVi: true))" : "Earnings announcement: \(item.shortDateFormatted(isVi: false))")
            }
        }
        .onAppear {
            item = EarningsService.shared.getEarnings(for: cleanSym)
        }
        .onReceive(EarningsService.shared.$earnings) { earnings in
            let newItem = earnings[cleanSym]
            if newItem != item {
                item = newItem
            }
        }
    }
}
