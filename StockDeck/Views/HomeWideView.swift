import SwiftUI
import AppKit

/// Desktop news & market insights view: combines AI-driven movement explanations
/// with a responsive grid of story cards. Tapping opens the article in the in-app browser.
struct HomeWideView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService

    @State private var mode: HomeViewMode
    private let showModePicker: Bool
    @State private var query = ""
    @State private var selectedNewsArticle: NewsArticle?
    @State private var isLoadingInsight = false
    @State private var insightError: String? = nil
    @ObservedObject private var translationService = NewsTranslationService.shared

    let onOpenSettings: () -> Void

    init(mode: HomeViewMode = .insights, showModePicker: Bool = true, onOpenSettings: @escaping () -> Void = {}) {
        self._mode = State(initialValue: mode)
        self.showModePicker = showModePicker
        self.onOpenSettings = onOpenSettings
    }

    private let insightColumns = [GridItem(.adaptive(minimum: 340, maximum: .infinity), spacing: DS.gap)]

    /// Filters news by free text — matches the headline, the tickers (source +
    /// related), and the publisher, sorted newest first.
    private var filteredNews: [NewsArticle] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let sorted = stockService.news.sorted { $0.publishTime > $1.publishTime }
        guard !q.isEmpty else { return sorted }
        return sorted.filter { a in
            a.title.lowercased().contains(q)
            || a.publisher.lowercased().contains(q)
            || (a.sourceSymbol?.lowercased().contains(q) ?? false)
            || a.relatedTickers.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        ZStack {
            homeContent
                .disabled(selectedNewsArticle != nil)
                .allowsHitTesting(selectedNewsArticle == nil)

            if let article = selectedNewsArticle {
                NewsDetailView(
                    article: article,
                    isWide: true,
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            selectedNewsArticle = nil
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
                .zIndex(1)
            }
        }
        .navigationTitle(showModePicker ? "Home" : (mode == .insights ? "AI Insights" : "News"))
        .task {
            if mode == .news {
                if !stockService.news.isEmpty {
                    NewsTranslationService.shared.translateHeadlinesIfNeeded(articles: stockService.news, storageService: storageService)
                }
                await stockService.refreshNews(storageService: storageService)
                NewsTranslationService.shared.translateHeadlinesIfNeeded(articles: stockService.news, storageService: storageService)
            } else {
                _ = storageService.loadDailyAIInsight()
                await stockService.fetchFearGreedIndex()
                if storageService.hasAIConfiguration && (storageService.dailyAIInsight == nil || !Calendar.current.isDateInToday(storageService.dailyAIInsight!.date) || (storageService.dailyAIInsight?.language != nil && storageService.dailyAIInsight?.language != storageService.appLanguage)) {
                    refreshInsights(force: false)
                }
                await stockService.refreshNews(storageService: storageService)
                NewsTranslationService.shared.translateHeadlinesIfNeeded(articles: stockService.news, storageService: storageService)
            }
        }
        .onChange(of: stockService.news) { _, newArticles in
            NewsTranslationService.shared.translateHeadlinesIfNeeded(articles: newArticles, storageService: storageService)
        }
        .onChange(of: storageService.appLanguage) { _, newLang in
            if storageService.hasAIConfiguration && storageService.dailyAIInsight?.language != newLang {
                refreshInsights(force: true)
            }
            Task {
                await stockService.refreshNews(storageService: storageService, force: true)
                NewsTranslationService.shared.translateHeadlinesIfNeeded(articles: stockService.news, storageService: storageService)
            }
        }
        .onChange(of: storageService.autoTranslateNews) { _, isAuto in
            if isAuto {
                NewsTranslationService.shared.translateHeadlinesIfNeeded(articles: stockService.news, storageService: storageService)
            }
        }
    }

    private var pageTitleKey: LocalizedStringKey {
        mode == .insights ? "AI Insights" : "News"
    }

    private var homeContent: some View {
        PageScaffold(showModePicker ? "Home" : pageTitleKey, caption: headerCaptionKey) {
            HStack(spacing: 12) {
                if showModePicker {
                    modePicker
                }
                if mode == .news {
                    if storageService.autoTranslateNews && translationService.isTranslatingHeadlines {
                        HStack(spacing: 5) {
                            DSSpinner(size: 11)
                            Text("Translating headlines…")
                                .font(DS.caption)
                                .foregroundStyle(DS.inkTertiary)
                        }
                        .padding(.trailing, 4)
                    } else if storageService.autoTranslateNews && translationService.isQuotaExhausted {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.orange)
                            Text("Translation quota exceeded")
                                .font(DS.caption)
                                .foregroundStyle(Color.orange)
                        }
                        .padding(.trailing, 4)
                        .help(String(localized: "AI translation quota is temporarily exhausted. Original headlines are displayed. Switch provider or API key in Settings."))
                    }
                    searchField
                }
                RefreshButton(isLoading: mode == .insights ? isLoadingInsight : stockService.isLoadingNews) {
                    if mode == .insights {
                        refreshInsights(force: true)
                        Task { await stockService.fetchFearGreedIndex(force: true) }
                    } else {
                        Task { await stockService.refreshNews(storageService: storageService, force: true) }
                    }
                }
            }
        } content: {
            Group {
                if mode == .insights {
                    insightsContent
                } else {
                    newsContent
                }
            }
        }
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(HomeViewMode.allCases, id: \.self) { m in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        mode = m
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: m == .insights ? "sparkles" : "newspaper")
                            .font(.system(size: 11))
                        Text(LocalizedStringKey(m.rawValue))
                            .font(.inter(11.5, weight: mode == m ? .bold : .medium, relativeTo: .caption))
                    }
                    .foregroundStyle(mode == m ? DS.brand : DS.inkSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(mode == m ? DS.brand.opacity(0.12) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(DS.cardAlt))
    }

    private var headerCaptionKey: LocalizedStringKey {
        if mode == .insights {
            return "Explanations of portfolio movements via AI & 24h news"
        }
        return newsCaptionKey
    }

    private func refreshInsights(force: Bool = false) {
        guard storageService.hasAIConfiguration else { return }
        isLoadingInsight = true
        insightError = nil
        Task {
            do {
                _ = try await HomeAIInsightService.shared.generateDailyInsight(
                    storageService: storageService,
                    stockService: stockService,
                    force: force
                )
                isLoadingInsight = false
            } catch {
                insightError = error.localizedDescription
                isLoadingInsight = false
            }
        }
    }

    @ViewBuilder
    private var insightsContent: some View {
        if !storageService.hasAIConfiguration {
            ScrollView {
                VStack(spacing: DS.gap) {
                    FearGreedGaugeCard(
                        stockData: stockService.stockFearGreed,
                        cryptoData: stockService.cryptoFearGreed
                    )
                    AIInsightMissingConfigCard(onOpenSettings: onOpenSettings)
                    if !stockService.news.isEmpty {
                        newsContent
                    }
                }
                .pageColumn()
                .padding(.top, 4)
            }
        } else if isLoadingInsight && storageService.dailyAIInsight == nil {
            VStack {
                Spacer()
                AIInsightLoadingCard()
                    .frame(maxWidth: 480)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let insight = storageService.dailyAIInsight {
            ScrollView {
                VStack(spacing: DS.gap) {
                    AIInsightPulseHeroCard(
                        insight: insight,
                        isLoading: isLoadingInsight,
                        onRefresh: { refreshInsights(force: true) }
                    )

                    FearGreedGaugeCard(
                        stockData: stockService.stockFearGreed,
                        cryptoData: stockService.cryptoFearGreed
                    )

                    if !insight.items.isEmpty {
                        let grouped = Dictionary(grouping: insight.items, by: \.marketCategory)
                        ForEach(MarketCategory.allCases) { cat in
                            if let items = grouped[cat], !items.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    MarketSectionHeader(category: cat, count: items.count)

                                    if let overview = insight.overview(for: cat), !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        MarketOverviewCard(category: cat, overview: overview)
                                    }

                                    LazyVGrid(columns: insightColumns, spacing: DS.gap) {
                                        ForEach(items) { item in
                                            SymbolInsightCard(item: item) { url in
                                                let article = item.makeNewsArticle(for: url, timestamp: insight.date)
                                                withAnimation(.easeInOut(duration: 0.18)) {
                                                    selectedNewsArticle = article
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 24))
                                .foregroundStyle(DS.inkTertiary)
                            Text("No detailed drivers available for individual symbols")
                                .font(DS.caption)
                                .foregroundStyle(DS.inkSecondary)
                            Button("Re-analyze Tracked Symbols") {
                                refreshInsights(force: true)
                            }
                            .buttonStyle(.bordered)
                            .tint(DS.brand)
                        }
                        .padding(.vertical, 20)
                    }
                }
                .pageColumn()
                .padding(.top, 4)
            }
        } else if let err = insightError {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(DS.down)
                Text("Unable to load AI insights: \(err)")
                    .font(DS.bodyStrong)
                    .foregroundStyle(DS.inkSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                Button("Try Again") {
                    refreshInsights(force: true)
                }
                .buttonStyle(.bordered)
                .tint(DS.brand)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 32))
                    .foregroundStyle(DS.inkTertiary)
                Text("No AI insights available for today")
                    .font(DS.bodyStrong)
                    .foregroundStyle(DS.inkSecondary)
                Button("Analyze Now") {
                    refreshInsights(force: true)
                }
                .buttonStyle(.bordered)
                .tint(DS.brand)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var newsContent: some View {
        if stockService.news.isEmpty {
            emptyState
        } else {
            let news = filteredNews
            if news.isEmpty {
                noMatchesState
            } else {
                ScrollView {
                    VStack(spacing: DS.gap) {
                        Card {
                            LazyVStack(spacing: 0) {
                                ForEach(news) { article in
                                    HomeWideNewsRow(article: article) { selected in
                                        withAnimation(.easeInOut(duration: 0.18)) {
                                            selectedNewsArticle = selected
                                        }
                                    }
                                    if article.id != news.last?.id {
                                        Divider()
                                            .overlay(DS.hairline.opacity(0.6))
                                            .padding(.horizontal, 4)
                                    }
                                }
                            }
                        }
                    }
                    .pageColumn()
                    .padding(.top, 4)
                }
            }
        }
    }

    private var searchField: some View {
        HomeSearchField(query: $query)
    }
    private var noMatchesState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "magnifyingglass").font(.system(size: 34)).foregroundStyle(DS.inkTertiary)
            Text("No stories match “\(query)”").font(DS.bodyStrong).foregroundStyle(DS.inkSecondary)
            Button { query = "" } label: { Label("Clear search", systemImage: "xmark") }
                .buttonStyle(.bordered).tint(DS.brand)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var newsCaptionKey: LocalizedStringKey {
        if stockService.news.isEmpty { return "Market stories for your symbols" }
        let n = filteredNews.count
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return "\(n) stories for your symbols"
        }
        return "\(n) of \(stockService.news.count) stories match"
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            if stockService.isLoadingNews {
                DSSpinner(size: 22)
                Text("Loading news…").font(DS.caption).foregroundStyle(DS.inkSecondary)
            } else {
                Image(systemName: "newspaper").font(.system(size: 34)).foregroundStyle(DS.inkTertiary)
                Text("No news available").font(DS.bodyStrong).foregroundStyle(DS.inkSecondary)
                Button {
                    Task { await stockService.refreshNews(storageService: storageService, force: true) }
                } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered)
                    .tint(DS.brand)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - News Row (Isolated Hover State)

private struct HomeWideNewsRow: View {
    let article: NewsArticle
    let onSelect: (NewsArticle) -> Void
    @EnvironmentObject private var storageService: StorageService
    @ObservedObject private var translationService = NewsTranslationService.shared
    @Environment(\.locale) private var locale
    @State private var hovered = false

    private var relativeTime: String {
        guard article.publishTime > 0 else { return "" }
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .abbreviated
        return f.localizedString(for: article.publishedAt, relativeTo: Date())
    }

    private var referenceTicker: String? { article.sourceSymbol ?? article.relatedTickers.first }
    private var otherTickers: [String] { Array(article.relatedTickers.filter { $0 != referenceTicker }.prefix(2)) }

    var body: some View {
        Button {
            onSelect(article)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if let thumb = article.thumbnailURL, let url = URL(string: thumb) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        default:
                            Color.clear
                        }
                    }
                    .frame(width: 56, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.hairline, lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 5) {
                    let translated = storageService.autoTranslateNews ? translationService.translatedTitle(for: article) : nil
                    let mainTitle = translated ?? article.title

                    Text(verbatim: mainTitle)
                        .font(.inter(13.5, weight: .semibold, relativeTo: .body))
                        .foregroundStyle(DS.ink)
                        .lineLimit(3)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .animation(.easeInOut(duration: 0.2), value: translated)

                    HStack(spacing: 6) {
                        if let ref = referenceTicker {
                            TickerChipWide(text: ref, emphasized: true)
                            ForEach(otherTickers, id: \.self) {
                                TickerChipWide(text: $0, emphasized: false)
                            }
                        }

                        if !article.publisher.isEmpty {
                            Text(verbatim: article.publisher)
                                .font(.inter(10.5, weight: .medium, relativeTo: .caption2))
                                .foregroundStyle(DS.inkSecondary)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                )
                        }

                        if !relativeTime.isEmpty {
                            Text("·")
                                .font(DS.micro)
                                .foregroundStyle(DS.inkTertiary)
                            Text(relativeTime)
                                .font(DS.micro)
                                .foregroundStyle(DS.inkTertiary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(hovered ? DS.inkSecondary : DS.inkTertiary.opacity(0.5))
                    }
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovered ? Color.primary.opacity(0.05) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { inside in
            hovered = inside
        }
        .onAppear {
            if storageService.autoTranslateNews {
                NewsTranslationService.shared.translateHeadlinesIfNeeded(articles: [article], storageService: storageService)
            }
        }
        .help(article.title)
    }
}

private struct TickerChipWide: View {
    let text: String; let emphasized: Bool
    var body: some View {
        HStack(spacing: 3) {
            SymbolLogo(symbol: text, size: 14)
            Text(verbatim: text).font(DS.micro)
        }
            .foregroundStyle(emphasized ? Color.white : DS.brand)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(emphasized ? DS.brand : DS.brand.opacity(0.10)))
    }
}

struct HomeSearchField: View {
    @Binding var query: String
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(DS.inkTertiary)
            TextField("Search news or ticker", text: $query)
                .textFieldStyle(.plain)
                .font(DS.body)
                .focused($searchFocused)
                .frame(width: 180)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(DS.inkTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Capsule().fill(DS.cardAlt))
        .overlay(Capsule().strokeBorder(searchFocused ? DS.brand : .clear, lineWidth: 1.5))
        .animation(.easeOut(duration: 0.15), value: searchFocused)
        .help("Filter news by headline, ticker or publisher")
    }
}
