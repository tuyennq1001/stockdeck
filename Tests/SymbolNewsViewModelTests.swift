import XCTest
import Combine
@testable import StockDeck

@MainActor
final class SymbolNewsViewModelTests: XCTestCase {
    private func article(_ id: String) -> NewsArticle {
        NewsArticle(id: id, title: id, publisher: "", link: "", publishTime: 0,
                    thumbnailURL: nil, relatedTickers: [])
    }

    func testUnrelatedNewsAndIdenticalSnapshotsDoNotPublishRows() {
        let item = article("tracked")
        let source = CurrentValueSubject<[String: [NewsArticle]], Never>(["VGT": [item]])
        let model = SymbolNewsViewModel()
        var publications = 0
        let subscription = model.$rows.dropFirst().sink { _ in publications += 1 }
        model.bind(to: source.eraseToAnyPublisher(), symbol: "vgt")
        XCTAssertEqual(publications, 1)
        source.send(["VGT": [item], "VOO": [article("unrelated")]])
        source.send(["VGT": [item]])
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(model.rows.map(\.article), [item])
        XCTAssertEqual(model.rows.first?.relativeTime, "")
        source.send(["VGT": [article("changed")]])
        XCTAssertEqual(publications, 2)
        withExtendedLifetime(subscription) {}
    }

    func testRebindingCancelsOldSymbolSubscriptionAndClearsAbsentNews() {
        let source = CurrentValueSubject<[String: [NewsArticle]], Never>(["VGT": [article("old")]])
        let model = SymbolNewsViewModel()
        model.bind(to: source.eraseToAnyPublisher(), symbol: "VGT")
        model.bind(to: source.eraseToAnyPublisher(), symbol: "VOO")
        XCTAssertTrue(model.rows.isEmpty)
        source.send(["VGT": [article("old-update")], "VOO": [article("current")]])
        XCTAssertEqual(model.rows.map(\.id), ["current"])
    }
}
