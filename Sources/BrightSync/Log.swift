import Foundation

/// Appends to ~/Library/Logs/BrightSync.log.
///
/// DDC and keyboard taps fail in ways that are invisible from the outside, so
/// the app keeps a plain text record of what it saw and did.
enum Log {
    private static let queue = DispatchQueue(label: "app.brightsync.log")
    private static let maxBytes = 512 * 1024

    private static let url: URL = {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("BrightSync.log")
    }()

    static var path: String { url.path }

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
                // Keep it small; this is a diary, not an archive.
                if let size = try? handle.offset(), size > maxBytes {
                    try? FileHandle(forWritingTo: url).truncate(atOffset: 0)
                }
            } else {
                try? data.write(to: url)
            }
        }
    }
}
