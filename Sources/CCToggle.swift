import AppKit

/// Кнопка-переключатель в стиле Control Center: иконка + подпись в стеклянной пилюле,
/// акцентная заливка во включённом состоянии. Клик вызывает onClick.
final class CCToggle: NSView {
    let id: String
    let title: String
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    var accent: NSColor
    /// Встроенные тумблеры рисуются фирменной бирюзой (тема-зависимой), кастомные — цветом пользователя.
    var isBuiltin = false { didSet { restyle() } }
    var isMomentaryAction = false { didSet { restyle() } }
    var isOn = false { didSet { restyle() } }
    var onClick: (() -> Void)?
    var stateProvider: (() -> Bool)?      // для обновления состояния в tick()
    private var pressed = false

    init(id: String, icon: String, title: String, accent: NSColor) {
        self.id = id; self.title = title; self.accent = accent
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Design.Radius.control
        layer?.cornerCurve = .continuous
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 44).isActive = true

        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
        iconView.symbolConfiguration = .init(pointSize: 14, weight: .semibold)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = title
        label.font = Design.Font.callout
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView); addSubview(label)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 9),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private func restyle() {
        guard let layer = layer else { return }
        let dark = isDark
        // Встроенные тумблеры — единая фирменная бирюза; кастомные сохраняют цвет пользователя.
        let fillAccent = isBuiltin ? Design.Color.accent(dark) : accent
        layer.cornerCurve = .continuous
        if isOn {
            // Lit-стекло: бирюзовая заливка + мягкое свечение-глубина.
            layer.backgroundColor = fillAccent.withAlphaComponent(dark ? 0.92 : 0.88).cgColor
            layer.borderWidth = 0
            layer.masksToBounds = false
            layer.shadowColor = (isBuiltin ? Design.Color.accentInk(dark) : fillAccent).cgColor
            layer.shadowOpacity = dark ? 0.55 : 0.35
            layer.shadowRadius = 7
            layer.shadowOffset = CGSize(width: 0, height: -2)
            iconView.contentTintColor = .white
            label.textColor = .white
        } else {
            // Empty-стекло: почти прозрачная заливка + тонкая световая кромка.
            layer.backgroundColor = Design.Color.controlFill(dark).cgColor
            layer.borderWidth = 1
            layer.borderColor = Design.Color.surfaceRim(dark).cgColor
            layer.shadowOpacity = 0
            iconView.contentTintColor = .secondaryLabelColor
            label.textColor = .labelColor
        }
        if window?.firstResponder === self {
            layer.borderWidth = 2
            layer.borderColor = NSColor.keyboardFocusIndicatorColor.cgColor
        }
    }
    func refresh() { if let p = stateProvider { isOn = p() } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    /// Активация (нажатие): мягкая анимация + onClick. Общая для мыши, клавиатуры и VoiceOver.
    /// press-микроанимация gated Motion.reduced (как GlassButton/tile-кнопка), длительность — токен durFast.
    private func activate() {
        if !Motion.reduced {
            let press = CABasicAnimation(keyPath: "transform.scale")
            press.fromValue = 0.96; press.toValue = 1.0; press.duration = Design.Motion.durFast
            layer?.add(press, forKey: "press")
        }
        onClick?()
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
        if accepted { restyle() }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { restyle() }
        return resigned
    }
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 49 || event.keyCode == 36) && !event.isARepeat { activate() }
        else { super.keyDown(with: event) }
    }

    // MARK: VoiceOver — переключатели и команды не выдают себя друг за друга
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { isMomentaryAction ? .button : .checkBox }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityValue() -> Any? { isMomentaryAction ? nil : (isOn ? 1 : 0) }
    override func accessibilityPerformPress() -> Bool { activate(); return true }
}
