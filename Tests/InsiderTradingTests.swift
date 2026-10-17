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

        // US Equities (including Binance US equities)
        XCTAssertTrue(service.isEligibleUSSymbol("AAPL"))
        XCTAssertTrue(service.isEligibleUSSymbol("NVDA"))
        XCTAssertTrue(service.isEligibleUSSymbol("TSLA"))
        XCTAssertTrue(service.isEligibleUSSymbol("AAPL.US"))
        XCTAssertTrue(service.isEligibleUSSymbol("BRK.B"))
        XCTAssertTrue(service.isEligibleUSSymbol("EQ_META"))
        XCTAssertTrue(service.isEligibleUSSymbol("EQ_META-USD"))
        XCTAssertTrue(service.isEligibleUSSymbol("EQ_ALPHABET"))
        XCTAssertEqual(service.cleanSymbol("EQ_META-USD"), "META")
        XCTAssertEqual(service.cleanSymbol("EQ_ALPHABET"), "GOOGL")

        // Vietnam Equities (HOSE / HNX / UPCoM)
        XCTAssertEqual(service.market(for: "FPT"), .vn)
        XCTAssertEqual(service.market(for: "FPT.VN"), .vn)
        XCTAssertEqual(service.market(for: "VNM.HM"), .vn)
        XCTAssertEqual(service.market(for: "HPG"), .vn)
        XCTAssertTrue(service.isEligibleSymbol("FPT"))
        XCTAssertTrue(service.isEligibleVNSymbol("FPT.VN"))
        XCTAssertFalse(service.isEligibleUSSymbol("FPT.VN"))
        XCTAssertFalse(service.isEligibleUSSymbol("VNM.HM"))
        XCTAssertEqual(service.cleanSymbol("FPT.VN"), "FPT")
        XCTAssertEqual(service.cleanSymbol("VNM.HM"), "VNM")

        // Unsupported markets: Crypto, Japan, Korea, Europe, HK, Taiwan, Indices, Futures, ETFs
        let unsupportedSymbols = [
            "7203.T", "7203", "03311187", "9C311125", "ひふみプラス",
            "005930.KS", "035720.KQ",
            "0700.HK", "SHEL.L", "SAP.DE", "MC.PA", "2330.TW", "600519.SS", "TD.TO", "BHP.AX",
            "BTC-USD", "ETH-USD", "SOLUSDT", "BTCUSDC", "PEPE", "BTCETH",
            "^GSPC", "^VNINDEX", "VNINDEX", "HNXINDEX", "UPINDEX", "^N225",
            "GC=F", "CL=F", "USDJPY=X",
            "SPY", "VOO", "QQQ", "E1VFVN30", "FUEVFVND", ""
        ]
        for sym in unsupportedSymbols {
            XCTAssertEqual(service.market(for: sym), .unsupported, "Expected \(sym) to be .unsupported")
            XCTAssertFalse(service.isEligibleSymbol(sym), "Expected \(sym) to be ineligible")
            XCTAssertFalse(service.isEligibleUSSymbol(sym), "Expected \(sym) to not be US symbol")
        }
    }

    func testVNInsiderParser() {
        let now = Date(timeIntervalSince1970: 1_792_000_000) // ~Oct 2026
        let recentExecMs = Int64((now.timeIntervalSince1970 - 15 * 86400) * 1000)
        let pendingBeginMs = Int64((now.timeIntervalSince1970 - 5 * 86400) * 1000)
        let pendingEndMs = Int64((now.timeIntervalSince1970 + 20 * 86400) * 1000)
        let failedEndMs = Int64((now.timeIntervalSince1970 - 30 * 86400) * 1000)

        let sampleJSON = """
        {
          "Data": {
            "TotalCount": 4,
            "Data": [
              {
                "Stock": "HPG",
                "TransactionMan": "Trần Vũ Minh",
                "TransactionManPosition": "Con",
                "RelatedMan": "Trần Đình Long",
                "RelatedManPosition": "Chủ tịch HĐQT",
                "VolumeBeforeTransaction": 176391996,
                "PlanBuyVolume": 50000000,
                "PlanSellVolume": 0,
                "PlanBeginDate": "/Date(\(recentExecMs - 10 * 86400 * 1000))/",
                "PlanEndDate": "/Date(\(recentExecMs))/",
                "RealBuyVolume": 33291904,
                "RealSellVolume": 0,
                "RealEndDate": "/Date(\(recentExecMs))/",
                "PublishedDate": "/Date(\(recentExecMs))/",
                "VolumeAfterTransaction": 209683900,
                "TransactionNote": "",
                "TyLeSoHuu": 2.48,
                "ShareHolderCode": "LQ_81519",
                "OrderDate": "/Date(\(recentExecMs))/"
              },
              {
                "Stock": "HPG",
                "TransactionMan": "Trần Vũ Minh",
                "TransactionManPosition": "Con",
                "RelatedMan": "Trần Đình Long",
                "RelatedManPosition": "Chủ tịch HĐQT",
                "VolumeBeforeTransaction": 209683900,
                "PlanBuyVolume": 50000000,
                "PlanSellVolume": 0,
                "PlanBeginDate": "/Date(\(pendingBeginMs))/",
                "PlanEndDate": "/Date(\(pendingEndMs))/",
                "RealBuyVolume": 0,
                "RealSellVolume": 0,
                "RealEndDate": null,
                "PublishedDate": "/Date(\(pendingBeginMs))/",
                "VolumeAfterTransaction": 0,
                "TransactionNote": "",
                "TyLeSoHuu": 0,
                "ShareHolderCode": "LQ_81519",
                "OrderDate": "/Date(\(pendingBeginMs))/"
              },
              {
                "Stock": "HPG",
                "TransactionMan": "Phạm Minh Tuấn",
                "TransactionManPosition": "Phó Tổng GĐ",
                "RelatedMan": "",
                "RelatedManPosition": "",
                "VolumeBeforeTransaction": 2957848,
                "PlanBuyVolume": 490082,
                "PlanSellVolume": 0,
                "PlanBeginDate": "/Date(\(recentExecMs))/",
                "PlanEndDate": "/Date(\(recentExecMs))/",
                "RealBuyVolume": 490082,
                "RealSellVolume": 0,
                "RealEndDate": "/Date(\(recentExecMs))/",
                "PublishedDate": "/Date(\(recentExecMs))/",
                "VolumeAfterTransaction": 3447930,
                "TransactionNote": "Mua cp ESOP",
                "TyLeSoHuu": 0.20,
                "ShareHolderCode": "CEO_99721",
                "OrderDate": "/Date(\(recentExecMs))/"
              },
              {
                "Stock": "HPG",
                "TransactionMan": "Người Đăng Ký Thất Bại",
                "TransactionManPosition": "Thành viên HĐQT",
                "RelatedMan": "",
                "RelatedManPosition": "",
                "VolumeBeforeTransaction": 500000,
                "PlanBuyVolume": 0,
                "PlanSellVolume": 350000,
                "PlanBeginDate": "/Date(\(failedEndMs - 20 * 86400 * 1000))/",
                "PlanEndDate": "/Date(\(failedEndMs))/",
                "RealBuyVolume": 0,
                "RealSellVolume": 0,
                "RealEndDate": "/Date(\(failedEndMs))/",
                "PublishedDate": "/Date(\(failedEndMs))/",
                "VolumeAfterTransaction": 500000,
                "TransactionNote": "",
                "TyLeSoHuu": 0.05,
                "ShareHolderCode": "CEO_00001",
                "OrderDate": "/Date(\(failedEndMs))/"
              }
            ]
          }
        }
        """

        guard let data = sampleJSON.data(using: .utf8) else {
            XCTFail("Failed to encode sample VN JSON")
            return
        }

        let parsed = VNInsiderParser.parse(data: data, symbol: "HPG", now: now, lookbackMonths: 24)
        // Should include: 1 pending PLAN, 1 executed open-market buy, 1 ESOP buy; and skip the failed 0-volume registration
        XCTAssertEqual(parsed.count, 3)

        let pendingTx = parsed.first { $0.isPendingPlan }
        XCTAssertNotNil(pendingTx)
        XCTAssertEqual(pendingTx?.transactionCode, "PLAN")
        XCTAssertTrue(pendingTx?.isOpenMarket ?? false)
        XCTAssertTrue(pendingTx?.isBuy ?? false)
        XCTAssertEqual(pendingTx?.shares, 50_000_000)
        XCTAssertEqual(pendingTx?.displayRole, "Con — Chủ tịch HĐQT Trần Đình Long")

        let execBuy = parsed.first { $0.transactionCode == "P" }
        XCTAssertNotNil(execBuy)
        XCTAssertEqual(execBuy?.shares, 33_291_904)
        XCTAssertEqual(execBuy?.price, 0)
        XCTAssertTrue(execBuy?.isOpenMarket ?? false)
        XCTAssertEqual(execBuy?.transactionNote, "Đạt 67% ĐK")
        XCTAssertEqual(execBuy?.ownershipRatioAfter ?? 0, 2.48, accuracy: 1e-3)

        let esopTx = parsed.first { $0.transactionCode == "ESOP" }
        XCTAssertNotNil(esopTx)
        XCTAssertFalse(esopTx?.isOpenMarket ?? true)
        XCTAssertEqual(esopTx?.transactionNote, "Mua cp ESOP")
        XCTAssertEqual(esopTx?.displayRole, "Phó Tổng GĐ")
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

        // Share-based sentiment for VN disclosures (where price == 0)
        let vnBuy = InsiderTransaction(
            id: "vnBuy",
            symbol: "HPG",
            ownerName: "Insider VN 1",
            transactionDate: twoMonthsAgo,
            transactionCode: "P",
            acquiredDisposed: "A",
            shares: 5_000_000,
            price: 0,
            sharesOwnedFollowing: 10_000_000,
            isVNDisclosure: true
        )
        let vnSell = InsiderTransaction(
            id: "vnSell",
            symbol: "HPG",
            ownerName: "Insider VN 2",
            transactionDate: twoMonthsAgo,
            transactionCode: "S",
            acquiredDisposed: "D",
            shares: 1_000_000,
            price: 0,
            sharesOwnedFollowing: 2_000_000,
            isVNDisclosure: true
        )
        let vnSummary = service.computeSentiment(symbol: "HPG", transactions: [vnBuy, vnSell], lookbackMonths: 24)
        XCTAssertEqual(vnSummary.sentiment, .netBuying)
        XCTAssertEqual(vnSummary.netShares, 4_000_000, accuracy: 1e-4)
        XCTAssertEqual(vnSummary.buyShareRatio, 5.0 / 6.0, accuracy: 1e-4)
    }

    @MainActor
    func testResolvedPriceAndValueForVN() {
        let service = InsiderTradingService.shared
        let stockService = StockService.shared
        let date = Date()

        // 1. US Form 4 transaction retains explicit price
        let usTx = InsiderTransaction(
            id: "us1",
            symbol: "AAPL",
            ownerName: "Tim Cook",
            transactionDate: date,
            transactionCode: "S",
            acquiredDisposed: "D",
            shares: 10_000,
            price: 235.50,
            sharesOwnedFollowing: 3_000_000
        )
        XCTAssertEqual(service.resolvedPrice(for: usTx), 235.50, accuracy: 1e-4)
        XCTAssertEqual(service.resolvedTotalValue(for: usTx), 2_355_000, accuracy: 1e-4)

        // 2. VN transaction with priceHistory point in StockService
        let vnDate = Calendar.current.date(byAdding: .day, value: -10, to: date)!
        stockService.priceHistory["HPG.VN"] = [
            PricePoint(date: vnDate, close: 27000.0)
        ]

        let vnTx = InsiderTransaction(
            id: "vn1",
            symbol: "HPG",
            ownerName: "Trần Vũ Minh",
            transactionDate: vnDate,
            transactionCode: "P",
            acquiredDisposed: "A",
            shares: 1_000_000,
            price: 0,
            sharesOwnedFollowing: 200_000_000,
            isVNDisclosure: true
        )

        let resolvedP = service.resolvedPrice(for: vnTx, rawSymbol: "HPG.VN")
        XCTAssertEqual(resolvedP, 27000.0, accuracy: 1e-2)

        let resolvedVal = service.resolvedTotalValue(for: vnTx, rawSymbol: "HPG.VN")
        // 1,000,000 shares * 27,000 VND = 27,000,000,000 VND (27 tỷ ₫)
        XCTAssertEqual(resolvedVal, 27_000_000_000.0, accuracy: 1e-2)

        // 3. Sentiment includes resolved values
        let summary = service.computeSentiment(symbol: "HPG.VN", transactions: [vnTx], lookbackMonths: 24)
        XCTAssertEqual(summary.totalBuyValue, 27_000_000_000.0, accuracy: 1e-2)
        XCTAssertEqual(summary.buyValueRatio, 1.0, accuracy: 1e-4)
        XCTAssertEqual(summary.sentiment, .netBuying)
    }

    @MainActor
    func testRule10b51DetectionAndExclusion() {
        let meta10b51XML = """
        <?xml version="1.0"?>
        <ownershipDocument>
            <periodOfReport>2026-10-12</periodOfReport>
            <issuer>
                <issuerTradingSymbol>META</issuerTradingSymbol>
            </issuer>
            <reportingOwner>
                <reportingOwnerId>
                    <rptOwnerName>Olivan Javier</rptOwnerName>
                </reportingOwnerId>
                <reportingOwnerRelationship>
                    <isOfficer>1</isOfficer>
                    <officerTitle>Chief Operating Officer</officerTitle>
                </reportingOwnerRelationship>
            </reportingOwner>
            <nonDerivativeTransaction>
                <securityTitle><value>Class A Common Stock</value></securityTitle>
                <transactionDate><value>2026-10-12</value></transactionDate>
                <transactionCoding>
                    <transactionCode>S</transactionCode>
                    <rule10b5-1Checked>1</rule10b5-1Checked>
                    <footnoteId id="F1"/>
                </transactionCoding>
                <transactionAmounts>
                    <transactionShares><value>946</value></transactionShares>
                    <transactionPricePerShare><value>728.10</value></transactionPricePerShare>
                    <transactionAcquiredDisposedCode><value>D</value></transactionAcquiredDisposedCode>
                </transactionAmounts>
                <postTransactionAmounts>
                    <sharesOwnedFollowingTransaction><value>17540</value></sharesOwnedFollowingTransaction>
                </postTransactionAmounts>
            </nonDerivativeTransaction>
            <footnotes>
                <footnote id="F1">The sales reported were effected pursuant to a Rule 10b5-1 trading plan adopted on May 10, 2026.</footnote>
            </footnotes>
        </ownershipDocument>
        """

        guard let data = meta10b51XML.data(using: .utf8) else {
            XCTFail("Failed to encode meta10b51XML")
            return
        }

        let parsed = Form4XMLParser.parse(data: data, symbol: "META", filingId: "0001326801-26-000085", filingDate: Date())
        XCTAssertEqual(parsed.count, 1)
        let tx = parsed[0]
        XCTAssertEqual(tx.symbol, "META")
        XCTAssertEqual(tx.ownerName, "Olivan Javier")
        XCTAssertEqual(tx.shares, 946)
        XCTAssertEqual(tx.price, 728.10, accuracy: 1e-4)
        XCTAssertTrue(tx.isRule10b51, "Transaction should be recognized as Rule 10b5-1")

        // Discretionary trade has isRule10b51 == false
        let discretionaryBuy = InsiderTransaction(
            id: "disc1",
            symbol: "META",
            ownerName: "Zuckerberg Mark",
            transactionDate: Date(),
            transactionCode: "P",
            acquiredDisposed: "A",
            shares: 10_000,
            price: 700.0,
            sharesOwnedFollowing: 100_000_000,
            isRule10b51: false
        )
        XCTAssertFalse(discretionaryBuy.isRule10b51)

        // Exclude 10b5-1 filter test
        let allTrades = [tx, discretionaryBuy]
        let excluded10b51 = allTrades.filter { !$0.isRule10b51 }
        XCTAssertEqual(excluded10b51.count, 1)
        XCTAssertEqual(excluded10b51.first?.ownerName, "Zuckerberg Mark")

        // Sentiment without 10b5-1 reflects only discretionary buy
        let sentiment = InsiderTradingService.shared.computeSentiment(symbol: "META", transactions: excluded10b51, lookbackMonths: 24)
        XCTAssertEqual(sentiment.sentiment, .netBuying)
        XCTAssertEqual(sentiment.totalSellValue, 0)
        XCTAssertEqual(sentiment.totalBuyValue, 7_000_000)
    }

    @MainActor func testStorageServiceInsiderSettings() {
        let storage = StorageService()
        XCTAssertTrue(storage.showInsiderMarkers)
        XCTAssertTrue(storage.excludeInsider10b51)
        XCTAssertTrue(storage.insiderOpenMarketOnly)

        storage.showInsiderMarkers = false
        storage.excludeInsider10b51 = false
        storage.insiderOpenMarketOnly = false

        let exported = storage.exportAppData()
        XCTAssertEqual(exported.showInsiderMarkers, false)
        XCTAssertEqual(exported.excludeInsider10b51, false)
        XCTAssertEqual(exported.insiderOpenMarketOnly, false)

        storage.resetToDefaults()
        XCTAssertTrue(storage.showInsiderMarkers)
        XCTAssertTrue(storage.excludeInsider10b51)
        XCTAssertTrue(storage.insiderOpenMarketOnly)
    }
}
