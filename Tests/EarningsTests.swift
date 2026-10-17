import XCTest
@testable import StockDeck

final class EarningsTests: XCTestCase {

    func testQuarterResultBeatMiss() {
        let beatQuarter = EarningsQuarterResult(
            quarterDate: Date(timeIntervalSince1970: 1782777600),
            epsActual: 2.02,
            epsEstimate: 1.89,
            epsDifference: 0.13,
            surprisePercent: 0.0674,
            currency: "USD",
            period: "-1q"
        )
        XCTAssertEqual(beatQuarter.beatMiss, .beat)
        XCTAssertEqual(beatQuarter.surprisePercentFormatted, "+6.7%")

        let missQuarter = EarningsQuarterResult(
            quarterDate: Date(timeIntervalSince1970: 1774915200),
            epsActual: 1.50,
            epsEstimate: 1.65,
            epsDifference: -0.15,
            surprisePercent: -0.0909,
            currency: "USD",
            period: "-2q"
        )
        XCTAssertEqual(missQuarter.beatMiss, .miss)
        XCTAssertEqual(missQuarter.surprisePercentFormatted, "-9.1%")

        let inLineQuarter = EarningsQuarterResult(
            quarterDate: Date(timeIntervalSince1970: 1767139200),
            epsActual: 2.00,
            epsEstimate: 2.00,
            epsDifference: 0.0,
            surprisePercent: 0.0,
            currency: "USD",
            period: "-3q"
        )
        XCTAssertEqual(inLineQuarter.beatMiss, .inLine)
    }

    func testCountdownText() {
        let cal = Calendar.current
        let today = Date()

        let todayItem = EarningsReportItem(
            symbol: "AAPL",
            nextDate: today,
            session: .amc
        )
        XCTAssertTrue(todayItem.isToday)
        XCTAssertEqual(todayItem.countdownText, "Today")

        if let tomorrow = cal.date(byAdding: .day, value: 1, to: today) {
            let tomorrowItem = EarningsReportItem(
                symbol: "MSFT",
                nextDate: tomorrow,
                session: .bmo
            )
            XCTAssertTrue(tomorrowItem.isTomorrow)
            XCTAssertEqual(tomorrowItem.countdownText, "Tomorrow")
        }

        if let inFiveDays = cal.date(byAdding: .day, value: 5, to: today) {
            let fiveDaysItem = EarningsReportItem(
                symbol: "NVDA",
                nextDate: inFiveDays,
                session: .amc
            )
            XCTAssertEqual(fiveDaysItem.countdownText, "In 5d")
            XCTAssertTrue(fiveDaysItem.isUpcoming(withinDays: 7))
            XCTAssertFalse(fiveDaysItem.isUpcoming(withinDays: 3))
        }
    }

    func testCleanSymbolAndEligibility() {
        XCTAssertEqual(EarningsService.cleanSymbol("EQ_AAPL"), "AAPL")
        XCTAssertEqual(EarningsService.cleanSymbol("EQ_META-USD"), "META")
        XCTAssertEqual(EarningsService.cleanSymbol("tsla.us"), "TSLA")
        XCTAssertEqual(EarningsService.cleanSymbol(" GOOGL "), "GOOGL")

        XCTAssertTrue(EarningsService.isEligible(symbol: "AAPL"))
        XCTAssertTrue(EarningsService.isEligible(symbol: "EQ_NVDA"))

        // Exclusions
        XCTAssertFalse(EarningsService.isEligible(symbol: "^GSPC"))
        XCTAssertFalse(EarningsService.isEligible(symbol: "^VNINDEX"))
        XCTAssertFalse(EarningsService.isEligible(symbol: "SPY"))
        XCTAssertFalse(EarningsService.isEligible(symbol: "QQQ"))
        XCTAssertFalse(EarningsService.isEligible(symbol: "BTCUSDT"))
        XCTAssertFalse(EarningsService.isEligible(symbol: "EURUSD=X"))
        XCTAssertFalse(EarningsService.isEligible(symbol: "GC=F"))
    }

    func testParseYahooEarningsResponse() throws {
        let json = """
        {
          "quoteSummary": {
            "result": [
              {
                "calendarEvents": {
                  "earnings": {
                    "earningsDate": [
                      { "raw": 1793649600, "fmt": "2026-11-02" }
                    ],
                    "isEarningsDateEstimate": false,
                    "earningsAverage": { "raw": 1.98 },
                    "earningsLow": { "raw": 1.93 },
                    "earningsHigh": { "raw": 2.07 },
                    "revenueAverage": { "raw": 113626875100 }
                  }
                },
                "earningsHistory": {
                  "history": [
                    {
                      "quarter": { "raw": 1782777600, "fmt": "2026-06-30" },
                      "epsActual": { "raw": 2.02 },
                      "epsEstimate": { "raw": 1.89 },
                      "epsDifference": { "raw": 0.13 },
                      "surprisePercent": { "raw": 0.0674 },
                      "currency": "USD",
                      "period": "-1q"
                    },
                    {
                      "quarter": { "raw": 1774915200, "fmt": "2026-03-31" },
                      "epsActual": { "raw": 2.01 },
                      "epsEstimate": { "raw": 1.94 },
                      "epsDifference": { "raw": 0.07 },
                      "surprisePercent": { "raw": 0.0346 },
                      "currency": "USD",
                      "period": "-2q"
                    }
                  ]
                }
              }
            ],
            "error": null
          }
        }
        """

        let data = json.data(using: .utf8)!
        let item = try EarningsService.parseEarningsResponse(data: data, symbol: "AAPL")

        XCTAssertEqual(item.symbol, "AAPL")
        XCTAssertNotNil(item.nextDate)
        XCTAssertEqual(item.session, .amc) // 20:00 UTC -> AMC
        XCTAssertEqual(item.epsEstimate, 1.98)
        XCTAssertEqual(item.revenueEstimate, 113626875100)

        XCTAssertEqual(item.history.count, 2)
        // Should be sorted chronologically descending (newest quarter -1q first, then -2q)
        XCTAssertEqual(item.history.first?.period, "-1q")
        XCTAssertEqual(item.history.last?.period, "-2q")
        XCTAssertEqual(item.history.first?.beatMiss, .beat)
    }

    func testParseBmoSession() throws {
        // 12:30 UTC -> BMO
        let bmoTimestamp = 1793017800 // e.g. 12:30:00 UTC
        let json = """
        {
          "quoteSummary": {
            "result": [
              {
                "calendarEvents": {
                  "earnings": {
                    "earningsDate": [
                      { "raw": \(bmoTimestamp), "fmt": "2026-10-27" }
                    ],
                    "isEarningsDateEstimate": false,
                    "earningsAverage": { "raw": 0.85 }
                  }
                }
              }
            ]
          }
        }
        """

        let data = json.data(using: .utf8)!
        let item = try EarningsService.parseEarningsResponse(data: data, symbol: "KO")
        XCTAssertEqual(item.session, .bmo)
    }

    func testEarningsDiskCacheRoundTrip() throws {
        let originalItem = EarningsReportItem(
            symbol: "NVDA",
            companyName: "NVIDIA Corporation",
            nextDate: Date(timeIntervalSince1970: 1782777600),
            session: .amc,
            epsEstimate: 0.75,
            revenueEstimate: 32000000000,
            history: [
                EarningsQuarterResult(
                    quarterDate: Date(timeIntervalSince1970: 1774915200),
                    epsActual: 0.68,
                    epsEstimate: 0.64,
                    epsDifference: 0.04,
                    surprisePercent: 0.0625
                )
            ]
        )

        let encoded = try JSONEncoder().encode(originalItem)
        let decoded = try JSONDecoder().decode(EarningsReportItem.self, from: encoded)

        XCTAssertEqual(decoded.symbol, "NVDA")
        XCTAssertEqual(decoded.companyName, "NVIDIA Corporation")
        XCTAssertEqual(decoded.session, .amc)
        XCTAssertEqual(decoded.epsEstimate, 0.75)
        XCTAssertEqual(decoded.revenueEstimate, 32000000000)
        XCTAssertEqual(decoded.history.count, 1)
        XCTAssertEqual(decoded.history.first?.beatMiss, .beat)
    }

    @MainActor
    func testEarningsNotificationDelivery() {
        let today = Date()
        let todayItem = EarningsReportItem(
            symbol: "AAPL",
            nextDate: today,
            session: .amc,
            epsEstimate: 1.98
        )

        // NotificationManager shouldDeliver logic test
        let id = "earnings-\(todayItem.symbol)-\(todayItem.shortDateFormatted)"
        let canDeliver = NotificationManager.shouldDeliver(
            identifier: id,
            now: today,
            lastSent: nil,
            window: 120
        )
        XCTAssertTrue(canDeliver)

        let duplicateDeliver = NotificationManager.shouldDeliver(
            identifier: id,
            now: today.addingTimeInterval(30),
            lastSent: today,
            window: 120
        )
        XCTAssertFalse(duplicateDeliver)
    }

    func testYahooEarningsParsesQuarterlyRevenueAndProfit() throws {
        let json = """
        {
          "quoteSummary": {
            "result": [
              {
                "earnings": {
                  "financialsChart": {
                    "quarterly": [
                      { "date": "3Q2025", "revenue": { "raw": 51242000000 }, "earnings": { "raw": 2709000000 }, "profitMargin": { "raw": 0.0528 } },
                      { "date": "4Q2025", "revenue": { "raw": 59893000000 }, "earnings": { "raw": 19450000000 }, "profitMargin": { "raw": 0.3247 } }
                    ]
                  }
                },
                "earningsHistory": {
                  "history": [
                    { "quarter": { "raw": 1759190400 }, "epsActual": { "raw": 1.05 }, "epsEstimate": { "raw": 6.71 }, "period": "-4q" },
                    { "quarter": { "raw": 1767139200 }, "epsActual": { "raw": 8.88 }, "epsEstimate": { "raw": 8.22 }, "period": "-3q" }
                  ]
                }
              }
            ]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let item = try EarningsService.parseEarningsResponse(data: data, symbol: "META")
        XCTAssertEqual(item.history.count, 2)
        // With newest quarter first:
        XCTAssertEqual(item.history.first?.revenue, 59893000000)
        XCTAssertEqual(item.history.first?.epsActual, 8.88)
        XCTAssertEqual(item.history.last?.revenue, 51242000000)
        XCTAssertEqual(item.history.last?.epsActual, 1.05)
    }

    func testYahooEarningsParsesTrendsAndGuidance() throws {
        let json = """
        {
          "quoteSummary": {
            "result": [
              {
                "earningsTrend": {
                  "trend": [
                    {
                      "period": "0q",
                      "endDate": "2026-09-30",
                      "growth": { "raw": 0.125 },
                      "earningsEstimate": {
                        "avg": { "raw": 5.25 },
                        "growth": { "raw": 0.152 },
                        "numberOfAnalysts": { "raw": 34 }
                      },
                      "revenueEstimate": {
                        "avg": { "raw": 49100000000 },
                        "growth": { "raw": 0.184 },
                        "numberOfAnalysts": { "raw": 32 }
                      }
                    },
                    {
                      "period": "+1q",
                      "endDate": "2026-12-31",
                      "growth": { "raw": 0.14 },
                      "earningsEstimate": {
                        "avg": { "raw": 6.80 },
                        "growth": { "raw": 0.165 },
                        "numberOfAnalysts": { "raw": 31 }
                      },
                      "revenueEstimate": {
                        "avg": { "raw": 58300000000 },
                        "growth": { "raw": 0.191 },
                        "numberOfAnalysts": { "raw": 30 }
                      }
                    }
                  ]
                }
              }
            ]
          }
        }
        """
        let data = json.data(using: .utf8)!
        let item = try EarningsService.parseEarningsResponse(data: data, symbol: "META")
        XCTAssertEqual(item.trends.count, 2)

        let q0 = item.trends.first
        XCTAssertEqual(q0?.period, "0q")
        XCTAssertEqual(q0?.epsEstimate, 5.25)
        XCTAssertEqual(q0?.epsGrowth, 0.152)
        XCTAssertEqual(q0?.revenueEstimate, 49100000000)
        XCTAssertEqual(q0?.revenueGrowth, 0.184)
        XCTAssertEqual(q0?.numberOfAnalysts, 32)

        let q1 = item.trends.last
        XCTAssertEqual(q1?.period, "+1q")
        XCTAssertEqual(q1?.epsEstimate, 6.80)
        XCTAssertEqual(q1?.revenueEstimate, 58300000000)
        XCTAssertEqual(q0?.formattedEndDate(isVi: true), "30/09/2026")
    }

    func testVietnameseLocalizationFormatters() {
        XCTAssertEqual(EarningsSession.bmo.title(isVi: true), "Trước phiên")
        XCTAssertEqual(EarningsSession.amc.title(isVi: true), "Sau phiên")
        XCTAssertEqual(EarningsSession.bmo.title(isVi: false), "Before Open")
        XCTAssertEqual(EarningsSession.amc.title(isVi: false), "After Close")

        XCTAssertEqual(BeatMissStatus.beat.title(isVi: true), "Vượt")
        XCTAssertEqual(BeatMissStatus.miss.title(isVi: true), "Hụt")
        XCTAssertEqual(BeatMissStatus.inLine.title(isVi: true), "Đúng dự báo")

        let today = Date()
        let todayItem = EarningsReportItem(symbol: "V", nextDate: today, session: .bmo)
        XCTAssertEqual(todayItem.countdownText(isVi: true), "Hôm nay")
        XCTAssertEqual(todayItem.countdownText(isVi: false), "Today")

        if let inFiveDays = Calendar.current.date(byAdding: .day, value: 5, to: today) {
            let futureItem = EarningsReportItem(symbol: "MA", nextDate: inFiveDays, session: .amc)
            XCTAssertEqual(futureItem.countdownText(isVi: true), "Còn 5 ngày")
            XCTAssertEqual(futureItem.countdownText(isVi: false), "In 5d")
        }
    }
}


