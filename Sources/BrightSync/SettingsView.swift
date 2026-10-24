import SwiftUI

/// The Settings window: one tab per area, laid out the way Mac settings
/// windows are, with labels in a right-aligned column and controls beside
/// them. The window takes the size of the tab and cannot be resized.
struct SettingsView: View {
    enum Tab: Hashable, CaseIterable {
        case brightness, color, sensors, general
    }

    @ObservedObject var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            BrightnessPane(model: model)
                .tabItem { Label("Brightness", systemImage: "sun.max") }
                .tag(Tab.brightness)
            ColorPane(model: model)
                .tabItem { Label("Color", systemImage: "paintpalette") }
                .tag(Tab.color)
            SensorsPane(model: model)
                .tabItem { Label("Sensors", systemImage: "sensor") }
                .tag(Tab.sensors)
            GeneralPane(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
        }
        .padding(20)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Small grey text under a control, in the control column.
private struct Note: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 360, alignment: .leading)
    }
}

private struct BrightnessPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Toggle("Sync brightness", isOn: $model.isEnabled)
            Picker("Follow:", selection: $model.source) {
                Text("Main display (automatic)").tag(AppModel.Source.mainDisplay)
                ForEach(model.displays, id: \.key) { display in
                    Text(display.name).tag(AppModel.Source.display(display.key))
                }
                if !model.ambient.sensors.isEmpty {
                    Divider()
                }
                ForEach(model.ambient.sensors) { choice in
                    Text("\(choice.sensor.name) (\(choice.provider))").tag(AppModel.Source.sensor(choice.id))
                }
                if model.sensorMissing {
                    Text("Chosen sensor (not available)").tag(model.source)
                }
            }
            .fixedSize()
            if let state = model.pausedReason ?? model.status.message {
                LabeledContent("Status:") { Text(state).foregroundStyle(.secondary) }
            }

            if model.followsSensor {
                LabeledContent("Light:") {
                    Text(model.ambient.lux.map { "\(HueBridge.format($0)) lux" } ?? model.lightCaption)
                }
                LabeledContent("Default:") {
                    Text(model.defaultPercent.map { "\($0)% at this light" } ?? "–")
                }
                Toggle("Adjust monitors together", isOn: $model.adjustTogether)
                if model.adjustTogether {
                    offsetRow("Brightness:", display: nil)
                } else {
                    ForEach(model.displays, id: \.key) { display in
                        offsetRow("\(display.name):", display: display.key)
                    }
                }
                LabeledContent("") {
                    VStack(alignment: .leading, spacing: 8) {
                        Note("The default rises 25 points for every tenfold increase in light: 10% at 1 lux, 60% at 100 lux, 100% from about 1800 lux. The slider moves it up or down at every light level; 0 is the default.")
                        Button("Reset to Default") { model.resetOffsets() }
                            .disabled(model.offsets.shared == 0 && model.offsets.perDisplay.values.allSatisfy { $0 == 0 })
                    }
                }
            } else {
                Picker("Check every:", selection: $model.interval) {
                    ForEach(Preferences.intervalChoices, id: \.self) { seconds in
                        Text(seconds < 60 ? "\(seconds) seconds" : seconds == 60 ? "1 minute" : "\(seconds / 60) minutes").tag(seconds)
                    }
                }
                .fixedSize()
            }
        }
        .formStyle(.columns)
    }

    /// A slider from -50 to +50 around the default curve, with the
    /// brightness it gives right now.
    private func offsetRow(_ label: String, display: String?) -> some View {
        LabeledContent(label) {
            HStack {
                OffsetSlider(value: offset(display)) {
                    model.setOffset(model.offsets.offset(for: display ?? ""), display: display, finished: true)
                }
                .frame(width: 220)
                Text(AmbientController.signed(model.offsets.offset(for: display ?? "")) + "%")
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
                Text(model.resultPercent(for: display).map { "→ \($0)%" } ?? "")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .disabled(model.ambient.lux == nil)
        }
    }

    private func offset(_ display: String?) -> Binding<Double> {
        Binding(get: { model.offsets.offset(for: display ?? "") },
                set: { value in
                    // Close to the middle means the default.
                    model.setOffset(abs(value) < 2.5 ? 0 : value.rounded(), display: display, finished: false)
                })
    }
}

private struct ColorPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Toggle("Sync color preset", isOn: $model.syncColor)
            Picker("Copy from:", selection: $model.colorSource) {
                Text("Main display (automatic)").tag(String?.none)
                ForEach(model.displays, id: \.key) { display in
                    Text(display.name).tag(String?.some(display.key))
                }
            }
            .fixedSize()
            .disabled(!model.syncColor)
            LabeledContent("") {
                Note("Copies the color preset (DDC code 0x14) from one display to the others, whatever brightness follows. Preset numbers are only nominally standard, and a monitor's own automatic color temperature does not usually show up as a preset.")
            }
        }
        .formStyle(.columns)
    }
}

private struct SensorsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            LabeledContent("Light sensors:") {
                VStack(alignment: .leading, spacing: 6) {
                    if model.ambient.sensors.isEmpty {
                        Text("None yet").foregroundStyle(.secondary)
                    }
                    ForEach(model.ambient.sensors) { choice in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(choice.sensor.name)
                            Text("\(choice.provider) · " + (choice.sensor.lux.map { "\(HueBridge.format($0)) lux" } ?? "no reading yet"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(model.ambient.providers.indices, id: \.self) { index in
                        let provider = model.ambient.providers[index]
                        if let line = provider.activity ?? provider.problem {
                            Text("\(provider.name): \(line)")
                                .font(.callout)
                                .foregroundStyle(provider.activity != nil ? Color.secondary : Color.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 360, alignment: .leading)
                        }
                    }
                    Menu("Add Sensor") {
                        ForEach(model.ambient.providers.indices, id: \.self) { index in
                            let provider = model.ambient.providers[index]
                            Button("\(provider.name)…") { provider.addSensors() }
                        }
                    }
                    .fixedSize()
                    .padding(.top, 4)
                    Note("BrightSync only talks to sensors you add, on your local network.")
                }
            }
        }
        .formStyle(.columns)
    }
}

private struct GeneralPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Toggle("Start at login", isOn: $model.launchAtLogin)
            Toggle("Pause during calls", isOn: $model.pauseDuringCalls)
            LabeledContent("") {
                Note("Sends nothing to the monitors while any app uses the camera or microphone. A video call keeps the display hardware that also carries these commands at its busiest. Brightness catches up when the call ends.")
                    .padding(.bottom, 8)
            }
            LabeledContent("Displays:") {
                VStack(alignment: .leading, spacing: 4) {
                    if model.displays.isEmpty {
                        Text("None found yet").foregroundStyle(.secondary)
                    }
                    ForEach(model.displays, id: \.key) { display in
                        Text("\(display.name) — \(model.describe(display))")
                    }
                    Button("Sync Now") { model.syncNow() }
                        .padding(.top, 4)
                }
            }
            LabeledContent("Log:") {
                Button("Reveal in Finder") { model.revealLog() }
            }
        }
        .formStyle(.columns)
    }
}

/// The same offset slider as in the menu: centred on 0, no fill, a mark in
/// the middle. `finished` runs when the mouse is released.
private struct OffsetSlider: NSViewRepresentable {
    @Binding var value: Double
    var finished: () -> Void

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider.offset(range: BrightnessOffsets.range)
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        if slider.doubleValue != value {
            slider.doubleValue = value
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject {
        var parent: OffsetSlider

        init(parent: OffsetSlider) {
            self.parent = parent
        }

        @objc func changed(_ slider: NSSlider) {
            parent.value = slider.doubleValue
            if NSApp.currentEvent?.type == .leftMouseUp {
                parent.finished()
            }
        }
    }
}
