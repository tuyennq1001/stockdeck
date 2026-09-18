import AppKit
import SwiftUI

/// Home tab: a compact finance news feed related to the user's tracked symbols
/// (or general market news when nothing is tracked). Tapping a story opens it
/// in the in-app browser.
struct HomeView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @State private var mode: HomeViewMode = .insights
    @State private var query = ""
    @State private var selectedNewsArticle: NewsArticle?
    @State private var isLoadingInsight = false
    @State private var insightError: String? = nil

    /// Filters by headline, tickers (source + related) and publisher.
    private var filteredNews: [NewsArticle] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return stockService.news }
        return stockService.news.filter { a in
            a.title.lowercased().contains(q)
            || a.publisher.lowercased().contains(q)
            || (a.sourceSymbol?.lowercased().contains(q) ?? false)
            || a.relatedTickers.contains { $0.lowercased().contains(q) }
        }
    }

    var body: some View {
        Group {
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
            } else {
                homeContent
            }
        }
        .task {
            _ = storageService.loadDailyAIInsight()
            await stockService.fetchFearGreedIndex()
            if storageService.hasAIConfiguration && (storageService.dailyAIInsight == nil || !Calendar.current.isDateInToday(storageService.dailyAIInsight!.date) || (storageService.dailyAIInsight?.language != nil && storageService.dailyAIInsight?.language != storageService.appLanguage)) {
                refreshInsights(force: false)
            }
            await stockService.refreshNews(storageService: storageService)
        }
        .onChange(of: storageService.appLanguage) { _, newLang in
            if storageService.hasAIConfiguration && storageService.dailyAIInsight?.language != newLang {
                refreshInsights(force: true)
            }
            Task {
                await stockService.refreshNews(storageService: storageService, force: true)
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
            modePicker
            Spacer()
            if mode == .news {
                searchField
            }
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
        .padding(.horizontal, 10)
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
                    LazyVStack(spacing: 0) {
                        ForEach(news) { article in
                            NewsRow(article: article) { selected in
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    selectedNewsArticle = selected
                                }
                            }
                            Divider().padding(.leading, 74)
                        }
                    }
                    .padding(.vertical, 4)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// A single news story row: thumbnail, headline, publisher · relative time, related tickers.
private struct NewsRow: View {
    let article: NewsArticle
    let onSelect: (NewsArticle) -> Void
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

    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            onSelect(article)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                thumbnail
                VStack(alignment: .leading, spacing: 4) {
                    Text(article.title)
                        .font(.inter(12, weight: .bold, relativeTo: .body))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if !article.content.isEmpty {
                        Text(article.content)
                            .font(.inter(11, relativeTo: .caption))
                            .foregroundColor(.secondary)
                            .lineSpacing(1.5)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 5) {
                        if !article.publisher.isEmpty {
                            Text(article.publisher)
                                .font(.inter(9.5, weight: .medium, relativeTo: .caption2))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        if !relativeTime.isEmpty {
                            Text("·").font(.inter(9.5, relativeTo: .caption2)).foregroundColor(.secondary)
                            Text(relativeTime)
                                .font(.inter(9.5, relativeTo: .caption2))
                                .foregroundColor(.secondary)
                        }
                        if let ref = referenceTicker {
                            Spacer(minLength: 4)
                            TickerChip(text: ref, emphasized: true)
                            ForEach(otherTickers, id: \.self) { ticker in
                                TickerChip(text: ticker, emphasized: false)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(hovering ? Color.secondary.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(article.title)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let thumb = article.thumbnailURL, let url = URL(string: thumb) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    placeholder
                default:
                    Rectangle().fill(Color.secondary.opacity(0.08))
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.secondary.opacity(0.08))
            .frame(width: 52, height: 52)
            .overlay(
                Image(systemName: "newspaper")
                    .font(.inter(16, relativeTo: .body))
                    .foregroundColor(.secondary)
            )
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
            SymbolLogo(symbol: text, size: 13)
            Text(text)
                .font(.inter(8, weight: .bold, relativeTo: .caption2))
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
