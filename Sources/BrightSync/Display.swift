import CoreGraphics
import DDCKit
import Foundation

/// An external display that can be addressed over DDC.
struct Display: Equatable {
    let id: CGDirectDisplayID
    let name: String
    let edidUUID: String

    /// Stable identity across reboots and reconnections. Display IDs are not
    /// stable, so preferences are keyed on the EDID UUID where we have one.
    var key: String {
        edidUUID.isEmpty ? "display-id:\(id)" : edidUUID
    }
}

enum ReadResult: Equatable {
    case value(current: Int, max: Int)
    /// The display answered that it has no such feature. Asking again is pointless.
    case unsupported
    case failed(String)
}

/// Everything that touches the displays. Only `read` and `write` send
/// anything over DDC; the rest asks macOS.
protocol DisplayBus: AnyObject {
    /// Re-resolves the DDC-capable displays from the I/O registry.
    func enumerate() -> [Display]
    /// Online and awake, by macOS's own account.
    func isAvailable(_ display: Display) -> Bool
    func read(_ display: Display, _ vcp: Int32) -> ReadResult
    func write(_ display: Display, _ vcp: Int32, _ value: Int) -> Bool
}

/// The real bus. Owns the DDC service handles and logs every transaction, so
/// that the log shows exactly what was sent, when, and how long it took.
final class DDCBus: DisplayBus {
    private struct Transport {
        let service: UnsafeMutableRawPointer
        let chipAddress: UInt32
    }

    private var transports: [CGDirectDisplayID: Transport] = [:]
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void = Log.write) {
        self.log = log
    }

    deinit {
        release()
    }

    func enumerate() -> [Display] {
        release()
        var buffer = [DDCKitDisplay](repeating: DDCKitDisplay(), count: Int(DDCKIT_MAX_DISPLAYS))
        let count = ddckit_enumerate(&buffer, Int32(DDCKIT_MAX_DISPLAYS))
        return buffer.prefix(Int(count)).compactMap { entry in
            guard let service = entry.service else { return nil }
            transports[entry.displayID] = Transport(service: service, chipAddress: entry.chipAddress)
            return Display(id: entry.displayID,
                           name: string(from: entry.productName),
                           edidUUID: string(from: entry.edidUUID))
        }
    }

    func isAvailable(_ display: Display) -> Bool {
        CGDisplayIsOnline(display.id) != 0 && CGDisplayIsAsleep(display.id) == 0
    }

    func read(_ display: Display, _ vcp: Int32) -> ReadResult {
        guard let transport = transports[display.id] else { return .failed("no DDC service") }
        var current: UInt16 = 0
        var maximum: UInt16 = 0
        let started = DispatchTime.now()
        let code = ddckit_read(transport.service, transport.chipAddress, UInt8(vcp), &current, &maximum)
        let result: ReadResult
        switch code {
        case DDCKIT_OK where maximum > 0: result = .value(current: Int(current), max: Int(maximum))
        case DDCKIT_OK: result = .failed("reported a maximum of 0")
        case DDCKIT_UNSUPPORTED: result = .unsupported
        default: result = .failed(Self.describe(code))
        }
        let outcome: String
        switch result {
        case let .value(current, max): outcome = "\(current)/\(max)"
        case .unsupported: outcome = "unsupported"
        case let .failed(reason): outcome = "failed: \(reason)"
        }
        log("ddc read  \(display.name) \(hex(vcp)) → \(outcome) (\(milliseconds(since: started)) ms)")
        return result
    }

    func write(_ display: Display, _ vcp: Int32, _ value: Int) -> Bool {
        guard let transport = transports[display.id] else { return false }
        let started = DispatchTime.now()
        let code = ddckit_write(transport.service, transport.chipAddress, UInt8(vcp), UInt16(max(0, value)))
        let outcome = code == DDCKIT_OK ? "sent" : "failed: \(Self.describe(code))"
        log("ddc write \(display.name) \(hex(vcp)) = \(value) → \(outcome) (\(milliseconds(since: started)) ms)")
        return code == DDCKIT_OK
    }

    func release() {
        for transport in transports.values {
            ddckit_release(transport.service)
        }
        transports = [:]
    }

    private static func describe(_ code: DDCKitResult) -> String {
        switch code {
        case DDCKIT_SEND_FAILED: return "request not sent"
        case DDCKIT_READ_FAILED: return "no reply"
        case DDCKIT_BAD_REPLY: return "invalid reply"
        default: return "error \(code.rawValue)"
        }
    }

    private func hex(_ vcp: Int32) -> String {
        String(format: "0x%02X", vcp)
    }

    private func milliseconds(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    /// C fixed-size char arrays arrive as tuples; the parameter must stay
    /// generic so the bytes are the tuple's own storage and not an `Any` box.
    private func string<Field>(from field: Field) -> String {
        var value = field
        return withUnsafePointer(to: &value) { pointer in
            String(cString: UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self))
        }
    }
}
