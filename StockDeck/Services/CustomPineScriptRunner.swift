import Foundation
import Combine
import Darwin

struct CustomPinePlot: Codable, Identifiable {
    struct Point: Codable {
        let time: Double
        let value: Double?
        let color: String?
        let shape: Bool?
        let state: Bool?
        let position: String?
        let markerShape: String?
    }
    let style: String
    let title: String
    let color: String?
    let points: [Point]
    var plotID: String? = nil
    var sourceOrder: Int? = nil
    var isUnnamed: Bool? = nil
    var lineWidth: Int? = nil
    var displayVisible: Bool? = nil
    var displayColorOverrides: [String: String]? = nil
    var displayMarkerShape: String? = nil
    var displayPosition: String? = nil
    var displayLineWidth: Int? = nil
    var id: String { plotID ?? title }
    var renderedPointCount: Int {
        switch style {
        case "shape": points.filter { $0.shape == true }.count
        case "barcolor": points.filter { $0.color != nil }.count
        default: points.filter { $0.value != nil }.count
        }
    }
}

struct CustomPineRunResult: Decodable {
    let ok: Bool
    let error: String?
    let title: String?
    let plots: [String: CustomPinePlot]?
    let alertCount: Int?
    let overlay: Bool?
}

struct PinePlotDisplayPreference: Codable {
    var visible: Bool?
    var colorOverrides: [String: String]?
    var markerShape: String?
    var position: String?
    var lineWidth: Int?

    init(plot: CustomPinePlot) {
        visible = plot.displayVisible
        colorOverrides = plot.displayColorOverrides
        markerShape = plot.displayMarkerShape
        position = plot.displayPosition
        lineWidth = plot.displayLineWidth
    }

    func apply(to plot: CustomPinePlot) -> CustomPinePlot {
        var value = plot
        value.displayVisible = visible
        value.displayColorOverrides = colorOverrides
        value.displayMarkerShape = markerShape
        value.displayPosition = position
        value.displayLineWidth = lineWidth
        return value
    }
}

enum CustomPineScriptRunner {
    private static let ignoreBrokenPipe: Void = { signal(SIGPIPE, SIG_IGN) }()
    struct Job: Encodable {
        let symbol: String
        let timezone: String
        let currency: String
        let source: String
        let timeframe: String
        let bars: [PineExecutionBar]
        let datasets: [String: [PineExecutionBar]]
    }

    static func run(source: String, context: PineExecutionContext) async throws -> CustomPineRunResult {
        guard source.utf8.count <= 128_000 else { throw RunnerError.message("Source tối đa 128 KB.") }
        guard !context.bars.isEmpty else { throw RunnerError.message("Không có nến OHLCV để chạy script.") }
        let worker = Task.detached(priority: .userInitiated) {
            let data = try JSONEncoder().encode(Job(symbol: context.symbol, timezone: context.timezone,
                currency: context.currency, source: source, timeframe: context.interval.pineTimeframe,
                bars: context.bars, datasets: context.datasets))
            guard let executable = Bundle.main.url(forAuxiliaryExecutable: "PineScriptRunner") else {
                throw RunnerError.message("App chưa đóng gói PineScriptRunner.")
            }
            let resultData = try await execute(executable: executable, data: data)
            let result = try JSONDecoder().decode(CustomPineRunResult.self, from: resultData)
            guard result.ok else { throw RunnerError.message(result.error ?? "Pine Script không chạy được.") }
            return result
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    // A queue slot is held until this function has reaped its helper, including cancellation.
    static func execute(executable: URL, arguments: [String] = [], data: Data, timeout: TimeInterval = 5,
                        onStart: @escaping (Int32) -> Void = { _ in }) async throws -> Data {
        try Task.checkCancellation()
        let cancellation = ProcessCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Foundation Process registers a run loop at launch. Keep launch, polling and
                // waitUntilExit on one background thread; async task resumption can change threads.
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try executeBlocking(executable: executable, arguments: arguments, data: data,
                                            timeout: timeout, cancellation: cancellation, onStart: onStart)
                    })
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private final class ProcessCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func check() throws {
            lock.lock(); let value = cancelled; lock.unlock()
            if value { throw CancellationError() }
        }
    }

    // Semaphore publication makes the completed read visible to the process owner thread.
    private final class PipeOutput: @unchecked Sendable {
        private let completed = DispatchSemaphore(value: 0)
        private var data = Data()
        init(_ handle: FileHandle) {
            DispatchQueue.global(qos: .utility).async { [self] in
                data = handle.readDataToEndOfFile(); completed.signal()
            }
        }
        func read() -> Data { completed.wait(); return data }
    }

    private static func executeBlocking(executable: URL, arguments: [String], data: Data, timeout: TimeInterval,
                                        cancellation: ProcessCancellation, onStart: (Int32) -> Void) throws -> Data {
        try cancellation.check()
        _ = ignoreBrokenPipe
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        onStart(process.processIdentifier)
        defer {
            stopAndReap(process)
            try? input.fileHandleForWriting.close()
        }
        let read = PipeOutput(output.fileHandleForReading), readErrors = PipeOutput(errors.fileHandleForReading)
        let written = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            try? input.fileHandleForWriting.write(contentsOf: data)
            try? input.fileHandleForWriting.close()
            written.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            try cancellation.check()
            Thread.sleep(forTimeInterval: 0.01)
        }
        try cancellation.check()
        guard !process.isRunning else { throw RunnerError.message("Script vượt giới hạn 5 giây và đã bị dừng.") }
        written.wait()
        let resultData = read.read()
        _ = readErrors.read()
        guard process.terminationStatus == 0 else {
            let result = try? JSONDecoder().decode(CustomPineRunResult.self, from: resultData)
            throw RunnerError.message(result?.error ?? "Pine Script không chạy được.")
        }
        return resultData
    }

    private static func stopAndReap(_ process: Process) {
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(0.25)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
    }

    enum RunnerError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}

struct SavedPineScript: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var source: String
}

@MainActor
final class PineScriptLibrary: ObservableObject {
    @Published private(set) var scripts: [SavedPineScript] = []
    private let key = "stockdeck.customPineScripts.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let scripts = try? JSONDecoder().decode([SavedPineScript].self, from: data) { self.scripts = scripts }
    }
    func save(_ script: SavedPineScript) {
        if let index = scripts.firstIndex(where: { $0.id == script.id }) { scripts[index] = script }
        else { scripts.append(script) }
        persist()
    }
    func delete(_ id: UUID) { scripts.removeAll { $0.id == id }; persist() }
    private func persist() {
        if let data = try? JSONEncoder().encode(scripts) { defaults.set(data, forKey: key) }
    }
}
