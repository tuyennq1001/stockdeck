import AppKit
import SwiftUI

/// Home tab: a compact finance news feed related to the user's tracked symbols
/// (or general market news when nothing is tracked). Tapping a story opens it
/// in the in-app browser.
struct HomeView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @State private var mode: HomeViewMode
    private let showModePicker: Bool
    @State private var query = ""
    @State private var selectedNewsArticle: NewsArticle?
    @State private var isLoadingInsight = false
    @State private var insightError: String? = nil
    @ObservedObject private var translationService = NewsTranslationService.shared

    init(initialMode: HomeViewMode = .insights, showModePicker: Bool = true) {
        self._mode = State(initialValue: initialMode)
        self.showModePicker = showModePicker
    }

    /// Filters by headline, tickers (source + related) and publisher, sorted newest first.
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

    private var homeContent: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            if mode == .insights {
                insightsView
            } else {
                newsView
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            if showModePicker {
                modePicker
            }
            if mode == .news {
                if storageService.autoTranslateNews && translationService.isTranslatingHeadlines {
                    HStack(spacing: 4) {
                        DSSpinner(size: 9)
                        Text("Translating headlines…")
                            .font(.inter(10, relativeTo: .caption))
                            .foregroundStyle(DS.inkTertiary)
                    }
                } else if storageService.autoTranslateNews && translationService.isQuotaExhausted {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.orange)
                        Text("Quota exceeded")
                            .font(.inter(10, relativeTo: .caption))
                            .foregroundStyle(Color.orange)
                    }
                    .help(String(localized: "AI translation quota is temporarily exhausted. Original headlines are displayed. Switch provider or API key in Settings."))
                }
                searchField
            }
            Spacer()
            Button {
                if mode == .insights {
                    refreshInsights(force: true)
                    Task { await stockService.fetchFearGreedIndex(force: true) }
                } else {
                    Task { await stockService.refreshNews(storageService: storageService, force: true) }
                }
            } label: {
                if (mode == .insights && isLoadingInsight) || (mode == .news && stockService.isLoadingNews) {
                    ProgressView().scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(isLoadingInsight || stockService.isLoadingNews)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var modePicker: some View {
        HStack(spacing: 2) {
            ForEach(HomeViewMode.allCases, id: \.self) { m in
                let isSelected = (mode == m)
                let icon = (m == .insights ? "sparkles" : "newspaper")
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        mode = m
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: icon)
                            .font(.system(size: 10))
                        Text(LocalizedStringKey(m.rawValue))
                            .font(.inter(10, weight: isSelected ? .bold : .medium, relativeTo: .caption2))
                    }
                    .foregroundColor(isSelected ? DS.brand : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(
                        Capsule()
                            .fill(isSelected ? DS.brand.opacity(0.12) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.secondary.opacity(0.08)))
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
    private var insightsView: some View {
        if !storageService.hasAIConfiguration {
            ScrollView {
                VStack(spacing: 12) {
                    FearGreedGaugeCard(
                        stockData: stockService.stockFearGreed,
                        cryptoData: stockService.cryptoFearGreed
                    )
                    .padding(.horizontal, 10)
                    .padding(.top, 8)

                    AIInsightMissingConfigCard(onOpenSettings: {})
                        .padding(.horizontal, 10)
                    newsView
                }
            }
        } else if isLoadingInsight && storageService.dailyAIInsight == nil {
            VStack(spacing: 10) {
                Spacer()
                ProgressView().scaleEffect(0.8)
                Text("AI is analyzing 24h price movement drivers…")
                    .font(.inter(11, relativeTo: .caption))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let insight = storageService.dailyAIInsight {
            ScrollView {
                VStack(spacing: 10) {
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
                                VStack(alignment: .leading, spacing: 8) {
                                    MarketSectionHeader(category: cat, count: items.count)

                                    if let overview = insight.overview(for: cat), !overview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        MarketOverviewCard(category: cat, overview: overview)
                                    }

                                    ForEach(items) { item in
                                        SymbolInsightCard(item: item) { url in
                                            let article = item.makeNewsArticle(for: url, timestamp: insight.date)
                                            withAnimation(.easeInOut(duration: 0.18)) {
                                                selectedNewsArticle = article
                                            }
                                        }
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .font(.system(size: 20))
                                .foregroundColor(.secondary)
                            Text("No detailed drivers available for individual symbols")
                                .font(.inter(11, relativeTo: .caption))
                                .foregroundColor(.secondary)
                            Button("Re-analyze Tracked Symbols") {
                                refreshInsights(force: true)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 16)
                    }
                }
                .padding(10)
            }
        } else if let err = insightError {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24))
                    .foregroundColor(DS.down)
                Text("AI Analysis Error: \(err)")
                    .font(.inter(11, relativeTo: .caption))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Button("Try Again") {
                    refreshInsights(force: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "sparkles")
                    .font(.system(size: 24))
                    .foregroundColor(.secondary)
                Text("No AI insights available for today")
                    .font(.inter(11, relativeTo: .caption))
                    .foregroundColor(.secondary)
                Button("Analyze Now") {
                    refreshInsights(force: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var newsView: some View {
        if stockService.news.isEmpty {
            if stockService.isLoadingNews {
                VStack(spacing: 10) {
                    Spacer()
                    ProgressView().scaleEffect(0.8)
                    Text("Loading news…")
                        .font(.inter(11, relativeTo: .caption))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "newspaper")
                        .font(.inter(32, relativeTo: .largeTitle))
                        .foregroundColor(.secondary)
                    Text("No news available")
                        .font(.inter(12, relativeTo: .body))
                        .foregroundColor(.secondary)
                    Button("Refresh") {
                        Task { await stockService.refreshNews(storageService: storageService, force: true) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            let news = filteredNews
            if news.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.inter(24, relativeTo: .title)).foregroundColor(.secondary)
                    Text("No stories match")
                        .font(.inter(11, relativeTo: .caption)).foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(news) { article in
                            NewsRow(article: article) { selected in
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
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary).font(.inter(10, relativeTo: .caption))
            TextField("Search news or ticker", text: $query)
                .textFieldStyle(.plain)
                .font(.inter(11, relativeTo: .caption))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary).font(.inter(10, relativeTo: .caption))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }
}

/// A single news story row: headline, ticker chips, publisher badge · relative time.
private struct NewsRow: View {
    let article: NewsArticle
    let onSelect: (NewsArticle) -> Void
    @EnvironmentObject private var storageService: StorageService
    @ObservedObject private var translationService = NewsTranslationService.shared
    @Environment(\.locale) private var locale
    @State private var hovering = false

    private var relativeTime: String {
        guard article.publishTime > 0 else { return "" }
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .abbreviated
        return f.localizedString(for: article.publishedAt, relativeTo: Date())
    }

    /// The stock this story is about: the tracked symbol it was fetched for,
    /// falling back to the first related ticker (general-market news).
    private var referenceTicker: String? {
        article.sourceSymbol ?? article.relatedTickers.first
    }

    /// Up to two more related tickers, excluding the reference one.
    private var otherTickers: [String] {
        Array(article.relatedTickers.filter { $0 != referenceTicker }.prefix(2))
    }

    var body: some View {
        Button {
            onSelect(article)
        } label: {
            HStack(alignment: .top, spacing: 10) {
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
                        .font(.inter(13, weight: .semibold, relativeTo: .body))
                        .foregroundStyle(DS.ink)
                        .lineLimit(3)
                        .lineSpacing(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .animation(.easeInOut(duration: 0.2), value: translated)

                    HStack(spacing: 6) {
                        if let ref = referenceTicker {
                            TickerChip(text: ref, emphasized: true)
                            ForEach(otherTickers, id: \.self) { ticker in
                                TickerChip(text: ticker, emphasized: false)
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

                        Spacer(minLength: 4)

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(hovering ? DS.inkSecondary : DS.inkTertiary.opacity(0.5))
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.05) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(article.title)
    }
}

/// A compact ticker pill shown next to a news story. The reference stock (the one
/// the story is about) is emphasized with a filled accent background; other
/// related tickers get a subtle tinted background.
private struct TickerChip: View {
    let text: String
    let emphasized: Bool

    var body: some View {
        HStack(spacing: 3) {
            SymbolLogo(symbol: text, size: 12)
            Text(verbatim: text)
                .font(.inter(9, weight: .bold, relativeTo: .caption2))
        }
        .foregroundColor(emphasized ? .white : DS.brand)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(emphasized ? DS.brand : DS.brand.opacity(0.12))
        )
    }
}
