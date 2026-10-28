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
        try FileManager.default.copyItem(at: resources.appendingPathComponent("CustomPineChart.js"), to: directory.appendingPathComponent("CustomPineChart.js"))
        var html = try String(contentsOf: resources.appendingPathComponent("LightweightChartTrial.html"))
        html = html.replacingOccurrences(of: "const chart=C.createChart", with: "const chart=window.testChart=C.createChart")
        html = html.replacingOccurrences(of: "const pineRenderer=new StockDeckPineChart(chart,C,candles,{dark});",
            with: "const pineRenderer=window.testPineRenderer=new StockDeckPineChart(chart,C,candles,{dark});")
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
        let compactSettings = try await web.evaluateJavaScript("(()=>{const d=document.getElementById('indicatorDialog'),r=d.getBoundingClientRect(),f=document.getElementById('indicatorFields'),a=d.querySelector('.dialog-actions').getBoundingClientRect();return r.width<=482&&r.height<=402&&f.scrollWidth<=f.clientWidth+1&&a.bottom<=r.bottom&&a.top>=r.top})()") as? Bool
        XCTAssertEqual(compactSettings, true, "Indicator settings must fit a compact dialog with reachable actions and no horizontal overflow")
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
        _ = try await web.evaluateJavaScript("const length=document.querySelector('[data-key=rsiPeriod]');length.value='21';length.dispatchEvent(new Event('input',{bubbles:true}));document.getElementById('closeIndicator').click();window.testChart.panes()[1].setHeight(120);window.testChart.takeScreenshot();document.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));")
        let chartGesturesRestored = try await web.evaluateJavaScript("window.testChart.options().handleScale.mouseWheel===true") as? Bool
        XCTAssertEqual(chartGesturesRestored, true, "Closing indicator settings must restore chart zoom")
        try await Task.sleep(nanoseconds: 400_000_000)
        _ = try await web.evaluateJavaScript("window.testChart.takeScreenshot()!==null")
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
        let sharedToolbarIcons = try await favoritesReload.evaluateJavaScript("['chartTypeLabel','indicatorLabel','pineScriptsLabel','displayLabel','resetView'].every(id=>document.getElementById(id).classList.contains('icon-only'))&&!!document.querySelector('#pineScriptsLabel svg')&&document.getElementById('pineScriptsLabel').getAttribute('aria-label')==='Scripts'") as? Bool
        XCTAssertEqual(sharedToolbarIcons, true, "The table chart should use Superchart's icon toolbar")

        let installedID = UUID(), attachedID = UUID()
        var routedAttachments: [UUID] = [], routedRemovals: [UUID] = [], managementOpens = 0
        native = coordinator(for: favoritesReload)
        native?.parent.onCustomPineAction = { id, action in
            if action == "attach" { routedAttachments.append(id) }
            if action == "remove" { routedRemovals.append(id) }
        }
        native?.parent.onManagePineScripts = { managementOpens += 1 }
        func publishMenu(_ items: [PineScriptMenuItem]) async throws {
            let encoded = try JSONEncoder().encode(items).base64EncodedString()
            _ = try await favoritesReload.evaluateJavaScript("window.setPineScriptsMenu(window.decodeStockDeckJSON('\(encoded)'))")
        }
        try await publishMenu([
            PineScriptMenuItem(id: installedID, name: "Đường SMA <20>", attached: false),
            PineScriptMenuItem(id: attachedID, name: "DCA", attached: true)
        ])
        let toolbarMenu = try await favoritesReload.evaluateJavaScript("!document.getElementById('pineScriptsMenu').hidden&&document.getElementById('pineScriptsMenu').previousElementSibling.id==='indicatorMenu'") as? Bool
        XCTAssertEqual(toolbarMenu, true, "Scripts belongs next to Indicators on the chart toolbar")
        let activeMenuItem = try await favoritesReload.evaluateJavaScript("(()=>{const b=document.querySelector('[data-pine-script-id=\"\(attachedID.uuidString)\"]');return !b.disabled&&b.textContent==='DCA'&&b.title==='Thêm DCA vào chart'})()") as? Bool
        XCTAssertEqual(activeMenuItem, true)
        let attachedBefore = messages.filter { $0["action"] as? String == "attach" }.count
        _ = try await favoritesReload.evaluateJavaScript("document.getElementById('pineScriptsMenu').open=true;const b=document.querySelector('[data-pine-script-id=\"\(installedID.uuidString)\"]');b.click();b.click();document.querySelector('[data-pine-manage]').click()")
        try await Task.sleep(for: .milliseconds(30))
        let attachMessages = messages.filter { $0["action"] as? String == "attach" }
        XCTAssertEqual(attachMessages.count, attachedBefore + 1, "Double clicks must not attach twice")
        XCTAssertEqual(attachMessages.last?["id"] as? String, installedID.uuidString)
        XCTAssertEqual(messages.last?["type"] as? String, "managePineScripts")
        XCTAssertEqual(routedAttachments, [installedID], "The native bridge must route menu selection to the workspace")
        XCTAssertEqual(managementOpens, 1)
        _ = try await favoritesReload.evaluateJavaScript("document.querySelector('[data-pine-script-id=\"\(attachedID.uuidString)\"]').click()")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(routedAttachments, [installedID, attachedID], "Selecting an indicator from the menu must always attach")
        native = nil
        try await publishMenu([PineScriptMenuItem(id: installedID, name: "Tên mới", attached: true)])
        let renamedMenu = try await favoritesReload.evaluateJavaScript("document.querySelectorAll('[data-pine-script-id]').length===1&&document.querySelector('[data-pine-script-id]').textContent==='Tên mới'") as? Bool
        XCTAssertEqual(renamedMenu, true, "Renames and library deletion must refresh the menu")
        try await publishMenu([])
        let emptyMenu = try await favoritesReload.evaluateJavaScript("document.getElementById('pineScriptsOptions').textContent.includes('Chưa có script')&&!!document.querySelector('[data-pine-manage]')") as? Bool
        XCTAssertEqual(emptyMenu, true)
        _ = try await favoritesReload.evaluateJavaScript("window.testSetSurface('detail');window.setChartData(\(sharedChartJSON))")
        let detailMenuHidden = try await favoritesReload.evaluateJavaScript("document.getElementById('pineScriptsMenu').hidden") as? Bool
        XCTAssertEqual(detailMenuHidden, true)
        _ = try await favoritesReload.evaluateJavaScript("window.testSetSurface('superchart');window.setChartData(\(sharedChartJSON))")

        // Pine integration uses explicit synthetic OHLC from this test only.
        let pineTime = candlePoints[40].date.timeIntervalSince1970 * 1000
        let pinePoint = CustomPinePlot.Point(time: pineTime, value: 105, color: "#FF9900", shape: true,
                                           state: true, position: "belowbar", markerShape: "triangleup")
        let pinePlot = CustomPinePlot(style: "line", title: "Đường EMA200", color: "#FF9900", points: [pinePoint], plotID: "shared")
        let map = [String(Int(pineTime / 1000)): sharedChartPayload.bars[40].time]
        let pineIDs = [UUID(), UUID(), UUID()]
        let pineIndicators = pineIDs.enumerated().map { index, id in
            CustomPineIndicator(id: id, title: "DCA \(index) · Đường EMA200", overlay: index == 0,
                status: "loaded", error: nil,
                plots: [pinePlot, CustomPinePlot(style: "line", title: "Risk without history", color: "#16816d", points: [])],
                timeMap: map, symbol: "TEST", interval: "1D")
        }
        let initialPaneCount = try await favoritesReload.evaluateJavaScript("window.testChart.panes().length") as? Int
        let paneCountBeforePine = try XCTUnwrap(initialPaneCount)
        let pineJSON = try JSONEncoder().encode(pineIndicators).base64EncodedString()
        _ = try await favoritesReload.evaluateJavaScript("window.setCustomPineIndicators(window.decodeStockDeckJSON('\(pineJSON)'))")
        let pineLegendCount = try await favoritesReload.evaluateJavaScript("document.querySelectorAll('.pine-legend').length") as? Int
        XCTAssertEqual(pineLegendCount, 3, "One row per script, even with matching plot names")
        let pinePaneCount = try await favoritesReload.evaluateJavaScript("window.testChart.panes().length") as? Int
        XCTAssertEqual(pinePaneCount, paneCountBeforePine + 2)
        _ = try await favoritesReload.evaluateJavaScript("window.testChart.takeScreenshot()!==null")
        let compactPinePanes = try await favoritesReload.evaluateJavaScript("(()=>{const panes=window.testChart.panes(),height=panes.reduce((n,p)=>n+p.getHeight(),0);return [...window.testPineRenderer.records.values()].every(record=>!record.anchor||(record.anchor.getPane().getHeight()<=height*0.2+2&&record.anchor.getPane().getHeight()<=panes[0].getHeight()/4+2))})()") as? Bool
        XCTAssertEqual(compactPinePanes, true, "Custom scripts must use at most one compact indicator slot, not the default full-size pane")
        _ = try await favoritesReload.evaluateJavaScript("window.testPineRenderer.records.get('\(pineIDs[2].uuidString)').anchor.getPane().setStretchFactor(20);document.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}))")
        for _ in 0..<30 {
            if messages.contains(where: { $0["name"] as? String == "paneLayout" && ($0["value"] as? String)?.contains("Pine:\(pineIDs[2].uuidString)") == true }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let boundedPaneLayout = try XCTUnwrap(messages.last { $0["type"] as? String == "chartPreferenceChanged" && $0["name"] as? String == "paneLayout" }?["value"] as? String)
        let boundedRatios = try JSONSerialization.jsonObject(with: Data(boundedPaneLayout.utf8)) as! [String: Double]
        XCTAssertLessThanOrEqual(try XCTUnwrap(boundedRatios["Pine:\(pineIDs[2].uuidString)"]), 0.202)
        _ = try await favoritesReload.evaluateJavaScript("window.testChart.resize(1000,500,true);window.testChart.takeScreenshot()!==null")
        let compactAfterResize = try await favoritesReload.evaluateJavaScript("(()=>{const panes=window.testChart.panes(),h=panes.reduce((sum,p)=>sum+p.getHeight(),0);return [...window.testPineRenderer.records.values()].every(r=>!r.anchor||r.anchor.getPane().getHeight()<=h*0.2+2)})()") as? Bool
        XCTAssertEqual(compactAfterResize, true, "Resizing must preserve compact pane proportions")
        _ = try await favoritesReload.evaluateJavaScript("const focus=document.getElementById('focusPane');focus.value=String(window.testPineRenderer.records.get('\(pineIDs[2].uuidString)').anchor.getPane().paneIndex());focus.dispatchEvent(new Event('change'));window.setCustomPineIndicators(window.decodeStockDeckJSON('\(pineJSON)'));window.testChart.takeScreenshot()!==null")
        let explicitFocus = try await favoritesReload.evaluateJavaScript("window.testPineRenderer.records.get('\(pineIDs[2].uuidString)').anchor.getPane().getStretchFactor()===20") as? Bool
        XCTAssertEqual(explicitFocus, true, "An explicit pane-focus action must remain usable across updates")
        _ = try await favoritesReload.evaluateJavaScript("document.getElementById('restorePanes').click();window.testChart.resize(1000,740,true);window.testChart.takeScreenshot()!==null")
        let compactAfterRestore = try await favoritesReload.evaluateJavaScript("(()=>{const panes=window.testChart.panes(),h=panes.reduce((sum,p)=>sum+p.getHeight(),0);return window.testPineRenderer.records.get('\(pineIDs[2].uuidString)').anchor.getPane().getHeight()<=h*0.2+2})()") as? Bool
        XCTAssertEqual(compactAfterRestore, true, "Restoring the full chart must restore the compact limit")
        let pineUnicode = try await favoritesReload.evaluateJavaScript("document.querySelector('.pine-legend .legend-name').textContent") as? String
        XCTAssertEqual(pineUnicode, pineIndicators[0].title, "UTF-8 must survive the native bridge")
        let missingRiskValue = try await favoritesReload.evaluateJavaScript("document.querySelector('.pine-legend .legend-value[title^=\"Risk without history:\"]')?.textContent") as? String
        XCTAssertEqual(missingRiskValue, "—", "An empty plot must remain visible as missing data, never disappear or become zero")
        // Test pine-toggle on legend
        _ = try await favoritesReload.evaluateJavaScript("document.querySelector('.pine-legend [data-action=pine-toggle]').click()")
        let pineIsHidden = try await favoritesReload.evaluateJavaScript("document.querySelector('.pine-legend').classList.contains('is-hidden')") as? Bool
        XCTAssertEqual(pineIsHidden, true, "Pine legend must be marked is-hidden when toggled off")

        let pineHasEyeSlash = try await favoritesReload.evaluateJavaScript("document.querySelector('.pine-legend [data-action=pine-toggle]').innerHTML.includes('M9.88')") as? Bool
        XCTAssertEqual(pineHasEyeSlash, true, "Pine legend toggle button must show eyeSlash icon when hidden")

        _ = try await favoritesReload.evaluateJavaScript("document.querySelector('.pine-legend [data-action=pine-toggle]').click()")
        let pineRestored = try await favoritesReload.evaluateJavaScript("!document.querySelector('.pine-legend').classList.contains('is-hidden')") as? Bool
        XCTAssertEqual(pineRestored, true, "Pine legend must restore normal visibility when toggled on")

        _ = try await favoritesReload.evaluateJavaScript("document.querySelector('.pine-legend [data-action=pine-settings]').click();document.querySelector('.pine-legend [data-action=pine-remove]').click()")
        try await Task.sleep(for: .milliseconds(30))
        let lastPineAction = messages.last { $0["type"] as? String == "customPineAction" }
        XCTAssertEqual(lastPineAction?["type"] as? String, "customPineAction")
        XCTAssertEqual(lastPineAction?["id"] as? String, pineIDs[0].uuidString)
        XCTAssertEqual(lastPineAction?["action"] as? String, "remove")
        let remaining = try JSONEncoder().encode([pineIndicators[2]]).base64EncodedString()
        _ = try await favoritesReload.evaluateJavaScript("window.setCustomPineIndicators(window.decodeStockDeckJSON('\(remaining)'))")
        let panesAfterRemoval = try await favoritesReload.evaluateJavaScript("window.testChart.panes().length") as? Int
        XCTAssertEqual(panesAfterRemoval, paneCountBeforePine + 1)

        // Synthetic Risk-like values isolate source-white visibility from the red threshold.
        let riskTimes = [40, 41].map { candlePoints[$0].date.timeIntervalSince1970 * 1000 }
        let riskPoints = riskTimes.enumerated().map { index, time in
            CustomPinePlot.Point(time: time, value: index == 0 ? 0.93 : 0.97, color: "#FFFFFF",
                shape: nil, state: nil, position: nil, markerShape: nil)
        }
        let riskPlot = CustomPinePlot(style: "line", title: "Risk", color: "#FFFFFF", points: riskPoints, plotID: "risk")
        let thresholdPoints = riskTimes.map { CustomPinePlot.Point(time: $0, value: 0.8, color: "#FF0000",
            shape: nil, state: nil, position: nil, markerShape: nil) }
        let threshold = CustomPinePlot(style: "line", title: "Sell Limit", color: "#FF0000", points: thresholdPoints, plotID: "sell")
        let riskMap = Dictionary(uniqueKeysWithValues: [40, 41].map { (String(Int(candlePoints[$0].date.timeIntervalSince1970)), sharedChartPayload.bars[$0].time) })
        let riskIndicator = CustomPineIndicator(id: pineIDs[2], title: "Risk contrast", overlay: false, status: "loaded", error: nil,
            plots: [riskPlot, threshold], timeMap: riskMap, symbol: "TEST", interval: "1D")
        let riskJSON = try JSONEncoder().encode([riskIndicator]).base64EncodedString()
        _ = try await favoritesReload.evaluateJavaScript("window.testPineRenderer.setDarkMode(false);window.setCustomPineIndicators(window.decodeStockDeckJSON('\(riskJSON)'));window.testChart.timeScale().setVisibleLogicalRange({from:38,to:43});window.testChart.takeScreenshot()!==null")
        let visibleRisk = try await favoritesReload.evaluateJavaScript("(()=>{const s=window.testPineRenderer.records.get('\(pineIDs[2].uuidString)').series.get('risk');return s.options().color==='#475569'&&s.data().length===2&&s.data()[1].value===0.97&&s.data()[1].color==='#475569'})()") as? Bool
        XCTAssertEqual(visibleRisk, true, "The Risk series must be distinct from the red 0.8 threshold on a light chart")
        let riskLegendColor = try await favoritesReload.evaluateJavaScript("document.querySelector('.pine-legend .legend-value[title=Risk]').style.color") as? String
        XCTAssertEqual(riskLegendColor, "rgb(71, 85, 105)")
        let paintedRisk = try await favoritesReload.evaluateJavaScript("(()=>{const c=window.testChart.takeScreenshot(),p=c.getContext('2d').getImageData(0,0,c.width,c.height).data;for(let i=0;i<p.length;i+=4)if(p[i]===71&&p[i+1]===85&&p[i+2]===105&&p[i+3]>0)return true;return false})()") as? Bool
        XCTAssertEqual(paintedRisk, true, "The visible Risk color must reach the actual canvas")
        _ = try await favoritesReload.evaluateJavaScript("window.testPineRenderer.setDarkMode(true);window.setCustomPineIndicators(window.decodeStockDeckJSON('\(riskJSON)'))")
        let darkRisk = try await favoritesReload.evaluateJavaScript("window.testPineRenderer.records.get('\(pineIDs[2].uuidString)').series.get('risk').data()[1].color") as? String
        XCTAssertEqual(darkRisk, "#FFFFFF")
        _ = try await favoritesReload.evaluateJavaScript("window.clearChartData()")
        let panesAfterClear = try await favoritesReload.evaluateJavaScript("window.testChart.panes().length") as? Int
        XCTAssertEqual(panesAfterClear, paneCountBeforePine)
        XCTAssertTrue(messages.filter { $0["type"] as? String == "jsError" }.isEmpty)
    }

    func testRSIPaneLayoutPersistenceAcrossColdStartAndSurfaces() async throws {
        let keys = ["stockdeck.chart.preferences.superchart.v1", "stockdeck.chart.preferences.detail.v1"]
        let originals = keys.map { UserDefaults.standard.object(forKey: $0) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { native = nil; for (key, value) in zip(keys, originals) { UserDefaults.standard.set(value, forKey: key) } }

        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("StockDeck/Resources")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.copyItem(at: resources.appendingPathComponent("LightweightCharts"), to: directory.appendingPathComponent("LightweightCharts"))
        try FileManager.default.copyItem(at: resources.appendingPathComponent("CustomPineChart.js"), to: directory.appendingPathComponent("CustomPineChart.js"))

        var html = try String(contentsOf: resources.appendingPathComponent("LightweightChartTrial.html"))
        html = html.replacingOccurrences(of: "const chart=C.createChart", with: "const chart=window.testChart=C.createChart")
        html = html.replacingOccurrences(of: "const pineRenderer=new StockDeckPineChart(chart,C,candles,{dark});",
            with: "const pineRenderer=window.testPineRenderer=new StockDeckPineChart(chart,C,candles,{dark});")
        html = html.replacingOccurrences(of: "const surface=window.stockDeckChartSurface==='superchart'?'superchart':'detail';",
            with: "let surface=window.stockDeckChartSurface==='superchart'?'superchart':'detail';window.testSetSurface=value=>{surface=value};")
        html = html.replacingOccurrences(of: "window.__getCoords=d=>coords(d);",
            with: "window.__getCoords=d=>coords(d);window.testRsi=()=>rsi;window.testCandles=()=>candles;window.testPaneScales=()=>paneScales;window.testViewports=()=>viewports;")

        let file = directory.appendingPathComponent("chart.html")
        try html.write(to: file, atomically: true, encoding: .utf8)

        // 1. Test cold start with a saved paneLayout (Price: 0.60, RSI: 0.25, MACD: 0.15) and saved paneScales
        let customLayout = "{\"Price\":0.6,\"RSI\":0.25,\"MACD\":0.15}"
        let customScales = "{\"RSI\":{\"from\":15,\"to\":85}}"
        let preferencesData = try JSONSerialization.data(withJSONObject: ["paneLayout": customLayout, "paneScales": customScales])

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "chart")
        config.userContentController.addUserScript(WKUserScript(
            source: "window.stockDeckPreferences=\(String(data: preferencesData, encoding: .utf8)!);window.stockDeckChartSurface='superchart';window.onerror=(message)=>window.webkit.messageHandlers.chart.postMessage({type:'jsError',message:String(message)});",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1000, height: 740), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web
        window.orderFront(nil)
        defer { window.orderOut(nil); config.userContentController.removeScriptMessageHandler(forName: "chart") }

        func coordinator(for web: WKWebView) -> LightweightChartWebView.Coordinator {
            LightweightChartWebView.Coordinator(parent: LightweightChartWebView(symbol: "TEST", interval: .day, points: points, currency: "USD", visibleFrom: nil, markers: [], targetPrice: nil, showInsiderMarkers: true, selectedRange: "3M", showsRangeControls: true, availableRanges: [], onSelectRange: { _ in }, onSelectInterval: { _ in }, webView: .constant(web), state: .constant("ready")))
        }

        web.loadFileURL(file, allowingReadAccessTo: directory)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("typeof window.setChartData==='function'")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // Simulate app cold launch: first empty points (hasOHLC = false), then points arrive (hasOHLC = true)
        let emptyPayload = LightweightChartMath.payload(points: [], interval: .day, symbol: "TEST", currency: "USD", periods: [:], showsRangeControls: true)
        let emptyJSON = String(data: try JSONEncoder().encode(emptyPayload), encoding: .utf8)!
        _ = try await web.evaluateJavaScript("window.setChartData(\(emptyJSON))")
        try await Task.sleep(nanoseconds: 100_000_000)

        var points: [PricePoint] = []
        for i in 0..<100 {
            let baseDate = Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 86400)
            let offset = Double(i % 13)
            points.append(PricePoint(date: baseDate, close: 105 + offset, open: 100 + offset, high: 115 + offset, low: 95 + offset))
        }
        native = coordinator(for: web)
        let fullPayload = LightweightChartMath.payload(points: points, interval: .day, symbol: "TEST", currency: "USD", periods: [:], showsRangeControls: true)
        let fullJSON = String(data: try JSONEncoder().encode(fullPayload), encoding: .utf8)!
        _ = try await web.evaluateJavaScript("window.setChartData(\(fullJSON))")
        try await Task.sleep(nanoseconds: 300_000_000)

        // Force a layout pass and verify restored ratio
        _ = try await web.evaluateJavaScript("window.testChart.takeScreenshot()!==null")
        let rawHeights = try await web.evaluateJavaScript("window.testChart.panes().map(p=>p.getHeight())") as? [Double]
        let heights = try XCTUnwrap(rawHeights)
        let total = heights.reduce(0, +)
        let rsiRatio = heights[1] / total
        XCTAssertEqual(rsiRatio, 0.25, accuracy: 0.03, "RSI pane proportion must be preserved across cold start without being clamped to 48px")

        _ = try await web.evaluateJavaScript("""
        (()=>{
            const seps = Array.from(document.querySelectorAll('div')).filter(d=>d.style.cursor==='row-resize' && d.offsetHeight > 0);
            const sep = seps[0];
            const r = sep.getBoundingClientRect();
            sep.dispatchEvent(new MouseEvent('mousedown', {bubbles: true, cancelable: true, clientX: r.x + 50, clientY: r.y + 4, pageY: r.y + 4, button: 0}));
            document.documentElement.dispatchEvent(new MouseEvent('mousemove', {bubbles: true, cancelable: true, clientX: r.x + 50, clientY: r.y + 104, pageY: r.y + 104, button: 0}));
            document.documentElement.dispatchEvent(new MouseEvent('mouseup', {bubbles: true, cancelable: true, clientX: r.x + 50, clientY: r.y + 104, pageY: r.y + 104, button: 0}));
        })()
        """)
        try await Task.sleep(nanoseconds: 300_000_000)
        let lastLayoutMsg = messages.last { $0["type"] as? String == "chartPreferenceChanged" && $0["name"] as? String == "paneLayout" }
        XCTAssertNotNil(lastLayoutMsg, "Dragging pane divider must capture and persist updated paneLayout")
        let draggedLayoutVal = try XCTUnwrap(lastLayoutMsg?["value"] as? String)
        let draggedLayout = try JSONSerialization.jsonObject(with: Data(draggedLayoutVal.utf8)) as! [String: Double]
        XCTAssertEqual(try XCTUnwrap(draggedLayout["RSI"]), 0.091, accuracy: 0.02, "Dragged RSI pane ratio must reflect actual mouse movement")
        let rsiScale = try await web.evaluateJavaScript("(()=>{const s=window.testRsi()?.priceScale();return s?{autoScale:s.options().autoScale,range:s.getVisibleRange()}:null})()") as? [String: Any]
        let autoScale = rsiScale?["autoScale"] as? Bool
        XCTAssertEqual(autoScale, false, "RSI priceScale must have autoScale disabled when restored from paneScales")
        if let range = rsiScale?["range"] as? [String: Double] {
            XCTAssertEqual(range["from"] ?? 0, 15, accuracy: 1.0)
            XCTAssertEqual(range["to"] ?? 0, 85, accuracy: 1.0)
        } else {
            XCTFail("RSI visible range should be present")
        }

        // 2. Test detail surface: resizing on detail saves paneLayout
        _ = try await web.evaluateJavaScript("window.testSetSurface('detail');window.testChart.panes()[1].setHeight(180);window.testChart.takeScreenshot()!==null;document.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));")
        try await Task.sleep(nanoseconds: 400_000_000)
        let detailLayoutMsg = messages.last { $0["type"] as? String == "chartPreferenceChanged" && $0["name"] as? String == "paneLayout" }
        XCTAssertNotNil(detailLayoutMsg, "Detail surface must capture and persist paneLayout changes")

        // 3. Test modifying RSI price scale saves paneScales
        _ = try await web.evaluateJavaScript("const s=window.testRsi().priceScale();s.setAutoScale(false);s.setVisibleRange({from:10,to:95});document.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));")
        try await Task.sleep(nanoseconds: 400_000_000)
        let scalesMsg = messages.last { $0["type"] as? String == "chartPreferenceChanged" && $0["name"] as? String == "paneScales" }
        XCTAssertNotNil(scalesMsg, "Adjusting RSI scale range must persist paneScales")
        let scalesVal = try XCTUnwrap(scalesMsg?["value"] as? String)
        XCTAssertTrue(scalesVal.contains("\"RSI\""))
        let storedScales = UserDefaults.standard.dictionary(forKey: keys[0])?["paneScales"] as? String
        XCTAssertNotNil(storedScales, "paneScales must be saved to native UserDefaults")

        // 4. Test modifying Price scale saves per-symbol in paneScales
        _ = try await web.evaluateJavaScript("const ps=window.testCandles().priceScale();ps.setAutoScale(false);ps.setVisibleRange({from:90,to:120});document.dispatchEvent(new MouseEvent('mouseup',{bubbles:true}));")
        try await Task.sleep(nanoseconds: 400_000_000)
        let priceScalesMsg = messages.last { $0["type"] as? String == "chartPreferenceChanged" && $0["name"] as? String == "paneScales" }
        let priceScalesVal = try XCTUnwrap(priceScalesMsg?["value"] as? String)
        XCTAssertTrue(priceScalesVal.contains("\"TEST\"") && priceScalesVal.contains("\"Price\""), "Price scale must be saved per-symbol in paneScales")

        // 5. Test zooming/panning X-axis saves viewports to UserDefaults
        _ = try await web.evaluateJavaScript("window.testChart.timeScale().setVisibleLogicalRange({from:15,to:45});")
        try await Task.sleep(nanoseconds: 400_000_000)
        let viewportMsg = messages.last { $0["type"] as? String == "chartPreferenceChanged" && $0["name"] as? String == "viewports" }
        XCTAssertNotNil(viewportMsg, "Adjusting X-axis logical range must persist viewports")
        let storedViewports = UserDefaults.standard.dictionary(forKey: keys[0])?["viewports"] as? String
        XCTAssertNotNil(storedViewports, "viewports must be saved to native UserDefaults")

        // 6. Test resetChartView restores autoScale and clears stored scale
        _ = try await web.evaluateJavaScript("window.resetChartView()")
        try await Task.sleep(nanoseconds: 200_000_000)
        let rsiResetAutoScale = try await web.evaluateJavaScript("window.testRsi()?.priceScale().options().autoScale") as? Bool
        XCTAssertEqual(rsiResetAutoScale, true, "resetChartView must restore RSI autoScale to true")
        let priceResetAutoScale = try await web.evaluateJavaScript("window.testCandles()?.priceScale().options().autoScale") as? Bool
        XCTAssertEqual(priceResetAutoScale, true, "resetChartView must restore Price autoScale to true")
    }

    func testAsynchronousBarsLoadForcesResetAndFitsRange() async throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("StockDeck/Resources")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.copyItem(at: resources.appendingPathComponent("LightweightCharts"), to: directory.appendingPathComponent("LightweightCharts"))
        try FileManager.default.copyItem(at: resources.appendingPathComponent("CustomPineChart.js"), to: directory.appendingPathComponent("CustomPineChart.js"))

        var html = try String(contentsOf: resources.appendingPathComponent("LightweightChartTrial.html"))
        html = html.replacingOccurrences(of: "const chart=C.createChart", with: "const chart=window.testChart=C.createChart")
        html = html.replacingOccurrences(of: "const surface=window.stockDeckChartSurface==='superchart'?'superchart':'detail';",
            with: "let surface=window.stockDeckChartSurface==='superchart'?'superchart':'detail';window.testSetSurface=value=>{surface=value};")

        let file = directory.appendingPathComponent("chart.html")
        try html.write(to: file, atomically: true, encoding: .utf8)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "chart")
        config.userContentController.addUserScript(WKUserScript(source: "window.stockDeckChartSurface='detail';window.onerror=(msg,url,line)=>window.webkit.messageHandlers.chart.postMessage({type:'jsError',message:msg+' at line '+line});", injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web
        window.orderFront(nil)
        defer { window.orderOut(nil); config.userContentController.removeScriptMessageHandler(forName: "chart") }

        web.loadFileURL(file, allowingReadAccessTo: directory)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("typeof window.setChartData==='function'")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // 1. Initial async state: empty bars
        let emptyPayload = LightweightChartMath.payload(points: [], interval: .day, symbol: "VOO", currency: "USD", periods: [:], showsRangeControls: true)
        let emptyJson = String(data: try JSONEncoder().encode(emptyPayload), encoding: .utf8)!
        _ = try await web.evaluateJavaScript("window.setChartData(\(emptyJson));")

        // 2. Data arrives asynchronously (100 bars)
        let points = (0..<100).map { PricePoint(date: Date(timeIntervalSince1970: 1_700_000_000 + Double($0)*86400), close: 400 + Double($0 % 10)) }
        let fullPayload = LightweightChartMath.payload(points: points, interval: .day, symbol: "VOO", currency: "USD", periods: [:], showsRangeControls: true)
        let fullJson = String(data: try JSONEncoder().encode(fullPayload), encoding: .utf8)!
        _ = try await web.evaluateJavaScript("window.setChartData(\(fullJson));")

        try await Task.sleep(nanoseconds: 300_000_000)

        // 3. Verify visible logical range spans the actual candles
        let rangeResult = try await web.evaluateJavaScript("window.testChart.timeScale().getVisibleLogicalRange()")
        let range = try XCTUnwrap(rangeResult as? [String: Double])
        let to = try XCTUnwrap(range["to"])
        let from = try XCTUnwrap(range["from"])

        XCTAssertGreaterThan(to, 50.0, "Chart viewport must fit or restore the actual candles, not 0-bar range")
        XCTAssertLessThan(from, 50.0, "Chart viewport start must span the data range")
    }

    func testDetailSurfaceSMAToggleDrawsMovingAverageSeries() async throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("StockDeck/Resources")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.copyItem(at: resources.appendingPathComponent("LightweightCharts"), to: directory.appendingPathComponent("LightweightCharts"))
        try FileManager.default.copyItem(at: resources.appendingPathComponent("CustomPineChart.js"), to: directory.appendingPathComponent("CustomPineChart.js"))

        var html = try String(contentsOf: resources.appendingPathComponent("LightweightChartTrial.html"))
        html = html.replacingOccurrences(of: "const chart=C.createChart", with: "const chart=window.testChart=C.createChart")

        let file = directory.appendingPathComponent("chart.html")
        try html.write(to: file, atomically: true, encoding: .utf8)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "chart")
        config.userContentController.addUserScript(WKUserScript(source: "window.stockDeckChartSurface='detail';window.onerror=(msg,url,line)=>window.webkit.messageHandlers.chart.postMessage({type:'jsError',message:msg+' at line '+line});", injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web
        window.orderFront(nil)
        defer { window.orderOut(nil); config.userContentController.removeScriptMessageHandler(forName: "chart") }

        web.loadFileURL(file, allowingReadAccessTo: directory)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("typeof window.setChartData==='function'")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let points = (0..<100).map { PricePoint(date: Date(timeIntervalSince1970: 1_700_000_000 + Double($0)*86400), close: 400 + Double($0 % 10)) }
        let periods: [String: Int] = [
            "SMA MA 1|SMA|close": 20, "SMA MA 2|SMA|close": 50, "SMA MA 3|SMA|close": 100, "SMA MA 4|SMA|close": 200
        ]
        let payload = LightweightChartMath.payload(points: points, interval: .day, symbol: "VOO", currency: "USD", periods: periods, showsRangeControls: true)
        let json = String(data: try JSONEncoder().encode(payload), encoding: .utf8)!
        _ = try await web.evaluateJavaScript("window.setChartData(\(json));")

        try await Task.sleep(nanoseconds: 300_000_000)

        // Verify SMA indicator is present on legend by default in detail surface
        let isSMAPresent = try await web.evaluateJavaScript("!!document.querySelector('[data-indicator=\"MA:SMA\"]')") as? Bool
        XCTAssertEqual(isSMAPresent, true, "SMA must be present on legend by default in detail surface")

        // Verify series count in main price pane includes the candles plus SMA series
        let seriesCount = try await web.evaluateJavaScript("window.testChart.panes()[0].getSeries().length") as? Int
        XCTAssertGreaterThan(seriesCount ?? 0, 1, "Main price pane must render SMA line series in detail surface")

        // 1. Hide SMA via eye toggle button on legend
        _ = try await web.evaluateJavaScript("document.querySelector('[data-indicator=\"MA:SMA\"] [data-action=\"toggle\"]').click()")
        try await Task.sleep(nanoseconds: 200_000_000)

        let isHidden = try await web.evaluateJavaScript("document.querySelector('[data-indicator=\"MA:SMA\"]').classList.contains('is-hidden')") as? Bool
        XCTAssertEqual(isHidden, true, "SMA legend row must have is-hidden class when toggled off")

        let hasEyeSlash = try await web.evaluateJavaScript("document.querySelector('[data-indicator=\"MA:SMA\"] [data-action=\"toggle\"]').innerHTML.includes('M9.88')") as? Bool
        XCTAssertEqual(hasEyeSlash, true, "Eye button must display eyeSlash icon when hidden")

        let hiddenSeriesCount = try await web.evaluateJavaScript("window.testChart.panes()[0].getSeries().length") as? Int
        XCTAssertEqual(hiddenSeriesCount, 3, "SMA lines must be removed when hidden (leaving 3 base series: candles, closeLine, volume)")

        // 2. Show SMA again via eye toggle
        _ = try await web.evaluateJavaScript("document.querySelector('[data-indicator=\"MA:SMA\"] [data-action=\"toggle\"]').click()")
        try await Task.sleep(nanoseconds: 200_000_000)

        let restoredSeriesCount = try await web.evaluateJavaScript("window.testChart.panes()[0].getSeries().length") as? Int
        XCTAssertEqual(restoredSeriesCount, 7, "All 4 SMA lines must be restored when shown (total 7 series)")

        // 3. Delete SMA via delete button on legend
        _ = try await web.evaluateJavaScript("document.querySelector('[data-indicator=\"MA:SMA\"] [data-action=\"delete\"]').click()")
        try await Task.sleep(nanoseconds: 200_000_000)

        let isSMADeleted = try await web.evaluateJavaScript("!document.querySelector('[data-indicator=\"MA:SMA\"]')") as? Bool
        XCTAssertEqual(isSMADeleted, true, "SMA row must be completely removed from legend after delete")

        let deletedSeriesCount = try await web.evaluateJavaScript("window.testChart.panes()[0].getSeries().length") as? Int
        XCTAssertEqual(deletedSeriesCount, 3, "SMA lines must be completely removed from chart after delete")

        // 4. Re-add SMA from indicator menu
        _ = try await web.evaluateJavaScript("document.querySelector('[data-ind=\"SMA\"]').click()")
        try await Task.sleep(nanoseconds: 200_000_000)

        let readdedSMA = try await web.evaluateJavaScript("!!document.querySelector('[data-indicator=\"MA:SMA\"]')") as? Bool
        XCTAssertEqual(readdedSMA, true, "Clicking SMA in indicator menu must re-add SMA to legend and chart")

        let readdedSeriesCount = try await web.evaluateJavaScript("window.testChart.panes()[0].getSeries().length") as? Int
        XCTAssertEqual(readdedSeriesCount, 7, "All 4 SMA lines must be drawn on chart after re-adding from menu")
    }
}
