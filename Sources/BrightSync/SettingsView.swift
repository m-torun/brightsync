import Charts
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
                    Text(model.ambient.selected?.lux.map { "\(HueBridge.format($0)) lux" } ?? model.sensorCaption)
                }
                LabeledContent("Brightness:") {
                    HStack {
                        Slider(value: brightness, in: 0...100) { editing in
                            if !editing, let percent = model.brightness {
                                model.setBrightness(percent, finished: true)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                        Text(model.brightness.map { "\(Int($0.rounded()))%" } ?? "–")
                            .monospacedDigit()
                            .frame(width: 40, alignment: .leading)
                    }
                    .disabled(model.brightness == nil)
                }
                LabeledContent("Curve:") {
                    CurveChart(curve: model.ambient.curve, lux: model.ambient.selected?.lux, percent: model.brightness)
                        .frame(width: 340, height: 160)
                        // Line the label up with the top of the chart, not its axis labels.
                        .alignmentGuide(.firstTextBaseline) { $0[.top] + 10 }
                }
                LabeledContent("") {
                    VStack(alignment: .leading, spacing: 8) {
                        Note("Moving the slider pins the curve to that brightness at the current light. Set it again in other light, in the evening or on a bright afternoon, to shape it. Beyond your pins it rises 25 points for every tenfold increase in light.")
                        Button("Reset Curve") { model.resetCurve() }
                            .disabled(model.ambient.curve.points.isEmpty)
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

    private var brightness: Binding<Double> {
        Binding(get: { model.brightness ?? 50 },
                set: { model.setBrightness($0.rounded(), finished: false) })
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

/// Brightness against light, on a log scale: the curve, the user's pins, and
/// where the current reading sits.
struct CurveChart: View {
    let curve: AmbientCurve
    let lux: Double?
    let percent: Double?

    private static let steps = Array(stride(from: 0.0, through: 5.0, by: 0.05))

    var body: some View {
        Chart {
            ForEach(Self.steps, id: \.self) { x in
                LineMark(x: .value("Light", x), y: .value("Brightness", curve.percent(at: pow(10, x))))
            }
            ForEach(curve.points, id: \.lux) { point in
                PointMark(x: .value("Light", AmbientCurve.decades(point.lux)), y: .value("Brightness", point.percent))
                    .symbolSize(40)
            }
            if let lux, let percent {
                RuleMark(x: .value("Light", AmbientCurve.decades(lux)))
                    .foregroundStyle(.orange.opacity(0.5))
                PointMark(x: .value("Light", AmbientCurve.decades(lux)), y: .value("Brightness", percent))
                    .foregroundStyle(.orange)
                    .symbolSize(70)
            }
        }
        .chartXScale(domain: 0...5)
        .chartYScale(domain: 0...100)
        .chartXAxis {
            AxisMarks(values: [0.0, 1, 2, 3, 4, 5]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let x = value.as(Double.self) {
                        Text(Self.luxLabel(x))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let y = value.as(Int.self) {
                        Text("\(y)%")
                    }
                }
            }
        }
    }

    private static func luxLabel(_ decades: Double) -> String {
        ["1 lux", "10", "100", "1k", "10k", "100k"][min(max(Int(decades.rounded()), 0), 5)]
    }
}
