import XCTest
@testable import StockDeck

final class PersistenceWriterTests: XCTestCase {
    func testOlderRevisionCannotOverwriteNewerSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stockdeck-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("snapshot.json")
        let writer = PersistenceWriter()
        try await writer.write(Data("latest".utf8), to: destination, revision: 2)
        try await writer.write(Data("stale".utf8), to: destination, revision: 1)

        XCTAssertEqual(try Data(contentsOf: destination), Data("latest".utf8))
    }
}
