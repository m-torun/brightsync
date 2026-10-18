import CoreGraphics
import DDCKit
import Foundation

/// A DDC-addressable external display.
struct Display {
    let id: CGDirectDisplayID
    let name: String
    let edidUUID: String
    let chipAddress: UInt32
    let service: UnsafeMutableRawPointer

    /// Stable identity across reboots and reconnections. Display IDs are not
    /// stable, so preferences are keyed on the EDID UUID where we have one.
    var key: String {
        edidUUID.isEmpty ? "display-id:\(id)" : edidUUID
    }

    func readBrightness() -> (current: Int, max: Int)? {
        read(DDCKIT_VCP_BRIGHTNESS)
    }

    func read(_ vcp: Int32) -> (current: Int, max: Int)? {
        var current: UInt16 = 0
        var maximum: UInt16 = 0
        guard ddckit_read(service, chipAddress, UInt8(vcp), &current, &maximum), maximum > 0 else {
            return nil
        }
        return (Int(current), Int(maximum))
    }

    @discardableResult
    func writeBrightness(_ value: Int) -> Bool {
        ddckit_write(service, chipAddress, UInt8(DDCKIT_VCP_BRIGHTNESS), UInt16(max(0, value)))
    }
}

/// Owns the DDC service handles and re-enumerates when displays change.
final class DisplayStore {
    private(set) var displays: [Display] = []

    func refresh() {
        release()
        var buffer = [DDCKitDisplay](repeating: DDCKitDisplay(), count: Int(DDCKIT_MAX_DISPLAYS))
        let count = ddckit_enumerate(&buffer, Int32(DDCKIT_MAX_DISPLAYS))
        displays = buffer.prefix(Int(count)).compactMap { entry in
            guard let service = entry.service else { return nil }
            return Display(
                id: entry.displayID,
                name: string(from: entry.productName),
                edidUUID: string(from: entry.edidUUID),
                chipAddress: entry.chipAddress,
                service: service
            )
        }
    }

    func release() {
        for display in displays {
            ddckit_release(display.service)
        }
        displays = []
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
