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
}
