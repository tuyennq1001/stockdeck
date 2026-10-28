import XCTest
@testable import StockDeck

final class LightweightChartMathTests: XCTestCase {
    func testSMAUsesTrailingWindowAndLeavesWarmupEmpty() {
        let values = LightweightChartMath.sma([1, 2, 3, 4], 3)
        XCTAssertNil(values[0]); XCTAssertNil(values[1])
        XCTAssertEqual(values[2]!, 2, accuracy: 0.0001)
        XCTAssertEqual(values[3]!, 3, accuracy: 0.0001)
    }

    func testEMAStartsAtSimpleAverageOfFirstPeriod() {
        let values = LightweightChartMath.ema([1, 2, 3, 4], 3)
        XCTAssertNil(values[0]); XCTAssertNil(values[1])
        XCTAssertEqual(values[2]!, 2, accuracy: 0.0001)
        XCTAssertEqual(values[3]!, 3, accuracy: 0.0001)
    }

    func testInvalidPeriodsReturnOnlyMissingValues() {
        XCTAssertTrue(LightweightChartMath.sma([1, 2], 0).allSatisfy { $0 == nil })
        XCTAssertTrue(LightweightChartMath.ema([1, 2], 3).allSatisfy { $0 == nil })
    }

    func testRSIFlatSeriesIsNeutralAndWarmsUpAfterPeriod() {
        let values = LightweightChartMath.rsi([10, 10, 10, 10], 2)
        XCTAssertNil(values[0]); XCTAssertNil(values[1])
        XCTAssertEqual(values[2]!, 50, accuracy: 0.0001)
        XCTAssertEqual(values[3]!, 50, accuracy: 0.0001)
    }

    func testBollingerBandsUsePopulationDeviation() {
        let bands = LightweightChartMath.bollinger([1, 2, 3], 3, 2)
        XCTAssertNil(bands.middle[1])
        XCTAssertEqual(bands.middle[2]!, 2, accuracy: 0.0001)
        XCTAssertEqual(bands.upper[2]!, 2 + 2 * sqrt(2.0 / 3.0), accuracy: 0.0001)
        XCTAssertEqual(bands.lower[2]!, 2 - 2 * sqrt(2.0 / 3.0), accuracy: 0.0001)
    }

    func testStochasticUsesHighLowRangeAndAppliesKAndDMovingAverageWarmup() {
        let values = LightweightChartMath.stochastic(
            highs: [10, 11, 12, 13, 14], lows: [0, 1, 2, 3, 4], closes: [5, 8, 10, 11, 12],
            kPeriod: 3, kSmoothing: 1, dPeriod: 2)
        XCTAssertNil(values.k[1])
        XCTAssertEqual(values.k[2]!, 83.333333, accuracy: 0.0001)
        XCTAssertNil(values.d[2])
        XCTAssertEqual(values.d[3]!, 83.333333, accuracy: 0.0001)
        XCTAssertEqual(values.k.count, 5)
    }

    func testStochasticFlatRangeIsNeutralAndInsufficientHistoryIsEmpty() {
        let flat = LightweightChartMath.stochastic(highs: [10, 10, 10], lows: [10, 10, 10],
            closes: [10, 10, 10], kPeriod: 2, kSmoothing: 1, dPeriod: 1)
        XCTAssertEqual(flat.k[1]!, 50, accuracy: 0.0001)
        XCTAssertEqual(flat.d[2]!, 50, accuracy: 0.0001)
        let short = LightweightChartMath.stochastic(highs: [10], lows: [9], closes: [9.5],
            kPeriod: 2, kSmoothing: 1, dPeriod: 1)
        XCTAssertTrue(short.k.allSatisfy { $0 == nil })
        XCTAssertTrue(short.d.allSatisfy { $0 == nil })
    }

    func testParabolicSARStartsWithWarmupAndReversesTrend() {
        let values = LightweightChartMath.parabolicSAR(highs: [10, 11, 12, 11, 9],
            lows: [8, 9, 10, 7, 6], closes: [9, 10, 11, 8, 7])
        XCTAssertNil(values[0])
        XCTAssertEqual(values[1]!, 8, accuracy: 0.0001)
        XCTAssertEqual(values[2]!, 8, accuracy: 0.0001)
        XCTAssertEqual(values[3]!, 12, accuracy: 0.0001)
        XCTAssertEqual(values[4]!, 12, accuracy: 0.0001)
    }

    func testIndicatorPayloadOnlyAddsNewOHLCStudiesInSuperchart() {
        let base = Date(timeIntervalSince1970: 1_735_689_600)
        let points: [PricePoint] = (0..<5).map { index -> PricePoint in
            let offset = Double(index) * 86_400
            let close = Double(index + 10)
            return PricePoint(date: base.addingTimeInterval(offset), close: close,
                open: close - 1, high: close + 1, low: close - 2)
        }
        let detail = LightweightChartMath.payload(points: points, interval: .day, symbol: "AAPL",
            currency: "USD", periods: [:], showsRangeControls: false)
        let superchart = LightweightChartMath.payload(points: points, interval: .day, symbol: "AAPL",
            currency: "USD", periods: [:], showsRangeControls: true)
        XCTAssertTrue(detail.stochasticK.isEmpty)
        XCTAssertTrue(detail.parabolicSAR.isEmpty)
        XCTAssertEqual(superchart.stochasticK.count, 0) // Default 14-period stochastic needs more history.
        XCTAssertEqual(superchart.parabolicSAR.count, 4)
    }

    func testMovingAverageSlotsUseConfiguredTypeAndOHLCSource() {
        let base = Date(timeIntervalSince1970: 1_735_689_600)
        let points: [PricePoint] = (0..<3).map { index in
            let close = Double(index + 10)
            return PricePoint(date: base.addingTimeInterval(Double(index) * 86_400), close: close,
                open: close - 2, high: close + 3, low: close - 4)
        }
        let payload = LightweightChartMath.payload(points: points, interval: .day, symbol: "AAPL",
            currency: "USD", periods: ["MA 1|SMA|high": 2, "MA 2|EMA|open": 2], showsRangeControls: true)

        XCTAssertEqual(payload.lines["MA 1|SMA|high"]?.map(\.value), [13.5, 14.5])
        XCTAssertEqual(payload.lines["MA 2|EMA|open"]?.map(\.value), [8.5, 9.5])
    }

    func testMovingAverageNonCloseSourceNeedsRealOHLC() {
        let base = Date(timeIntervalSince1970: 1_735_689_600)
        let points = [PricePoint(date: base, close: 10), PricePoint(date: base.addingTimeInterval(86_400), close: 11)]
        let payload = LightweightChartMath.payload(points: points, interval: .day, symbol: "AAPL",
            currency: "USD", periods: ["MA 1|SMA|high": 2], showsRangeControls: true)

        XCTAssertTrue(payload.lines["MA 1|SMA|high"]?.isEmpty == true)
    }

    func testWeeklyAggregationPreservesOHLCAndVolume() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let monday = calendar.date(from: DateComponents(year: 2025, month: 1, day: 6))!
        let tuesday = calendar.date(byAdding: .day, value: 1, to: monday)!
        let input = [PricePoint(date: monday, close: 11, open: 10, high: 12, low: 9, volume: 100),
                     PricePoint(date: tuesday, close: 12, open: 11, high: 14, low: 10, volume: 150)]
        let result = LightweightChartMath.aggregate(input, interval: .week, symbol: "AAPL", calendar: calendar)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].open, 10)
        XCTAssertEqual(result[0].close, 12)
        XCTAssertEqual(result[0].high, 14)
        XCTAssertEqual(result[0].low, 9)
        XCTAssertEqual(result[0].volume, 250)
    }

    func testWeeklyCloseOnlyDataDoesNotInventOHLCOrVolume() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let monday = calendar.date(from: DateComponents(year: 2025, month: 1, day: 6))!
        let tuesday = calendar.date(byAdding: .day, value: 1, to: monday)!
        let input = [PricePoint(date: monday, close: 11), PricePoint(date: tuesday, close: 12)]
        let result = LightweightChartMath.aggregate(input, interval: .week, symbol: "FUND", calendar: calendar)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].open); XCTAssertNil(result[0].high); XCTAssertNil(result[0].low)
        XCTAssertNil(result[0].volume)
    }

    func testDuplicateTradingDayDoesNotDoubleCountVolumeAndPrefersOHLC() {
        let date = Date(timeIntervalSince1970: 1_736_172_000)
        let input = [PricePoint(date: date, close: 11, volume: 100),
                     PricePoint(date: date, close: 12, open: 10, high: 13, low: 9, volume: 150)]
        let result = LightweightChartMath.aggregate(input, interval: .day, symbol: "AAPL")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].close, 12)
        XCTAssertEqual(result[0].open, 10)
        XCTAssertEqual(result[0].volume, 150)
    }

    func testBarDateUsesMarketTradingDay() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let timestamp = utc.date(from: DateComponents(year: 2025, month: 1, day: 6, hour: 15, minute: 30))!
        let payload = LightweightChartMath.payload(points: [PricePoint(date: timestamp, close: 100)],
            interval: .day, symbol: "7203.T", currency: "JPY", periods: [:])
        XCTAssertEqual(payload.bars.first?.time, "2025-01-07")
        XCTAssertFalse(payload.hasOHLC)
    }

    func testPartialDailyOHLCKeepsRealCandlesAndDoesNotFillMissingFields() {
        let start = Date(timeIntervalSince1970: 1_736_000_000)
        let points = [
            PricePoint(date: start, close: 102, open: 100, high: 105, low: 99, volume: 1_000),
            PricePoint(date: start.addingTimeInterval(86_400), close: 104, volume: 1_200)
        ]

        let payload = LightweightChartMath.payload(points: points, interval: .day,
            symbol: "TEST", currency: "USD", periods: [:], showsRangeControls: true)

        XCTAssertTrue(payload.hasOHLC, "A daily series with real OHLC bars should allow candle display")
        XCTAssertEqual(payload.bars.count, 2)
        XCTAssertEqual(payload.bars[0].open, 100)
        XCTAssertNil(payload.bars[1].open)
        XCTAssertNil(payload.bars[1].high)
        XCTAssertNil(payload.bars[1].low)
        XCTAssertEqual(payload.bars[1].close, 104)
    }

    func testAutomaticIntervalUsesDailyWeeklyAndMonthlyBarsByRangeLength() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        func start(_ years: Double) -> Date { end.addingTimeInterval(-years * 365.2425 * 24 * 60 * 60) }
        let points = [PricePoint(date: start(10), close: 10), PricePoint(date: end, close: 20)]
        XCTAssertEqual(LightweightChartInterval.automatic(visibleFrom: start(0.5), points: points), .day)
        XCTAssertEqual(LightweightChartInterval.automatic(visibleFrom: start(3), points: points), .week)
        XCTAssertEqual(LightweightChartInterval.automatic(visibleFrom: start(7), points: points), .month)
        XCTAssertEqual(LightweightChartInterval.automatic(visibleFrom: nil, points: points), .month)
    }

    func testRangePresetsChooseRequestedTimeframeWithoutClobberingManualChoice() {
        XCTAssertEqual(LightweightChartRangePreset(rawValue: "5Y")?.automaticInterval, .week)
        XCTAssertEqual(LightweightChartRangePreset(rawValue: "10Y")?.automaticInterval, .month)
        XCTAssertEqual(LightweightChartRangePreset(rawValue: "1Y")?.automaticInterval, .day)
        XCTAssertEqual(LightweightChartRangePreset(rawValue: "2Y")?.automaticInterval, .week)
        XCTAssertEqual(LightweightChartRangePreset.range(for: .day), .oneYear)
        XCTAssertEqual(LightweightChartRangePreset.range(for: .week), .twoYears)
        XCTAssertEqual(LightweightChartRangePreset.range(for: .month), .sevenYears)
        XCTAssertEqual(LightweightChartRangePreset.range(for: .year), .sevenYears)
        XCTAssertNil(LightweightChartRangePreset.all.automaticInterval)
    }

    func testChartPayloadCarriesToolbarSelectionAndAvailableRanges() {
        let payload = LightweightChartMath.payload(points: [], interval: .week, symbol: "AAPL",
            currency: "USD", periods: [:], selectedRange: "5Y", showsRangeControls: true,
            availableRanges: ["1M", "3M", "5Y", "All"])
        XCTAssertEqual(payload.selectedRange, "5Y")
        XCTAssertEqual(payload.interval, "1W")
        XCTAssertTrue(payload.showsRangeControls)
        XCTAssertEqual(payload.availableRanges, ["1M", "3M", "5Y", "All"])
    }

    func testIndicatorSettingsClampInvalidValuesAndKeepRSILevelsOrdered() {
        let settings = LightweightIndicatorSettings(rsiPeriod: 0, rsiOversold: 99, rsiOverbought: -2,
            macdFast: 50, macdSlow: 1, macdSignal: 0, bollingerPeriod: 1, bollingerDeviations: 99,
            rsiColor: "red", rsiLineWidth: 99, macdColor: "#fff", signalColor: "#da9147",
            macdLineWidth: 0, macdLineEnabled: true, signalLineEnabled: false, histogramEnabled: true,
            bollingerColor: "#8a78bd", bollingerLineWidth: 9).validated()
        XCTAssertEqual(settings.rsiPeriod, 2)
        XCTAssertLessThan(settings.rsiOversold, settings.rsiOverbought)
        XCTAssertEqual(settings.macdFast, 50)
        XCTAssertEqual(settings.macdSlow, 51)
        XCTAssertEqual(settings.macdSignal, 2)
        XCTAssertEqual(settings.bollingerDeviations, 10)
        XCTAssertEqual(settings.rsiColor, "#9467bd")
        XCTAssertEqual(settings.macdLineWidth, 1)
    }

    func testIndicatorSettingsApplyNewStudyDefaultsAndValidateBounds() {
        let defaults = LightweightIndicatorSettings().validated()
        XCTAssertTrue(defaults.rsiThresholdsVisible)
        XCTAssertTrue(defaults.rsiUpperVisible)
        XCTAssertTrue(defaults.rsiMiddleVisible)
        XCTAssertTrue(defaults.rsiLowerVisible)
        XCTAssertEqual(defaults.rsiMiddle, 50)
        XCTAssertEqual(defaults.rsiThresholdWidth, 1)
        XCTAssertTrue(defaults.rsiBackgroundFillVisible)
        XCTAssertEqual(defaults.rsiBackgroundColor, "#9467bd")
        XCTAssertEqual(defaults.rsiBackgroundOpacity, 12)
        XCTAssertTrue(defaults.rsiAxisLabelsVisible)
        XCTAssertTrue(defaults.rsiValuesVisible)
        XCTAssertEqual(defaults.rsiOversoldColor, "#16816d")
        XCTAssertEqual(defaults.rsiOverboughtColor, "#d95f59")
        XCTAssertEqual(defaults.stochasticKPeriod, 14)
        XCTAssertEqual(defaults.stochasticKSmoothing, 3)
        XCTAssertEqual(defaults.stochasticDPeriod, 3)
        XCTAssertEqual(defaults.stochasticOversold, 20)
        XCTAssertEqual(defaults.stochasticOverbought, 80)
        XCTAssertEqual(defaults.sarStep, 0.02, accuracy: 0.0001)
        XCTAssertEqual(defaults.sarIncrement, 0.02, accuracy: 0.0001)
        XCTAssertEqual(defaults.sarMaximum, 0.2, accuracy: 0.0001)
        let invalid = LightweightIndicatorSettings(rsiBackgroundColor: "bad", rsiBackgroundOpacity: 120,
            stochasticKPeriod: 0, stochasticKSmoothing: 0,
            stochasticDPeriod: 0, stochasticOversold: 80, stochasticOverbought: 20,
            stochasticKColor: "bad", stochasticDColor: "#da9147", stochasticLineWidth: 8,
            sarStep: 0.4, sarIncrement: 0, sarMaximum: 0.1, sarColor: "bad", sarDotSize: 0).validated()
        XCTAssertEqual(invalid.stochasticKPeriod, 2)
        XCTAssertEqual(invalid.stochasticKSmoothing, 1)
        XCTAssertEqual(invalid.stochasticDPeriod, 1)
        XCTAssertEqual(invalid.stochasticOversold, 20)
        XCTAssertEqual(invalid.stochasticOverbought, 80)
        XCTAssertEqual(invalid.rsiBackgroundColor, "#9467bd")
        XCTAssertEqual(invalid.rsiBackgroundOpacity, 100)
        XCTAssertEqual(invalid.stochasticLineWidth, 4)
        XCTAssertEqual(invalid.sarStep, 0.2, accuracy: 0.0001)
        XCTAssertEqual(invalid.sarMaximum, 0.2, accuracy: 0.0001)
        XCTAssertEqual(invalid.sarDotSize, 1)
        XCTAssertEqual(invalid.sarColor, "#16816d")
    }

    func testRSIMiddleLevelRemainsBetweenOversoldAndOverbought() {
        let settings = LightweightIndicatorSettings(rsiOversold: 44, rsiOverbought: 55, rsiMiddle: 20).validated()
        XCTAssertGreaterThan(settings.rsiMiddle, settings.rsiOversold)
        XCTAssertLessThan(settings.rsiMiddle, settings.rsiOverbought)
    }

    func testIndicatorSettingsDecodeLegacyDataWithNewDefaults() throws {
        let data = Data(#"{"rsiPeriod":21,"rsiOversold":25,"rsiOverbought":75}"#.utf8)
        let decoded = try JSONDecoder().decode(LightweightIndicatorSettings.self, from: data)
        XCTAssertEqual(decoded.rsiPeriod, 21)
        XCTAssertTrue(decoded.rsiThresholdsVisible)
        XCTAssertTrue(decoded.rsiUpperVisible)
        XCTAssertTrue(decoded.rsiMiddleVisible)
        XCTAssertTrue(decoded.rsiLowerVisible)
        XCTAssertEqual(decoded.rsiMiddle, 50)
        XCTAssertEqual(decoded.rsiOversoldColor, "#16816d")
        XCTAssertEqual(decoded.rsiOverboughtColor, "#d95f59")
        XCTAssertEqual(decoded.stochasticKPeriod, 14)
        XCTAssertEqual(decoded.sarStep, 0.02, accuracy: 0.0001)
    }

    func testIndicatorComponentStylesRoundTripAndClampVisualSettings() throws {
        var settings = LightweightIndicatorSettings()
        settings.componentStyles["rsi"] = .init(visible: false, color: "#123456", opacity: 140,
            thickness: 8, lineStyle: "dotted", plotType: "step")
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(LightweightIndicatorSettings.self, from: data).validated()
        let rsi = try XCTUnwrap(decoded.componentStyles["rsi"])
        XCTAssertFalse(rsi.visible)
        XCTAssertEqual(rsi.color, "#123456")
        XCTAssertEqual(rsi.opacity, 100)
        XCTAssertEqual(rsi.thickness, 4)
        XCTAssertEqual(rsi.lineStyle, "dotted")
        XCTAssertEqual(rsi.plotType, "step")
    }

    func testLegacyIndicatorStyleMigratesIntoIndependentComponents() throws {
        let data = Data(##"{"rsiColor":"#112233","rsiLineWidth":3,"rsiBackgroundColor":"#223344","rsiBackgroundOpacity":28,"bollingerColor":"#334455","bollingerLineWidth":2}"##.utf8)
        let decoded = try JSONDecoder().decode(LightweightIndicatorSettings.self, from: data)
        XCTAssertEqual(decoded.componentStyles["rsi"]?.color, "#112233")
        XCTAssertEqual(decoded.componentStyles["rsi"]?.thickness, 3)
        XCTAssertEqual(decoded.componentStyles["rsiFill"]?.color, "#223344")
        XCTAssertEqual(decoded.componentStyles["rsiFill"]?.opacity, 28)
        XCTAssertEqual(decoded.componentStyles["bbUpper"]?.color, "#334455")
        XCTAssertEqual(decoded.componentStyles["bbLower"]?.thickness, 2)
    }

    func testPriceRangeStorePersistsPerSymbolAndRoundTrips() {
        let suite = "LightweightPriceRangeStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let range = LightweightPriceRange(id: "range-1", startTime: "2025-01-06", endTime: "2025-01-10",
            startPrice: 100, endPrice: 112.5)
        LightweightPriceRangeStore.save([range], symbol: "aapl", defaults: defaults)
        XCTAssertEqual(LightweightPriceRangeStore.load(symbol: "AAPL", defaults: defaults), [range])
        XCTAssertTrue(LightweightPriceRangeStore.load(symbol: "MSFT", defaults: defaults).isEmpty)
        LightweightPriceRangeStore.save([], symbol: "AAPL", defaults: defaults)
        XCTAssertTrue(LightweightPriceRangeStore.load(symbol: "AAPL", defaults: defaults).isEmpty)
    }

    func testFileDrawingStoreMigratesLegacyDataBeforeRemovingIt() async throws {
        let suite = "LightweightDrawingMigration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let range = LightweightPriceRange(id: "legacy", startTime: "2025-01-06", endTime: "2025-01-10",
            startPrice: 100, endPrice: 112.5)
        defaults.set(try JSONEncoder().encode([range]), forKey: "stockdeck.lightweightChart.priceRanges.v1.AAPL")

        let store = LightweightChartDrawingStore(directory: directory, defaults: defaults)
        let migrated = await store.load(symbol: "AAPL")
        XCTAssertEqual(migrated, [range])
        XCTAssertNil(defaults.data(forKey: "stockdeck.lightweightChart.priceRanges.v1.AAPL"))
        let reopened = await store.load(symbol: "AAPL")
        XCTAssertEqual(reopened, [range])
        let otherSymbol = await store.load(symbol: "MSFT")
        XCTAssertTrue(otherSymbol.isEmpty)
    }

    func testPriceRangeDecodesLegacyRecordsWithoutKind() throws {
        let data = Data(#"{"id":"old","startTime":"2025-01-06","endTime":"2025-01-10","startPrice":10,"endPrice":12}"#.utf8)
        let decoded = try JSONDecoder().decode(LightweightPriceRange.self, from: data)
        XCTAssertEqual(decoded.kind, "range")
        XCTAssertEqual(decoded.color, "#1a9b82")
        XCTAssertEqual(decoded.lineWidth, 1)
        XCTAssertFalse(decoded.isLocked)
    }
}
