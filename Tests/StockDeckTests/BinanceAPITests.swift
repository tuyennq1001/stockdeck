import XCTest
@testable import StockDeck

final class BinanceAPITests: XCTestCase {
    func testPortfolioSourceTypeEncodingDecoding() throws {
        let manualPortfolio = Portfolio(name: "Manual Tech", sourceType: .manual)
        XCTAssertFalse(manualPortfolio.isReadOnly)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let manualData = try encoder.encode(manualPortfolio)
        let decodedManual = try decoder.decode(Portfolio.self, from: manualData)
        XCTAssertEqual(decodedManual.sourceType, .manual)
        XCTAssertFalse(decodedManual.isReadOnly)

        let binancePortfolio = Portfolio(name: "Binance Crypto", sourceType: .binance(keychainId: "test-id-123"))
        XCTAssertTrue(binancePortfolio.isReadOnly)

        let binanceData = try encoder.encode(binancePortfolio)
        let decodedBinance = try decoder.decode(Portfolio.self, from: binanceData)
        XCTAssertEqual(decodedBinance.sourceType, .binance(keychainId: "test-id-123"))
        XCTAssertTrue(decodedBinance.isReadOnly)
    }

    func testPortfolioBackwardCompatibilityDefaultsToManual() throws {
        let oldJSON = """
        {
            "id": "11111111-2222-3333-4444-555555555555",
            "name": "Legacy Portfolio",
            "holdings": []
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let portfolio = try decoder.decode(Portfolio.self, from: oldJSON)
        XCTAssertEqual(portfolio.sourceType, .manual)
        XCTAssertFalse(portfolio.isReadOnly)
    }

    func testBinanceHMACSHA256Signature() throws {
        let service = BinanceAPIService.shared
        let message = "symbol=LTCBTC&side=BUY&type=LIMIT&timeInForce=GTC&quantity=1&price=0.1&recvWindow=5000&timestamp=1499827319559"
        let secret = "NhqPtFormatSampleSecretKeyForTestingHMAC"
        
        let signature = service.hmacHMAC256(message: message, secret: secret)
        XCTAssertNotNil(signature)
        XCTAssertFalse(signature!.isEmpty)
    }

    func testBinanceAssetBalanceQuantityCalculation() throws {
        let balance = BinanceAssetBalance(asset: "BTC", free: "0.5", locked: "0.1")
        XCTAssertEqual(balance.totalQuantity, 0.6, accuracy: 1e-9)
    }

    func testBinanceAssetBalanceIncludesFreezeAndWithdrawing() throws {
        let balance = BinanceAssetBalance(asset: "BTC", free: "0.5", locked: "0.1", freeze: "0.2", withdrawing: "0.05")
        XCTAssertEqual(balance.totalQuantity, 0.85, accuracy: 1e-9)
    }

    func testBinanceMarginNetEquitySubtractsBorrowedAndInterest() throws {
        let asset = BinanceMarginAsset(asset: "BTC", free: "1.0", locked: "0.5", borrowed: "0.3", interest: "0.05")
        // net equity = free + locked - borrowed - interest = 1.0 + 0.5 - 0.3 - 0.05 = 1.15
        XCTAssertEqual(asset.totalQuantity, 1.15, accuracy: 1e-9)

        // Negative net equity is possible when borrowed > available collateral
        let underwater = BinanceMarginAsset(asset: "BTC", free: "0.1", locked: "0.0", borrowed: "0.5", interest: "0.02")
        XCTAssertEqual(underwater.totalQuantity, -0.42, accuracy: 1e-9)
    }

    func testBinanceFuturesIncludesUnrealizedProfit() throws {
        let asset = BinanceFuturesAsset(asset: "USDT", walletBalance: "100.0", unrealizedProfit: "25.5")
        XCTAssertEqual(asset.totalQuantity, 125.5, accuracy: 1e-9)

        let loss = BinanceFuturesAsset(asset: "USDT", walletBalance: "100.0", unrealizedProfit: "-40.0")
        XCTAssertEqual(loss.totalQuantity, 60.0, accuracy: 1e-9)
    }

    func testBinanceStablecoinUSDPeggedList() throws {
        XCTAssertTrue(BinanceStablecoin.isUSDPegged("FDUSD"))
        XCTAssertTrue(BinanceStablecoin.isUSDPegged("TUSD"))
        XCTAssertTrue(BinanceStablecoin.isUSDPegged("DAI"))
        XCTAssertTrue(BinanceStablecoin.isUSDPegged("USDP"))
        XCTAssertTrue(BinanceStablecoin.isUSDPegged("PAXG"))
        XCTAssertTrue(BinanceStablecoin.isUSDPegged("BUSD"))
        XCTAssertTrue(BinanceStablecoin.isUSDPegged("USDT"))
        XCTAssertTrue(BinanceStablecoin.isUSDPegged("USDC"))
        XCTAssertFalse(BinanceStablecoin.isUSDPegged("PEPE"))
        XCTAssertFalse(BinanceStablecoin.isUSDPegged("BTC"))
    }

    func testIsStandardCryptoSymbolExpandedList() throws {
        for symbol in ["PEPE-USD", "WIF-USD", "BONK-USD", "FLOKI-USD", "DOGS-USD", "PNUT-USD",
                       "ARB-USD", "OP-USD", "STRK-USD", "POL-USD", "METIS-USD",
                       "FET-USD", "RENDER-USD", "TAO-USD", "INJ-USD", "WLD-USD",
                       "ORDI-USD", "SATS-USD", "JUP-USD", "ENA-USD", "ONDO-USD",
                       "PYTH-USD", "AAVE-USD", "MKR-USD", "CRV-USD", "RUNE-USD",
                       "TIA-USD", "SEI-USD",
                       "FDUSD-USD", "TUSD-USD", "DAI-USD", "USDP-USD", "PAXG-USD"] {
            XCTAssertTrue(StorageService.isStandardCryptoSymbol(symbol), "\(symbol) should be standard crypto")
        }
        XCTAssertFalse(StorageService.isStandardCryptoSymbol("AAPL"))
        XCTAssertFalse(StorageService.isStandardCryptoSymbol("MSFT-USD"))
    }

    func testNormalizeBinanceHoldingSymbolExpandedStablecoins() throws {
        XCTAssertEqual(StorageService.normalizeBinanceHoldingSymbol("FDUSD-USD"), "FDUSD-USD")
        XCTAssertEqual(StorageService.normalizeBinanceHoldingSymbol("TUSD-USD"), "TUSD-USD")
        XCTAssertEqual(StorageService.normalizeBinanceHoldingSymbol("DAI-USD"), "DAI-USD")
        XCTAssertEqual(StorageService.normalizeBinanceHoldingSymbol("USDP-USD"), "USDP-USD")
        XCTAssertEqual(StorageService.normalizeBinanceHoldingSymbol("PAXG-USD"), "PAXG-USD")
        XCTAssertEqual(StorageService.normalizeBinanceHoldingSymbol("PEPE-USD"), "PEPE-USD")
    }

    func testBinanceEarnLDWrappersAreNotDoubleCounted() throws {
        let spot = [
            BinanceAssetBalance(asset: "LDBTC", free: "0.11475751"),
            BinanceAssetBalance(asset: "USDT", free: "1049.66"),
            BinanceAssetBalance(asset: "LDUSDT", free: "926.63194103")
        ]
        let earn = [
            BinanceEarnPosition(asset: "BTC", totalAmount: "0.11509176", amount: nil),
            BinanceEarnPosition(asset: "USDT", totalAmount: "1050.08780379", amount: nil)
        ]

        let balances = BinanceAPIService.mergeSpotAndEarnBalances(spot: spot, earn: earn)

        XCTAssertEqual(balances["BTC"] ?? 0, 0.11509176, accuracy: 1e-9)
        XCTAssertEqual(balances["USDT"] ?? 0, 2099.74780379, accuracy: 1e-9)
    }

    func testBinanceLDWrapperFallsBackWhenEarnEndpointOmitsAsset() throws {
        let spot = [
            BinanceAssetBalance(asset: "LDADA", free: "5.25"),
            BinanceAssetBalance(asset: "LDO", free: "3.0")
        ]

        let balances = BinanceAPIService.mergeSpotAndEarnBalances(spot: spot, earn: [])

        XCTAssertEqual(balances["ADA"] ?? 0, 5.25, accuracy: 1e-9)
        XCTAssertEqual(balances["LDO"] ?? 0, 3.0, accuracy: 1e-9)
    }

    func testNormalizeBinanceHoldingSymbol() throws {
        XCTAssertEqual(StorageService.normalizeBinanceHoldingSymbol("LDBTC-USD"), "BTC-USD")
        XCTAssertEqual(StorageService.normalizeBinanceHoldingSymbol("LDSOL-USD"), "SOL-USD")
        XCTAssertEqual(StorageService.normalizeBinanceHoldingSymbol("LDETH-USD"), "ETH-USD")
        XCTAssertEqual(StorageService.normalizeBinanceHoldingSymbol("LDUSDC-USD"), "USDC-USD")
        XCTAssertEqual(StorageService.normalizeBinanceHoldingSymbol("BTC-USD"), "BTC-USD")
    }

    func testCanonicalSymbolForEquitiesAndCrypto() throws {
        XCTAssertEqual(StockService.canonicalSymbol(for: "GOOGL"), "GOOGL")
        XCTAssertEqual(StockService.canonicalSymbol(for: "GOOG"), "GOOG")
        XCTAssertEqual(StockService.canonicalSymbol(for: "ALPHABET"), "GOOGL")
        XCTAssertEqual(StockService.canonicalSymbol(for: "EQ_ALPHABET"), "GOOGL")
        XCTAssertEqual(StockService.canonicalSymbol(for: "EQ_ALPHABET-USD"), "GOOGL")
        XCTAssertEqual(StockService.canonicalSymbol(for: "ALPHABET-USD"), "GOOGL")
        XCTAssertEqual(StockService.canonicalSymbol(for: "EQ_GOOGL"), "GOOGL")
        XCTAssertEqual(StockService.canonicalSymbol(for: "EQ_GOOGL-USD"), "GOOGL")
        XCTAssertEqual(StockService.canonicalSymbol(for: "FB"), "META")
        XCTAssertEqual(StockService.canonicalSymbol(for: "BTC-USD"), "BTC-USD")
        XCTAssertEqual(StockService.canonicalSymbol(for: "ETH-USD"), "ETH-USD")
    }

    // MARK: - Partial Spot cost basis → split holdings

    func testPartialSpotCostBasisSplitsHoldingIntoTwo() throws {
        let service = BinanceAPIService.shared
        let basis = BinanceEquityCostBasis(averagePrice: 64_692.90, purchaseDate: nil, coveredQuantity: 0.0212)

        let holdings = service.buildHoldings(
            assetName: "BTC",
            quantity: 0.131736,
            equityCosts: [:],
            spotCosts: ["BTC": basis]
        )

        XCTAssertEqual(holdings.count, 2, "Partial coverage should split into known + unknown cost holdings")

        let known = holdings.first { $0.hasKnownCostBasis }
        let unknown = holdings.first { !$0.hasKnownCostBasis }
        XCTAssertEqual(known?.quantity ?? 0, 0.0212, accuracy: 1e-9)
        XCTAssertEqual(known?.avgPrice ?? 0, 64_692.90, accuracy: 1e-9)
        XCTAssertEqual(unknown?.quantity ?? 0, 0.131736 - 0.0212, accuracy: 1e-9)
        XCTAssertTrue(unknown?.avgPrice.isNaN ?? false)

        let total = holdings.reduce(0) { $0 + $1.quantity }
        XCTAssertEqual(total, 0.131736, accuracy: 1e-9)
    }

    func testFullCoverageStaysSingleHolding() throws {
        let service = BinanceAPIService.shared
        let basis = BinanceEquityCostBasis(averagePrice: 60_000, purchaseDate: nil, coveredQuantity: 1.5)

        let holdings = service.buildHoldings(
            assetName: "ETH",
            quantity: 1.5,
            equityCosts: [:],
            spotCosts: ["ETH": basis]
        )

        XCTAssertEqual(holdings.count, 1)
        XCTAssertEqual(holdings[0].quantity, 1.5, accuracy: 1e-9)
        XCTAssertEqual(holdings[0].avgPrice, 60_000, accuracy: 1e-9)
    }

    func testMissingCostBasisStaysUnknown() throws {
        let service = BinanceAPIService.shared

        let holdings = service.buildHoldings(
            assetName: "SOL",
            quantity: 8.6,
            equityCosts: [:],
            spotCosts: [:]
        )

        XCTAssertEqual(holdings.count, 1)
        XCTAssertTrue(holdings[0].avgPrice.isNaN)
        XCTAssertFalse(holdings[0].hasKnownCostBasis)
    }

    func testDustRemainderIsNotSplit() throws {
        let service = BinanceAPIService.shared
        let basis = BinanceEquityCostBasis(averagePrice: 10_000, purchaseDate: nil, coveredQuantity: 0.996)

        let holdings = service.buildHoldings(
            assetName: "ADA",
            quantity: 1.0,
            equityCosts: [:],
            spotCosts: ["ADA": basis]
        )

        XCTAssertEqual(holdings.count, 1, "≤1% remainder should not produce a separate unknown-cost lot")
        XCTAssertEqual(holdings[0].quantity, 1.0, accuracy: 1e-9)
    }

    func testStablecoinAndEquityAreNeverSplit() throws {
        let service = BinanceAPIService.shared
        let basis = BinanceEquityCostBasis(averagePrice: 60_000, purchaseDate: nil, coveredQuantity: 0.5)

        let stable = service.buildHoldings(
            assetName: "USDT",
            quantity: 100.0,
            equityCosts: [:],
            spotCosts: [:]
        )
        XCTAssertEqual(stable.count, 1)
        XCTAssertEqual(stable[0].avgPrice, 1.0, accuracy: 1e-9)

        let equity = service.buildHoldings(
            assetName: "EQ_GOOGL",
            quantity: 3.0,
            equityCosts: ["EQ_GOOGL": basis],
            spotCosts: [:]
        )
        XCTAssertEqual(equity.count, 1)
        XCTAssertEqual(equity[0].symbol, "GOOGL")
        XCTAssertEqual(equity[0].avgPrice, 60_000, accuracy: 1e-9)
    }

    // MARK: - Load-time aggregation keeps partial cost basis split

    func testAggregateBinanceHoldingsKeepsPartialCostSplit() throws {
        let known = Holding(symbol: "LDBTC-USD", quantity: 0.0212, avgPrice: 64_692.90)
        let unknown = Holding(symbol: "BTC-USD", quantity: 0.1105, avgPrice: .nan)

        let aggregated = StorageService.aggregateBinanceHoldings([known, unknown])

        XCTAssertEqual(aggregated.count, 2)
        let knownAgg = aggregated.first { $0.hasKnownCostBasis }
        let unknownAgg = aggregated.first { !$0.hasKnownCostBasis }
        XCTAssertEqual(knownAgg?.symbol, "BTC-USD")
        XCTAssertEqual(knownAgg?.quantity ?? 0, 0.0212, accuracy: 1e-9)
        XCTAssertEqual(unknownAgg?.symbol, "BTC-USD")
        XCTAssertEqual(unknownAgg?.quantity ?? 0, 0.1105, accuracy: 1e-9)
    }

    func testAggregateBinanceHoldingsMergesSameCostKind() throws {
        let a = Holding(symbol: "LDETH-USD", quantity: 1.0, avgPrice: .nan)
        let b = Holding(symbol: "ETH-USD", quantity: 2.5, avgPrice: .nan)

        let aggregated = StorageService.aggregateBinanceHoldings([a, b])

        XCTAssertEqual(aggregated.count, 1)
        XCTAssertEqual(aggregated[0].symbol, "ETH-USD")
        XCTAssertEqual(aggregated[0].quantity, 3.5, accuracy: 1e-9)
        XCTAssertTrue(aggregated[0].avgPrice.isNaN)
    }

    func testAcquisitionDatesAppliedToHoldings() throws {
        let service = BinanceAPIService.shared
        let depositDate = Date(timeIntervalSince1970: 1700000000) // 2023-11-14
        let spotDate = Date(timeIntervalSince1970: 1710000000) // 2024-03-09
        let basis = BinanceEquityCostBasis(averagePrice: 60_000, purchaseDate: spotDate, coveredQuantity: 1.0)

        // SOL with no spot basis but with deposit/convert acquisition date
        let solHoldings = service.buildHoldings(
            assetName: "SOL",
            quantity: 5.0,
            equityCosts: [:],
            spotCosts: [:],
            acquisitionDates: ["SOL": depositDate]
        )
        XCTAssertEqual(solHoldings.count, 1)
        XCTAssertEqual(solHoldings[0].purchaseDate, depositDate)

        // BTC with spot cost basis earlier than deposit date -> uses earliest
        let btcHoldings = service.buildHoldings(
            assetName: "BTC",
            quantity: 1.0,
            equityCosts: [:],
            spotCosts: ["BTC": basis],
            acquisitionDates: ["BTC": Date(timeIntervalSince1970: 1720000000)]
        )
        XCTAssertEqual(btcHoldings.count, 1)
        XCTAssertEqual(btcHoldings[0].purchaseDate, spotDate)
    }
}

