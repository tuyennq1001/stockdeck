import XCTest
import CryptoKit
import Darwin
@testable import StockDeck

// OHLC fixtures below are synthetic, confined to deterministic regression tests.
private func pineTestPoint(_ time: String, close: Double = 102) -> PricePoint {
    PricePoint(date: ISO8601DateFormatter().date(from: time)!, close: close, open: close - 2, high: close + 3, low: close - 4, volume: 10)
}
private func pineTestResult(_ title: String = "indicator") -> CustomPineRunResult {
    let plot = CustomPinePlot(style: "line", title: "same plot", color: "#0000FF", points: [])
    return CustomPineRunResult(ok: true, error: nil, title: title, plots: ["same plot": plot], alertCount: 0, overlay: true)
}
private actor PineExecutionProbe {
    private var continuations: [CheckedContinuation<CustomPineRunResult, Error>?] = []
    private(set) var symbols: [String] = []
    private(set) var active = 0
    private(set) var maximum = 0
    func run(_ source: String, context: PineExecutionContext) async throws -> CustomPineRunResult {
        active += 1; maximum = max(maximum, active); symbols.append(context.symbol)
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
    func finish(_ index: Int, fail: Bool = false) {
        guard index < continuations.count, let continuation = continuations[index] else { return }
        continuations[index] = nil; active -= 1
        if fail { continuation.resume(throwing: CustomPineScriptRunner.RunnerError.message("fixture failure")) }
        else { continuation.resume(returning: pineTestResult()) }
    }
}

private actor PinePreparationProbe {
    private var jobs: [(PineChartInput, CheckedContinuation<PineExecutionContext, Error>)] = []
    private(set) var started = 0
    private(set) var cancelled = Set<Int>()
    func run(_ input: PineChartInput) async throws -> PineExecutionContext {
        let index = started; started += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { jobs.append((input, $0)) }
        } onCancel: { Task { await self.markCancelled(index) } }
    }
    private func markCancelled(_ index: Int) { cancelled.insert(index) }
    // Deliberately finish even after cancellation to test rejection of late results.
    func finish(_ index: Int) throws { jobs[index].1.resume(returning: try PineExecutionContext.prepare(jobs[index].0)) }
}

@MainActor
final class PineScriptWorkspaceTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "StockDeck.PineTests.\(UUID())", value = UserDefaults(suiteName: name)!
        addTeardownBlock { value.removePersistentDomain(forName: name) }
        return value
    }
    private func input(_ symbol: String = "AAPL", interval: LightweightChartInterval = .day) -> PineChartInput {
        let points = [pineTestPoint("2026-01-02T15:00:00Z")]
        return PineChartInput(symbol: symbol, interval: interval, points: points, dailyPoints: points)
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for Pine workspace")
    }

    func testImportLibraryDoesNotAttachAndRestoreSanitizesIDs() async throws {
        let store = defaults(), library = PineScriptLibrary(defaults: store)
        let a = SavedPineScript(name: "A", source: "plot(close)"), b = SavedPineScript(name: "B", source: "plot(close)")
        library.save(a); library.save(b)
        let workspace = PineScriptWorkspace(defaults: store, library: library, execute: { _,_ in pineTestResult() })
        XCTAssertTrue(workspace.activeIDs.isEmpty)
        workspace.setInput(input())
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertTrue(workspace.indicators.isEmpty, "A loaded chart should not implicitly attach a library script")
        workspace.attach(a.id); workspace.attach(a.id); workspace.attach(b.id)
        XCTAssertEqual(workspace.activeIDs, [a.id,b.id])
        XCTAssertTrue(workspace.indicators.allSatisfy { $0.status == "loading" })
        try await wait { workspace.indicators.allSatisfy { $0.status == "loaded" } }
        store.set([a.id.uuidString, "invalid", a.id.uuidString, UUID().uuidString, b.id.uuidString], forKey: "stockdeck.superchart.activePineScripts.v1")
        let restored = PineScriptWorkspace(defaults: store, library: library, execute: { _,_ in pineTestResult() })
        XCTAssertEqual(restored.activeIDs, [a.id,b.id])
        restored.setInput(input()); try await wait { restored.indicators.allSatisfy { $0.status == "loaded" } }
        library.delete(a.id)
        XCTAssertEqual(restored.activeIDs, [b.id]); XCTAssertEqual(restored.indicators.map(\.id), [b.id])
        restored.remove(b.id); XCTAssertEqual(library.scripts.map(\.id), [b.id])
    }

    func testQueueWaitsForCancelledWorkAndNeverPublishesOldSymbol() async throws {
        let store = defaults(), library = PineScriptLibrary(defaults: store), probe = PineExecutionProbe()
        let scripts = (0..<3).map { SavedPineScript(name: "Script \($0)", source: "\($0)") }
        scripts.forEach(library.save)
        let workspace = PineScriptWorkspace(defaults: store, library: library, execute: { try await probe.run($0, context: $1) })
        scripts.forEach { workspace.attach($0.id) }; workspace.setInput(input())
        try await wait { await probe.symbols.count == 2 }
        workspace.setInput(input("MSFT")); try await Task.sleep(for: .milliseconds(220))
        let startedBeforeReap = await probe.symbols.count
        XCTAssertEqual(startedBeforeReap, 2, "Cancelled helpers still hold their queue slots")
        await probe.finish(0); try await wait { await probe.symbols.count == 3 }
        XCTAssertFalse(workspace.indicators.contains { $0.status == "loaded" })
        await probe.finish(1); try await wait { await probe.symbols.count == 4 }
        await probe.finish(2); try await wait { await probe.symbols.count == 5 }
        await probe.finish(3); await probe.finish(4)
        try await wait { workspace.indicators.allSatisfy { $0.status == "loaded" && $0.symbol == "MSFT" } }
        let maximum = await probe.maximum
        XCTAssertEqual(maximum, 2)
    }

    func testOneFailureRetryAndLibraryEditAreIndependent() async throws {
        let store = defaults(), library = PineScriptLibrary(defaults: store), probe = PineExecutionProbe()
        var a = SavedPineScript(name: "A", source: "old"), b = SavedPineScript(name: "B", source: "other")
        library.save(a); library.save(b)
        let workspace = PineScriptWorkspace(defaults: store, library: library, execute: { try await probe.run($0, context: $1) })
        workspace.attach(a.id); workspace.attach(b.id); workspace.setInput(input())
        try await wait { await probe.symbols.count == 2 }
        await probe.finish(0, fail: true); await probe.finish(1)
        try await wait { workspace.indicators.first?.status == "error" && workspace.indicators.last?.status == "loaded" }
        workspace.retry(a.id); try await wait { await probe.symbols.count == 3 }; await probe.finish(2)
        try await wait { workspace.indicators.first?.status == "loaded" }
        a.source = "edited"; library.save(a)
        try await wait { await probe.symbols.count == 4 }
        XCTAssertEqual(workspace.indicators.last?.status, "loaded")
        workspace.remove(a.id); await probe.finish(3)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(workspace.indicators.map(\.id), [b.id])
    }

    func testLegacyStyleMigratesAndSurvivesSourceEditsAndRestart() async throws {
        let store = defaults(), library = PineScriptLibrary(defaults: store)
        var script = SavedPineScript(name: "Saved", source: "original source")
        library.save(script)
        var plot = pineTestResult().plots!["same plot"]!
        plot.displayVisible = false; plot.displayLineWidth = 4
        let hash = SHA256.hash(data: Data(script.source.utf8)).map { String(format: "%02x", $0) }.joined()
        let legacy = [plot.id: PinePlotDisplayPreference(plot: plot)]
        store.set(try JSONEncoder().encode(legacy), forKey: "stockdeck.customPineDisplaySettings.\(hash).v1")
        let workspace = PineScriptWorkspace(defaults: store, library: library, execute: { _,_ in pineTestResult() })
        workspace.attach(script.id); workspace.setInput(input())
        try await wait { workspace.indicators.first?.status == "loaded" }
        XCTAssertEqual(workspace.indicators.first?.plots.first?.displayLineWidth, 4)
        script.source = "new source"; library.save(script)
        try await wait { workspace.indicators.first?.status == "loaded" }
        XCTAssertEqual(workspace.indicators.first?.plots.first?.displayVisible, false)
        let restored = PineScriptWorkspace(defaults: store, library: library, execute: { _,_ in pineTestResult() })
        restored.setInput(input()); try await wait { restored.indicators.first?.status == "loaded" }
        XCTAssertEqual(restored.indicators.first?.plots.first?.displayVisible, false)
    }

    func testMissingIntradayDataIsAnErrorAndCanRetryWithoutDailyFallback() async throws {
        let store = defaults(), library = PineScriptLibrary(defaults: store)
        let script = SavedPineScript(name: "A", source: "plot(close)"); library.save(script)
        let workspace = PineScriptWorkspace(defaults: store, library: library, execute: { _,_ in XCTFail("Must not run with missing intraday bars"); return pineTestResult() })
        workspace.attach(script.id)
        workspace.setInput(PineChartInput(symbol: "AAPL", interval: .hour, points: [], dailyPoints: input().points, error: "No intraday data"))
        try await wait { workspace.indicators.first?.status == "error" }
        XCTAssertEqual(workspace.indicators.first?.error, "No intraday data")
        XCTAssertTrue(workspace.indicators.first?.plots.isEmpty == true)
        workspace.retry(script.id); try await wait { workspace.indicators.first?.status == "error" }
    }

    func testSameSourceTitlesNeverShareStyleAcrossDifferentPlotIDs() async throws {
        let store = defaults(), library = PineScriptLibrary(defaults: store)
        let script = SavedPineScript(name: "Duplicate plots", source: "fixture"); library.save(script)
        let plot = CustomPinePlot(style: "line", title: "same", color: "#FF0000", points: [])
        let result = CustomPineRunResult(ok: true, error: nil, title: "fixture",
            plots: ["same": plot, "same#1": plot], alertCount: 0, overlay: true)
        let workspace = PineScriptWorkspace(defaults: store, library: library, execute: { _, _ in result })
        workspace.attach(script.id); workspace.setInput(input())
        try await wait { workspace.indicators.first?.status == "loaded" }
        var first = try XCTUnwrap(workspace.indicators.first?.plots.first { $0.id == "same" })
        first.displayVisible = false; first.displayLineWidth = 4
        workspace.saveStyle([first.id: first], for: script.id)
        let updated = try XCTUnwrap(workspace.indicators.first?.plots)
        XCTAssertEqual(updated.first { $0.id == "same" }?.displayVisible, false)
        XCTAssertEqual(updated.first { $0.id == "same#1" }?.displayVisible, nil)
        XCTAssertEqual(updated.first { $0.id == "same#1" }?.displayLineWidth, nil)
    }

    func testLastRemovalCancelsPreparationAndLateContextCannotRestartPine() async throws {
        let store = defaults(), library = PineScriptLibrary(defaults: store), preparation = PinePreparationProbe(), executor = PineExecutionProbe()
        let script = SavedPineScript(name: "Installed", source: "plot(close)"); library.save(script)
        let workspace = PineScriptWorkspace(defaults: store, library: library,
            prepare: { try await preparation.run($0) }, execute: { try await executor.run($0, context: $1) })
        workspace.attach(script.id); workspace.setInput(input())
        try await wait { await preparation.started == 1 }
        workspace.remove(script.id)
        try await wait { await preparation.cancelled.contains(0) }
        try await preparation.finish(0)
        workspace.setInput(input("MSFT", interval: .week))
        try await Task.sleep(for: .milliseconds(200))
        let calls = await preparation.started, runs = await executor.symbols.count
        XCTAssertEqual(calls, 1); XCTAssertEqual(runs, 0)
        XCTAssertTrue(workspace.indicators.isEmpty); XCTAssertEqual(library.scripts.map(\.id), [script.id])
        workspace.attach(script.id)
        try await wait { await preparation.started == 2 }
        try await preparation.finish(1)
        try await wait { await executor.symbols.count == 1 }
        await executor.finish(0)
        try await wait { workspace.indicators.first?.status == "loaded" }
        // A completed context must also be discarded on final removal.
        workspace.remove(script.id); workspace.attach(script.id)
        try await wait { await preparation.started == 3 }
        try await preparation.finish(2)
        try await wait { await executor.symbols.count == 2 }; await executor.finish(1)
    }

    func testRemoveAllClearsQueuedScriptsAndKeepsMenuLibrary() async throws {
        let store = defaults(), library = PineScriptLibrary(defaults: store), executor = PineExecutionProbe()
        let scripts = (0..<3).map { SavedPineScript(name: "Library \($0)", source: "\($0)") }
        scripts.forEach(library.save)
        let workspace = PineScriptWorkspace(defaults: store, library: library, execute: { try await executor.run($0, context: $1) })
        scripts.forEach { workspace.attach($0.id) }; workspace.setInput(input())
        try await wait { await executor.symbols.count == 2 }
        scripts.forEach { workspace.remove($0.id) }
        await executor.finish(0); await executor.finish(1)
        workspace.setInput(input("MSFT", interval: .month))
        try await Task.sleep(for: .milliseconds(200))
        let count = await executor.symbols.count
        XCTAssertEqual(count, 2, "The third queued script must not start after final removal")
        XCTAssertEqual(workspace.menuItems.count, 3)
        XCTAssertTrue(workspace.menuItems.allSatisfy { !$0.attached })
        var renamed = scripts[0]; renamed.name = "Đã đổi tên"; library.save(renamed)
        XCTAssertEqual(workspace.menuItems.first?.name, "Đã đổi tên")
        library.delete(renamed.id); XCTAssertEqual(workspace.menuItems.count, 2)
    }

    func testRemovalDuringDebounceNeverStartsPreparation() async throws {
        let store = defaults(), library = PineScriptLibrary(defaults: store), preparation = PinePreparationProbe()
        let script = SavedPineScript(name:"A",source:"plot(close)"); library.save(script)
        let workspace = PineScriptWorkspace(defaults:store,library:library,prepare:{ try await preparation.run($0) },execute:{ _,_ in pineTestResult() })
        workspace.attach(script.id);workspace.setInput(input());workspace.remove(script.id)
        try await Task.sleep(for:.milliseconds(200))
        let count = await preparation.started
        XCTAssertEqual(count,0)
    }
}

final class PineExecutionContextTests: XCTestCase {
    @MainActor
    func testMonthlyChartHistoryIsNeverPassedAsDailySecurityData() throws {
        let daily = [pineTestPoint("2026-01-02T15:00:00Z"), pineTestPoint("2026-01-05T15:00:00Z", close: 104),
                     pineTestPoint("2026-01-06T15:00:00Z", close: 106)]
        let monthly = [pineTestPoint("2026-01-01T15:00:00Z", close: 106)]
        let view = LightweightPriceChartView(symbol: "AAPL", points: daily, maxPoints: monthly, currency: "USD",
            visibleFrom: nil, markers: [], targetPrice: nil, isLoading: false, retry: {},
            selectedRange: .constant("All"), showsRangePicker: true, surface: .superchart)
        let input = view.pineInput
        XCTAssertEqual(input.points, monthly, "The All chart can display monthly history")
        XCTAssertEqual(input.dailyPoints, daily, "Daily security requests must retain the actual daily source")
        let context = try PineExecutionContext.prepare(PineChartInput(symbol: input.symbol, interval: .month,
            points: input.points, dailyPoints: input.dailyPoints))
        XCTAssertEqual(context.bars.count, 1)
        XCTAssertEqual(context.datasets["D"]?.count, 3)
        XCTAssertEqual(context.datasets["W"]?.count, 2)
        XCTAssertEqual(context.datasets["D"]?.first?.close, 102)
    }
    func testEveryTimeframeMapsExplicitlyAndPreservesPreparedOHLC() throws {
        let expected = ["5","30","60","240","360","D","W","M","3M","6M","12M"]
        XCTAssertEqual(LightweightChartInterval.allCases.map(\.pineTimeframe), expected)
        let intraday = [pineTestPoint("2026-01-02T14:30:00Z"),pineTestPoint("2026-01-02T14:35:00Z",close:104),pineTestPoint("2026-01-02T15:00:00Z",close:106)]
        let daily = [pineTestPoint("2026-01-02T15:00:00Z"),pineTestPoint("2026-02-02T15:00:00Z",close:104),pineTestPoint("2026-04-01T15:00:00Z",close:106),pineTestPoint("2026-07-01T15:00:00Z",close:108)]
        let counts = [3,2,1,1,1,4,4,4,3,2,1]
        for (index, interval) in LightweightChartInterval.allCases.enumerated() {
            let context = try PineExecutionContext.prepare(PineChartInput(symbol:"AAPL",interval:interval,points:interval.isIntraday ? intraday : daily,dailyPoints:daily))
            XCTAssertEqual(context.bars.count, counts[index], interval.rawValue)
            XCTAssertEqual(context.bars.first?.open, 100, interval.rawValue)
            XCTAssertEqual(context.datasets[interval.pineTimeframe]?.count, context.bars.count)
            XCTAssertEqual(context.timeMap.count, context.bars.count)
            XCTAssertTrue(context.bars.allSatisfy { $0.closeTime > $0.openTime })
        }
        let halfYear = try PineExecutionContext.makeBars(daily,interval:.halfYear,symbol:"AAPL")
        XCTAssertEqual(halfYear[0].close,106);XCTAssertEqual(halfYear[0].high,109);XCTAssertEqual(halfYear[0].low,98);XCTAssertEqual(halfYear[0].volume,30)
    }
    func testSessionAnchorsFollowDSTAndWeekMonthBoundaries() throws {
        let points = [pineTestPoint("2026-03-06T14:35:00Z"),pineTestPoint("2026-03-09T13:35:00Z",close:104)]
        let hourly = try PineExecutionContext.makeBars(points,interval:.hour,symbol:"AAPL")
        XCTAssertEqual(hourly.map(\.openTime), [1772807400000,1773063000000])
        let boundary = [pineTestPoint("2026-01-30T15:00:00Z"),pineTestPoint("2026-02-02T15:00:00Z",close:104)]
        XCTAssertEqual(try PineExecutionContext.makeBars(boundary,interval:.week,symbol:"AAPL").count,2)
        XCTAssertEqual(try PineExecutionContext.makeBars(boundary,interval:.month,symbol:"AAPL").count,2)
    }
    func testMissingOHLCIsNotFabricated() {
        XCTAssertThrowsError(try PineExecutionContext.makeBars([PricePoint(date:Date(),close:100)],interval:.day,symbol:"AAPL"))
    }
    func testAsyncPreparationPropagatesCancellationToWorker() async {
        let point = pineTestPoint("2026-01-02T15:00:00Z")
        let input = PineChartInput(symbol:"AAPL",interval:.day,points:[point],dailyPoints:[point])
        let task = Task.detached { try await PineExecutionContext.prepareAsync(input) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancelled candle preparation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

final class PineProcessLifecycleTests: XCTestCase {
    private final class PIDBox: @unchecked Sendable {
        let lock = NSLock(); var pid: Int32 = 0
        func store(_ value: Int32) { lock.lock(); defer { lock.unlock() }; pid = value }
        func read() -> Int32 { lock.lock(); defer { lock.unlock() }; return pid }
    }
    func testRepeatedShortLivedHelpersFinishAndAreReaped() async throws {
        let pid = PIDBox(), input = Data("Pine lifecycle regression".utf8)
        for _ in 0..<40 {
            let result = try await CustomPineScriptRunner.execute(executable: URL(fileURLWithPath: "/bin/cat"), data: input, onStart: pid.store)
            XCTAssertEqual(result, input)
            XCTAssertEqual(kill(pid.read(), 0), -1); XCTAssertEqual(errno, ESRCH)
        }
    }
    func testCancellationReapsHelperBeforeReturning() async throws {
        let pid = PIDBox()
        let task = Task.detached {
            try await CustomPineScriptRunner.execute(executable: URL(fileURLWithPath:"/bin/sleep"), arguments:["30"], data:Data(), onStart:pid.store)
        }
        while pid.read() == 0 { try await Task.sleep(for:.milliseconds(10)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(kill(pid.read(),0),-1);XCTAssertEqual(errno,ESRCH)
    }
    func testTimeoutKillsHelperIgnoringTerminateAndReapsIt() async throws {
        let pid = PIDBox(), start = Date()
        let task = Task.detached {
            try await CustomPineScriptRunner.execute(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c","trap '' TERM; while :; do :; done"],data:Data(),timeout:0.1,onStart:pid.store)
        }
        do { _ = try await task.value; XCTFail("Expected timeout") } catch { XCTAssertTrue(error.localizedDescription.contains("giới hạn")) }
        XCTAssertLessThan(Date().timeIntervalSince(start),2)
        XCTAssertEqual(kill(pid.read(),0),-1);XCTAssertEqual(errno,ESRCH)
    }
}
