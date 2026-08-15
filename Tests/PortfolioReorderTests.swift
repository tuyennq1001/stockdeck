import XCTest
@testable import StockDeck

final class PortfolioReorderTests: XCTestCase {

    @MainActor
    private func createTestStorage() -> StorageService {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("test_stockdeck.json")
        return StorageService(fileURL: fileURL)
    }

    @MainActor
    func testMovePortfolioBeforeOrAfter() {
        let storage = createTestStorage()
        let p1 = storage.createPortfolio(name: "A")
        let p2 = storage.createPortfolio(name: "B")
        let p3 = storage.createPortfolio(name: "C")

        XCTAssertEqual(storage.portfolios.map(\.name), ["A", "B", "C"])

        // Move C before A
        storage.movePortfolio(from: p3.id, beforeOrAfter: p1.id)
        XCTAssertEqual(storage.portfolios.map(\.name), ["C", "A", "B"])

        // Move C before B (already adjacent, order should stay stable)
        storage.movePortfolio(from: p3.id, beforeOrAfter: p2.id)
        XCTAssertEqual(storage.portfolios.map(\.name), ["A", "C", "B"])

        // Moving onto itself is a no-op
        storage.movePortfolio(from: p2.id, beforeOrAfter: p2.id)
        XCTAssertEqual(storage.portfolios.map(\.name), ["A", "C", "B"])
    }

    @MainActor
    func testMovePortfolioPreservesHoldings() {
        let storage = createTestStorage()
        let p1 = storage.createPortfolio(name: "A")
        let p2 = storage.createPortfolio(name: "B")
        let p3 = storage.createPortfolio(name: "C")

        storage.addHolding(to: p1.id, symbol: "AAPL", quantity: 10, avgPrice: 100)
        storage.addHolding(to: p3.id, symbol: "TSLA", quantity: 5, avgPrice: 200)

        storage.movePortfolio(from: p3.id, beforeOrAfter: p1.id)

        XCTAssertEqual(storage.portfolios.map(\.name), ["C", "A", "B"])
        XCTAssertEqual(storage.portfolios[0].holdings.map(\.symbol), ["TSLA"])
        XCTAssertEqual(storage.portfolios[1].holdings.map(\.symbol), ["AAPL"])
        XCTAssertTrue(storage.portfolios[2].holdings.isEmpty)
    }

    @MainActor
    func testMovePortfolioToEnd() {
        let storage = createTestStorage()
        let p1 = storage.createPortfolio(name: "A")
        let p2 = storage.createPortfolio(name: "B")
        let p3 = storage.createPortfolio(name: "C")

        // Move A after C (drop on the last tab moves it into position before C
        // so the last tab stays the anchor; the net effect is A lands last).
        storage.movePortfolio(from: p1.id, beforeOrAfter: p3.id)
        XCTAssertEqual(storage.portfolios.map(\.name), ["B", "A", "C"])
    }

    @MainActor
    func testMovePortfolioAfterReachesEnd() {
        let storage = createTestStorage()
        let p1 = storage.createPortfolio(name: "A")
        let p2 = storage.createPortfolio(name: "B")
        let p3 = storage.createPortfolio(name: "C")

        // Dropping on the lower half of the last row = "after C" → A lands at
        // the very end of the list.
        storage.movePortfolio(from: p1.id, relativeTo: p3.id, placement: .after)
        XCTAssertEqual(storage.portfolios.map(\.name), ["B", "C", "A"])
    }

    @MainActor
    func testMovePortfolioAfterShiftsTargetWhenSourceIsBeforeIt() {
        let storage = createTestStorage()
        let p1 = storage.createPortfolio(name: "A")
        let p2 = storage.createPortfolio(name: "B")
        let p3 = storage.createPortfolio(name: "C")

        // Move B after A → [A, B, C] already satisfied; must be a no-op.
        storage.movePortfolio(from: p2.id, relativeTo: p1.id, placement: .after)
        XCTAssertEqual(storage.portfolios.map(\.name), ["A", "B", "C"])

        // Move B after C (target after removal) → B reaches the end.
        storage.movePortfolio(from: p2.id, relativeTo: p3.id, placement: .after)
        XCTAssertEqual(storage.portfolios.map(\.name), ["A", "C", "B"])
    }
}
