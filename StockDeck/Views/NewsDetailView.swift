import SwiftUI
import AppKit

/// In-app native Reader Mode detail view for news articles.
/// Renders clean typography, lead image, summary highlights, and extracted article body
/// without the lag, ads, or popover freeze issues of a full web browser.
struct NewsDetailView: View {
    @EnvironmentObject var stockService: StockService
    @EnvironmentObject var storageService: StorageService
    @Environment(\.showSymbolDetail) private var showSymbolDetail
    @Environment(\.openURL) private var openURL
    @Environment(\.locale) private var locale

    let article: NewsArticle
    let onBack: () -> Void

    @State private var crawledArticle: CrawledArticle?
    @State private var isLoadingBody = false

    private var displayTitle: String {
        if let crawledTitle = crawledArticle?.title, !crawledTitle.isEmpty,
           !crawledTitle.lowercased().contains("google news"),
           !crawledTitle.lowercased().contains("google tin tức") {
            return crawledTitle
        }
        return article.title
    }

    private var displayPublisher: String {
        if !article.publisher.isEmpty &&
           article.publisher.lowercased() != "google news" &&
           article.publisher.lowercased() != "google tin tức" {
            return article.publisher
        }
        if let pub = crawledArticle?.publisher, !pub.isEmpty,
           pub.lowercased() != "google news" && pub.lowercased() != "google tin tức" {
            return pub
        }
        return article.sourceSymbol ?? "News"
    }

    private var relativeTime: String {
        guard article.publishTime > 0 else { return "" }
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .abbreviated
        return f.localizedString(for: article.publishedAt, relativeTo: Date())
    }

    private var imageURLString: String? {
        if let lead = crawledArticle?.leadImageURL, !lead.isEmpty,
           !lead.contains("googleusercontent.com") && !lead.contains("gstatic.com") {
            return lead
        }
        if let thumb = article.thumbnailURL, !thumb.isEmpty,
           !thumb.contains("googleusercontent.com") && !thumb.contains("gstatic.com") {
            return thumb
        }
        return nil
    }

    private var bodyParagraphs: [String] {
        guard let crawled = crawledArticle else { return [] }
        let cleanTitle = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanArticleTitle = article.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleanContent = article.content.trimmingCharacters(in: .whitespacesAndNewlines)

        return crawled.paragraphs.filter { para in
            let cleanP = para.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanP.isEmpty else { return false }
            let lowerP = cleanP.lowercased()

            // Filter out exact duplicate of headline title
            if lowerP == cleanTitle || lowerP == cleanArticleTitle {
                return false
            }

            // Filter out duplicate or near duplicate of highlights card content
            if !cleanContent.isEmpty {
                if cleanP == cleanContent || lowerP == cleanContent.lowercased() {
                    return false
                }
                if cleanContent.count >= 20 && cleanP.hasPrefix(cleanContent) && cleanP.count < cleanContent.count + 25 {
                    return false
                }
            }

            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // Ticker pills
                    tickersRow

                    // Headline Title
                    Text(displayTitle)
                        .font(.inter(15, weight: .bold, relativeTo: .title3))
                        .foregroundStyle(DS.ink)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)

                    // Source & Timestamp metadata
                    HStack(spacing: 6) {
                        Image(systemName: "newspaper.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(DS.brand)
                        Text(displayPublisher)
                            .font(.inter(11, weight: .semibold, relativeTo: .caption))
                            .foregroundStyle(DS.inkSecondary)
                        if !relativeTime.isEmpty {
                            Text("·").font(DS.caption).foregroundStyle(DS.inkTertiary)
                            Text(relativeTime)
                                .font(DS.caption)
                                .foregroundStyle(DS.inkTertiary)
                        }
                    }

                    // Lead image if available
                    if let imgStr = imageURLString, let imgURL = URL(string: imgStr) {
                        AsyncImage(url: imgURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(maxHeight: 200)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .strokeBorder(DS.hairline, lineWidth: 1)
                                    )
                            default:
                                EmptyView()
                            }
                        }
                    }

                    // Key Summary / Highlights card
                    if !article.content.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 5) {
                                Image(systemName: "text.quote")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(DS.brand)
                                Text("Key Highlights")
                                    .font(.inter(10.5, weight: .bold, relativeTo: .caption2))
                                    .foregroundStyle(DS.brand)
                            }
                            Text(article.content)
                                .font(.inter(12, weight: .medium, relativeTo: .body))
                                .foregroundStyle(DS.ink)
                                .lineSpacing(2.5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(DS.cardAlt)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(DS.hairline, lineWidth: 1)
                        )
                    }

                    // Crawled article body paragraphs
                    if !bodyParagraphs.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(bodyParagraphs.enumerated()), id: \.offset) { _, para in
                                Text(para)
                                    .font(.inter(13, weight: .regular, relativeTo: .body))
                                    .foregroundStyle(DS.ink)
                                    .lineSpacing(3.5)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, 4)
                    } else if isLoadingBody {
                        HStack(spacing: 8) {
                            DSSpinner(size: 11)
                            Text("Loading complete story…")
                                .font(DS.caption)
                                .foregroundStyle(DS.inkTertiary)
                        }
                        .padding(.vertical, 8)
                    }

                    // Footer action to open original link in browser
                    externalSourceFooter
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.ground)
        .task(id: article.link) {
            await loadCrawledContent()
        }
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .bold))
                    Text("Back")
                        .font(.inter(12, weight: .medium, relativeTo: .body))
                }
                .foregroundStyle(DS.brand)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .keyboardShortcut(.cancelAction)

            Divider().frame(height: 14)

            Text(displayPublisher)
                .font(.inter(12, weight: .semibold, relativeTo: .subheadline))
                .foregroundStyle(DS.ink)
                .lineLimit(1)

            Spacer(minLength: 4)

            if let url = article.url {
                Button(action: {
                    openInBrowser(url)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "safari")
                            .font(.system(size: 11, weight: .medium))
                        Text("Open")
                            .font(.inter(11, weight: .medium, relativeTo: .caption))
                    }
                    .foregroundStyle(DS.inkSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(DS.hairline, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Open original article in default browser")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var tickersRow: some View {
        let reference = article.sourceSymbol ?? article.relatedTickers.first
        let others = article.relatedTickers.filter { $0 != reference }

        if reference != nil || !others.isEmpty {
            HStack(spacing: 6) {
                if let ref = reference {
                    Button(action: {
                        showSymbolDetail.perform(ref)
                    }) {
                        HStack(spacing: 4) {
                            SymbolLogo(symbol: ref, size: 14)
                            Text(ref)
                                .font(.inter(9.5, weight: .bold, relativeTo: .caption2))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(DS.brand))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }

                ForEach(others, id: \.self) { sym in
                    Button(action: {
                        showSymbolDetail.perform(sym)
                    }) {
                        HStack(spacing: 4) {
                            SymbolLogo(symbol: sym, size: 14)
                            Text(sym)
                                .font(.inter(9.5, weight: .bold, relativeTo: .caption2))
                        }
                        .foregroundStyle(DS.brand)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(DS.brand.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
                Spacer()
            }
        }
    }

    private var externalSourceFooter: some View {
        VStack(spacing: 8) {
            Divider().overlay(DS.hairline.opacity(0.8))
            if let url = article.url {
                Button(action: {
                    openInBrowser(url)
                }) {
                    HStack(spacing: 5) {
                        Text("Read original story on \(displayPublisher)")
                            .font(.inter(11, weight: .medium, relativeTo: .caption))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(DS.brand)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .padding(.top, 8)
    }

    private func openInBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private func loadCrawledContent() async {
        guard !article.link.isEmpty else { return }
        isLoadingBody = true
        let result = await ArticleCrawlerService.shared.fetchArticle(
            for: article.link,
            fallbackTitle: article.title,
            fallbackPublisher: article.publisher
        )
        crawledArticle = result
        isLoadingBody = false
    }
}
