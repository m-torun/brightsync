import CoreAudio
import CoreGraphics
import CoreMediaIO
import Foundation
import IOKit.pwr_mgt
import os

/// Things macOS does not announce as events but that still make DDC traffic
/// unwise, checked on demand by the gate before every transaction.
enum HoldConditions {
    /// The conditions the app uses, in the order they are reported.
    static func all() -> [() -> String?] {
        [
            { Preferences.pauseDuringCalls && CaptureDevices.inUse() ? "camera or microphone in use" : nil },
            { IdleDisplaySleep.isImminent() ? "displays about to sleep" : nil },
        ]
    }
}

/// Whether any app is using a camera or the microphone, i.e. most likely a
/// call. A video call with many tiles keeps the display coprocessor that also
/// carries DDC at its busiest. Reading these properties needs no permission
/// and does not open the devices.
enum CaptureDevices {
    static func inUse() -> Bool {
        cameraInUse() || microphoneInUse()
    }

    static func cameraInUse() -> Bool {
        var address = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &size, &devices) == 0 else { return false }
        address.mSelector = CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)
        return devices.contains { device in
            var running: UInt32 = 0
            var length = UInt32(MemoryLayout<UInt32>.size)
            return CMIOObjectGetPropertyData(device, &address, 0, nil, length, &length, &running) == 0 && running != 0
        }
    }

    static func microphoneInUse() -> Bool {
        if #available(macOS 14.2, *) {
            // Per process, so a headset playing music does not count.
            return audioObjects(kAudioHardwarePropertyProcessObjectList).contains { process in
                flag(process, kAudioProcessPropertyIsRunningInput)
            }
        }
        // Older systems only say whether a device runs at all, so only
        // input-only devices are telling.
        return audioObjects(kAudioHardwarePropertyDevices).contains { device in
            streams(device, kAudioObjectPropertyScopeInput) > 0
                && streams(device, kAudioObjectPropertyScopeOutput) == 0
                && flag(device, kAudioDevicePropertyDeviceIsRunningSomewhere)
        }
    }

    private static func audioObjects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private static func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private static func streams(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }
}

/// Whether macOS is about to put the displays to sleep for inactivity.
/// Display sleep is only announced once it has happened, so the gate holds
/// off for the last stretch of the idle timer instead.
enum IdleDisplaySleep {
    /// How long before the idle timer runs out to stop sending.
    static let margin: TimeInterval = 15

    static func isImminent() -> Bool {
        guard let timeout = timeout(), !displaySleepPrevented() else { return false }
        return idleSeconds() >= timeout - margin
    }

    static func idleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0) ?? .null)
    }

    /// True while an app (a video player, a call) keeps the display awake.
    static func displaySleepPrevented() -> Bool {
        var status: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&status) == kIOReturnSuccess,
              let assertions = status?.takeRetainedValue() as? [String: Int] else { return false }
        return (assertions[kIOPMAssertPreventUserIdleDisplaySleep as String] ?? 0) > 0
    }

    private static let cache = OSAllocatedUnfairLock<(value: TimeInterval?, read: TimeInterval)>(initialState: (nil, -.infinity))

    /// The display sleep timer in seconds, or nil when it is off. macOS has
    /// no public API for it, so `pmset -g` is asked, at most every 5 minutes.
    static func timeout() -> TimeInterval? {
        let now = DisplayGate.uptime()
        if let cached = cache.withLock({ now - $0.read < 300 ? $0 : nil }) {
            return cached.value
        }
        let value = readTimeout()
        cache.withLock { $0 = (value, now) }
        return value
    }

    private static func readTimeout() -> TimeInterval? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return parseTimeout(output)
    }

    /// Minutes from the ` displaysleep  10` line; 0 means never.
    static func parseTimeout(_ pmset: String) -> TimeInterval? {
        for line in pmset.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if fields.first == "displaysleep", fields.count > 1, let minutes = Double(fields[1]) {
                return minutes > 0 ? minutes * 60 : nil
            }
        }
        return nil
    }
}
