import XCTest
@testable import StockDeck

final class KeyStatisticsTests: XCTestCase {

    private func json(_ s: String) -> Data { s.data(using: .utf8)! }

    func testParseQuoteSummaryAllMetricsPresent() throws {
        let sample = """
        {
          "quoteSummary": {
            "result": [
              {
                "defaultKeyStatistics": {
                  "pegRatio": { "raw": 2.73, "fmt": "2.73" },
                  "enterpriseToEbitda": { "raw": 29.931, "fmt": "29.93" },
                  "beta": { "raw": 1.069, "fmt": "1.07" },
                  "profitMargins": { "raw": 0.25, "fmt": "25.00%" },
                  "bookValue": { "raw": 10.0 },
                  "sharesOutstanding": { "raw": 1000000000 },
                  "netIncomeToCommon": { "raw": 3000000000 }
                },
                "financialData": {
                  "returnOnEquity": { "raw": 1.4875, "fmt": "148.75%" },
                  "returnOnAssets": { "raw": 0.2708, "fmt": "27.08%" },
                  "profitMargins": { "raw": 0.2762, "fmt": "27.62%" },
                  "debtToEquity": { "raw": 78.445, "fmt": "78.44%" },
                  "totalDebt": { "raw": 5000000000 },
                  "totalCash": { "raw": 3000000000 },
                  "totalRevenue": { "raw": 20000000000 },
                  "operatingMargins": { "raw": 0.20 }
                }
              }
            ],
            "error": null
          }
        }
        """
        let stats = try StockService.parseQuoteSummaryResponse(json(sample))
        XCTAssertEqual(stats.pegRatio, 2.73)
        XCTAssertEqual(stats.enterpriseToEbitda, 29.931)
        XCTAssertEqual(stats.beta, 1.069)
        // ROE, ROA, Profit Margin multiplied by 100.0 for percent display
        XCTAssertEqual(try XCTUnwrap(stats.returnOnEquity), 148.75, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(stats.returnOnAssets), 27.08, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(stats.profitMargins), 27.62, accuracy: 0.001)
        // Debt to Equity
        XCTAssertEqual(try XCTUnwrap(stats.debtToEquity), 78.445, accuracy: 0.001)
        // ROIC: Equity = 10 * 1B = 10B, Invested Capital = 10B + 5B - 3B = 12B
        // EBIT = 20B * 0.20 = 4B, Tax Rate = 1 - 3/4 = 25% -> NOPAT = 3B -> ROIC = 3B / 12B = 25.0%
        XCTAssertEqual(try XCTUnwrap(stats.roic), 25.0, accuracy: 0.001)
        XCTAssertTrue(stats.hasData)
        XCTAssertTrue(stats.hasProfitabilityOrRisk)
    }

    func testParseQuoteSummaryWithEmptyObjects() throws {
        // Yahoo returns `{}` for metrics that have no data (e.g. Beta on 285A.T)
        let sample = """
        {
          "quoteSummary": {
            "result": [
              {
                "defaultKeyStatistics": {
                  "pegRatio": { "raw": 0.2, "fmt": "0.20" },
                  "enterpriseToEbitda": { "raw": 10.214, "fmt": "10.21" },
                  "beta": {}
                },
                "financialData": {
                  "returnOnEquity": { "raw": 0.8711, "fmt": "87.11%" },
                  "returnOnAssets": {},
                  "profitMargins": {}
                }
              }
            ],
            "error": null
          }
        }
        """
        let stats = try StockService.parseQuoteSummaryResponse(json(sample))
        XCTAssertEqual(stats.pegRatio, 0.2)
        XCTAssertEqual(stats.enterpriseToEbitda, 10.214)
        XCTAssertNil(stats.beta, "Empty object should decode as nil raw number")
        XCTAssertEqual(try XCTUnwrap(stats.returnOnEquity), 87.11, accuracy: 0.001)
        XCTAssertNil(stats.returnOnAssets)
        XCTAssertNil(stats.profitMargins)
        XCTAssertTrue(stats.hasData)
        XCTAssertTrue(stats.hasProfitabilityOrRisk)
    }

    func testParseQuoteSummaryEmptyResult() throws {
        let sample = """
        {
          "quoteSummary": {
            "result": [],
            "error": null
          }
        }
        """
        let stats = try StockService.parseQuoteSummaryResponse(json(sample))
        XCTAssertNil(stats.pegRatio)
        XCTAssertNil(stats.enterpriseToEbitda)
        XCTAssertNil(stats.beta)
        XCTAssertNil(stats.returnOnEquity)
        XCTAssertNil(stats.returnOnAssets)
        XCTAssertNil(stats.profitMargins)
        XCTAssertFalse(stats.hasData)
        XCTAssertFalse(stats.hasProfitabilityOrRisk)
    }

    func testProfitMarginsFallbackToDefaultKeyStatistics() throws {
        let sample = """
        {
          "quoteSummary": {
            "result": [
              {
                "defaultKeyStatistics": {
                  "profitMargins": { "raw": 0.185, "fmt": "18.50%" }
                },
                "financialData": {}
              }
            ],
            "error": null
          }
        }
        """
        let stats = try StockService.parseQuoteSummaryResponse(json(sample))
        XCTAssertEqual(try XCTUnwrap(stats.profitMargins), 18.5, accuracy: 0.001)
    }

    func testKeyStatisticsExpiration() {
        let recent = KeyStatistics(fetchedAt: Date())
        XCTAssertFalse(recent.isExpired)

        let expired = KeyStatistics(fetchedAt: Date().addingTimeInterval(-86401))
        XCTAssertTrue(expired.isExpired)
    }

    func testROICEdgeCases() throws {
        // Case 1: Invested Capital <= 0 (cash > equity + debt)
        let sampleNegativeCapital = """
        {
          "quoteSummary": {
            "result": [
              {
                "defaultKeyStatistics": {
                  "bookValue": { "raw": 2.0 },
                  "sharesOutstanding": { "raw": 1000000 }
                },
                "financialData": {
                  "totalDebt": { "raw": 0 },
                  "totalCash": { "raw": 5000000 },
                  "totalRevenue": { "raw": 10000000 },
                  "operatingMargins": { "raw": 0.2 }
                }
              }
            ],
            "error": null
          }
        }
        """
        let stats1 = try StockService.parseQuoteSummaryResponse(json(sampleNegativeCapital))
        XCTAssertNil(stats1.roic, "ROIC should be nil when invested capital is <= 0")

        // Case 2: Missing revenue or operating margin
        let sampleMissingRevenue = """
        {
          "quoteSummary": {
            "result": [
              {
                "defaultKeyStatistics": {
                  "bookValue": { "raw": 10.0 },
                  "sharesOutstanding": { "raw": 1000000 }
                },
                "financialData": {
                  "totalDebt": { "raw": 1000000 },
                  "totalCash": { "raw": 500000 }
                }
              }
            ],
            "error": null
          }
        }
        """
        let stats2 = try StockService.parseQuoteSummaryResponse(json(sampleMissingRevenue))
        XCTAssertNil(stats2.roic, "ROIC should be nil when revenue or operating margin is missing")
    }

    func testKeyStatisticsCodable() throws {
        let original = KeyStatistics(
            pegRatio: 1.5,
            enterpriseToEbitda: 12.3,
            beta: 0.95,
            returnOnEquity: 18.2,
            returnOnAssets: 7.4,
            roic: 22.8,
            profitMargins: 21.0,
            debtToEquity: 45.6,
            fetchedAt: Date(timeIntervalSince1970: 1700000000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(KeyStatistics.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testWatchlistMetricValuationPropertiesAndCodable() throws {
        let metrics: [WatchlistMetric] = [.pe, .forwardPe, .pb, .divYield, .eps, .marketCap]
        for m in metrics {
            XCTAssertEqual(m.category, .valuation)
        }
        XCTAssertEqual(WatchlistMetric.pe.title, "P/E")
        XCTAssertEqual(WatchlistMetric.forwardPe.title, "Fwd P/E")
        XCTAssertEqual(WatchlistMetric.pb.title, "P/B")
        XCTAssertEqual(WatchlistMetric.divYield.title, "Div Yield")
        XCTAssertEqual(WatchlistMetric.eps.title, "EPS")
        XCTAssertEqual(WatchlistMetric.marketCap.title, "Mkt Cap")

        let encoded = try JSONEncoder().encode(metrics)
        let decoded = try JSONDecoder().decode([WatchlistMetric].self, from: encoded)
        XCTAssertEqual(decoded, metrics)
    }

    func testPortfolioColumnMetricValuationPropertiesAndCodable() throws {
        let metrics: [PortfolioColumnMetric] = [.marketCap, .pe, .forwardPe, .pb, .divYield, .eps]
        for m in metrics {
            XCTAssertEqual(m.category, .valuation)
        }
        XCTAssertEqual(PortfolioColumnMetric.marketCap.title, "Mkt Cap")
        XCTAssertEqual(PortfolioColumnMetric.pe.title, "P/E")
        XCTAssertEqual(PortfolioColumnMetric.forwardPe.title, "Fwd P/E")
        XCTAssertEqual(PortfolioColumnMetric.pb.title, "P/B")
        XCTAssertEqual(PortfolioColumnMetric.divYield.title, "Div Yield")
        XCTAssertEqual(PortfolioColumnMetric.eps.title, "EPS")

        let encoded = try JSONEncoder().encode(metrics)
        let decoded = try JSONDecoder().decode([PortfolioColumnMetric].self, from: encoded)
        XCTAssertEqual(decoded, metrics)

        XCTAssertEqual(PortfolioColumnMetric.from(raw: "pe"), .pe)
        XCTAssertEqual(PortfolioColumnMetric.from(raw: "marketCap"), .marketCap)
        XCTAssertEqual(PortfolioColumnMetric.from(raw: "volume20w"), .volume50w)
        XCTAssertEqual(PortfolioColumnMetric.from(raw: "volume7d"), .volume50d)
    }

    @MainActor
    func testVietnameseQuoteValuationMerging() {
        let stockService = StockService.shared
        let vnQuote = StockQuote(
            symbol: "FPT",
            name: "FPT Corporation",
            price: 135000,
            change: 2500,
            changePercent: 1.88,
            currency: "VND",
            marketState: "REGULAR"
        )
        let yahooQuote = StockQuote(
            symbol: "FPT.VN",
            name: "FPT Corp",
            price: 135000,
            change: 2500,
            changePercent: 1.88,
            currency: "VND",
            marketCap: 180000000000000,
            trailingPE: 22.4,
            forwardPE: 19.1,
            priceToBook: 4.8,
            epsTrailingTwelveMonths: 6020,
            dividendYield: 1.6
        )

        stockService.quotes["FPT"] = vnQuote
        stockService.quotes["FPT.VN"] = yahooQuote

        stockService.mergeVietnameseValuationQuotes(for: ["FPT"])

        guard let merged = stockService.quotes["FPT"] else {
            XCTFail("Merged quote should exist")
            return
        }

        XCTAssertEqual(merged.price, 135000)
        XCTAssertEqual(merged.change, 2500)
        XCTAssertEqual(merged.currency, "VND")
        XCTAssertEqual(merged.trailingPE, 22.4)
        XCTAssertEqual(merged.forwardPE, 19.1)
        XCTAssertEqual(merged.priceToBook, 4.8)
        XCTAssertEqual(merged.dividendYield, 1.6)
        XCTAssertEqual(merged.epsTrailingTwelveMonths, 6020)
        XCTAssertEqual(merged.marketCap, 180000000000000)
    }

    func testWatchRowMetricValueValuation() {
        let q = StockQuote(
            symbol: "AAPL",
            name: "Apple Inc.",
            price: 220,
            change: 2.5,
            changePercent: 1.15,
            currency: "USD",
            marketCap: 3400000000000,
            trailingPE: 33.5,
            forwardPE: 28.2,
            priceToBook: 48.0,
            epsTrailingTwelveMonths: 6.57,
            dividendYield: 0.55
        )
        let row = WatchlistWideView.WatchRow(
            id: "AAPL",
            order: 0,
            symbol: "AAPL",
            name: "Apple Inc.",
            currency: "USD",
            isIndex: false,
            rate: 1.0,
            price: 220,
            extPrice: nil,
            extChangePercent: nil,
            extLabel: "",
            change: 2.5,
            changePercent: 1.15,
            oneMonthChangePercent: nil,
            threeMonthChangePercent: nil,
            sixMonthChangePercent: nil,
            ytdChangePercent: nil,
            oneYearChangePercent: nil,
            twoYearChangePercent: nil,
            threeYearChangePercent: nil,
            fiveYearChangePercent: nil,
            tenYearChangePercent: nil,
            allTimeHigh: nil,
            allTimeLow: nil,
            fromAthPercent: nil,
            fromAtlPercent: nil,
            history: [],
            allTimeHistory: [],
            loaded: true,
            quote: q,
            marketCap: 3400000000000,
            buyTarget: nil,
            toBuyTargetPercent: nil,
            isInBuyZone: false,
            isCrypto: false
        )

        XCTAssertEqual(row.metricValue(for: .pe), 33.5)
        XCTAssertEqual(row.metricValue(for: .forwardPe), 28.2)
        XCTAssertEqual(row.metricValue(for: .pb), 48.0)
        XCTAssertEqual(row.metricValue(for: .divYield), 0.55)
        XCTAssertEqual(row.metricValue(for: .eps), 6.57)
        XCTAssertEqual(row.metricValue(for: .marketCap), 3400000000000)
    }

    func testSimplizeCompanyResponseDecoding() throws {
        let sample = """
        {
          "status": 200,
          "message": "success",
          "data": {
            "ticker": "SHS",
            "peRatio": 12.45,
            "pbRatio": 1.12,
            "epsRatio": 1180.5,
            "marketCap": 9500000000000,
            "dividendYieldCurrent": 4.5,
            "bookValue": 13200.0,
            "roe": 10.8,
            "roa": 6.2,
            "beta5y": 1.35,
            "outstandingSharesValue": 813000000
          }
        }
        """
        let decoded = try JSONDecoder().decode(SimplizeCompanyResponse.self, from: json(sample))
        XCTAssertEqual(decoded.status, 200)
        let data = try XCTUnwrap(decoded.data)
        XCTAssertEqual(data.ticker, "SHS")
        XCTAssertEqual(data.peRatio, 12.45)
        XCTAssertEqual(data.pbRatio, 1.12)
        XCTAssertEqual(data.epsRatio, 1180.5)
        XCTAssertEqual(data.marketCap, 9500000000000)
        XCTAssertEqual(data.dividendYieldCurrent, 4.5)
        XCTAssertEqual(data.bookValue, 13200.0)
        XCTAssertEqual(data.roe, 10.8)
        XCTAssertEqual(data.roa, 6.2)
        XCTAssertEqual(data.beta5y, 1.35)
        XCTAssertEqual(data.outstandingSharesValue, 813000000)
    }

    func testFormatIndexTurnoverVietnameseAndEnglish() {
        let turnover = 13_547_688_000_000.0 // 13.548 nghìn tỷ VND
        let vnFormatted = StorageService.formatIndexTurnover(turnover, isVietnamese: true)
        XCTAssertEqual(vnFormatted, "13.548 tỷ ₫")

        let enFormatted = StorageService.formatIndexTurnover(turnover, isVietnamese: false)
        XCTAssertEqual(enFormatted, "₫13.55T")

        // Zero / negative / non-finite
        XCTAssertEqual(StorageService.formatIndexTurnover(0, isVietnamese: true), "—")
        XCTAssertEqual(StorageService.formatIndexTurnover(-100, isVietnamese: false), "—")
        XCTAssertEqual(StorageService.formatIndexTurnover(Double.nan, isVietnamese: true), "—")
    }

    func testVietnameseValuationCacheEntryExpiration() {
        let fresh = VietnameseValuationCacheEntry(
            trailingPE: 12.5,
            priceToBook: 1.2,
            eps: 1500,
            marketCap: 10_000_000_000,
            dividendYield: 3.5,
            bookValue: 12000,
            roe: 12.0,
            roa: 7.0,
            beta: 1.1,
            sharesOutstanding: 800_000_000,
            totalValue: nil,
            fetchedAt: Date()
        )
        XCTAssertFalse(fresh.isExpired)

        let stale = VietnameseValuationCacheEntry(
            trailingPE: 12.5,
            priceToBook: 1.2,
            eps: 1500,
            marketCap: 10_000_000_000,
            dividendYield: 3.5,
            bookValue: 12000,
            roe: 12.0,
            roa: 7.0,
            beta: 1.1,
            sharesOutstanding: 800_000_000,
            totalValue: nil,
            fetchedAt: Date().addingTimeInterval(-90000) // 25 hours ago
        )
        XCTAssertTrue(stale.isExpired)
    }

    func testVietnameseIndexSymbolsRecognition() {
        XCTAssertTrue(StockService.isIndexSymbol("VNINDEX"))
        XCTAssertTrue(StockService.isIndexSymbol("HNXINDEX"))
        XCTAssertTrue(StockService.isIndexSymbol("UPINDEX"))
        XCTAssertFalse(StockService.isIndexSymbol("SHS"))
        XCTAssertFalse(StockService.isIndexSymbol("HPG"))

        XCTAssertTrue(StockService.isVietnameseStock("VNINDEX"))
        XCTAssertTrue(StockService.isVietnameseStock("HNXINDEX"))
        XCTAssertTrue(StockService.isVietnameseStock("UPINDEX"))
        XCTAssertTrue(StockService.isVietnameseStock("SHS"))
    }
}

