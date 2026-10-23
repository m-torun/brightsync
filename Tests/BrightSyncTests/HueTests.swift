import Foundation
import Testing
@testable import BrightSync

struct EventStreamParserTests {
    @Test func eventsSplitAcrossChunksAreJoined() {
        var parser = EventStreamParser()
        #expect(parser.feed(Data(": hi\n\nid: 1:0\nda".utf8)).isEmpty)
        #expect(parser.feed(Data("ta: [1,2]\n".utf8)).isEmpty)
        #expect(parser.feed(Data("\nid: 2:0\ndata: [3]\n\n".utf8)) == ["[1,2]", "[3]"])
    }

    @Test func crlfAndMultilineData() {
        var parser = EventStreamParser()
        #expect(parser.feed(Data("data: a\r\ndata: b\r\n\r\n".utf8)) == ["a\nb"])
    }
}

struct HueModelTests {
    @Test func lightLevelIsLogarithmic() {
        #expect(abs(Hue.lux(fromLightLevel: 11105) - 12.9) < 0.05)
        #expect(abs(Hue.lux(fromLightLevel: 20001) - 100) < 0.01)
        #expect(abs(Hue.lux(fromLightLevel: 0) - 1) < 0.01)
    }

    @Test func sensorsAreNamedAfterTheirDevice() throws {
        let devices = """
        {"errors": [], "data": [
          {"id": "dev-1", "type": "device", "metadata": {"name": "Desk sensor", "archetype": "unknown_archetype"},
           "product_data": {"model_id": "SML001"}, "services": []},
          {"id": "dev-2", "type": "device", "metadata": {"name": "Lamp"}}
        ]}
        """
        let levels = """
        {"errors": [], "data": [
          {"id": "ll-1", "type": "light_level", "enabled": true,
           "owner": {"rid": "dev-1", "rtype": "device"},
           "light": {"light_level": 11105, "light_level_valid": true,
                     "light_level_report": {"changed": "2026-10-23T14:57:02.299Z", "light_level": 11105}}}
        ]}
        """
        let sensors = Hue.sensors(bridgeID: "ABCDEF0123456789",
                                  lightLevels: try JSONDecoder().decode(HueEnvelope.self, from: Data(levels.utf8)).resources,
                                  devices: try JSONDecoder().decode(HueEnvelope.self, from: Data(devices.utf8)).resources)
        #expect(sensors.count == 1)
        #expect(sensors[0].id == "hue:abcdef0123456789:ll-1")
        #expect(sensors[0].name == "Desk sensor")
        #expect(abs(sensors[0].lux! - 12.9) < 0.05)
        #expect(sensors[0].updated == Date(timeIntervalSince1970: 1_792_767_422.299))
    }

    @Test func anEventWithResourcesOfOtherShapesStillDecodes() throws {
        let event = """
        [{"creationtime": "2026-10-23T15:08:53Z", "id": "e1", "type": "update", "data": [
          {"id": "m-1", "type": "motion", "motion": {"motion": true}},
          {"id": "ll-1", "type": "light_level", "light": {"light_level_report": {"changed": "2026-10-23T15:08:53.877Z", "light_level": 18072}}},
          {"type": "broken"}
        ]}]
        """
        let envelopes = try JSONDecoder().decode([HueEnvelope].self, from: Data(event.utf8))
        #expect(envelopes[0].type == "update")
        #expect(envelopes[0].resources.map(\.id) == ["m-1", "ll-1"])
        #expect(envelopes[0].resources[1].light?.light_level_report?.light_level == 18072)
    }

    @Test func bothPhilipsRootsLoad() {
        #expect(HueTrust.roots.count == 2)
    }
}
