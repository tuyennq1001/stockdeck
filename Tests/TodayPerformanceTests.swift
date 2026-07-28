import XCTest
@testable import StockDeck

final class TodayPerformanceTests: XCTestCase {
    private func input(
        quantity: Double,
        regularPrice: Double,
        previousClose: Double,
        rate: Double = 1,
        leverage: Double? = nil
    ) -> TodayPerformance.Input {
        TodayPerformance.Input(
            holding: Holding(symbol: "X", quantity: quantity, avgPrice: 0, leverage: leverage),
            regularPrice: regularPrice,
            previousClose: previousClose,
            rate: rate
        )
    }

    func testTotalsUsePreviousCloseQuantityAndFxRate() {
        let result = TodayPerformance.totals([
            input(quantity: 10, regularPrice: 110, previousClose: 100, rate: 0.9),
            input(quantity: 5, regularPrice: 48, previousClose: 50, rate: 2),
        ])

        XCTAssertEqual(result.gain, 70, accuracy: 1e-9)
        XCTAssertEqual(result.percent, 70 / 1400 * 100, accuracy: 1e-9)
    }

    func testPercentUsesPreviousClosePortfolioValue() {
        let result = TodayPerformance.totals([
            input(quantity: 10, regularPrice: 110, previousClose: 100),
        ])

        XCTAssertEqual(result.gain, 100, accuracy: 1e-9)
        XCTAssertEqual(result.percent, 10, accuracy: 1e-9)
    }

    func testLeverageAppliesToGainAndPreviousCloseValue() {
        let result = TodayPerformance.totals([
            input(quantity: 10, regularPrice: 110, previousClose: 100, leverage: 3),
        ])

        XCTAssertEqual(result.gain, 300, accuracy: 1e-9)
        XCTAssertEqual(result.percent, 10, accuracy: 1e-9)
    }

    func testEmptyPortfolioReturnsZero() {
        let result = TodayPerformance.totals([])
        XCTAssertEqual(result.gain, 0)
        XCTAssertEqual(result.percent, 0)
    }
}
