import AppKit

/// Перевёрнутый clip-view: начало координат находится сверху, поэтому содержимое
/// поповера прижато к верхней границе и прокручивается вниз.
final class TopClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// Стеклянный контейнер, сообщающий владельцу о смене light/dark appearance.
///
/// На Big Sur viewDidChangeEffectiveAppearance может сработать СИНХРОННО прямо внутри присвоения
/// material/blendingMode/state (т.е. во время loadView popover'а). Синхронный callback мог снова
/// войти в loadView → переполнение стека. Поэтому уведомление ОТЛОЖЕНО в async и объединено:
/// десятки одинаковых событий за один layout cycle схлопываются в один вызов applyTheme.
final class GlassContainer: NSVisualEffectView {
    var onAppearanceChange: (() -> Void)?
    private var appearanceUpdateScheduled = false

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()

        guard !appearanceUpdateScheduled else { return }
        appearanceUpdateScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appearanceUpdateScheduled = false
            self.onAppearanceChange?()
        }
    }
}

/// Иконка футера с единым hover-оформлением.
final class FooterIconButton: NSButton {
    private var hovering = false
    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    func setup() {
        wantsLayer = true
        layer?.cornerRadius = Design.Radius.control
        layer?.cornerCurve = .continuous
        restyle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseEnteredAndExited],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        restyle()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        restyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        layer?.backgroundColor = hovering
            ? Design.Color.controlFill(isDark).cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = hovering ? 1 : 0
        layer?.borderColor = hovering
            ? Design.Color.rimHighlight(isDark, 0.18).cgColor
            : NSColor.clear.cgColor
        contentTintColor = hovering ? .labelColor : .secondaryLabelColor
    }
}

/// Тема-зависимый hairline-разделитель.
final class HairlineView: NSView {
    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        restyle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        layer?.backgroundColor = Design.Color.hairline(isDark, 0.07).cgColor
    }
}

/// Световой шов безеля, использующий токены дизайн-системы.
final class RimLightView: NSView {
    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        restyle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        layer?.backgroundColor = Design.Color.rimHighlight(isDark, 0.18).cgColor
    }
}

/// Строка-действие без скрытого gesture recognizer: корректно обрабатывает
/// отпускание мыши, клавиатуру, курсор и VoiceOver.
final class PopoverActionRow: NSStackView {
    var onPress: (() -> Void)? {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    var accessibilityText = ""
    private var pressed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Design.Radius.control
        layer?.cornerCurve = .continuous
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func mouseDown(with event: NSEvent) {
        guard onPress != nil else { return }
        window?.makeFirstResponder(self)
        pressed = true
        alphaValue = 0.68
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed else { return }
        alphaValue = bounds.contains(convert(event.locationInWindow, from: nil)) ? 0.68 : 1
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        alphaValue = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) { activate() }
    }

    override func resetCursorRects() {
        if onPress != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override var acceptsFirstResponder: Bool { onPress != nil }
    override var canBecomeKeyView: Bool { onPress != nil }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { showFocus(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { showFocus(false) }
        return resigned
    }
    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 49 || event.keyCode == 36) && !event.isARepeat { activate() }
        else { super.keyDown(with: event) }
    }

    private func activate() { onPress?() }
    private func showFocus(_ visible: Bool) {
        layer?.borderWidth = visible ? 2 : 0
        layer?.borderColor = visible ? NSColor.keyboardFocusIndicatorColor.cgColor : NSColor.clear.cgColor
    }

    override func isAccessibilityElement() -> Bool { onPress != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { accessibilityText }
    override func accessibilityPerformPress() -> Bool {
        guard onPress != nil else { return false }
        activate()
        return true
    }
}
