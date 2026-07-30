import AppKit

/// Перевёрнутый clip-view: начало координат находится сверху, поэтому содержимое
/// поповера прижато к верхней границе и прокручивается вниз.
final class TopClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// Невидимый overlay-scroller. Прокрутка трекпадом и колёсиком остаётся доступной,
/// но системный индикатор не занимает место в компактном поповере.
final class HiddenScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func draw(_ dirtyRect: NSRect) {}
    override var alphaValue: CGFloat {
        get { 0 }
        set {}
    }
}

/// Стеклянный контейнер, сообщающий владельцу о смене light/dark appearance.
final class GlassContainer: NSVisualEffectView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
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

/// Нейтральная интерактивная капсула. Цвет состояния принадлежит вложенному
/// индикатору, а поверхность остаётся одинаковой для всех уровней здоровья.
final class CapsuleView: NSView {
    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    var onClick: (() -> Void)? {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Design.Radius.chip
        layer?.cornerCurve = .continuous
        restyle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func mouseDown(with event: NSEvent) {
        guard let onClick else {
            super.mouseDown(with: event)
            return
        }
        if !Motion.reduced {
            let press = CABasicAnimation(keyPath: "transform.scale")
            press.fromValue = 0.96
            press.toValue = 1
            press.duration = Design.Motion.durFast
            layer?.add(press, forKey: "press")
        }
        onClick()
    }

    override func resetCursorRects() {
        guard onClick != nil else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func isAccessibilityElement() -> Bool {
        onClick != nil
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        .button
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }

    func restyle() {
        layer?.backgroundColor = Design.Color.controlFill(isDark).cgColor
    }
}
