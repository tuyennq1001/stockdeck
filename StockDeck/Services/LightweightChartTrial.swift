import AppKit
import SwiftUI
import WebKit

enum LightweightChartInterval: String, CaseIterable, Identifiable {
    case fiveMinutes = "5m", thirtyMinutes = "30m", hour = "1h", fourHours = "4h", sixHours = "6h"
    case day = "1D", week = "1W", month = "1M", quarter = "3M", halfYear = "6M", year = "1Y"
    var seconds: Int? {
        switch self {
        case .fiveMinutes: 300
        case .thirtyMinutes: 1800
        case .hour: 3600
        case .fourHours: 14400
        case .sixHours: 21600
        default: nil
        }
    }
    var isIntraday: Bool { seconds != nil }
    var label: String {
        switch self {
        case .day: "D"
        case .week: "W"
        case .month: "M"
        case .year: "Y"
        default: rawValue
        }
    }
    var id: String { rawValue }

    static func automatic(visibleFrom: Date?, points: [PricePoint]) -> Self {
        guard let firstDate = visibleFrom ?? points.first?.date, let lastDate = points.last?.date else { return .day }
        let years = max(0, lastDate.timeIntervalSince(firstDate)) / (365.2425 * 24 * 60 * 60)
        if years <= 1 { return .day }
        if years <= 5 { return .week }
        return .month
    }
}

enum LightweightChartRangePreset: String, CaseIterable {
    case oneDay = "1D", fiveDays = "5D"
    case oneMonth = "1M", threeMonths = "3M", sixMonths = "6M", ytd = "YTD", oneYear = "1Y"
    case threeYears = "3Y", fiveYears = "5Y", sevenYears = "7Y", tenYears = "10Y", all = "All"

    var automaticInterval: LightweightChartInterval? {
        switch self {
        case .oneDay: .fiveMinutes
        case .fiveDays: .thirtyMinutes
        case .oneMonth, .threeMonths, .sixMonths, .ytd, .oneYear: .day
        case .threeYears, .fiveYears: .week
        case .sevenYears, .tenYears: .month
        case .all: nil
        }
    }

    static func range(for interval: LightweightChartInterval) -> Self {
        switch interval {
        case .fiveMinutes: .oneDay
        case .thirtyMinutes: .fiveDays
        case .hour, .fourHours, .sixHours: .oneMonth
        case .day: .threeMonths
        case .week: .oneYear
        case .month, .quarter, .halfYear, .year: .fiveYears
        }
    }
}

struct LightweightBar: Codable {
    let time: String
    let open, high, low: Double?
    let close: Double
    let volume: Double?
}

struct LightweightChartPayload: Encodable {
    let symbol: String
    let currency: String
    let timeZone: String
    let interval: String
    let bars: [LightweightBar]
    let visibleFrom: String?
    let visibleTo: String?
    let markers: [LightweightChartMarker]
    let targetPrice: Double?
    let showInsiderMarkers: Bool
    let drawings: [LightweightPriceRange]
    let hasOHLC: Bool
    let lines: [String: [LightweightIndicatorPoint]]
    let rsi: [LightweightIndicatorPoint]
    let macd: [LightweightIndicatorPoint]
    let signal: [LightweightIndicatorPoint]
    let histogram: [LightweightIndicatorPoint]
    let stochasticK: [LightweightIndicatorPoint]
    let stochasticD: [LightweightIndicatorPoint]
    let parabolicSAR: [LightweightIndicatorPoint]
    let upperBand: [LightweightIndicatorPoint]
    let middleBand: [LightweightIndicatorPoint]
    let lowerBand: [LightweightIndicatorPoint]
    let indicatorSettings: LightweightIndicatorSettings
    let selectedRange: String
    let showsRangeControls: Bool
    let availableRanges: [String]
}

struct LightweightIndicatorSettings: Codable, Equatable {
    struct ComponentStyle: Codable, Equatable {
        var visible = true
        var color = "#9467bd"
        var opacity = 100
        var thickness = 2
        var lineStyle = "solid"
        var plotType = "line"

        private enum CodingKeys: String, CodingKey { case visible, color, opacity, thickness, lineStyle, plotType }

        init(visible: Bool = true, color: String = "#9467bd", opacity: Int = 100,
             thickness: Int = 2, lineStyle: String = "solid", plotType: String = "line") {
            self.visible = visible
            self.color = color
            self.opacity = opacity
            self.thickness = thickness
            self.lineStyle = lineStyle
            self.plotType = plotType
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            visible = try values.decodeIfPresent(Bool.self, forKey: .visible) ?? true
            color = try values.decodeIfPresent(String.self, forKey: .color) ?? "#9467bd"
            opacity = try values.decodeIfPresent(Int.self, forKey: .opacity) ?? 100
            thickness = try values.decodeIfPresent(Int.self, forKey: .thickness) ?? 2
            lineStyle = try values.decodeIfPresent(String.self, forKey: .lineStyle) ?? "solid"
            plotType = try values.decodeIfPresent(String.self, forKey: .plotType) ?? "line"
        }

        func validated() -> Self {
            var value = self
            value.opacity = min(max(value.opacity, 0), 100)
            value.thickness = min(max(value.thickness, 1), 4)
            if value.color.count != 7 || value.color.first != "#" || !value.color.dropFirst().allSatisfy(\.isHexDigit) {
                value.color = "#9467bd"
            }
            if !["solid", "dashed", "dotted"].contains(value.lineStyle) { value.lineStyle = "solid" }
            if !["line", "step", "area", "histogram", "circles"].contains(value.plotType) { value.plotType = "line" }
            return value
        }
    }

    static let defaultComponentStyles: [String: ComponentStyle] = [
        "rsi": .init(color: "#9467bd", thickness: 2),
        "rsiUpper": .init(color: "#d95f59", thickness: 1, lineStyle: "dashed"),
        "rsiMiddle": .init(color: "#858b98", thickness: 1, lineStyle: "dashed"),
        "rsiLower": .init(color: "#16816d", thickness: 1, lineStyle: "dashed"),
        "rsiFill": .init(color: "#9467bd", opacity: 12, thickness: 1),
        "macd": .init(color: "#4183c4", thickness: 2),
        "signal": .init(color: "#da9147", thickness: 1),
        "macdHistogram": .init(color: "#1a9b82", plotType: "histogram"),
        "bbUpper": .init(color: "#8a78bd", thickness: 1),
        "bbMiddle": .init(color: "#8a78bd", thickness: 1, lineStyle: "dashed"),
        "bbLower": .init(color: "#8a78bd", thickness: 1),
        "bbFill": .init(color: "#8a78bd", opacity: 10),
        "stochasticK": .init(color: "#9467bd", thickness: 2),
        "stochasticD": .init(color: "#da9147", thickness: 2),
        "sar": .init(color: "#16816d", thickness: 2, plotType: "circles")
    ]

    var componentStyles = LightweightIndicatorSettings.defaultComponentStyles
    var rsiPeriod = 14
    var rsiOversold = 30.0
    var rsiOverbought = 70.0
    var rsiThresholdsVisible = true
    var rsiUpperVisible = true
    var rsiMiddleVisible = true
    var rsiLowerVisible = true
    var rsiMiddle = 50.0
    var rsiOversoldColor = "#16816d"
    var rsiOverboughtColor = "#d95f59"
    var rsiMiddleColor = "#858b98"
    var rsiThresholdWidth = 1
    var rsiBackgroundFillVisible = true
    var rsiBackgroundColor = "#9467bd"
    var rsiBackgroundOpacity = 12
    var rsiAxisLabelsVisible = true
    var rsiValuesVisible = true
    var macdFast = 12
    var macdSlow = 26
    var macdSignal = 9
    var bollingerPeriod = 20
    var bollingerDeviations = 2.0
    var rsiColor = "#9467bd"
    var rsiLineWidth = 2
    var macdColor = "#4183c4"
    var signalColor = "#da9147"
    var macdLineWidth = 2
    var macdLineEnabled = true
    var signalLineEnabled = true
    var histogramEnabled = true
    var bollingerColor = "#8a78bd"
    var bollingerLineWidth = 1
    var stochasticKPeriod = 14
    var stochasticKSmoothing = 3
    var stochasticDPeriod = 3
    var stochasticOversold = 20.0
    var stochasticOverbought = 80.0
    var stochasticKColor = "#9467bd"
    var stochasticDColor = "#da9147"
    var stochasticLineWidth = 2
    var sarStep = 0.02
    var sarIncrement = 0.02
    var sarMaximum = 0.2
    var sarColor = "#16816d"
    var sarDotSize = 2

    func validated() -> Self {
        var value = self
        value.rsiPeriod = min(max(value.rsiPeriod, 2), 500)
        value.rsiOversold = min(max(value.rsiOversold, 0), 49)
        value.rsiOverbought = min(max(value.rsiOverbought, 51), 100)
        value.rsiMiddle = min(max(value.rsiMiddle, value.rsiOversold + 0.5), value.rsiOverbought - 0.5)
        value.macdFast = min(max(value.macdFast, 2), 500)
        value.macdSlow = min(max(value.macdSlow, value.macdFast + 1), 1_000)
        value.macdSignal = min(max(value.macdSignal, 2), 500)
        value.bollingerPeriod = min(max(value.bollingerPeriod, 2), 500)
        value.bollingerDeviations = min(max(value.bollingerDeviations, 0.1), 10)
        value.stochasticKPeriod = min(max(value.stochasticKPeriod, 2), 500)
        value.stochasticKSmoothing = min(max(value.stochasticKSmoothing, 1), 100)
        value.stochasticDPeriod = min(max(value.stochasticDPeriod, 1), 100)
        if value.stochasticOversold >= value.stochasticOverbought {
            value.stochasticOversold = 20
            value.stochasticOverbought = 80
        } else {
            value.stochasticOversold = min(max(value.stochasticOversold, 0), 49)
            value.stochasticOverbought = min(max(value.stochasticOverbought, 51), 100)
        }
        value.sarStep = min(max(value.sarStep, 0.001), 0.2)
        value.sarIncrement = min(max(value.sarIncrement, 0.001), 0.2)
        value.sarMaximum = min(max(value.sarMaximum, value.sarStep), 0.99)
        value.rsiLineWidth = min(max(value.rsiLineWidth, 1), 4)
        value.rsiThresholdWidth = min(max(value.rsiThresholdWidth, 1), 3)
        value.rsiBackgroundOpacity = min(max(value.rsiBackgroundOpacity, 0), 100)
        value.macdLineWidth = min(max(value.macdLineWidth, 1), 4)
        value.bollingerLineWidth = min(max(value.bollingerLineWidth, 1), 4)
        value.stochasticLineWidth = min(max(value.stochasticLineWidth, 1), 4)
        value.sarDotSize = min(max(value.sarDotSize, 1), 5)
        value.componentStyles = value.componentStyles.mapValues { $0.validated() }
        if !Self.validColor(value.rsiColor) { value.rsiColor = "#9467bd" }
        if !Self.validColor(value.rsiOversoldColor) { value.rsiOversoldColor = "#16816d" }
        if !Self.validColor(value.rsiOverboughtColor) { value.rsiOverboughtColor = "#d95f59" }
        if !Self.validColor(value.rsiMiddleColor) { value.rsiMiddleColor = "#858b98" }
        if !Self.validColor(value.rsiBackgroundColor) { value.rsiBackgroundColor = "#9467bd" }
        if !Self.validColor(value.macdColor) { value.macdColor = "#4183c4" }
        if !Self.validColor(value.signalColor) { value.signalColor = "#da9147" }
        if !Self.validColor(value.bollingerColor) { value.bollingerColor = "#8a78bd" }
        if !Self.validColor(value.stochasticKColor) { value.stochasticKColor = "#9467bd" }
        if !Self.validColor(value.stochasticDColor) { value.stochasticDColor = "#da9147" }
        if !Self.validColor(value.sarColor) { value.sarColor = "#16816d" }
        return value
    }

    private static func validColor(_ value: String) -> Bool {
        value.count == 7 && value.first == "#" && value.dropFirst().allSatisfy(\.isHexDigit)
    }
}

extension LightweightIndicatorSettings {
    private enum CodingKeys: String, CodingKey {
        case rsiPeriod, rsiOversold, rsiOverbought, rsiThresholdsVisible, rsiUpperVisible, rsiMiddleVisible
        case rsiLowerVisible, rsiMiddle, rsiOversoldColor, rsiOverboughtColor, rsiMiddleColor, rsiThresholdWidth
        case rsiBackgroundFillVisible, rsiBackgroundColor, rsiBackgroundOpacity
        case rsiAxisLabelsVisible, rsiValuesVisible
        case macdFast, macdSlow, macdSignal
        case bollingerPeriod, bollingerDeviations, rsiColor, rsiLineWidth, macdColor, signalColor
        case macdLineWidth, macdLineEnabled, signalLineEnabled, histogramEnabled, bollingerColor, bollingerLineWidth
        case stochasticKPeriod, stochasticKSmoothing, stochasticDPeriod, stochasticOversold, stochasticOverbought
        case stochasticKColor, stochasticDColor, stochasticLineWidth, sarStep, sarIncrement, sarMaximum, sarColor, sarDotSize
        case componentStyles
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let savedStyles = try values.decodeIfPresent([String: ComponentStyle].self, forKey: .componentStyles)
        self.init(
            rsiPeriod: try values.decodeIfPresent(Int.self, forKey: .rsiPeriod) ?? 14,
            rsiOversold: try values.decodeIfPresent(Double.self, forKey: .rsiOversold) ?? 30,
            rsiOverbought: try values.decodeIfPresent(Double.self, forKey: .rsiOverbought) ?? 70,
            rsiThresholdsVisible: try values.decodeIfPresent(Bool.self, forKey: .rsiThresholdsVisible) ?? true,
            rsiUpperVisible: try values.decodeIfPresent(Bool.self, forKey: .rsiUpperVisible)
                ?? values.decodeIfPresent(Bool.self, forKey: .rsiThresholdsVisible) ?? true,
            rsiMiddleVisible: try values.decodeIfPresent(Bool.self, forKey: .rsiMiddleVisible)
                ?? values.decodeIfPresent(Bool.self, forKey: .rsiThresholdsVisible) ?? true,
            rsiLowerVisible: try values.decodeIfPresent(Bool.self, forKey: .rsiLowerVisible)
                ?? values.decodeIfPresent(Bool.self, forKey: .rsiThresholdsVisible) ?? true,
            rsiMiddle: try values.decodeIfPresent(Double.self, forKey: .rsiMiddle) ?? 50,
            rsiOversoldColor: try values.decodeIfPresent(String.self, forKey: .rsiOversoldColor) ?? "#16816d",
            rsiOverboughtColor: try values.decodeIfPresent(String.self, forKey: .rsiOverboughtColor) ?? "#d95f59",
            rsiMiddleColor: try values.decodeIfPresent(String.self, forKey: .rsiMiddleColor) ?? "#858b98",
            rsiThresholdWidth: try values.decodeIfPresent(Int.self, forKey: .rsiThresholdWidth) ?? 1,
            rsiBackgroundFillVisible: try values.decodeIfPresent(Bool.self, forKey: .rsiBackgroundFillVisible) ?? true,
            rsiBackgroundColor: try values.decodeIfPresent(String.self, forKey: .rsiBackgroundColor) ?? "#9467bd",
            rsiBackgroundOpacity: try values.decodeIfPresent(Int.self, forKey: .rsiBackgroundOpacity) ?? 12,
            rsiAxisLabelsVisible: try values.decodeIfPresent(Bool.self, forKey: .rsiAxisLabelsVisible) ?? true,
            rsiValuesVisible: try values.decodeIfPresent(Bool.self, forKey: .rsiValuesVisible) ?? true,
            macdFast: try values.decodeIfPresent(Int.self, forKey: .macdFast) ?? 12,
            macdSlow: try values.decodeIfPresent(Int.self, forKey: .macdSlow) ?? 26,
            macdSignal: try values.decodeIfPresent(Int.self, forKey: .macdSignal) ?? 9,
            bollingerPeriod: try values.decodeIfPresent(Int.self, forKey: .bollingerPeriod) ?? 20,
            bollingerDeviations: try values.decodeIfPresent(Double.self, forKey: .bollingerDeviations) ?? 2,
            rsiColor: try values.decodeIfPresent(String.self, forKey: .rsiColor) ?? "#9467bd",
            rsiLineWidth: try values.decodeIfPresent(Int.self, forKey: .rsiLineWidth) ?? 2,
            macdColor: try values.decodeIfPresent(String.self, forKey: .macdColor) ?? "#4183c4",
            signalColor: try values.decodeIfPresent(String.self, forKey: .signalColor) ?? "#da9147",
            macdLineWidth: try values.decodeIfPresent(Int.self, forKey: .macdLineWidth) ?? 2,
            macdLineEnabled: try values.decodeIfPresent(Bool.self, forKey: .macdLineEnabled) ?? true,
            signalLineEnabled: try values.decodeIfPresent(Bool.self, forKey: .signalLineEnabled) ?? true,
            histogramEnabled: try values.decodeIfPresent(Bool.self, forKey: .histogramEnabled) ?? true,
            bollingerColor: try values.decodeIfPresent(String.self, forKey: .bollingerColor) ?? "#8a78bd",
            bollingerLineWidth: try values.decodeIfPresent(Int.self, forKey: .bollingerLineWidth) ?? 1,
            stochasticKPeriod: try values.decodeIfPresent(Int.self, forKey: .stochasticKPeriod) ?? 14,
            stochasticKSmoothing: try values.decodeIfPresent(Int.self, forKey: .stochasticKSmoothing) ?? 3,
            stochasticDPeriod: try values.decodeIfPresent(Int.self, forKey: .stochasticDPeriod) ?? 3,
            stochasticOversold: try values.decodeIfPresent(Double.self, forKey: .stochasticOversold) ?? 20,
            stochasticOverbought: try values.decodeIfPresent(Double.self, forKey: .stochasticOverbought) ?? 80,
            stochasticKColor: try values.decodeIfPresent(String.self, forKey: .stochasticKColor) ?? "#9467bd",
            stochasticDColor: try values.decodeIfPresent(String.self, forKey: .stochasticDColor) ?? "#da9147",
            stochasticLineWidth: try values.decodeIfPresent(Int.self, forKey: .stochasticLineWidth) ?? 2,
            sarStep: try values.decodeIfPresent(Double.self, forKey: .sarStep) ?? 0.02,
            sarIncrement: try values.decodeIfPresent(Double.self, forKey: .sarIncrement) ?? 0.02,
            sarMaximum: try values.decodeIfPresent(Double.self, forKey: .sarMaximum) ?? 0.2,
            sarColor: try values.decodeIfPresent(String.self, forKey: .sarColor) ?? "#16816d",
            sarDotSize: try values.decodeIfPresent(Int.self, forKey: .sarDotSize) ?? 2
        )
        componentStyles = savedStyles ?? Self.defaultComponentStyles
        if savedStyles == nil {
            componentStyles["rsi"]?.color = rsiColor
            componentStyles["rsi"]?.thickness = rsiLineWidth
            componentStyles["rsiUpper"]?.color = rsiOverboughtColor
            componentStyles["rsiMiddle"]?.color = rsiMiddleColor
            componentStyles["rsiLower"]?.color = rsiOversoldColor
            componentStyles["rsiUpper"]?.visible = rsiUpperVisible
            componentStyles["rsiMiddle"]?.visible = rsiMiddleVisible
            componentStyles["rsiLower"]?.visible = rsiLowerVisible
            componentStyles["rsiUpper"]?.thickness = rsiThresholdWidth
            componentStyles["rsiMiddle"]?.thickness = rsiThresholdWidth
            componentStyles["rsiLower"]?.thickness = rsiThresholdWidth
            componentStyles["rsiFill"]?.color = rsiBackgroundColor
            componentStyles["rsiFill"]?.opacity = rsiBackgroundOpacity
            componentStyles["rsiFill"]?.visible = rsiBackgroundFillVisible
            componentStyles["macd"]?.color = macdColor
            componentStyles["macd"]?.thickness = macdLineWidth
            componentStyles["macd"]?.visible = macdLineEnabled
            componentStyles["signal"]?.color = signalColor
            componentStyles["signal"]?.visible = signalLineEnabled
            componentStyles["macdHistogram"]?.visible = histogramEnabled
            componentStyles["bbUpper"]?.color = bollingerColor
            componentStyles["bbMiddle"]?.color = bollingerColor
            componentStyles["bbLower"]?.color = bollingerColor
            componentStyles["bbUpper"]?.thickness = bollingerLineWidth
            componentStyles["bbMiddle"]?.thickness = bollingerLineWidth
            componentStyles["bbLower"]?.thickness = bollingerLineWidth
            componentStyles["stochasticK"]?.color = stochasticKColor
            componentStyles["stochasticD"]?.color = stochasticDColor
            componentStyles["stochasticK"]?.thickness = stochasticLineWidth
            componentStyles["stochasticD"]?.thickness = stochasticLineWidth
            componentStyles["sar"]?.color = sarColor
            componentStyles["sar"]?.thickness = sarDotSize
        }
    }
}

struct LightweightChartMarker: Codable, Hashable {
    let time: String
    let position: String
    let color: String
    let shape: String
    let text: String
}

struct LightweightPriceRange: Codable, Hashable, Identifiable {
    let id: String
    var kind: String
    var color: String
    var lineWidth: Double
    var isLocked: Bool
    let startTime: String
    let endTime: String
    let startPrice: Double
    let endPrice: Double
    var lineStyle: String?
    var extendRight: Bool?
    var text: String?
    var fontSize: Double?
    var fontColor: String?

    init(id: String, kind: String = "range", color: String = "#1a9b82", lineWidth: Double = 1, isLocked: Bool = false,
         startTime: String, endTime: String, startPrice: Double, endPrice: Double,
         lineStyle: String? = "solid", extendRight: Bool? = false, text: String? = nil, fontSize: Double? = nil,
         fontColor: String? = nil) {
        self.id = id
        self.kind = kind
        self.color = color
        self.lineWidth = lineWidth
        self.isLocked = isLocked
        self.startTime = startTime
        self.endTime = endTime
        self.startPrice = startPrice
        self.endPrice = endPrice
        self.lineStyle = lineStyle
        self.extendRight = extendRight
        self.text = text
        let isRangeTool = ["range", "dateRange", "datePriceRange", "ruler"].contains(kind)
        self.fontSize = fontSize ?? (isRangeTool ? 10 : (kind == "pin" ? 12 : 13))
        self.fontColor = fontColor
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, color, lineWidth, isLocked, startTime, endTime, startPrice, endPrice
        case lineStyle, extendRight, text, fontSize, fontColor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "range"
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? "#1a9b82"
        lineWidth = try container.decodeIfPresent(Double.self, forKey: .lineWidth) ?? 1
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        if let s = try? container.decode(String.self, forKey: .startTime) {
            startTime = s
        } else if let intVal = try? container.decode(Int.self, forKey: .startTime) {
            startTime = String(intVal)
        } else if let dblVal = try? container.decode(Double.self, forKey: .startTime) {
            startTime = String(Int(dblVal))
        } else {
            startTime = try container.decode(String.self, forKey: .startTime)
        }
        if let e = try? container.decode(String.self, forKey: .endTime) {
            endTime = e
        } else if let intVal = try? container.decode(Int.self, forKey: .endTime) {
            endTime = String(intVal)
        } else if let dblVal = try? container.decode(Double.self, forKey: .endTime) {
            endTime = String(Int(dblVal))
        } else {
            endTime = try container.decode(String.self, forKey: .endTime)
        }
        startPrice = try container.decode(Double.self, forKey: .startPrice)
        endPrice = try container.decode(Double.self, forKey: .endPrice)
        lineStyle = try container.decodeIfPresent(String.self, forKey: .lineStyle) ?? "solid"
        extendRight = try container.decodeIfPresent(Bool.self, forKey: .extendRight) ?? false
        text = try container.decodeIfPresent(String.self, forKey: .text)
        let isRangeTool = ["range", "dateRange", "datePriceRange", "ruler"].contains(kind)
        let defaultSize: Double = isRangeTool ? 10 : (kind == "pin" ? 12 : 13)
        let decodedFontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize)
        if let decodedFontSize {
            fontSize = (isRangeTool && decodedFontSize == 13) ? 10 : decodedFontSize
        } else {
            fontSize = defaultSize
        }
        fontColor = try container.decodeIfPresent(String.self, forKey: .fontColor)
    }
}

actor LightweightChartDrawingStore {
    static let shared = LightweightChartDrawingStore()
    private let directory: URL
    private let defaults: UserDefaults
    private let legacyPrefix = "stockdeck.lightweightChart.priceRanges.v1."
    private var memoryCache: [String: [LightweightPriceRange]] = [:]

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StockDeck/ChartDrawings", isDirectory: true)
        self.defaults = defaults
    }

    func load(symbol: String) -> [LightweightPriceRange] {
        let key = symbol.uppercased()
        if let cached = memoryCache[key] {
            return cached
        }
        let url = fileURL(for: key)
        if let data = try? Data(contentsOf: url),
           let values = try? JSONDecoder().decode([LightweightPriceRange].self, from: data) {
            let valid = values.filter(Self.isValid)
            memoryCache[key] = valid
            return valid
        }
        guard let legacy = defaults.data(forKey: legacyPrefix + key),
              let values = try? JSONDecoder().decode([LightweightPriceRange].self, from: legacy) else { return [] }
        let valid = values.filter(Self.isValid)
        memoryCache[key] = valid
        do {
            try persist(valid, at: url)
            defaults.removeObject(forKey: legacyPrefix + key)
        } catch {
            // Keep the legacy copy intact until durable migration succeeds.
        }
        return valid
    }

    func save(_ ranges: [LightweightPriceRange], symbol: String) throws {
        guard ranges.allSatisfy(Self.isValid) else { throw DrawingStoreError.invalidDrawing }
        let key = symbol.uppercased()
        memoryCache[key] = ranges
        try persist(ranges, at: fileURL(for: key))
        LightweightChartMath.clearPayloadCache()
    }

    private func fileURL(for symbol: String) -> URL {
        let name = Data(symbol.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }

    private func persist(_ ranges: [LightweightPriceRange], at url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(ranges)
        try data.write(to: url, options: .atomic)
    }

    private static func isValid(_ range: LightweightPriceRange) -> Bool {
        range.startPrice.isFinite && range.endPrice.isFinite && range.startPrice > 0 && range.endPrice > 0
            && !range.startTime.isEmpty && !range.endTime.isEmpty
            && (1...4).contains(range.lineWidth)
            && (range.color == "auto" || (range.color.count == 7 && range.color.first == "#" && range.color.dropFirst().allSatisfy(\.isHexDigit)))
            && (range.fontColor == nil || range.fontColor == "auto" || (range.fontColor!.count == 7 && range.fontColor!.first == "#" && range.fontColor!.dropFirst().allSatisfy(\.isHexDigit)))
            && (range.fontSize == nil || (10...28).contains(range.fontSize!))
            && (range.text == nil || range.text!.count <= 1000)
    }

    enum DrawingStoreError: Error { case invalidDrawing }
}

enum LightweightPriceRangeStore {
    private static let prefix = "stockdeck.lightweightChart.priceRanges.v1."

    static func load(symbol: String, defaults: UserDefaults = .standard) -> [LightweightPriceRange] {
        guard let data = defaults.data(forKey: prefix + symbol.uppercased()),
              let ranges = try? JSONDecoder().decode([LightweightPriceRange].self, from: data) else { return [] }
        return ranges.filter { $0.startPrice.isFinite && $0.endPrice.isFinite }
    }

    static func save(_ ranges: [LightweightPriceRange], symbol: String, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(ranges) else { return }
        defaults.set(data, forKey: prefix + symbol.uppercased())
    }
}

struct LightweightIndicatorPoint: Codable {
    let time: String
    let value: Double
}

enum LightweightChartMath {
    private static let cacheLock = NSLock()
    private static var payloadCache: [Int: Data] = [:]
    private static var cacheOrder: [Int] = []

    static func encodedPayload(points: [PricePoint], interval: LightweightChartInterval, symbol: String,
                              currency: String, periods: [String: Int], visibleFrom: Date?,
                              markers: [LightweightChartMarker], targetPrice: Double?,
                              showInsiderMarkers: Bool = true,
                              drawings: [LightweightPriceRange] = [],
                              indicatorSettings: LightweightIndicatorSettings = .init(),
                              selectedRange: String = "3M", showsRangeControls: Bool = false,
                              availableRanges: [String] = [], visibleTo: Date? = nil) -> Data? {
        var hasher = Hasher()
        hasher.combine(symbol); hasher.combine(currency); hasher.combine(interval.rawValue)
        hasher.combine(visibleFrom?.timeIntervalSince1970); hasher.combine(visibleTo?.timeIntervalSince1970); hasher.combine(targetPrice)
        hasher.combine(showInsiderMarkers)
        hasher.combine(selectedRange); hasher.combine(showsRangeControls)
        for range in availableRanges { hasher.combine(range) }
        let settings = indicatorSettings.validated()
        hasher.combine(settings.rsiPeriod); hasher.combine(settings.rsiOversold); hasher.combine(settings.rsiOverbought)
        hasher.combine(settings.rsiThresholdsVisible); hasher.combine(settings.rsiOversoldColor)
        hasher.combine(settings.rsiOverboughtColor)
        hasher.combine(settings.rsiUpperVisible); hasher.combine(settings.rsiMiddleVisible)
        hasher.combine(settings.rsiLowerVisible); hasher.combine(settings.rsiMiddle)
        hasher.combine(settings.rsiMiddleColor); hasher.combine(settings.rsiThresholdWidth)
        hasher.combine(settings.rsiBackgroundFillVisible); hasher.combine(settings.rsiBackgroundColor)
        hasher.combine(settings.rsiBackgroundOpacity); hasher.combine(settings.rsiAxisLabelsVisible)
        hasher.combine(settings.rsiValuesVisible)
        hasher.combine(settings.macdFast); hasher.combine(settings.macdSlow); hasher.combine(settings.macdSignal)
        hasher.combine(settings.bollingerPeriod); hasher.combine(settings.bollingerDeviations)
        hasher.combine(settings.rsiColor); hasher.combine(settings.rsiLineWidth)
        hasher.combine(settings.macdColor); hasher.combine(settings.signalColor); hasher.combine(settings.macdLineWidth)
        hasher.combine(settings.macdLineEnabled); hasher.combine(settings.signalLineEnabled); hasher.combine(settings.histogramEnabled)
        hasher.combine(settings.bollingerColor); hasher.combine(settings.bollingerLineWidth)
        hasher.combine(settings.stochasticKPeriod); hasher.combine(settings.stochasticKSmoothing)
        hasher.combine(settings.stochasticDPeriod); hasher.combine(settings.stochasticOversold)
        hasher.combine(settings.stochasticOverbought); hasher.combine(settings.stochasticKColor)
        hasher.combine(settings.stochasticDColor); hasher.combine(settings.stochasticLineWidth)
        hasher.combine(settings.sarStep); hasher.combine(settings.sarIncrement); hasher.combine(settings.sarMaximum)
        hasher.combine(settings.sarColor); hasher.combine(settings.sarDotSize)
        for key in settings.componentStyles.keys.sorted() {
            guard let style = settings.componentStyles[key] else { continue }
            hasher.combine(key); hasher.combine(style.visible); hasher.combine(style.color)
            hasher.combine(style.opacity); hasher.combine(style.thickness); hasher.combine(style.lineStyle)
            hasher.combine(style.plotType)
        }
        for marker in markers {
            hasher.combine(marker.time); hasher.combine(marker.position); hasher.combine(marker.color)
            hasher.combine(marker.shape); hasher.combine(marker.text)
        }
        for key in periods.keys.sorted() { hasher.combine(key); hasher.combine(periods[key]) }
        for drawing in drawings {
            hasher.combine(drawing)
        }
        for point in points {
            hasher.combine(point.date.timeIntervalSince1970); hasher.combine(point.close)
            hasher.combine(point.open); hasher.combine(point.high); hasher.combine(point.low); hasher.combine(point.volume)
        }
        let key = hasher.finalize()
        cacheLock.lock()
        if let cached = payloadCache[key] { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        let value = payload(points: points, interval: interval, symbol: symbol, currency: currency,
                            periods: periods, visibleFrom: visibleFrom, markers: markers, targetPrice: targetPrice,
                            showInsiderMarkers: showInsiderMarkers, drawings: drawings, indicatorSettings: settings,
                            selectedRange: selectedRange, showsRangeControls: showsRangeControls,
                            availableRanges: availableRanges, visibleTo: visibleTo)
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        cacheLock.lock()
        payloadCache[key] = data
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        if cacheOrder.count > 8 { payloadCache.removeValue(forKey: cacheOrder.removeFirst()) }
        cacheLock.unlock()
        return data
    }

    static func clearPayloadCache() {
        cacheLock.lock()
        payloadCache.removeAll()
        cacheOrder.removeAll()
        cacheLock.unlock()
    }

    static func aggregate(_ input: [PricePoint], interval: LightweightChartInterval,
                          symbol: String, calendar: Calendar = .current) -> [PricePoint] {
        let ordered = deduplicate(input).sorted { $0.date < $1.date }
        guard interval != .day else { return deduplicate(ordered) }
        var cal = calendar
        let schedule = MarketCategory.marketSchedule(for: symbol)
        cal.timeZone = schedule.timeZone
        cal.firstWeekday = 2
        cal.minimumDaysInFirstWeek = 4
        var result: [PricePoint] = []
        var key: Date?
        for point in ordered where valid(point) {
            let bucket: Date
            if let seconds = interval.seconds {
                let day = cal.startOfDay(for: point.date)
                let anchor = cal.date(byAdding: .minute, value: schedule.mondayOpenMinutes, to: day) ?? day
                bucket = anchor.addingTimeInterval(floor(point.date.timeIntervalSince(anchor) / Double(seconds)) * Double(seconds))
            } else if interval == .week {
                bucket = cal.dateInterval(of: .weekOfYear, for: point.date)?.start ?? cal.startOfDay(for: point.date)
            } else {
                let span = interval == .quarter ? 3 : interval == .halfYear ? 6 : interval == .year ? 12 : 1
                var components = cal.dateComponents([.year, .month], from: point.date)
                components.month = ((components.month! - 1) / span) * span + 1
                components.day = 1
                bucket = cal.date(from: components) ?? cal.startOfDay(for: point.date)
            }
            if key == bucket, let last = result.popLast() {
                let preservesOHLC = last.open != nil && last.high != nil && last.low != nil
                    && point.open != nil && point.high != nil && point.low != nil
                let volume: Double? = last.volume != nil || point.volume != nil
                    ? (last.volume ?? 0) + (point.volume ?? 0) : nil
                result.append(PricePoint(date: last.date, close: point.close,
                    open: preservesOHLC ? last.open : nil,
                    high: preservesOHLC ? max(last.high!, point.high!) : nil,
                    low: preservesOHLC ? min(last.low!, point.low!) : nil, volume: volume))
            } else {
                key = bucket
                result.append(PricePoint(date: interval == .week || interval == .month ? point.date : bucket,
                    close: point.close, open: point.open, high: point.high, low: point.low, volume: point.volume))
            }
        }
        return deduplicate(result)
    }

    static func payload(points: [PricePoint], interval: LightweightChartInterval, symbol: String,
                        currency: String, periods: [String: Int], visibleFrom: Date? = nil,
                        markers: [LightweightChartMarker] = [], targetPrice: Double? = nil,
                        showInsiderMarkers: Bool = true,
                        drawings: [LightweightPriceRange] = [],
                        indicatorSettings: LightweightIndicatorSettings = .init(),
                        selectedRange: String = "3M", showsRangeControls: Bool = false,
                        availableRanges: [String] = [], visibleTo: Date? = nil) -> LightweightChartPayload {
        let settings = indicatorSettings.validated()
        let grouped = aggregate(points, interval: interval, symbol: symbol)
        let bars = grouped.compactMap { point -> LightweightBar? in
            guard valid(point) else { return nil }
            return LightweightBar(time: chartTime(point.date, interval: interval, symbol: symbol),
                                  open: point.open, high: point.high, low: point.low,
                                  close: point.close, volume: point.volume.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil })
        }
        let ohlcBars = bars.filter { bar in
            guard let open = bar.open, let high = bar.high, let low = bar.low else { return false }
            return high.isFinite && low.isFinite && open.isFinite
                && high >= max(open, bar.close) && low <= min(open, bar.close)
        }
        let hasOHLC = !ohlcBars.isEmpty
        let closes = bars.map(\.close)
        var lines: [String: [LightweightIndicatorPoint]] = [:]
        for (name, period) in periods where period > 0 {
            let values: [Double?]
            let components = name.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            if components.count == 3, components[0].hasPrefix("MA ") {
                let source = components[2]
                guard source == "close" || hasOHLC else {
                    lines[name] = []
                    continue
                }
                let sourceBars: [LightweightBar]
                let prices: [Double]
                switch source {
                case "open": sourceBars = bars.filter { $0.open != nil }; prices = sourceBars.compactMap(\.open)
                case "high": sourceBars = bars.filter { $0.high != nil }; prices = sourceBars.compactMap(\.high)
                case "low": sourceBars = bars.filter { $0.low != nil }; prices = sourceBars.compactMap(\.low)
                case "hl2": sourceBars = bars.filter { $0.high != nil && $0.low != nil }; prices = sourceBars.compactMap { bar in
                    guard let high = bar.high, let low = bar.low else { return nil }; return (high + low) / 2
                }
                case "hlc3": sourceBars = bars.filter { $0.high != nil && $0.low != nil }; prices = sourceBars.compactMap { bar in
                    guard let high = bar.high, let low = bar.low else { return nil }; return (high + low + bar.close) / 3
                }
                case "ohlc4": sourceBars = bars.filter { $0.open != nil && $0.high != nil && $0.low != nil }; prices = sourceBars.compactMap { bar in
                    guard let open = bar.open, let high = bar.high, let low = bar.low else { return nil }
                    return (open + high + low + bar.close) / 4
                }
                default: sourceBars = bars; prices = closes
                }
                switch components[1] {
                case "SMA": values = sma(prices, period)
                case "EMA": values = ema(prices, period)
                default: continue
                }
            } else {
                switch name.split(separator: " ").first.map(String.init) {
                case "SMA": values = sma(closes, period)
                case "EMA": values = ema(closes, period)
                default: continue
                }
            }
            let sourceBars: [LightweightBar]
            if components.count == 3, components[0].hasPrefix("MA ") {
                switch components[2] {
                case "open": sourceBars = bars.filter { $0.open != nil }
                case "high": sourceBars = bars.filter { $0.high != nil }
                case "low": sourceBars = bars.filter { $0.low != nil }
                case "hl2", "hlc3": sourceBars = bars.filter { $0.high != nil && $0.low != nil }
                case "ohlc4": sourceBars = bars.filter { $0.open != nil && $0.high != nil && $0.low != nil }
                default: sourceBars = bars
                }
            } else { sourceBars = bars }
            lines[name] = zip(sourceBars, values).compactMap { bar, value in
                value.map { LightweightIndicatorPoint(time: bar.time, value: $0) }
            }
        }
        func indicatorPoints(_ values: [Double?], on source: [LightweightBar] = bars) -> [LightweightIndicatorPoint] {
            zip(source, values).compactMap { bar, value in
                value.flatMap { $0.isFinite ? LightweightIndicatorPoint(time: bar.time, value: $0) : nil }
            }
        }
        let bands = bollinger(closes, settings.bollingerPeriod, settings.bollingerDeviations)
        let macdValues = macd(closes, fast: settings.macdFast, slow: settings.macdSlow, signal: settings.macdSignal)
        let highs = ohlcBars.compactMap(\.high), lows = ohlcBars.compactMap(\.low)
        let stochasticValues = showsRangeControls && hasOHLC
            ? stochastic(highs: highs, lows: lows, closes: ohlcBars.map(\.close), kPeriod: settings.stochasticKPeriod,
                         kSmoothing: settings.stochasticKSmoothing, dPeriod: settings.stochasticDPeriod)
            : (k: Array<Double?>(repeating: nil, count: ohlcBars.count), d: Array<Double?>(repeating: nil, count: ohlcBars.count))
        let sarValues = showsRangeControls && hasOHLC
            ? parabolicSAR(highs: highs, lows: lows, closes: ohlcBars.map(\.close), step: settings.sarStep,
                           increment: settings.sarIncrement, maximum: settings.sarMaximum)
            : Array<Double?>(repeating: nil, count: ohlcBars.count)
        var markerTimes: [String: String] = [:]
        if interval.isIntraday {
            for (point, bar) in zip(grouped, bars) {
                let day = tradingDay(point.date, symbol: symbol)
                if markerTimes[day] == nil { markerTimes[day] = bar.time }
            }
        }
        let displayMarkers = interval.isIntraday ? markers.compactMap { marker -> LightweightChartMarker? in
            guard let time = markerTimes[marker.time] else { return nil }
            return .init(time: time, position: marker.position, color: marker.color, shape: marker.shape, text: marker.text)
        } : markers
        return LightweightChartPayload(symbol: symbol, currency: currency,
            timeZone: MarketCategory.marketSchedule(for: symbol).timeZone.identifier, interval: interval.rawValue,
            bars: bars, visibleFrom: visibleFrom.map { chartTime($0, interval: interval, symbol: symbol) },
            visibleTo: visibleTo.map { chartTime($0, interval: interval, symbol: symbol) },
            markers: displayMarkers, targetPrice: targetPrice.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
            showInsiderMarkers: showInsiderMarkers, drawings: drawings,
            hasOHLC: hasOHLC, lines: lines, rsi: indicatorPoints(rsi(closes, settings.rsiPeriod)),
            macd: indicatorPoints(macdValues.macd), signal: indicatorPoints(macdValues.signal),
            histogram: indicatorPoints(macdValues.histogram),
            stochasticK: indicatorPoints(stochasticValues.k, on: ohlcBars), stochasticD: indicatorPoints(stochasticValues.d, on: ohlcBars),
            parabolicSAR: indicatorPoints(sarValues, on: ohlcBars), upperBand: indicatorPoints(bands.upper),
            middleBand: indicatorPoints(bands.middle), lowerBand: indicatorPoints(bands.lower),
            indicatorSettings: settings, selectedRange: selectedRange,
            showsRangeControls: showsRangeControls, availableRanges: availableRanges)
    }

    static func sma(_ values: [Double], _ period: Int) -> [Double?] {
        guard period > 0 else { return Array(repeating: nil, count: values.count) }
        var output = Array<Double?>(repeating: nil, count: values.count)
        guard values.count >= period else { return output }
        var sum = values.prefix(period).reduce(0, +)
        output[period - 1] = sum / Double(period)
        for i in period..<values.count { sum += values[i] - values[i - period]; output[i] = sum / Double(period) }
        return output
    }

    static func ema(_ values: [Double], _ period: Int) -> [Double?] {
        guard period > 0, values.count >= period else { return Array(repeating: nil, count: values.count) }
        var output = Array<Double?>(repeating: nil, count: values.count)
        var current = values.prefix(period).reduce(0, +) / Double(period)
        output[period - 1] = current
        let alpha = 2 / Double(period + 1)
        for i in period..<values.count { current += alpha * (values[i] - current); output[i] = current }
        return output
    }

    static func bollinger(_ values: [Double], _ period: Int, _ deviations: Double)
        -> (upper: [Double?], middle: [Double?], lower: [Double?]) {
        var upper = Array<Double?>(repeating: nil, count: values.count)
        var middle = upper, lower = upper
        guard period > 0, values.count >= period else { return (upper, middle, lower) }
        for index in (period - 1)..<values.count {
            let window = values[(index - period + 1)...index]
            let mean = window.reduce(0, +) / Double(period)
            let variance = window.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(period)
            let offset = sqrt(variance) * deviations
            middle[index] = mean; upper[index] = mean + offset; lower[index] = mean - offset
        }
        return (upper, middle, lower)
    }

    static func rsi(_ values: [Double], _ period: Int) -> [Double?] {
        var output = Array<Double?>(repeating: nil, count: values.count)
        guard period > 0, values.count > period else { return output }
        var gain = 0.0, loss = 0.0
        for index in 1...period {
            let change = values[index] - values[index - 1]
            gain += max(change, 0); loss += max(-change, 0)
        }
        gain /= Double(period); loss /= Double(period)
        func value(_ gain: Double, _ loss: Double) -> Double {
            gain == 0 && loss == 0 ? 50 : loss == 0 ? 100 : 100 - 100 / (1 + gain / loss)
        }
        output[period] = value(gain, loss)
        for index in (period + 1)..<values.count {
            let change = values[index] - values[index - 1]
            gain = (gain * Double(period - 1) + max(change, 0)) / Double(period)
            loss = (loss * Double(period - 1) + max(-change, 0)) / Double(period)
            output[index] = value(gain, loss)
        }
        return output
    }

    static func macd(_ values: [Double], fast: Int, slow: Int, signal: Int)
        -> (macd: [Double?], signal: [Double?], histogram: [Double?]) {
        let fastEMA = ema(values, fast), slowEMA = ema(values, slow)
        var line = Array<Double?>(repeating: nil, count: values.count)
        for index in values.indices {
            if let fastValue = fastEMA[index], let slowValue = slowEMA[index] { line[index] = fastValue - slowValue }
        }
        let first = line.firstIndex(where: { $0 != nil }) ?? values.count
        let compact = line.compactMap { $0 }
        let compactSignal = ema(compact, signal)
        var signalLine = Array<Double?>(repeating: nil, count: values.count)
        var histogram = signalLine
        for offset in compact.indices {
            let index = first + offset
            if index < values.count, let sig = compactSignal[offset], let macdValue = line[index] {
                signalLine[index] = sig; histogram[index] = macdValue - sig
            }
        }
        return (line, signalLine, histogram)
    }

    static func stochastic(highs: [Double], lows: [Double], closes: [Double], kPeriod: Int,
                           kSmoothing: Int = 3, dPeriod: Int = 3) -> (k: [Double?], d: [Double?]) {
        let count = closes.count
        let empty = Array<Double?>(repeating: nil, count: count)
        guard highs.count == count, lows.count == count, kPeriod > 0, kSmoothing > 0, dPeriod > 0,
              highs.allSatisfy(\.isFinite), lows.allSatisfy(\.isFinite), closes.allSatisfy(\.isFinite),
              count >= kPeriod else { return (empty, empty) }
        var raw = empty
        for index in (kPeriod - 1)..<count {
            let start = index - kPeriod + 1
            let highest = highs[start...index].max() ?? highs[index]
            let lowest = lows[start...index].min() ?? lows[index]
            let span = highest - lowest
            raw[index] = span > 0 ? (closes[index] - lowest) / span * 100 : 50
        }
        let smoothedK = movingAverage(raw, period: kSmoothing)
        return (smoothedK, movingAverage(smoothedK, period: dPeriod))
    }

    static func parabolicSAR(highs: [Double], lows: [Double], closes: [Double], step: Double = 0.02,
                             increment: Double = 0.02, maximum: Double = 0.2) -> [Double?] {
        let count = closes.count
        var output = Array<Double?>(repeating: nil, count: count)
        guard highs.count == count, lows.count == count, count >= 2,
              highs.allSatisfy(\.isFinite), lows.allSatisfy(\.isFinite), closes.allSatisfy(\.isFinite),
              step > 0, increment > 0, maximum >= step else { return output }
        var isRising = closes[1] >= closes[0]
        var sar = isRising ? min(lows[0], lows[1]) : max(highs[0], highs[1])
        var extreme = isRising ? max(highs[0], highs[1]) : min(lows[0], lows[1])
        var acceleration = step
        output[1] = sar
        guard count > 2 else { return output }
        for index in 2..<count {
            var candidate = sar + acceleration * (extreme - sar)
            if isRising {
                candidate = min(candidate, min(lows[index - 1], lows[index - 2]))
                if lows[index] < candidate {
                    isRising = false
                    candidate = extreme
                    extreme = lows[index]
                    acceleration = step
                } else if highs[index] > extreme {
                    extreme = highs[index]
                    acceleration = min(acceleration + increment, maximum)
                }
            } else {
                candidate = max(candidate, max(highs[index - 1], highs[index - 2]))
                if highs[index] > candidate {
                    isRising = true
                    candidate = extreme
                    extreme = highs[index]
                    acceleration = step
                } else if lows[index] < extreme {
                    extreme = lows[index]
                    acceleration = min(acceleration + increment, maximum)
                }
            }
            sar = candidate
            output[index] = candidate
        }
        return output
    }

    private static func movingAverage(_ values: [Double?], period: Int) -> [Double?] {
        var output = Array<Double?>(repeating: nil, count: values.count)
        guard period > 0 else { return output }
        var sum = 0.0
        var validCount = 0
        for index in values.indices {
            if let value = values[index] { sum += value; validCount += 1 }
            if index >= period, let removed = values[index - period] { sum -= removed; validCount -= 1 }
            if index >= period - 1, validCount == period { output[index] = sum / Double(period) }
        }
        return output
    }

    static func chartTime(_ date: Date, interval: LightweightChartInterval, symbol: String) -> String {
        interval.isIntraday ? String(Int(date.timeIntervalSince1970)) : tradingDay(date, symbol: symbol)
    }
    private static func valid(_ point: PricePoint) -> Bool { point.close.isFinite && point.close > 0 }
    static func tradingDay(_ date: Date, symbol: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MarketCategory.marketSchedule(for: symbol).timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }
    private static func deduplicate(_ points: [PricePoint]) -> [PricePoint] {
        var map: [Date: PricePoint] = [:]
        for point in points where valid(point) {
            guard let existing = map[point.date] else { map[point.date] = point; continue }
            let existingScore = (existing.open != nil ? 1 : 0) + (existing.high != nil ? 1 : 0)
                + (existing.low != nil ? 1 : 0) + (existing.volume != nil ? 1 : 0)
            let pointScore = (point.open != nil ? 1 : 0) + (point.high != nil ? 1 : 0)
                + (point.low != nil ? 1 : 0) + (point.volume != nil ? 1 : 0)
            if pointScore > existingScore { map[point.date] = point }
        }
        return map.values.sorted { $0.date < $1.date }
    }
}

struct LightweightCustomRange: Equatable, Codable {
    let from: String
    let to: String

    func dates(symbol: String) -> (Date, Date)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MarketCategory.marketSchedule(for: symbol).timeZone
        func date(_ text: String) -> Date? {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3, text.count == 10,
                  let value = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                  LightweightChartMath.tradingDay(value, symbol: symbol) == text else { return nil }
            return value
        }
        guard let start = date(from), let end = date(to), start <= end,
              let nextDay = calendar.date(byAdding: .day, value: 1, to: end) else { return nil }
        return (start, nextDay.addingTimeInterval(-1))
    }

    func automaticInterval(symbol: String) -> LightweightChartInterval {
        guard let (start, end) = dates(symbol: symbol) else { return .day }
        let days = end.timeIntervalSince(start) / 86400
        return days <= 366 ? .day : days <= 5 * 366 ? .week : .month
    }
}

struct LightweightChartViewSelection: Equatable {
    let range: String
    let interval: LightweightChartInterval
    var customRange: LightweightCustomRange? = nil
}

enum LightweightChartSurface: String {
    case detail
    case superchart
}

enum LightweightChartViewSelectionStore {
    static func load(symbol: String, surface: LightweightChartSurface,
                     defaults: UserDefaults = .standard) -> LightweightChartViewSelection? {
        let key = sharedKey(surface: surface)
        if let saved = defaults.dictionary(forKey: key),
           let selection = decode(saved, symbol: symbol) { return selection }

        // Migrate the previous per-symbol selection once, using the currently
        // open symbol as the initial shared toolbar choice for this chart.
        if let saved = defaults.dictionary(forKey: scopedKey(symbol, surface: surface)),
           let selection = decode(saved, symbol: symbol) {
            save(selection, surface: surface, defaults: defaults)
            return selection
        }

        // Also migrate selections from versions before the v2 per-symbol store.
        let legacyKey = surface == .superchart ? "stockdeck.superchart.view.v1" : legacySymbolKey(symbol)
        guard let saved = defaults.dictionary(forKey: legacyKey),
              let selection = decode(saved, symbol: symbol) else { return nil }
        save(selection, surface: surface, defaults: defaults)
        if surface == .superchart { defaults.removeObject(forKey: legacyKey) }
        return selection
    }

    static func save(_ selection: LightweightChartViewSelection,
                     surface: LightweightChartSurface, defaults: UserDefaults = .standard) {
        var values = ["range": selection.range, "interval": selection.interval.rawValue]
        if let custom = selection.customRange {
            values["customFrom"] = custom.from
            values["customTo"] = custom.to
        }
        defaults.set(values, forKey: sharedKey(surface: surface))
    }

    private static func decode(_ saved: [String: Any], symbol: String) -> LightweightChartViewSelection? {
        guard
              let range = saved["range"] as? String,
              (LightweightChartRangePreset(rawValue: range) != nil || range == "Custom"),
              let rawInterval = saved["interval"] as? String,
              let interval = LightweightChartInterval(rawValue: rawInterval) else { return nil }
        let custom = (saved["customFrom"] as? String).flatMap { from in
            (saved["customTo"] as? String).map { LightweightCustomRange(from: from, to: $0) }
        }
        guard range != "Custom" || custom?.dates(symbol: symbol) != nil else { return nil }
        return LightweightChartViewSelection(range: range, interval: interval, customRange: custom)
    }

    private static func scopedKey(_ symbol: String, surface: LightweightChartSurface) -> String {
        "stockdeck.lightweightChart.view.v2.\(surface.rawValue).\(StockService.canonicalSymbol(for: symbol))"
    }

    private static func sharedKey(surface: LightweightChartSurface) -> String {
        "stockdeck.lightweightChart.view.v3.\(surface.rawValue)"
    }

    private static func legacySymbolKey(_ symbol: String) -> String {
        "stockdeck.lightweightChart.view.v1.\(StockService.canonicalSymbol(for: symbol))"
    }
}

@MainActor
struct LightweightPriceChartView: View {
    let symbol: String
    let points: [PricePoint]
    let maxPoints: [PricePoint]
    let currency: String
    let visibleFrom: Date?
    let markers: [LightweightChartMarker]
    let targetPrice: Double?
    let isLoading: Bool
    let retry: () -> Void
    @Binding var selectedRange: String
    let showsRangePicker: Bool
    var surface: LightweightChartSurface = .detail
    var pineIndicators: [CustomPineIndicator] = []
    var pineMenuItems: [PineScriptMenuItem] = []
    var onManagePineScripts: () -> Void = {}
    var onCustomPineAction: (UUID, String) -> Void = { _, _ in }
    var onPineInput: (PineChartInput) -> Void = { _ in }
    private static let allRanges = ["1D", "5D", "1M", "3M", "6M", "YTD", "1Y", "3Y", "5Y", "7Y", "10Y", "All"]
    @State private var interval: LightweightChartInterval = .day
    @State private var webView: WKWebView?
    @State private var state = "loading"
    @State private var restoredViewForSymbol: String?
    @State private var skipRangeAutoSelection = false
    @State private var customRange: LightweightCustomRange?
    @State private var intradayPoints: [PricePoint] = []
    @State private var intradaySymbol: String?
    @State private var intradayError: String?
    @State private var loadingIntraday = false
    @State private var intradayReload = 0
    private var hasOHLC: Bool { activePoints.contains { point in
        guard let open = point.open, let high = point.high, let low = point.low else { return false }
        return open.isFinite && high.isFinite && low.isFinite && high >= max(open, point.close) && low <= min(open, point.close)
    } }

    private var rangeStart: Date? {
        if selectedRange == "Custom" { return customRange?.dates(symbol: symbol)?.0 }
        if selectedRange == "All" { return nil }
        let now = activePoints.last?.date ?? Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MarketCategory.marketSchedule(for: symbol).timeZone
        switch selectedRange {
        case "1D", "5D":
            let days = Array(Set(activePoints.map { calendar.startOfDay(for: $0.date) })).sorted()
            let count = selectedRange == "1D" ? 1 : 5
            return days.isEmpty ? nil : days[max(0, days.count - count)]
        case "1M": return calendar.date(byAdding: .month, value: -1, to: now)
        case "3M": return calendar.date(byAdding: .month, value: -3, to: now)
        case "6M": return calendar.date(byAdding: .month, value: -6, to: now)
        case "YTD": return calendar.date(from: calendar.dateComponents([.year], from: now))
        case "1Y": return calendar.date(byAdding: .year, value: -1, to: now)
        case "3Y": return calendar.date(byAdding: .year, value: -3, to: now)
        case "5Y": return calendar.date(byAdding: .year, value: -5, to: now)
        case "7Y": return calendar.date(byAdding: .year, value: -7, to: now)
        case "10Y": return calendar.date(byAdding: .year, value: -10, to: now)
        default: return visibleFrom
        }
    }

    private var activePoints: [PricePoint] {
        if interval.isIntraday { return intradaySymbol == symbol ? intradayPoints : [] }
        if selectedRange == "Custom", let start = customRange?.dates(symbol: symbol)?.0,
           let first = points.first?.date, start < first, !maxPoints.isEmpty {
            return maxPoints
        }
        if ["7Y", "10Y", "All"].contains(selectedRange), !maxPoints.isEmpty { return maxPoints }
        return points
    }

    private var activeInterval: LightweightChartInterval {
        interval
    }

    var pineInput: PineChartInput {
        // maxPoints may contain monthly history for long ranges; it must not replace the daily source.
        PineChartInput(symbol: symbol, interval: interval, points: activePoints, dailyPoints: points,
            loading: interval.isIntraday ? (loadingIntraday || intradaySymbol != symbol) : (points.isEmpty && isLoading),
            error: interval.isIntraday ? intradayError : nil)
    }
    private func hasHistoryCoverage(for range: String) -> Bool {
        let history = maxPoints.isEmpty ? points : maxPoints
        guard let years = Int(range.dropLast()), let first = history.first?.date,
              let last = history.last?.date else { return false }
        let required = Double(years) * 365.2425 * 24 * 60 * 60
        return last.timeIntervalSince(first) >= required - 31 * 24 * 60 * 60
    }

    private var availableRanges: [String] {
        Self.allRanges.filter { range in
            !["3Y", "5Y", "7Y", "10Y"].contains(range) || hasHistoryCoverage(for: range)
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            if !showsRangePicker {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(LightweightChartInterval.allCases) { item in
                            Button(item.label) { selectInterval(item) }
                        }
                    } label: {
                        Label(activeInterval.label, systemImage: "chevron.down")
                            .font(.inter(12, weight: .semibold, relativeTo: .body))
                    }
                    .help("Khung nến; khoảng xem sẽ chọn D/W/M tự động, hoặc chọn thủ công.")
                    Spacer()
                    if !hasOHLC && !points.isEmpty {
                        Text("Chỉ có giá đóng cửa; đang hiển thị đường giá.").font(.caption2).foregroundStyle(DS.inkTertiary)
                    }
                }
            }
            if state == "error" {
                ContentUnavailableView("Không mở được chart", systemImage: "exclamationmark.triangle",
                    description: Text("Thử tải lại chart."))
                Button("Thử lại") { state = "loading"; webView?.reload(); retry() }
            } else if activePoints.isEmpty && isLoading && webView == nil && !showsRangePicker {
                ProgressView("Đang tải lịch sử giá…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if activePoints.isEmpty && webView == nil && !showsRangePicker && !interval.isIntraday {
                ContentUnavailableView("Không có lịch sử giá", systemImage: "chart.xyaxis.line",
                    description: Text("Chưa có lịch sử giá cho mã này."))
                Button("Thử lại", action: retry).padding(.bottom, 12)
            } else {
                ZStack(alignment: .top) {
                    if showsRangePicker || interval.isIntraday || !activePoints.isEmpty || webView != nil {
                        LightweightChartWebView(symbol: symbol, interval: activeInterval, points: activePoints,
                            currency: currency, visibleFrom: rangeStart, markers: markers,
                            targetPrice: targetPrice, showInsiderMarkers: StorageService.shared.showInsiderMarkers,
                            selectedRange: selectedRange, showsRangeControls: showsRangePicker, surface: surface,
                            pineIndicators: pineIndicators, pineMenuItems: pineMenuItems, onManagePineScripts: onManagePineScripts,
                            onCustomPineAction: onCustomPineAction,
                            availableRanges: availableRanges,
                            onSelectRange: selectRange, onSelectInterval: selectInterval,
                            visibleTo: selectedRange == "Custom" ? customRange?.dates(symbol: symbol)?.1 : nil,
                            onSelectCustomRange: selectCustomRange,
                            webView: $webView, state: $state)
                    }
                    if interval.isIntraday && loadingIntraday {
                        ProgressView("Đang tải dữ liệu trong ngày…").padding(8).background(.regularMaterial, in: Capsule()).padding(.top, 60)
                    } else if interval.isIntraday && activePoints.isEmpty {
                        VStack(spacing: 8) {
                            Text(intradayError ?? "Không có dữ liệu trong ngày cho mã này.")
                                .multilineTextAlignment(.center).frame(maxWidth: 360)
                            Button("Thử lại") { intradayReload += 1 }
                        }.padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(.top, 60)
                    } else if activePoints.isEmpty && isLoading { ProgressView("Đang tải lịch sử giá…").padding(8).background(.regularMaterial, in: Capsule()) }
                    else if activePoints.isEmpty { ContentUnavailableView("Không có lịch sử giá", systemImage: "chart.xyaxis.line", description: Text("Chưa có lịch sử giá cho mã này.")); Button("Thử lại", action: retry) }
                    else if state == "loading" { ProgressView("Đang dựng chart…").padding(8).background(.regularMaterial, in: Capsule()) }
                }
            }
            Link("Lightweight Charts by TradingView", destination: URL(string: "https://www.tradingview.com/")!)
                .font(.system(size: 9)).foregroundStyle(DS.inkTertiary).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: pineInput, initial: true) { _, input in
            onPineInput(input)
        }
        .task(id: "\(symbol)|\(interval.isIntraday)|\(intradayReload)") {
            guard interval.isIntraday else { loadingIntraday = false; return }
            loadingIntraday = true
            intradayError = nil
            let requestedSymbol = symbol
            do {
                let loaded = try await SuperchartIntradayLoader.shared.load(symbol: requestedSymbol)
                guard !Task.isCancelled else { return }
                intradaySymbol = requestedSymbol
                intradayPoints = loaded
            } catch {
                guard !Task.isCancelled else { return }
                intradaySymbol = requestedSymbol
                intradayPoints = []
                intradayError = error.localizedDescription
            }
            loadingIntraday = false
        }
        .onAppear { restoreView(for: symbol) }
        .onChange(of: symbol) { _, newSymbol in
            restoreView(for: newSymbol)
        }
        .onChange(of: selectedRange) { _, range in
            if skipRangeAutoSelection { skipRangeAutoSelection = false; persistView(); return }
            let preset = LightweightChartRangePreset(rawValue: range)
            interval = range == "Custom" ? (customRange?.automaticInterval(symbol: symbol) ?? .day)
                : preset?.automaticInterval ?? LightweightChartInterval.automatic(
                visibleFrom: nil, points: maxPoints.isEmpty ? points : maxPoints)
            persistView()
            webView?.evaluateJavaScript("window.resetChartView?.()")
        }
    }

    private func selectRange(_ range: String) {
        guard let preset = LightweightChartRangePreset(rawValue: range) else { return }
        let changed = selectedRange != range
        selectedRange = range
        interval = preset.automaticInterval ?? LightweightChartInterval.automatic(
            visibleFrom: nil, points: maxPoints.isEmpty ? points : maxPoints)
        persistView()
        if !changed { webView?.evaluateJavaScript("window.resetChartView?.()") }
    }

    private func selectCustomRange(_ custom: LightweightCustomRange) {
        guard custom.dates(symbol: symbol) != nil else { return }
        customRange = custom
        interval = custom.automaticInterval(symbol: symbol)
        selectedRange = "Custom"
        persistView()
        webView?.evaluateJavaScript("window.resetChartView?.()")
    }

    private func selectInterval(_ value: LightweightChartInterval) {
        interval = value
        if selectedRange == "Custom" {
            persistView()
            webView?.evaluateJavaScript("window.resetChartView?.()")
            return
        }
        let range = LightweightChartRangePreset.range(for: value).rawValue
        skipRangeAutoSelection = selectedRange != range
        selectedRange = range
        persistView()
        webView?.evaluateJavaScript("window.resetChartView?.()")
    }

    private func restoreView(for symbol: String) {
        guard restoredViewForSymbol != symbol else { return }
        restoredViewForSymbol = symbol
        customRange = nil
        if let saved = LightweightChartViewSelectionStore.load(symbol: symbol, surface: surface) {
            skipRangeAutoSelection = selectedRange != saved.range
            customRange = saved.customRange
            selectedRange = saved.range
            interval = saved.interval
        } else {
            skipRangeAutoSelection = selectedRange != "3M"
            selectedRange = "3M"
            interval = LightweightChartRangePreset.threeMonths.automaticInterval
                ?? LightweightChartInterval.automatic(visibleFrom: nil, points: maxPoints.isEmpty ? points : maxPoints)
        }
    }

    private func persistView() {
        LightweightChartViewSelectionStore.save(.init(range: selectedRange, interval: interval, customRange: customRange),
            surface: surface)
    }
}

@MainActor
struct LightweightChartWebView: NSViewRepresentable {
    let symbol: String
    let interval: LightweightChartInterval
    let points: [PricePoint]
    let currency: String
    let visibleFrom: Date?
    let markers: [LightweightChartMarker]
    let targetPrice: Double?
    let showInsiderMarkers: Bool
    let selectedRange: String
    let showsRangeControls: Bool
    var surface: LightweightChartSurface = .superchart
    var pineIndicators: [CustomPineIndicator] = []
    var pineMenuItems: [PineScriptMenuItem] = []
    var onManagePineScripts: () -> Void = {}
    var onCustomPineAction: (UUID, String) -> Void = { _, _ in }
    let availableRanges: [String]
    let onSelectRange: (String) -> Void
    let onSelectInterval: (LightweightChartInterval) -> Void
    var visibleTo: Date? = nil
    var onSelectCustomRange: (LightweightCustomRange) -> Void = { _ in }
    @Binding var webView: WKWebView?
    @Binding var state: String

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let surfaceName = surface.rawValue
        let preferenceKey = "stockdeck.chart.preferences.\(surfaceName).v1"
        var preferences: [String: Any]
        if let current = UserDefaults.standard.dictionary(forKey: preferenceKey) {
            preferences = current
            if surface == .detail && preferences["paneLayout"] == nil,
               let superchartPrefs = UserDefaults.standard.dictionary(forKey: "stockdeck.chart.preferences.superchart.v1"),
               let layout = superchartPrefs["paneLayout"] {
                preferences["paneLayout"] = layout
                UserDefaults.standard.set(preferences, forKey: preferenceKey)
            }
        } else if surface == .detail,
                  let migrated = UserDefaults.standard.dictionary(forKey: "stockdeck.chart.preferences.superchart.v1") {
            preferences = migrated
            UserDefaults.standard.set(migrated, forKey: preferenceKey)
        } else {
            preferences = [:]
        }
        if let data = try? JSONSerialization.data(withJSONObject: preferences),
           let json = String(data: data, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(source: "window.stockDeckPreferences=\(json);",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        config.userContentController.addUserScript(WKUserScript(source: "window.stockDeckChartSurface='\(surfaceName)';",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.add(context.coordinator, name: "chart")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        if let html = Bundle.module.url(forResource: "LightweightChartTrial", withExtension: "html"),
           let directory = Bundle.module.resourceURL {
            view.loadFileURL(html, allowingReadAccessTo: directory)
        }
        DispatchQueue.main.async { webView = view }
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        let symbolChanged = context.coordinator.lastSymbol.map { $0 != symbol } ?? false
        if symbolChanged { view.evaluateJavaScript("window.clearChartData?.()") }
        context.coordinator.lastSymbol = symbol
        context.coordinator.sendData(to: view)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.evaluateJavaScript("window.disposeChart?.()")
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "chart")
        coordinator.parent.webView = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
        var parent: LightweightChartWebView
        private var indicatorPeriods: [String: Int] = [:]
        var lastSymbol: String?
        private var indicatorSettings: LightweightIndicatorSettings
        private static let legacyIndicatorSettingsKey = "stockdeck.lightweightChart.indicatorSettings.v1"
        init(parent: LightweightChartWebView) {
            self.parent = parent
            let key = Self.indicatorSettingsKey(surface: parent.surface)
            let surface = parent.surface.rawValue
            let preferences = UserDefaults.standard.dictionary(forKey: "stockdeck.chart.preferences.\(surface).v1")
            let data = (preferences?["indicatorSettings"] as? String)?.data(using: .utf8)
                ?? UserDefaults.standard.data(forKey: key)
                ?? (parent.surface == .detail ? (UserDefaults.standard.data(forKey: Self.legacyIndicatorSettingsKey)
                    ?? UserDefaults.standard.data(forKey: Self.indicatorSettingsKey(surface: .superchart))) : nil)
            if let data,
               let value = try? JSONDecoder().decode(LightweightIndicatorSettings.self, from: data) {
                indicatorSettings = value.validated()
                if UserDefaults.standard.data(forKey: key) == nil,
                   let migrated = try? JSONEncoder().encode(indicatorSettings) {
                    UserDefaults.standard.set(migrated, forKey: key)
                }
            } else {
                indicatorSettings = .init()
            }
        }
        private static func indicatorSettingsKey(surface: LightweightChartSurface) -> String {
            "stockdeck.lightweightChart.indicatorSettings.\(surface.rawValue).v1"
        }
        func sendData(to webView: WKWebView) {
            guard webView.url != nil else { return }
            let requestID = UUID()
            latestRequest = requestID
            let points = parent.points, interval = parent.interval, symbol = parent.symbol, currency = parent.currency
            let visibleFrom = parent.visibleFrom, visibleTo = parent.visibleTo, markers = parent.markers, targetPrice = parent.targetPrice
            let showInsiderMarkers = parent.showInsiderMarkers
            let selectedRange = parent.selectedRange
            // Detail charts use the same full controls as Superchart, but keep
            // their stored chart preferences separate.
            let showsRangeControls = parent.showsRangeControls || parent.surface == .detail
            let availableRanges = parent.availableRanges
            let pineIndicators = parent.pineIndicators, pineMenuItems = parent.pineMenuItems
            let indicatorSettings = self.indicatorSettings
            var periods = parent.surface == .superchart
                ? ["MA 1|SMA|close": 20, "MA 2|SMA|close": 50, "MA 3|SMA|close": 100, "MA 4|SMA|close": 200]
                : ["SMA 20": 20, "SMA 50": 50, "SMA 100": 100, "SMA 200": 200,
                   "EMA 20": 20, "EMA 50": 50, "EMA 100": 100, "EMA 200": 200]
            periods.merge(indicatorPeriods) { _, new in new }
            Task { [weak self, weak webView] in
                let drawings = await LightweightChartDrawingStore.shared.load(symbol: symbol)
                let encoded = await Task.detached(priority: .userInitiated) {
                    let data = LightweightChartMath.encodedPayload(points: points, interval: interval, symbol: symbol,
                        currency: currency, periods: periods,
                        visibleFrom: visibleFrom, markers: markers, targetPrice: targetPrice,
                        showInsiderMarkers: showInsiderMarkers, drawings: drawings,
                        indicatorSettings: indicatorSettings, selectedRange: selectedRange,
                        showsRangeControls: showsRangeControls, availableRanges: availableRanges, visibleTo: visibleTo)
                    return (data?.base64EncodedString(), (try? JSONEncoder().encode(pineIndicators))?.base64EncodedString(),
                            (try? JSONEncoder().encode(pineMenuItems))?.base64EncodedString())
                }.value
                guard let base64 = encoded.0 else { return }
                guard let self, self.latestRequest == requestID, let webView else { return }
                _ = try? await webView.evaluateJavaScript("window.setChartData && window.setChartData(window.decodeStockDeckJSON('\(base64)'))")
                if let plots = encoded.1 {
                    guard self.latestRequest == requestID else { return }
                    _ = try? await webView.evaluateJavaScript("window.setCustomPineIndicators?.(window.decodeStockDeckJSON('\(plots)'))")
                }
                if let menu = encoded.2 {
                    guard self.latestRequest == requestID else { return }
                    _ = try? await webView.evaluateJavaScript("window.setPineScriptsMenu?.(window.decodeStockDeckJSON('\(menu)'))")
                }
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { parent.state = "ready"; sendData(to: webView) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { parent.state = "error" }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { parent.state = "error" }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            let alert = NSAlert()
            alert.messageText = prompt
            let field = NSTextField(string: defaultText ?? "")
            field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Hủy")
            completionHandler(alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "chartPreferenceChanged", let name = body["name"] as? String,
               ["display", "indicators", "indicatorSettings", "paneLayout", "paneScales", "viewports", "timeframes", "drawingFavorites", "drawingPreferences"].contains(name),
               let value = body["value"] as? String, value.utf8.count < 100_000 {
                let surface = parent.surface.rawValue
                let key = "stockdeck.chart.preferences.\(surface).v1"
                var preferences = UserDefaults.standard.dictionary(forKey: key) ?? [:]
                preferences[name] = value
                UserDefaults.standard.set(preferences, forKey: key)
                return
            }
            if type == "indicatorSettingsChanged",
               let value = body["settings"], JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value),
               let settings = try? JSONDecoder().decode(LightweightIndicatorSettings.self, from: data) {
                indicatorSettings = settings.validated()
                if let rawPeriods = body["periods"] as? [String: Int] {
                    indicatorPeriods = rawPeriods.filter { (1...2_000).contains($0.value) }
                }
                if let data = try? JSONEncoder().encode(indicatorSettings) {
                    UserDefaults.standard.set(data, forKey: Self.indicatorSettingsKey(surface: parent.surface))
                }
                if let webView = parent.webView { sendData(to: webView) }
            } else if type == "indicatorConfigChanged", let raw = body["periods"] as? [String: Int] {
                indicatorPeriods = raw.filter { (1...2_000).contains($0.value) }
                if let webView = parent.webView { sendData(to: webView) }
            } else if type == "toggleInsiderMarkers" {
                StorageService.shared.showInsiderMarkers = body["visible"] as? Bool ?? !StorageService.shared.showInsiderMarkers
            } else if type == "customPineAction", let rawID = body["id"] as? String,
                      let id = UUID(uuidString: rawID), let action = body["action"] as? String,
                      ["attach", "settings", "remove", "retry"].contains(action) {
                parent.onCustomPineAction(id, action)
            } else if type == "managePineScripts" {
                parent.onManagePineScripts()
            } else if type == "selectRangePreset", let range = body["range"] as? String,
                      LightweightChartRangePreset(rawValue: range) != nil {
                parent.onSelectRange(range)
            } else if type == "selectCustomRange", let from = body["from"] as? String,
                      let to = body["to"] as? String {
                let custom = LightweightCustomRange(from: from, to: to)
                if custom.dates(symbol: parent.symbol) != nil { parent.onSelectCustomRange(custom) }
            } else if type == "selectChartInterval", let rawValue = body["interval"] as? String,
                      let interval = LightweightChartInterval(rawValue: rawValue) {
                parent.onSelectInterval(interval)
            } else if type == "priceRangesChanged",
                      let symbol = body["symbol"] as? String,
                      StockService.canonicalSymbol(for: symbol) == StockService.canonicalSymbol(for: parent.symbol),
                      let ranges = body["ranges"],
                      JSONSerialization.isValidJSONObject(ranges),
                      let data = try? JSONSerialization.data(withJSONObject: ranges),
                      let decoded = try? JSONDecoder().decode([LightweightPriceRange].self, from: data) {
                guard let targetWebView = parent.webView else { return }
                Task { [weak targetWebView, weak self] in
                    let success: Bool
                    do {
                        try await LightweightChartDrawingStore.shared.save(decoded, symbol: symbol)
                        success = true
                    } catch {
                        success = false
                    }
                    guard let self, let targetWebView,
                          StockService.canonicalSymbol(for: self.parent.symbol) == StockService.canonicalSymbol(for: symbol) else { return }
                    _ = try? await targetWebView.evaluateJavaScript("window.setDrawingSaveState?.(\(success ? "true" : "false"))")
                }
            }
        }
        private var latestRequest = UUID()
    }
}
