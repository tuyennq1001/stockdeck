import XCTest
import CryptoKit
import WebKit
@testable import StockDeck

// Opt-in measurement on a verified real capture; no timing thresholds in the test suite.
@MainActor
final class PineSMABenchmarkTests: XCTestCase {
    private struct CapturedBar: Decodable {
        let openTime: Double, open: Double, high: Double, low: Double, close: Double, volume: Double
    }
    nonisolated private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    private func summary(_ samples: [Double]) -> [String: Any] {
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        return ["samplesMs": samples, "medianMs": median, "maxMs": sorted.last!]
    }

    func testRealSMACalculationAndWebKitUpdate() async throws {
        guard ProcessInfo.processInfo.environment["STOCKDECK_PINE_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt in with STOCKDECK_PINE_BENCHMARK=1 after ./dev.sh; requires the real Bitstamp capture")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let measured = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: root.appendingPathComponent("tools/custom-script-poc/local/btc-usd-daily.json"))
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hash == "d715394871f1ab90adb9d96e25bf82991729e84a07237fb2b1601bcf4be3aebd" else {
                throw CustomPineScriptRunner.RunnerError.message("Benchmark capture hash mismatch")
            }
            let bars = try JSONDecoder().decode([CapturedBar].self, from: data)
            let points = bars.map { PricePoint(date: Date(timeIntervalSince1970: $0.openTime / 1000),
                close: $0.close, open: $0.open, high: $0.high, low: $0.low, volume: $0.volume) }
            let start = DispatchTime.now().uptimeNanoseconds
            let context = try PineExecutionContext.prepare(PineChartInput(symbol: "BTC-USD", interval: .day, points: points, dailyPoints: points))
            let preparationMs = Self.milliseconds(since: start)
            let closes = context.bars.map(\.close)
            var native: [Double?] = [], nativeMs: [Double] = []
            for index in 0..<31 {
                let start = DispatchTime.now().uptimeNanoseconds
                native = LightweightChartMath.sma(closes, 20)
                if index > 0 { nativeMs.append(Self.milliseconds(since: start)) }
            }
            let source = "//@version=6\nindicator(\"SMA20 benchmark\",overlay=true)\nplot(ta.sma(close,20),title=\"SMA20\",color=color.blue)"
            let job = CustomPineScriptRunner.Job(symbol: context.symbol, timezone: context.timezone, currency: context.currency,
                source: source, timeframe: context.interval.pineTimeframe, bars: context.bars, datasets: context.datasets)
            let encodeStart = DispatchTime.now().uptimeNanoseconds
            let encoded = try JSONEncoder().encode(job)
            let encodeMs = Self.milliseconds(since: encodeStart)
            let helper = root.appendingPathComponent(".build/StockDeck-Dev.app/Contents/MacOS/PineScriptRunner")
            var helperMs: [Double] = [], result: CustomPineRunResult?
            for _ in 0..<10 {
                let start = DispatchTime.now().uptimeNanoseconds
                let output = try await CustomPineScriptRunner.execute(executable: helper, data: encoded)
                result = try JSONDecoder().decode(CustomPineRunResult.self, from: output)
                helperMs.append(Self.milliseconds(since: start))
            }
            return (points, context, native, result!, nativeMs, helperMs, preparationMs, encodeMs, hash)
        }.value
        let (points, context, nativeValues, result, nativeMs, helperMs, preparationMs, encodeMs, hash) = measured
        print("SMA calculation complete; comparing outputs and chart updates"); fflush(stdout)
        XCTAssertEqual(result.ok, true)
        let plot = try XCTUnwrap(result.plots?.values.first)
        let byTime = Dictionary(uniqueKeysWithValues: zip(context.bars, nativeValues).map { (Int($0.0.openTime), $0.1) })
        XCTAssertEqual(plot.points.count, 2500)
        for point in plot.points {
            XCTAssertEqual(try XCTUnwrap(point.value), try XCTUnwrap(byTime[Int(point.time)] ?? nil), accuracy: 0.000001)
        }

        // Same 5,540 candles and latest 2,500 SMA points in both drawing scenarios.
        // Payload and Pine JSON are preloaded, so these timings exclude native computation/encoding and IPC.
        let payload = LightweightChartMath.payload(points: points, interval: .day, symbol: context.symbol, currency: "USD",
            periods: ["SMA MA 1|SMA|close": 20], showsRangeControls: true)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        let line = plot.points.map { ["time": context.timeMap[String(Int($0.time / 1000))]!, "value": $0.value!] as [String: Any] }
        object["lines"] = ["SMA MA 1|SMA|close": line]
        let payloadBase64 = try JSONSerialization.data(withJSONObject: object).base64EncodedString()
        let indicator = CustomPineIndicator(id: UUID(), title: "SMA20 benchmark", overlay: true, status: "loaded", error: nil,
            plots: [plot], timeMap: context.timeMap, symbol: context.symbol, interval: "1D")
        let pineBase64 = try JSONEncoder().encode([indicator]).base64EncodedString()
        let resources = root.appendingPathComponent("StockDeck/Resources")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["LightweightCharts", "CustomPineChart.js"] {
            try FileManager.default.copyItem(at: resources.appendingPathComponent(name), to: directory.appendingPathComponent(name))
        }
        let html = try String(contentsOf: resources.appendingPathComponent("LightweightChartTrial.html"))
            .replacingOccurrences(of: "const chart=C.createChart", with: "const chart=window.benchChart=C.createChart")
        let chartFile = directory.appendingPathComponent("chart.html")
        try html.write(to: chartFile, atomically: true, encoding: .utf8)
        var rendering: [String: Any] = [:]
        for pine in [false, true] {
            print("SMA WebKit scenario: \(pine ? "Pine" : "built-in")"); fflush(stdout)
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
            let slots = ["SMA", "EMA"].flatMap { type in (1...4).map { slot in
                ["name": "\(type) MA \(slot)", "type": type, "slot": slot, "period": 20,
                 "source": "close", "enabled": type == "SMA" && slot == 1] as [String: Any]
            } }
            let preferences = ["display": String(data: try JSONSerialization.data(withJSONObject: [
                "enabled": pine ? [] : ["SMA"], "volume": false, "target": false]), encoding: .utf8)!,
                "indicators": String(data: try JSONSerialization.data(withJSONObject: slots), encoding: .utf8)!]
            let prefsJSON = String(data: try JSONSerialization.data(withJSONObject: preferences), encoding: .utf8)!
            config.userContentController.addUserScript(WKUserScript(source: "window.stockDeckChartSurface='superchart';window.stockDeckPreferences=\(prefsJSON);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), configuration: config)
            let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = web; window.orderFront(nil)
            defer { window.orderOut(nil) }
            web.loadFileURL(chartFile, allowingReadAccessTo: directory)
            for _ in 0..<100 {
                if (try? await web.evaluateJavaScript("typeof window.setChartData==='function'")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            _ = try await web.evaluateJavaScript("window.benchPayload=window.decodeStockDeckJSON('\(payloadBase64)');window.benchPine=\(pine ? "window.decodeStockDeckJSON('\(pineBase64)')" : "[]");")
            var submission: [Double] = [], flushing: [Double] = []
            for index in 0..<12 {
                let output = try await web.evaluateJavaScript("""
                    (()=>{
                    const start=performance.now();
                    window.setChartData(window.benchPayload);
                    window.setCustomPineIndicators(window.benchPine);
                    const submission=performance.now()-start;
                    const flushStart=performance.now();
                    window.benchScreenshot=window.benchChart.takeScreenshot();
                    const flush=performance.now()-flushStart;
                    return {submission,flush,error:document.getElementById('error').textContent,
                      nativeVisible:!document.querySelector('[data-indicator=\"MA:SMA\"]').classList.contains('is-hidden'),
                      pineRows:document.querySelectorAll('.pine-legend').length};
                    })()
                    """) as! [String: Any]
                XCTAssertEqual(output["error"] as? String, "")
                XCTAssertEqual(output["nativeVisible"] as? Bool, !pine)
                XCTAssertEqual(output["pineRows"] as? Int, pine ? 1 : 0)
                if index >= 2 {
                    submission.append(output["submission"] as! Double); flushing.append(output["flush"] as! Double)
                }
                if index == 11 {
                    let encoded = try await web.evaluateJavaScript("window.benchScreenshot.toDataURL('image/png').split(',')[1]") as! String
                    if let png = Data(base64Encoded: encoded) {
                        let path = URL(fileURLWithPath: "/tmp/stockdeck-sma-\(pine ? "pine" : "builtin").png")
                        try await Task.detached { try png.write(to: path) }.value
                    }
                }
            }
            rendering[pine ? "pine" : "builtin"] = ["submission": summary(submission), "chartCanvasFlushAndCopy": summary(flushing)]
        }
        let report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()),
            "host": ProcessInfo.processInfo.operatingSystemVersionString, "build": "Swift Debug, bundled JavaScriptCore helper and WKWebView",
            "dataset": "Bitstamp BTCUSD daily, 5540 real candles", "sha256": hash, "period": 20, "matchedPoints": plot.points.count,
            "nativeMath": summary(nativeMs), "pineColdHelperIncludingIPCAndDecode": summary(helperMs),
            "pineContextPreparationMs": preparationMs, "pineJobEncodingMs": encodeMs, "rendering": rendering,
            "scope": "Cold helper includes startup, compilation, execution and output; rendering measures synchronous JS chart submission and separate chart.takeScreenshot() canvas flush/composition/copy, not pure GPU paint or FPS. Native timing is SMA math only. No performance assertions or extrapolation to arbitrary scripts."]
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let destination = URL(fileURLWithPath: "/tmp/stockdeck-sma-benchmark.json")
        try await Task.detached { try reportData.write(to: destination) }.value
        print("SMA benchmark report: \(destination.path)")
    }
}
