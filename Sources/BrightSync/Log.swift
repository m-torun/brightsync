import Foundation

/// Appends to ~/Library/Logs/BrightSync.log.
///
/// DDC failures are invisible from the outside — a write is accepted and
/// quietly ignored, a read returns noise — so the app keeps a plain text
/// record of every transaction and every display event. When the file passes
/// 1 MB it moves to BrightSync.log.1, so the lines before a hang survive.
enum Log {
    private static let queue = DispatchQueue(label: "app.brightsync.log")
    private static let maxBytes = 1024 * 1024

    private static let url: URL = {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("BrightSync.log")
    }()

    static var path: String { url.path }

    /// Waits for pending lines to reach the file, for a process about to exit.
    static func flush() {
        queue.sync {}
    }

    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp)  \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                if (try? handle.seekToEnd()) != nil {
                    try? handle.write(contentsOf: data)
                }
                if let size = try? handle.offset(), size > maxBytes {
                    let previous = url.appendingPathExtension("1")
                    try? FileManager.default.removeItem(at: previous)
                    try? FileManager.default.moveItem(at: url, to: previous)
                }
            } else {
                try? data.write(to: url)
            }
        }
    }
}
