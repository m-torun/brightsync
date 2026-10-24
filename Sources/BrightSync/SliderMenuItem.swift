import AppKit

/// A slider inside a menu, laid out like the menu's own items: a title and
/// value on one line, the slider, and optionally a caption.
final class SliderMenuView: NSView {
    /// Where macOS starts the text of items in a menu with checkmarks.
    private static let indent: CGFloat = 24

    private let title = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private let slider: NSSlider
    private var dragging = false
    /// Called while dragging; `finished` is true when the mouse is released.
    var onChange: ((Double, _ finished: Bool) -> Void)?

    /// A slider centred on 0, for an offset: snaps to 0 nearby and shows a sign.
    init(title text: String, offsetRange: ClosedRange<Double>, captioned: Bool) {
        slider = NSSlider.offset(range: offsetRange)
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: captioned ? 64 : 48))
        autoresizingMask = [.width]
        title.stringValue = text
        title.font = .menuFont(ofSize: 0)
        title.lineBreakMode = .byTruncatingTail
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        value.textColor = .secondaryLabelColor
        value.alignment = .right
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail
        caption.isHidden = !captioned
        slider.target = self
        slider.action = #selector(changed)

        for view in [title, value, slider, caption] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.indent),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            title.trailingAnchor.constraint(lessThanOrEqualTo: value.leadingAnchor, constant: -8),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            value.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.indent),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.indent),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
            caption.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 0),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    /// Shows the offset, or a disabled slider when there is nothing to offset
    /// from yet. Leaves the knob alone while it is being dragged.
    func show(offset: Double?, title text: String? = nil, caption captionText: String? = nil) {
        if let text {
            title.stringValue = text
        }
        if let captionText {
            caption.stringValue = captionText
        }
        slider.isEnabled = offset != nil
        title.textColor = offset != nil ? .labelColor : .disabledControlTextColor
        guard !dragging else { return }
        slider.doubleValue = offset ?? 0
        value.stringValue = offset.map { Self.format($0) + "%" } ?? ""
    }

    @objc private func changed() {
        // Close to the middle means the default: make it easy to get back to.
        if abs(slider.doubleValue) < 2.5 {
            slider.doubleValue = 0
        }
        let offset = slider.doubleValue.rounded()
        let finished = NSApp.currentEvent?.type == .leftMouseUp
        dragging = !finished
        value.stringValue = Self.format(offset) + "%"
        onChange?(offset, finished)
    }

    static func format(_ offset: Double) -> String {
        AmbientController.signed(offset)
    }
}

extension NSSlider {
    /// A slider for an offset around 0: no fill from the left end, which
    /// would read as an amount, and marks at both ends and the middle.
    static func offset(range: ClosedRange<Double>) -> NSSlider {
        let slider = NSSlider(value: 0, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        slider.isContinuous = true
        slider.trackFillColor = .clear
        slider.numberOfTickMarks = 3
        slider.tickMarkPosition = .below
        return slider
    }
}
