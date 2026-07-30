import AppKit
import QuartzCore

/// Нижняя инфо-полоса вкладки «Поток»: ряд мини-виджетов (CAPS-подпись над моно-числом), каждый —
/// кликабельный пин/анпин. Дефолт-набор виден всегда; «доступные» добавляются пином. Механика пинов —
/// точная копия HardwareView.flow→hardware.pinned + fly-to-pin (UserDefaults "flow.pinned"). Полоса
/// заполняет пустое место под схемой, не раздувая FlowView (отдельный подвью в vstack плитки).
///
/// ЧЕСТНОСТЬ: на десктопе (нет АКБ) батарейные виджеты (циклы/здоровье/время-от-батареи) скрыты —
/// нечего показывать. Энергия/пик/время — «за сессию», БЕЗ диск-персиста (так подписано в тултипе).
final class FlowInfoBar: NSView {

    /// Снимок данных для полосы — собирается хостом раз в тик (battery + session + topApp).
    struct Feed {
        var hasBattery = true
        var cycleCount = 0
        var health = 0.0          // %
        var capacityWh = 0.0      // Вт·ч
        var onBattery = false     // сейчас на батарее (для «время от батареи»)
        var topApp: String?       // имя главного потребителя (или nil)
    }

    /// Каждый виджет — id + локализованный caps-заголовок + замыкание-значение (живое, читается в render).
    private struct Widget {
        let id: String
        let cap: () -> String
        let value: () -> String?           // nil → виджет недоступен сейчас (на десктопе и т.п.) → не показываем
        let needsBattery: Bool
    }

    private final class Cell: NSView {
        let id: String
        let cap = CATextLayer()
        let val = CATextLayer()
        var onClick: ((String) -> Void)?
        var onHover: ((String?) -> Void)?
        var axLabel = ""
        var pinned = false
        private let scale: CGFloat = 2
        init(id: String) {
            self.id = id
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = Design.Radius.infoBar; layer?.cornerCurve = .continuous; layer?.masksToBounds = false   // B3: было 7
            // V6: пары весов зеркалят узлы схемы (имя 9 regular / число моно-12 semibold) —
            // одноранговые элементы вкладки набраны ОДНОЙ парой, а не двумя
            cap.contentsScale = scale; cap.alignmentMode = .center; cap.truncationMode = .end
            cap.font = NSFont.systemFont(ofSize: 9, weight: .regular); cap.fontSize = 9
            val.contentsScale = scale; val.alignmentMode = .center; val.truncationMode = .end
            val.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold); val.fontSize = 12
            layer?.addSublayer(cap); layer?.addSublayer(val)
            focusRingType = .default
            applyResolvedColors()
        }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
        private func resolved(_ color: NSColor) -> NSColor {
            Design.Color.resolved(color, dark: isDark)
        }
        private func applyResolvedColors() {
            cap.foregroundColor = resolved(.secondaryLabelColor).cgColor
            val.foregroundColor = resolved(.labelColor).cgColor
        }
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyResolvedColors()
        }
        override func layout() {
            super.layout()
            let w = bounds.width, h = bounds.height
            cap.frame = CGRect(x: 2, y: 4, width: w - 4, height: 11)
            val.frame = CGRect(x: 2, y: h - 18, width: w - 4, height: 15)
        }
        func set(cap c: String, value v: String, pinned: Bool, tint: NSColor) {
            self.pinned = pinned
            // V6 де-КАПС: обычный регистр без трекинга — последний остаточный КАПС вкладки снят
            // (закон «подписи обычным регистром»); ранг серого = secondaryLabel (один на все подписи).
            cap.string = NSAttributedString(string: c,
                attributes: [.font: NSFont.systemFont(ofSize: 9, weight: .regular),
                             .foregroundColor: pinned ? tint : resolved(.secondaryLabelColor)])
            CATransaction.begin(); CATransaction.setDisableActions(true)
            val.foregroundColor = resolved(.labelColor).cgColor
            val.string = v
            CATransaction.commit()
        }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds,
                options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
        }
        override func mouseEntered(with e: NSEvent) { setHover(true); onHover?(id) }
        override func mouseExited(with e: NSEvent) { setHover(false); onHover?(nil) }
        override func mouseDown(with e: NSEvent) { onClick?(id) }
        private func setHover(_ on: Bool) {
            CATransaction.begin(); CATransaction.setAnimationDuration(Motion.reduced ? 0 : Design.Motion.durFast)
            layer?.backgroundColor = on ? Design.Color.accent(isDark).withAlphaComponent(isDark ? 0.10 : 0.12).cgColor
                                        : NSColor.clear.cgColor
            CATransaction.commit()
        }
        override var acceptsFirstResponder: Bool { true }
        override func becomeFirstResponder() -> Bool { onHover?(id); return true }
        override func keyDown(with e: NSEvent) {
            if e.keyCode == 49 || e.keyCode == 36 { onClick?(id) } else { super.keyDown(with: e) }
        }
        override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: Design.Radius.infoBar, yRadius: Design.Radius.infoBar).fill() }   // B3: было 7
        override var focusRingMaskBounds: NSRect { bounds }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityLabel() -> String? {
            axLabel + " · " + (pinned ? L("открепить") : L("закрепить"))
        }
        override func accessibilityPerformPress() -> Bool { onClick?(id); return true }
    }

    /// Разбор наведённого виджета — для подписи под схемой (тот же сток, что у узлов).
    var detailSink: ((String?) -> Void)?

    private var feed = Feed()
    private var cells: [String: Cell] = [:]
    private let row = NSStackView()
    /// pinned = id опциональных виджетов, добавленных ПОВЕРХ дефолта (как hardware.pinned).
    private var pinned: [String] = (UserDefaults.standard.array(forKey: "flow.pinned") as? [String]) ?? []
    private var hovered: String?

    // дефолт-набор (виден всегда) + доступные (по пину).
    // Дедуп (L4): ЦИКЛЫ/ЗДОРОВЬЕ убраны из дефолта — они дублируют консоль батареи, а здоровье>100%
    // должно жить в ОДНОМ доме (батарея-дриллдаун). Взамен в дефолт — «Потребитель» (топ-приложение
    // по расходу): высокий ватт становится действенным прямо тут (инлайн-виновник из брифа). Циклы/
    // здоровье остаются доступны по пину.
    private let defaultIDs = ["uptime", "energy", "topapp"]
    private let optionalIDs = ["cycles", "health", "peaktemp", "onbattery"]

    private lazy var widgets: [String: Widget] = [
        "uptime": Widget(id: "uptime", cap: { L("Аптайм") }, value: { Self.uptimeStr() }, needsBattery: false),
        "cycles": Widget(id: "cycles", cap: { L("Циклы") },
            value: { [weak self] in self.map { String($0.feed.cycleCount) } }, needsBattery: true),
        "health": Widget(id: "health", cap: { L("Здоровье") },
            value: { [weak self] in self.map { String(format: "%.0f%%", $0.feed.health) } }, needsBattery: true),
        "energy": Widget(id: "energy", cap: { L("За сессию") },
            // мёртвый ноль честнее тире: «0.0 Вт·ч» на видном месте читался как сломанный счётчик
            value: { SessionEnergy.wattHours < 0.1 ? "—" : String(format: L("%.1f Вт·ч"), SessionEnergy.wattHours) },
            needsBattery: false),
        "peaktemp": Widget(id: "peaktemp", cap: { L("Пик °C") },
            value: { SessionEnergy.peakTemp.map { String(format: "%.0f°", $0) } }, needsBattery: false),
        "onbattery": Widget(id: "onbattery", cap: { L("От батареи") },
            value: { Self.durStr(SessionEnergy.onBatterySeconds) }, needsBattery: true),
        "topapp": Widget(id: "topapp", cap: { L("Потребитель") },
            // честное «—» до первого замера ВМЕСТО скрытия: иначе колонки полосы прыгали
            // по центрам, когда виджет появлялся со вторым тиком
            value: { [weak self] in self.flatMap { $0.feed.topApp } ?? "—" }, needsBattery: false),
    ]

    override init(frame: NSRect) { super.init(frame: frame); commonInit() }
    required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }
    override var isFlipped: Bool { true }
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { L("Сводка за сессию") }

    private func commonInit() {
        wantsLayer = true; layer?.masksToBounds = false
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// id виджетов в текущем порядке: дефолт + закреплённые (только доступные сейчас).
    private func activeIDs() -> [String] {
        var ids = defaultIDs + pinned.filter { optionalIDs.contains($0) }
        // на десктопе батарейные виджеты опускаем честно
        if !feed.hasBattery { ids = ids.filter { !(widgets[$0]?.needsBattery ?? false) } }
        // у недоступных значений (nil) виджет тоже не показываем (например topApp ещё не пришёл)
        return ids.filter { widgets[$0]?.value() != nil }
    }

    /// Хост подаёт свежий снимок раз в тик — пересобираем ряд, если состав сменился, иначе обновляем значения.
    func update(_ f: Feed) {
        feed = f
        let ids = activeIDs()
        let want = Set(ids)
        // создаём недостающие ячейки, прячем лишние
        for id in ids where cells[id] == nil {
            let c = Cell(id: id)
            c.translatesAutoresizingMaskIntoConstraints = false
            c.onClick = { [weak self] in self?.togglePin($0) }
            c.onHover = { [weak self] in self?.setHover($0) }
            cells[id] = c
        }
        // перестроить порядок стека под ids (дёшево — ≤7 вью)
        let current = row.arrangedSubviews.compactMap { ($0 as? Cell)?.id }
        if current != ids {
            row.arrangedSubviews.forEach { row.removeArrangedSubview($0); $0.removeFromSuperview() }
            for id in ids { if let c = cells[id] { row.addArrangedSubview(c) } }
        }
        let pinnedSet = Set(pinned)
        let tint = Design.Color.accent(isDark)
        for id in ids {
            guard let c = cells[id], let w = widgets[id], let v = w.value() else { continue }
            c.set(cap: w.cap(), value: v, pinned: pinnedSet.contains(id), tint: tint)
            c.axLabel = w.cap() + " " + v
        }
        _ = want   // (порядок уже синхронизирован выше)
        // эмитим ТОЛЬКО когда курсор реально над ячейкой полосы: безусловный emitDetail() слал nil
        // в ОБЩИЙ flowDetail-сток каждый тик и стирал живой разбор узла схемы под курсором
        if hovered != nil { emitDetail() }
    }

    private func togglePin(_ id: String) {
        guard optionalIDs.contains(id) || pinned.contains(id) else {
            // тап по ДЕФОЛТ-виджету — даём «доступные» добавить через… сам дефолт не пинуется/анпинуется.
            // Семантика: дефолт всегда виден; пином управляются только опциональные.
            return
        }
        if let i = pinned.firstIndex(of: id) { pinned.remove(at: i) }
        else { pinned.append(id); flyToPin(id) }
        UserDefaults.standard.set(pinned, forKey: "flow.pinned")
        update(feed)
    }

    /// fly-to-pin: дубль-ячейки летит на её место (клон HardwareView.flyToPin). Под reduced — мгновенно.
    private func flyToPin(_ id: String) {
        guard !Motion.reduced, let c = cells[id], let host = layer else { return }
        let ghost = CALayer()
        ghost.frame = c.frame.isEmpty ? bounds : c.frame
        ghost.backgroundColor = Design.Color.accent(isDark).withAlphaComponent(0.18).cgColor
        ghost.cornerRadius = Design.Radius.infoBar   // B3: было 7 (совпадает со скруглением капсулы-источника)
        host.addSublayer(ghost)
        let a = CABasicAnimation(keyPath: "transform.scale")
        a.fromValue = 0.6; a.toValue = 1.0
        a.duration = Design.Motion.durBase
        a.timingFunction = Design.Motion.overshoot
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 0.7; fade.toValue = 0
        fade.duration = Design.Motion.durBase
        CATransaction.begin()
        CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
        ghost.opacity = 0
        ghost.add(a, forKey: "fly"); ghost.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    private func setHover(_ id: String?) {
        guard id != hovered else { return }
        hovered = id; emitDetail()
    }
    private func emitDetail() {
        guard let id = hovered, let w = widgets[id], let v = w.value() else { detailSink?(nil); return }
        let hint = optionalIDs.contains(id) ? " · " + (pinned.contains(id) ? L("открепить") : L("закрепить")) : ""
        let suffix = (id == "energy" || id == "peaktemp" || id == "onbattery") ? " · " + L("за сессию") : ""
        detailSink?(w.cap() + " · " + v + suffix + hint)
    }

    // — форматтеры —
    private static func uptimeStr() -> String? {
        guard let s = SystemUptime.seconds() else { return nil }
        return durStr(s)
    }
    /// «N дн M ч» / «N ч M мин» / «N мин» — компактно, без лишних нулей.
    private static func durStr(_ seconds: Double) -> String? {
        guard seconds >= 0 else { return nil }
        let total = Int(seconds)
        let d = total / 86400, h = (total % 86400) / 3600, m = (total % 3600) / 60
        if d > 0 { return String(format: L("%d дн %d ч"), d, h) }
        if h > 0 { return String(format: L("%d ч %d мин"), h, m) }
        return String(format: L("%d мин"), m)
    }
}
