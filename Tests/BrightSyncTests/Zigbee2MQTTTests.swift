import Foundation
import Testing
@testable import BrightSync

struct Zigbee2MQTTAddressTests {
    @Test func aBareHostGetsTheDefaultPort() {
        #expect(Zigbee2MQTT.socketURL(for: "192.168.1.10")?.absoluteString == "ws://192.168.1.10:8080/api")
        #expect(Zigbee2MQTT.socketURL(for: " z2m.local:8781 ")?.absoluteString == "ws://z2m.local:8781/api")
    }

    @Test func thePageAddressFromTheBrowserWorks() {
        #expect(Zigbee2MQTT.socketURL(for: "http://z2m.local:8781/#/")?.absoluteString == "ws://z2m.local:8781/api")
        #expect(Zigbee2MQTT.socketURL(for: "https://home.example/zigbee/")?.absoluteString == "wss://home.example/zigbee/api")
        #expect(Zigbee2MQTT.socketURL(for: "ws://z2m.local:8080/api")?.absoluteString == "ws://z2m.local:8080/api")
    }

    @Test func unusableAddressesAreRefused() {
        #expect(Zigbee2MQTT.socketURL(for: "") == nil)
        #expect(Zigbee2MQTT.socketURL(for: "ftp://z2m.local") == nil)
        #expect(Zigbee2MQTT.label(for: "http://z2m.local:8781/#/") == "z2m.local:8781")
    }
}

struct Zigbee2MQTTModelTests {
    /// Trimmed from a real `bridge/devices` message: the coordinator, an
    /// unnamed presence sensor with illuminance at the top level, a renamed
    /// sensor with it nested in features, a plug, and a disabled sensor.
    static let devices = """
    {"topic": "bridge/devices", "payload": [
      {"ieee_address": "0x00124b0000000001", "friendly_name": "Coordinator", "type": "Coordinator", "definition": null},
      {"ieee_address": "0x00124B0000000002", "friendly_name": "0x00124b0000000002", "type": "Router",
       "definition": {"model": "3RPL01084Z", "vendor": "Third Reality", "description": "Multi-function smart presence sensor R3",
                      "exposes": [{"type": "binary", "property": "occupancy"}, {"type": "numeric", "property": "illuminance", "unit": "lx"}]}},
      {"ieee_address": "0x00124b0000000003", "friendly_name": "Hall sensor", "type": "EndDevice", "disabled": false,
       "definition": {"model": "X", "exposes": [{"type": "composite", "features": [{"type": "numeric", "property": "illuminance_lux"}]}]}},
      {"ieee_address": "0x00124b0000000004", "friendly_name": "Lamp plug", "type": "Router",
       "definition": {"model": "P", "exposes": [{"type": "switch", "features": [{"type": "binary", "property": "state"}]}]}},
      {"ieee_address": "0x00124b0000000005", "friendly_name": "Old sensor", "disabled": true,
       "definition": {"model": "Y", "exposes": [{"type": "numeric", "property": "illuminance"}]}}
    ]}
    """

    @Test func onlyDevicesThatReportLightAreSensors() {
        guard case let .devices(list) = Zigbee2MQTT.parse(Self.devices) else {
            Issue.record("not parsed as a device list")
            return
        }
        #expect(list == [
            Zigbee2MQTT.Device(ieee: "0x00124b0000000002", friendlyName: "0x00124b0000000002", name: "Multi-function smart presence sensor R3"),
            Zigbee2MQTT.Device(ieee: "0x00124b0000000003", friendlyName: "Hall sensor", name: "Hall sensor"),
        ])
    }

    @Test func luxComesFromEitherVersionsProperty() {
        #expect(Zigbee2MQTT.lux(from: ["illuminance": 28, "occupancy": true]) == 28)
        // Zigbee2MQTT 1: `illuminance` was raw, `illuminance_lux` the lux.
        #expect(Zigbee2MQTT.lux(from: ["illuminance": 30001, "illuminance_lux": 1000]) == 1000)
        #expect(Zigbee2MQTT.lux(from: ["occupancy": true]) == nil)
    }

    @Test func messagesAreToldApart() {
        guard case let .state(name, state) = Zigbee2MQTT.parse(#"{"topic": "Hall sensor", "payload": {"illuminance": 12}}"#) else {
            Issue.record("state not parsed")
            return
        }
        #expect(name == "Hall sensor")
        #expect(Zigbee2MQTT.lux(from: state) == 12)
        guard case let .availability(device, online) = Zigbee2MQTT.parse(#"{"topic": "Hall sensor/availability", "payload": {"state": "offline"}}"#),
              case let .availability(_, legacyOnline) = Zigbee2MQTT.parse(#"{"topic": "Hall sensor/availability", "payload": "online"}"#) else {
            Issue.record("availability not parsed")
            return
        }
        #expect(device == "Hall sensor" && !online && legacyOnline)
        guard case .other = Zigbee2MQTT.parse(#"{"topic": "bridge/logging", "payload": {"level": "info", "message": "x"}}"#),
              case .other = Zigbee2MQTT.parse("not json") else {
            Issue.record("other messages not ignored")
            return
        }
    }

    @Test func lastSeenIsUsedWhenTheServerSendsIt() {
        #expect(Zigbee2MQTT.lastSeen(["last_seen": 1_792_767_422_299]) == Date(timeIntervalSince1970: 1_792_767_422.299))
        #expect(Zigbee2MQTT.lastSeen(["last_seen": "2026-10-23T14:57:02.299Z"]) == Date(timeIntervalSince1970: 1_792_767_422.299))
        #expect(Zigbee2MQTT.lastSeen([:]) == nil)
    }
}

struct Zigbee2MQTTReadingsTests {
    private func state(_ name: String, _ lux: Double) -> Zigbee2MQTT.Message {
        .state(name, ["illuminance": lux, "linkquality": 80])
    }

    private func devices() -> Zigbee2MQTT.Message {
        Zigbee2MQTT.parse(Zigbee2MQTTModelTests.devices)
    }

    @Test func aRepeatedReadingIsNotAChange() {
        var readings = Zigbee2MQTT.Readings()
        let now = Date(timeIntervalSince1970: 1000)
        let changed1 = readings.apply(devices())
        #expect(changed1)
        let changed2 = readings.apply(state("Hall sensor", 12), at: now)
        #expect(changed2)
        let changed3 = readings.apply(state("Hall sensor", 12), at: now.addingTimeInterval(5))
        #expect(!changed3)
        let hall = readings.sensors.first { $0.name == "Hall sensor" }
        #expect(hall?.lux == 12)
        #expect(hall?.updated == now)
        #expect(hall?.id == "zigbee2mqtt:0x00124b0000000003")
        let changed4 = readings.apply(state("Lamp plug", 3))
        #expect(!changed4)
    }

    @Test func aStateBeforeTheDeviceListStillCounts() {
        var readings = Zigbee2MQTT.Readings()
        let changed5 = readings.apply(state("Hall sensor", 40))
        #expect(!changed5)
        let changed6 = readings.apply(devices())
        #expect(changed6)
        #expect(readings.sensors.first { $0.name == "Hall sensor" }?.lux == 40)
    }

    @Test func anOfflineSensorHasNoReadingUntilItIsBack() {
        var readings = Zigbee2MQTT.Readings()
        _ = readings.apply(devices())
        _ = readings.apply(state("Hall sensor", 12))
        let changed7 = readings.apply(.availability("Hall sensor", false))
        #expect(changed7)
        var hall = readings.sensors.first { $0.name == "Hall sensor" }
        #expect(hall?.lux == nil)
        #expect(hall?.unavailable == "offline in Zigbee2MQTT")
        let changed8 = readings.apply(.availability("Hall sensor", false))
        #expect(!changed8)
        let changed9 = readings.apply(.availability("Hall sensor", true))
        #expect(changed9)
        hall = readings.sensors.first { $0.name == "Hall sensor" }
        #expect(hall?.lux == 12)
        #expect(hall?.unavailable == nil)
    }

    @Test func aRenameKeepsTheSensorID() {
        var readings = Zigbee2MQTT.Readings()
        _ = readings.apply(devices())
        let renamed = Zigbee2MQTTModelTests.devices.replacingOccurrences(of: "\"friendly_name\": \"0x00124b0000000002\"",
                                                                         with: "\"friendly_name\": \"Desk presence\"")
        let changed10 = readings.apply(Zigbee2MQTT.parse(renamed))
        #expect(changed10)
        let desk = readings.sensors.first { $0.name == "Desk presence" }
        #expect(desk?.id == "zigbee2mqtt:0x00124b0000000002")
    }
}

/// Talks to a real Zigbee2MQTT server, when one is named in
/// BRIGHTSYNC_TEST_ZIGBEE2MQTT (its web interface's address).
struct Zigbee2MQTTServerTests {
    static let address = ProcessInfo.processInfo.environment["BRIGHTSYNC_TEST_ZIGBEE2MQTT"]

    @Test(.enabled(if: address != nil), .timeLimit(.minutes(1)))
    func aRealServerSendsItsSensorsAndAReading() async throws {
        let server = Zigbee2MQTTServer(address: try #require(Self.address), log: { _ in })
        defer { server.stop() }
        let snapshot: Zigbee2MQTTServer.Snapshot = await withCheckedContinuation { continuation in
            var resumed = false
            server.onUpdate = { snapshot in
                // Done once a sensor has a reading, or the server has none.
                let done = snapshot.problem != nil
                    || (snapshot.connected && (snapshot.sensors.isEmpty || snapshot.sensors.contains { $0.lux != nil }))
                guard done, !resumed else { return }
                resumed = true
                continuation.resume(returning: snapshot)
            }
            server.connect()
        }
        #expect(snapshot.problem == nil)
        #expect(snapshot.connected)
        print("sensors:", snapshot.sensors.map { "\($0.name) \($0.lux.map { "\($0) lux" } ?? "no reading")" })
    }
}
