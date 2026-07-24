import AppKit

/// Строка-тумблер для NSMenu, которая НЕ закрывает меню при клике (владелец: «когда нажимаю
/// что-нибудь, оно не должно закрываться — там ещё есть функции», хочет щёлкать твики подряд).
///
/// Механика: единственный санкционированный AppKit-способ «клик без закрытия» — custom view
/// у NSMenuItem: клики внутри item.view не завершают tracking, пока view сам не позовёт
/// cancelTracking. Мы его НЕ зовём → меню живёт, галочка обновляется на месте.
///
/// Вид повторяет нативный пункт: зона галочки слева → template-иконка → заголовок 13pt;
/// hover — скруглённая подсветка selectedContentBackgroundColor с белым текстом (Big Sur-грамматика).
final class MenuToggleRow: NSView {
    private let check = NSImageView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let hilite = NSView()
    private let state: () -> Bool
    private let onToggle: () -> Void
    private var hovered = false

    static let rowWidth: CGFloat = 270
    static let rowHeight: CGFloat = 24

    init(title: String, symbol: String?, state: @escaping () -> Bool, onToggle: @escaping () -> Void) {
        self.state = state
        self.onToggle = onToggle
        super.init(frame: NSRect(x: 0, y: 0, width: Self.rowWidth, height: Self.rowHeight))
        autoresizingMask = [.width]

        hilite.wantsLayer = true
        hilite.layer?.cornerRadius = 4
        hilite.layer?.cornerCurve = .continuous
        hilite.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hilite)

        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .bold))
        check.contentTintColor = .labelColor
        check.translatesAutoresizingMaskIntoConstraints = false
        addSubview(check)

        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            img.isTemplate = true
            icon.image = img.withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        }
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        label.stringValue = title
        label.font = .menuFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.rowHeight),
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.rowWidth),
            hilite.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            hilite.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            hilite.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            hilite.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 12),
            icon.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Перечитать состояние из stateProvider (галочка «на месте», без закрытия меню).
    func refresh() {
        check.isHidden = !state()
        applyColors()
    }

    private func applyColors() {
        if hovered {
            hilite.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
            label.textColor = .white
            icon.contentTintColor = .white
            check.contentTintColor = .white
        } else {
            hilite.layer?.backgroundColor = NSColor.clear.cgColor
            label.textColor = .labelColor
            icon.contentTintColor = .secondaryLabelColor
            check.contentTintColor = .labelColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; applyColors() }
    override func mouseExited(with event: NSEvent) { hovered = false; applyColors() }
    override func mouseUp(with event: NSEvent) {
        onToggle()
        refresh()                                   // мгновенный отклик; async-состояния доведёт 1Гц-таймер меню
    }

    // VoiceOver: строка = чекбокс с текущим состоянием
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityLabel() -> String? { label.stringValue }
    override func accessibilityValue() -> Any? { state() ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool { onToggle(); refresh(); return true }
}
