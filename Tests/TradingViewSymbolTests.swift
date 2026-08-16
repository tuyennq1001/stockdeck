import XCTest
@testable import StockDeck

final class TradingViewSymbolTests: XCTestCase {

    private func map(_ symbol: String, exchange: String = "") -> String? {
        TradingViewSymbol.map(symbol, exchange: exchange)
    }

    // MARK: - Indices

    func testUSIndices() {
        XCTAssertEqual(map("^GSPC"), "INDEX:SPX")
        XCTAssertEqual(map("^DJI"), "INDEX:DJI")
        XCTAssertEqual(map("^IXIC"), "INDEX:IXIC")
        XCTAssertEqual(map("^VIX"), "CBOE:VIX")
    }

    func testGlobalIndices() {
        XCTAssertEqual(map("^N225"), "INDEX:NKY")
        XCTAssertEqual(map("^KS11"), "INDEX:KOSPI")
        XCTAssertEqual(map("^VNINDEX.VN"), "INDEX:VNI")
        XCTAssertEqual(map("^HSI"), "INDEX:HSI")
        XCTAssertEqual(map("^FTSE"), "INDEX:UKX")
        XCTAssertEqual(map("^GDAXI"), "INDEX:GDAXI")
    }

    func testUnknownIndexFallsBackToNil() {
        XCTAssertNil(map("^UNKNOWN123"))
    }

    // MARK: - FX, futures & commodities

    func testFXPairs() {
        XCTAssertEqual(map("USDJPY=X"), "FX:USDJPY")
        XCTAssertEqual(map("EURUSD=X"), "FX:EURUSD")
        XCTAssertNil(map("AUD=X"))
    }

    func testIndexFutures() {
        XCTAssertEqual(map("ES=F"), "CME:ES1!")
        XCTAssertEqual(map("NQ=F"), "CME:NQ1!")
        XCTAssertEqual(map("YM=F"), "CBOT:YM1!")
    }

    func testCommodities() {
        XCTAssertEqual(map("GC=F"), "TVC:GOLD")
        XCTAssertEqual(map("SI=F"), "TVC:SILVER")
        XCTAssertEqual(map("CL=F"), "TVC:CL")
        XCTAssertEqual(map("BZ=F"), "TVC:BRENT")
    }

    func testUnknownFutureFallsBackToNil() {
        XCTAssertNil(map("XX=F"))
    }

    // MARK: - Crypto

    func testCryptoYahooStyle() {
        XCTAssertEqual(map("BTC-USD"), "CRYPTO:BTCUSD")
        XCTAssertEqual(map("ETH-USD"), "CRYPTO:ETHUSD")
        XCTAssertEqual(map("SOL-USD"), "CRYPTO:SOLUSD")
    }

    func testCryptoBinanceNative() {
        XCTAssertEqual(map("BTCUSDT"), "BINANCE:BTCUSDT")
        XCTAssertEqual(map("ETHUSDC"), "BINANCE:ETHUSDC")
    }

    // MARK: - Country exchanges

    func testUSStocks() {
        XCTAssertEqual(map("AAPL", exchange: "NASDAQ"), "NASDAQ:AAPL")
        XCTAssertEqual(map("JPM", exchange: "NYSE"), "NYSE:JPM")
        XCTAssertEqual(map("SPY", exchange: "NYSEARCA"), "NYSEARCA:SPY")
    }

    func testUSStockWithoutKnownExchangePassesRawTicker() {
        XCTAssertEqual(map("AAPL"), "AAPL")
        XCTAssertEqual(map("msft"), "MSFT")
    }

    func testVietnamStocks() {
        XCTAssertEqual(map("VCB.VN", exchange: "HOSE"), "HOSE:VCB")
        XCTAssertEqual(map("PVS.VN", exchange: "HNX"), "HNX:PVS")
        XCTAssertEqual(map("FPT", exchange: "HOSE"), "HOSE:FPT")
        XCTAssertEqual(map("VND", exchange: ""), "HOSE:VND")
    }

    func testHKRollsToTelco() {
        XCTAssertEqual(map("0700.HK"), "HKEX:0700")
        XCTAssertEqual(map("9988.HK"), "HKEX:9988")
    }

    func testJapaneseStocks() {
        XCTAssertEqual(map("7203.T"), "TSE:7203")
        XCTAssertEqual(map("6758.T"), "TSE:6758")
    }

    func testLondonAndFrankfurt() {
        XCTAssertEqual(map("RR.L"), "LSE:RR")
        XCTAssertEqual(map("VWCE.DE"), "XETR:VWCE")
    }

    // MARK: - Unsupported

    func testJapaneseMutualFundFallsBackToNil() {
        XCTAssertNil(map("04317188"))
        XCTAssertNil(map("03311187.JP"))
    }
}