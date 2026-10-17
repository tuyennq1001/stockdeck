import SwiftUI

/// Main Earnings Calendar desktop view (under Utilities in Sidebar):
/// provides a split-view (Master Timeline + Inspector Panel) of upcoming earnings announcements
/// for all eligible equities tracked in user's portfolios and watchlists.
struct EarningsCalendarView: View {
    @ObservedObject var earningsService = EarningsService.shared
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService

    enum SourceFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case portfolios = "Portfolios"
        case watchlists = "Watchlists"

        var id: String { rawValue }

        func title(isVi: Bool) -> String {
            switch self {
            case .all: return isVi ? "Tất cả" : "All"
            case .portfolios: return isVi ? "Danh mục" : "Portfolios"
            case .watchlists: return isVi ? "Watchlist" : "Watchlists"
            }
        }
    }

    @State private var selectedFilter: SourceFilter = .all
    @State private var selectedSymbol: String? = nil
    @State private var isRefreshing: Bool = false

    private var isVi: Bool {
        storageService.appLanguage.lowercased() == "vi"
    }

    // MARK: - Symbol Aggregation & Deterministic Filtering

    private var portfolioSymbols: Set<String> {
        Set(storageService.portfolios.flatMap { $0.holdings.map(\.symbol) })
    }

    private var watchlistSymbols: Set<String> {
        Set(storageService.watchlists.flatMap(\.symbols))
    }

    private var targetSymbols: [String] {
        let pool: Set<String>
        switch selectedFilter {
        case .all:
            pool = portfolioSymbols.union(watchlistSymbols)
        case .portfolios:
            pool = portfolioSymbols
        case .watchlists:
            pool = watchlistSymbols
        }
        return pool.filter { EarningsService.isEligible(symbol: $0) }.sorted()
    }

    /// Sorted list of earnings items that have an upcoming report date.
    /// Uses symbol as tie-breaker to ensure 100% stable sorting and eliminate UI flickering.
    private var scheduledEarnings: [EarningsReportItem] {
        let items: [EarningsReportItem] = targetSymbols.compactMap { sym in
            let clean = EarningsService.cleanSymbol(sym)
            guard let item = earningsService.getEarnings(for: clean),
                  item.hasUpcomingDate,
                  let days = item.daysUntilNextEarnings,
                  days >= 0 else {
                return nil
            }
            return item
        }
        return items.sorted { a, b in
            guard let da = a.nextDate, let db = b.nextDate else {
                return a.symbol < b.symbol
            }
            if da != db {
                return da < db
            }
            return a.symbol < b.symbol
        }
    }

    private var activeSelectedItem: EarningsReportItem? {
        if let selectedSymbol,
           let match = scheduledEarnings.first(where: { $0.symbol == selectedSymbol }) {
            return match
        }
        return scheduledEarnings.first
    }

    // MARK: - Timeline Groups

    private var todayItems: [EarningsReportItem] {
        scheduledEarnings.filter { $0.isToday }
    }

    private var thisWeekItems: [EarningsReportItem] {
        scheduledEarnings.filter { item in
            guard let days = item.daysUntilNextEarnings else { return false }
            return days > 0 && days <= 7
        }
    }

    private var nextWeekItems: [EarningsReportItem] {
        scheduledEarnings.filter { item in
            guard let days = item.daysUntilNextEarnings else { return false }
            return days > 7 && days <= 14
        }
    }

    private var laterItems: [EarningsReportItem] {
        scheduledEarnings.filter { item in
            guard let days = item.daysUntilNextEarnings else { return false }
            return days > 14
        }
    }

    // MARK: - Body

    var body: some View {
        PageScaffold(
            isVi ? "Lịch BCTC" : "Earnings Calendar",
            caption: isVi ? "Lịch công bố báo cáo tài chính của danh mục & watchlist." : "Upcoming earnings announcements for your portfolios & watchlists.",
            trailing: {
                HStack(spacing: 12) {
                    sourcePicker
                    RefreshButton(isLoading: isRefreshing || !earningsService.loadingSymbols.isEmpty) {
                        refreshData(force: true)
                    }
                }
            }
        ) {
            Group {
                if scheduledEarnings.isEmpty && (!earningsService.loadingSymbols.isEmpty || isRefreshing) {
                    loadingPlaceholder
                } else if scheduledEarnings.isEmpty {
                    emptyStateView
                } else {
                    splitCalendarView
                }
            }
            .pageColumn()
        }
        .task(id: selectedFilter) {
            await loadDataIfNeeded()
        }
        .onChange(of: scheduledEarnings) { _, newEarnings in
            if selectedSymbol == nil || !newEarnings.contains(where: { $0.symbol == selectedSymbol }) {
                selectedSymbol = newEarnings.first?.symbol
            }
        }
    }

    // MARK: - Subviews

    private var sourcePicker: some View {
        HStack(spacing: 2) {
            ForEach(SourceFilter.allCases) { filter in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedFilter = filter
                    }
                } label: {
                    Text(filter.title(isVi: isVi))
                        .font(.inter(11.5, weight: selectedFilter == filter ? .bold : .medium, relativeTo: .caption))
                        .foregroundStyle(selectedFilter == filter ? DS.brand : DS.inkSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(selectedFilter == filter ? DS.brand.opacity(0.12) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(DS.cardAlt))
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.regular)
            Text(isVi ? "Đang cập nhật lịch BCTC..." : "Fetching earnings calendar...")
                .font(DS.caption)
                .foregroundStyle(DS.inkSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 36))
                .foregroundStyle(DS.inkTertiary)
            Text(isVi ? "Không có lịch BCTC sắp tới" : "No Upcoming Earnings Announced")
                .font(.inter(14, weight: .bold, relativeTo: .headline))
                .foregroundStyle(DS.ink)
            Text(isVi ? "Các mã trong danh mục hoặc watchlist chưa công bố ngày báo cáo trong thời gian tới."
                      : "None of the equities currently tracked in your portfolios or watchlists have confirmed dates.")
                .font(DS.caption)
                .foregroundStyle(DS.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Split View (Master Timeline + Detail Inspector)

    private var splitCalendarView: some View {
        HStack(alignment: .top, spacing: 16) {
            // Master: Calendar Timeline List
            VStack(alignment: .leading, spacing: 8) {
                columnHeaderBar

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !todayItems.isEmpty {
                            timelineSection(
                                title: isVi ? "Hôm nay" : "Today",
                                icon: "flame.fill",
                                iconColor: .red,
                                items: todayItems
                            )
                        }

                        if !thisWeekItems.isEmpty {
                            timelineSection(
                                title: isVi ? "Tuần này" : "This Week",
                                icon: "calendar.circle.fill",
                                iconColor: .orange,
                                items: thisWeekItems
                            )
                        }

                        if !nextWeekItems.isEmpty {
                            timelineSection(
                                title: isVi ? "Tuần tới" : "Next Week",
                                icon: "calendar",
                                iconColor: .blue,
                                items: nextWeekItems
                            )
                        }

                        if !laterItems.isEmpty {
                            timelineSection(
                                title: isVi ? "Sắp tới" : "Later",
                                icon: "clock.arrow.circlepath",
                                iconColor: DS.inkSecondary,
                                items: laterItems
                            )
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity)

            // Detail: Right Inspector Panel
            inspectorPanel
                .frame(width: 380)
        }
    }

    private var columnHeaderBar: some View {
        HStack(spacing: 8) {
            Text(isVi ? "MÃ & CÔNG TY" : "SYMBOL")
                .frame(minWidth: 140, alignment: .leading)

            Spacer()

            Text(isVi ? "NGÀY & PHIÊN" : "DATE & SESSION")
                .frame(minWidth: 95, alignment: .trailing)

            Text(isVi ? "DỰ BÁO KỲ TỚI" : "NEXT ESTIMATE")
                .frame(minWidth: 85, alignment: .trailing)
                .help(isVi ? "EPS & Doanh thu ước tính đồng thuận từ các nhà phân tích" : "Consensus EPS & Revenue estimates")

            Text(isVi ? "QUÝ TRƯỚC" : "PRIOR")
                .frame(width: 65, alignment: .trailing)
                .help(isVi ? "Kết quả Surprise (Beat / Miss) của kỳ báo cáo liền trước" : "Surprise % from the most recent reported quarter")
        }
        .font(.inter(9.5, weight: .bold, relativeTo: .caption2))
        .foregroundStyle(DS.inkTertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(DS.cardAlt.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func timelineSection(
        title: String,
        icon: String,
        iconColor: Color,
        items: [EarningsReportItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section Header
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.inter(13, weight: .bold, relativeTo: .headline))
                    .foregroundStyle(DS.ink)
                Text("(\(items.count))")
                    .font(.inter(11.5, weight: .medium, relativeTo: .caption))
                    .foregroundStyle(DS.inkTertiary)
                Spacer()
            }
            .padding(.horizontal, 4)

            // Rows Container
            VStack(spacing: 1) {
                ForEach(items) { item in
                    calendarRow(item)
                }
            }
            .background(DS.cardAlt.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(DS.hairline, lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func calendarRow(_ item: EarningsReportItem) -> some View {
        let isSelected = activeSelectedItem?.symbol == item.symbol

        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedSymbol = item.symbol
            }
        } label: {
            HStack(spacing: 10) {
                // Logo & Symbol Info
                SymbolLogo(symbol: item.symbol, size: 26)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(item.symbol)
                            .font(.inter(12.5, weight: .bold, relativeTo: .body))
                            .foregroundStyle(DS.ink)

                        sourceBadge(for: item.symbol)
                    }

                    let quote = stockService.quotes[item.symbol]
                    Text(quote?.name ?? StockService.beautifiedSymbol(item.symbol))
                        .font(.inter(10.5, weight: .regular, relativeTo: .caption))
                        .foregroundStyle(DS.inkSecondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 140, alignment: .leading)

                Spacer()

                // Date & Session
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(item.shortDateFormatted)
                            .font(.inter(12, weight: .semibold, relativeTo: .body))
                            .foregroundStyle(DS.ink)

                        if item.session != .unspecified {
                            Text(item.session.badgeText)
                                .font(.inter(9, weight: .bold, relativeTo: .caption2))
                                .foregroundStyle(item.session == .bmo ? Color.orange : Color.indigo)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill((item.session == .bmo ? Color.orange : Color.indigo).opacity(0.12)))
                                .help(item.session == .bmo ? "BMO: Before Market Open (Trước giờ mở cửa)" : "AMC: After Market Close (Sau giờ đóng cửa)")
                        }
                    }

                    Text(item.countdownText)
                        .font(.inter(9.5, weight: .medium, relativeTo: .caption2))
                        .foregroundStyle(countdownColor(item: item))
                }
                .frame(minWidth: 95, alignment: .trailing)

                Divider().frame(height: 22)

                // Consensus Estimates
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 3) {
                        Text("EPS:")
                            .font(.inter(9.5, weight: .regular, relativeTo: .caption2))
                            .foregroundStyle(DS.inkTertiary)
                        Text(item.epsEstimate.map { String(format: "$%.2f", $0) } ?? "—")
                            .font(.inter(11, weight: .semibold, relativeTo: .caption))
                            .foregroundStyle(DS.ink)
                    }

                    HStack(spacing: 3) {
                        Text("Rev:")
                            .font(.inter(9.5, weight: .regular, relativeTo: .caption2))
                            .foregroundStyle(DS.inkTertiary)
                        Text(item.revenueEstimate.map { formatRevenue($0) } ?? "—")
                            .font(.inter(10.5, weight: .medium, relativeTo: .caption))
                            .foregroundStyle(DS.inkSecondary)
                    }
                }
                .frame(minWidth: 85, alignment: .trailing)
                .help(isVi ? "Dự báo: EPS \(item.epsEstimate.map { String(format: "$%.2f", $0) } ?? "—"), Doanh thu \(item.revenueEstimate.map { formatRevenue($0) } ?? "—")" : "Consensus: EPS \(item.epsEstimate.map { String(format: "$%.2f", $0) } ?? "—"), Rev \(item.revenueEstimate.map { formatRevenue($0) } ?? "—")")

                // Prior Quarter Surprise Badge (first item in descending chronological order)
                if let priorQuarter = item.history.first {
                    priorQuarterBadge(priorQuarter)
                        .frame(width: 65, alignment: .trailing)
                } else {
                    Spacer().frame(width: 65)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isSelected ? DS.brand.opacity(0.09) : DS.card)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? DS.brand.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    // MARK: - Inspector Panel Subviews

    @ViewBuilder
    private var inspectorPanel: some View {
        if let item = activeSelectedItem {
            VStack(alignment: .leading, spacing: 12) {
                // Header: Symbol, Name, Source Badge
                HStack(spacing: 10) {
                    SymbolLogo(symbol: item.symbol, size: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.symbol)
                                .font(.inter(15, weight: .bold, relativeTo: .title3))
                                .foregroundStyle(DS.ink)

                            sourceBadge(for: item.symbol)
                        }

                        let quote = stockService.quotes[item.symbol]
                        Text(quote?.name ?? StockService.beautifiedSymbol(item.symbol))
                            .font(.inter(11, weight: .regular, relativeTo: .caption))
                            .foregroundStyle(DS.inkSecondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }

                if let quote = stockService.quotes[item.symbol] {
                    let currSym = StorageService.currencySymbol(for: quote.currency)
                    let sign = quote.changePercent >= 0 ? "+" : ""
                    let pctStr = String(format: "%@%.2f%%", sign, quote.changePercent)

                    HStack(spacing: 8) {
                        Text(StorageService.formatAmount(quote.price, symbol: currSym))
                            .font(.inter(15, weight: .bold, relativeTo: .title3))
                            .foregroundStyle(DS.ink)

                        Text(pctStr)
                            .font(.inter(11, weight: .bold, relativeTo: .caption))
                            .foregroundStyle(quote.isPositive ? DS.up : DS.down)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill((quote.isPositive ? DS.up : DS.down).opacity(0.12)))

                        Spacer()
                    }
                    .padding(.top, -4)
                }

                Divider().opacity(0.5)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // 1. Upcoming Announcement Card
                        inspectorUpcomingSection(item: item)

                        // 2. 4 Recent Quarters History Table
                        inspectorHistorySection(item: item)

                        // 3. Wall Street Forward Guidance / Outlook
                        inspectorGuidanceSection(item: item)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(14)
            .background(DS.card)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(DS.hairline, lineWidth: 0.5)
            )
        } else {
            emptyInspectorPlaceholder
        }
    }

    @ViewBuilder
    private func inspectorUpcomingSection(item: EarningsReportItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header: Date & Session
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DS.brand)

                Text(item.formattedDateRange)
                    .font(.inter(12, weight: .bold, relativeTo: .subheadline))
                    .foregroundStyle(DS.ink)

                if item.daysUntilNextEarnings != nil {
                    Text(item.countdownText)
                        .font(.inter(9.5, weight: .bold, relativeTo: .caption2))
                        .foregroundStyle(countdownColor(item: item))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(countdownColor(item: item).opacity(0.12)))
                }

                Spacer()

                if item.session != .unspecified {
                    Text(item.session.title)
                        .font(.inter(9.5, weight: .semibold, relativeTo: .caption2))
                        .foregroundStyle(item.session == .bmo ? Color.orange : Color.indigo)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill((item.session == .bmo ? Color.orange : Color.indigo).opacity(0.12)))
                        .help(item.session == .bmo
                              ? (isVi ? "Báo cáo trước giờ mở cửa phiên chính (Before Market Open)" : "Reports Before Market Open")
                              : (isVi ? "Báo cáo sau giờ đóng cửa phiên chính (After Market Close)" : "Reports After Market Close"))
                }
            }

            // Consensus Estimates Grid
            HStack(spacing: 12) {
                // Consensus EPS
                VStack(alignment: .leading, spacing: 3) {
                    Text(isVi ? "EPS Dự báo" : "Consensus EPS")
                        .font(.inter(10, weight: .medium, relativeTo: .caption2))
                        .foregroundStyle(DS.inkTertiary)
                    Text(item.epsEstimate.map { String(format: "$%.2f", $0) } ?? "—")
                        .font(.inter(13, weight: .bold, relativeTo: .body))
                        .foregroundStyle(DS.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(isVi ? "Ước tính EPS trung bình của các nhà phân tích cho kỳ tới" : "Consensus EPS average estimate")

                Divider().frame(height: 24)

                // Consensus Revenue
                VStack(alignment: .leading, spacing: 3) {
                    Text(isVi ? "Doanh thu Dự báo" : "Consensus Revenue")
                        .font(.inter(10, weight: .medium, relativeTo: .caption2))
                        .foregroundStyle(DS.inkTertiary)
                    Text(item.revenueEstimate.map { formatRevenue($0) } ?? "—")
                        .font(.inter(13, weight: .bold, relativeTo: .body))
                        .foregroundStyle(DS.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(isVi ? "Ước tính Doanh thu trung bình của các nhà phân tích cho kỳ tới" : "Consensus Revenue average estimate")

                if let low = item.epsLow, let high = item.epsHigh, low != high {
                    Divider().frame(height: 24)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(isVi ? "Biên độ EPS" : "EPS Range")
                            .font(.inter(10, weight: .medium, relativeTo: .caption2))
                            .foregroundStyle(DS.inkTertiary)
                        Text(String(format: "$%.2f–$%.2f", low, high))
                            .font(.inter(11, weight: .semibold, relativeTo: .caption))
                            .foregroundStyle(DS.inkSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(isVi ? "Khoảng dự báo EPS thấp nhất đến cao nhất" : "Analyst EPS estimate range")
                }
            }
            .padding(10)
            .background(DS.cardAlt.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder
    private func inspectorHistorySection(item: EarningsReportItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(isVi ? "Lịch sử 4 quý gần nhất" : "Recent 4 Quarters Track Record")
                    .font(.inter(11.5, weight: .bold, relativeTo: .subheadline))
                    .foregroundStyle(DS.ink)

                Spacer()

                // Beat track record pill (e.g. "3/4 Beat")
                let beats = item.history.filter { $0.beatMiss == .beat }.count
                let total = item.history.filter { $0.beatMiss == .beat || $0.beatMiss == .miss }.count
                if total > 0 {
                    Text(isVi ? "\(beats)/\(total) quý vượt kỳ vọng" : "\(beats)/\(total) Beats")
                        .font(.inter(9.5, weight: .bold, relativeTo: .caption2))
                        .foregroundStyle(beats >= total / 2 ? DS.up : DS.down)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill((beats >= total / 2 ? DS.up : DS.down).opacity(0.12)))
                }
            }

            if item.history.isEmpty {
                HStack {
                    Spacer()
                    Text(isVi ? "Chưa có dữ liệu lịch sử BCTC" : "No historical quarterly earnings data")
                        .font(.inter(11, weight: .regular, relativeTo: .caption))
                        .foregroundStyle(DS.inkTertiary)
                    Spacer()
                }
                .padding(.vertical, 16)
                .background(DS.cardAlt.opacity(0.2))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    // Table Header
                    HStack(spacing: 6) {
                        Text(isVi ? "Quý" : "Quarter")
                            .frame(width: 50, alignment: .leading)
                        Spacer()
                        Text(isVi ? "Doanh thu & LN" : "Rev & Net Inc")
                            .frame(width: 96, alignment: .trailing)
                            .help(isVi ? "Doanh thu & Lợi nhuận ròng (Biên lợi nhuận ròng %)" : "Revenue & Net Income (Net Margin %)")
                        Text(isVi ? "EPS TT / DB" : "EPS Act/Est")
                            .frame(width: 66, alignment: .trailing)
                            .help(isVi ? "EPS Thực tế và Dự báo phân tích" : "Actual EPS vs Consensus Estimate")
                        Text(isVi ? "Surprise" : "Surprise")
                            .frame(width: 64, alignment: .trailing)
                            .help(isVi ? "Tỷ lệ % vượt hoặc hụt so với dự báo của phân tích" : "Beat / Miss Surprise %")
                    }
                    .font(.inter(9.5, weight: .bold, relativeTo: .caption2))
                    .foregroundStyle(DS.inkTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(DS.cardAlt.opacity(0.6))

                    Divider().opacity(0.5)

                    // Table Rows
                    ForEach(item.history) { q in
                        inspectorQuarterRow(q)
                        if q.id != item.history.last?.id {
                            Divider().opacity(0.3)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(DS.hairline, lineWidth: 0.5)
                )
            }
        }
    }

    @ViewBuilder
    private func inspectorQuarterRow(_ q: EarningsQuarterResult) -> some View {
        HStack(spacing: 6) {
            // Quarter
            Text(q.quarterFormatted)
                .font(.inter(11, weight: .bold, relativeTo: .caption))
                .foregroundStyle(DS.ink)
                .frame(width: 50, alignment: .leading)

            Spacer()

            // Revenue & Net Income
            VStack(alignment: .trailing, spacing: 1.5) {
                Text(q.revenue.map { formatRevenue($0) } ?? "—")
                    .font(.inter(10.5, weight: .semibold, relativeTo: .caption2))
                    .foregroundStyle(DS.ink)

                if let net = q.netIncome {
                    HStack(spacing: 2) {
                        Text(isVi ? "LN:" : "Net:")
                            .font(.inter(8.5, weight: .regular, relativeTo: .caption2))
                            .foregroundStyle(DS.inkTertiary)
                        Text(formatRevenue(net))
                            .font(.inter(8.5, weight: .medium, relativeTo: .caption2))
                            .foregroundStyle(DS.inkSecondary)
                        if let margin = q.profitMarginFormatted {
                            Text("(\(margin))")
                                .font(.inter(8, weight: .regular, relativeTo: .caption2))
                                .foregroundStyle(DS.inkTertiary)
                        }
                    }
                }
            }
            .frame(width: 96, alignment: .trailing)

            // EPS Actual vs Estimate
            VStack(alignment: .trailing, spacing: 1.5) {
                Text(q.epsActual.map { String(format: "$%.2f", $0) } ?? "—")
                    .font(.inter(11, weight: .bold, relativeTo: .caption))
                    .foregroundStyle(DS.ink)
                if let est = q.epsEstimate {
                    Text(String(format: "Est $%.2f", est))
                        .font(.inter(8.5, weight: .medium, relativeTo: .caption2))
                        .foregroundStyle(DS.inkTertiary)
                }
            }
            .frame(width: 66, alignment: .trailing)

            // Surprise Badge
            priorQuarterBadge(q)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func inspectorGuidanceSection(item: EarningsReportItem) -> some View {
        if !item.trends.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DS.brand)

                    Text(isVi ? "Dự báo tăng trưởng Wall Street" : "Wall Street Consensus Guidance")
                        .font(.inter(11.5, weight: .bold, relativeTo: .subheadline))
                        .foregroundStyle(DS.ink)

                    Spacer()
                }

                VStack(spacing: 0) {
                    // Table Header
                    HStack(spacing: 6) {
                        Text(isVi ? "Kỳ" : "Period")
                            .frame(width: 65, alignment: .leading)
                        Spacer()
                        Text(isVi ? "EPS (Tăng trưởng)" : "EPS (Growth)")
                            .frame(width: 105, alignment: .trailing)
                            .help(isVi ? "Dự báo EPS đồng thuận & Tăng trưởng YoY" : "Consensus EPS Estimate & YoY Growth")
                        Text(isVi ? "D.Thu (Tăng trưởng)" : "Rev (Growth)")
                            .frame(width: 105, alignment: .trailing)
                            .help(isVi ? "Dự báo Doanh thu đồng thuận & Tăng trưởng YoY" : "Consensus Revenue Estimate & YoY Growth")
                        Text(isVi ? "CTCK" : "Analysts")
                            .frame(width: 40, alignment: .trailing)
                            .help(isVi ? "Số lượng nhà phân tích phố Wall đưa ra ước tính" : "Number of Wall Street analysts contributing to consensus")
                    }
                    .font(.inter(9.5, weight: .bold, relativeTo: .caption2))
                    .foregroundStyle(DS.inkTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(DS.cardAlt.opacity(0.6))

                    Divider().opacity(0.5)

                    ForEach(item.trends) { trend in
                        inspectorTrendRow(trend)
                        if trend.id != item.trends.last?.id {
                            Divider().opacity(0.3)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(DS.hairline, lineWidth: 0.5)
                )
            }
        }
    }

    @ViewBuilder
    private func inspectorTrendRow(_ t: EarningsTrendItem) -> some View {
        HStack(spacing: 6) {
            // Period title (e.g. "Quý này" / "Current Qtr", sub: "0q")
            VStack(alignment: .leading, spacing: 1.5) {
                Text(trendPeriodTitle(t.period))
                    .font(.inter(10.5, weight: .bold, relativeTo: .caption2))
                    .foregroundStyle(DS.ink)
                Text(t.period.uppercased())
                    .font(.inter(8.5, weight: .medium, relativeTo: .caption2))
                    .foregroundStyle(DS.inkTertiary)
            }
            .frame(width: 65, alignment: .leading)

            Spacer()

            // EPS Est + Growth
            VStack(alignment: .trailing, spacing: 1.5) {
                Text(t.epsEstimate.map { String(format: "$%.2f", $0) } ?? "—")
                    .font(.inter(10.5, weight: .semibold, relativeTo: .caption2))
                    .foregroundStyle(DS.ink)
                if let g = t.epsGrowth {
                    Text(formatGrowthPercent(g))
                        .font(.inter(8.5, weight: .medium, relativeTo: .caption2))
                        .foregroundStyle(g >= 0 ? DS.up : DS.down)
                }
            }
            .frame(width: 105, alignment: .trailing)

            // Revenue Est + Growth
            VStack(alignment: .trailing, spacing: 1.5) {
                Text(t.revenueEstimate.map { formatRevenue($0) } ?? "—")
                    .font(.inter(10.5, weight: .semibold, relativeTo: .caption2))
                    .foregroundStyle(DS.ink)
                if let g = t.revenueGrowth {
                    Text(formatGrowthPercent(g))
                        .font(.inter(8.5, weight: .medium, relativeTo: .caption2))
                        .foregroundStyle(g >= 0 ? DS.up : DS.down)
                }
            }
            .frame(width: 105, alignment: .trailing)

            // Analysts count
            Text(t.numberOfAnalysts.map { "\($0)" } ?? "—")
                .font(.inter(10, weight: .medium, relativeTo: .caption2))
                .foregroundStyle(DS.inkSecondary)
                .frame(width: 40, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var emptyInspectorPlaceholder: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 32))
                .foregroundStyle(DS.inkTertiary)
            Text(isVi ? "Chọn một mã để xem chi tiết BCTC" : "Select a symbol to view report details")
                .font(.inter(12.5, weight: .medium, relativeTo: .caption))
                .foregroundStyle(DS.inkSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .background(DS.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(DS.hairline, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func sourceBadge(for symbol: String) -> some View {
        let inPort = portfolioSymbols.contains(symbol)
        let inWatch = watchlistSymbols.contains(symbol)

        if inPort {
            Text(isVi ? "Danh mục" : "Portfolio")
                .font(.inter(9, weight: .semibold, relativeTo: .caption2))
                .foregroundStyle(DS.brand)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(DS.brand.opacity(0.12)))
        } else if inWatch {
            Text("Watchlist")
                .font(.inter(9, weight: .medium, relativeTo: .caption2))
                .foregroundStyle(DS.inkSecondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(DS.cardAlt))
        }
    }

    @ViewBuilder
    private func priorQuarterBadge(_ q: EarningsQuarterResult) -> some View {
        let actStr = q.epsActual.map { String(format: "$%.2f", $0) } ?? "—"
        let estStr = q.epsEstimate.map { String(format: "$%.2f", $0) } ?? "—"
        let tooltip: String = {
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
                .padding(.horizontal, 5)
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
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(DS.down.opacity(0.12)))

            case .inLine:
                Text("In-Line")
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

    private func countdownColor(item: EarningsReportItem) -> Color {
        guard let days = item.daysUntilNextEarnings else { return DS.inkTertiary }
        if days == 0 {
            return .red
        } else if days <= 2 {
            return .orange
        } else {
            return DS.inkSecondary
        }
    }

    private func formatRevenue(_ val: Double) -> String {
        if val >= 1_000_000_000_000 {
            return String(format: "$%.2fT", val / 1_000_000_000_000.0)
        } else if val >= 1_000_000_000 {
            return String(format: "$%.2fB", val / 1_000_000_000.0)
        } else if val >= 1_000_000 {
            return String(format: "$%.2fM", val / 1_000_000.0)
        } else {
            return String(format: "$%.0f", val)
        }
    }

    private func formatGrowthPercent(_ val: Double) -> String {
        let pct = abs(val) <= 2.0 ? val * 100.0 : val
        let sign = pct > 0 ? "+" : ""
        return String(format: "%@%.1f%%", sign, pct)
    }

    private func trendPeriodTitle(_ period: String) -> String {
        switch period {
        case "0q": return isVi ? "Quý này" : "Current Qtr"
        case "+1q": return isVi ? "Quý sau" : "Next Qtr"
        case "0y": return isVi ? "Năm nay" : "Current Year"
        case "+1y": return isVi ? "Năm sau" : "Next Year"
        default: return period.uppercased()
        }
    }

    // MARK: - Actions

    private func loadDataIfNeeded() async {
        let symbols = targetSymbols
        guard !symbols.isEmpty else { return }
        await earningsService.ensureEarnings(for: symbols, force: false)
    }

    private func refreshData(force: Bool = true) {
        let symbols = targetSymbols
        guard !symbols.isEmpty else { return }
        isRefreshing = true
        Task {
            await earningsService.ensureEarnings(for: symbols, force: force)
            isRefreshing = false
        }
    }
}
