import SwiftUI

/// A card displaying SEC Form 4 insider transactions (buying & selling by officers, directors,
/// and major shareholders) along with 3-month net sentiment.
struct InsiderTradingCard: View {
    @ObservedObject var insiderService = InsiderTradingService.shared
    @EnvironmentObject var storageService: StorageService
    let symbol: String

    @State private var filterOpenMarket: Bool = true
    @State private var showInfoPopover: Bool = false
    private let lookbackMonths: Int = 24
    @State private var isExpanded: Bool = false

    private var isEligible: Bool {
        insiderService.isEligibleUSSymbol(symbol)
    }

    private var cleanSym: String {
        symbol.uppercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".US", with: "")
    }

    private var isLoading: Bool {
        insiderService.loadingSymbols.contains(cleanSym)
    }

    private var transactions: [InsiderTransaction] {
        let all = insiderService.transactions[cleanSym] ?? []
        return filterOpenMarket ? all.filter(\.isOpenMarket) : all
    }

    private var summary: InsiderSentimentSummary? {
        insiderService.sentiment[cleanSym]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow

            if !isEligible {
                nonUSNoticeView
            } else if isLoading && transactions.isEmpty {
                loadingView
            } else if transactions.isEmpty {
                emptyStateView
            } else {
                if let summary = summary {
                    summaryCardView(summary)
                }

                filterBar

                transactionsListView
            }
        }
        .padding(14)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .premiumCard()
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

                Text("SEC Form 4")
                    .font(.inter(10, weight: .semibold, relativeTo: .caption2))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DS.cardAlt))
                    .foregroundStyle(DS.inkSecondary)
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
                    Text("About SEC Form 4")
                        .font(.inter(12, weight: .bold, relativeTo: .caption))
                        .foregroundStyle(DS.ink)
                    Text("Under SEC rules, corporate officers, directors, and >10% owners must report trades within 2 business days. Open-market buys (Code P) reflect direct management investment.")
                        .font(.inter(11, weight: .regular, relativeTo: .caption))
                        .foregroundStyle(DS.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(width: 240)
            }

            if isEligible {
                Button(action: {
                    Task { await insiderService.ensureTransactions(for: symbol) }
                }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.inkSecondary)
                        .rotationEffect(.degrees(isLoading ? 360 : 0))
                        .animation(isLoading ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isLoading)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Refresh Form 4 filings")
            }
        }
    }

    private func summaryCardView(_ s: InsiderSentimentSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("2-Year Summary")
                    .font(.inter(11.5, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(DS.inkSecondary)
                Spacer()
            }

            // Stat pills
            HStack(spacing: 8) {
                statPill(
                    title: "Bought",
                    shares: s.totalBuyShares,
                    value: s.totalBuyValue,
                    color: DS.up
                )
                statPill(
                    title: "Sold",
                    shares: s.totalSellShares,
                    value: s.totalSellValue,
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

    private func statPill(title: String, shares: Double, value: Double, color: Color) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.inter(10, weight: .medium, relativeTo: .caption2))
                    .foregroundStyle(DS.inkSecondary)

                HStack(spacing: 4) {
                    Text(formatShares(shares))
                        .font(.inter(11, weight: .semibold, relativeTo: .caption).monospacedDigit())
                        .foregroundStyle(color)

                    if value > 0 {
                        Text("(\(formatCurrency(value)))")
                            .font(.inter(10, weight: .regular, relativeTo: .caption2))
                            .foregroundStyle(DS.inkTertiary)
                    }
                }
            }
            Spacer()
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
        HStack(alignment: .center, spacing: 8) {
            // Action badge
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(tx.isBuy ? "BUY" : "SELL")
                        .font(.inter(10, weight: .bold, relativeTo: .caption2))
                        .foregroundStyle(tx.isBuy ? DS.up : DS.down)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill((tx.isBuy ? DS.up : DS.down).opacity(0.12))
                        )

                    Text(tx.transactionCode)
                        .font(.inter(9, weight: .bold, relativeTo: .caption2))
                        .foregroundStyle(DS.inkTertiary)
                        .help(tx.codeDescription)
                }

                Text(tx.transactionDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.inter(10, weight: .regular, relativeTo: .caption2))
                    .foregroundStyle(DS.inkTertiary)
            }
            .frame(width: 75, alignment: .leading)

            // Person details
            VStack(alignment: .leading, spacing: 2) {
                Text(tx.ownerName)
                    .font(.inter(12, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(DS.ink)
                    .lineLimit(1)

                Text(tx.displayRole)
                    .font(.inter(10, weight: .regular, relativeTo: .caption2))
                    .foregroundStyle(DS.inkSecondary)
                    .lineLimit(1)
            }

            Spacer()

            // Volume and Value
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(formatShares(tx.shares)) shs")
                    .font(.inter(11, weight: .semibold, relativeTo: .caption).monospacedDigit())
                    .foregroundStyle(DS.ink)

                Text("@ \(formatCurrency(tx.price)) • \(formatCurrency(tx.totalValue))")
                    .font(.inter(10, weight: .regular, relativeTo: .caption2).monospacedDigit())
                    .foregroundStyle(DS.inkTertiary)
            }
        }
        .padding(.vertical, 3)
    }

    private var nonUSNoticeView: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe.americas.fill")
                .foregroundStyle(DS.inkTertiary)
            Text("SEC Form 4 insider reporting is available for US-listed securities.")
                .font(.inter(11, weight: .medium, relativeTo: .caption))
                .foregroundStyle(DS.inkSecondary)
        }
        .padding(.vertical, 8)
    }

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.6)
            Text("Loading Form 4 insider filings from SEC EDGAR…")
                .font(.inter(11, weight: .medium, relativeTo: .caption))
                .foregroundStyle(DS.inkSecondary)
        }
        .padding(.vertical, 12)
    }

    private var emptyStateView: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(DS.inkTertiary)
            Text("No Form 4 insider transactions recorded in the past 2 years.")
                .font(.inter(11, weight: .medium, relativeTo: .caption))
                .foregroundStyle(DS.inkSecondary)
        }
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func sentimentColor(_ s: InsiderSentimentSummary.Sentiment) -> Color {
        switch s {
        case .netBuying: return DS.up
        case .netSelling: return DS.down
        case .neutral: return DS.inkSecondary
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

    private func formatShares(_ shares: Double) -> String {
        if shares >= 1_000_000 {
            return String(format: "%.2fM", shares / 1_000_000)
        } else if shares >= 1_000 {
            return String(format: "%.1fK", shares / 1_000)
        }
        return String(format: "%.0f", shares)
    }
}
