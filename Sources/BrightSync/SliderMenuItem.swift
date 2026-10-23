import AppKit

/// The brightness slider at the top of the menu, laid out like the menu's own
/// items: a title and value on one line, the slider, then a caption saying
/// what the sensor reads.
final class SliderMenuView: NSView {
    /// Where macOS starts the text of items in a menu with checkmarks.
    private static let indent: CGFloat = 24

    private let title = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private var dragging = false
    /// Called while dragging; `finished` is true when the mouse is released.
    var onChange: ((Double, _ finished: Bool) -> Void)?

    init(title text: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 62))
        autoresizingMask = [.width]
        title.stringValue = text
        title.font = .menuFont(ofSize: 0)
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)

        for view in [title, value, slider, caption] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.indent),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            value.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.indent),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.indent),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            caption.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    /// Shows the curve's current value, or a disabled slider when there is
    /// no reading. Leaves the knob alone while it is being dragged.
    func show(percent: Double?, caption text: String) {
        caption.stringValue = text
        slider.isEnabled = percent != nil
        title.textColor = percent != nil ? .labelColor : .disabledControlTextColor
        guard !dragging else { return }
        if let percent {
            slider.doubleValue = percent
        }
        value.stringValue = percent.map { "\(Int($0.rounded()))%" } ?? ""
    }

    @objc private func changed() {
        let finished = NSApp.currentEvent?.type == .leftMouseUp
        dragging = !finished
        value.stringValue = "\(Int(slider.doubleValue.rounded()))%"
        onChange?(slider.doubleValue.rounded(), finished)
    }
}
