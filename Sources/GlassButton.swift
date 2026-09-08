import AppKit

/// Стеклянная action-кнопка Control Center: SF-иконка + подпись в controlFill-пилюле,
/// тонкая световая кромка (surfaceRim), hover-подсветка (rimHighlight), press-микроанимация.
/// Модель — CCToggle/FooterIconButton, но БЕЗ on/off-состояния (это триггер действия, не тумблер).
/// Клик/Space/Return/VoiceOver-press → onClick. Уважает Motion.reduced (без press-анимации).
final class GlassButton: NSView {
    var onClick: (() -> Void)?
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let cornerRadius: CGFloat
    private var hovering = false
    private var pressed = false
    private var symbol: String?

    /// Подпись/иконка фирменной бирюзой (деструктив/CTA-акцент). Иначе — системный .labelColor.
    var accentText: Bool { didSet { restyle() } }

    /// Settable title — используется installBtn (Установить/Переустановить хелпер…).
    var title: String {
        didSet {
            label.stringValue = title
            iconView.toolTip = title
            invalidateIntrinsicContentSize()
        }
    }

    var isEnabled = true {
        didSet {
            if !isEnabled { pressed = false }
            alphaValue = isEnabled ? 1 : 0.45
            restyle()
            window?.invalidateCursorRects(for: self)
        }
    }

    init(title: String, symbol: String?, accentText: Bool = false, cornerRadius: CGFloat = Design.Radius.control) {
        self.title = title
        self.symbol = symbol
        self.accentText = accentText
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        focusRingType = .default
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true

        if let symbol {
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            iconView.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
            iconView.imageScaling = .scaleProportionallyDown
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = title
        label.font = Design.Font.callout
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        let hasIcon = symbol != nil
        let isIconOnly = hasIcon && title.isEmpty
        addSubview(iconView); addSubview(label)
        var layoutConstraints = [
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: hasIcon ? 15 : 0),
            iconView.heightAnchor.constraint(equalToConstant: 15),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if isIconOnly {
            layoutConstraints += [
                iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.widthAnchor.constraint(equalToConstant: 0),
                label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor),
            ]
        } else {
            layoutConstraints += [
                iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hasIcon ? 10 : 0),
                label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: hasIcon ? 6 : 10),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            ]
        }
        NSLayoutConstraint.activate(layoutConstraints)
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private func restyle() {
        guard let layer = layer else { return }
        let dark = isDark
        layer.cornerCurve = .continuous
        // покой → controlFill + surfaceRim; hover → чуть плотнее (surfaceRim фон) + rimHighlight кромка.
        layer.backgroundColor = (hovering ? Design.Color.surfaceRim(dark) : Design.Color.controlFill(dark)).cgColor
        layer.borderWidth = 1
        layer.borderColor = (hovering ? Design.Color.rimHighlight(dark, 0.18) : Design.Color.surfaceRim(dark)).cgColor
        let tint = accentText ? Design.Color.accent(dark) : .labelColor
        iconView.contentTintColor = tint
        label.textColor = tint
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { guard isEnabled else { return }; hovering = true; restyle() }
    override func mouseExited(with event: NSEvent) { hovering = false; restyle() }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    /// Активация (нажатие): press-микроанимация (gated Motion.reduced) + onClick. Общая для мыши/клавы/VO.
    private func activate() {
        guard isEnabled else { return }
        if !Motion.reduced {
            let press = CABasicAnimation(keyPath: "transform.scale")
            press.fromValue = 0.96; press.toValue = 1.0; press.duration = Design.Motion.durFast
            layer?.add(press, forKey: "press")
        }
        onClick?()
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        window?.makeFirstResponder(self)
        pressed = true
        alphaValue = 0.72
    }
    override func mouseDragged(with event: NSEvent) {
        guard pressed else { return }
        let p = convert(event.locationInWindow, from: nil)
        alphaValue = bounds.contains(p) ? 0.72 : 1
    }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        alphaValue = isEnabled ? 1 : 0.45
        let p = convert(event.locationInWindow, from: nil)
        if isEnabled, bounds.contains(p) { activate() }
    }

    // MARK: клавиатура — фокус + пробел/Enter
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 49 || event.keyCode == 36), !event.isARepeat { activate() }   // Space / Return
        else { super.keyDown(with: event) }
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }

    // MARK: VoiceOver — button с меткой (НЕ checkBox — это действие)
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title.isEmpty ? toolTip : title }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        activate()
        return true
    }
}
