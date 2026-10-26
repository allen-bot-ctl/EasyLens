import Foundation

// Metadata-only JSONL trace for the local lens experiment. Never stores OCR text
// or screen images. Every event carries a run ID so repeated launches can be
// summarized independently.
@MainActor
final class ProbeLogger {
    let runID = UUID().uuidString
    let path: String
    private let handle: FileHandle?

    init() {
        let directory = Bundle.main.bundleURL.deletingLastPathComponent()
        path = directory.appendingPathComponent("lens-probe-\(runID).jsonl").path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
        handle?.seekToEndOfFile()
    }

    func event(_ name: String, _ fields: [String: Any] = [:]) {
        var record: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "run_id": runID,
            "event": name
        ]
        for (key, value) in fields { record[key] = value }
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              let handle else { return }
        handle.write(data)
        handle.write(Data([0x0A]))
    }
}
