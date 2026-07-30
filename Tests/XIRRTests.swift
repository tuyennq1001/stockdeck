import XCTest
@testable import StockDeck

final class XIRRTests: XCTestCase {
    func testSanityTwoFlows10Percent() {
        let date0 = Date(timeIntervalSince1970: 1_700_000_000)
        let date1 = date0.addingTimeInterval(365 * 86400)
        
        let flows = [
            CashFlow(date: date0, amount: -100.0),
            CashFlow(date: date1, amount: 110.0)
        ]
        
        guard let rate = XIRR.rate(flows) else {
            XCTFail("XIRR solver returned nil for simple 10% 1-year flow")
            return
        }
        
        XCTAssertEqual(rate, 0.10, accuracy: 1e-3)
    }
    
    func testMultiFlowKnownClosedForm() {
        let d0 = Date(timeIntervalSince1970: 1_700_000_000)
        let d1 = d0.addingTimeInterval(365 * 86400)
        let d2 = d0.addingTimeInterval(2 * 365 * 86400)
        
        // Two equal outflows of 100 at year 0 and year 1, terminal inflow of 231 at year 2
        // NPV(r) = -100 - 100/(1+r) + 231/(1+r)^2 = 0
        // -100*(1+r)^2 - 100*(1+r) + 231 = 0 => 100*(1+r)^2 + 100*(1+r) - 231 = 0
        // (1+r) = (-100 + sqrt(10000 + 92400))/200 = (-100 + 320)/200 = 1.10 => r = 0.10
        let flows = [
            CashFlow(date: d0, amount: -100.0),
            CashFlow(date: d1, amount: -100.0),
            CashFlow(date: d2, amount: 231.0)
        ]
        
        guard let rate = XIRR.rate(flows) else {
            XCTFail("XIRR solver returned nil for multi-flow case")
            return
        }
        
        XCTAssertEqual(rate, 0.10, accuracy: 1e-3)
    }
    
    func testEdgeCases() {
        // Less than 2 flows
        XCTAssertNil(XIRR.rate([]))
        XCTAssertNil(XIRR.rate([CashFlow(date: Date(), amount: -100)]))
        
        // All same sign
        XCTAssertNil(XIRR.rate([
            CashFlow(date: Date(), amount: 100),
            CashFlow(date: Date().addingTimeInterval(86400 * 100), amount: 200)
        ]))
        
        XCTAssertNil(XIRR.rate([
            CashFlow(date: Date(), amount: -100),
            CashFlow(date: Date().addingTimeInterval(86400 * 100), amount: -200)
        ]))
        
        // Duration less than 1 day
        XCTAssertNil(XIRR.rate([
            CashFlow(date: Date(), amount: -100),
            CashFlow(date: Date().addingTimeInterval(100), amount: 110)
        ]))
    }
}
