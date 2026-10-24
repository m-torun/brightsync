import Foundation

/// An ambient light sensor that brightness can follow.
struct LightSensor: Equatable {
    /// Stable across launches and unique across providers; kept in preferences.
    let id: String
    let name: String
    /// The latest reading, nil until one arrives.
    var lux: Double?
    /// When the sensor took that reading.
    var updated: Date?
    /// Why there is no usable reading, e.g. "turned off in the Hue app".
    /// Brightness is left where it is meanwhile.
    var unavailable: String?
}

/// A kind of light sensor. BrightSync ships with Philips Hue; another kind
/// (MQTT, Zigbee, ESPHome, a script...) plugs in by implementing this and
/// being listed in `AmbientController.defaultProviders`. Settings lists every
/// provider's sensors together, and offers each provider under Add Sensor.
///
/// A provider should push readings as they arrive rather than poll, and must
/// never prompt the user on its own: `start` only resumes what the user set
/// up before, and anything that needs the user (pairing, permissions) happens
/// from the menu.
protocol LightSensorProvider: AnyObject {
    /// The kind of sensor, e.g. "Philips Hue". Shown under Add Sensor and
    /// next to each of its sensors.
    var name: String { get }
    /// Something in progress worth showing, e.g. waiting for a button press.
    var activity: String? { get }
    /// The sensors available right now. Read on the main queue.
    var sensors: [LightSensor] { get }
    /// Something worth showing in the menu, e.g. "Hue bridge not found".
    var problem: String? { get }
    /// Called on the main queue whenever the sensors, readings or problem change.
    var onChange: (() -> Void)? { get set }
    /// Resumes connections set up earlier. Must not prompt.
    func start()
    /// Reconnects now, e.g. after the Mac wakes or the network changes.
    func refresh()
    /// Walks the user through adding sensors of this kind, e.g. pairing a
    /// Hue bridge. Called from Settings, on the main queue.
    func addSensors()
}
