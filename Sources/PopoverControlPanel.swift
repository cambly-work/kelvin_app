import AppKit
import QuartzCore

/// Сворачиваемый Control Center под компактной шапкой поповера.
/// В покое занимает одну строку; переключатели и вывод звука появляются только
/// по запросу, поэтому активная вкладка остаётся главным экраном.
final class PopoverControlPanel: NSView {
    var onExpansionChanged: ((Bool) -> Void)?

    private final class Header: NSView {
        var onPress: (() -> Void)?

        private let icon = NSImageView()
        private let titleLabel = NSTextField(labelWithString: "")
        private let summaryLabel = NSTextField(labelWithString: "")
        private let chevron = NSImageView()
        private var hovering = false
        private var pressed = false
        private var expanded = false
        private var tracking: NSTrackingArea?

        init(title: String, summary: String) {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 11
            layer?.cornerCurve = .continuous

            icon.image = NSImage(systemSymbolName: "switch.2", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false

            titleLabel.stringValue = title
            titleLabel.font = Design.Font.calloutEmph
            titleLabel.lineBreakMode = .byTruncatingTail
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

            summaryLabel.stringValue = summary
            summaryLabel.isHidden = summary.isEmpty
            summaryLabel.font = Design.Font.caption
            summaryLabel.textColor = .secondaryLabelColor
            summaryLabel.lineBreakMode = .byTruncatingTail
            summaryLabel.translatesAutoresizingMaskIntoConstraints = false
            summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            chevron.imageScaling = .scaleProportionallyDown
            chevron.translatesAutoresizingMaskIntoConstraints = false

            for view in [icon, titleLabel, summaryLabel, chevron] { addSubview(view) }
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                icon.centerYAnchor.constraint(equalTo: centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),

                titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

                summaryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 10),
                summaryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                summaryLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -8),

                chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
                chevron.widthAnchor.constraint(equalToConstant: 11),
                chevron.heightAnchor.constraint(equalToConstant: 11),
            ])
            updateChevron()
            restyle()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        private var isDark: Bool {
            effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }

        func setExpanded(_ value: Bool, animated: Bool) {
            guard expanded != value else { return }
            expanded = value
            if animated && !Motion.reduced {
                let turn = CABasicAnimation(keyPath: "transform.rotation.z")
                turn.fromValue = value ? -Double.pi / 2 : 0
                turn.toValue = value ? 0 : -Double.pi / 2
                turn.duration = Design.Motion.durFast
                turn.timingFunction = Design.Motion.easeStandard
                chevron.layer?.add(turn, forKey: "turn")
            }
            updateChevron()
            setAccessibilityHelp(value ? L("Свернуть управление") : L("Развернуть управление"))
        }

        private func updateChevron() {
            chevron.image = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        }

        private func restyle() {
            let accent = Design.Color.accent(isDark)
            icon.contentTintColor = accent
            chevron.contentTintColor = .secondaryLabelColor
            titleLabel.textColor = .labelColor
            layer?.backgroundColor = (hovering
                ? Design.Color.controlFill(isDark)
                : NSColor.clear).cgColor
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            restyle()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { hovering = true; restyle() }
        override func mouseExited(with event: NSEvent) { hovering = false; restyle() }

        private func activate() {
            if !Motion.reduced {
                let press = CABasicAnimation(keyPath: "transform.scale")
                press.fromValue = 0.985
                press.toValue = 1
                press.duration = Design.Motion.durFast
                layer?.add(press, forKey: "press")
            }
            onPress?()
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            pressed = true
            alphaValue = 0.72
        }
        override func mouseDragged(with event: NSEvent) {
            guard pressed else { return }
            alphaValue = bounds.contains(convert(event.locationInWindow, from: nil)) ? 0.72 : 1
        }
        override func mouseUp(with event: NSEvent) {
            guard pressed else { return }
            pressed = false
            alphaValue = 1
            if bounds.contains(convert(event.locationInWindow, from: nil)) { activate() }
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }
        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted {
                layer?.borderWidth = 2
                layer?.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
            }
            return accepted
        }
        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { layer?.borderWidth = 0 }
            return resigned
        }
        override func keyDown(with event: NSEvent) {
            if (event.keyCode == 49 || event.keyCode == 36) && !event.isARepeat { activate() }
            else { super.keyDown(with: event) }
        }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityLabel() -> String? {
            summaryLabel.stringValue.isEmpty
                ? titleLabel.stringValue
                : titleLabel.stringValue + " · " + summaryLabel.stringValue
        }
        override func accessibilityPerformPress() -> Bool { activate(); return true }
    }

    private let header: Header
    private let content: NSView
    private var expandedBottom: NSLayoutConstraint!
    private var collapsedBottom: NSLayoutConstraint!
    private(set) var isExpanded: Bool

    init(title: String, summary: String, content: NSView, expanded: Bool) {
        header = Header(title: title, summary: summary)
        self.content = content
        isExpanded = expanded
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 15
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        header.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(content)

        expandedBottom = content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        collapsedBottom = header.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            header.heightAnchor.constraint(equalToConstant: 36),

            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])

        header.onPress = { [weak self] in self?.toggle() }
        applyExpanded(expanded, animated: false, notify: false)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func toggle() { applyExpanded(!isExpanded, animated: true, notify: true) }

    private func applyExpanded(_ expanded: Bool, animated: Bool, notify: Bool) {
        isExpanded = expanded
        expandedBottom.isActive = expanded
        collapsedBottom.isActive = !expanded
        content.isHidden = !expanded
        content.alphaValue = expanded ? 1 : 0
        header.setExpanded(expanded, animated: animated)
        invalidateIntrinsicContentSize()
        needsLayout = true
        superview?.needsLayout = true
        if notify { onExpansionChanged?(expanded) }
    }

    private func restyle() {
        layer?.backgroundColor = (isDark
            ? NSColor.white.withAlphaComponent(0.035)
            : NSColor.black.withAlphaComponent(0.025)).cgColor
        layer?.borderWidth = 0
        layer?.borderColor = NSColor.clear.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}
