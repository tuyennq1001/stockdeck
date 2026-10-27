import XCTest
import AppKit
@testable import StockDeck

final class PineScriptStyleTests: XCTestCase {
    func testCSSColorsDecodeAndPreserveOpacityWhenEdited() throws {
        let rgb = try XCTUnwrap(PineStyleColor("rgb(21, 255, 0)"))
        XCTAssertEqual(rgb.cssString, "#15FF00")
        let transparent = try XCTUnwrap(PineStyleColor("rgba(255, 255, 255, 0.1)"))
        XCTAssertEqual(transparent.opacityPercent, 10)
        let edited = try XCTUnwrap(PineStyleColor(transparent.nativeColor))
        XCTAssertEqual(edited.cssString, "#FFFFFF1A")
        XCTAssertEqual(PineStyleColor(edited.cssString)?.opacityPercent, 10)
        XCTAssertEqual(PineStyleColor("#fff3")?.cssString, "#FFFFFF33")
        XCTAssertEqual(PineStyleColor("rgba(100%,0%,0%,50%)")?.opacityPercent, 50)
        XCTAssertEqual(PineStyleColor("white")?.cssString, "#FFFFFF")
        XCTAssertNil(PineStyleColor("not a color"))
        XCTAssertNil(PineStyleColor("rgb(NaN,0,0)"))
        XCTAssertNil(PineStyleColor("rgb(0,0)"))
        // The existing opaque app color API retains its documented contract.
        XCTAssertEqual(transparent.nativeColor.hexString, "#FFFFFF")
    }

    func testUnnamedLevelsGetReadableLabelsWithoutChangingIDsOrPreferences() throws {
        // Explicit test-only plot fixtures, not product market data.
        let json = Data(##"{"#0":{"style":"line","title":"#0","color":"#FFFFFF1A","points":[{"time":1,"value":0.9},{"time":2,"value":0.9}],"sourceOrder":0,"isUnnamed":true,"lineWidth":1},"Risk":{"style":"line","title":"Risk","points":[{"time":1,"value":0.4,"color":"rgb(21, 255, 0)"},{"time":2,"value":0.6,"color":"#FF0000"}],"sourceOrder":1,"isUnnamed":false,"lineWidth":3}}"##.utf8)
        var plots = try JSONDecoder().decode([String: CustomPinePlot].self, from: json)
        plots["#0"]?.displayVisible = false
        plots["#0"]?.displayColorOverrides = ["#FFFFFF1A": "#12345633"]
        let model = PineScriptStylePresentation(plots: plots)
        XCTAssertEqual(model.primary.map(\.title), ["Risk"])
        XCTAssertEqual(model.primary.first?.colors, ["rgb(21, 255, 0)", "#FF0000"])
        XCTAssertEqual(model.primary.first?.lineWidth, 3)
        let level = try XCTUnwrap(model.auxiliary.first)
        XCTAssertTrue(level.title.hasPrefix("Mức "))
        XCTAssertFalse(level.title.contains("#0"))
        XCTAssertEqual(level.id, "#0")
        XCTAssertEqual(level.lineWidth, 1)
        XCTAssertEqual(model.plots["#0"]?.displayVisible, false)
        XCTAssertEqual(model.plots["#0"]?.displayColorOverrides?["#FFFFFF1A"], "#12345633")
    }

    func testExplicitInternalLookingTitlesDuplicateTitlesAndLegacyPayloads() throws {
        let json = Data(##"{"a":{"style":"line","title":"#0","points":[],"isUnnamed":false,"sourceOrder":2},"b":{"style":"line","title":"same","points":[],"sourceOrder":0},"c":{"style":"line","title":"same","points":[],"sourceOrder":1},"#10":{"style":"line","title":"#10","points":[{"time":1,"value":1},{"time":2,"value":2}]},"#2":{"style":"line","title":"#2","points":[{"time":1,"value":1},{"time":2,"value":2}]}}"##.utf8)
        let model = PineScriptStylePresentation(plots: try JSONDecoder().decode([String: CustomPinePlot].self, from: json))
        XCTAssertEqual(model.primary.map(\.id), ["b", "c", "a", "#2", "#10"])
        XCTAssertEqual(model.primary[2].title, "#0", "An explicitly named plot must retain its source title")
        XCTAssertEqual(model.primary[3].title, "Đường 4")
        XCTAssertTrue(model.auxiliary.isEmpty, "Variable lines must never be labeled as constant levels")
        XCTAssertEqual(model.plots.count, 5, "Duplicate source titles must retain independent IDs")
    }

    func testActualHelperExportsStyleMetadataAndSellMarkerDefaults() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let helper = root.appendingPathComponent(".build/debug/PineScriptRunner")
        let bars: [PineExecutionBar] = (0..<3).map { index -> PineExecutionBar in
            let time = 1_700_000_000_000.0 + Double(index) * 86_400_000.0
            return PineExecutionBar(openTime: time, closeTime: time + 86_400_000.0,
                open: 100, high: 103, low: 99, close: Double(100 + index), volume: 10, chartTime: "fixture")
        }
        let source = """
        //@version=6
        indicator("Style test",overlay=false)
        plot(0.9,color=color.new(color.white,90),linewidth=1)
        plot(close,title="same",color=color.lime,linewidth=3)
        plot(close+1,title="same",color=color.red,linewidth=2)
        plotshape(bar_index > 0,title="Sell",style=shape.triangledown,location=location.abovebar,color=color.red)
        """
        let job = CustomPineScriptRunner.Job(symbol: "TEST", timezone: "UTC", currency: "USD", source: source,
            timeframe: "D", bars: bars, datasets: ["D": bars])
        let output = try await CustomPineScriptRunner.execute(executable: helper, data: JSONEncoder().encode(job))
        let result = try JSONDecoder().decode(CustomPineRunResult.self, from: output)
        XCTAssertTrue(result.ok, result.error ?? "Helper failed")
        let plots = try XCTUnwrap(result.plots)
        XCTAssertEqual(plots.count, 4)
        let model = PineScriptStylePresentation(plots: plots)
        XCTAssertEqual(model.auxiliary.count, 1)
        XCTAssertEqual(model.auxiliary.first?.lineWidth, 1)
        XCTAssertEqual(model.primary.map(\.title), ["same", "same", "Sell"])
        XCTAssertEqual(model.primary.map(\.lineWidth).prefix(2), [3, 2])
        XCTAssertEqual(model.primary.last?.marker, "triangledown")
        XCTAssertEqual(model.primary.last?.position, "abovebar")
        XCTAssertEqual(Set(model.primary.map(\.id)).count, 3)
        XCTAssertEqual(plots.values.compactMap(\.sourceOrder).sorted(), [0, 1, 2, 3])
        let color = try XCTUnwrap(model.auxiliary.first?.colors.first.flatMap(PineStyleColor.init))
        XCTAssertEqual(color.opacityPercent, 10)
    }
}
