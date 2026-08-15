import SwiftUI

/// Per-symbol finance news shown at the bottom of the symbol detail page
/// (below the notes card). Fetches on demand from Google News' public RSS
/// feed — no API key — and is throttled per symbol so opening a chart
/// repeatedly stays cheap.
struct SymbolNewsCard: View {
    @ObservedObject var stockService: StockService
    let symbol: String

    @State private var activeLink: InAppWebLink?

    private var key: String { symbol.uppercased() }
    private var articles: [NewsArticle] { stockService.newsBySymbol[key] ?? [] }
    private var isLoading: Bool { stockService.isLoadingSymbolNews.contains(key) }

    var body: some View {
        Card(title: "News") {
            VStack(spacing: 0) {
                if articles.isEmpty {
                    statusRow
                } else {
                    ForEach(articles) { article in
                        row(article)
                        if article.id != articles.last?.id {
                            Divider().overlay(DS.hairline.opacity(0.6)).padding(.horizontal, 8)
                        }
                    }
                }
            }
        }
        .task(id: symbol) { await stockService.refreshNews(for: symbol) }
        .sheet(item: $activeLink) { link in
            InAppWebViewPopup(url: link.url)
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

    private func row(_ article: NewsArticle) -> some View {
        Button {
            if let url = article.url { activeLink = InAppWebLink(url: url) }
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
                    .frame(width: 56, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.hairline, lineWidth: 1))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(article.title)
                        .font(DS.body)
                        .foregroundStyle(DS.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(article.publisher.isEmpty ? symbol : article.publisher)
                            .font(DS.micro).foregroundStyle(DS.inkTertiary).lineLimit(1)
                        if article.publishTime > 0 {
                            Text("· \(relativeTime(article))").font(DS.micro).foregroundStyle(DS.inkTertiary).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(DS.inkTertiary)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func relativeTime(_ article: NewsArticle) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: article.publishedAt, relativeTo: Date())
    }
}