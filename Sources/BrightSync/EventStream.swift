import Foundation

/// Splits a server-sent event stream into each event's data. Chunks may end
/// anywhere, so partial lines are kept until the rest arrives.
struct EventStreamParser {
    private var buffer: [UInt8] = []
    private var data: [String] = []

    /// Returns the data of every event completed by this chunk.
    mutating func feed(_ chunk: Data) -> [String] {
        buffer.append(contentsOf: chunk)
        var events: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[..<newline]
            if line.last == 0x0D {
                line = line.dropLast()
            }
            let text = String(decoding: line, as: UTF8.self)
            buffer.removeFirst(newline + 1)
            if text.isEmpty {
                // A blank line ends the event.
                if !data.isEmpty {
                    events.append(data.joined(separator: "\n"))
                    data = []
                }
            } else if text.hasPrefix("data:") {
                var value = text.dropFirst(5)
                if value.first == " " {
                    value = value.dropFirst()
                }
                data.append(String(value))
            }
            // Comments (":") and the id, event and retry fields are not needed.
        }
        return events
    }
}
