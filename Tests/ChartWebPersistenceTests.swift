import XCTest
import WebKit
@testable import StockDeck

@MainActor
final class ChartWebPersistenceTests: XCTestCase, WKScriptMessageHandler {
    private var messages: [[String: Any]] = []
    private var native: LightweightChartWebView.Coordinator?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { messages.append(body) }
        native?.userContentController(userContentController, didReceive: message)
    }

    func testRSIStyleIsPublishedAndPaneResizeIsCaptured() async throws {
        let keys = ["stockdeck.chart.preferences.superchart.v1", "stockdeck.lightweightChart.indicatorSettings.superchart.v1"]
        let originals = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { native = nil; for (key,value) in zip(keys,originals) { UserDefaults.standard.set(value, forKey: key) } }
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("StockDeck/Resources")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: resources.appendingPathComponent("LightweightCharts"), to: directory.appendingPathComponent("LightweightCharts"))
        var html = try String(contentsOf: resources.appendingPathComponent("LightweightChartTrial.html"))
        html = html.replacingOccurrences(of: "const chart=C.createChart", with: "const chart=window.testChart=C.createChart")
        html = html.replacingOccurrences(of: "const surface=window.stockDeckChartSurface==='superchart'?'superchart':'detail';",
            with: "let surface=window.stockDeckChartSurface==='superchart'?'superchart':'detail';window.testSetSurface=value=>{surface=value};")
        html = html.replacingOccurrences(of: "const onCrosshairMove=param=>{scheduleDraw();scheduleReadoutUpdate(param);};",
            with: "const onCrosshairMove=param=>{scheduleDraw();scheduleReadoutUpdate(param);};window.testCrosshair=onCrosshairMove;window.testSetReadout=updateReadout;")
        html = html.replacingOccurrences(of: "ctx.fillStyle=colorWithOpacity(style.color||'#8a78bd',style.opacity??10);",
            with: "window.testBandPaints=(window.testBandPaints||0)+1;window.testBandFirst=points.find(point=>point);ctx.fillStyle=colorWithOpacity(style.color||'#8a78bd',style.opacity??10);")
        let file = directory.appendingPathComponent("chart.html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "chart")
        config.userContentController.addUserScript(WKUserScript(source: "window.stockDeckChartSurface='superchart';window.onerror=(message)=>window.webkit.messageHandlers.chart.postMessage({type:'jsError',message:String(message)});", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        defer { config.userContentController.removeScriptMessageHandler(forName: "chart") }
        web.loadFileURL(file, allowingReadAccessTo: directory)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("typeof window.setChartData==='function'")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        // Synthetic price history is confined to this regression test.
        let points = (0..<100).map { PricePoint(date: Date(timeIntervalSince1970: 1_700_000_000 + Double($0)*86400), close: 100 + Double($0 % 13)) }
        func coordinator(for web: WKWebView) -> LightweightChartWebView.Coordinator {
            LightweightChartWebView.Coordinator(parent: LightweightChartWebView(symbol: "TEST", interval: .day, points: points, currency: "USD", visibleFrom: nil, markers: [], targetPrice: nil, showInsiderMarkers: true, selectedRange: "3M", showsRangeControls: true, availableRanges: [], onSelectRange: { _ in }, onSelectInterval: { _ in }, webView: .constant(web), state: .constant("ready")))
        }
        native = coordinator(for: web)
        let payload = LightweightChartMath.payload(points: points, interval: .day, symbol: "TEST", currency: "USD", periods: [:], showsRangeControls: true)
        let json = String(data: try JSONEncoder().encode(payload), encoding: .utf8)!
        _ = try await web.evaluateJavaScript("window.setChartData(\(json));window.testChart.applyOptions({autoSize:false});window.testChart.resize(1000,740,true);document.querySelector('[data-indicator=RSI] [data-action=settings]').click();document.querySelector('[data-style-key=rsi] .style-color').click();")
        let popoverTitle = try await web.evaluateJavaScript("document.querySelector('.style-popover-title')?.textContent") as? String
        XCTAssertEqual(popoverTitle, "RSI · RSI")
        let chartGesturesLocked = try await web.evaluateJavaScript("(()=>{const o=window.testChart.options();return !o.handleScroll.pressedMouseMove&&!o.handleScroll.horzTouchDrag&&!o.handleScale.mouseWheel&&!o.handleScale.pinch})()") as? Bool
        XCTAssertEqual(chartGesturesLocked, true, "Opening indicator settings must disable chart pan and zoom")
        let selectedWidth = try await web.evaluateJavaScript("document.querySelector('.style-popover [data-thickness=\\\"2\\\"]')?.getAttribute('aria-pressed')") as? String
        XCTAssertEqual(selectedWidth, "true")
        let selectedLine = try await web.evaluateJavaScript("document.querySelector('.style-popover [data-style=\\\"solid\\\"]')?.getAttribute('aria-pressed')") as? String
        XCTAssertEqual(selectedLine, "true")
        let rsiPaletteHasFocus = try await web.evaluateJavaScript("!!document.activeElement.closest('.style-popover')") as? Bool
        XCTAssertEqual(rsiPaletteHasFocus, true)
        let rsiPaletteHit = try await web.evaluateJavaScript("(()=>{const chip=document.querySelector('.style-popover button[title=\"#ef3340\"]'),r=chip.getBoundingClientRect();return document.elementFromPoint(r.x+r.width/2,r.y+r.height/2)===chip})()") as? Bool
        XCTAssertEqual(rsiPaletteHit, true)
        _ = try await web.evaluateJavaScript("document.querySelector('.style-popover button[title=\"#ef3340\"]').click()")
        try await Task.sleep(nanoseconds: 500_000_000)
        let errors = messages.filter { $0["type"] as? String == "jsError" }
        XCTAssertTrue(errors.isEmpty, "\(errors)")
        let changed = try XCTUnwrap(messages.last { $0["type"] as? String == "indicatorSettingsChanged" })
        let data = try JSONSerialization.data(withJSONObject: changed["settings"]!)
        let settings = try JSONDecoder().decode(LightweightIndicatorSettings.self, from: data)
        XCTAssertEqual(settings.componentStyles["rsi"]?.color, "#ef3340")
        _ = try await web.evaluateJavaScript("const length=document.querySelector('[data-key=rsiPeriod]');length.value='21';length.dispatchEvent(new Event('input',{bubbles:true}));document.getElementById('closeIndicator').click();window.testChart.panes()[1].setHeight(120);document.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));")
        let chartGesturesRestored = try await web.evaluateJavaScript("window.testChart.options().handleScale.mouseWheel===true") as? Bool
        XCTAssertEqual(chartGesturesRestored, true, "Closing indicator settings must restore chart zoom")
        try await Task.sleep(nanoseconds: 400_000_000)
        let layoutMessage = try XCTUnwrap(messages.last { $0["type"] as? String == "chartPreferenceChanged" && $0["name"] as? String == "paneLayout" })
        let layout = try XCTUnwrap(layoutMessage["value"] as? String)
        let heightResult = try await web.evaluateJavaScript("window.testChart.panes().map(p=>p.getHeight())")
        let heights = try XCTUnwrap(heightResult as? [Double])
        let ratio = heights[1] / heights.reduce(0,+)
        let storedLayout = try JSONSerialization.jsonObject(with: Data(layout.utf8)) as! [String: Double]
        XCTAssertEqual(try XCTUnwrap(storedLayout["RSI"]), ratio, accuracy: 0.02)
        let savedSettings = try XCTUnwrap(messages.last { $0["type"] as? String == "chartPreferenceChanged" && $0["name"] as? String == "indicatorSettings" }?["value"] as? String)
        let preferences = try JSONSerialization.data(withJSONObject: ["paneLayout": layout, "indicatorSettings": savedSettings])
        config.userContentController.addUserScript(WKUserScript(source: "window.stockDeckPreferences=\(String(data: preferences, encoding: .utf8)!);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        _ = try await web.evaluateJavaScript("localStorage.clear()")
        let reopened = WKWebView(frame: web.frame, configuration: config)
        window.contentView = reopened
        reopened.loadFileURL(file, allowingReadAccessTo: directory)
        for _ in 0..<100 {
            if (try? await reopened.evaluateJavaScript("typeof window.setChartData==='function'")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let committedSettings = try JSONDecoder().decode(LightweightIndicatorSettings.self, from: Data(savedSettings.utf8))
        XCTAssertEqual(committedSettings.rsiPeriod, 21)
        native = coordinator(for: reopened)
        native?.sendData(to: reopened)
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = try await reopened.evaluateJavaScript("window.testChart.applyOptions({autoSize:false});window.testChart.resize(1000,740,true)")
        let restoredResult = try await reopened.evaluateJavaScript("window.testChart.panes().map(p=>p.getHeight())")
        let restoredHeights = try XCTUnwrap(restoredResult as? [Double])
        XCTAssertEqual(restoredHeights[1]/restoredHeights.reduce(0,+), ratio, accuracy: 0.03)
        _ = try await reopened.evaluateJavaScript("document.querySelector('[data-indicator=RSI] [data-action=settings]').click()")
        let period = try await reopened.evaluateJavaScript("document.querySelector('[data-key=rsiPeriod]').value") as? String
        XCTAssertEqual(period, "21")
        let color = try await reopened.evaluateJavaScript("document.querySelector('[data-style-key=rsi] .style-color i').style.borderTopColor") as? String
        XCTAssertEqual(color, "rgb(239, 51, 64)")
        let beforeCollapse = restoredHeights
        _ = try await reopened.evaluateJavaScript("document.getElementById('closeIndicator').click();document.getElementById('collapseIndicators').click()")
        let afterCollapse = try await reopened.evaluateJavaScript("window.testChart.panes().map(p=>p.getHeight())") as? [Double]
        XCTAssertEqual(beforeCollapse, afterCollapse)
        _ = try await reopened.evaluateJavaScript("document.getElementById('collapseIndicators').click();document.querySelector('[data-ind=BB]').click();document.querySelector('[data-indicator=BB] [data-action=settings]').click();document.querySelector('[data-style-key=bbMiddle] .style-color').click();")
        let paletteHasFocus = try await reopened.evaluateJavaScript("!!document.activeElement.closest('.style-popover')") as? Bool
        XCTAssertEqual(paletteHasFocus, true, "The palette must accept real keyboard/pointer interaction inside the modal dialog")
        let paletteHit = try await reopened.evaluateJavaScript("(()=>{const chip=document.querySelector('.style-popover button[title=\"#ef3340\"]'),r=chip.getBoundingClientRect();return document.elementFromPoint(r.x+r.width/2,r.y+r.height/2)===chip})()") as? Bool
        XCTAssertEqual(paletteHit, true)
        _ = try await reopened.evaluateJavaScript("document.querySelector('.style-popover button[title=\"#ef3340\"]').click();document.getElementById('closeIndicator').click()")
        try await Task.sleep(nanoseconds: 300_000_000)
        let bbMessage = try XCTUnwrap(messages.last { $0["type"] as? String == "indicatorSettingsChanged" })
        let bbData = try JSONSerialization.data(withJSONObject: bbMessage["settings"]!)
        let bbSettings = try JSONDecoder().decode(LightweightIndicatorSettings.self, from: bbData)
        XCTAssertEqual(bbSettings.componentStyles["bbMiddle"]?.color, "#ef3340")
        // Flush native chart rendering: background WKWebViews throttle animation frames in tests.
        _ = try await reopened.evaluateJavaScript("window.testChart.takeScreenshot()!==null")

        func numericScript(_ script: String) async throws -> Double {
            let value = try await reopened.evaluateJavaScript(script)
            let errors = messages.filter { $0["type"] as? String == "jsError" }
            return try XCTUnwrap(value as? Double, "\(script): \(String(describing: value)); JS errors: \(errors)")
        }
        let paintsBeforeZoom = try await numericScript("window.testBandPaints")
        let fillTopBeforeZoom = try await numericScript("window.testBandFirst.top")
        _ = try await reopened.evaluateJavaScript("window.testChart.priceScale('right').setAutoScale(false);window.testChart.priceScale('right').setVisibleRange({from:50,to:250})")
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try await reopened.evaluateJavaScript("window.testChart.takeScreenshot()!==null")
        let paintsAfterZoom = try await numericScript("window.testBandPaints")
        let fillTopAfterZoom = try await numericScript("window.testBandFirst.top")
        XCTAssertGreaterThan(paintsAfterZoom, paintsBeforeZoom, "Price-axis zoom must repaint the band without mouse movement")
        XCTAssertNotEqual(fillTopAfterZoom, fillTopBeforeZoom, "The band must use the updated price coordinates")
        let fillXBeforeZoom = try await numericScript("window.testBandFirst.x")
        _ = try await reopened.evaluateJavaScript("window.testChart.timeScale().setVisibleLogicalRange({from:20,to:60})")
        try await Task.sleep(nanoseconds: 200_000_000)
        _ = try await reopened.evaluateJavaScript("window.testChart.takeScreenshot()!==null")
        let fillXAfterZoom = try await numericScript("window.testBandFirst.x")
        XCTAssertNotEqual(fillXAfterZoom, fillXBeforeZoom, "Time-axis zoom must repaint the band with updated coordinates")

        _ = try await reopened.evaluateJavaScript("for(const name of ['Stochastic','SAR']){const input=document.querySelector(`[data-ind=\\\"${name}\\\"]`);if(input&&!input.checked)input.click();}for(const name of ['MA:SMA','RSI','MACD','BB','Stochastic','SAR'])document.querySelector(`[data-indicator=\\\"${name}\\\"] [data-action=\\\"delete\\\"]`)?.click()")
        try await Task.sleep(nanoseconds: 300_000_000)
        let deletedDisplay = try XCTUnwrap(messages.last { $0["type"] as? String == "chartPreferenceChanged" && $0["name"] as? String == "display" }?["value"] as? String)
        let deletedDisplayObject = try JSONSerialization.jsonObject(with: Data(deletedDisplay.utf8)) as! [String: Any]
        XCTAssertEqual(Set(deletedDisplayObject["deletedIndicators"] as? [String] ?? []), Set(["SMA", "RSI", "MACD", "BB", "Stochastic", "SAR"]))
        let deletedIndicators = try XCTUnwrap(messages.last { $0["type"] as? String == "chartPreferenceChanged" && $0["name"] as? String == "indicators" }?["value"] as? String)
        let finalPreferences: [String: Any] = ["display": deletedDisplay, "indicators": deletedIndicators,
            "indicatorSettings": savedSettings, "paneLayout": layout]
        let finalPreferencesJSON = String(data: try JSONSerialization.data(withJSONObject: finalPreferences), encoding: .utf8)!
        config.userContentController.addUserScript(WKUserScript(source: "window.stockDeckPreferences=\(finalPreferencesJSON);",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let finalReload = WKWebView(frame: web.frame, configuration: config)
        window.contentView = finalReload
        finalReload.loadFileURL(file, allowingReadAccessTo: directory)
        for _ in 0..<100 {
            if (try? await finalReload.evaluateJavaScript("typeof window.setChartData==='function'")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        native = coordinator(for: finalReload)
        native?.sendData(to: finalReload)
        try await Task.sleep(nanoseconds: 400_000_000)
        let deletedRowsRestored = try await finalReload.evaluateJavaScript("['MA:SMA','RSI','MACD','BB','Stochastic','SAR'].every(name=>!document.querySelector(`[data-indicator=\\\"${name}\\\"]`))") as? Bool
        XCTAssertEqual(deletedRowsRestored, true, "Deleted indicators must remain removed after reopening the chart")
        _ = try await finalReload.evaluateJavaScript("document.querySelector('[data-ind=RSI]').click()")
        let restoredAfterExplicitAdd = try await finalReload.evaluateJavaScript("!!document.querySelector('[data-indicator=RSI]')") as? Bool
        XCTAssertEqual(restoredAfterExplicitAdd, true, "Explicitly enabling an indicator must clear its deleted state")

        try await Task.sleep(nanoseconds: 300_000_000)
        _ = try await finalReload.evaluateJavaScript("document.querySelector('[data-favorite-interval=\"6h\"]').click()")
        let quickInterval = try await finalReload.evaluateJavaScript("!!document.querySelector('#intervalFavorites [data-interval=\"6h\"]')") as? Bool
        XCTAssertEqual(quickInterval, true, "A favorite must be selectable directly on the toolbar")
        let favorites = try XCTUnwrap(UserDefaults.standard.dictionary(forKey: keys[0])?["timeframes"] as? String)
        XCTAssertTrue(favorites.contains("6h"), "Favorites must reach native preferences, not just localStorage")

        _ = try await finalReload.evaluateJavaScript("document.getElementById('customRangeButton').click();document.getElementById('customFrom').value='2023-12-01';document.getElementById('customTo').value='2023-12-15';document.getElementById('customRangeForm').dispatchEvent(new Event('submit',{cancelable:true}));")
        let custom = try XCTUnwrap(messages.last { $0["type"] as? String == "selectCustomRange" })
        XCTAssertEqual(custom["from"] as? String, "2023-12-01")
        XCTAssertEqual(custom["to"] as? String, "2023-12-15")
        let customClosed = try await finalReload.evaluateJavaScript("!document.getElementById('customRangeDialog').open&&window.testChart.options().handleScale.mouseWheel") as? Bool
        XCTAssertEqual(customClosed, true)

        let bounded = LightweightChartMath.payload(points: points, interval: .day, symbol: "TEST", currency: "USD",
            periods: [:], visibleFrom: points[20].date, selectedRange: "Custom", showsRangeControls: true,
            visibleTo: points[40].date)
        let boundedJSON = String(data: try JSONEncoder().encode(bounded), encoding: .utf8)!
        _ = try await finalReload.evaluateJavaScript("window.setChartData(\(boundedJSON));window.resetChartView();window.testChart.takeScreenshot()!==null")
        try await Task.sleep(nanoseconds: 200_000_000)
        let logicalBounds = try await finalReload.evaluateJavaScript("window.testChart.takeScreenshot();window.testChart.timeScale().getVisibleLogicalRange()") as? [String: Double]
        XCTAssertGreaterThan(try XCTUnwrap(logicalBounds?["from"]), 15)
        XCTAssertLessThan(try XCTUnwrap(logicalBounds?["to"]), 45, "Custom range must stop at the chosen end date")

        // Intraday candles must keep numeric timestamps through drawing, indicators and a return to daily data.
        let hourlyPoints = (0..<200).map { PricePoint(date: Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 300), close: Double(100 + $0 % 15)) }
        let hourlyPayload = LightweightChartMath.payload(points: hourlyPoints, interval: .fiveMinutes,
            symbol: "BTC-USD", currency: "USD", periods: [:], showsRangeControls: true)
        let hourlyJSON = String(data: try JSONEncoder().encode(hourlyPayload), encoding: .utf8)!
        _ = try await finalReload.evaluateJavaScript("window.setChartData(\(hourlyJSON));window.testChart.takeScreenshot()!==null")
        let showsTime = try await finalReload.evaluateJavaScript("window.testChart.options().timeScale.timeVisible") as? Bool
        XCTAssertEqual(showsTime, true)
        _ = try await finalReload.evaluateJavaScript("window.setChartData(\(json));window.testChart.takeScreenshot()!==null")
        let showsDates = try await finalReload.evaluateJavaScript("!window.testChart.options().timeScale.timeVisible") as? Bool
        XCTAssertEqual(showsDates, true)
        XCTAssertTrue(messages.filter { $0["type"] as? String == "jsError" }.isEmpty)

        let storedPreferences = UserDefaults.standard.dictionary(forKey: keys[0]) ?? [:]
        let storedJSON = String(data: try JSONSerialization.data(withJSONObject: storedPreferences), encoding: .utf8)!
        config.userContentController.addUserScript(WKUserScript(source: "window.stockDeckPreferences=\(storedJSON);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        native = nil
        let favoritesReload = WKWebView(frame: web.frame, configuration: config)
        window.contentView = favoritesReload
        favoritesReload.loadFileURL(file, allowingReadAccessTo: directory)
        for _ in 0..<100 {
            if (try? await favoritesReload.evaluateJavaScript("typeof window.setChartData==='function'")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let favoriteRestored = try await favoritesReload.evaluateJavaScript("window.setChartData(\(json));!!document.querySelector('#intervalFavorites [data-interval=\"6h\"]')") as? Bool
        XCTAssertEqual(favoriteRestored, true, "Native favorites must restore when the web chart is reopened")

        let candlePoints = (0..<100).map { index in
            let close = 100 + Double(index % 13)
            return PricePoint(date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)*86400),
                close: close, open: close - 0.5, high: close + 1, low: close - 1, volume: 500 + Double(index))
        }
        let candlePayload = LightweightChartMath.payload(points: candlePoints, interval: .day, symbol: "TEST",
            currency: "USD", periods: [:], showsRangeControls: true)
        let candleJSON = String(data: try JSONEncoder().encode(candlePayload), encoding: .utf8)!
        _ = try await favoritesReload.evaluateJavaScript("window.setChartData(\(candleJSON));document.getElementById('lineType').click();")
        let lineSelected = try await favoritesReload.evaluateJavaScript("document.getElementById('lineType').textContent.startsWith('✓')") as? Bool
        XCTAssertEqual(lineSelected, true)
        _ = try await favoritesReload.evaluateJavaScript("document.getElementById('candleType').click()")
        let candleSelected = try await favoritesReload.evaluateJavaScript("document.getElementById('candleType').textContent.startsWith('✓')") as? Bool
        XCTAssertEqual(candleSelected, true, "Daily bars with valid OHLC must allow candle selection")

        let latestRSI = try await favoritesReload.evaluateJavaScript("document.querySelector('#indicatorLegend [data-legend-key=RSI]')?.textContent") as? String
        let hoveredTime = String(data: try JSONEncoder().encode(candlePayload.bars[40].time), encoding: .utf8)!
        _ = try await favoritesReload.evaluateJavaScript("window.testSetReadout(\(hoveredTime))")
        let hoverClose = try await favoritesReload.evaluateJavaScript("document.querySelector('#candleReadout [data-field=close] i')?.textContent") as? String
        XCTAssertEqual(hoverClose, "\(Int(candlePoints[40].close))")
        let hoverFields = try await favoritesReload.evaluateJavaScript("Object.fromEntries([...document.querySelectorAll('#candleReadout [data-field]')].map(node=>[node.dataset.field,node.querySelector('i').textContent]))") as? [String: String]
        XCTAssertEqual(hoverFields?["change"], "+1")
        XCTAssertEqual(hoverFields?["changePercent"], "+1.00%")
        XCTAssertEqual(hoverFields?["volume"], "540")
        let hoveredRSI = try await favoritesReload.evaluateJavaScript("document.querySelector('#indicatorLegend [data-legend-key=RSI]')?.textContent") as? String
        XCTAssertNotEqual(hoveredRSI, latestRSI, "Indicator legend should show the hovered candle's value")
        _ = try await favoritesReload.evaluateJavaScript("window.testSetReadout(null)")
        let restoredRSI = try await favoritesReload.evaluateJavaScript("document.querySelector('#indicatorLegend [data-legend-key=RSI]')?.textContent") as? String
        XCTAssertEqual(restoredRSI, latestRSI, "Leaving the chart should restore latest indicator values")

        let closeOnlyPayload = LightweightChartMath.payload(points: points, interval: .day, symbol: "TEST",
            currency: "USD", periods: [:], showsRangeControls: true)
        let closeOnlyJSON = String(data: try JSONEncoder().encode(closeOnlyPayload), encoding: .utf8)!
        _ = try await favoritesReload.evaluateJavaScript("window.setChartData(\(closeOnlyJSON))")
        let candlesDisabled = try await favoritesReload.evaluateJavaScript("document.getElementById('candleType').disabled") as? Bool
        XCTAssertEqual(candlesDisabled, true, "Close-only sources should not offer fabricated candles")
        let detailPayload = LightweightChartMath.payload(points: candlePoints, interval: .day, symbol: "TEST", currency: "USD", periods: [:])
        let detailJSON = String(data: try JSONEncoder().encode(detailPayload), encoding: .utf8)!
        _ = try await favoritesReload.evaluateJavaScript("window.testSetSurface('detail');window.setChartData(\(detailJSON))")
        let detailRenderError = try await favoritesReload.evaluateJavaScript("document.getElementById('error').textContent") as? String
        XCTAssertTrue(detailRenderError?.isEmpty ?? true, "The table detail chart should render indicators without JavaScript errors: \(detailRenderError ?? "")")
        let detailReadoutVisible = try await favoritesReload.evaluateJavaScript("!document.getElementById('candleReadout').hidden") as? Bool
        XCTAssertEqual(detailReadoutVisible, true, "The table detail chart should show the candle information row")
        let detailCandlesEnabled = try await favoritesReload.evaluateJavaScript("!document.getElementById('candleType').disabled") as? Bool
        XCTAssertEqual(detailCandlesEnabled, true, "The table detail chart should allow candles for valid daily OHLC data")
        let detailToolbarUsesIcons = try await favoritesReload.evaluateJavaScript("document.getElementById('chartTypeLabel').classList.contains('icon-only')&&document.getElementById('indicatorLabel').classList.contains('icon-only')") as? Bool
        XCTAssertEqual(detailToolbarUsesIcons, true, "The table detail chart should use the shared icon toolbar")
        let detailLatestRSI = try await favoritesReload.evaluateJavaScript("document.querySelector('#indicatorLegend [data-legend-key=RSI]')?.textContent") as? String
        let detailHoveredTime = String(data: try JSONEncoder().encode(detailPayload.bars[40].time), encoding: .utf8)!
        _ = try await favoritesReload.evaluateJavaScript("window.testSetReadout(\(detailHoveredTime))")
        let detailHoverClose = try await favoritesReload.evaluateJavaScript("document.querySelector('#candleReadout [data-field=close] i')?.textContent") as? String
        XCTAssertEqual(detailHoverClose, "\(Int(candlePoints[40].close))")
        let detailHoveredRSI = try await favoritesReload.evaluateJavaScript("document.querySelector('#indicatorLegend [data-legend-key=RSI]')?.textContent") as? String
        XCTAssertNotEqual(detailHoveredRSI, detailLatestRSI, "The table detail RSI value should follow the hovered candle")
        _ = try await favoritesReload.evaluateJavaScript("window.testSetReadout(null)")
        let detailRestoredRSI = try await favoritesReload.evaluateJavaScript("document.querySelector('#indicatorLegend [data-legend-key=RSI]')?.textContent") as? String
        XCTAssertEqual(detailRestoredRSI, detailLatestRSI, "Leaving the detail chart should restore the latest RSI value")

        let sharedChartPayload = LightweightChartMath.payload(points: candlePoints, interval: .day, symbol: "TEST",
            currency: "USD", periods: [:], selectedRange: "3M", showsRangeControls: true,
            availableRanges: ["1D", "5D", "1M", "3M", "6M", "YTD", "1Y", "3Y", "5Y", "7Y", "10Y", "All"])
        let sharedChartJSON = String(data: try JSONEncoder().encode(sharedChartPayload), encoding: .utf8)!
        _ = try await favoritesReload.evaluateJavaScript("window.testSetSurface('superchart');window.setChartData(\(sharedChartJSON))")
        let sharedRangeVisible = try await favoritesReload.evaluateJavaScript("!document.getElementById('rangeBar').hidden&&document.querySelectorAll('#rangePresets [data-range]').length===9") as? Bool
        XCTAssertEqual(sharedRangeVisible, true, "The table chart should expose Superchart's range picker")
        let sharedToolbarIcons = try await favoritesReload.evaluateJavaScript("['chartTypeLabel','indicatorLabel','displayLabel','resetView'].every(id=>document.getElementById(id).classList.contains('icon-only'))") as? Bool
        XCTAssertEqual(sharedToolbarIcons, true, "The table chart should use Superchart's icon toolbar")
    }
}
