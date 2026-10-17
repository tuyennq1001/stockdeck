import SwiftUI

/// A card displaying regulatory insider transactions (SEC Form 4 for US equities and
/// SSC/Exchange disclosures for Vietnam equities) along with a 2-year net sentiment summary.
struct InsiderTradingCard: View {
    @ObservedObject var insiderService = InsiderTradingService.shared
    @ObservedObject var stockService = StockService.shared
    @EnvironmentObject var storageService: StorageService
    let symbol: String

    @State private var showInfoPopover: Bool = false
    private let lookbackMonths: Int = 60
    @State private var isExpanded: Bool = false

    struct GroupedTradeRow: Identifiable {
        let id: String
        let date: Date
        let ownerName: String
        let displayRole: String
        let transactionCode: String
        let isBuy: Bool
        let isPendingPlan: Bool
        let isRule10b51: Bool
        let isVNDisclosure: Bool
        let count: Int
        let totalShares: Double
        let totalValue: Double
        let effectivePrice: Double
        let sharesOwnedFollowing: Double
        let ownershipRatioAfter: Double?
        let transactionNote: String?
    }

    private var market: InsiderMarket {
        insiderService.market(for: symbol)
    }

    private var isVi: Bool {
        storageService.appLanguage.lowercased() == "vi"
    }

    private var cleanSym: String {
        insiderService.cleanSymbol(symbol)
    }

    private var isLoading: Bool {
        insiderService.loadingSymbols.contains(cleanSym)
    }

    private var allTransactions: [InsiderTransaction] {
        insiderService.transactions[cleanSym] ?? []
    }

    private var hasRule10b51Trades: Bool {
        allTransactions.contains(where: \.isRule10b51)
    }

    private var baseTransactions: [InsiderTransaction] {
        let pool = storageService.insiderOpenMarketOnly ? allTransactions.filter(\.isOpenMarket) : allTransactions
        if storageService.excludeInsider10b51 {
            return pool.filter { !$0.isRule10b51 }
        }
        return pool
    }

    private var groupedTransactions: [GroupedTradeRow] {
        let df = DateFormatter.secDate

        var groups: [String: [InsiderTransaction]] = [:]
        var order: [String] = []

        for tx in baseTransactions {
            let dayStr = df.string(from: tx.transactionDate)
            let key = "\(tx.ownerName)_\(dayStr)_\(tx.transactionCode)_\(tx.isRule10b51)_\(tx.isPendingPlan)"
            if groups[key] == nil {
                order.append(key)
            }
            groups[key, default: []].append(tx)
        }

        return order.compactMap { key -> GroupedTradeRow? in
            guard let txs = groups[key], let first = txs.first else { return nil }
            let count = txs.count
            let totalShares = txs.reduce(0.0) { $0 + $1.shares }

            let totalVal = txs.reduce(0.0) { sum, t in
                let p = insiderService.resolvedPrice(for: t, rawSymbol: symbol)
                let v = t.shares * p
                return sum + (v > 0 ? v : t.totalValue)
            }

            let effPrice = totalShares > 0 ? (totalVal / totalShares) : (first.price > 0 ? first.price : insiderService.resolvedPrice(for: first, rawSymbol: symbol))
            let last = txs.last ?? first

            return GroupedTradeRow(
                id: "\(first.id)_grouped_\(count)",
                date: first.transactionDate,
                ownerName: first.ownerName,
                displayRole: first.displayRole,
                transactionCode: first.transactionCode,
                isBuy: first.isBuy,
                isPendingPlan: first.isPendingPlan,
                isRule10b51: first.isRule10b51,
                isVNDisclosure: first.isVNDisclosure,
                count: count,
                totalShares: totalShares,
                totalValue: totalVal,
                effectivePrice: effPrice,
                sharesOwnedFollowing: last.sharesOwnedFollowing,
                ownershipRatioAfter: last.ownershipRatioAfter,
                transactionNote: first.transactionNote
            )
        }
    }

    private var activeSummary: InsiderSentimentSummary {
        let targetPool = baseTransactions.isEmpty ? (storageService.excludeInsider10b51 ? allTransactions.filter { !$0.isRule10b51 } : allTransactions) : baseTransactions
        return insiderService.computeSentiment(
            symbol: symbol,
            transactions: targetPool,
            lookbackMonths: lookbackMonths
        )
    }

    var body: some View {
        Group {
            if insiderService.shouldShowCard(for: symbol) {
                let groups = groupedTransactions
                let summary = activeSummary
                VStack(alignment: .leading, spacing: 12) {
                    headerRow

                    summaryCardView(summary)

                    filterBar

                    if groups.isEmpty && !allTransactions.isEmpty {
                        noOpenMarketNoticeView
                    } else {
                        transactionsListView(groups: groups)
                    }
                }
                .padding(14)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .premiumCard()
            }
        }
        .task(id: symbol) {
            await insiderService.ensureTransactions(for: symbol)
        }
    }

    // MARK: - Subviews

    private var headerRow: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "person.badge.shield.checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.brand)

                Text(isVi ? "Giao dịch nội bộ" : "Insider Trading")
                    .font(.inter(14, weight: .bold, relativeTo: .subheadline))
                    .foregroundStyle(DS.ink)

                if market == .vn {
                    Text(isVi ? "CBTT Nội bộ" : "Insider Filing")
                        .font(.inter(10, weight: .semibold, relativeTo: .caption2))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DS.cardAlt))
                        .foregroundStyle(DS.inkSecondary)
                } else {
                    Text(verbatim: "SEC Form 4")
                        .font(.inter(10, weight: .semibold, relativeTo: .caption2))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DS.cardAlt))
                        .foregroundStyle(DS.inkSecondary)
                }
            }

            Spacer()

            Button(action: { showInfoPopover.toggle() }) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.inkTertiary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showInfoPopover) {
                VStack(alignment: .leading, spacing: 6) {
                    if market == .vn {
                        Text(isVi ? "Giao dịch Cổ đông Nội bộ & Liên quan" : "Insider & Affiliated Disclosures")
                            .font(.inter(12, weight: .bold, relativeTo: .caption))
                            .foregroundStyle(DS.ink)
                        Text(isVi ? "Theo quy định CBTT trên sàn chứng khoán Việt Nam (HOSE/HNX/UPCoM), người nội bộ (HĐQT, Ban Giám đốc, BKS) và người có liên quan phải đăng ký trước khi giao dịch và báo cáo kết quả thực hiện. Chế độ Giao dịch mở lọc các giao dịch khớp lệnh và đăng ký mới (ẩn ESOP)."
                                  : "Under regulatory disclosure rules on Vietnam stock exchanges (HOSE/HNX/UPCoM), insiders (Board of Directors, Executives, Supervisory Board) and affiliated persons must pre-register before trading and disclose results. Open Market mode filters out ESOP transactions.")
                            .font(.inter(11, weight: .regular, relativeTo: .caption))
                            .foregroundStyle(DS.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(verbatim: "About SEC Form 4")
                            .font(.inter(12, weight: .bold, relativeTo: .caption))
                            .foregroundStyle(DS.ink)
                        Text(isVi ? "Theo quy định của SEC, các lãnh đạo doanh nghiệp, thành viên HĐQT và cổ đông sở hữu >10% phải báo cáo giao dịch trong vòng 2 ngày làm việc. Lệnh mua trên sàn (Mã P) phản ánh việc ban lãnh đạo trực tiếp đầu tư vào công ty."
                                  : "Under SEC rules, corporate officers, directors, and >10% owners must report trades within 2 business days. Open-market buys (Code P) reflect direct management investment.")
                            .font(.inter(11, weight: .regular, relativeTo: .caption))
                            .foregroundStyle(DS.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12)
                .frame(width: 260)
            }

            Button(action: {
                Task { await insiderService.ensureTransactions(for: symbol, force: true) }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.inkSecondary)
                    .rotationEffect(.degrees(isLoading ? 360 : 0))
                    .animation(isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isLoading)
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(isVi ? "Làm mới dữ liệu giao dịch nội bộ" : (market == .vn ? "Refresh disclosure filings" : "Refresh Form 4 filings"))
        }
    }

    private func sentimentLabel(_ s: InsiderSentimentSummary.Sentiment) -> String {
        if isVi {
            switch s {
            case .netBuying: return "Mua ròng"
            case .netSelling: return "Bán ròng"
            case .neutral: return "Trung lập"
            }
        }
        return s.rawValue
    }

    private func summaryCardView(_ s: InsiderSentimentSummary) -> some View {
        let color = sentimentColor(s.sentiment)
        let totalShares = s.totalBuyShares + s.totalSellShares

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text(isVi ? "Tổng quan 5 năm" : "5-Year Summary")
                    .font(.inter(11.5, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(DS.inkSecondary)

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: sentimentIcon(s.sentiment))
                        .font(.system(size: 9, weight: .bold))
                    Text(sentimentLabel(s.sentiment))
                        .font(.inter(10, weight: .bold, relativeTo: .caption2))
                }
                .foregroundStyle(color)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(
                    Capsule().fill(color.opacity(0.12))
                )
            }

            if totalShares > 0 {
                GeometryReader { geo in
                    let buyWidth = max(0, min(geo.size.width, geo.size.width * CGFloat(s.buyShareRatio)))
                    HStack(spacing: 2) {
                        if s.totalBuyShares > 0 {
                            Capsule()
                                .fill(DS.up)
                                .frame(width: s.totalSellShares > 0 ? max(6, buyWidth - 1) : geo.size.width, height: 5)
                        }
                        if s.totalSellShares > 0 {
                            Capsule()
                                .fill(DS.down)
                                .frame(maxWidth: .infinity, minHeight: 5, maxHeight: 5)
                        }
                    }
                }
                .frame(height: 5)
            }

            // Stat pills
            HStack(spacing: 8) {
                statPill(
                    title: isVi ? "Mua" : "Bought",
                    value: s.totalBuyValue,
                    count: s.buyCount,
                    color: DS.up
                )
                statPill(
                    title: isVi ? "Bán" : "Sold",
                    value: s.totalSellValue,
                    count: s.sellCount,
                    color: DS.down
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(DS.cardAlt)
        )
    }

    private func statPill(title: String, value: Double, count: Int, color: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.inter(10, weight: .medium, relativeTo: .caption2))
                        .foregroundStyle(DS.inkSecondary)
                    if count > 0 {
                        Text("(\(count))")
                            .font(.inter(9.5, weight: .regular, relativeTo: .caption2).monospacedDigit())
                            .foregroundStyle(DS.inkTertiary)
                    }
                }

                Text(formatDisplayValue(value))
                    .font(.inter(11.5, weight: .bold, relativeTo: .caption).monospacedDigit())
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.08))
        )
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Text(storageService.insiderOpenMarketOnly ? (isVi ? "Giao dịch mở" : "Open market") : (isVi ? "Tất cả hồ sơ" : "All filings"))
                    .font(.inter(10.5, weight: .medium, relativeTo: .caption))
                    .foregroundStyle(DS.inkSecondary)

                if storageService.excludeInsider10b51 {
                    Text("•")
                        .font(.inter(9, relativeTo: .caption))
                        .foregroundStyle(DS.inkTertiary)
                    Text(isVi ? "Loại trừ 10b5-1" : "Excl. 10b5-1")
                        .font(.inter(10.5, weight: .medium, relativeTo: .caption))
                        .foregroundStyle(DS.brand)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                Capsule().fill(DS.cardAlt)
            )

            Spacer()

            Text(isVi ? "\(groupedTransactions.count) giao dịch" : "\(groupedTransactions.count) trade\(groupedTransactions.count == 1 ? "" : "s")")
                .font(.inter(11, weight: .regular, relativeTo: .caption))
                .foregroundStyle(DS.inkTertiary)
        }
    }

    private var noOpenMarketNoticeView: some View {
        HStack(spacing: 6) {
            if storageService.excludeInsider10b51 && hasRule10b51Trades {
                Text(isVi ? "Chỉ có giao dịch theo kế hoạch tự động (đã lọc theo cài đặt)." : "Only Rule 10b5-1 trading plans recorded (excluded by Settings).")
                    .font(.inter(11, weight: .regular, relativeTo: .caption))
                    .foregroundStyle(DS.inkSecondary)
            } else {
                Text(market == .vn
                     ? (isVi ? "Chỉ có giao dịch ESOP trong 5 năm qua." : "Only ESOP transactions recorded in the past 5 years.")
                     : (isVi ? "Không có giao dịch mở nào trong 5 năm qua." : "No open-market trades in the past 5 years."))
                    .font(.inter(11, weight: .regular, relativeTo: .caption))
                    .foregroundStyle(DS.inkSecondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func displayedTransactions(from groups: [GroupedTradeRow]) -> [GroupedTradeRow] {
        isExpanded ? groups : Array(groups.prefix(8))
    }

    private func transactionsListView(groups: [GroupedTradeRow]) -> some View {
        let displayed = displayedTransactions(from: groups)
        return VStack(spacing: 6) {
            ForEach(displayed) { row in
                transactionRow(row)
                if row.id != displayed.last?.id {
                    Divider().opacity(0.5)
                }
            }

            if groups.count > 8 {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 4) {
                        Text(isExpanded ? (isVi ? "Thu gọn" : "Show less") : (isVi ? "Xem tất cả \(groups.count) giao dịch" : "Show all \(groups.count) transactions"))
                            .font(.inter(11, weight: .semibold, relativeTo: .caption))
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .foregroundStyle(DS.brand)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
    }

    private func transactionRow(_ row: GroupedTradeRow) -> some View {
        let badgeColor = row.isBuy ? DS.up : DS.down
        let badgeLabel: String = {
            if row.isPendingPlan {
                return row.isBuy ? (isVi ? "ĐK MUA" : "PLAN BUY") : (isVi ? "ĐK BÁN" : "PLAN SELL")
            }
            return row.isBuy ? (isVi ? "MUA" : "BUY") : (isVi ? "BÁN" : "SELL")
        }()

        let displayVal = formatDisplayValue(row.totalValue)
        let subtitle = priceAndOwnershipSubtitle(for: row)

        return HStack(alignment: .center, spacing: 8) {
            // Action badge, Date & 10b5-1 badge
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(badgeLabel)
                        .font(.inter(9.5, weight: .bold, relativeTo: .caption2))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(badgeColor.opacity(row.isPendingPlan ? 0.08 : 0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(badgeColor.opacity(row.isPendingPlan ? 0.45 : 0), lineWidth: 1)
                        )

                    if !row.isPendingPlan {
                        Text(row.transactionCode)
                            .font(.inter(9, weight: .bold, relativeTo: .caption2))
                            .foregroundStyle(DS.inkTertiary)
                    }
                }

                Text(row.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.inter(10, weight: .regular, relativeTo: .caption2))
                    .foregroundStyle(DS.inkTertiary)
            }
            .frame(width: 82, alignment: .leading)

            // Person details, Role/Relationship & Note
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(row.ownerName)
                        .font(.inter(12, weight: .semibold, relativeTo: .caption))
                        .foregroundStyle(DS.ink)
                        .lineLimit(1)

                    if row.isRule10b51 {
                        Text("10b5-1")
                            .font(.inter(8.5, weight: .bold, relativeTo: .caption2))
                            .foregroundStyle(DS.brand)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(
                                Capsule().fill(DS.brand.opacity(0.12))
                            )
                            .help(isVi ? "Giao dịch tự động định kỳ theo kế hoạch Rule 10b5-1" : "Pre-scheduled automated sale pursuant to a Rule 10b5-1 trading plan")
                    }

                    if row.count > 1 {
                        Text(isVi ? "(\(row.count) lệnh)" : "(\(row.count) orders)")
                            .font(.inter(9.5, weight: .medium, relativeTo: .caption2))
                            .foregroundStyle(DS.inkTertiary)
                    }
                }

                Text(localizedRole(row.displayRole))
                    .font(.inter(10, weight: .regular, relativeTo: .caption2))
                    .foregroundStyle(DS.inkSecondary)
                    .lineLimit(1)
                    .help(localizedRole(row.displayRole))

                if let note = row.transactionNote, !note.isEmpty {
                    Text(note)
                        .font(.inter(9.5, weight: .regular, relativeTo: .caption2))
                        .foregroundStyle(DS.inkTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // Monetary Value & Execution Price / Ownership
            VStack(alignment: .trailing, spacing: 2) {
                Text(displayVal)
                    .font(.inter(11.5, weight: .semibold, relativeTo: .caption).monospacedDigit())
                    .foregroundStyle(DS.ink)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.inter(10, weight: .regular, relativeTo: .caption2).monospacedDigit())
                        .foregroundStyle(DS.inkTertiary)
                }
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Helpers

    private func localizedRole(_ role: String) -> String {
        guard isVi else { return role }
        switch role {
        case "Director": return "Thành viên HĐQT"
        case "Officer": return "Cán bộ quản lý"
        case "10% Owner": return "Cổ đông lớn (>10%)"
        case "Insider": return "Người nội bộ"
        default: return role
        }
    }

    private func priceAndOwnershipSubtitle(for row: GroupedTradeRow) -> String? {
        if market == .vn {
            let priceStr = row.effectivePrice > 0 ? "@ \(formatPrice(row.effectivePrice))" : ""
            if let ratio = row.ownershipRatioAfter, ratio > 0 {
                let ratioStr = isVi ? "Sở hữu: \(String(format: "%.2f%%", ratio))" : "Holding: \(String(format: "%.2f%%", ratio))"
                return priceStr.isEmpty ? ratioStr : "\(priceStr) • \(ratioStr)"
            }
            if row.isPendingPlan {
                let planStr = isVi ? "Đang ĐK" : "Pending"
                let fullPlanStr = isVi ? "Đang đăng ký" : "Pending"
                return priceStr.isEmpty ? fullPlanStr : "\(priceStr) • \(planStr)"
            }
            return priceStr.isEmpty ? nil : priceStr
        } else {
            if row.effectivePrice > 0 {
                return "@ \(formatPrice(row.effectivePrice))"
            }
            return nil
        }
    }

    private func sentimentColor(_ s: InsiderSentimentSummary.Sentiment) -> Color {
        switch s {
        case .netBuying: return DS.up
        case .netSelling: return DS.down
        case .neutral: return DS.inkSecondary
        }
    }

    private func sentimentIcon(_ s: InsiderSentimentSummary.Sentiment) -> String {
        switch s {
        case .netBuying: return "arrow.up.right"
        case .netSelling: return "arrow.down.right"
        case .neutral: return "minus"
        }
    }

    private func formatDisplayValue(_ value: Double) -> String {
        guard value > 0 else { return "—" }
        if market == .vn {
            return formatVNDValue(value)
        } else {
            return formatCurrency(value)
        }
    }

    private func formatVNDValue(_ value: Double) -> String {
        let ty = value / 1_000_000_000.0
        if ty >= 1000.0 {
            return String(format: "%.1fK tỷ ₫", ty / 1000.0)
        } else if ty >= 1.0 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = "."
            formatter.maximumFractionDigits = ty >= 100 ? 0 : (ty >= 10 ? 1 : 2)
            let s = formatter.string(from: NSNumber(value: ty)) ?? String(format: "%.1f", ty)
            return "\(s) tỷ ₫"
        } else if value >= 1_000_000.0 {
            let tr = value / 1_000_000.0
            return String(format: "%.0f tr ₫", tr)
        } else {
            return "\(Int(value)) ₫"
        }
    }

    private func formatPrice(_ price: Double) -> String {
        if market == .vn {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = ","
            formatter.maximumFractionDigits = 0
            let s = formatter.string(from: NSNumber(value: Int(round(price)))) ?? "\(Int(round(price)))"
            return "₫\(s)"
        } else {
            return String(format: "$%.2f", price)
        }
    }

    private func formatCurrency(_ value: Double, signed: Bool = false) -> String {
        let prefix = signed && value > 0 ? "+" : ""
        let absVal = abs(value)
        if absVal >= 1_000_000_000 {
            return "\(prefix)$\(String(format: "%.2fB", value / 1_000_000_000))"
        } else if absVal >= 1_000_000 {
            return "\(prefix)$\(String(format: "%.2fM", value / 1_000_000))"
        } else if absVal >= 1_000 {
            return "\(prefix)$\(String(format: "%.1fK", value / 1_000))"
        }
        return "\(prefix)$\(String(format: "%.0f", value))"
    }
}
