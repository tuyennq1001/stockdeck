import XCTest
@testable import StockDeck

final class MovingAverageTests: XCTestCase {

    // MARK: - SMA

    func testSMABasic() {
        XCTAssertEqual(MovingAverage.sma([1, 2, 3, 4], period: 4), 2.5)
    }

    func testSMATrailingWindowOnly() {
        let closes: [Double] = [100, 100, 100, 1, 2, 3]
        XCTAssertEqual(MovingAverage.sma(closes, period: 3), 2) // last three: 1,2,3
    }

    func testSMAInsufficientData() {
        XCTAssertNil(MovingAverage.sma([1, 2], period: 3))
        XCTAssertNil(MovingAverage.sma([], period: 200))
    }

    func testSMAExactBoundary() {
        var closes: [Double] = []
        for i in 1...200 { closes.append(Double(i)) }
        XCTAssertEqual(MovingAverage.sma(closes, period: 200), 100.5)
    }

    // MARK: - EMA

    func testEMAConstantSeriesStaysConstant() {
        // Any EMA of a constant series equals that constant.
        let closes = Array(repeating: 50.0, count: 300)
        XCTAssertEqual(MovingAverage.ema(closes, period: 200) ?? -1, 50.0, accuracy: 1e-9)
    }

    func testEMARespondsToRecentMoves() {
        // A flat series then a jump up: EMA trails below the latest value.
        var closes = Array(repeating: 100.0, count: 250)
        closes.append(200)
        let ema = MovingAverage.ema(closes, period: 200)
        XCTAssertNotNil(ema)
        XCTAssertLessThan(ema!, 200)
        XCTAssertGreaterThan(ema!, 100)
    }

    func testEMANilWhenEmpty() {
        XCTAssertNil(MovingAverage.ema([], period: 200))
    }

    // MARK: - Weekly resample + weekly SMA

    func testWeeklyClosesPicksLastCloseOfEachWeek() {
        let calendar = Calendar(identifier: .gregorian)
        let week1 = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1))! // Monday
        let week1Day2 = calendar.date(from: DateComponents(year: 2024, month: 1, day: 2))!
        let week2 = calendar.date(from: DateComponents(year: 2024, month: 1, day: 8))! // next Monday
        let points = [
            PricePoint(date: week1, close: 10),
            PricePoint(date: week1Day2, close: 20), // same week, last seen
            PricePoint(date: week2, close: 30),
        ]
        let weekly = MovingAverage.weeklyCloses(from: points, calendar: calendar)
        XCTAssertEqual(weekly, [20, 30])
    }

    func testWeeklySMAUsesWeeklyCloses() {
        // Flat 210 daily closes → every weekly close is 100, so the weekly SMA
        // is 100 regardless of how weeks are grouped by the current calendar.
        var points: [PricePoint] = []
        let calendar = Calendar(identifier: .gregorian)
        var base = calendar.date(from: DateComponents(year: 2020, month: 1, day: 6))!
        for _ in 0..<210 {
            points.append(PricePoint(date: base, close: 100))
            base = calendar.date(byAdding: .day, value: 1, to: base)!
        }
        XCTAssertEqual(MovingAverage.value(kind: .weeklySMA(period: 5), points: points), 100)
    }

    // MARK: - Cross evaluation

    func testFirstEvaluationPrimesWithoutFiring() {
        let r = MovingAverage.evaluateCross(condition: .priceAboveSMA200,
                                            average: 100, price: 150, wasAbove: nil)
        XCTAssertEqual(r?.fire, false)
        XCTAssertEqual(r?.nowAbove, true)
    }

    func testCrossAboveFiresOnSideChange() {
        let up = MovingAverage.evaluateCross(condition: .priceAboveSMA200,
                                             average: 100, price: 120, wasAbove: false)
        XCTAssertEqual(up?.fire, true)
        XCTAssertEqual(up?.nowAbove, true)

        let same = MovingAverage.evaluateCross(condition: .priceAboveSMA200,
                                               average: 100, price: 130, wasAbove: true)
        XCTAssertEqual(same?.fire, false) // still above — no new crossing
    }

    func testCrossBelowFiresOnSideChange() {
        let down = MovingAverage.evaluateCross(condition: .priceBelowSMA200,
                                               average: 100, price: 80, wasAbove: true)
        XCTAssertEqual(down?.fire, true)
        XCTAssertEqual(down?.nowAbove, false)
    }

    func testCrossNoDataReturnsNil() {
        XCTAssertNil(MovingAverage.evaluateCross(condition: .priceAboveSMA200,
                                                 average: nil, price: 120, wasAbove: false))
        XCTAssertNil(MovingAverage.evaluateCross(condition: .priceAboveSMA200,
                                                 average: 0, price: 120, wasAbove: false))
        XCTAssertNil(MovingAverage.evaluateCross(condition: .priceAboveSMA200,
                                                 average: 100, price: 0, wasAbove: false))
    }

    // MARK: - Kind mapping on conditions

    func testConditionMapsToKind() {
        XCTAssertEqual(AlertCondition.priceAboveSMA200.movingAverage, .sma(period: 200))
        XCTAssertEqual(AlertCondition.priceBelowEMA200.movingAverage, .ema(period: 200))
        XCTAssertEqual(AlertCondition.priceAboveWeeklySMA200.movingAverage, .weeklySMA(period: 200))
        XCTAssertNil(AlertCondition.priceAbove.movingAverage)
    }
}