import SwiftUI
import Combine

/// Per-symbol finance news shown at the bottom of the symbol detail page
/// (below the notes card). Fetches on demand from Google News' public RSS
/// feed — no API key — and is throttled per symbol so opening a chart
/// repeatedly stays cheap.
struct SymbolNewsCard: View {
    let stockService: StockService
    let symbol: String
    var onSelectArticle: ((NewsArticle) -> Void)? = nil

    @EnvironmentObject private var storageService: StorageService
    @StateObject private var model = SymbolNewsViewModel()
    @State private var isLoading = false

    var body: some View {
        Card(title: "News") {
            VStack(spacing: 0) {
                if model.rows.isEmpty {
                    statusRow
                } else {
                    ForEach(model.rows) { newsRow in
                        NewsRowItemView(
                            newsRow: newsRow,
                            symbol: symbol,
                            onSelectArticle: onSelectArticle
                        )
                        if newsRow.id != model.rows.last?.id {
                            Divider()
                                .overlay(DS.hairline.opacity(0.6))
                                .padding(.horizontal, 4)
                        }
                    }
                }
            }
        }
        .task(id: symbol) {
            model.bind(to: stockService.$newsBySymbol.eraseToAnyPublisher(), symbol: symbol)
            isLoading = true
            defer { isLoading = false }
            await stockService.refreshNews(for: symbol)
            if let articles = stockService.newsBySymbol[symbol.uppercased()] {
                NewsTranslationService.shared.translateHeadlinesIfNeeded(articles: articles, storageService: storageService)
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if isLoading {
                DSSpinner(size: 11)
                Text("Loading news…")
            } else {
                Image(systemName: "newspaper").font(.system(size: 11)).foregroundStyle(DS.inkTertiary)
                Text("No recent news")
            }
        }
        .font(DS.caption)
        .foregroundStyle(DS.inkTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
    }
}

// MARK: - Row Item (Isolated Hover State for Performance)

private struct NewsRowItemView: View {
    let newsRow: SymbolNewsViewModel.Row
    let symbol: String
    var onSelectArticle: ((NewsArticle) -> Void)?

    @EnvironmentObject private var storageService: StorageService
    @ObservedObject private var translationService = NewsTranslationService.shared
    @State private var isHovered = false

    var body: some View {
        let article = newsRow.article
        Button {
            if let onSelectArticle {
                onSelectArticle(article)
            } else if let url = article.url {
                NSWorkspace.shared.open(url)
            }
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

                    HStack(spacing: 6) {
                        let pubText = article.publisher.isEmpty ? symbol : article.publisher
                        Text(verbatim: pubText)
                            .font(.inter(10.5, weight: .medium, relativeTo: .caption2))
                            .foregroundStyle(DS.inkSecondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.primary.opacity(0.06))
                            )

                        if article.publishTime > 0 && !newsRow.relativeTime.isEmpty {
                            Text("·")
                                .font(DS.micro)
                                .foregroundStyle(DS.inkTertiary)
                            Text(newsRow.relativeTime)
                                .font(DS.micro)
                                .foregroundStyle(DS.inkTertiary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isHovered ? DS.inkSecondary : DS.inkTertiary.opacity(0.5))
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            isHovered = inside
        }
    }
}
