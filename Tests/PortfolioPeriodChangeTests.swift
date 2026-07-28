import XCTest
@testable import StockDeck

/// Covers the hero-pill period change: the delta between the first and last
/// points of the drawn value curve, so the pill reflects the selected range
/// (24H/7D/1M/1Y/All) rather than always the day-over-day move.
final class PortfolioPeriodChangeTests: XCTestCase {

    private func day(_ d: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(d * 86400)) }
    private func pt(_ d: Int, _ v: Double) -> ValuePoint { ValuePoint(date: day(d), value: v) }

    func testPercentOverSpan() {
        let points = [pt(1, 100), pt(2, 110), pt(3, 120)]
        XCTAssertEqual(PortfolioPeriodChange.percent(points) ?? 0, 20, accuracy: 1e-9)
        XCTAssertEqual(PortfolioPeriodChange.value(points) ?? 0, 20, accuracy: 1e-9)
    }

    func testNegativeSpan() {
        let points = [pt(1, 200), pt(2, 150)]
        XCTAssertEqual(PortfolioPeriodChange.percent(points) ?? 0, -25, accuracy: 1e-9)
        XCTAssertEqual(PortfolioPeriodChange.value(points) ?? 0, -50, accuracy: 1e-9)
    }

    /// Different windows over the same curve must yield different figures — the
    /// bug was that the pill never changed with the range.
    func testDifferentWindowsDiffer() {
        let full = [pt(1, 100), pt(2, 105), pt(3, 90), pt(4, 108)]
        let lastTwo = Array(full.suffix(2))
        XCTAssertNotEqual(PortfolioPeriodChange.percent(full),
                          PortfolioPeriodChange.percent(lastTwo))
    }

    func testTooFewPointsIsNil() {
        XCTAssertNil(PortfolioPeriodChange.percent([pt(1, 100)]))
        XCTAssertNil(PortfolioPeriodChange.percent([]))
        XCTAssertNil(PortfolioPeriodChange.value([pt(1, 100)]))
    }

    func testDegenerateBaseIsNil() {
        // First point ~0 → percent undefined, but absolute value still defined.
        let points = [pt(1, 0), pt(2, 50)]
        XCTAssertNil(PortfolioPeriodChange.percent(points))
        XCTAssertEqual(PortfolioPeriodChange.value(points) ?? -1, 50, accuracy: 1e-9)
    }

    func testCAGRCalculation() {
        // 100 to 144 over 2 years (730 days) -> CAGR = sqrt(1.44) - 1 = 20%
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 730.5 * 86400)
        let pts = [ValuePoint(date: start, value: 100), ValuePoint(date: end, value: 144)]

        let cagr = PortfolioPeriodChange.cagr(pts)
        XCTAssertNotNil(cagr)
        XCTAssertEqual(cagr ?? 0, 20.0, accuracy: 0.1)

        // Short period (< 350 days) should return nil
        let shortEnd = Date(timeIntervalSince1970: 100 * 86400)
        let shortPts = [ValuePoint(date: start, value: 100), ValuePoint(date: shortEnd, value: 120)]
        XCTAssertNil(PortfolioPeriodChange.cagr(shortPts))
    }
}
