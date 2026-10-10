import Foundation

/// Serializes atomic local writes and rejects snapshots older than a newer
/// revision already accepted by the writer.
actor PersistenceWriter {
    private var newestRevisionByFile: [URL: UInt64] = [:]

    func write(_ data: Data, to fileURL: URL, revision: UInt64) throws {
        guard revision >= (newestRevisionByFile[fileURL] ?? 0) else { return }
        newestRevisionByFile[fileURL] = revision
        let backupURL = fileURL.appendingPathExtension("bak")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: backupURL)
            try FileManager.default.copyItem(at: fileURL, to: backupURL)
        }
        try data.write(to: fileURL, options: .atomic)
    }
}
