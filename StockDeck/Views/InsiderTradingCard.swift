import SwiftUI

/// A card displaying regulatory insider transactions (SEC Form 4 for US equities and
/// SSC/Exchange disclosures for Vietnam equities) along with a 2-year net sentiment summary.
struct InsiderTradingCard: View {
    @ObservedObject var insiderService = InsiderTradingService.shared
    @ObservedObject var stockService = StockService.shared
    @EnvironmentObject var storageService: StorageService
    let symbol: String

    @State private var filterOpenMarket: Bool = true
    @State private var showInfoPopover: Bool = false
    private let lookbackMonths: Int = 24
    @State private var isExpanded: Bool = false

    private var market: InsiderMarket {
        insiderService.market(for: symbol)
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

    private var transactions: [InsiderTransaction] {
        filterOpenMarket ? allTransactions.filter(\.isOpenMarket) : allTransactions
    }

    private var activeSummary: InsiderSentimentSummary {
        let targetPool = transactions.isEmpty ? allTransactions : transactions
        return insiderService.computeSentiment(
            symbol: symbol,
            transactions: targetPool,
            lookbackMonths: lookbackMonths
        )
    }

    var body: some View {
        Group {
            if insiderService.shouldShowCard(for: symbol) {
                VStack(alignment: .leading, spacing: 12) {
                    headerRow

                    summaryCardView(activeSummary)

                    filterBar

                    if transactions.isEmpty && !allTransactions.isEmpty {
                        noOpenMarketNoticeView
                    } else {
                        transactionsListView
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

                Text("Insider Trading")
                    .font(.inter(14, weight: .bold, relativeTo: .subheadline))
                    .foregroundStyle(DS.ink)

                if market == .vn {
                    Text("CBTT Nội bộ")
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
                        Text("Giao dịch Cổ đông Nội bộ & Liên quan")
                            .font(.inter(12, weight: .bold, relativeTo: .caption))
                            .foregroundStyle(DS.ink)
                        Text("Theo quy định CBTT trên sàn chứng khoán Việt Nam (HOSE/HNX/UPCoM), người nội bộ (HĐQT, Ban Giám đốc, BKS) và người có liên quan phải đăng ký trước khi giao dịch và báo cáo kết quả thực hiện. Tab Open Market lọc các giao dịch trên sàn và đăng ký mới (ẩn ESOP).")
                            .font(.inter(11, weight: .regular, relativeTo: .caption))
                            .foregroundStyle(DS.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(verbatim: "About SEC Form 4")
                            .font(.inter(12, weight: .bold, relativeTo: .caption))
                            .foregroundStyle(DS.ink)
                        Text("Under SEC rules, corporate officers, directors, and >10% owners must report trades within 2 business days. Open-market buys (Code P) reflect direct management investment.")
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
            .help(market == .vn ? "Làm mới dữ liệu giao dịch nội bộ" : "Refresh Form 4 filings")
        }
    }

    private func summaryCardView(_ s: InsiderSentimentSummary) -> some View {
        let color = sentimentColor(s.sentiment)
        let totalShares = s.totalBuyShares + s.totalSellShares

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text("2-Year Summary")
                    .font(.inter(11.5, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(DS.inkSecondary)

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: sentimentIcon(s.sentiment))
                        .font(.system(size: 9, weight: .bold))
                    Text(s.sentiment.rawValue)
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
                    title: "Bought",
                    value: s.totalBuyValue,
                    count: s.buyCount,
                    color: DS.up
                )
                statPill(
                    title: "Sold",
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
        HStack {
            HStack(spacing: 4) {
                filterButton(title: "Open Market", active: filterOpenMarket) {
                    filterOpenMarket = true
                }
                filterButton(title: "All Filings", active: !filterOpenMarket) {
                    filterOpenMarket = false
                }
            }

            Spacer()

            Text("\(transactions.count) trade\(transactions.count == 1 ? "" : "s")")
                .font(.inter(11, weight: .regular, relativeTo: .caption))
                .foregroundStyle(DS.inkTertiary)
        }
    }

    private func filterButton(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.inter(11, weight: active ? .semibold : .regular, relativeTo: .caption))
                .foregroundStyle(active ? DS.ink : DS.inkTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(active ? DS.cardAlt : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    private var noOpenMarketNoticeView: some View {
        HStack(spacing: 6) {
            Text(market == .vn ? "Chỉ có giao dịch ESOP trong 2 năm qua." : "No open-market trades in the past 2 years.")
                .font(.inter(11, weight: .regular, relativeTo: .caption))
                .foregroundStyle(DS.inkSecondary)
            Button("Xem tất cả (\(allTransactions.count))") {
                filterOpenMarket = false
            }
            .font(.inter(11, weight: .semibold, relativeTo: .caption))
            .foregroundStyle(DS.brand)
            .buttonStyle(.plain)
            .pointingHandCursor()
        }
        .padding(.vertical, 6)
    }

    private var displayedTransactions: [InsiderTransaction] {
        isExpanded ? transactions : Array(transactions.prefix(8))
    }

    private var transactionsListView: some View {
        VStack(spacing: 6) {
            ForEach(displayedTransactions) { tx in
                transactionRow(tx)
                if tx.id != displayedTransactions.last?.id {
                    Divider().opacity(0.5)
                }
            }

            if transactions.count > 8 {
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isExpanded.toggle()
                    }
                }) {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "Show less" : "Show all \(transactions.count) transactions")
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

    private func transactionRow(_ tx: InsiderTransaction) -> some View {
        let badgeColor = tx.isBuy ? DS.up : DS.down
        let badgeLabel: String = {
            if tx.isPendingPlan {
                return tx.isBuy ? "ĐK MUA" : "ĐK BÁN"
            }
            return tx.isBuy ? "BUY" : "SELL"
        }()

        return HStack(alignment: .center, spacing: 8) {
            // Action badge & Date
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(badgeLabel)
                        .font(.inter(9.5, weight: .bold, relativeTo: .caption2))
                        .foregroundStyle(badgeColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(badgeColor.opacity(tx.isPendingPlan ? 0.08 : 0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(badgeColor.opacity(tx.isPendingPlan ? 0.45 : 0), lineWidth: 1)
                        )

                    if !tx.isPendingPlan {
                        Text(tx.transactionCode)
                            .font(.inter(9, weight: .bold, relativeTo: .caption2))
                            .foregroundStyle(DS.inkTertiary)
                            .help(tx.codeDescription)
                    }
                }

                Text(tx.transactionDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.inter(10, weight: .regular, relativeTo: .caption2))
                    .foregroundStyle(DS.inkTertiary)
            }
            .frame(width: 82, alignment: .leading)

            // Person details, Role/Relationship & Note
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.ownerName)
                    .font(.inter(12, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(DS.ink)
                    .lineLimit(1)

                Text(tx.displayRole)
                    .font(.inter(10, weight: .regular, relativeTo: .caption2))
                    .foregroundStyle(DS.inkSecondary)
                    .lineLimit(1)
                    .help(tx.displayRole)

                if let note = tx.transactionNote, !note.isEmpty {
                    Text(note)
                        .font(.inter(9.5, weight: .regular, relativeTo: .caption2))
                        .foregroundStyle(DS.inkTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // Monetary Value & Execution Price / Ownership
            let resolvedP = insiderService.resolvedPrice(for: tx, rawSymbol: symbol)
            let totalVal = tx.shares * resolvedP
            let displayVal = formatDisplayValue(totalVal > 0 ? totalVal : tx.totalValue)
            let subtitle = priceAndOwnershipSubtitle(for: tx, resolvedPrice: resolvedP)

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

    private func priceAndOwnershipSubtitle(for tx: InsiderTransaction, resolvedPrice: Double) -> String? {
        if market == .vn {
            let priceStr = resolvedPrice > 0 ? "@ \(formatPrice(resolvedPrice))" : ""
            if let ratio = tx.ownershipRatioAfter, ratio > 0 {
                let ratioStr = "Sở hữu: \(String(format: "%.2f%%", ratio))"
                return priceStr.isEmpty ? ratioStr : "\(priceStr) • \(ratioStr)"
            }
            if tx.isPendingPlan {
                return priceStr.isEmpty ? "Đang đăng ký" : "\(priceStr) • Đang ĐK"
            }
            return priceStr.isEmpty ? nil : priceStr
        } else {
            let effPrice = tx.price > 0 ? tx.price : resolvedPrice
            if effPrice > 0 {
                return "@ \(formatPrice(effPrice))"
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
