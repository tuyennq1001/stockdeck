import Foundation
import Combine

/// Observe only this symbol's news. Quote ticks and other symbols' stories do
/// not publish rows or recreate relative-date formatters in the news card.
@MainActor
final class SymbolNewsViewModel: ObservableObject {
    struct Row: Identifiable {
        let article: NewsArticle
        let relativeTime: String
        var id: String { article.id }
    }

    @Published private(set) var rows: [Row] = []
    private var subscription: AnyCancellable?

    func bind(to publisher: AnyPublisher<[String: [NewsArticle]], Never>, symbol: String,
              locale: Locale = .current, now: Date = Date()) {
        subscription?.cancel()
        let key = symbol.uppercased()
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        subscription = publisher
            .map { $0[key] ?? [] }
            .removeDuplicates()
            .sink { [weak self] articles in
                self?.rows = articles.map { article in
                    Row(article: article, relativeTime: article.publishTime > 0
                        ? formatter.localizedString(for: article.publishedAt, relativeTo: now)
                        : "")
                }
            }
    }
}
