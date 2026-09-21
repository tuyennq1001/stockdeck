import XCTest
@testable import StockDeck

final class InsiderTradingTests: XCTestCase {

    func testForm4XMLParser() {
        let sampleXML = """
        <?xml version="1.0"?>
        <ownershipDocument>
            <periodOfReport>2026-09-15</periodOfReport>
            <issuer>
                <issuerTradingSymbol>AAPL</issuerTradingSymbol>
            </issuer>
            <reportingOwner>
                <reportingOwnerId>
                    <rptOwnerName>Cook Timothy D</rptOwnerName>
                </reportingOwnerId>
                <reportingOwnerRelationship>
                    <isDirector>1</isDirector>
                    <isOfficer>1</isOfficer>
                    <officerTitle>Chief Executive Officer</officerTitle>
                </reportingOwnerRelationship>
            </reportingOwner>
            <nonDerivativeTransaction>
                <securityTitle><value>Common Stock</value></securityTitle>
                <transactionDate><value>2026-09-15</value></transactionDate>
                <transactionCoding>
                    <transactionCode>S</transactionCode>
                </transactionCoding>
                <transactionAmounts>
                    <transactionShares><value>14000</value></transactionShares>
                    <transactionPricePerShare><value>235.40</value></transactionPricePerShare>
                    <transactionAcquiredDisposedCode><value>D</value></transactionAcquiredDisposedCode>
                </transactionAmounts>
                <postTransactionAmounts>
                    <sharesOwnedFollowingTransaction><value>3280000</value></sharesOwnedFollowingTransaction>
                </postTransactionAmounts>
            </nonDerivativeTransaction>
            <nonDerivativeTransaction>
                <securityTitle><value>Common Stock</value></securityTitle>
                <transactionDate><value>2026-09-16</value></transactionDate>
                <transactionCoding>
                    <transactionCode>P</transactionCode>
                </transactionCoding>
                <transactionAmounts>
                    <transactionShares><value>5000</value></transactionShares>
                    <transactionPricePerShare><value>234.50</value></transactionPricePerShare>
                    <transactionAcquiredDisposedCode><value>A</value></transactionAcquiredDisposedCode>
                </transactionAmounts>
                <postTransactionAmounts>
                    <sharesOwnedFollowingTransaction><value>3285000</value></sharesOwnedFollowingTransaction>
                </postTransactionAmounts>
            </nonDerivativeTransaction>
        </ownershipDocument>
        """

        guard let data = sampleXML.data(using: .utf8) else {
            XCTFail("Failed to convert sample XML to data")
            return
        }

        let parsed = Form4XMLParser.parse(data: data, symbol: "AAPL", filingId: "0001140361-26-037020", filingDate: Date())
        XCTAssertEqual(parsed.count, 2)

        let sellTx = parsed[0]
        XCTAssertEqual(sellTx.symbol, "AAPL")
        XCTAssertEqual(sellTx.ownerName, "Cook Timothy D")
        XCTAssertEqual(sellTx.officerTitle, "Chief Executive Officer")
        XCTAssertTrue(sellTx.isDirector)
        XCTAssertTrue(sellTx.isOfficer)
        XCTAssertEqual(sellTx.transactionCode, "S")
        XCTAssertFalse(sellTx.isBuy)
        XCTAssertTrue(sellTx.isOpenMarket)
        XCTAssertEqual(sellTx.shares, 14000)
        XCTAssertEqual(sellTx.price, 235.40, accuracy: 1e-4)
        XCTAssertEqual(sellTx.totalValue, 14000 * 235.40, accuracy: 1e-4)
        XCTAssertEqual(sellTx.sharesOwnedFollowing, 3280000)

        let buyTx = parsed[1]
        XCTAssertEqual(buyTx.symbol, "AAPL")
        XCTAssertEqual(buyTx.transactionCode, "P")
        XCTAssertTrue(buyTx.isBuy)
        XCTAssertTrue(buyTx.isOpenMarket)
        XCTAssertEqual(buyTx.shares, 5000)
        XCTAssertEqual(buyTx.price, 234.50, accuracy: 1e-4)
    }

    func testTransactionProperties() {
        let tx = InsiderTransaction(
            id: "tx1",
            symbol: "NVDA",
            ownerName: "Huang Jen Hsun",
            officerTitle: "President and CEO",
            isDirector: true,
            isOfficer: true,
            isTenPercentOwner: false,
            transactionDate: Date(),
            transactionCode: "P",
            acquiredDisposed: "A",
            shares: 10000,
            price: 120.0,
            sharesOwnedFollowing: 5000000
        )

        XCTAssertTrue(tx.isBuy)
        XCTAssertTrue(tx.isOpenMarket)
        XCTAssertEqual(tx.totalValue, 1_200_000.0, accuracy: 1e-4)
        XCTAssertEqual(tx.codeDescription, "Open Market Buy")
        XCTAssertEqual(tx.displayRole, "President and CEO")

        // Zero price grant should NOT be open market
        let grantTx = InsiderTransaction(
            id: "tx2",
            symbol: "NVDA",
            ownerName: "Executive C",
            transactionDate: Date(),
            transactionCode: "A",
            acquiredDisposed: "A",
            shares: 5000,
            price: 0.0,
            sharesOwnedFollowing: 20000
        )
        XCTAssertFalse(grantTx.isOpenMarket)

        let zeroPriceSellTx = InsiderTransaction(
            id: "tx3",
            symbol: "V",
            ownerName: "Executive D",
            transactionDate: Date(),
            transactionCode: "S",
            acquiredDisposed: "D",
            shares: 1000,
            price: 0.0,
            sharesOwnedFollowing: 10000
        )
        XCTAssertFalse(zeroPriceSellTx.isOpenMarket)
    }

    func testSkipZeroPriceGrantXMLParsing() {
        let sampleXML = """
        <?xml version="1.0"?>
        <ownershipDocument>
            <periodOfReport>2026-08-20</periodOfReport>
            <issuer><issuerTradingSymbol>V</issuerTradingSymbol></issuer>
            <reportingOwner>
                <reportingOwnerId><rptOwnerName>McInerney Ryan</rptOwnerName></reportingOwnerId>
                <reportingOwnerRelationship><isOfficer>1</isOfficer><officerTitle>CEO</officerTitle></reportingOwnerRelationship>
            </reportingOwner>
            <!-- Valid Market Sell -->
            <nonDerivativeTransaction>
                <transactionDate><value>2026-08-20</value></transactionDate>
                <transactionCoding><transactionCode>S</transactionCode></transactionCoding>
                <transactionAmounts>
                    <transactionShares><value>5000</value></transactionShares>
                    <transactionPricePerShare><value>368.0</value></transactionPricePerShare>
                    <transactionAcquiredDisposedCode><value>D</value></transactionAcquiredDisposedCode>
                </transactionAmounts>
                <postTransactionAmounts><sharesOwnedFollowingTransaction><value>50000</value></sharesOwnedFollowingTransaction></postTransactionAmounts>
            </nonDerivativeTransaction>
            <!-- Zero-price Grant / Award -->
            <nonDerivativeTransaction>
                <transactionDate><value>2026-08-21</value></transactionDate>
                <transactionCoding><transactionCode>A</transactionCode></transactionCoding>
                <transactionAmounts>
                    <transactionShares><value>17900</value></transactionShares>
                    <transactionPricePerShare><value>0</value></transactionPricePerShare>
                    <transactionAcquiredDisposedCode><value>A</value></transactionAcquiredDisposedCode>
                </transactionAmounts>
                <postTransactionAmounts><sharesOwnedFollowingTransaction><value>67900</value></sharesOwnedFollowingTransaction></postTransactionAmounts>
            </nonDerivativeTransaction>
        </ownershipDocument>
        """

        guard let data = sampleXML.data(using: .utf8) else {
            XCTFail("Failed to convert sample XML to data")
            return
        }

        let parsed = Form4XMLParser.parse(data: data, symbol: "V", filingId: "test_filing", filingDate: Date())
        // The grant with price 0 must be skipped completely!
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].transactionCode, "S")
        XCTAssertEqual(parsed[0].price, 368.0)
    }

    func testSentimentSummary() {
        let bullish = InsiderSentimentSummary(
            symbol: "AAPL",
            lookbackMonths: 3,
            totalBuyShares: 50000,
            totalSellShares: 10000,
            totalBuyValue: 5_000_000,
            totalSellValue: 1_000_000,
            buyCount: 3,
            sellCount: 1,
            openMarketBuyCount: 3,
            openMarketSellCount: 1
        )
        XCTAssertEqual(bullish.sentiment, .netBuying)
        XCTAssertEqual(bullish.netValue, 4_000_000, accuracy: 1e-4)
        XCTAssertEqual(bullish.netShares, 40000, accuracy: 1e-4)

        let bearish = InsiderSentimentSummary(
            symbol: "NVDA",
            lookbackMonths: 3,
            totalBuyShares: 0,
            totalSellShares: 25000,
            totalBuyValue: 0,
            totalSellValue: 3_000_000,
            buyCount: 0,
            sellCount: 2,
            openMarketBuyCount: 0,
            openMarketSellCount: 2
        )
        XCTAssertEqual(bearish.sentiment, .netSelling)
        XCTAssertEqual(bearish.netValue, -3_000_000, accuracy: 1e-4)
    }

    @MainActor
    func testSymbolEligibility() {
        let service = InsiderTradingService.shared

        XCTAssertTrue(service.isEligibleUSSymbol("AAPL"))
        XCTAssertTrue(service.isEligibleUSSymbol("NVDA"))
        XCTAssertTrue(service.isEligibleUSSymbol("TSLA"))
        XCTAssertTrue(service.isEligibleUSSymbol("AAPL.US"))

        // Non-US symbols should be rejected
        XCTAssertFalse(service.isEligibleUSSymbol("FPT.VN"))
        XCTAssertFalse(service.isEligibleUSSymbol("VNM.HM"))
        XCTAssertFalse(service.isEligibleUSSymbol("7203.T"))
        XCTAssertFalse(service.isEligibleUSSymbol("BTC-USD"))
        XCTAssertFalse(service.isEligibleUSSymbol("ETH-USD"))
        XCTAssertFalse(service.isEligibleUSSymbol("^GSPC"))
        XCTAssertFalse(service.isEligibleUSSymbol("^VNINDEX"))
        XCTAssertFalse(service.isEligibleUSSymbol(""))
    }

    @MainActor
    func testComputeSentimentWithLookback() {
        let service = InsiderTradingService.shared
        let now = Date()
        let twoMonthsAgo = Calendar.current.date(byAdding: .month, value: -2, to: now)!
        let eightMonthsAgo = Calendar.current.date(byAdding: .month, value: -8, to: now)!

        let txRecent = InsiderTransaction(
            id: "txRecent",
            symbol: "AAPL",
            ownerName: "Executive A",
            transactionDate: twoMonthsAgo,
            transactionCode: "P",
            acquiredDisposed: "A",
            shares: 1000,
            price: 200.0,
            sharesOwnedFollowing: 10000
        )

        let txOld = InsiderTransaction(
            id: "txOld",
            symbol: "AAPL",
            ownerName: "Executive B",
            transactionDate: eightMonthsAgo,
            transactionCode: "S",
            acquiredDisposed: "D",
            shares: 5000,
            price: 190.0,
            sharesOwnedFollowing: 50000
        )

        // 3-month lookback only catches txRecent (Buy) -> Net Buying
        let sentiment3M = service.computeSentiment(symbol: "AAPL", transactions: [txRecent, txOld], lookbackMonths: 3)
        XCTAssertEqual(sentiment3M.sentiment, .netBuying)
        XCTAssertEqual(sentiment3M.buyCount, 1)
        XCTAssertEqual(sentiment3M.sellCount, 0)

        // 12-month lookback catches both -> Net Selling (old sell of 5000 shs > recent buy of 1000 shs)
        let sentiment12M = service.computeSentiment(symbol: "AAPL", transactions: [txRecent, txOld], lookbackMonths: 12)
        XCTAssertEqual(sentiment12M.sentiment, .netSelling)
        XCTAssertEqual(sentiment12M.buyCount, 1)
        XCTAssertEqual(sentiment12M.sellCount, 1)
    }
}
