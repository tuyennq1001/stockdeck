import Foundation
import Combine
import CryptoKit

extension LightweightChartInterval {
    var pineTimeframe: String {
        switch self {
        case .fiveMinutes: "5"
        case .thirtyMinutes: "30"
        case .hour: "60"
        case .fourHours: "240"
        case .sixHours: "360"
        case .day: "D"
        case .week: "W"
        case .month: "M"
        case .quarter: "3M"
        case .halfYear: "6M"
        case .year: "12M"
        }
    }
}

struct PineChartInput: Equatable {
    let symbol: String
    let interval: LightweightChartInterval
    let points: [PricePoint]
    let dailyPoints: [PricePoint]
    var loading = false
    var error: String? = nil
}

struct PineExecutionBar: Codable {
    let openTime: Double
    let closeTime: Double
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Double?
    let chartTime: String
}

struct PineExecutionContext {
    let symbol: String
    let interval: LightweightChartInterval
    let timezone: String
    let currency: String
    let bars: [PineExecutionBar]
    let datasets: [String: [PineExecutionBar]]
    let timeMap: [String: String]

    static func prepareAsync(_ input: PineChartInput) async throws -> Self {
        let worker = Task.detached(priority: .userInitiated) { try prepare(input) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func prepare(_ input: PineChartInput) throws -> Self {
        try Task.checkCancellation()
        if let error = input.error { throw CustomPineScriptRunner.RunnerError.message(error) }
        let bars = try makeBars(input.points, interval: input.interval, symbol: input.symbol)
        guard !bars.isEmpty else { throw CustomPineScriptRunner.RunnerError.message("Không có dữ liệu OHLCV cho khung nến này.") }
        var datasets = [input.interval.pineTimeframe: bars]
        for interval in LightweightChartInterval.allCases where interval != input.interval {
            try Task.checkCancellation()
            // Intraday frames may only be built from captured intraday data, never daily closes.
            let source = interval.isIntraday ? (input.interval.isIntraday ? input.points : []) : input.dailyPoints
            if !source.isEmpty, let values = try? makeBars(source, interval: interval, symbol: input.symbol), !values.isEmpty {
                datasets[interval.pineTimeframe] = values
            }
        }
        try Task.checkCancellation()
        return Self(symbol: input.symbol, interval: input.interval,
                    timezone: MarketCategory.marketSchedule(for: input.symbol).timeZone.identifier,
                    currency: StockService.detectedCurrency(for: input.symbol), bars: bars, datasets: datasets,
                    timeMap: bars.reduce(into: [:]) { $0[String(Int($1.openTime / 1000))] = $1.chartTime })
    }

    static func makeBars(_ points: [PricePoint], interval: LightweightChartInterval, symbol: String) throws -> [PineExecutionBar] {
        try Task.checkCancellation()
        let grouped = LightweightChartMath.aggregate(points, interval: interval, symbol: symbol)
        try Task.checkCancellation()
        guard grouped.count <= 20_000 else { throw CustomPineScriptRunner.RunnerError.message("Script hỗ trợ tối đa 20.000 nến.") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MarketCategory.marketSchedule(for: symbol).timeZone
        return try grouped.map { point in
            try Task.checkCancellation()
            guard let open = point.open, let high = point.high, let low = point.low,
                  [open, high, low, point.close].allSatisfy(\.isFinite), high >= max(open, point.close), low <= min(open, point.close) else {
                throw CustomPineScriptRunner.RunnerError.message("Nguồn giá thiếu OHLC cho script ở khung \(interval.label).")
            }
            let end: Date
            if let seconds = interval.seconds { end = point.date.addingTimeInterval(Double(seconds)) }
            else {
                switch interval {
                case .day: end = calendar.date(byAdding: .day, value: 1, to: point.date)!
                case .week: end = calendar.dateInterval(of: .weekOfYear, for: point.date)!.end
                default:
                    let months = interval == .quarter ? 3 : interval == .halfYear ? 6 : interval == .year ? 12 : 1
                    let start = calendar.dateInterval(of: .month, for: point.date)!.start
                    end = calendar.date(byAdding: .month, value: months, to: start)!
                }
            }
            return PineExecutionBar(openTime: point.date.timeIntervalSince1970 * 1000,
                                    closeTime: end.timeIntervalSince1970 * 1000,
                                    open: open, high: high, low: low, close: point.close, volume: point.volume,
                                    chartTime: LightweightChartMath.chartTime(point.date, interval: interval, symbol: symbol))
        }
    }
}

struct PineScriptMenuItem: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let attached: Bool
}

struct CustomPineIndicator: Codable, Identifiable {
    let id: UUID
    let title: String
    let overlay: Bool
    let status: String
    let error: String?
    let plots: [CustomPinePlot]
    let timeMap: [String: String]
    let symbol: String?
    let interval: String?
}

@MainActor
final class PineScriptWorkspace: ObservableObject {
    typealias Executor = (String, PineExecutionContext) async throws -> CustomPineRunResult
    typealias Preparer = (PineChartInput) async throws -> PineExecutionContext
    let library: PineScriptLibrary
    @Published private(set) var activeIDs: [UUID] = []
    @Published private(set) var indicators: [CustomPineIndicator] = []
    @Published private(set) var menuItems: [PineScriptMenuItem] = []
    private let defaults: UserDefaults
    private let execute: Executor
    private let prepare: Preparer
    private var subscription: AnyCancellable?
    private var snapshot: [SavedPineScript] = []
    private var input: PineChartInput?
    private var context: PineExecutionContext?
    private var contextError: String?
    private var contextID = UUID()
    private var preparation: Task<Void, Never>?
    private var pending: [UUID] = []
    private var running: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
    private var tokens: [UUID: UUID] = [:]
    private var results: [UUID: CustomPineRunResult] = [:]
    private var errors: [UUID: String] = [:]
    private var preferences: [UUID: [String: PinePlotDisplayPreference]] = [:]
    private let activeKey = "stockdeck.superchart.activePineScripts.v1"

    init(defaults: UserDefaults = .standard, library: PineScriptLibrary? = nil,
         prepare: @escaping Preparer = { try await PineExecutionContext.prepareAsync($0) },
         execute: @escaping Executor = { try await CustomPineScriptRunner.run(source: $0, context: $1) }) {
        self.defaults = defaults
        self.library = library ?? PineScriptLibrary(defaults: defaults)
        self.execute = execute
        self.prepare = prepare
        snapshot = self.library.scripts
        let valid = Set(snapshot.map(\.id))
        var seen = Set<UUID>()
        activeIDs = (defaults.stringArray(forKey: activeKey) ?? []).compactMap(UUID.init(uuidString:))
            .filter { valid.contains($0) && seen.insert($0).inserted }
        persistActive()
        subscription = self.library.$scripts.sink { [weak self] in self?.reconcile($0) }
        publish()
    }

    func attach(_ id: UUID) {
        guard library.scripts.contains(where: { $0.id == id }), !activeIDs.contains(id) else { return }
        activeIDs.append(id); persistActive()
        if context == nil, let input { self.input = nil; setInput(input) }
        enqueue(id); publish()
    }
    func remove(_ id: UUID) {
        activeIDs.removeAll { $0 == id }; invalidate(id)
        results[id] = nil; errors[id] = nil
        if activeIDs.isEmpty {
            preparation?.cancel(); preparation = nil
            contextID = UUID(); context = nil; contextError = nil
            pending = []; tokens = [:]; results = [:]; errors = [:]
        }
        persistActive(); publish()
    }
    func retry(_ id: UUID) {
        guard activeIDs.contains(id) else { return }
        if context == nil, let input { self.input = nil; setInput(input) }
        else { enqueue(id) }
    }
    func setInput(_ value: PineChartInput) {
        guard input != value else { return }
        input = value; preparation?.cancel(); contextID = UUID(); context = nil; contextError = nil
        for id in activeIDs { invalidate(id) }
        results = [:]; errors = [:]; publish()
        guard !value.loading, !activeIDs.isEmpty else { return }
        let revision = contextID, prepare = prepare
        preparation = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(150))
                let prepared = try await prepare(value)
                guard let self, !Task.isCancelled, self.contextID == revision else { return }
                self.context = prepared
                for id in self.activeIDs { self.enqueue(id) }
                self.publish()
            } catch {
                guard let self, !Task.isCancelled, self.contextID == revision else { return }
                self.contextError = error.localizedDescription
                for id in self.activeIDs { self.errors[id] = error.localizedDescription }
                self.publish()
            }
        }
    }

    func saveStyle(_ plots: [String: CustomPinePlot], for id: UUID) {
        guard activeIDs.contains(id) else { return }
        let values = plots.values.reduce(into: [String: PinePlotDisplayPreference]()) { $0[$1.id] = PinePlotDisplayPreference(plot: $1) }
        preferences[id] = values
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: styleKey(id)) }
        publish()
    }

    private func reconcile(_ scripts: [SavedPineScript]) {
        let valid = Set(scripts.map(\.id))
        for id in activeIDs where !valid.contains(id) { remove(id) }
        let changed = scripts.filter { script in snapshot.first(where: { $0.id == script.id })?.source != script.source }
        snapshot = scripts
        for script in changed where activeIDs.contains(script.id) { enqueue(script.id) }
        publish()
    }
    private func invalidate(_ id: UUID) {
        tokens[id] = UUID(); pending.removeAll { $0 == id }
        for job in running.values where job.id == id { job.task.cancel() }
    }
    private func enqueue(_ id: UUID) {
        invalidate(id); results[id] = nil; errors[id] = nil
        if context != nil { pending.append(id) }
        else if let contextError { errors[id] = contextError }
        publish(); pump()
    }
    private func pump() {
        guard let context else { return }
        while running.count < 2, !pending.isEmpty {
            let id = pending.removeFirst()
            guard activeIDs.contains(id), let script = snapshot.first(where: { $0.id == id }) else { continue }
            let token = UUID(), revision = contextID, executor = execute
            tokens[id] = token
            let task = Task { [weak self] in
                let outcome: Result<CustomPineRunResult, Error>
                do { outcome = .success(try await executor(script.source, context)) }
                catch { outcome = .failure(error) }
                guard let self else { return }
                self.running[token] = nil
                if !Task.isCancelled, self.tokens[id] == token, self.contextID == revision, self.activeIDs.contains(id) {
                    switch outcome {
                    case .success(let result):
                        if result.ok { self.results[id] = result }
                        else { self.errors[id] = result.error ?? "Script không chạy được." }
                    case .failure(let error): self.errors[id] = error.localizedDescription
                    }
                }
                self.publish(); self.pump()
            }
            running[token] = (id, task)
        }
    }
    private func persistActive() { defaults.set(activeIDs.map(\.uuidString), forKey: activeKey) }
    deinit {
        preparation?.cancel()
        for job in running.values { job.task.cancel() }
    }
    private func styleKey(_ id: UUID) -> String { "stockdeck.customPineStyle.\(id.uuidString).v1" }
    private func style(for script: SavedPineScript) -> [String: PinePlotDisplayPreference] {
        if let value = preferences[script.id] { return value }
        let hash = SHA256.hash(data: Data(script.source.utf8)).map { String(format: "%02x", $0) }.joined()
        let legacy = "stockdeck.customPineDisplaySettings.\(hash).v1"
        let data = defaults.data(forKey: styleKey(script.id)) ?? defaults.data(forKey: legacy)
        let value = data.flatMap { try? JSONDecoder().decode([String: PinePlotDisplayPreference].self, from: $0) } ?? [:]
        preferences[script.id] = value
        if let data { defaults.set(data, forKey: styleKey(script.id)) }
        return value
    }
    private func publish() {
        let attached = Set(activeIDs)
        menuItems = snapshot.map { PineScriptMenuItem(id: $0.id, name: $0.name, attached: attached.contains($0.id)) }
        let times = context?.timeMap ?? [:]
        indicators = activeIDs.compactMap { id in
            guard let script = snapshot.first(where: { $0.id == id }) else { return nil }
            let result = results[id], prefs = style(for: script)
            let plots = (result?.plots ?? [:]).keys.sorted().compactMap { key -> CustomPinePlot? in
                guard var plot = result?.plots?[key] else { return nil }
                plot.plotID = key
                return prefs[key]?.apply(to: plot) ?? plot
            }
            return CustomPineIndicator(id: id, title: result?.title ?? script.name, overlay: result?.overlay ?? true,
                                       status: errors[id] != nil ? "error" : result != nil ? "loaded" : "loading",
                                       error: errors[id], plots: plots, timeMap: times, symbol: input?.symbol, interval: input?.interval.rawValue)
        }
    }
}
