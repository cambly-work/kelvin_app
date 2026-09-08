//
//  PopoverWidgets.swift
//  Kelvin
//
//  Изолированные NSView-виджеты поповера. Извлечены из main.swift для читаемости.
//

import AppKit

/// Сегмент-контрол в стиле Control Center: лёгкий frosted-трек + скользящая пилюля
/// фирменного бренд-акцента. Заменяет стоковый NSSegmentedControl (тяжёлая системная
/// капсула выпадала из «стекла»). Кнопки дают бесплатную доступность/клавиатуру.
final class PillTabBar: NSView {
    private let labels: [String]
    private let icons: [String]?                 // SF-символы; при 5+ вкладках рисуем иконки (текст не влезает)
    private var iconMode: Bool { icons != nil && labels.count >= 5 }
    private var buttons: [NSButton] = []
    private let pill = NSView()
    /// Тихие warn/crit-точки-оверлеи (по одной на вкладку): спокойная машина — точек нет.
    /// Оверлей поверх ярлыка, НЕ влияет на высоту таб-бара (fixed-height-инвариант).
    private var dots: [NSView] = []
    private var dotLevels: [Design.Level?] = []
    private(set) var selectedIndex: Int
    var onSelect: ((Int) -> Void)?
    /// Отключает сегменты на время асинхронного системного действия, сохраняя
    /// выбранную пилюлю и визуальную геометрию контрола.
    var isInteractionEnabled = true {
        didSet {
            buttons.forEach { $0.isEnabled = isInteractionEnabled }
            alphaValue = isInteractionEnabled ? 1 : 0.58
        }
    }
    /// Повторный тап по УЖЕ выбранному сегменту (для disclosure-паттернов: «Лимит» открывает/прячет бар).
    var onReselect: ((Int) -> Void)?
    /// Цвет активной пилюли: nil → дефолтный accentMuted (истор. саб-бары). Домен-рельс ставит сюда
    /// цвет ТЕПЛОВОГО РЕЖИМА (spокоен→бирюза/нагрузка→янтарь/жара→красный) — навигация дышит вместе с прибором.
    var pillColor: NSColor? { didSet { if pillColor != oldValue { applyTheme() } } }

    init(labels: [String], icons: [String]? = nil, selected: Int) {
        self.labels = labels
        self.icons = icons
        self.selectedIndex = min(max(selected, 0), max(labels.count - 1, 0))
        self.dotLevels = Array(repeating: nil, count: labels.count)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Design.Radius.track
        layer?.cornerCurve = .continuous
        pill.wantsLayer = true
        pill.layer?.cornerRadius = Design.Radius.pill
        pill.layer?.cornerCurve = .continuous
        addSubview(pill)
        for (i, t) in labels.enumerated() {
            let b = NSButton(title: t, target: self, action: #selector(tap(_:)))
            b.tag = i
            b.isBordered = false
            b.setButtonType(.momentaryChange)
            b.cell?.usesSingleLineMode = true                    // без переноса: длинные ярлыки жмём кеглем, не в 2 строки
            b.imageScaling = .scaleProportionallyDown
            if iconMode { b.toolTip = t }                        // имя вкладки во всплывашке (иконки без текста)
            b.translatesAutoresizingMaskIntoConstraints = true   // кладём по frame в layout()
            buttons.append(b)
            addSubview(b)
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 2.5
            dot.layer?.cornerCurve = .continuous
            dot.isHidden = true
            dots.append(dot)
            addSubview(dot)
        }
        applyTheme()
    }

    /// Тихая точка статуса на вкладке: nil — нет точки (спокойная машина), .warn/.crit — цвет семантики.
    /// Зовётся из update(); дёшево (no-op при том же состоянии), оверлей не трогает геометрию ярлыков.
    func setDot(_ index: Int, _ level: Design.Level?) {
        guard index >= 0, index < dots.count, dotLevels[index] != level else { return }
        dotLevels[index] = level
        let dot = dots[index]
        if let level {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = level == .crit ? Design.Color.levelCrit : Design.Color.levelWarn
            dot.layer?.backgroundColor = (dark ? c : (c.blended(withFraction: 0.18, of: .black) ?? c)).cgColor
            dot.isHidden = false
        } else {
            dot.isHidden = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func tap(_ sender: NSButton) {
        guard isInteractionEnabled else { return }
        guard sender.tag != selectedIndex else { onReselect?(sender.tag); return }   // повторный тап — не onSelect (иначе повторный модал), но disclosure-хук
        select(sender.tag, animated: !Motion.reduced)
        onSelect?(sender.tag)
    }

    func select(_ i: Int, animated: Bool) {
        guard i >= 0, i < buttons.count else { return }
        selectedIndex = i
        restyle()
        movePill(animated: animated)
    }

    override func layout() {
        super.layout()
        let n = CGFloat(buttons.count); guard n > 0 else { return }
        restyle()                       // подогнать кегль под ширину сегмента (иначе 4 длинных ярлыка переносятся)
        let segW = bounds.width / n
        for (i, b) in buttons.enumerated() {
            b.frame = NSRect(x: CGFloat(i) * segW, y: 0, width: segW, height: bounds.height)
            // точка-оверлей: справа от текста ярлыка, у верхней кромки сегмента (геометрию не трогает)
            let d: CGFloat = 5
            let contentW = iconMode ? 15 : (labels[i] as NSString).size(withAttributes: [.font: b.font as Any]).width
            let dx = CGFloat(i) * segW + (segW + contentW) / 2 + 4
            dots[i].frame = NSRect(x: min(dx, CGFloat(i + 1) * segW - d - 2),
                                   y: bounds.height - d - 6, width: d, height: d)
        }
        movePill(animated: false)
    }

    private func movePill(animated: Bool) {
        let n = CGFloat(buttons.count); guard n > 0, bounds.width > 0 else { return }
        let segW = bounds.width / n
        let target = NSRect(x: CGFloat(selectedIndex) * segW + 2, y: 2, width: segW - 4, height: bounds.height - 4)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Design.Motion.durBase
                ctx.timingFunction = Design.Motion.overshoot   // «магнитный» микро-перелёт пилюли
                pill.animator().frame = target
            }
        } else {
            pill.frame = target
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func applyTheme() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = Design.Color.tabTrack(dark).cgColor
        pill.layer?.backgroundColor = (pillColor.map { $0.withAlphaComponent(dark ? 0.22 : 0.26) }
                                       ?? Design.Color.accentMuted(dark)).cgColor
        // rim-light кромка активной пилюли — тот же безель-шов, что у плиток (objёмный край из света)
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = Design.Color.rimHighlight(dark, 0.18).cgColor
        for (i, lvl) in dotLevels.enumerated() where lvl != nil {   // перекрасить точки под новую тему
            dotLevels[i] = nil; setDot(i, lvl)        // сброс кэша → setDot перерисует под текущую тему
        }
        restyle()
    }

    private func restyle() {
        if iconMode, let icons {
            let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            for (i, b) in buttons.enumerated() {
                let active = (i == selectedIndex)
                b.attributedTitle = NSAttributedString(string: "")
                b.image = NSImage(systemSymbolName: icons[i], accessibilityDescription: labels[i])?.withSymbolConfiguration(cfg)
                b.imagePosition = .imageOnly
                b.contentTintColor = active ? .labelColor : .secondaryLabelColor
            }
            return
        }
        let center = NSMutableParagraphStyle(); center.alignment = .center; center.lineBreakMode = .byTruncatingTail
        let size = fittedFontSize()
        for (i, b) in buttons.enumerated() {
            let active = (i == selectedIndex)
            b.image = nil
            b.attributedTitle = NSAttributedString(string: labels[i], attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: active ? .semibold : .medium),
                .foregroundColor: active ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: center])
        }
    }

    /// Наибольший кегль в [9…12], при котором самый длинный ярлык влезает в сегмент ОДНОЙ строкой.
    /// Нужно с 4 вкладками: «Приложения»/«Приватность» при 12pt не помещаются в ~76px и переносятся.
    private func fittedFontSize() -> CGFloat {
        let n = CGFloat(buttons.count)
        guard n > 0, bounds.width > 0 else { return 12 }
        let segW = bounds.width / n - 10                 // минус внутренние отступы сегмента/пилюли
        var size: CGFloat = 12
        while size > 9 {
            let f = NSFont.systemFont(ofSize: size, weight: .semibold)
            let widest = labels.map { ($0 as NSString).size(withAttributes: [.font: f]).width }.max() ?? 0
            if widest <= segW { break }
            size -= 0.5
        }
        return size
    }
}

/// Мини-спарклайн истории impact (грамматика HardwareView.renderTrace): встыковые сегменты +
/// кромка. Безразмерный (НЕ ватты, НЕ GraphView с осью Вт). Данные — AppSession.history.
/// Motion.reduced-нейтрален (renderTrace без анимаций, cap setDisableActions).
final class MiniSpark: NSView {
    private var hist: [Double] = []
    var tint: NSColor = .systemTeal
    /// Ж4: герой шире/выше строк — на lineWidth 1 линия читалась тоньше. heavy → 1.5, чтобы вес совпал на глаз.
    var heavy = false { didSet { line.lineWidth = heavy ? 1.5 : 1; render() } }
    private let line = CAShapeLayer()
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; setup() }
    required init?(coder: NSCoder) { fatalError() }
    private func setup() {
        line.fillColor = NSColor.clear.cgColor
        line.lineWidth = 1
        line.lineJoin = .round
        layer?.addSublayer(line)
    }
    func setHistory(_ h: [Double], tint: NSColor) { self.hist = h; self.tint = tint; render() }
    override func layout() { super.layout(); render() }
    private func render() {
        guard let host = layer else { return }
        let W = bounds.width, H = bounds.height
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var segs = host.sublayers?.filter { $0 !== line } ?? []
        // O13: <2 точек истории (карта новая ~первые 10с) — рисуем плоскую baseline-линию tint 0.3 во всю
        // ширину, а не прячем всё: зарезервированный слот не «дырявит» макет пустой прорезью у имени.
        guard W > 1, hist.count >= 2 else {
            segs.forEach { $0.isHidden = true }
            if W > 1 {
                let mid = H / 2
                let base = CGMutablePath()
                base.move(to: CGPoint(x: 0, y: mid)); base.addLine(to: CGPoint(x: W, y: mid))
                line.path = base
                line.strokeColor = tint.withAlphaComponent(0.3).cgColor
                line.isHidden = false
            } else { line.isHidden = true }
            return
        }
        let lo = hist.min() ?? 0, hi = hist.max() ?? 1
        let span = max(hi - lo, 0.0001)
        func norm(_ v: Double) -> CGFloat { CGFloat(max(0, min(1, (v - lo) / span))) }
        let count = hist.count
        let segW = W / CGFloat(count)
        let segWidth = segW + 0.5
        while segs.count < count { let l = CALayer(); host.insertSublayer(l, below: line); segs.append(l) }
        for i in count..<segs.count { segs[i].isHidden = true }
        let edge = CGMutablePath()
        for (i, v) in hist.enumerated() {
            let seg = segs[i]; seg.isHidden = false; seg.removeAllAnimations()
            let hgt = max(1, norm(v) * H)
            let x = CGFloat(i) * segW
            let wd = (i == count - 1) ? max(W - x, segWidth) : segWidth
            seg.frame = CGRect(x: x, y: H - hgt, width: wd, height: hgt)
            seg.backgroundColor = tint.withAlphaComponent(0.5).cgColor
            if i == 0 { edge.move(to: CGPoint(x: x, y: H - hgt)) } else { edge.addLine(to: CGPoint(x: x, y: H - hgt)) }
            edge.addLine(to: CGPoint(x: x + segW, y: H - hgt))
        }
        line.path = edge; line.strokeColor = tint.cgColor; line.isHidden = false
    }
}

/// Кликабельная обёртка строки лидерборда (Batch D): тап → флип на досье приложения.
/// Несёт стеклянную подложку строки и ширину IW; press/hover — состояние (не движение, ок при reduced).
final class DossierRowView: NSView {
    weak var owner: PopoverController?
    var appName: String = ""          // СЫРОЕ a.name — ключ корреляции
    var a11yText: String = ""
    var isHero = false                // герой не приподнимается/не раскрывается — он уже раскрыт
    // Ссылки на мутируемый контент — FLIP-переиспользование обновляет НА МЕСТЕ (не пересоздаёт вью).
    weak var valLabel: NSTextField?
    weak var fillWidth: NSLayoutConstraint?
    weak var spark: MiniSpark?
    weak var flagHost: NSView?        // контейнер флага (пересобираем при смене страны)
    weak var microLine: NSTextField?  // герой: строка CPU · MEM
    var barW: CGFloat = 64
    private var pressed = false
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    /// Базовый фон строки — controlFill; герой перекрашивается отдельно (accent-tint), сохраняем.
    var baseFill: CGColor?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        pressed = true
        layer?.opacity = 0.7
    }
    override func mouseDragged(with event: NSEvent) {
        guard pressed else { return }
        layer?.opacity = bounds.contains(convert(event.locationInWindow, from: nil)) ? 0.7 : 1
    }
    override func mouseUp(with event: NSEvent) {
        layer?.opacity = 1
        let p = convert(event.locationInWindow, from: nil)
        if pressed && bounds.contains(p) { owner?.openDossier(for: appName) }
        pressed = false
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = Design.Color.trackFill(isDark).cgColor
        guard !isHero else { return }
        // Небольшое hover-приподнятие показывает кликабельность, не перекрывая соседние строки.
        if !Motion.reduced, let lyr = layer {
            let s: CGFloat = 1.012
            let tx = bounds.width * (1 - s) / 2, ty = bounds.height * (1 - s) / 2
            CATransaction.begin(); CATransaction.setAnimationDuration(Design.Motion.durFast)
            lyr.transform = CATransform3DConcat(CATransform3DMakeScale(s, s, 1),
                                                CATransform3DMakeTranslation(tx, ty, 0))
            lyr.shadowColor = NSColor.black.cgColor
            lyr.shadowOpacity = isDark ? 0.22 : 0.14
            lyr.shadowRadius = 5; lyr.shadowOffset = CGSize(width: 0, height: -1.5)
            lyr.masksToBounds = false
            CATransaction.commit()
        }
        owner?.setRowHover(appName, entered: true)   // строка не должна переехать прямо под курсором
    }
    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = baseFill ?? Design.Color.controlFill(isDark).cgColor
        guard !isHero else { return }
        if !Motion.reduced {
            CATransaction.begin(); CATransaction.setAnimationDuration(Design.Motion.durFast)
            layer?.transform = CATransform3DIdentity
            layer?.shadowOpacity = 0
            CATransaction.commit()
        }
        owner?.setRowHover(appName, entered: false)   // применить отложенный снимок после выхода
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
        if (event.keyCode == 49 || event.keyCode == 36) && !event.isARepeat {
            owner?.openDossier(for: appName)
        } else {
            super.keyDown(with: event)
        }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { a11yText }
    override func accessibilityPerformPress() -> Bool { owner?.openDossier(for: appName); return true }
}
