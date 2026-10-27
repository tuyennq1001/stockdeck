import XCTest
import WebKit
@testable import StockDeck

final class SuperchartDrawingAndFavoritesTests: XCTestCase {

    func testPriceRangeLegacyJSONDecodingCompatibility() throws {
        let legacyJSON = """
        {
            "id": "test-legacy-1",
            "kind": "range",
            "color": "#1a9b82",
            "lineWidth": 2,
            "isLocked": false,
            "startTime": "2026-10-01",
            "endTime": "2026-10-15",
            "startPrice": 120.5,
            "endPrice": 135.0
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try JSONDecoder().decode(LightweightPriceRange.self, from: data)

        XCTAssertEqual(decoded.id, "test-legacy-1")
        XCTAssertEqual(decoded.kind, "range")
        XCTAssertEqual(decoded.color, "#1a9b82")
        XCTAssertEqual(decoded.lineWidth, 2)
        XCTAssertFalse(decoded.isLocked)
        XCTAssertEqual(decoded.startTime, "2026-10-01")
        XCTAssertEqual(decoded.endTime, "2026-10-15")
        XCTAssertEqual(decoded.startPrice, 120.5)
        XCTAssertEqual(decoded.endPrice, 135.0)
        XCTAssertEqual(decoded.lineStyle, "solid")
        XCTAssertEqual(decoded.extendRight, false)
        XCTAssertNil(decoded.text)
        XCTAssertEqual(decoded.fontSize, 13)
    }

    func testPriceRangeNewFieldsRoundTrip() throws {
        let drawing = LightweightPriceRange(
            id: "test-new-1",
            kind: "horizontalRay",
            color: "#f59e0b",
            lineWidth: 3,
            isLocked: true,
            startTime: "2026-10-20",
            endTime: "2026-10-25",
            startPrice: 140.0,
            endPrice: 140.0,
            lineStyle: "dashed",
            extendRight: true,
            text: "Kháng cự then chốt",
            fontSize: 14,
            fontColor: "#ffffff"
        )

        let encoded = try JSONEncoder().encode(drawing)
        let decoded = try JSONDecoder().decode(LightweightPriceRange.self, from: encoded)

        XCTAssertEqual(decoded.id, "test-new-1")
        XCTAssertEqual(decoded.kind, "horizontalRay")
        XCTAssertEqual(decoded.color, "#f59e0b")
        XCTAssertEqual(decoded.lineWidth, 3)
        XCTAssertTrue(decoded.isLocked)
        XCTAssertEqual(decoded.startTime, "2026-10-20")
        XCTAssertEqual(decoded.endTime, "2026-10-25")
        XCTAssertEqual(decoded.startPrice, 140.0)
        XCTAssertEqual(decoded.endPrice, 140.0)
        XCTAssertEqual(decoded.lineStyle, "dashed")
        XCTAssertEqual(decoded.extendRight, true)
        XCTAssertEqual(decoded.text, "Kháng cự then chốt")
        XCTAssertEqual(decoded.fontSize, 14)
        XCTAssertEqual(decoded.fontColor, "#ffffff")
    }

    func testDrawingStoreValidation() async throws {
        let store = LightweightChartDrawingStore()

        let validPin = LightweightPriceRange(
            id: "pin-1",
            kind: "pin",
            color: "#3b82f6",
            lineWidth: 1,
            isLocked: false,
            startTime: "2026-10-10",
            endTime: "2026-10-10",
            startPrice: 150.0,
            endPrice: 150.0,
            text: "Breakout đỉnh cũ"
        )
        try await store.save([validPin], symbol: "AAPL")
        let loaded = await store.load(symbol: "AAPL")
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.text, "Breakout đỉnh cũ")

        let autoColorRange = LightweightPriceRange(
            id: "range-auto-1",
            kind: "range",
            color: "auto",
            lineWidth: 2,
            isLocked: false,
            startTime: "2026-10-12",
            endTime: "2026-10-20",
            startPrice: 100,
            endPrice: 125
        )
        try await store.save([autoColorRange], symbol: "MSFT")
        let loadedAuto = await store.load(symbol: "MSFT")
        XCTAssertEqual(loadedAuto.count, 1)
        XCTAssertEqual(loadedAuto.first?.color, "auto")

        let textTooLong = String(repeating: "A", count: 1001)
        let invalidRange = LightweightPriceRange(
            id: "invalid-1",
            kind: "range",
            color: "#1a9b82",
            lineWidth: 1,
            isLocked: false,
            startTime: "2026-10-01",
            endTime: "2026-10-02",
            startPrice: 100,
            endPrice: 110,
            text: textTooLong
        )
        do {
            try await store.save([invalidRange], symbol: "NVDA")
            XCTFail("Should reject text > 1000 characters")
        } catch {
            // Expected
        }
    }

    func testSuperchartFavoriteSourcesAndShortcutsPersistence() {
        let testDefaults = UserDefaults(suiteName: "StockDeckTests.SuperchartFavorites")!
        testDefaults.removePersistentDomain(forName: "StockDeckTests.SuperchartFavorites")

        let favoriteKey = "stockdeck.superchart.favoriteSources.v1"
        let shortcutKey = "stockdeck.superchart.sourceShortcuts.v1"

        let initialFavorites = ["source-1", "source-2", "source-3"]
        testDefaults.set(initialFavorites, forKey: favoriteKey)

        let initialAliases = ["source-1": "Tech Top", "source-2": "Cổ tức 8%"]
        testDefaults.set(initialAliases, forKey: shortcutKey)

        let loadedFavorites = testDefaults.stringArray(forKey: favoriteKey) ?? []
        let loadedAliases = testDefaults.dictionary(forKey: shortcutKey) as? [String: String] ?? [:]

        XCTAssertEqual(loadedFavorites, ["source-1", "source-2", "source-3"])
        XCTAssertEqual(loadedAliases["source-1"], "Tech Top")
        XCTAssertEqual(loadedAliases["source-2"], "Cổ tức 8%")
        XCTAssertNil(loadedAliases["source-3"])
    }

    @MainActor
    func testChartHtmlDrawingToolElementsExist() async throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("StockDeck/Resources")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.copyItem(
            at: resources.appendingPathComponent("LightweightCharts"),
            to: directory.appendingPathComponent("LightweightCharts")
        )
        let htmlPath = resources.appendingPathComponent("LightweightChartTrial.html")
        let html = try String(contentsOf: htmlPath)

        let file = directory.appendingPathComponent("chart.html")
        try html.write(to: file, atomically: true, encoding: .utf8)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)

        web.loadFileURL(file, allowingReadAccessTo: directory)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("typeof window.setChartData==='function'")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // Verify rail buttons and modifiers exist
        let selectBtn = try await web.evaluateJavaScript("!!document.getElementById('toolSelect')") as? Bool
        XCTAssertEqual(selectBtn, true)

        let rulerBtn = try await web.evaluateJavaScript("!!document.getElementById('toolRuler')") as? Bool
        XCTAssertEqual(rulerBtn, true)

        let modMagnet = try await web.evaluateJavaScript("!!document.getElementById('modMagnet')") as? Bool
        XCTAssertEqual(modMagnet, true)

        let modStay = try await web.evaluateJavaScript("!!document.getElementById('modStay')") as? Bool
        XCTAssertEqual(modStay, true)

        let modLockAll = try await web.evaluateJavaScript("!!document.getElementById('modLockAll')") as? Bool
        XCTAssertEqual(modLockAll, true)

        let modHideAll = try await web.evaluateJavaScript("!!document.getElementById('modHideAll')") as? Bool
        XCTAssertEqual(modHideAll, true)

        let modClearAll = try await web.evaluateJavaScript("!!document.getElementById('modClearAll')") as? Bool
        XCTAssertEqual(modClearAll, true)

        // Verify flyout menu and text dialog
        let flyout = try await web.evaluateJavaScript("!!document.getElementById('drawFlyout')") as? Bool
        XCTAssertEqual(flyout, true)

        let pinTooltip = try await web.evaluateJavaScript("!!document.getElementById('pinTooltip')") as? Bool
        XCTAssertEqual(pinTooltip, true)

        let inlineEditor = try await web.evaluateJavaScript("!!document.getElementById('inlineDrawingEditor')") as? Bool
        XCTAssertEqual(inlineEditor, true)

        // Verify line style and extend button in #drawingTools
        let lineStyleSelect = try await web.evaluateJavaScript("!!document.getElementById('drawingLineStyle')") as? Bool
        XCTAssertEqual(lineStyleSelect, true)

        let extendBtn = try await web.evaluateJavaScript("!!document.getElementById('extendDrawing')") as? Bool
        XCTAssertEqual(extendBtn, true)

        let editTextBtn = try await web.evaluateJavaScript("!!document.getElementById('editDrawingText')") as? Bool
        XCTAssertEqual(editTextBtn, true)

        let colorBtn = try await web.evaluateJavaScript("!!document.getElementById('drawingColorBtn')") as? Bool
        XCTAssertEqual(colorBtn, true)

        let colorSwatch = try await web.evaluateJavaScript("!!document.getElementById('drawingColorSwatch')") as? Bool
        XCTAssertEqual(colorSwatch, true)

        let duplicateBtn = try await web.evaluateJavaScript("!!document.getElementById('duplicateDrawing')") as? Bool
        XCTAssertEqual(duplicateBtn, true)

        let fontColorBtn = try await web.evaluateJavaScript("!!document.getElementById('drawingFontColorBtn')") as? Bool
        XCTAssertEqual(fontColorBtn, true)

        let fontSizeSelect = try await web.evaluateJavaScript("!!document.getElementById('drawingFontSize')") as? Bool
        XCTAssertEqual(fontSizeSelect, true)

        let dragHandle = try await web.evaluateJavaScript("!!document.getElementById('drawingDragHandle')") as? Bool
        XCTAssertEqual(dragHandle, true)

        let fontSizeBtn = try await web.evaluateJavaScript("!!document.getElementById('drawingFontSizeBtn')") as? Bool
        XCTAssertEqual(fontSizeBtn, true)

        let widthBtn = try await web.evaluateJavaScript("!!document.getElementById('drawingWidthBtn')") as? Bool
        XCTAssertEqual(widthBtn, true)

        let lineStyleBtn = try await web.evaluateJavaScript("!!document.getElementById('drawingLineStyleBtn')") as? Bool
        XCTAssertEqual(lineStyleBtn, true)

        let utf8Helper = try await web.evaluateJavaScript("typeof window.__setChartDataBase64 === 'function'") as? Bool
        XCTAssertEqual(utf8Helper, true)

        let saveStateGone = try await web.evaluateJavaScript("document.getElementById('saveState') === null") as? Bool
        XCTAssertEqual(saveStateGone, true)
    }

    @MainActor
    func testFloatingToolbarFullInteractiveLifecycle() async throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("StockDeck/Resources")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.copyItem(
            at: resources.appendingPathComponent("LightweightCharts"),
            to: directory.appendingPathComponent("LightweightCharts")
        )
        let htmlPath = resources.appendingPathComponent("LightweightChartTrial.html")
        let html = try String(contentsOf: htmlPath)

        let file = directory.appendingPathComponent("chart.html")
        try html.write(to: file, atomically: true, encoding: .utf8)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)

        web.loadFileURL(file, allowingReadAccessTo: directory)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("typeof window.setChartData==='function'")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // 1. Initialize data with sample bars and drawings
        let initScript = """
        window.setChartData({
            symbol: 'TEST',
            currency: 'USD',
            interval: '1D',
            bars: [
                { time: '2026-10-01', open: 100, high: 110, low: 95, close: 105 },
                { time: '2026-10-02', open: 105, high: 115, low: 102, close: 112 },
                { time: '2026-10-05', open: 112, high: 120, low: 108, close: 118 }
            ]
        });
        window.setPriceRanges([
            { id: 'note-1', kind: 'pin', startTime: '2026-10-02', endTime: '2026-10-02', startPrice: 110, endPrice: 110, color: '#3b82f6', text: 'Ghi chú ban đầu', fontSize: 13, fontColor: '#ffffff' },
            { id: 'range-1', kind: 'range', startTime: '2026-10-01', endTime: '2026-10-05', startPrice: 100, endPrice: 120, color: '#16816d', lineWidth: 1, lineStyle: 'solid' },
            { id: 'trend-1', kind: 'trend', startTime: '2026-10-01', endTime: '2026-10-05', startPrice: 95, endPrice: 115, color: '#2962ff', lineWidth: 1, lineStyle: 'solid', extendRight: false }
        ]);
        """
        do {
            _ = try await web.evaluateJavaScript(initScript)
        } catch {
            XCTFail("Step 1 failed: \(error)")
            return
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        // 2. Select note-1 and verify font controls are hidden for Note (icon-only, no text on canvas)
        let selectNoteScript = """
        (function() {
            window.__selectDrawing('note-1');
            const d = window.__getDrawings().find(x => x.id === 'note-1');
            const tools = document.getElementById('drawingTools');
            return {
                hidden: tools.hidden,
                drawingsCount: window.__getDrawings().length,
                selectedId: window.__getSelectedId(),
                fontColorHidden: document.getElementById('drawingFontColorBtn').hidden,
                fontSizeHidden: document.getElementById('drawingFontSizeBtn').hidden,
                editTextVisible: !document.getElementById('editDrawingText').hidden
            };
        })()
        """
        do {
            let res = try await web.evaluateJavaScript(selectNoteScript) as? [String: Any]
            let isHidden = res?["hidden"] as? Bool
            XCTAssertEqual(isHidden, false, "Toolbar should not be hidden when note-1 is selected")
            XCTAssertEqual(res?["fontColorHidden"] as? Bool, false, "Font color button must be visible for note")
            XCTAssertEqual(res?["fontSizeHidden"] as? Bool, false, "Font size button must be visible for note")
            XCTAssertEqual(res?["editTextVisible"] as? Bool, true, "Edit text button must be visible for note")
        } catch {
            XCTFail("Step 2 failed: \(error)")
            return
        }

        // 2b. Test Note default pin-only vs hover callout & verify #pinTooltip is disabled
        let hoverNoteScript = """
        (function() {
            const d = window.__getDrawings().find(x => x.id === 'note-1');
            const tip = document.getElementById('pinTooltip');
            const tipDisplay = window.getComputedStyle(tip).display;
            const tools = document.getElementById('drawingTools');
            const toolsZIndex = parseInt(window.getComputedStyle(tools).zIndex || '0', 10);
            const editor = document.getElementById('inlineDrawingEditor');
            const editorZIndex = parseInt(window.getComputedStyle(editor).zIndex || '0', 10);
            return {
                tipDisplay,
                toolsAboveEditor: toolsZIndex > editorZIndex,
                noteText: d ? d.text : null
            };
        })()
        """
        do {
            let tipRes = try await web.evaluateJavaScript(hoverNoteScript) as? [String: Any]
            XCTAssertEqual(tipRes?["tipDisplay"] as? String, "none", "Redundant #pinTooltip must be display:none so there are never two popups")
            XCTAssertEqual(tipRes?["toolsAboveEditor"] as? Bool, true, "Floating toolbar z-index must be above inline editor")
            XCTAssertEqual(tipRes?["noteText"] as? String, "Ghi chú ban đầu")
        } catch {
            XCTFail("Step 2b failed: \(error)")
            return
        }

        // 3. Test Drag Handle
        let dragScript = """
        (function() {
            const handle = document.getElementById('drawingDragHandle');
            const tools = document.getElementById('drawingTools');
            const downEvt = new PointerEvent('pointerdown', { clientX: 200, clientY: 100, pointerId: 1, bubbles: true });
            handle.dispatchEvent(downEvt);
            const moveEvt = new PointerEvent('pointermove', { clientX: 350, clientY: 220, pointerId: 1, bubbles: true });
            handle.dispatchEvent(moveEvt);
            const upEvt = new PointerEvent('pointerup', { clientX: 350, clientY: 220, pointerId: 1, bubbles: true });
            handle.dispatchEvent(upEvt);
            return {
                left: parseInt(tools.style.left),
                top: parseInt(tools.style.top),
                isCustom: !!window.__getToolbarCustomPos()
            };
        })()
        """
        do {
            guard let dragResult = try await web.evaluateJavaScript(dragScript) as? [String: Any],
                  let isCustom = dragResult["isCustom"] as? Bool else {
                XCTFail("Failed to execute drag handle script")
                return
            }
            XCTAssertTrue(isCustom, "Custom position should be tracked when toolbar is dragged")
        } catch {
            XCTFail("Step 3 failed: \(error)")
            return
        }

        // 4. Test Font Color popover on range-1
        let fontColorScript = """
        (function() {
            window.__selectDrawing('range-1');
            document.getElementById('drawingFontColorBtn').click();
            const pop = document.querySelector('.drawing-color-popover');
            if (!pop) return { popoverOpened: false };
            const chip = pop.querySelector('[data-color="#38bdf8"]');
            if (chip) chip.click();
            const d = window.__getDrawings().find(x => x.id === 'range-1');
            return {
                popoverOpened: true,
                fontColor: d ? d.fontColor : null,
                popoverRemoved: document.querySelector('.drawing-color-popover') === null
            };
        })()
        """
        do {
            guard let fontColorRes = try await web.evaluateJavaScript(fontColorScript) as? [String: Any] else {
                XCTFail("Failed to execute font color script")
                return
            }
            XCTAssertEqual(fontColorRes["popoverOpened"] as? Bool, true)
            XCTAssertEqual(fontColorRes["fontColor"] as? String, "#38bdf8", "Range font color should update to #38bdf8")
            XCTAssertEqual(fontColorRes["popoverRemoved"] as? Bool, true, "Popover should close after color selection")
        } catch {
            XCTFail("Step 4 failed: \(error)")
            return
        }

        // 5. Test Font Size popover & verify persistence across setChartData re-render
        let fontSizeScript = """
        (function() {
            document.getElementById('drawingFontSizeBtn').click();
            const pop = document.querySelector('.floating-mini-popover');
            if (!pop) return { popoverOpened: false };
            const item18 = [...pop.querySelectorAll('.popover-item')].find(el => el.textContent.includes('18px'));
            if (item18) item18.click();
            const d = window.__getDrawings().find(x => x.id === 'range-1');
            const labelText = document.getElementById('drawingFontSizeLabel')?.textContent;
            return {
                popoverOpened: true,
                fontSize: d ? d.fontSize : null,
                labelText,
                popoverRemoved: document.querySelector('.floating-mini-popover') === null
            };
        })()
        """
        do {
            guard let fontSizeRes = try await web.evaluateJavaScript(fontSizeScript) as? [String: Any] else {
                XCTFail("Failed to execute font size script")
                return
            }
            XCTAssertEqual(fontSizeRes["popoverOpened"] as? Bool, true)
            XCTAssertEqual(fontSizeRes["fontSize"] as? Double, 18, "Range font size should update to 18px")
            XCTAssertEqual(fontSizeRes["labelText"] as? String, "18px", "Label text should be 18px")
            XCTAssertEqual(fontSizeRes["popoverRemoved"] as? Bool, true)

            // Test Full Round-Trip: simulate incoming setChartData cycle and verify it does NOT revert to 13
            let reRenderScript = """
            (function() {
                const currentDrawings = window.__getDrawings();
                window.setChartData({
                    symbol: 'AAPL',
                    currency: 'USD',
                    interval: '1d',
                    bars: [{ time: '2026-10-20', open: 150, high: 155, low: 149, close: 154, volume: 1000 }],
                    drawings: currentDrawings
                });
                const d = window.__getDrawings().find(x => x.id === 'range-1');
                const labelText = document.getElementById('drawingFontSizeLabel')?.textContent;
                return {
                    fontSizeAfterReRender: d ? d.fontSize : null,
                    labelAfterReRender: labelText
                };
            })()
            """
            guard let reRenderRes = try await web.evaluateJavaScript(reRenderScript) as? [String: Any] else {
                XCTFail("Failed to execute reRenderScript")
                return
            }
            XCTAssertEqual(reRenderRes["fontSizeAfterReRender"] as? Double, 18, "Font size must stay 18px and never revert to 13px after setChartData")
            XCTAssertEqual(reRenderRes["labelAfterReRender"] as? String, "18px", "Toolbar label must stay 18px")
        } catch {
            XCTFail("Step 5 failed: \(error)")
            return
        }

        // 6. Test Marker Color popover
        let markerColorScript = """
        (function() {
            window.__selectDrawing('note-1');
            document.getElementById('drawingColorBtn').click();
            const pop = document.querySelector('.drawing-color-popover');
            if (!pop) return { popoverOpened: false };
            const chip = pop.querySelector('[data-color="#ef4444"]');
            if (chip) chip.click();
            const d = window.__getDrawings().find(x => x.id === 'note-1');
            return {
                color: d ? d.color : null,
                popoverRemoved: document.querySelector('.drawing-color-popover') === null
            };
        })()
        """
        guard let markerColorRes = try await web.evaluateJavaScript(markerColorScript) as? [String: Any] else {
            XCTFail("Failed to execute marker color script")
            return
        }
        XCTAssertEqual(markerColorRes["color"] as? String, "#ef4444", "Marker color should update to #ef4444")
        XCTAssertEqual(markerColorRes["popoverRemoved"] as? Bool, true)

        // 7. Test Edit Text Inline Editor
        let editTextScript = """
        (function() {
            window.__selectDrawing('note-1');
            document.getElementById('editDrawingText').click();
            const editor = document.getElementById('inlineDrawingEditor');
            const input = document.getElementById('inlineDrawingInput');
            const wasVisible = !editor.hidden;
            input.value = 'Hỗ trợ cứng';
            input.dispatchEvent(new Event('input'));
            // Commit on Enter
            input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
            const d = window.__getDrawings().find(x => x.id === 'note-1');
            return {
                wasVisible,
                editorHiddenAfter: editor.hidden,
                updatedText: d ? d.text : null
            };
        })()
        """
        guard let editTextRes = try await web.evaluateJavaScript(editTextScript) as? [String: Any] else {
            XCTFail("Failed to execute edit text script")
            return
        }
        XCTAssertEqual(editTextRes["wasVisible"] as? Bool, true, "Inline editor should open")
        XCTAssertEqual(editTextRes["editorHiddenAfter"] as? Bool, true, "Inline editor should close after Enter")
        XCTAssertEqual(editTextRes["updatedText"] as? String, "Hỗ trợ cứng")

        // 8. Test Lock / Unlock
        let lockScript = """
        (function() {
            const lockBtn = document.getElementById('lockDrawing');
            lockBtn.click();
            const d = window.__getDrawings().find(x => x.id === 'note-1');
            const isLocked = d && d.isLocked;
            const isDeleteDisabled = document.getElementById('deleteRange').disabled;
            const isColorDisabled = document.getElementById('drawingColorBtn').disabled;
            lockBtn.click(); // Unlock again
            return {
                locked: isLocked,
                deleteDisabledWhenLocked: isDeleteDisabled,
                colorDisabledWhenLocked: isColorDisabled,
                unlockedAfterSecondClick: d && !d.isLocked
            };
        })()
        """
        guard let lockRes = try await web.evaluateJavaScript(lockScript) as? [String: Any] else {
            XCTFail("Failed to execute lock script")
            return
        }
        XCTAssertEqual(lockRes["locked"] as? Bool, true)
        XCTAssertEqual(lockRes["deleteDisabledWhenLocked"] as? Bool, true)
        XCTAssertEqual(lockRes["colorDisabledWhenLocked"] as? Bool, true)
        XCTAssertEqual(lockRes["unlockedAfterSecondClick"] as? Bool, true)

        // 9. Test Duplicate Drawing
        let duplicateScript = """
        (function() {
            const initialCount = window.__getDrawings().length;
            document.getElementById('duplicateDrawing').click();
            return {
                initialCount,
                newCount: window.__getDrawings().length,
                newSelectedId: window.__getSelectedId()
            };
        })()
        """
        guard let dupRes = try await web.evaluateJavaScript(duplicateScript) as? [String: Any],
              let initialCount = dupRes["initialCount"] as? Int,
              let newCount = dupRes["newCount"] as? Int else {
            XCTFail("Failed to execute duplicate script")
            return
        }
        XCTAssertEqual(newCount, initialCount + 1, "Duplicate should add 1 drawing")

        // 10. Test Range Features (Width, Style, No Extend/No Text on Range) and Note (Font size, Color)
        let rangeFeaturesScript = """
        (function() {
            window.__selectDrawing('note-1');
            const noteFontSizeBtn = document.getElementById('drawingFontSizeBtn');
            const noteFontColorBtn = document.getElementById('drawingFontColorBtn');
            const noteFontSizeVisible = !noteFontSizeBtn.hidden;
            const noteFontColorVisible = !noteFontColorBtn.hidden;

            // Open inline editor on note-1 and change font size to 16px while inline editor is open
            document.getElementById('editDrawingText').click();
            noteFontSizeBtn.click();
            const popFont = document.querySelector('.floating-mini-popover');
            const item16px = [...popFont.querySelectorAll('.popover-item')].find(el => el.textContent.includes('16px'));
            if (item16px) {
                item16px.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true }));
                item16px.click();
            }
            const inlineFontSizeAfter = document.getElementById('inlineDrawingInput')?.style.fontSize;
            document.getElementById('inlineDrawingInput')?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
            const dNoteAfter = window.__getDrawings().find(x => x.id === 'note-1');

            window.__selectDrawing('range-1');
            const extendBtn = document.getElementById('extendDrawing');
            const editTextBtn = document.getElementById('editDrawingText');
            const extendHiddenOnRange = extendBtn.hidden;
            const textHiddenOnRange = editTextBtn.hidden;

            // Line width to 4px
            document.getElementById('drawingWidthBtn').click();
            const popWidth = document.querySelector('.floating-mini-popover');
            const item4px = [...popWidth.querySelectorAll('.popover-item')].find(el => el.textContent.includes('4px'));
            if (item4px) item4px.click();
            const widthLabelAfter = document.getElementById('drawingWidthLabel')?.textContent;

            // Line style to dashed
            document.getElementById('drawingLineStyleBtn').click();
            const popStyle = document.querySelector('.floating-mini-popover');
            const itemDashed = [...popStyle.querySelectorAll('.popover-item')].find(el => el.textContent.includes('Đứt'));
            if (itemDashed) itemDashed.click();
            const styleLabelAfter = document.getElementById('drawingLineStyleLabel')?.textContent;

            const dRange = window.__getDrawings().find(x => x.id === 'range-1');

            // Now select trend-1 and test extend right
            window.__selectDrawing('trend-1');
            const extendVisibleOnTrend = !extendBtn.hidden;
            extendBtn.click();
            const dTrend = window.__getDrawings().find(x => x.id === 'trend-1');

            return {
                noteFontSizeVisible,
                noteFontColorVisible,
                noteFontSize: dNoteAfter ? dNoteAfter.fontSize : null,
                extendHiddenOnRange,
                textHiddenOnRange,
                lineWidth: dRange ? dRange.lineWidth : null,
                widthLabelAfter,
                lineStyle: dRange ? dRange.lineStyle : null,
                styleLabelAfter,
                extendVisibleOnTrend,
                trendExtendRight: dTrend ? dTrend.extendRight : null
            };
        })()
        """
        guard let rangeRes = try await web.evaluateJavaScript(rangeFeaturesScript) as? [String: Any] else {
            XCTFail("Failed to execute range features script")
            return
        }
        XCTAssertEqual(rangeRes["noteFontSizeVisible"] as? Bool, true, "Note should show font size button")
        XCTAssertEqual(rangeRes["noteFontColorVisible"] as? Bool, true, "Note should show font color button")
        XCTAssertEqual(rangeRes["noteFontSize"] as? Double, 16, "Note font size should update to 16")
        XCTAssertEqual(rangeRes["extendHiddenOnRange"] as? Bool, true, "Range tools must not show Extend Right button")
        XCTAssertEqual(rangeRes["textHiddenOnRange"] as? Bool, true, "Range tools must not show Edit Text button")
        XCTAssertEqual(rangeRes["lineWidth"] as? Double, 4, "Range line width should update to 4")
        XCTAssertEqual(rangeRes["widthLabelAfter"] as? String, "4px", "Toolbar width label should update to 4px")
        XCTAssertEqual(rangeRes["lineStyle"] as? String, "dashed", "Range line style should update to dashed")
        XCTAssertEqual(rangeRes["styleLabelAfter"] as? String, "Đứt", "Toolbar style label should update to Đứt")
        XCTAssertEqual(rangeRes["extendVisibleOnTrend"] as? Bool, true, "Trend line must show Extend Right button")
        XCTAssertEqual(rangeRes["trendExtendRight"] as? Bool, true, "Trend line extend right should be true")

        // 11. Test Delete
        let deleteScript = """
        (function() {
            window.__selectDrawing('range-1');
            document.getElementById('deleteRange').click();
            const remainingRange = window.__getDrawings().find(x => x.id === 'range-1');
            return {
                isDeleted: remainingRange === undefined,
                toolbarHidden: document.getElementById('drawingTools').hidden
            };
        })()
        """
        guard let delRes = try await web.evaluateJavaScript(deleteScript) as? [String: Any] else {
            XCTFail("Failed to execute delete script")
            return
        }
        XCTAssertEqual(delRes["isDeleted"] as? Bool, true, "range-1 should be deleted")
        XCTAssertEqual(delRes["toolbarHidden"] as? Bool, true, "Toolbar should be hidden after deletion")
    }
}
