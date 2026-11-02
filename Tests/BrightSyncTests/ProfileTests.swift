import Foundation
import Testing
@testable import BrightSync

struct ProfileTests {
    let dell = Display(id: 1, name: "DELL", edidUUID: "uuid-dell")
    let lenovo = Display(id: 2, name: "LEN", edidUUID: "uuid-lenovo")
    let bedroom = Display(id: 3, name: "LG", edidUUID: "uuid-lg")

    func settings(sensor: String?) -> ProfileSettings {
        ProfileSettings(sourceSensor: sensor, sharedOffset: 10)
    }

    @Test func theFirstRunKeepsWhatIsSetAndNamesItAfterTheMonitors() {
        var book = ProfileBook()
        #expect(book.arrive(at: [lenovo, dell], with: settings(sensor: "desk")) == nil)
        #expect(book.activeName == "DELL + LEN")
        #expect(book.settings(named: "DELL + LEN") == settings(sensor: "desk"))
    }

    @Test func theSameMonitorsInAnotherOrderAreTheSameProfile() {
        var book = ProfileBook()
        _ = book.arrive(at: [dell, lenovo], with: settings(sensor: "desk"))
        #expect(book.arrive(at: [lenovo, dell], with: settings(sensor: "other")) == nil)
        #expect(book.names == ["DELL + LEN"])
    }

    @Test func goingBackBringsBackEachRoomsSettings() {
        var book = ProfileBook()
        _ = book.arrive(at: [dell, lenovo], with: settings(sensor: "desk"))
        _ = book.arrive(at: [bedroom], with: settings(sensor: "desk"))
        // A sensor is chosen in the bedroom; that is saved when leaving it.
        let back = book.arrive(at: [lenovo, dell], with: settings(sensor: "bedside"))
        #expect(back == .init(settings: settings(sensor: "desk"), isNew: false))
        let again = book.arrive(at: [bedroom], with: settings(sensor: "desk"))
        #expect(again == .init(settings: settings(sensor: "bedside"), isNew: false))
        #expect(book.names == ["DELL + LEN", "LG"])
    }

    @Test func aNewRoomKeepsThePreferencesButNotTheSensor() {
        var book = ProfileBook()
        var live = settings(sensor: "desk")
        live.sourceDisplay = "uuid-dell"
        live.colorSource = "uuid-dell"
        live.displayOffsets = ["uuid-dell": 5]
        live.rampSeconds = 30
        _ = book.arrive(at: [dell], with: live)
        let arrival = book.arrive(at: [bedroom], with: live)
        #expect(arrival?.isNew == true)
        #expect(arrival?.settings.sourceSensor == nil)
        #expect(arrival?.settings.sourceDisplay == nil)
        #expect(arrival?.settings.colorSource == nil)
        #expect(arrival?.settings.displayOffsets == [:])
        #expect(arrival?.settings.rampSeconds == 30)
        #expect(arrival?.settings.sharedOffset == 10)
    }

    @Test func aMonitorSwitchedAwayKeepsTheRoomsSensor() {
        var book = ProfileBook()
        _ = book.arrive(at: [dell, lenovo], with: settings(sensor: "desk"))
        let arrival = book.arrive(at: [lenovo], with: settings(sensor: "desk"))
        #expect(arrival == .init(settings: settings(sensor: "desk"), isNew: true))
        #expect(book.activeName == "LEN")
    }

    @Test func noMonitorsLeavesTheActiveProfileAlone() {
        var book = ProfileBook()
        _ = book.arrive(at: [dell], with: settings(sensor: "desk"))
        #expect(book.arrive(at: [], with: settings(sensor: "desk")) == nil)
        #expect(book.activeName == "DELL")
        #expect(book.names == ["DELL"])
    }

    @Test func aBookSurvivesBeingSaved() throws {
        var book = ProfileBook()
        _ = book.arrive(at: [dell], with: settings(sensor: "desk"))
        _ = book.arrive(at: [bedroom], with: settings(sensor: "desk"))
        let saved = try JSONEncoder().encode(book)
        #expect(try JSONDecoder().decode(ProfileBook.self, from: saved) == book)
    }
}
