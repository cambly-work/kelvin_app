import AppKit
import CoreAudio   // AudioDeviceID для плитки «Звук · вывод» (переключение системного вывода)

// MARK: - UI поповера

/// Перевёрнутый clip-view для вертикального скролла: isFlipped=true → (0,0) сверху-слева,
/// контент прижат к ВЕРХУ и скроллится вниз (иначе NSClipView якорит документ к низу).
final class TopClipView: NSClipView { override var isFlipped: Bool { true } }

/// Скрытый скроллер (V3 «лоск»): контент листается трекпадом/колёсиком, но «лифт» не рисуется —
/// чистый вид поповера (как у Control Center / iStat, где полосы прокрутки нет).
final class HiddenScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func draw(_ dirtyRect: NSRect) {}
    override var alphaValue: CGFloat { get { 0 } set { } }
}

/// Стеклянный контейнер, пробрасывающий смену темы (light/dark).
final class GlassContainer: NSVisualEffectView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

/// Статус-спайн: 2pt вертикальный шов у левой внутренней кромки поповера вдоль колонки данных.
/// Покой — еле заметный hairline; warn/crit — светящийся 32pt сегмент у проблемного модуля
/// (мягкая accentInk-тень, не грязный ореол). Если позицию сегмента чисто вычислить нельзя —
/// деградирует к плоскому hairline во всю высоту (всё ещё безель-шов). Второй потребитель
/// worst-of из refreshHealthVerdict — НЕ пересчитывает сигналы.
final class StatusSpine: NSView {
    private let track = CALayer()      // покой: hairline во всю высоту
    private let glow = CALayer()       // warn/crit: короткий светящийся сегмент
    private let segH: CGFloat = 32     // высота сегмента (фиксированная 32pt)
    private var level: Design.Level = .ok
    private var anchorCenterY: CGFloat?    // центр сегмента в координатах спайна (nil → деградация к hairline)
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    override init(frame: NSRect) { super.init(frame: frame); commonInit() }
    required init?(coder: NSCoder) { fatalError() }
    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.isGeometryFlipped = true        // y растёт вниз — как экранные координаты модулей
        track.cornerRadius = 1
        track.anchorPoint = CGPoint(x: 0.5, y: 0)   // верхняя кромка — для top-down прорисовки
        glow.cornerRadius = 1
        glow.opacity = 0
        glow.masksToBounds = false
        glow.shadowOffset = .zero
        glow.shadowRadius = 5
        layer?.addSublayer(track)
        layer?.addSublayer(glow)
        restyle()
    }
    override var isFlipped: Bool { true }     // y растёт вниз — как экранные координаты модулей
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // track anchor (0.5,0): bounds полной высоты, position у верхней кромки (geometryFlipped → y 0 = верх)
        track.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        track.position = CGPoint(x: bounds.width/2, y: 0)
        layoutGlow()
        CATransaction.commit()
    }
    private func layoutGlow() {
        let cy = anchorCenterY ?? bounds.midY
        let y = max(0, min(bounds.height - segH, cy - segH/2))
        glow.frame = CGRect(x: 0, y: y, width: bounds.width, height: segH)
    }
    private func restyle() {
        let dark = isDark
        track.backgroundColor = Design.Color.hairline(dark, 0.10).cgColor
        // та же светлая-тема −18% затемнение, что у всех семантических поверхностей (точки вкладок,
        // вердикт-точка, чип-трасса): спайн и вердикт-точка — один worst-of, должны читаться одним цветом.
        let raw = level == .crit ? Design.Color.levelCrit : Design.Color.levelWarn
        let c = dark ? raw : (raw.blended(withFraction: 0.18, of: .black) ?? raw)
        glow.backgroundColor = c.withAlphaComponent(0.55).cgColor
        glow.shadowColor = Design.Color.accentInk(dark).cgColor   // мягкая глубинная тень, НЕ грязный цветной ореол
        glow.shadowOpacity = 0.5
    }

    /// Второй потребитель worst-of: уровень + центр проблемного модуля (в КООРДИНАТАХ спайна).
    /// nil-центр → деградация к плоскому hairline (сегмент скрыт). Gate Motion.reduced на появление.
    func apply(level: Design.Level, centerY: CGFloat?) {
        self.level = level
        self.anchorCenterY = (level == .ok) ? nil : centerY
        restyle()
        let show = (level != .ok) && (centerY != nil)
        if Motion.reduced {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layoutGlow(); glow.opacity = show ? 1 : 0
            CATransaction.commit()
            return
        }
        CATransaction.begin(); CATransaction.setDisableActions(true); layoutGlow(); CATransaction.commit()
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = glow.opacity; anim.toValue = show ? 1 : 0
        anim.duration = Design.Motion.durBase
        anim.timingFunction = Design.Motion.easeStandard
        glow.opacity = show ? 1 : 0
        glow.add(anim, forKey: "spineGlow")
    }

    /// Анимация открытия: шов прорисовывается сверху вниз (scale.y 0→1 вокруг верхней кромки).
    /// anchorPoint (0.5,0) уже задан в commonInit. Gate Motion.reduced. Если apply() уже зажёг
    /// warn/crit-свечение (open на проблеме), пере-заводим его reveal с beginTime = длительность
    /// прорисовки шва — чтобы цветной сегмент проявлялся ПОСЛЕ шва, на котором сидит, а не до него.
    func animateIn() {
        guard !Motion.reduced else { return }
        let dur = Design.Motion.durBase
        let a = CABasicAnimation(keyPath: "transform.scale.y")
        a.fromValue = 0; a.toValue = 1
        a.duration = dur
        a.timingFunction = Design.Motion.easeOut
        track.add(a, forKey: "spineDraw")
        if glow.opacity > 0 {                                        // свечение уже целится в 1 → отложить его проявление за шов
            let g = CABasicAnimation(keyPath: "opacity")
            g.fromValue = 0; g.toValue = 1
            g.beginTime = CACurrentMediaTime() + dur                 // ждём, пока шов дорисуется сверху вниз
            g.duration = dur
            g.timingFunction = Design.Motion.easeStandard
            g.fillMode = .backwards                                  // до beginTime держим 0 — сегмент скрыт под рисующимся швом
            glow.add(g, forKey: "spineGlow")                         // перебивает apply()-фейд (тот же ключ)
        }
    }
}

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

/// Иконка-кнопка футера: по умолчанию без рамки/фона (как раньше), при наведении — мягкая
/// controlFill-пилюля + тинт в labelColor (та же сдержанность, что у CCToggle сверху).
final class FooterIconButton: NSButton {
    private var hovering = false
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    func setup() {
        wantsLayer = true
        layer?.cornerRadius = Design.Radius.control
        layer?.cornerCurve = .continuous
        restyle()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; restyle() }
    override func mouseExited(with event: NSEvent) { hovering = false; restyle() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }
    private func restyle() {
        // hover: controlFill-пилюля + 1px rim-light кромка (тот же словарь наведения, что у LimitChip).
        layer?.backgroundColor = hovering ? Design.Color.controlFill(isDark).cgColor : NSColor.clear.cgColor
        layer?.borderWidth = hovering ? 1 : 0
        layer?.borderColor = hovering ? Design.Color.rimHighlight(isDark, 0.18).cgColor : NSColor.clear.cgColor
        contentTintColor = hovering ? .labelColor : .secondaryLabelColor
    }
}

/// Тончайший шов-разделитель: hairline-линия (~0.07), сама перекрашивается под тему.
/// Бренд-шов «приборного безеля» вместо системного NSBox.separator (тот резче и не тема-токенизирован).
final class HairlineView: NSView {
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; restyle() }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }
    private func restyle() { layer?.backgroundColor = Design.Color.hairline(isDark, 0.07).cgColor }
}

/// Световой безель-шов (rim-light ~0.18): тонкий блик-линия, сама перекрашивается под тему.
/// Объёмный край из света — один словарь с rim-кромкой плиток/активной пилюли.
final class RimLightView: NSView {
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; restyle() }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }
    private func restyle() { layer?.backgroundColor = Design.Color.rimHighlight(isDark, 0.18).cgColor }
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

/// Нейтральная controlFill-капсула (как LimitChip, но без действия): несёт вердикт-точку + слово.
/// Сама перекрашивается под тему; цвет несёт только точка (worst-of уровень), фон нейтрален.
final class CapsuleView: NSView {
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    /// Кликабельная капсула вердикта: тап раскрывает деталь поповером (надёжнее капризного
    /// AppKit-таймера всплытия тултипа). nil → капсула инертна (нет pointingHand).
    var onClick: (() -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); commonInit() }
    required init?(coder: NSCoder) { fatalError() }
    private func commonInit() {
        wantsLayer = true
        layer?.cornerRadius = Design.Radius.chip
        layer?.cornerCurve = .continuous
        restyle()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }
    func restyle() { layer?.backgroundColor = Design.Color.controlFill(isDark).cgColor }

    override func mouseDown(with event: NSEvent) {
        guard onClick != nil else { super.mouseDown(with: event); return }
        if !Motion.reduced {
            let press = CABasicAnimation(keyPath: "transform.scale")
            press.fromValue = 0.96; press.toValue = 1.0; press.duration = Design.Motion.durFast
            layer?.add(press, forKey: "press")
        }
        onClick?()
    }
    override func resetCursorRects() { if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) } }
    override func isAccessibilityElement() -> Bool { onClick != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }
}

/// Кликабельная обёртка строки лидерборда (Batch D): тап → флип на досье приложения.
/// Несёт стеклянную подложку строки и ширину IW; press/hover — состояние (не движение, ок при reduced).
final class DossierRowView: NSView {
    weak var owner: PopoverController?
    var appName: String = ""          // СЫРОЕ a.name — ключ корреляции
    var a11yText: String = ""
    var isHero = false                // герой не приподнимается/не раскрывается — он уже раскрыт
    var canExpand = true              // строки лидерборда раскрываются на ховере; герой — нет
    // Ссылки на мутируемый контент — FLIP-переиспользование обновляет НА МЕСТЕ (не пересоздаёт вью).
    weak var valLabel: NSTextField?
    weak var fillWidth: NSLayoutConstraint?
    weak var spark: MiniSpark?
    weak var flagHost: NSView?        // контейнер флага (пересобираем при смене страны)
    weak var microLine: NSTextField?  // герой: строка CPU · MEM
    var barW: CGFloat = 64
    private var pressed = false
    private var expanded = false
    private var overlay: NSView?      // ховер-раскрытие: ОВЕРЛЕЙ (не в arrangedSubviews) — layout соседей не трогаем
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    /// Базовый фон строки — controlFill; герой перекрашивается отдельно (accent-tint), сохраняем.
    var baseFill: CGColor?

    override func mouseDown(with event: NSEvent) {
        pressed = true
        layer?.opacity = 0.7
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
        layer?.backgroundColor = Design.Color.surfaceRim(isDark).cgColor
        guard !isHero else { return }
        // ХОВЕР-ПРИПОДНЯТИЕ: scale 1.012 + мягкая тень (gate Motion.reduced). Центрируем scale
        // ручной трансляцией (НЕ трогаем anchorPoint — тот дерётся с автолейаутом). Оверлей-раскрытие
        // (B4) вне transform → не конфликтуют.
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
        owner?.setRowHover(appName, entered: true)   // O4: заморозить пересортировку, пока строка раскрыта
        if canExpand { showExpand() }
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
        hideExpand()
        owner?.setRowHover(appName, entered: false)   // O4: разморозить — применить отложенный снимок
    }

    /// Принудительно снести ховер-оверлей (O6): строка выпадает из топа под курсором — иначе панель
    /// осиротела бы над лидербордом до следующего ховера. Зовётся из эвикт-цикла renderAppRows.
    func dismissOverlay() { hideExpand() }
    /// Визуальный QA использует тот же путь построения, что и настоящее наведение.
    func showPreviewForSnapshot() { showExpand() }

    /// Ховер-раскрытие ОВЕРЛЕЕМ (не в стеке): показывает CPU/MEM/потоки/страны под самой строкой,
    /// поверх соседей. Не меняет высоту appsStack/поповера (fittingSize-инвариант держится).
    private func showExpand() {
        guard overlay == nil, let content = owner?.appExpandContent(for: appName) else { return }
        expanded = true
        let panel = NSView()
        panel.wantsLayer = true
        // Оверлей находится поверх соседних строк. Непрозрачная локальная поверхность
        // не даёт тексту быстрого просмотра смешиваться с показателями под ним.
        panel.layer?.backgroundColor = NSColor(
            calibratedWhite: isDark ? 0.17 : 0.96,
            alpha: 1
        ).cgColor
        panel.layer?.cornerRadius = Design.Radius.chip
        panel.layer?.cornerCurve = .continuous
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = Design.Color.surfaceRim(isDark).cgColor
        Design.Elevation.tile(panel.layer!, dark: isDark)
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 7),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -7),
        ])
        // Кладём в самый верх host, а не просто «над текущей строкой». Иначе строки,
        // расположенные после неё в NSStackView, остаются выше панели и рисуют текст
        // поверх её фона — это выглядит как полупрозрачность, хотя заливка непрозрачна.
        // Host списка не включает нижнюю сводку CPU/памяти. Берём поверхность всей
        // apps-плитки, чтобы и эта соседняя секция гарантированно оставалась под карточкой.
        guard let host = owner?.appsPreviewOverlayHost() ?? superview else { return }
        host.addSubview(panel, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: bottomAnchor, constant: 2),
        ])
        overlay = panel
        if !Motion.reduced {
            // Только геометрическое появление: fade здесь недопустим, поскольку панель
            // перекрывает числовые строки и в промежуточных кадрах смешивает два текста.
            panel.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: 4))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Design.Motion.durFast
                panel.layer?.setAffineTransform(.identity)
            }
        }
    }
    private func hideExpand() {
        guard let panel = overlay else { return }
        overlay = nil; expanded = false
        // Удаляем сразу: fade-out снова проявил бы список сквозь текст карточки.
        panel.removeFromSuperview()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { a11yText }
    override func accessibilityPerformPress() -> Bool { owner?.openDossier(for: appName); return true }
}

final class PopoverController: NSViewController {
    private let CW: CGFloat = 304       // ширина плитки (IW + 2×16 паддинга)
    private let IW: CGFloat = 272       // ширина контента внутри плитки
    private let FW: CGFloat = 292       // ширина схемы расхода (почти полноширинная: плитка с узким полем 6px)
    private let appsBarW: CGFloat = 64  // лидерборд: энергобар сужен с 84 → имя дышит (не truncate)
    private let appsValW: CGFloat = 30  // колонка значения (поджата с 34); шапка садится над ней
    private let appsFlagW: CGFloat = 16 // колонка флага страны-назначения
    private let appsSparkW: CGFloat = 44 // мини-спарклайн истории impact между именем и баром
    private var cards: [NSView] = []    // ссылки на карточки для смены темы
    /// Снапшот-режим (BM_SNAP): вместо пользовательской раскладки строим все модули (чтобы отснять всё),
    /// НЕ трогая UserDefaults владельца. nil в обычной работе.
    static var snapshotLayout: [PopoverItem]? = nil
    private let root = NSStackView()    // вертикальный стек модулей-плиток
    private weak var headerTile: NSView?       // плитка-шапка (battery) — якорь спайна для crit-заряда
    private weak var tabAreaView: NSView?      // контейнер вкладок — якорь спайна для жары/нагрузки
    private var footer: NSView!         // нижние кнопки (строятся один раз)
    private var ccToggles: [CCToggle] = []   // плитка быстрых переключателей
    private var tabTiles: [Int: NSView] = [:]   // вкладки тяжёлых секций (индекс → плитка)
    private var tabOrder: [String] = []      // id вкладок в порядке таб-бара (для адресных warn/crit-точек)
    private var tabBar: PillTabBar?          // кастомный сегмент-контрол вкладок
    private let tabTitleLabel = NSTextField(labelWithString: "")   // имя активной вкладки (иконки-вкладки без подписей)
    private var currentTab = 0               // активная вкладка (для направления кросс-фейда)
    private var tabContainer: NSView?               // контейнер вкладок; в иерархии ТОЛЬКО показанная вкладка → адаптивная высота
    private static let topIDs: Set<String> = ["battery", "toggles", "batteryStats", "disk", "btbattery", "audio"]   // компактный верх
    /// Read-only стат-модули: смежный их прогон сливается в ОДНУ консоль-плитку с волосяными швами.
    private static let statIDs: Set<String> = ["batteryStats", "disk", "btbattery"]
    private static let tabIDs: Set<String> = ["flow", "hardware", "apps", "privacy", "maintenance", "history", "health"]   // секции-вкладки
    /// Ярлык вкладки — резолвим L() СВЕЖИМ при каждой сборке таб-бара (buildModules), а не один раз:
    /// иначе static let замораживал бы язык первого показа и вкладки не переводились бы при смене языка.
    private static func tabLabel(_ id: String) -> String {
        switch id {
        case "flow":        return L("Питание")
        case "hardware":    return L("Железо")
        case "apps":        return L("Приложения")
        case "privacy":     return L("Приватность")
        case "maintenance": return L("Обслуживание")
        case "history":     return L("История")
        case "health":      return L("Здоровье")
        default:            return id
        }
    }
    /// SF-иконка вкладки — таб-бар переходит на иконки при 5+ вкладках (текст не влезает), имя = tooltip.
    private static func tabIcon(_ id: String) -> String {
        switch id {
        case "flow":        return "bolt.fill"
        case "hardware":    return "cpu"
        case "apps":        return "square.grid.2x2.fill"
        case "privacy":     return "shield.lefthalf.filled"
        case "maintenance": return "wrench.and.screwdriver.fill"
        case "history":     return "chart.line.uptrend.xyaxis"
        case "health":      return "heart.fill"
        default:            return "square"
        }
    }
    private var isDark: Bool { view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    /// Бирюза зарядки = фирменный акцент Kelvin (единый бренд-токен, тема-зависимый).
    private var chargeAccent: NSColor { SettingsStore.brandAccent(dark: isDark) }
    private let ring = ChargeRing()
    private let chargeTrack = ChargeTrack()              // AlDente-дорожка заряда (строка 2 плитки): драг-потолок + паруса + режим
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusSub = NSTextField(labelWithString: "")
    // «Живой термо-прибор» (V2): дышащая аура состояния + топ-бар шапки (бренд + температура ядра).
    private let auraView = AuraView()                             // радиальный цвет-режим у верхней кромки поповера
    // Вердикт здоровья: одна слим-строка в шапке («Mac в норме?» за 1 секунду без переключения вкладок).
    // Цветная точка + слово худшего активного сигнала (жара/нагрузка/заряд/форс-кулер). Язык — как у вердикт-карты фаервола.
    private let healthDot = NSTextField(labelWithString: "●")
    private let healthLabel = NSTextField(labelWithString: "")
    /// Нейтральная controlFill-капсула вокруг вердикта (точка + слово) — сенсор-подпись.
    private let verdictPill = CapsuleView()
    private let statSysVal = NSTextField(labelWithString: "—")
    private var statSysCap = NSTextField(labelWithString: L("Ватт"))
    private let statBatVal = NSTextField(labelWithString: "—")
    // «АКБ» вместо «В батарею»: значение знаковое (+заряд/−разряд/0), направление несёт знак —
    // подпись «В батарею: −12» была самопротиворечивой. (statTimeVal/statTimeCap «ОСТАЛОСЬ» удалены — мёртвый код.)
    private var statBatCap = NSTextField(labelWithString: L("АКБ"))
    // V2 витальные-приборы: 4 ячейки Ватт/Темп/Кулер/АКБ (макет). Темп тинтуется по режиму.
    private let statTempVal = NSTextField(labelWithString: "—")
    private var statTempCap = NSTextField(labelWithString: L("Темп"))
    private let statFanVal = NSTextField(labelWithString: "—")
    private var statFanCap = NSTextField(labelWithString: L("Кулер"))
    private let graph = GraphView()
    private let flowView = FlowView(frame: .zero)
    private let flowInfoBar = FlowInfoBar(frame: .zero)
    private let thermalLabel = NSTextField(labelWithString: "")
    private var flowDetail: String?          // разбор узла под курсором (интерактив схемы)
    // V6: термосводка CPU°/GPU°/кулеров удалена (дублировала шапку поповера и вкладку «Железо») —
    // строка теперь ТОЛЬКО живой разбор узла/виджета под курсором, в покое пуста (высота стабильна).
    private func applyThermalLabel() {
        thermalLabel.stringValue = flowDetail ?? ""
        thermalLabel.textColor = .secondaryLabelColor
    }
    private let cellsLabel = NSTextField(labelWithString: "—")
    private var metric: [String: NSTextField] = [:]
    /// Фиксированные слоты строк Bluetooth-плитки (иконка + имя + заряд). Кол-во строк
    /// постоянно — высота поповера не прыгает при подключении/отключении устройств.
    private struct BTSlot { let row: NSStackView; let icon: NSImageView; let name: NSTextField; let value: NSTextField }
    private var btSlots: [BTSlot] = []
    /// Фиксированные слоты плитки «Звук · вывод»: иконка + имя устройства + галка (текущий дефолт).
    /// Клик по не-текущему слоту → сделать его выводом по умолчанию (Pro). Кол-во слотов постоянно.
    private struct AudioSlot { let row: NSStackView; let icon: NSImageView; let name: NSTextField; let check: NSImageView; var deviceID: AudioDeviceID? }
    private var audioSlots: [AudioSlot] = []
    // Вкладка «История» V5 = карточка батареи (владелец: «30 дней CPU — мутные данные»).
    // Пилюли метрик/диапазонов удалены; SQLite пишет все метрики как прежде (90 дней — PDF/тренд/CSV).
    private var historyChart: HistoryChart?
    private let historyFooter = NSTextField(labelWithString: "")
    private let historyDegrade = NSTextField(labelWithString: "")   // строка деталей тренда под графиком
    private let historyVerdict = NSTextField(labelWithString: "")   // ГОТОВЫЙ ВЫВОД («АКБ стабильна» / «теряет N%/мес»)
    private let histCardHealth = NSTextField(labelWithString: "—")  // три крупных числа карточки
    private let histCardCycles = NSTextField(labelWithString: "—")
    private let histCardTrend = NSTextField(labelWithString: "—")

    // Advisor (Health Center) UI elements
    private let healthVerdictLabel = NSTextField(labelWithString: "")
    private let healthMetaLabel = NSTextField(labelWithString: "")
    private let healthFindingsContainer = NSStackView()
    private var lastAdvisorResult: AdvisorResult?
    private var advisorDismissalStore = AdvisorDismissalStore()

    private let compStatus = NSTextField(labelWithString: "")
    private var comp: [String: NSTextField] = [:]
    private var installBtn = GlassButton(title: L("Установить хелпер…"), symbol: "arrow.down.circle")
    private let sensorsView = HardwareView(frame: .zero)
    private let sensorDetail = NSTextField(labelWithString: "")
    private let privacyView = PrivacyView(frame: .zero)   // вкладка «Приватность» — радар соединений
    private var vpnChipRefresh: (() -> Void)?             // обновление VPN-чипа (при показе вкладки/после действия)

    private let appsStack = NSStackView()
    // Лидерборд приложений: имя (lowercased) → флаг страны-назначения активного соединения
    // («жрёт батарею И звонит домой» — приватность-сигнал). Считаем lsof в фоне, тут только кэш.
    private var appCountryFlags: [String: String] = [:]
    private var appsLast: [AppEnergy] = []     // последний снимок энергии — для перерисовки при приходе флагов
    // Футер вкладки «Приложения»: честная сводка из УЖЕ собранных данных (top-сводка/SystemUsage/AppSession) —
    // заполняет высоту вкладки (не «урезала» поповер) и даёт системный контекст под лидербордом.
    private let appsFootProcs = NSTextField(labelWithString: "—")
    private let appsFootCPU = NSTextField(labelWithString: "—")
    private let appsFootMem = NSTextField(labelWithString: "—")
    private let hardwareStatus = NSTextField(labelWithString: "")
    private let appsTotalSpark = MiniSpark()
    private let appsUpdatedLabel = NSTextField(labelWithString: "")
    private var appsUpdatedAt: Date?
    private var appFlagsBusy = false           // защита от наслоения фоновых lsof-снимков

    // ДОСЬЕ (Batch D): тап по строке лидерборда → флип на заднюю грань = досье приложения.
    // Состояние openDossier — ИНВАРИАНТ перерендера: пока задано, renderAppRows рисует ЛИЦО
    // досье (не лидерборд) и обновляет его НА МЕСТЕ — живой снимок/гео-колбэк не сносят флип.
    private var openDossierName: String? = nil       // сырое a.name (ключ корреляции); nil = лидерборд
    private var dossierConns: [NetConn] = []          // соединения приложения (свой snapshot, НЕ из refreshAppFlags)
    private var dossierCountries: [String] = []       // уникальные гео-метки "🇺🇸 США" в порядке появления
    private var dossierHasLAN = false                 // были conns без гео (LAN/неизвестно)
    private var dossierAppPath: String? = nil         // путь к .app (Finder/блок); nil у демонов/несматченных
    private var dossierBusy = false                   // защита от наслоения фоновых snapshot для досье
    private weak var dossierBackButton: NSView?       // для VoiceOver-фокуса при открытии
    private weak var appsFlipHost: NSView?            // обёртка appsStack — на ней крутим/фейдим флип

    // ГИБРИД A+ГЕРОЙ: FLIP-переиспользование строк по имени (НЕ removeFromSuperview каждый тик).
    enum AppsSort { case impact, cpu, net }
    private var appsSort: AppsSort = .impact           // сегмент сортировки: Расход / CPU / Сеть
    private var appRows: [String: DossierRowView] = [:]  // сырое имя → живая карточка (герой ⊂ этого же словаря)
    private var appHeroName: String?                    // имя карточки, отрисованной как ГЕРОЙ
    private var hoveredRowName: String?                 // строка под курсором: замораживаем reorder, пока раскрыта (иначе оверлей отклеивается)
    private var pendingAppsSnapshot: [AppEnergy]?       // отложенный снимок, пришедший под ховером — применим по mouseExited
    private weak var appsHeader: NSView?                // шапка колонки + сегмент сортировки (переиспользуем)
    private weak var appsVerdict: NSTextField?         // вывод-вердикт «кто грузит» над лидербордом (переиспользуем)
    private var lastVerdictTip: String?                // guard: не переустанавливать toolTip капсулы каждый тик
    private var verdictDetail: String = ""             // полная фраза вердикта — для кликабельной капсулы
    private var verdictLevelOK = true                  // .ok → клик по капсуле no-op (нет pointingHand)
    private var tempCritStreak = 0                     // устойчивость крит-температуры: мгновенный скачок ≠ «Перегрев»
    private var lastVerdictLevel: Design.Level = .ok   // резолвнутый уровень вердикта → тинт кольца (герой-шапка)
    private var lastAuraColor: NSColor? = nil          // аура строго следует кольцу; guard не перезапускает fade каждый тик

    private static func sectionLabel(_ s: String) -> NSTextField {
        // V3 (совет по типографике): заголовки секций — ОБЫЧНЫЙ регистр, без трекинга, вторичный цвет.
        // CAPS-подписи = сильнейший «самодельный-дашборд» тэлл; у Control Center капса нет. Строки уже в нужном регистре.
        let l = NSTextField(labelWithString: s)
        l.font = Design.Font.sys(11, .medium)
        l.textColor = .secondaryLabelColor
        return l
    }
    /// Динамическая подпись (меняется в update()): V3 — без трекинга/капса, регистр берём из строки.
    private func capsText(_ field: NSTextField, _ s: String) {
        field.stringValue = s
    }

    // MARK: — честные форматтеры вкладки «Приложения»

    /// MEM в человекочитаемом виде: <1024 МБ → «N МБ», иначе → «N.N ГБ».
    private func fmtMem(_ mb: Double) -> String {
        mb < 1024 ? String(format: L("%.0f МБ"), mb) : String(format: L("%.1f ГБ"), mb / 1024)
    }
    /// impact — безразмерный (НАГРУЗКА/РАСХОД), НИКОГДА «Вт».
    private func fmtImpact(_ v: Double) -> String { String(format: "%.1f", v) }
    private func fmtCPU(_ c: Double) -> String { String(format: "%.0f%%", c) }

    /// Значение колонки по текущей сортировке (для строки/героя): impact/CPU%/impact.
    private func appValueText(_ a: AppEnergy) -> String {
        switch appsSort {
        case .impact: return fmtImpact(a.impact)
        case .cpu:    return a.cpu.map(fmtCPU) ?? "—"
        case .net:                                   // колонка «Сеть» = число направлений (стран), не impact
            let n = appNetCount(a)
            return n == 0 ? "—" : "\(n)"
        }
    }
    /// Число направлений (уникальных стран) исходящих соединений приложения за сессию — метрика режима «Сеть».
    private func appNetCount(_ a: AppEnergy) -> Int {
        AppSession.countryCodes(nameLower: a.name.lowercased()).count
    }
    /// Величина АКТИВНОГО сорта — длина энергобара и значение колонки берут ЕЁ, а не всегда impact:
    /// иначе в режимах CPU/Сеть бар противоречил и числу, и порядку строк.
    private func appSortMetric(_ a: AppEnergy) -> Double {
        switch appsSort {
        case .impact: return a.impact
        case .cpu:    return a.cpu ?? 0
        case .net:    return Double(appNetCount(a))
        }
    }

    /// Отсортированный снимок по текущему сегменту (Расход/CPU/Сеть). tie-break — impact.
    private func sortedApps(_ apps: [AppEnergy]) -> [AppEnergy] {
        switch appsSort {
        case .impact: return apps.sorted { $0.impact > $1.impact }
        case .cpu:    return apps.sorted { ($0.cpu ?? -1, $0.impact) > ($1.cpu ?? -1, $1.impact) }
        case .net:
            return apps.sorted {
                let l = AppSession.countryCodes(nameLower: $0.name.lowercased()).count
                let r = AppSession.countryCodes(nameLower: $1.name.lowercased()).count
                return (l, $0.impact) > (r, $1.impact)
            }
        }
    }

    /// ТУЛТИП-ХЕЛПЕР (правило): ставит full ТОЛЬКО если текст реально усечён (изм. ширина > доступной).
    /// Иначе toolTip = nil (не плодим пустой зуд). Зовётся ПОСЛЕ layout (иначе avail неизвестна).
    private func applyTruncTip(_ field: NSTextField, full: String, avail: CGFloat) {
        let measured = (full as NSString).size(withAttributes: [.font: field.font ?? Design.Font.caption]).width
        field.toolTip = (avail > 0 && measured > avail + 0.5) ? full : nil
    }

    /// Контент ховер-раскрытия строки (богатая панель — там родилась боль обрезки): CPU/MEM/потоки
    /// + страны-назначения (флаг+имя через GeoIP.name). Зовётся из DossierRowView.showExpand.
    func appExpandContent(for name: String) -> NSView? {
        guard let a = appsLast.first(where: { $0.name == name }) else { return nil }
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 3

        // строка мини-статов: CPU · MEM · потоки
        var stats: [String] = []
        if let c = a.cpu { stats.append("CPU " + fmtCPU(c)) }
        if let m = a.memMB { stats.append(fmtMem(m)) }
        if let t = a.threads { stats.append(String(format: L("%d потоков"), t)) }
        if !stats.isEmpty {
            let s = NSTextField(labelWithString: stats.joined(separator: "  ·  "))
            s.font = Design.Font.numericBody
            s.textColor = .secondaryLabelColor
            col.addArrangedSubview(s)
        }

        // страны-назначения за сессию: флаг + имя, усечение с тултипом
        let codes = AppSession.countryCodes(nameLower: name.lowercased())
        if !codes.isEmpty {
            let full = codes.map { GeoIP.name($0) }.joined(separator: ", ")
            let shownCodes = codes.prefix(4)
            let label = shownCodes.map { "\(GeoIP.flag($0)) \(GeoIP.name($0))" }.joined(separator: "  ")
            let cty = NSTextField(labelWithString: label + (codes.count > shownCodes.count ? "  +\(codes.count - shownCodes.count)" : ""))
            cty.font = Design.Font.caption
            cty.textColor = .secondaryLabelColor
            cty.lineBreakMode = .byTruncatingTail
            cty.toolTip = full        // агрегат стран — тултип всегда (полный список имён)
            col.addArrangedSubview(cty)
        } else {
            let l = NSTextField(labelWithString: L("Нет активных соединений"))
            l.font = Design.Font.caption; l.textColor = .tertiaryLabelColor
            col.addArrangedSubview(l)
        }
        col.widthAnchor.constraint(equalToConstant: IW - 20).isActive = true
        return col
    }

    /// Верхняя поверхность всей apps-плитки: список + шов + системная сводка.
    /// Нужна hover-карточке, чтобы её z-порядок был выше всех этих соседей.
    func appsPreviewOverlayHost() -> NSView? {
        appsFlipHost?.superview ?? appsFlipHost
    }

    override func loadView() {
        configureLeaves()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12                // V3 (совет): секции разделяет ВОЗДУХ, а не стенки-хайрлайны (у Control Center так)
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        buildFooter()

        // Стеклянный фон (NSVisualEffectView) — нативный «glass» для Sequoia.
        let container = GlassContainer()
        container.onAppearanceChange = { [weak self] in self?.applyTheme() }
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        // V3: контент в ВЕРТИКАЛЬНОМ скролле → с любым набором модулей поповер влезает и ЛИСТАЕТСЯ.
        // Высоту берём от НАТУРАЛЬНОГО контента (updatePreferredSize от root.fittingSize): короткая вкладка →
        // короткий поповер (пустота внизу уходит), контент выше экрана → скролл. Скролл ПРОЗРАЧНЫЙ (стекло/аура сквозят).
        let scroll = NSScrollView()
        scroll.contentView = TopClipView()          // перевёрнутый клип → контент СВЕРХУ (не якорится к низу)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.verticalScroller = HiddenScroller()   // V3: «лифт» не рисуем — листается трекпадом, чисто
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.documentView = root
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // документ (root) = ширина viewport (без гориз. скролла), высота НАТУРАЛЬНАЯ (верт. скролл)
            root.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            root.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        // V3: StatusSpine (левый шов) ретайрнут — единая стеклянная поверхность несёт состояние аурой,
        // без вертикального шва в левом гаттере (он читался как «полоска сбоку»).
        // Дышащая аура состояния (V2 «живой термо-прибор») — ПОД контентом, у верхней кромки: тинтует
        // стекло цветом теплового режима. Перекрашивается медленно при смене вердикта (refreshHealthVerdict).
        auraView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(auraView, positioned: .below, relativeTo: scroll)
        // Пришпилено ко ВСЕМ кромкам контейнера → аура НИКОГДА не влияет на fittingSize/размер поповера
        // (баг «растягивается при тоггле»); свечение концентрируется вверху через фикс-полосу в AuraView.layout().
        NSLayoutConstraint.activate([
            auraView.topAnchor.constraint(equalTo: container.topAnchor),
            auraView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            auraView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            auraView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        view = container
        // ПОСЛЕ view=container: isDark читает view.effectiveAppearance — до присвоения это триггерит
        // повторный loadView (рекурсия). Стартовый фон+цвет ауры ставим здесь.
        auraView.applyBase(dark: isDark, opacity: CGFloat(SettingsStore.popoverOpacity))
        auraView.setColor(Design.Color.stateColor(.ok, isDark), animated: false)
        buildModules()
    }

    /// Одноразовая настройка постоянных вью-листьев (шрифты, фикс-размеры).
    private func configureLeaves() {
        ring.translatesAutoresizingMaskIntoConstraints = false
        ring.widthAnchor.constraint(equalToConstant: 88).isActive = true
        ring.heightAnchor.constraint(equalToConstant: 88).isActive = true
        statusTitle.font = Design.Font.headline; statusTitle.alignment = .right
        statusSub.font = Design.Font.caption; statusSub.textColor = .secondaryLabelColor; statusSub.alignment = .right
        healthDot.font = Design.Font.callout                       // точка-индикатор уровня (цвет — по худшему сигналу)
        healthLabel.font = Design.Font.calloutEmph; healthLabel.textColor = .secondaryLabelColor
        healthLabel.lineBreakMode = .byTruncatingTail
        // вердикт — короткое слово; держим его целым (никогда «…»). При редком дефиците ширины
        // первой уступает вторичная строка статуса (АКБ-температура дублируется в кольце), не вердикт.
        healthLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusSub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 60).isActive = true   // выше — место под оси/сетку/подписи
        graph.widthAnchor.constraint(equalToConstant: FW).isActive = true
        flowView.translatesAutoresizingMaskIntoConstraints = false
        flowView.heightAnchor.constraint(equalToConstant: 292).isActive = true   // V4 компакт: −48 (полоса ужата, воздух схемы уплотнён)
        flowView.widthAnchor.constraint(equalToConstant: FW).isActive = true
        flowView.detailSink = { [weak self] detail in self?.flowDetail = detail; self?.applyThermalLabel() }
        flowInfoBar.translatesAutoresizingMaskIntoConstraints = false
        flowInfoBar.heightAnchor.constraint(equalToConstant: 38).isActive = true
        flowInfoBar.widthAnchor.constraint(equalToConstant: FW).isActive = true
        flowInfoBar.detailSink = { [weak self] detail in
            // полоса делит сток-подпись со схемой: её разбор перебивает термо-сводку, как и разбор узла
            self?.flowDetail = detail; self?.applyThermalLabel()
        }
        thermalLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)   // цвет ставит applyThermalLabel (один ранг)
        sensorsView.translatesAutoresizingMaskIntoConstraints = false
        sensorsView.detailSink = { [weak self] d in self?.sensorDetail.stringValue = d }
        sensorDetail.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        sensorDetail.textColor = .secondaryLabelColor; sensorDetail.lineBreakMode = .byTruncatingTail
        compStatus.font = .systemFont(ofSize: 10); compStatus.textColor = .secondaryLabelColor
        compStatus.lineBreakMode = .byWordWrapping; compStatus.maximumNumberOfLines = 2
        installBtn.onClick = { [weak self] in self?.showInstall() }
        appsStack.orientation = .vertical; appsStack.alignment = .leading; appsStack.spacing = 5
        privacyView.translatesAutoresizingMaskIntoConstraints = false
        privacyView.heightAnchor.constraint(equalToConstant: 348).isActive = true   // +18 под спарклайн-полосу
        privacyView.widthAnchor.constraint(equalToConstant: FW).isActive = true
    }
    private func buildFooter() {
        func iconBtn(_ symbol: String, _ target: AnyObject?, _ action: Selector, _ tip: String) -> NSButton {
            let b = FooterIconButton(title: "", target: target, action: action)
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)  // единый вес со шкалой символов
            b.imageScaling = .scaleProportionallyDown
            b.isBordered = false
            b.contentTintColor = .secondaryLabelColor
            b.toolTip = tip
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
            b.setup()
            return b
        }
        let refresh = iconBtn("arrow.clockwise", self, #selector(refreshApps), L("Обновить"))
        // «второй мозг» продукта (Caffeine/Night Shift/фаервол/dev/безопасность) больше не спрятан
        // только за правым кликом — даём ему видимую точку входа в футере.
        let tools = iconBtn("ellipsis.circle", NSApp.delegate, #selector(AppDelegate.openToolsFromFooter), L("Инструменты"))
        let settings = iconBtn("gearshape", self, #selector(openSettings), L("Настройки"))
        let quit = iconBtn("power", NSApp, #selector(NSApplication.terminate(_:)), L("Выйти"))
        let f = NSStackView(views: [refresh, spacer(), tools, settings, quit])
        f.spacing = 8
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: CW).isActive = true
        footer = f
    }

    /// Пересобирает поповер: компактный верх (battery/toggles/stats) стопкой,
    /// тяжёлые секции (flow/hardware/apps) — через сегмент-контрол, по одной за раз.
    /// Обновить подписи статических элементов при смене языка. Вызывается из buildModules().
    private func relocalizeStatic() {
        statSysCap.stringValue = L("Ватт")
        statBatCap.stringValue = L("АКБ")
        statTempCap.stringValue = L("Темп")
        statFanCap.stringValue = L("Кулер")
        installBtn.title = L("Установить хелпер…")
        for v in (footer as? NSStackView)?.subviews ?? [] {
            if let b = v as? FooterIconButton, let sel = b.action {
                if sel == #selector(refreshApps) { b.toolTip = L("Обновить") }
                else if sel == #selector(AppDelegate.openToolsFromFooter) { b.toolTip = L("Инструменты") }
                else if sel == #selector(openSettings) { b.toolTip = L("Настройки") }
                else if sel == #selector(NSApplication.terminate(_:)) { b.toolTip = L("Выйти") }
            }
        }
    }

    func buildModules() {
        relocalizeStatic()
        cards.removeAll(); ccToggles = []; tabTiles = [:]; btSlots = []; tabContainer = nil
        headerTile = nil; tabAreaView = nil           // якоря спайна пересоздаются при ребилде
        // прогреваем сенсоры данными ДО замера высоты вкладок — иначе пустая панель
        // дала бы заниженную высоту контейнера и обрезала бы низ. record:false — прогрев НЕ пишет
        // в кольцо трассы (ребилд по BMPopoverChanged иначе впрыснул бы внеплановый кадр); 1Гц-тик владеет историей.
        sensorsView.update(SensorsModel.snapshot(cpuLoad: SystemUsage.shared.cpu(),
                                                 ramLoad: SystemUsage.shared.ram(),
                                                 components: PowerInfo.components(), record: false))
        for v in root.arrangedSubviews { root.removeArrangedSubview(v); v.removeFromSuperview() }
        // десктоп без АКБ — прячем батарейные модули (кольцо/статистику), остальное остаётся
        let noBattery = ProcessInfo.processInfo.environment["BM_NOBATT"] != nil || BatteryReader.read() == nil
        // .filter на РЕЗУЛЬТАТ ??, а не только на фолбэк: иначе снапшот-дефолт с on:false-модулями строил бы
        // ВСЕ (консоль/диск/BT) и снимок не совпал бы с тем, что реально видит владелец. No-op для MIN/ALL/шиппинга.
        var layout = (Self.snapshotLayout ?? SettingsStore.popoverLayout).filter { $0.on }
        if noBattery { layout = layout.filter { $0.id != "battery" && $0.id != "batteryStats" } }

        // КОНСОЛЬ-ГРУППЫ: смежный прогон read-only стат-модулей (batteryStats/disk/btbattery)
        // сливается в ОДНУ плитку с волосяными швами между рядами; прогон длины 1 или модуль
        // battery/toggles рендерятся как отдельная плитка (как раньше). Порядок и on/off из popoverLayout
        // сохранены — пользователь может вставить тумблеры между disk и btbattery, и группа разорвётся.
        let topItems = layout.filter { Self.topIDs.contains($0.id) }
        // V3 «единая поверхность»: между модулями — волосяной делитель, а не зазор между карточками.
        var placedTop = false
        func placeTop(_ v: NSView) {
            root.addArrangedSubview(v)   // V3: модули разделяет ВОЗДУХ (root.spacing 12), а не стенки-хайрлайны
            placedTop = true
        }
        var idx = 0
        while idx < topItems.count {
            let id = topItems[idx].id
            if Self.statIDs.contains(id) {
                // собираем максимальный смежный прогон стат-модулей
                var run = [id]
                var j = idx + 1
                while j < topItems.count, Self.statIDs.contains(topItems[j].id) { run.append(topItems[j].id); j += 1 }
                if run.count >= 2 {
                    placeTop(buildStatGroupTile(run))
                } else if let tile = buildModule(id) {
                    placeTop(tile)
                }
                idx = j
            } else {
                if let tile = buildModule(id) { placeTop(tile) }
                idx += 1
            }
        }

        let tabs = layout.filter { Self.tabIDs.contains($0.id) }
        tabOrder = tabs.map { $0.id }                 // запоминаем порядок для адресных warn/crit-точек
        if !tabs.isEmpty {
            if placedTop { root.addArrangedSubview(sectionDivider()) }   // делитель перед рельсом вкладок
            // дефолт — последняя открытая вкладка (BM_TAB переопределяет для дебага)
            let initTab = ProcessInfo.processInfo.environment["BM_TAB"].flatMap { Int($0) }
                ?? UserDefaults.standard.integer(forKey: "popover.lastTab")
            let sel = min(max(initTab, 0), tabs.count - 1)
            currentTab = sel
            let bar = PillTabBar(labels: tabs.map { Self.tabLabel($0.id) }, icons: tabs.map { Self.tabIcon($0.id) }, selected: sel)
            bar.onSelect = { [weak self] idx in self?.selectTab(idx) }
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: CW).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 32).isActive = true
            bar.pillColor = Design.Color.accent(isDark)   // «Спокойный прибор»: навигация НЕ красится состоянием — всегда бирюза
            tabBar = bar
            root.addArrangedSubview(bar)
            // Имя активной вкладки текстом (вкладки — иконки без подписей → это главный пробел
            // в обнаружимости; всплывашки были, но всегда-видимое имя читается сразу, как секц-заголовок).
            tabTitleLabel.font = Design.Font.calloutEmph
            tabTitleLabel.textColor = .secondaryLabelColor
            tabTitleLabel.alignment = .left
            tabTitleLabel.stringValue = Self.tabLabel(tabs[sel].id)   // V3: обычный регистр (не CAPS)
            tabTitleLabel.translatesAutoresizingMaskIntoConstraints = false
            tabTitleLabel.widthAnchor.constraint(equalToConstant: CW).isActive = true
            root.addArrangedSubview(tabTitleLabel)
            // Контейнер вкладок: в иерархии держим ТОЛЬКО ПОКАЗАННУЮ вкладку → его высота = её высоте
            // (истинно адаптивно; скрытые вкладки НЕ в иерархии → не раздувают fittingSize/высоту поповера →
            // пустота под короткими вкладками исчезает). Switch/снапшот переставляют вкладку (showTab).
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.widthAnchor.constraint(equalToConstant: CW).isActive = true
            tabContainer = container
            // Временно строим плитки для кэша. Каждая вкладка сохраняет собственную естественную
            // высоту: короткие «Приложения» и «Железо» больше не растягиваются по самому высокому соседу.
            for (i, item) in tabs.enumerated() {
                if let tile = buildModule(item.id) {
                    tile.translatesAutoresizingMaskIntoConstraints = false
                    container.addSubview(tile)
                    NSLayoutConstraint.activate([
                        tile.topAnchor.constraint(equalTo: container.topAnchor),
                        tile.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                        tile.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    ])
                    tabTiles[i] = tile
                    tile.layoutSubtreeIfNeeded()
                }
            }
            // Оставляем в контейнере ТОЛЬКО показанную вкладку → контейнер = её высоте (адаптивно).
            for (_, t) in tabTiles { t.removeFromSuperview() }
            showTab(sel)
            root.addArrangedSubview(container)
            tabAreaView = container                     // якорь для жары/нагрузки (вкладки Питание/Железо)
        }
        // световой безель-шов под колонкой данных — отделяет футер, замыкает «консоль» снизу
        let footerSeam = RimLightView()
        footerSeam.translatesAutoresizingMaskIntoConstraints = false
        footerSeam.widthAnchor.constraint(equalToConstant: CW).isActive = true
        footerSeam.heightAnchor.constraint(equalToConstant: 1).isActive = true
        root.addArrangedSubview(footerSeam)
        root.addArrangedSubview(footer)
        paintCards()
        auraView.applyBase(dark: isDark, opacity: CGFloat(SettingsStore.popoverOpacity))   // прозрачность фона из настроек
        updatePreferredSize()
    }
    /// Смена вкладки с кросс-фейдом: уходящая плитка гаснет со сдвигом по X в сторону движения,
    /// приходящая — проявляется с противоположной. Высоту НЕ трогаем (контейнер фиксирован).
    /// Снапшот-рендер (BM_SNAP): офскрин `cacheDisplay` → PNG, БЕЗ окна и без Screen-Recording-TCC.
    /// Рендерит верх+каждую вкладку. Между кадрами прокачиваем run loop, чтобы async-данные (радар/чипы/
    /// сенсоры/аудио — они грузятся с фона на main) успели долиться. Возвращает число снятых кадров.
    func renderSnapshots(to dir: String, light: Bool) -> Int {
        _ = self.view                                   // триггерим loadView
        if light { self.view.appearance = NSAppearance(named: .aqua) }
        // Офскрин-окно (НИКОГДА не показываем): даёт view.window != nil, чтобы window-гейтнутые апдейты
        // (радар приватности/гео-флаги/чипы — они применяются лишь при наличии окна) реально сработали.
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 900),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        if light { win.appearance = NSAppearance(named: .aqua) }
        win.contentViewController = self
        buildModules()
        // Наполняем данными КАК настоящий тик: несколько апдейтов (история кольца/flow) + apps-лидерборд.
        var hist: [Double] = []
        for _ in 0..<6 {
            let b = BatteryReader.read() ?? .absent
            let e = EnergyModel.snapshot()
            let c = PowerInfo.components()
            let sensors = SensorsModel.snapshot(cpuLoad: SystemUsage.shared.cpu(),
                                                ramLoad: SystemUsage.shared.ram(),
                                                components: c)
            hist.append(e.systemWatts > 0.1 ? e.systemWatts : b.watts)
            if hist.count > 90 { hist.removeFirst() }
            update(battery: b, history: hist, components: c, energy: e, sensors: sensors)
            pumpRunLoop(0.4)
        }
        refreshApps()                                   // apps-лидерборд (через `top`, async)
        pumpRunLoop(3.0)
        var n = 0
        func shot(_ name: String) {
            self.view.layoutSubtreeIfNeeded()
            let sz = self.root.fittingSize        // снимок = ПОЛНЫЙ контент (скролл развёрнут), высота от root
            win.setContentSize(NSSize(width: max(sz.width, CW), height: max(sz.height, 120)))
            self.view.layoutSubtreeIfNeeded()
            let r = self.view.bounds
            guard r.width > 1, r.height > 1, let rep = self.view.bitmapImageRepForCachingDisplay(in: r) else { return }
            self.view.cacheDisplay(in: r, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: String(format: "%@/%02d_%@.png", dir, n, name)))
                n += 1
            }
        }
        let order = tabOrder
        if order.isEmpty {
            shot("popover")
        } else {
            for (i, tid) in order.enumerated() {
                currentTab = i
                showTab(i)                               // в контейнере только показанная вкладка (адаптивная высота)
                // Snapshot должен проходить тот же путь визуального состояния, что и живой selectTab:
                // иначе на всех PNG оставались заголовок и подсветка первой вкладки «Питание».
                tabTitleLabel.stringValue = Self.tabLabel(tid)
                tabBar?.select(i, animated: false)
                if tid == "hardware" { sensorsView.animateIn() }
                if tid == "apps" { refreshApps() }
                if tid == "history" { refreshHistory() }
                if tid == "privacy" {                  // радар снимаем во ВСЕХ трёх сегментах (Страны/Приложения/Порты)
                    vpnChipRefresh?(); mediaChipRefresh?()
                    for (bname, b) in [("countries", PrivacyView.Basis.country), ("apps", PrivacyView.Basis.app), ("ports", PrivacyView.Basis.ports)] {
                        privacyView.setBasis(b); privacyView.animateIn()
                        updatePreferredSize(); pumpRunLoop(1.5)
                        shot("privacy_" + bname)
                    }
                    continue
                }
                updatePreferredSize()
                pumpRunLoop(2.5)                        // тик данных этой вкладки (apps-лидерборд/flow медленнее)
                shot(tid)
                if tid == "apps", let row = appRows.values.first {
                    row.showPreviewForSnapshot()
                    self.view.layoutSubtreeIfNeeded()
                    shot("apps_hover")
                    row.dismissOverlay()
                }
            }
        }
        return n
    }
    /// Ручная прокачка главного run loop N секунд — исполняет отложенные/фон→main блоки без `app.run()`.
    private func pumpRunLoop(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }

    /// Показать вкладку i: в контейнере остаётся ТОЛЬКО она (пин top+bottom+leading+trailing = контейнер),
    /// прочие убраны из иерархии → высота контейнера = высоте показанной вкладки (адаптивно, без пустоты внизу).
    private func showTab(_ i: Int) {
        guard let container = tabContainer, let tile = tabTiles[i] else { return }
        for (k, t) in tabTiles where k != i && t.superview != nil { t.removeFromSuperview() }
        if tile.superview !== container {
            tile.removeFromSuperview()
            container.addSubview(tile)
            NSLayoutConstraint.activate([
                tile.topAnchor.constraint(equalTo: container.topAnchor),
                tile.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                tile.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                tile.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        tile.isHidden = false
    }

    private func selectTab(_ sel: Int) {
        guard sel != currentTab else { return }
        let prev = currentTab
        currentTab = sel
        UserDefaults.standard.set(sel, forKey: "popover.lastTab")   // запоминаем вкладку между открытиями
        if sel < tabOrder.count { tabTitleLabel.stringValue = Self.tabLabel(tabOrder[sel]) }  // имя вкладки текстом (обычный регистр)
        // оживление тяжёлых вкладок
        if sel < tabOrder.count, tabOrder[sel] == "hardware" {
            DispatchQueue.main.async { [weak self] in self?.sensorsView.animateIn() }
        }
        if sel < tabOrder.count, tabOrder[sel] == "privacy" {
            DispatchQueue.main.async { [weak self] in self?.privacyView.animateIn(); self?.vpnChipRefresh?(); self?.mediaChipRefresh?() }
        }
        if prev < tabOrder.count, tabOrder[prev] == "privacy" { privacyView.stopAnimations() }
        if sel < tabOrder.count, tabOrder[sel] == "history" { DispatchQueue.main.async { [weak self] in self?.refreshHistory() } }
        if sel < tabOrder.count, tabOrder[sel] == "health" { DispatchQueue.main.async { [weak self] in self?.refreshAdvisor() } }
        // Адаптивный свап: в контейнере остаётся только показанная вкладка → поповер ресайзится под неё
        // (пустота под короткими вкладками исчезает). Уходящая убирается из иерархии — cross-fade скрытой не нужен.
        showTab(sel)
        updatePreferredSize()
        // Проявление новой вкладки со сдвигом в сторону движения (кроме «Уменьшить движение»).
        if !Motion.reduced, let inL = tabTiles[sel]?.layer {
            inL.removeAllAnimations()
            inL.opacity = 1; inL.transform = CATransform3DIdentity
            let dir: CGFloat = sel > prev ? 1 : -1
            let op = CABasicAnimation(keyPath: "opacity"); op.fromValue = 0; op.toValue = 1
            let tx = CABasicAnimation(keyPath: "transform.translation.x"); tx.fromValue = 6 * dir; tx.toValue = 0
            let g = CAAnimationGroup(); g.animations = [op, tx]; g.duration = Design.Motion.durBase; g.timingFunction = Design.Motion.easeIn
            inL.add(g, forKey: "tabIn")
        }
    }
    private func updatePreferredSize() {
        guard isViewLoaded else { return }
        view.layoutSubtreeIfNeeded()
        // Высоту берём от НАТУРАЛЬНОГО контента (root), а не от раздутого view.fittingSize (скролл его не отражает).
        // Кап по видимой высоте экрана: выше кэпа контент ЛИСТАЕТСЯ, ниже — поповер ровно по контенту (адаптивно).
        let sz = root.fittingSize
        // До появления окна `view.window?.screen` nil. В мультимониторной конфигурации берём экран
        // под курсором, иначе вторичный небольшой дисплей наследовал высоту основного.
        let mouse = NSEvent.mouseLocation
        let targetScreen = view.window?.screen
            ?? NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        let screenH = targetScreen?.visibleFrame.height ?? 900
        let cap = max(300, screenH - 72)
        preferredContentSize = NSSize(width: sz.width, height: min(sz.height, cap))
    }
    private func buildModule(_ id: String) -> NSView? {
        switch id {
        case "battery":      return buildBatteryTile()
        case "toggles":      return buildTogglesTile()
        case "flow":         return buildFlowTile()
        case "batteryStats": return buildBatteryStatsTile()
        case "hardware":     return buildHardwareTile()
        case "apps":         return buildAppsTile()
        case "privacy":      return buildPrivacyTile()
        case "maintenance":  return buildMaintenanceTile()
        case "disk":         return buildDiskTile()
        case "btbattery":    return buildBTBatteryTile()
        case "audio":        return buildAudioTile()
        case "history":      return buildHistoryTile()
        case "health":       return buildHealthTile()
        default:             return nil
        }
    }

    /// Внутренний контент стат-модуля (без glass-обёртки) — для консоль-группы.
    private func statContent(for id: String) -> NSView? {
        switch id {
        case "batteryStats": return buildBatteryStatsContent()
        case "disk":         return buildDiskContent()
        case "btbattery":    return buildBTBatteryContent()
        default:             return nil
        }
    }

    /// Консоль-карта: смежный прогон стат-модулей в ОДНОЙ glass-плитке с волосяными швами между рядами.
    /// Высота РЕКЛАМИРУЕТСЯ обратно (один отступ вместо N плиточных) — никогда не растёт.
    private func buildStatGroupTile(_ run: [String]) -> NSView {
        var rows: [NSView] = []
        for (i, id) in run.enumerated() {
            guard let content = statContent(for: id) else { continue }
            if i > 0 { rows.append(divider()) }            // шов между модулями группы
            rows.append(content)
        }
        let stack = vstack(rows, 12)
        return glassTile(stack)
    }

    /// V2 витальные: ОБРАМЛЁННАЯ ПОЛОСА-ПРИБОР (rounded панель + хайрлайн-делители между 4 ячейками
    /// Ватт/Темп/Кулер/В АКБ) — читается как приборная панель, а не числа враздрай. Ячейки равной ширины.
    private func buildVitalsStrip() -> NSView {
        let pairs: [(NSTextField, NSTextField)] = [(statSysVal, statSysCap), (statTempVal, statTempCap),
                                                   (statFanVal, statFanCap), (statBatVal, statBatCap)]
        var cells: [NSView] = []
        var views: [NSView] = []
        for (i, (val, cap)) in pairs.enumerated() {
            if i > 0 { views.append(vitalDivider()) }
            let cell = vitalCell(val, cap)
            cells.append(cell); views.append(cell)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal; row.distribution = .fill; row.spacing = 0; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        for c in cells.dropFirst() { c.widthAnchor.constraint(equalTo: cells[0].widthAnchor).isActive = true }
        // V3: БЕЗ обрамляющей панели (бордюр карточки читался как ещё один шов) — 4 ячейки на единой
        // поверхности, разделённые только волосяными вертикалями (vitalDivider). Вертикальный воздух даёт
        // spacing родительского vstack шапки.
        row.widthAnchor.constraint(equalToConstant: IW).isActive = true
        return row
    }
    private func vitalCell(_ val: NSTextField, _ cap: NSTextField) -> NSView {
        val.font = Design.Font.numericVital; val.alignment = .center     // значение СВЕРХУ (макет V3), крупно, rounded
        cap.font = Design.Font.sys(11, .regular); cap.textColor = .tertiaryLabelColor; cap.alignment = .center   // V3: обычный регистр, 11pt
        let s = vstack([val, cap], 2); s.alignment = .centerX
        return s
    }
    private func vitalDivider() -> NSView {
        let d = NSView(); d.wantsLayer = true
        d.layer?.backgroundColor = Design.Color.hairline(isDark, 0.10).cgColor
        d.translatesAutoresizingMaskIntoConstraints = false
        d.widthAnchor.constraint(equalToConstant: 1).isActive = true
        d.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return d
    }
    /// Волосяной делитель СЕКЦИЙ (V3 «единая поверхность»): 0.5pt линия во всю ширину модуля (CW),
    /// разделяет модули на одной стеклянной панели вместо «плавающих» карточек (грамматика Control Center).
    private func sectionDivider() -> NSView {
        let d = NSView(); d.wantsLayer = true
        d.layer?.backgroundColor = Design.Color.hairline(isDark, isDark ? 0.10 : 0.12).cgColor
        d.translatesAutoresizingMaskIntoConstraints = false
        d.widthAnchor.constraint(equalToConstant: CW).isActive = true
        d.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return d
    }

    /// Топ-бар шапки (V3): тихий словомарк «KELVIN» слева + кнопка «Настроить поповер» справа
    /// (slider.horizontal.3 → Настройки · Поповер: прозрачность / набор-порядок модулей / плотность).
    /// «ядро NN°» ретайрнут — дублировал ТЕМП в витальных; трекинг словомарка снижен 2.2→0.4 (нативнее).
    private func headerTopBar() -> NSView {
        // V3: словомарк «KELVIN» убран (совет: панель не подписывают — бренд несёт иконка в меню-баре).
        // Остаётся тихая кнопка «Настроить» справа сверху; иконка в едином SF-Symbols весе/масштабе.
        let edit = FooterIconButton(title: "", target: self, action: #selector(openPopoverSettings))
        edit.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: L("Настроить поповер"))
        edit.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        edit.imageScaling = .scaleProportionallyDown
        edit.isBordered = false
        edit.contentTintColor = .tertiaryLabelColor
        edit.toolTip = L("Настроить поповер")
        edit.translatesAutoresizingMaskIntoConstraints = false
        edit.widthAnchor.constraint(equalToConstant: 24).isActive = true
        edit.heightAnchor.constraint(equalToConstant: 20).isActive = true
        edit.setup()
        let row = NSStackView(views: [spacer(), edit])
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: IW).isActive = true
        return row
    }

    private func buildBatteryTile() -> NSView {
        // hero (V3): кольцо-заряд + статус словами, СЛЕВА-выровнено рядом (грамматика макета).
        // Вердикт-пилюля/слово («Нагрузка»/«Греется») ретайрнуты — владелец: слова лишние; состояние
        // несут тихая аура + тинт кольца. statusTitle/Sub теперь left-align (были right у прежней капсулы).
        statusTitle.alignment = .left
        statusSub.alignment = .left
        let statusCol = vstack([statusTitle, statusSub], 3); statusCol.alignment = .leading
        let hero = NSStackView(views: [ring, statusCol, spacer()])
        hero.alignment = .centerY; hero.spacing = 14
        hero.translatesAutoresizingMaskIntoConstraints = false
        hero.widthAnchor.constraint(equalToConstant: IW).isActive = true
        // витальные-приборы Ватт/Темп/Кулер/В АКБ (без бордюра, хайрлайн-делители).
        let vitals = buildVitalsStrip()
        // строка режима заряда Выкл/Лимит/Парус — ЧИСТЫЙ сегмент; жирная полоса-дубль (ChargeTrack.bar,
        // дублировала % кольца — владелец звал её «ползунком») убрана из ChargeTrack.
        chargeTrack.translatesAutoresizingMaskIntoConstraints = false
        chargeTrack.widthAnchor.constraint(equalToConstant: IW).isActive = true
        // disclosure лимита меняет высоту дорожки → поповер должен подрасти/ужаться следом
        chargeTrack.onHeightChanged = { [weak self] in
            self?.view.layoutSubtreeIfNeeded()
            self?.updatePreferredSize()
        }
        let tile = glassTile(vstack([headerTopBar(), hero, vitals, chargeTrack], 12))
        headerTile = tile
        return tile
    }
    /// Световой безель-шов по верхней кромке плитки: 1px rim-light, вписан в скругления.
    /// Оверлей поверх контента — НЕ влияет на высоту (плитка-инвариант цел).
    private func addTopRim(to tile: NSView) {
        let rim = RimLightView()
        rim.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(rim)
        NSLayoutConstraint.activate([
            rim.topAnchor.constraint(equalTo: tile.topAnchor, constant: 1),
            rim.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: Design.Radius.tile),
            rim.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -Design.Radius.tile),
            rim.heightAnchor.constraint(equalToConstant: 1),
        ])
    }
    private func buildFlowTile() -> NSView {
        // схема — почти на всю ширину плитки (узкое поле 6px).
        // V6: заголовок «Питание · расход» УБРАН (дублировал таб-тайтл «Питание» через строку),
        // термострока CPU°/GPU°/кулеров УБРАНА как сводка (дублировала шапку поповера и «Железо») —
        // thermalLabel остаётся ПУСТОЙ строкой-стоком для живого разбора узла под курсором.
        glassTile(vstack([flowView, flowInfoBar,
                          padLeading(thermalLabel, 10, width: FW)], 8), hInset: 6, fill: true)
    }
    /// Обёртка фиксированной ширины с левым отступом — для выравнивания текста при узком поле плитки.
    private func padLeading(_ v: NSView, _ inset: CGFloat, width: CGFloat) -> NSView {
        let c = NSView(); c.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            c.widthAnchor.constraint(equalToConstant: width),
            v.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: inset),
            v.topAnchor.constraint(equalTo: c.topAnchor),
            v.bottomAnchor.constraint(equalTo: c.bottomAnchor),
            v.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -inset),
        ])
        return c
    }
    /// Вкладка «Приватность» — радар исходящих соединений (PrivacyView) + честная сноска.
    /// Данные приходят из refreshAppFlags (тот же lsof-снимок, что кормит флаги «Приложений»).
    private func buildPrivacyTile() -> NSView {
        let sub = NSTextField(labelWithString: "")
        sub.font = Design.Font.caption; sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byWordWrapping; sub.maximumNumberOfLines = 2
        sub.preferredMaxLayoutWidth = FW - 20
        let note = NSTextField(labelWithString: "")
        note.font = Design.Font.sys(9, .regular); note.textColor = .tertiaryLabelColor
        note.lineBreakMode = .byWordWrapping; note.maximumNumberOfLines = 6   // «Порты»-сноска длиннее (оговорка про метки) — не режем
        note.preferredMaxLayoutWidth = FW - 20
        // Подпись/сноска зависят от основы: исходящие (страны/приложения) ↔ входящая поверхность (порты).
        // Честность: для портов явно оговариваем «видно в сети ≠ доступно из интернета».
        func applyBasis(_ b: PrivacyView.Basis) {
            if b == .ports {
                sub.stringValue = L("Какие порты открыты на этом Mac — слушающие TCP-сокеты и их видимость.")
                note.stringValue = L("Только наблюдение (lsof). «Наружу» — привязка к сетевому адресу (виден в вашей сети), «только этот Mac» — loopback. Видно в сети ≠ доступно из интернета: NAT и фаервол могут не пускать. Метка сервиса — обычное назначение номера порта, а не проверка того, что реально слушает.")
            } else {
                sub.stringValue = L("Куда сейчас звонит ваш Mac — исходящие соединения и их страны.")
                note.stringValue = L("Только наблюдение: локальный снимок (lsof), без перехвата и без сети. Страна — офлайн-база. Блокировать исходящее нельзя; блок входящих и доменов — в Настройках.")
            }
        }
        applyBasis(privacyView.currentBasis)                        // старт с текущей основы (переживает переоткрытие)
        privacyView.onBasisChange = { applyBasis($0) }
        return glassTile(vstack([padLeading(Self.sectionLabel(L("Приватность · радар")), 10, width: FW),
                                 padLeading(sub, 10, width: FW),
                                 padLeading(buildMediaChip(), 10, width: FW),
                                 padLeading(buildVPNChip(), 10, width: FW),
                                 privacyView,
                                 padLeading(note, 10, width: FW)], 8), hInset: 6, fill: true)
    }

    private var mediaChipRefresh: (() -> Void)?
    /// Чип «камера/микрофон используются» — FDA-free live-детект (CoreAudio/CoreMediaIO). Честно БЕЗ имени
    /// приложения (публичного API нет): красный = активно, серый = не активно.
    private func buildMediaChip() -> NSView {
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let label = NSTextField(labelWithString: L("проверка…"))
        label.font = Design.Font.body; label.lineBreakMode = .byTruncatingTail; label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: FW - 20).isActive = true
        row.toolTip = L("какое приложение — из этого API не видно")   // честная граница: устройство активно, имя не выдаём
        func apply(_ s: MediaSensors.State) {
            let sym: String, color: NSColor, text: String
            if s.camera && s.mic { sym = "video.fill"; color = .systemRed; text = L("Камера и микрофон используются") }
            else if s.camera     { sym = "video.fill"; color = .systemRed; text = L("Камера используется") }
            else if s.mic        { sym = "mic.fill";   color = .systemRed; text = L("Микрофон используется") }
            else                 { sym = "video.slash"; color = .tertiaryLabelColor; text = L("Камера и микрофон не активны") }
            icon.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            icon.contentTintColor = color
            label.stringValue = text; label.textColor = s.any ? .labelColor : .secondaryLabelColor
        }
        mediaChipRefresh = { MediaSensors.read { apply($0) } }   // фон-чтение → apply на main
        mediaChipRefresh?()
        return row
    }

    /// VPN-чип: честный статус (free) + connect/disconnect системного профиля (Pro).
    /// «Защищён» только когда именованный профиль Connected; иначе — маршрут по умолчанию (голый utun ≠ VPN).
    private func buildVPNChip() -> NSView {
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let label = NSTextField(labelWithString: L("проверка…"))
        label.font = Design.Font.body; label.lineBreakMode = .byTruncatingTail; label.textColor = .secondaryLabelColor
        let btn = GlassButton(title: L("Подключить"), symbol: "lock.fill")
        btn.isHidden = true
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [icon, label, spacer, btn])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: FW - 20).isActive = true

        func sym(_ name: String, _ color: NSColor) {
            icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            icon.contentTintColor = color
        }
        func apply(_ s: VPN.Status) {                               // UI-правки на main (status читается в фоне)
            if let a = s.active {                                   // именованный профиль Connected → защищён
                sym("lock.fill", .systemGreen)
                label.stringValue = String(format: L("VPN активен: %@"), a.name); label.textColor = .labelColor
                btn.title = L("Отключить"); btn.isHidden = false
                btn.onClick = { [weak self] in
                    guard SettingsWindowController.shared.requirePro(.vpn) else { return }
                    VPN.disconnect(a.name)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.vpnChipRefresh?() }
                }
            } else if let target = s.profiles.first(where: { $0.enabled }) ?? s.profiles.first {   // есть профиль, отключён
                sym("lock.open", .systemOrange)
                label.stringValue = L("Без VPN")                       // коротко (не влезало «…маршрут через en0» рядом с кнопкой)
                label.toolTip = String(format: L("Маршрут по умолчанию через %@"), s.defaultInterface)   // деталь маршрута — на ховере
                label.textColor = .secondaryLabelColor
                btn.title = s.profiles.count > 1 ? String(format: L("Подключить: %@"), target.name) : L("Подключить")
                btn.isHidden = false
                btn.onClick = { [weak self] in
                    guard SettingsWindowController.shared.requirePro(.vpn) else { return }
                    VPN.connect(target.name)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.vpnChipRefresh?() }
                }
            } else {                                                // системных профилей нет
                sym("lock.slash", .tertiaryLabelColor)
                label.stringValue = L("Нет системных VPN-профилей"); label.textColor = .tertiaryLabelColor
                btn.isHidden = true
            }
        }
        vpnChipRefresh = { VPN.status { apply($0) } }               // фон-чтение → apply на main (не блокируем открытие)
        vpnChipRefresh?()
        return row
    }

    /// Вкладка «Обслуживание» — read-only постура (XProtect/SIP/FileVault), всё без root.
    /// Строки-плейсхолдеры синхронно (высота корректна), постура читается В ФОНЕ и заполняет их на main.
    private func buildMaintenanceTile() -> NSView {
        struct Row { let view: NSView; let icon: NSImageView; let value: NSTextField }
        func makeRow(_ title: String) -> Row {
            let iv = NSImageView(); iv.imageScaling = .scaleProportionallyDown
            iv.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            iv.contentTintColor = .tertiaryLabelColor
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 18).isActive = true
            let t = NSTextField(labelWithString: title); t.font = Design.Font.body; t.textColor = .labelColor
            t.setContentCompressionResistancePriority(.required, for: .horizontal)      // заголовок держит ширину
            let v = NSTextField(labelWithString: L("проверка…")); v.font = Design.Font.numericBody; v.alignment = .right
            v.textColor = .tertiaryLabelColor
            // Статус остаётся одной компактной правой колонкой. Полная строка
            // доступна в tooltip; перенос ломал вертикальный ритм вкладки.
            v.lineBreakMode = .byTruncatingTail; v.maximumNumberOfLines = 1
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)    // при дефиците ширины гнётся ЗНАЧЕНИЕ, не заголовок
            let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let r = NSStackView(views: [iv, t, spacer, v])
            r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 8
            r.translatesAutoresizingMaskIntoConstraints = false
            r.widthAnchor.constraint(equalToConstant: IW).isActive = true
            return Row(view: r, icon: iv, value: v)
        }
        // unknown/neutral = серо (не зелёный «ок»); level=nil без neutral = зелёный «в норме». Честность закон #1.
        func setRow(_ row: Row, _ value: String, _ level: Design.Level?, symbol: String, unknown: Bool = false, neutral: Bool = false) {
            let grey = unknown || neutral
            row.value.stringValue = value
            row.value.toolTip = value
            row.value.textColor = grey ? .tertiaryLabelColor
                : (level == nil ? .secondaryLabelColor : (level == .crit ? .systemRed : .systemOrange))
            row.icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            row.icon.contentTintColor = grey ? .tertiaryLabelColor
                : (level == .crit ? .systemRed : (level == .warn ? .systemOrange : .systemGreen))
        }
        let xp = makeRow(L("Защита XProtect"))
        let sip = makeRow(L("Целостность системы (SIP)"))
        let fv = makeRow(L("Шифрование диска (FileVault)"))
        let boot = makeRow(L("Boot-args"))
        let upd = makeRow(L("Обновления macOS"))
        let mem = makeRow(L("Память"))
        let therm = makeRow(L("Термонагрузка"))
        let sleep = makeRow(L("Что мешает сну"))
        let crash = makeRow(L("Отчёты о сбоях (7 дн)"))
        let note = NSTextField(labelWithString: L("Только чтение. Факты из системных утилит (csrutil, fdesetup, XProtect, pmset) — без root."))
        note.font = Design.Font.sys(9, .regular); note.textColor = .tertiaryLabelColor
        note.lineBreakMode = .byWordWrapping; note.maximumNumberOfLines = 2
        note.preferredMaxLayoutWidth = IW

        Maintenance.posture { p in
            let xpUnknown = p.xprotect == nil
            setRow(xp, p.xprotect.map { L("сигнатуры ") + $0 } ?? "—", nil,
                   symbol: xpUnknown ? "questionmark.circle" : "checkmark.shield.fill", unknown: xpUnknown)
            setRow(sip, p.sip.label, p.sip.level,
                   symbol: p.sip.level == nil ? "lock.fill" : "exclamationmark.shield.fill")
            let fvUnknown = p.fileVault == nil
            let fvLevel: Design.Level? = p.fileVault == false ? .warn : nil
            let fvVal = fvUnknown ? "—" : (p.fileVault! ? L("включено") : L("выключено"))
            setRow(fv, fvVal, fvLevel,
                   symbol: fvUnknown ? "questionmark.circle" : (fvLevel == nil ? "lock.fill" : "lock.open.fill"), unknown: fvUnknown)
            // boot-args: ВСЕГДА нейтрально-серо (факт без вердикта по флагам — «no verdict» политика);
            // стандартно → «стандартные», кастом → verbatim (заполненный флажок как маркер «есть что-то»).
            let ba = p.bootArgs
            setRow(boot, ba ?? L("стандартные"), nil, symbol: ba == nil ? "flag" : "flag.fill", neutral: true)
            // обновления macOS: атрибуция самой ОС. Патч в текущей ОС → warn (актуально применим); апгрейд ОС
            // (major) → НЕЙТРАЛЬ (валидный выбор, не «тревога»). «нет» — тоже нейтраль (не зелёное «защищены»).
            let df = DateFormatter(); df.dateFormat = "d MMM"; df.locale = Locale(identifier: I18n.current.rawValue)
            let ups = p.pendingUpdates
            if let sel = ups.first(where: { !$0.major }) ?? ups.first {   // предпочитаем не-major патч
                let extra = ups.count - 1
                let val = extra > 0 ? String(format: L("%@ +%d"), sel.name, extra) : sel.name
                if sel.major {
                    setRow(upd, String(format: L("доступно обновление ОС: %@"), val), nil, symbol: "arrow.up.circle", neutral: true)
                } else {
                    setRow(upd, val, .warn, symbol: "arrow.down.circle.fill")
                }
            } else if let ch = p.updateChecked, Date().timeIntervalSince(ch) < 14 * 86400 {
                setRow(upd, String(format: L("нет (проверено %@)"), df.string(from: ch)), nil, symbol: "checkmark.circle", neutral: true)
            } else {
                setRow(upd, String(format: L("проверка: %@"), p.updateChecked.map { df.string(from: $0) } ?? L("никогда")),
                       nil, symbol: "questionmark.circle", neutral: true)
            }
            // память: ЧЕСТНО показываем ДАВЛЕНИЕ (метрика ядра), а не «% занято» (высокий used на macOS — норма).
            // green только для измеренного «в норме»; повышенное→orange, критическое→red, неизвестно→серо.
            let ms = p.memory
            let mLabel: String; let mLevel: Design.Level?; var mGrey = false
            switch ms.pressure {
            case .normal:   mLabel = L("в норме");     mLevel = nil
            case .warning:  mLabel = L("повышенное");  mLevel = .warn
            case .critical: mLabel = L("критическое"); mLevel = .crit
            case .unknown:  mLabel = "—";              mLevel = nil; mGrey = true
            }
            // своп в работе при «норме» → НЕ зелёно-успокаивающе (наш же код зовёт своп признаком нехватки):
            // гасим зелёный в нейтраль, текст остаётся честным. Зелёный только при норме И нулевом свопе.
            if ms.pressure == .normal && ms.swapUsed > 0 { mGrey = true }
            let swapStr = ms.swapUsed > 0 ? " · " + String(format: L("своп %.1f ГБ"), Double(ms.swapUsed) / 1e9) : ""
            setRow(mem, mLabel + swapStr, mLevel,
                   symbol: ms.pressure == .unknown ? "questionmark.circle" : "memorychip", neutral: mGrey)
            mem.view.toolTip = L("Давление памяти (не «% занято»): ядро само сообщает, реально ли не хватает RAM. Своп в работе — признак нехватки.")
            // здоровье/стабильность — зелёный ТОЛЬКО для .nominal; fair/unknown нейтрально-серые
            setRow(therm, p.thermal.label, p.thermal.level,
                   symbol: p.thermal == .unknown ? "questionmark.circle" : (p.thermal.level == nil ? "thermometer.medium" : "thermometer.sun.fill"),
                   neutral: p.thermal == .fair || p.thermal == .unknown)
            let blocked = !p.sleepBlockers.isEmpty
            setRow(sleep, blocked ? p.sleepBlockers.prefix(3).joined(separator: ", ") : L("ничто не мешает"), nil,
                   symbol: blocked ? "powersleep" : "moon.zzz.fill", neutral: blocked)
            let crashed = p.crashes7d > 0
            let crashVal = crashed ? "\(p.crashes7d)" + (p.latestCrash.map { " · " + $0 } ?? "") : "0"
            setRow(crash, crashVal, nil,
                   symbol: crashed ? "exclamationmark.triangle" : "checkmark.circle", neutral: crashed)
        }
        return glassTile(vstack([
            Self.sectionLabel(L("Обслуживание · защита")), xp.view, sip.view, fv.view, boot.view, upd.view,
            Self.sectionLabel(L("Здоровье и стабильность")), mem.view, therm.view, sleep.view, crash.view,
            note,
        ], 10), fill: true)
    }
    private func buildBatteryStatsTile() -> NSView { glassTile(buildBatteryStatsContent()) }
    /// Внутренний контент «Батарея» (без glass-обёртки) — для одиночной плитки И консоль-группы.
    private func buildBatteryStatsContent() -> NSView {
        // «Темп. АКБ» (не просто «Темп») — развести с витальной «Темп» (та = CPU): разные датчики, разные числа.
        let battRow = NSStackView(views: [battStat("Здоровье", L("Здоровье")), battStat("Циклы", L("Циклы")), battStat("Температура", L("Темп. АКБ"))])
        battRow.distribution = .fillEqually; battRow.spacing = 8
        battRow.translatesAutoresizingMaskIntoConstraints = false
        battRow.widthAnchor.constraint(equalToConstant: IW).isActive = true
        // Возраст АКБ (дата + циклы/ресурс) — метрика-строка; заполняется в апдейте, пустая скрыта.
        let age = NSTextField(labelWithString: ""); age.font = Design.Font.sys(10, .regular); age.textColor = .secondaryLabelColor
        age.lineBreakMode = .byTruncatingTail; metric["battAge"] = age
        // «Почему не заряжается» — видна ТОЛЬКО когда воткнут+не заряжается+не полный (иначе скрыта).
        let why = NSTextField(labelWithString: ""); why.font = Design.Font.sys(10, .regular); why.textColor = .systemOrange
        why.lineBreakMode = .byWordWrapping; why.maximumNumberOfLines = 2; why.preferredMaxLayoutWidth = IW
        why.isHidden = true; metric["battWhy"] = why
        return vstack([Self.sectionLabel(L("Батарея")), battRow, age, why], 10)
    }

    /// Возраст АКБ из literal-даты (если парсится yyyy-MM-dd) + циклы/ресурс. Дата НЕ утверждается точной («≈»).
    private func batteryAgeLine(_ b: BatteryInfo) -> String {
        var parts: [String] = []
        if let d = b.manufactureDate {
            var s = String(format: L("АКБ %@"), d)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            if let date = f.date(from: d) {
                let months = Calendar.current.dateComponents([.month], from: date, to: Date()).month ?? 0
                if months > 0 { s += String(format: L(" · ≈%.1f г."), Double(months) / 12.0) }
            }
            parts.append(s)
        }
        if let rated = b.ratedCycles {
            parts.append(String(format: L("%d / %d циклов (%.0f%%)"), b.cycleCount, rated, Double(b.cycleCount) / Double(rated) * 100))
        } else {
            parts.append(String(format: L("%d циклов"), b.cycleCount))
        }
        return parts.joined(separator: " · ")
    }

    /// Честная причина «не заряжается». НАШИ причины (лимит/парус) заявляем ТОЛЬКО когда демон РЕАЛЬНО стоит
    /// (иначе BCLM никто не пишет — приписывать себе нельзя) И лимит сейчас НЕ поднят top-up/будильником.
    /// heat-паузу НЕ атрибутируем: демон решает по TB0T, а мы видим лишь Temperature АКБ — они расходятся.
    /// Причина ОС — недокументированный код literal (смысл не выдумываем).
    private func batteryWhyNotCharging(_ b: BatteryInfo) -> String? {
        guard b.present, b.external, !b.charging, b.charge < 100 else { return nil }
        if FanController.daemonInstalled, !ChargeControl.isTopUpActive, !inChargeAlarmWindow() {
            if SettingsStore.chargeMode == "sail", b.charge >= SettingsStore.sailUpper - 2 {
                return String(format: L("Не заряжается: парусный режим %d–%d%% (Kelvin)"), SettingsStore.sailLower, SettingsStore.sailUpper)
            }
            if SettingsStore.chargeLimit < 100, b.charge >= SettingsStore.chargeLimit - 2 {
                return String(format: L("Не заряжается: лимит %d%% (Kelvin)"), SettingsStore.chargeLimit)
            }
        }
        if let r = b.notChargingReason, r != 0 {
            return String(format: L("Не заряжается: система приостановила заряд (код %d)"), r)
        }
        return nil
    }

    /// Активно ли сейчас суточное окно планового дозаряда (тогда демон поднимает BCLM=100 — лимит не держит).
    private func inChargeAlarmWindow() -> Bool {
        guard SettingsStore.chargeAlarmOn else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let target = SettingsStore.chargeAlarmTargetMin, lead = SettingsStore.chargeAlarmLeadMin
        let start = (target - lead + 1440) % 1440
        return start <= target ? (now >= start && now <= target) : (now >= start || now <= target)
    }
    /// Диск: свободно / занято % / ввод-вывод (R/W) + живая скорость сети (↓/↑).
    /// Сеть локальна (NetUsage сэмплит счётчики интерфейса, без телеметрии). Постоянное число строк.
    private func buildDiskTile() -> NSView { glassTile(buildDiskContent()) }
    /// Внутренний контент «Диск» (без glass-обёртки) — для одиночной плитки И консоль-группы.
    private func buildDiskContent() -> NSView {
        let diskRow = NSStackView(views: [battStat("diskFree", L("Свободно")),
                                          battStat("diskUsed", L("Занято"))])
        diskRow.distribution = .fillEqually; diskRow.spacing = 8
        diskRow.translatesAutoresizingMaskIntoConstraints = false
        diskRow.widthAnchor.constraint(equalToConstant: IW).isActive = true
        // В/В диска — СВОЯ полноширинная строка: «↓1.2M ↑850K» в 1/3-колонке обрезалось до «↓1.2M ↑85».
        let ioVal = NSTextField(labelWithString: "↓0 ↑0")
        metric["diskIO"] = ioVal
        let ioRow = miniStat(ioVal, NSTextField(labelWithString: L("Диск · В/В")))
        ioRow.widthAnchor.constraint(equalToConstant: IW).isActive = true
        // строка скорости сети: значение «↓1.2M ↑850K» + подпись (тот же miniStat-язык, на всю ширину)
        let netVal = NSTextField(labelWithString: "↓0 ↑0")
        metric["netRate"] = netVal
        let netRow = miniStat(netVal, NSTextField(labelWithString: L("Сеть")))
        netRow.widthAnchor.constraint(equalToConstant: IW).isActive = true
        // честное раскрытие purgeable: часть «свободного» (по Finder) — очищаемый кэш/снимки, не свободно сейчас
        let purge = NSTextField(labelWithString: "")
        purge.font = Design.Font.sys(9, .regular); purge.textColor = .tertiaryLabelColor
        purge.lineBreakMode = .byWordWrapping; purge.maximumNumberOfLines = 2
        purge.preferredMaxLayoutWidth = IW; purge.isHidden = true
        metric["diskPurge"] = purge
        refreshDisk()                                   // первичное заполнение до первого тика
        return vstack([Self.sectionLabel(L("Диск")), diskRow, purge, ioRow, netRow], 10)
    }
    /// Живые значения диска: ёмкость (мгновенно) + свежая скорость R/W. Зовётся из update() каждый тик.
    private func refreshDisk() {
        guard metric["diskFree"] != nil else { return }   // плитка не построена
        DiskUsage.shared.sample()                          // освежаем дельту R/W, как net
        if let cap = DiskInfo.capacity(), cap.total > 0 {
            metric["diskFree"]?.stringValue = String(format: "%.0f", Double(cap.free) / 1e9) + " " + L("ГБ")
            let usedPct = Double(cap.total - cap.free) / Double(cap.total) * 100
            metric["diskUsed"]?.stringValue = String(format: "%.0f%%", usedPct)
            if cap.purgeable >= 500_000_000 {           // раскрываем только если очищаемого заметно (≥0.5 ГБ)
                metric["diskPurge"]?.stringValue = String(format: L("из них ≈%.1f ГБ очищаемые (purgeable): кэш и снимки — Finder считает их свободными, поэтому «занято» тоже занижено"), Double(cap.purgeable) / 1e9)
                metric["diskPurge"]?.isHidden = false
            } else {
                metric["diskPurge"]?.isHidden = true
            }
        } else {
            metric["diskFree"]?.stringValue = "—"
            metric["diskUsed"]?.stringValue = "—"
            metric["diskPurge"]?.isHidden = true
        }
        metric["diskIO"]?.stringValue = "↓\(NetUsage.fmtRate(DiskUsage.shared.read)) ↑\(NetUsage.fmtRate(DiskUsage.shared.write))"
        let net = NetUsage.shared.sample()              // локальный замер ↓/↑ (как net-чип в меню-баре)
        metric["netRate"]?.stringValue = "↓\(NetUsage.fmtRate(net.down)) ↑\(NetUsage.fmtRate(net.up))"
    }
    /// Bluetooth-периферия: список подключённых устройств с зарядом (L/R/кейс или одно %).
    /// ФИКСИРОВАННОЕ число строк-слотов — высота поповера не прыгает; лишние слоты пустеют.
    /// Кэш читается мгновенно, тяжёлый system_profiler освежается вне main (refreshIfStale).
    private func buildBTBatteryTile() -> NSView { glassTile(buildBTBatteryContent(), fill: false) }   // V3: топ-модуль ХУГАЕТ контент (fill:true растягивался на слабину .fill-стека → пустой провал)
    /// Внутренний контент Bluetooth (без glass-обёртки) — для одиночной плитки И консоль-группы.
    private func buildBTBatteryContent() -> NSView {
        let slotCount = 4                                  // AirPods + мышь + клава + трекпад; хвостовые пустые слоты схлопываются
        btSlots = []
        var rows: [NSView] = [Self.sectionLabel(L("Bluetooth"))]
        for _ in 0..<slotCount {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.contentTintColor = .secondaryLabelColor
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            let name = NSTextField(labelWithString: "")
            name.font = Design.Font.caption
            name.textColor = .labelColor
            name.lineBreakMode = .byTruncatingTail
            let value = NSTextField(labelWithString: "")
            value.font = Design.Font.numericBody
            value.textColor = .secondaryLabelColor
            value.alignment = .right
            let row = NSStackView(views: [icon, name, spacer(), value])
            row.alignment = .centerY; row.spacing = 7
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: IW).isActive = true
            btSlots.append(BTSlot(row: row, icon: icon, name: name, value: value))
            rows.append(row)
        }
        refreshBT()                                        // первичное заполнение из кэша до первого тика
        return vstack(rows, 6)
    }
    /// Живые значения Bluetooth: читаем кэш синхронно, рисуем по фиксированным слотам и
    /// подкидываем неблокирующее обновление кэша. Зовётся из update() каждый тик (no-op без плитки).
    private func refreshBT() {
        guard !btSlots.isEmpty else { return }             // плитка не построена
        let devs = BTPeripherals.cached()
        for (i, slot) in btSlots.enumerated() {
            if i < devs.count {
                let d = devs[i]
                slot.icon.image = NSImage(systemSymbolName: d.icon, accessibilityDescription: nil)
                slot.icon.isHidden = false
                slot.name.stringValue = d.name
                slot.name.textColor = .labelColor
                slot.value.stringValue = btValueString(d)
                slot.row.isHidden = false
            } else if i == 0 && devs.isEmpty {
                // единственная строка-состояние «нет устройств»
                slot.icon.image = nil; slot.icon.isHidden = true
                slot.name.stringValue = L("нет устройств")
                slot.name.textColor = .tertiaryLabelColor
                slot.value.stringValue = ""
                slot.row.isHidden = false
            } else {
                // хвостовые пустые слоты СХЛОПЫВАЕМ (как в «Звук») — без мёртвого вертикального провала
                slot.row.isHidden = true
            }
        }
        // освежаем кэш вне main; по готовности — перерисовываем слоты, пока поповер на экране
        // (у контроллера есть window только когда поповер показан — иначе незачем перерисовывать)
        BTPeripherals.refreshIfStale { [weak self] in
            if self?.view.window != nil { self?.refreshBT() }
        }
    }
    /// Компактная подпись заряда устройства: «Л84 П86 К72» для AirPods или одно «84%».
    private func btValueString(_ d: BTPeripheral) -> String {
        if d.main == nil && (d.left != nil || d.right != nil || d.caseLvl != nil) {
            var parts: [String] = []
            if let l = d.left    { parts.append(L("Лев.") + " \(l)") }
            if let r = d.right   { parts.append(L("Прав.") + " \(r)") }
            if let c = d.caseLvl { parts.append(L("Кейс") + " \(c)") }
            return parts.joined(separator: "  ")
        }
        if let m = d.main { return "\(m)%" }
        return d.worst.map { "\($0)%" } ?? "—"
    }

    /// Плитка «Звук · вывод»: строки-устройства, текущее с галкой; клик по другому → сделать выводом
    /// по умолчанию (Pro). ЧЕСТНОСТЬ: меняем СИСТЕМНЫЙ вывод по умолчанию, не «маршрутизируем весь звук».
    private func buildAudioTile() -> NSView { glassTile(buildAudioContent(), fill: false) }   // V3: топ-модуль ХУГАЕТ контент (fill:true растягивался на слабину .fill-стека → пустой провал)
    
    /// Вкладка «Здоровье» — Центр здоровья Mac (Kelvin Advisor).
    /// Показывает общий статус и список рекомендаций.
    private func buildHealthTile() -> NSView {
        // Общий статус (вердикт)
        healthVerdictLabel.font = Design.Font.headline
        healthVerdictLabel.textColor = .labelColor
        healthVerdictLabel.lineBreakMode = .byWordWrapping
        healthVerdictLabel.maximumNumberOfLines = 2
        healthVerdictLabel.preferredMaxLayoutWidth = IW
        healthVerdictLabel.translatesAutoresizingMaskIntoConstraints = false
        healthVerdictLabel.widthAnchor.constraint(equalToConstant: IW).isActive = true
        
        // Мета-информация: количество рекомендаций, время анализа
        healthMetaLabel.font = Design.Font.sys(9, .regular)
        healthMetaLabel.textColor = .tertiaryLabelColor
        healthMetaLabel.lineBreakMode = .byTruncatingTail
        healthMetaLabel.maximumNumberOfLines = 1
        
        // Список рекомендаций (контейнер)
        healthFindingsContainer.orientation = .vertical
        healthFindingsContainer.spacing = 8
        healthFindingsContainer.translatesAutoresizingMaskIntoConstraints = false
        healthFindingsContainer.widthAnchor.constraint(equalToConstant: IW).isActive = true
        
        // Кнопка обновления
        let refreshBtn = GlassButton(title: L(\"Обновить\"), symbol: \"arrow.clockwise\", cornerRadius: Design.Radius.chip)
        refreshBtn.onClick = { [weak self] in self?.refreshAdvisor() }
        
        let content = vstack([healthVerdictLabel, healthMetaLabel, healthFindingsContainer, refreshBtn], 10)
        return glassTile(content, fill: true)
    }
    
    private func buildAudioContent() -> NSView {
        let slotCount = 6                                  // покрывает почти любой набор; переполнение честно раскрываем в сноске
        audioSlots = []
        var rows: [NSView] = [Self.sectionLabel(L("Звук · вывод"))]
        for _ in 0..<slotCount {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyDown
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            let name = NSTextField(labelWithString: "")
            name.font = Design.Font.body; name.textColor = .labelColor
            name.lineBreakMode = .byTruncatingTail
            let check = NSImageView()
            check.translatesAutoresizingMaskIntoConstraints = false
            check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
            check.contentTintColor = Design.Color.accent(isDark)
            check.widthAnchor.constraint(equalToConstant: 16).isActive = true
            check.isHidden = true
            let row = NSStackView(views: [icon, name, spacer(), check])
            row.alignment = .centerY; row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: IW).isActive = true
            let g = NSClickGestureRecognizer(target: self, action: #selector(audioSlotClicked(_:)))
            row.addGestureRecognizer(g)
            audioSlots.append(AudioSlot(row: row, icon: icon, name: name, check: check, deviceID: nil))
            rows.append(row)
        }
        let note = NSTextField(labelWithString: L("Меняет системный вывод по умолчанию. Приложение со своим выбором устройства это не трогает."))
        note.font = Design.Font.sys(9, .regular); note.textColor = .tertiaryLabelColor
        note.lineBreakMode = .byWordWrapping; note.maximumNumberOfLines = 3
        note.preferredMaxLayoutWidth = IW
        metric["audioNote"] = note                         // refreshAudio дописывает честное раскрытие переполнения
        rows.append(note)
        refreshAudio()                                     // первичное заполнение до первого тика
        return vstack(rows, 6)
    }
    /// Живые значения аудио: перечисление устройств вне main, отрисовка по фиксированным слотам.
    /// Зовётся из update() каждый тик (no-op без плитки). Ловит и hot-plug, и смену дефолта извне.
    private func refreshAudio() {
        guard !audioSlots.isEmpty else { return }          // плитка не построена
        AudioDevices.outputs { [weak self] devs in
            guard let self = self, !self.audioSlots.isEmpty else { return }
            for i in self.audioSlots.indices {
                let slot = self.audioSlots[i]
                if i < devs.count {
                    let d = devs[i]
                    self.audioSlots[i].deviceID = d.id
                    slot.icon.image = NSImage(systemSymbolName: d.isCurrent ? "hifispeaker.fill" : "hifispeaker", accessibilityDescription: nil)
                    slot.icon.contentTintColor = d.isCurrent ? Design.Color.accent(self.isDark) : .secondaryLabelColor
                    slot.icon.isHidden = false
                    slot.name.stringValue = d.name
                    slot.name.textColor = d.isCurrent ? .labelColor : .secondaryLabelColor
                    slot.check.isHidden = !d.isCurrent
                    slot.row.isHidden = false
                } else if i == 0 {
                    self.audioSlots[i].deviceID = nil
                    slot.icon.image = nil; slot.icon.isHidden = true
                    slot.name.stringValue = L("нет устройств вывода")
                    slot.name.textColor = .tertiaryLabelColor
                    slot.check.isHidden = true
                    slot.row.isHidden = false
                } else {
                    self.audioSlots[i].deviceID = nil
                    slot.row.isHidden = true
                }
            }
            // честно раскрываем, если устройств больше, чем слотов (без «тихого капа»)
            let base = L("Меняет системный вывод по умолчанию. Приложение со своим выбором устройства это не трогает.")
            if devs.count > self.audioSlots.count {
                self.metric["audioNote"]?.stringValue = base + " " + String(format: L("+%d ещё — в Настройках звука."), devs.count - self.audioSlots.count)
            } else {
                self.metric["audioNote"]?.stringValue = base
            }
        }
    }
    /// Клик по слоту: не-текущий → сделать выводом по умолчанию (Pro-гейт). Текущий = no-op (без гейта).
    @objc private func audioSlotClicked(_ g: NSClickGestureRecognizer) {
        guard let v = g.view, let slot = audioSlots.first(where: { $0.row === v }), let id = slot.deviceID else { return }
        if slot.check.isHidden == false { return }         // уже текущий вывод — клик ничего не меняет
        guard Licensing.shared.isPro else { _ = SettingsWindowController.shared.requirePro(.audioSwitch); return }
        if AudioDevices.setDefaultOutput(id) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refreshAudio() }
        }
    }

    /// Вкладка «История» V5 = КАРТОЧКА БАТАРЕИ (решение владельца: «30 дней CPU — мутные данные»):
    /// вердикт-вывод + три крупных числа (Здоровье/Циклы/Тренд) + ОДИН маленький график заряда за
    /// сегодня + экспорт CSV/PDF. Данные в SQLite пишутся как прежде (90 дней — для PDF и тренда).
    private func buildHistoryTile() -> NSView {
        // Вердикт — главный вывод, читается первым (как в «Приложениях»).
        historyVerdict.font = Design.Font.headline
        historyVerdict.textColor = .labelColor
        historyVerdict.lineBreakMode = .byWordWrapping; historyVerdict.maximumNumberOfLines = 2
        historyVerdict.preferredMaxLayoutWidth = IW
        historyVerdict.translatesAutoresizingMaskIntoConstraints = false
        historyVerdict.widthAnchor.constraint(equalToConstant: IW).isActive = true

        // Три крупных числа — та же miniStat-грамматика, что футер «Приложений»/консоль.
        let numsRow = NSStackView(views: [miniStat(histCardHealth, NSTextField(labelWithString: L("Здоровье"))),
                                          miniStat(histCardCycles, NSTextField(labelWithString: L("Циклы"))),
                                          miniStat(histCardTrend, NSTextField(labelWithString: L("Тренд")))])
        numsRow.distribution = .fillEqually; numsRow.spacing = 8
        numsRow.translatesAutoresizingMaskIntoConstraints = false
        numsRow.widthAnchor.constraint(equalToConstant: IW).isActive = true

        // Один маленький график: заряд за сегодня (24 ч) — «как жила батарея сегодня».
        let chartCap = Self.sectionLabel(L("Заряд сегодня"))
        let chart = HistoryChart()
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 72).isActive = true
        chart.widthAnchor.constraint(equalToConstant: IW).isActive = true
        historyChart = chart

        historyFooter.font = Design.Font.sys(9, .regular); historyFooter.textColor = .tertiaryLabelColor
        historyFooter.lineBreakMode = .byWordWrapping; historyFooter.maximumNumberOfLines = 2
        historyFooter.preferredMaxLayoutWidth = IW

        // строка деталей (здоровье/циклы текстом — дубль чисел в компакте не нужен; оставляем тренд-детали)
        historyDegrade.font = Design.Font.sys(10, .regular); historyDegrade.textColor = .secondaryLabelColor
        historyDegrade.alignment = .left
        historyDegrade.lineBreakMode = .byWordWrapping; historyDegrade.maximumNumberOfLines = 2
        historyDegrade.preferredMaxLayoutWidth = IW
        historyDegrade.translatesAutoresizingMaskIntoConstraints = false
        historyDegrade.widthAnchor.constraint(equalToConstant: IW).isActive = true

        let exportBtn = GlassButton(title: L("Экспорт CSV"), symbol: "square.and.arrow.up", cornerRadius: Design.Radius.chip)
        exportBtn.onClick = { [weak self] in self?.exportHistoryCSV() }
        let pdfBtn = GlassButton(title: L("PDF-отчёт"), symbol: "doc.richtext", cornerRadius: Design.Radius.chip)
        pdfBtn.onClick = { [weak self] in self?.exportHealthReportPDF() }
        let btnRow = NSStackView(views: [exportBtn, pdfBtn])
        btnRow.spacing = 8

        refreshHistory()
        return glassTile(vstack([Self.sectionLabel(L("Батарея · история")), historyVerdict, numsRow,
                                 chartCap, chart, historyDegrade, historyFooter, btnRow], 10), fill: true)
    }

    /// Экспорт истории выбранного периода в CSV-файл (Pro). Данные уже собраны `History.exportCSV`.
    private func exportHistoryCSV() {
        guard Licensing.shared.isPro else { _ = SettingsWindowController.shared.requirePro(.history); return }
        let since = Int64(Date().timeIntervalSince1970) - 30 * 86_400   // карточка без выбора диапазона → полный отчёт за 30д
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "kelvin-history.csv"       // расширение задаёт тип (без импорта UTI)
        panel.title = L("Экспорт истории")
        NSApp.activate(ignoringOtherApps: true)                 // поповер мог потерять фокус — поднимаем панель поверх
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            History.shared.exportCSV(since: since) { csv in
                DispatchQueue.global(qos: .utility).async {
                    try? csv.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    /// PDF-отчёт «Здоровье Mac за месяц» (Pro). Строит из локальной истории + текущей батареи.
    private func exportHealthReportPDF() {
        guard Licensing.shared.isPro else { _ = SettingsWindowController.shared.requirePro(.history); return }
        let period: TimeInterval = 30 * 86_400
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "kelvin-health-report.pdf"
        panel.title = L("Отчёт о здоровье Mac")
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let b = BatteryReader.read()
                let hs = History.shared.series(.health, since: Int64(Date().timeIntervalSince1970) - Int64(period))
                let insight = BatteryHealth.analyze(battery: b, healthSeries: hs)
                let data = Report.healthReportPDF(period: period, battery: b, insight: insight)
                try? data.write(to: url)
            }
        }
    }

    /// Обновить карточку деградации АКБ (тренд/циклы/прогноз). Читает историю health за ≤90д — независимо
    /// от выбранного диапазона графика (честный полный анализ). Скрывается на десктопе (нет АКБ).
    private func refreshDegrade(battery b: BatteryInfo?, series: [(ts: Int64, v: Double)]) {
        let ins = BatteryHealth.analyze(battery: b, healthSeries: series)
        guard ins.present, let h = ins.health else {
            historyDegrade.stringValue = ""; historyDegrade.isHidden = true
            historyVerdict.stringValue = ""; historyVerdict.isHidden = true
            histCardHealth.stringValue = "—"; histCardCycles.stringValue = "—"; histCardTrend.stringValue = "—"
            return
        }
        historyDegrade.isHidden = false
        // Три крупных числа карточки: Здоровье / Циклы / Тренд (честно «—», пока тренд не измерим)
        histCardHealth.stringValue = String(format: "%.0f%%", h)
        histCardCycles.stringValue = ins.cycles.map(String.init) ?? "—"
        if ins.enough, let spm = ins.slopePerMonth {
            histCardTrend.stringValue = spm < -0.15 ? String(format: "%.1f%%/мес", spm) : L("стабильно")
        } else {
            histCardTrend.stringValue = "—"
        }
        // Вердикт-фраза (главный вывод, headline над графиком). Слово «стабильна» честно ограничено
        // порогом шума −0.15%/мес (обоснован в BatteryHealth) — не заявляем точность выше измеримой.
        historyVerdict.isHidden = false
        if ins.enough, let spm = ins.slopePerMonth {
            if spm < -0.15 {
                historyVerdict.stringValue = String(format: L("АКБ теряет ~%.1f%% в месяц"), abs(spm))
            } else {
                historyVerdict.stringValue = L("АКБ стабильна — деградации не видно")
            }
        } else {
            historyVerdict.stringValue = L("Вывод о деградации появится через ~2 недели наблюдений")
        }
        // Детали под графиком: ресурс циклов (числа Здоровье/Циклы/Тренд уже вынесены крупно — не дублируем)
        if let cy = ins.cycles, let rated = ins.ratedCycles, rated > 0 {
            historyDegrade.stringValue = String(format: L("Ресурс: %d из ~%d циклов (%.0f%%)"), cy, rated, Double(cy) / Double(rated) * 100)
        } else {
            historyDegrade.stringValue = ""
        }
    }

    /// Обновить карточку батареи: мини-график заряда за 24 ч + вердикт/числа (refreshDegrade).
    private func refreshHistory() {
        guard let chart = historyChart else { return }                 // вкладка не построена
        let now = Int64(Date().timeIntervalSince1970)
        History.shared.dashboard(chargeSince: now - 86_400, healthSince: now - 90 * 86_400) { [weak self, weak chart] data in
            guard let self, let chart else { return }
            chart.set(points: data.charge.map { (x: Double($0.ts), y: $0.v) }, color: self.chargeAccent, unit: "%",
                  yCap: 100, yFloor: 0,
                  empty: L("накопление данных — график появится, когда наберётся история"))
        if let earliest = data.earliest {
            let df = DateFormatter(); df.dateFormat = "d MMM HH:mm"; df.locale = Locale(identifier: I18n.current.rawValue)
            let n = data.count
            let pts: String                                            // #5: склонение «точек» по числу и языку
            switch I18n.current {
            case .ru: pts = SettingsStore.plural(n, "точка", "точки", "точек")
            case .uk: pts = SettingsStore.plural(n, "точка", "точки", "точок")
            case .en: pts = n == 1 ? "point" : "points"
            case .pt: pts = n == 1 ? "ponto" : "pontos"
            }
            historyFooter.stringValue = String(format: L("Данные с %@ · %d %@ · снимок раз в минуту, локально"),
                                               df.string(from: Date(timeIntervalSince1970: TimeInterval(earliest))), n, pts)
        } else {
            historyFooter.stringValue = L("История пуста — Kelvin снимает метрики раз в минуту, пока запущен. Загляни позже.")
        }
            self.refreshDegrade(battery: data.battery, series: data.health)
        }
    }
    /// Освежить историю, если открыта её вкладка (переоткрытие поповера на «Истории» — selectTab не сработает на той же вкладке).
    func refreshHistoryIfVisible() {
        if currentTab < tabOrder.count, tabOrder[currentTab] == "history" { refreshHistory() }
    }
    
    /// Обновить Advisor (Центр здоровья Mac) — собрать снимок данных, проанализировать, отрисовать.
    @objc private func refreshAdvisor() {
        guard healthVerdictLabel.superview != nil else { return }  // плитка не построена
        
        // Собираем AdvisorSnapshot из текущих доступных данных
        let battery = BatteryHealth.shared.batteryInfo
        let energy = PowerInfo.shared.latestEnergy
        let sensors = SensorsModel.shared.latestSnapshot
        
        // Батарея
        let batteryPresent = battery?.present ?? false
        let batteryChargePercent = battery?.charge
        let batteryHealthPercent = battery?.health
        let batteryCycles = battery?.cycleCount
        let batteryRatedCycles = AppConfig.shared.maxBatteryCycles ?? 1000
        let batteryTemperature = battery?.temperature
        let batteryCharging = battery?.charging ?? false
        let batteryExternalConnected = energy?.plugged ?? false
        
        // Заряд (из ChargeControl/SettingsStore)
        let chargeLimitEnabled = ChargeControl.limit < 100
        let chargeLimitValue = ChargeControl.limit
        let sailModeActive = ChargeControl.mode == .sail
        let heatProtectionActive = ChargeControl.mode == .heatProtection
        
        // Температуры
        let cpuTempSensor = sensors.temps.first { $0.id == "cpu" }
        let gpuTempSensor = sensors.temps.first { $0.id == "gpu" }
        let cpuTemperature = cpuTempSensor?.value
        let gpuTemperature = gpuTempSensor?.value
        let cpuTemperatureKeys = cpuTempSensor.map { [$0.name] }
        
        // Производительность
        let cpuLoad = SystemUsage.shared.cpuUsagePercent / 100.0
        
        // Память
        let memInfo = MemoryInfo.shared.latestInfo
        let memoryPressure = memInfo?.pressure ?? .unknown
        let memoryTotalRAM = memInfo?.totalRAM ?? 0
        let memorySwapUsed = memInfo?.swapUsed ?? 0
        
        // Диск
        let diskInfo = Maintenance.shared.diskInfo
        let diskFreeBytes = diskInfo?.freeBytes
        let diskTotalBytes = diskInfo?.totalBytes
        
        // Обслуживание
        let uptime = ProcessInfo.processInfo.systemUptime
        let crashSummary = Maintenance.shared.recentCrashSummary
        let recentCrashesCount = crashSummary?.count ?? 0
        
        // Helpers
        let fanHelperInstalled = HelperInstall.fanInstalled
        let chargeHelperInstalled = HelperInstall.powerdInstalled
        
        let snapshot = AdvisorSnapshot(
            batteryPresent: batteryPresent,
            batteryChargePercent: batteryChargePercent,
            batteryHealthPercent: batteryHealthPercent,
            batteryCycles: batteryCycles,
            batteryRatedCycles: batteryRatedCycles,
            batteryTemperature: batteryTemperature,
            batteryCharging: batteryCharging,
            batteryExternalConnected: batteryExternalConnected,
            chargeLimitEnabled: chargeLimitEnabled,
            chargeLimitValue: chargeLimitValue,
            sailModeActive: sailModeActive,
            heatProtectionActive: heatProtectionActive,
            cpuTemperature: cpuTemperature,
            gpuTemperature: gpuTemperature,
            cpuTemperatureKeys: cpuTemperatureKeys,
            cpuLoad: cpuLoad,
            thermalPressure: nil,
            memoryPressure: memoryPressure,
            memoryTotalRAM: memoryTotalRAM,
            memorySwapUsed: memorySwapUsed,
            diskFreeBytes: diskFreeBytes,
            diskTotalBytes: diskTotalBytes,
            uptime: uptime,
            recentCrashesCount: recentCrashesCount,
            crashSummary: crashSummary,
            fanHelperInstalled: fanHelperInstalled,
            chargeHelperInstalled: chargeHelperInstalled
        )
        
        // Анализируем вне main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = AdvisorEngine.shared.analyze(snapshot)
            
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lastAdvisorResult = result
                
                // Обновляем вердикт
                self.healthVerdictLabel.stringValue = result.statusText
                self.healthVerdictLabel.textColor = {
                    switch result.maxSeverity {
                    case .critical: return Design.Color.levelCrit
                    case .warning: return Design.Color.levelWarn
                    case .notice: return Design.Color.levelWarn
                    case .info: return .labelColor
                    }
                }()
                
                // Мета-информация
                let count = result.findings.count
                let timeFormatted = DateFormatter.localizedString(from: result.analyzedAt, dateStyle: .none, timeStyle: .short)
                self.healthMetaLabel.stringValue = count > 0
                    ? String(format: L("%d рекомендаций · %@"), count, timeFormatted)
                    : String(format: L("Анализ: %@ "), timeFormatted)
                
                // Очищаем контейнер
                self.healthFindingsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
                
                // Строим карточки рекомендаций
                for finding in result.findings {
                    let card = self.buildAdvisorCard(finding)
                    self.healthFindingsContainer.addArrangedSubview(card)
                }
            }
        }
    }
    
    /// Построить карточку рекомендации.
    private func buildAdvisorCard(_ finding: AdvisorFinding) -> NSView {
        let card = NSStackView()
        card.orientation = .vertical
        card.spacing = 6
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: IW).isActive = true
        
        // Header: иконка + заголовок + меню скрытия
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: finding.category.icon, accessibilityDescription: finding.category.label)
        iconView.contentTintColor = {
            switch finding.severity {
            case .critical: return Design.Color.levelCrit
            case .warning: return Design.Color.levelWarn
            case .notice: return Design.Color.accent(isDark)
            case .info: return .secondaryLabelColor
            }
        }()
        iconView.imageScaling = .scaleProportionallyUp
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 20).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 20).isActive = true
        
        let titleLabel = NSTextField(labelWithString: finding.title)
        titleLabel.font = Design.Font.sys(13, .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        
        let titleRow = NSStackView(views: [iconView, titleLabel, spacer()])
        titleRow.alignment = .centerY
        titleRow.spacing = 8
        
        // Кнопка скрытия (меню)
        let dismissBtn = GlassButton(title: "", symbol: "ellipsis.circle", cornerRadius: Design.Radius.chip)
        dismissBtn.toolTip = L("Скрыть рекомендацию")
        dismissBtn.onClick = { [weak self] in
            self?.advisorDismissalStore.dismiss(finding.dismissKey)
            self?.refreshAdvisor()
        }
        dismissBtn.translatesAutoresizingMaskIntoConstraints = false
        dismissBtn.widthAnchor.constraint(equalToConstant: 24).isActive = true
        dismissBtn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        
        titleRow.addArrangedSubview(dismissBtn)
        
        // Explanation
        let expLabel = NSTextField(wrappingLabelWithString: finding.explanation)
        expLabel.font = Design.Font.sys(12, .regular)
        expLabel.textColor = .secondaryLabelColor
        expLabel.lineBreakMode = .byWordWrapping
        expLabel.maximumNumberOfLines = 3
        
        // Metric (если есть)
        var metricLabel: NSTextField? = nil
        if let metric = finding.metric {
            metricLabel = NSTextField(labelWithString: metric)
            metricLabel?.font = Design.Font.sys(11, .medium)
            metricLabel?.textColor = .tertiaryLabelColor
        }
        
        // Action button
        var actionBtn: GlassButton? = nil
        if let action = finding.action {
            let btnTitle: String
            switch action {
            case .enableChargeLimit: btnTitle = L("Включить лимит")
            case .enableHeatProtection: btnTitle = L("Защита от нагрева")
            case .activateFanProfile: btnTitle = L("Включить кулеры")
            case .openSettings: btnTitle = L("Открыть настройки")
            case .openPopoverSection: btnTitle = L("Показать")
            case .revealApplication: btnTitle = L("Открыть")
            case .openStorageManagement: btnTitle = L("Управление")
            }
            actionBtn = GlassButton(title: btnTitle, symbol: nil, cornerRadius: Design.Radius.chip)
            actionBtn?.onClick = { [weak self] in
                self?.handleAdvisorAction(action, finding: finding)
            }
        }
        
        // Details button
        let detailsBtn = GlassButton(title: L("Подробнее"), symbol: "chevron.right", cornerRadius: Design.Radius.chip)
        detailsBtn.font = Design.Font.sys(11, .regular)
        if let dest = finding.detailsDestination {
            detailsBtn.onClick = { [weak self] in
                self?.openAdvisorDetails(destination: dest)
            }
        } else {
            detailsBtn.isEnabled = false
            detailsBtn.isHidden = true
        }
        
        // Собираем
        let buttonsRow = NSStackView()
        buttonsRow.orientation = .horizontal
        buttonsRow.spacing = 8
        if let btn = actionBtn { buttonsRow.addArrangedSubview(btn) }
        buttonsRow.addArrangedSubview(detailsBtn)
        buttonsRow.addArrangedSubview(spacer())
        
        card.addArrangedSubview(titleRow)
        card.addArrangedSubview(expLabel)
        if let m = metricLabel { card.addArrangedSubview(m) }
        card.addArrangedSubview(buttonsRow)
        
        // Glass style background
        let glassCard = NSStackView()
        glassCard.orientation = .vertical
        glassCard.spacing = 8
        glassCard.addArrangedSubview(card)
        glassCard.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        glassCard.wantsLayer = true
        glassCard.layer?.backgroundColor = Design.Color.glassBackground(isDark).cgColor
        glassCard.layer?.cornerRadius = Design.Radius.card
        glassCard.layer?.borderWidth = 1
        glassCard.layer?.borderColor = Design.Color.glassBorder(isDark).cgColor
        
        return glassCard
    }
    
    /// Обработать действие рекомендации.
    private func handleAdvisorAction(_ action: AdvisorAction, finding: AdvisorFinding) {
        switch action {
        case .enableChargeLimit(let percent):
            guard Licensing.shared.isPro else {
                _ = SettingsWindowController.shared.requirePro(.chargeControl)
                return
            }
            if !HelperInstall.powerdInstalled {
                HelperInstall.installPowerd()
                return
            }
            ChargeControl.setLimit(percent)
            refreshAdvisor()
            
        case .enableHeatProtection:
            guard Licensing.shared.isPro else {
                _ = SettingsWindowController.shared.requirePro(.chargeControl)
                return
            }
            if !HelperInstall.powerdInstalled {
                HelperInstall.installPowerd()
                return
            }
            ChargeControl.enableHeatProtection()
            refreshAdvisor()
            
        case .activateFanProfile(let profile):
            guard Licensing.shared.isPro else {
                _ = SettingsWindowController.shared.requirePro(.fanControl)
                return
            }
            if !HelperInstall.fanInstalled {
                HelperInstall.installFan()
                return
            }
            FanController.activateProfile(profile)
            refreshAdvisor()
            
        case .openSettings(let section):
            SettingsWindowController.shared.showSection(section)
            
        case .openPopoverSection(let section):
            if let idx = tabOrder.firstIndex(of: section) {
                selectTab(idx)
            }
            
        case .revealApplication(let appName):
            let workspace = NSWorkspace.shared
            if let appURL = workspace.urlForApplication(withBundleIdentifier: appName) {
                workspace.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            } else if let appURL = workspace.urlForApplication(toOpen: URL(fileURLWithPath: "/Applications/\(appName).app")) {
                workspace.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            }
            
        case .openStorageManagement:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.storage")!)
        }
    }
    
    /// Открыть подробности рекомендации.
    private func openAdvisorDetails(destination: String) {
        if let idx = tabOrder.firstIndex(of: destination) {
            selectTab(idx)
        } else {
            SettingsWindowController.shared.showSection(destination)
        }
    }
    
    /// Открыть/подсветить вкладку «Приватность» (из баннера first-conn). Поповер уже показан вызывающим.
    func focusPrivacyTab() {
        guard let idx = tabOrder.firstIndex(of: "privacy") else { return }
        if idx != currentTab { selectTab(idx) }
        tabBar?.select(idx, animated: false)
    }
    private func buildHardwareTile() -> NSView {
        // ватты CPU/GPU/DRAM приходят из хелпера; температуры/вентиляторы/нагрузка — без него.
        comp = [:]
        hardwareStatus.font = Design.Font.caption
        hardwareStatus.textColor = .secondaryLabelColor
        hardwareStatus.alignment = .right
        hardwareStatus.lineBreakMode = .byTruncatingTail
        hardwareStatus.translatesAutoresizingMaskIntoConstraints = false
        let title = Self.sectionLabel(L("Обзор"))
        let titleRow = NSStackView(views: [title, spacer(), hardwareStatus])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.widthAnchor.constraint(equalToConstant: IW).isActive = true
        let sensorsTitle = Self.sectionLabel(L("Датчики"))
        let hw: [NSView] = [titleRow, gpuStatusView(), sensorsTitle, sensorsView,
                            compStatus, installBtn]
        return glassTile(vstack(hw, 8), fill: true)
    }

    /// Короткое имя GPU без вендорного префикса (для компактной строки «спит»).
    private func shortGPU(_ name: String) -> String {
        var s = name
        for p in ["NVIDIA GeForce ", "AMD Radeon ", "Intel ", "Apple "] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        return s
    }

    private let gpuLine = NSTextField(labelWithString: "")   // живой индикатор активной GPU (перекрашивается в тике)
    private var gpuModeBar: PillTabBar?                       // переключатель политики графики (только dual-GPU с mux)
    private var gpuModeBusy = false                           // защита от повторного клика, пока висит admin-промпт

    /// Строка-glance «какая видеокарта работает» + (на dual-GPU с mux) переключатель политики.
    /// V5: НАШ стеклянный PillTabBar вместо чужеродного NSSegmentedControl (владелец: «не очень красиво»).
    /// На M-серии/одной карте — просто имя единственного GPU.
    private func gpuStatusView() -> NSView {
        gpuLine.lineBreakMode = .byTruncatingTail
        gpuLine.translatesAutoresizingMaskIntoConstraints = false
        gpuLine.widthAnchor.constraint(equalToConstant: IW).isActive = true
        paintGPU()
        guard GPUInfo.switchable else { return gpuLine }
        let bar = PillTabBar(labels: [L("Встроенная"), L("Дискретная"), L("Авто")], selected: 2)
        bar.pillColor = Design.Color.accent(isDark)
        bar.onSelect = { [weak self] idx in self?.gpuModeChanged(idx) }
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: IW).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 26).isActive = true
        // Честная граница: переключатель — ПОЛИТИКА pmset; фактическую карту показывает живая строка выше
        // (дискретная может не заснуть, пока её держит приложение).
        bar.toolTip = L("Политика переключения (pmset). Какая карта реально работает — показывает строка выше.")
        gpuModeBar = bar
        // pmset -g — подпроцесс: начальное значение тянем асинхронно, без блокировки построения поповера
        DispatchQueue.global(qos: .utility).async {
            let m = GPUInfo.mode()
            DispatchQueue.main.async { [weak self] in self?.selectGPUSegment(m) }
        }
        return vstack([gpuLine, bar], 6)
    }
    private func selectGPUSegment(_ m: GPUMode?) {
        guard let bar = gpuModeBar else { return }
        let idx: Int
        switch m {
        case .integratedOnly: idx = 0
        case .discreteOnly:   idx = 1
        case .automatic, nil: idx = 2
        }
        if bar.selectedIndex != idx { bar.select(idx, animated: false) }
    }
    private func gpuModeChanged(_ idx: Int) {
        guard !gpuModeBusy else { return }                   // повторный клик, пока висит admin-промпт — игнор
        let target: GPUMode = idx == 0 ? .integratedOnly : (idx == 1 ? .discreteOnly : .automatic)
        if GPUInfo.mode() == target {
            selectGPUSegment(target)
            return
        }
        gpuModeBusy = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = GPUInfo.setMode(target)                // osascript + admin-промпт, блокирует ЭТОТ поток, не main
            let confirmed = GPUInfo.mode()                  // истинное состояние после (Cancel → прежнее)
            DispatchQueue.main.async {
                self?.gpuModeBusy = false
                self?.selectGPUSegment(confirmed)           // и при успехе, и при отказе — бар = правда pmset
                if ok { self?.paintGPU() }
            }
        }
    }
    /// Перекрасить строку GPU по ТЕКУЩЕЙ активной карте (живая смена дискретная↔встроенная).
    private func paintGPU() {
        let gpus = GPUInfo.all()
        let active = GPUInfo.active()
        let f11 = Design.Font.caption
        if let a = active {
            let s = NSMutableAttributedString()
            s.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: NSColor.systemGreen, .font: f11]))
            s.append(NSAttributedString(string: a.name, attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 11, weight: .semibold)]))
            if let other = gpus.first(where: { $0.registryID != a.registryID }) {
                s.append(NSAttributedString(string: "   ·  " + String(format: L("%@ спит"), shortGPU(other.name)), attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: f11]))
            }
            gpuLine.attributedStringValue = s
        } else {
            gpuLine.font = f11
            gpuLine.stringValue = gpus.first?.name ?? "—"
        }
    }
    private func buildAppsTile() -> NSView {
        // appsStack заворачиваем в host: флип (вращение/фейд) крутим на host, НЕ на appsStack и
        // НЕ на плитке (тень glassTile не трогаем). sectionLabel — статичный корешок секции.
        let host = NSView()
        host.wantsLayer = true
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(appsStack)
        appsStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            appsStack.topAnchor.constraint(equalTo: host.topAnchor),
            appsStack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            appsStack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            appsStack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        appsFlipHost = host
        // Компактная системная сводка завершает рейтинг и не конкурирует с ним отдельным графиком.
        let statsRow = NSStackView(views: [miniStat(appsFootProcs, NSTextField(labelWithString: L("Процессов"))),
                                           miniStat(appsFootCPU, NSTextField(labelWithString: L("CPU всего"))),
                                           miniStat(appsFootMem, NSTextField(labelWithString: L("Память")))])
        statsRow.distribution = .fillEqually; statsRow.spacing = 8
        statsRow.translatesAutoresizingMaskIntoConstraints = false
        statsRow.widthAnchor.constraint(equalToConstant: IW).isActive = true
        appsUpdatedLabel.font = Design.Font.sys(10, .regular)
        appsUpdatedLabel.textColor = .tertiaryLabelColor
        let seam = RimLightView()
        seam.translatesAutoresizingMaskIntoConstraints = false
        seam.widthAnchor.constraint(equalToConstant: IW).isActive = true
        seam.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return glassTile(vstack([host, seam, statsRow, appsUpdatedLabel], 7))
    }

    // MARK: плитка быстрых переключателей (Control Center) — встроенные + свои кнопки, по раскладке
    private func buildTogglesTile() -> NSView {
        var buttons: [CCToggle] = []
        for item in SettingsStore.toggleLayout where item.on {
            if item.id.hasPrefix("custom:") {
                let cid = String(item.id.dropFirst("custom:".count))
                if let c = SettingsStore.customToggles.first(where: { $0.id == cid }) { buttons.append(makeCustomButton(c)) }
            } else if let def = QuickToggleRegistry.def(item.id), def.available() {
                buttons.append(makeBuiltinToggle(def))
            }
        }
        var rows: [NSView] = [Self.sectionLabel(L("Переключатели"))]
        if buttons.isEmpty {
            let l = NSTextField(labelWithString: L("включи в Настройки → Переключатели"))
            l.font = Design.Font.caption; l.textColor = .tertiaryLabelColor
            rows.append(l)
        }
        // ЖЁСТКАЯ сетка 2×N: ячейка ровно (IW−8)/2. `.fillEqually` НЕ гарантирует равенство
        // (equal-size стека не required и проигрывает текстовой геометрии CCToggle — «Wi-Fi» + длинная
        // подпись давали 57/207pt, «как влазит текст»). Required-ширина каждой ячейки решает.
        let cellW = (IW - 8) / 2
        var i = 0
        while i < buttons.count {
            let second: NSView
            if i + 1 < buttons.count {
                second = buttons[i + 1]
            } else {
                // нечётный последний: держим половину сетки, правая ячейка пустая — грид читается ровно
                second = NSView()
                second.translatesAutoresizingMaskIntoConstraints = false
            }
            buttons[i].widthAnchor.constraint(equalToConstant: cellW).isActive = true
            second.widthAnchor.constraint(equalToConstant: cellW).isActive = true
            let row = NSStackView(views: [buttons[i], second])
            row.distribution = .fill; row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: IW).isActive = true
            rows.append(row)
            i += 2
        }
        return glassTile(vstack(rows, 8))
    }
    private func makeBuiltinToggle(_ def: QuickToggleDef) -> CCToggle {
        let t = CCToggle(id: def.id, icon: def.icon, title: def.label, accent: def.accent)
        t.toolTip = def.label                           // фикс-ячейка сетки режет длинные подписи «…» — полное имя в тултипе
        t.isBuiltin = true
        t.stateProvider = def.isOn
        t.isOn = def.isOn()
        t.onClick = { [weak self] in
            def.toggle()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.refreshToggles() }
        }
        ccToggles.append(t)
        return t
    }
    private func makeCustomButton(_ c: CustomToggle) -> CCToggle {
        let t = CCToggle(id: "custom:\(c.id)", icon: c.icon.isEmpty ? "bolt.fill" : c.icon, title: c.label, accent: c.accent)
        t.isOn = false                                  // мгновенное действие, не состояние
        // Pro-гейт на КЛИК, а не только на создание: после даунгрейда в Free кнопка не должна исполнять bash.
        t.onClick = {
            guard Licensing.shared.isPro else { _ = SettingsWindowController.shared.requirePro(.customToggles); return }
            CustomCommand.run(c.command)
        }
        return t
    }
    func refreshToggles() { ccToggles.forEach { $0.refresh() } }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        return v
    }
    /// Мини-показатель: крупное моноширинное значение + капс-подпись под ним.
    private func miniStat(_ val: NSTextField, _ cap: NSTextField) -> NSStackView {
        val.font = Design.Font.numericLarge
        val.alignment = .left
        cap.font = Design.Font.sys(11, .regular)       // как витальные подписи: единый регистр/кегль (убит 9pt-CAPS «двух эпох»)
        cap.textColor = .tertiaryLabelColor
        cap.lineBreakMode = .byTruncatingTail
        let s = vstack([val, cap], 2)
        s.alignment = .leading
        return s
    }
    /// Мини-показатель батареи: значение кладём в metric[key], чтобы update() обновлял его как раньше.
    private func battStat(_ key: String, _ caption: String) -> NSStackView {
        let val = NSTextField(labelWithString: "—")
        metric[key] = val
        return miniStat(val, NSTextField(labelWithString: caption))
    }
    private func validMin(_ m: Int) -> Int? { (m > 0 && m < 1200) ? m : nil }
    private func fmtHM(_ mins: Int) -> String {
        mins >= 60 ? String(format: "%d:%02d", mins/60, mins%60) : String(format: L("%d мин"), mins)
    }
    /// Вертикальный стек контента карточки.
    private func vstack(_ views: [NSView], _ spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }
    /// Стеклянная плитка (Control Center / Liquid Glass): непрерывные скругления,
    /// frosted-fill поверх размытого фона поповера, мягкая тень-глубина вместо рамки.
    private func glassTile(_ inner: NSView, radius: CGFloat = Design.Radius.tile, hInset: CGFloat = 16, fill: Bool = false) -> NSView {
        let tile = NSView()
        tile.wantsLayer = true
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.layer?.cornerRadius = radius
        tile.layer?.cornerCurve = .continuous
        tile.layer?.borderWidth = 0.75                 // мягкая световая кромка (glass rim), не хайрлайн
        Design.Elevation.tile(tile.layer!, dark: isDark)   // e1: тень-глубина из токена
        tile.addSubview(inner)
        inner.translatesAutoresizingMaskIntoConstraints = false
        // fill: контент прижат к ВЕРХУ (bottom — «не ниже»), чтобы карточку можно было
        // растянуть на всю высоту вкладки без расползания строк (для таб-плиток).
        let bottom = fill
            ? inner.bottomAnchor.constraint(lessThanOrEqualTo: tile.bottomAnchor, constant: -14)
            : inner.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -14)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: tile.topAnchor, constant: 14),
            bottom,
            inner.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: hInset),
            inner.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -hInset),
        ])
        cards.append(tile)
        return tile
    }
    /// V3 «единая стеклянная поверхность» (грамматика Control Center): плитки ПОЛНОСТЬЮ прозрачны —
    /// ни заливки, ни кромки, ни тени. Весь поповер = ОДНА стеклянная панель (GlassContainer .popover),
    /// секции разделяются только волосяными делителями (sectionDivider) + отступом. Это убивает «полоски
    /// по бокам»: раньше светлая заливка плитки (CW) на фоне тёмной базы ауры в 14pt-гаттере читалась как
    /// боковые тёмные полосы; теперь центр и гаттер — одно равномерное стекло, шва нет.
    private func paintCards() {
        for c in cards {
            c.layer?.backgroundColor = NSColor.clear.cgColor
            c.layer?.borderWidth = 0
            c.layer?.shadowOpacity = 0
        }
    }
    func applyTheme() {
        paintCards()
        tabBar?.applyTheme()
        graph.needsDisplay = true
        ring.needsLayout = true
        auraView.applyBase(dark: isDark, opacity: CGFloat(SettingsStore.popoverOpacity))
        // Цветовые токены различаются между темами — следующий update синхронно
        // пересчитает и кольцо, и ауру, не сохраняя старотемный CGColor.
        lastAuraColor = nil
    }

    /// Один цветовой источник для кольца и фонового свечения. Сравнение в sRGB
    /// предотвращает повторный запуск длинного cross-fade на каждом секундном тике.
    private func syncAura(to color: NSColor, animated: Bool) {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        if let previous = lastAuraColor?.usingColorSpace(.sRGB),
           previous.isEqual(resolved) {
            return
        }
        lastAuraColor = resolved
        auraView.setColor(resolved, animated: animated, intensity: 0.72, duration: 0.72)
    }
    /// Консоль-включение (power-up): СЕКВЕНЦИЯ вместо одновременного всплытия —
    /// (1) шов прорисовывается сверху вниз, (2) ряды-плитки оседают со стаггером 0.045
    /// (перекрывая хвост шва, чтобы было снапово), (3) кольцо свипует дугой.
    func playOpenAnimation() {
        // СБРОС заморозки каскада закрытия: playCloseAnimation оставляет "close" на корневом
        // view.layer (fillMode .forwards + isRemovedOnCompletion false) — без снятия на открытии
        // корневой слой остаётся на opacity 0 и ВЕСЬ контент поповера невидим на повторном показе.
        view.layer?.removeAnimation(forKey: "close")
        view.layer?.opacity = 1
        // свип геройных гейджей «Железа», если поповер открылся на этой вкладке
        if currentTab < tabOrder.count, tabOrder[currentTab] == "hardware" {
            DispatchQueue.main.async { [weak self] in self?.sensorsView.animateIn() }
        }
        // оживление радара, если поповер открылся на вкладке «Приватность»
        if currentTab < tabOrder.count, tabOrder[currentTab] == "privacy" {
            DispatchQueue.main.async { [weak self] in self?.privacyView.animateIn(); self?.vpnChipRefresh?(); self?.mediaChipRefresh?() }
        }
        guard !Motion.reduced else { ring.animateIn(); return }   // «Уменьшить движение» — без всплытия/прорисовки
        // плитки оседают со стаггером сразу с открытия. Прежний spineLead (0.11с прорисовки шва) УБРАН
        // вместе со StatusSpine — иначе fillMode .backwards держал бы контент на opacity 0 эти 110мс («моргок»).
        // Только РАЗМЕЩЁННЫЕ в иерархии карточки: замер вкладок кладёт в cards все до 6 таб-плиток,
        // но показана одна — 5 отсоединённых «съедали» слоты стаггера и раздували задержку видимой вкладки.
        let live = cards.filter { $0.superview != nil }
        for (i, c) in live.enumerated() {
            guard let lyr = c.layer else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = -14; move.toValue = 0          // y вверх → старт чуть ниже, всплывает
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.985; scale.toValue = 1.0    // материя «надувается» на месте
            let g = CAAnimationGroup()
            g.animations = [fade, move, scale]
            g.duration = Design.Motion.durSlow
            g.beginTime = CACurrentMediaTime() + Double(i) * Design.Motion.stagger
            g.timingFunction = Design.Motion.easeStandard   // фирменная decelerate-кривая
            g.fillMode = .backwards
            lyr.add(g, forKey: "in")
        }
        ring.animateIn()                                          // 3) кольцо свипует (длинный свип сам читается последним)
    }
    /// Каскад ЗАКРЫТИЯ: цельный fade корневого слоя контента + лёгкое оседание вниз —
    /// зеркало открытия (которое всплывает с −y). Держим ≤ durBase, чтобы системный teardown
    /// .transient-окна не обрезал. Анимируем view.layer (живёт пока жив controller) → безопасно.
    /// `done` гарантированно зовётся ровно один раз, иначе performClose потеряется.
    func playCloseAnimation(_ done: @escaping () -> Void) {
        guard !Motion.reduced, let lyr = view.layer else { done(); return }
        var fired = false
        let fire = { if !fired { fired = true; done() } }
        CATransaction.begin()
        CATransaction.setCompletionBlock(fire)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = 0; move.toValue = -3              // экранный y вниз → оседание (зеркало всплытию)
        let g = CAAnimationGroup()
        g.animations = [fade, move]
        g.duration = Design.Motion.durClose
        g.timingFunction = Design.Motion.easeOut
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        lyr.add(g, forKey: "close")
        CATransaction.commit()
    }
    /// E1-проброс: flowView приватный — даём AppDelegate честные точки входа.
    func pulseUSB(connect: Bool) { flowView.pulseObod(connect: connect) }
    func setUSBCount(_ n: Int, name: String?) { flowView.setUSBCount(n, name: name) }
    /// Волосяной шов-разделитель: тонкая (1px) hairline-линия в ширину контента (IW),
    /// перекрашивается под тему. Заменяет тяжёлый NSBox.separator — это бренд-шов «безеля», а не системная рамка.
    private func divider() -> NSView {
        let v = HairlineView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: IW).isActive = true
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }
    private func metricRow(_ key: String) -> NSStackView {
        let name = NSTextField(labelWithString: key)
        name.font = Design.Font.caption
        name.textColor = .secondaryLabelColor
        let value = NSTextField(labelWithString: "—")
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        value.alignment = .right
        metric[key] = value
        let row = NSStackView(views: [name, spacer(), value])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: IW).isActive = true
        return row
    }

    // MARK: обновление данных
    func update(battery b: BatteryInfo, history: [Double], components c: ComponentPower,
                energy e: EnergySnapshot, sensors: SensorsSnapshot) {
        flowView.update(e, components: c, hasBattery: b.present)
        var feed = FlowInfoBar.Feed()
        feed.hasBattery = b.present
        feed.cycleCount = b.cycleCount
        feed.health = b.health
        feed.capacityWh = b.capacityWh
        feed.onBattery = b.present && !e.plugged
        feed.topApp = appsLast.first?.name
        flowInfoBar.update(feed)
        // (V6: термосводка удалена — строка под схемой несёт только живой разбор под курсором)
        applyThermalLabel()
        // «ядро NN°» ретайрнут из шапки (V3) — дублировал ТЕМП в витальных; тинт-температуру несёт витальная ячейка ниже.
        // «Спокойный прибор»: пилюля рельса — константная бирюза (ставится в buildModules), состоянием не красится
        refreshToggles()               // переключатели — не-батарейное, обновляем всегда (и на десктопе)
        refreshDisk()                  // диск — тоже не-батарейное; no-op, если плитка не построена
        refreshBT()                    // Bluetooth — не-батарейное; no-op, если плитка не построена
        refreshAudio()                 // аудио-вывод — не-батарейное; no-op, если плитка не построена

        // Сенсоры раз в тик — ЕДИНЫЙ источник и для витальных ячеек, и для вкладки «Железо»
        // (раньше снимок брался ниже, а «Темп» кормилась из e.cpuTemp=TC0P — иного датчика, чем герой).
        // Витальные Ватт/Темп/Кулер + спарклайн НЕ зависят от наличия АКБ — обновляем всегда
        // (десктоп без батареи иначе оставался бы с пустой полосой и мёртвым графом навсегда;
        //  и разовый провал чтения батареи не должен замораживать расход/термику).
        statSysVal.stringValue = e.systemWatts > 0.1 ? String(format: "%.0f", e.systemWatts) : "—"  // нет замера → «—», не фейковый «0»
        statSysVal.textColor = .labelColor
        let cpuTempSensor = sensors.temps.first { $0.id == "cpu" }        // тот же PECI-датчик, что и герой «Железа»
        statTempVal.stringValue = cpuTempSensor.map { String(format: "%.0f°", $0.value) } ?? "—"
        let cpuTempLvl = cpuTempSensor.map { Design.sensorLevel(id: "cpu", $0.value) } ?? .ok
        // «Спокойный прибор»: норма НЕЙТРАЛЬНА (не вечно-бирюзовая) — цвет только на реальном тепле
        statTempVal.textColor = (cpuTempLvl == .ok) ? .labelColor : Design.Color.stateColor(cpuTempLvl, isDark)
        statFanVal.stringValue = (e.fans.first.map { $0 > 0 } ?? false) ? String(format: "%.0f", e.fans.first!) : "—"
        statFanVal.textColor = .labelColor
        graph.accentColor = chargeAccent        // спарклайн всегда бренд-бирюза (состояние несёт кольцо)
        graph.setHistory(history)

        // «АКБ» — знак берём из СТАБИЛЬНОГО battFlow (гистерезис), а не из сырого b.charging: иначе
        // на удержании лимита/кратком спайке B0AP выдавал фантомный «−N», противореча схеме Питания.
        switch b.present ? e.battFlow : .idle {
        case .charging:    statBatVal.stringValue = String(format: "+%.0f", e.battWatts); statBatVal.textColor = chargeAccent
        case .discharging: statBatVal.stringValue = "\u{2212}" + String(format: "%.0f", e.battWatts); statBatVal.textColor = .labelColor
        case .idle:        statBatVal.stringValue = b.present ? "0" : "—"; statBatVal.textColor = .labelColor
        }

        if b.present {
            // «Спокойный прибор»: кольцо несёт ТОЛЬКО состояние ЗАРЯДА — тепло живёт в ячейке «Темп» и в
            // ауре (та краснеет при реальном crit). Тепловой crit из тинта кольца УБРАН: иначе 90% заряда +
            // горячий CPU красили кольцо красным, читаясь как «критический заряд». Заряжается → бирюза;
            // иначе семантика заряда (≤15 красный / ≤35 амбер / иначе зелёный).
            let ringColor: NSColor = b.charging ? Design.Color.accentBright(isDark)
                : (b.charge <= 15 ? Design.Color.levelCrit
                   : (b.charge <= 35 ? Design.Color.levelWarn : Design.Color.levelOK))
            ring.set(charge: b.charge, charging: b.charging, flow: e.battFlow, plugged: e.plugged, accent: ringColor)
            syncAura(to: ringColor, animated: true)
            applyChargeLimit()                         // тик на кольце + дорожка заряда (Pro charge limit)
            // дорожка заряда (строка 2): реальное состояние потолка/режима/парусов + Pro-флаг
            chargeTrack.set(charge: b.charge, charging: b.charging, flow: e.battFlow,
                            limit: ChargeControl.limit, mode: ChargeControl.mode,
                            sailUpper: ChargeControl.sailUpper, sailLower: ChargeControl.sailLower,
                            topUpActive: ChargeControl.isTopUpActive, pro: Licensing.shared.isPro)

            // Статус ЧЕЛОВЕЧЕСКИМ языком, коротко (прежнее «адаптер 47 Вт» обрезалось до «адаптер 47 В»):
            // «Зарядка · до полного 1:20» / «От сети · держим 80%» / «От батареи · осталось 4:10».
            if b.charging {
                statusTitle.stringValue = L("Зарядка")
                statusTitle.textColor = chargeAccent
                // «ещё» (не «до полного»): правая колонка шапки узкая (ring 80 + широкий вердикт),
                // длинный префикс обрезал бы САМО значение по хвосту («до полного 30 мин»→«до полного 3»).
                // Точный ярлык «ДО ПОЛНОГО» — в стат-строке ниже; здесь коротко, значение всегда видно.
                statusSub.stringValue = validMin(b.timeToFull).map { String(format: L("ещё %@"), fmtHM($0)) }
                    ?? String(format: L("%.0f Вт"), e.adapterWatts)
            } else if b.external {
                statusTitle.stringValue = L("От сети")
                statusTitle.textColor = .secondaryLabelColor
                statusSub.stringValue = (ChargeControl.limit < 100 && b.charge >= ChargeControl.limit - 2)
                    ? String(format: L("держим %d%%"), ChargeControl.limit)
                    : String(format: L("%d%%"), b.charge)
            } else {
                statusTitle.stringValue = L("От батареи")
                statusTitle.textColor = .systemGreen
                statusSub.stringValue = validMin(b.timeToEmpty).map { String(format: L("ещё %@"), fmtHM($0)) }
                    ?? String(format: L("АКБ %.0f°"), b.temperature)
            }
            // (Ватт/Темп/Кулер/АКБ + спарклайн уже обновлены ВЫШЕ — не зависят от батарейной ветки.)

            metric["Здоровье"]?.stringValue = String(format: "%.0f%%", b.health)
            // Здоровье = один канонический дом (из футера Flow здоровье убрано в L4). >100% делаем
            // САМООЧЕВИДНЫМ реальной парой мА·ч (coconutBattery-стиль): текущая полная ёмкость vs заводская —
            // тогда «104%» читается как факт «АКБ чуть выше заводской», а не как баг. Честность закон #1.
            metric["Здоровье"]?.toolTip = (b.designCapacity > 0 && b.maxCapacity > 0)
                ? String(format: L("Полная ёмкость сейчас %d мА·ч из заводских %d мА·ч (%.0f%%). Выше 100%% — норма для новых или откалиброванных АКБ; ниже — естественный износ."),
                         b.maxCapacity, b.designCapacity, b.health)
                : nil
            metric["Циклы"]?.stringValue = "\(b.cycleCount)"
            metric["battAge"]?.stringValue = batteryAgeLine(b)
            if let why = batteryWhyNotCharging(b) {
                metric["battWhy"]?.stringValue = why; metric["battWhy"]?.isHidden = false
            } else { metric["battWhy"]?.isHidden = true }
            metric["Температура"]?.stringValue = String(format: L("%.1f °C"), b.temperature)
            metric["Напряжение"]?.stringValue = String(format: L("%.2f В"), b.voltage)
            let mins = b.timeToEmpty
            metric["Осталось"]?.stringValue = (!b.charging && mins > 0 && mins < 1200) ? String(format: "%d:%02d", mins/60, mins%60) : "—"
            metric["Ёмкость"]?.stringValue = String(format: L("%.0f / %.0f Вт·ч"), b.capacityWh, b.maxWh)
            cellsLabel.stringValue = b.cells.isEmpty ? "—" : String(format: L("Ячейки: %@ В"), b.cells.map { String(format: "%.3f", $0) }.joined(separator: " · "))
        } else {
            ring.setLimit(nil)                          // нет АКБ — ни тика лимита (плитка-шапка скрыта целиком)
            syncAura(to: Design.Color.stateColor(lastVerdictLevel, isDark), animated: true)
        }

        // сенсоры уже сняты выше (единый снимок за тик) — просто отдаём во вкладку «Железо»
        sensorsView.update(sensors)
        let hardwareSignal = worstTempSignal(sensors.temps)
        switch hardwareSignal.level {
        case .ok:
            if let hottest = hardwareSignal.sensor {
                hardwareStatus.stringValue = String(format: L("Макс. %@"), hottest.text)
                hardwareStatus.toolTip = String(
                    format: L("Самый горячий датчик: %@ · %@"),
                    hottest.name,
                    hottest.text
                )
                hardwareStatus.textColor = .secondaryLabelColor
            } else {
                hardwareStatus.stringValue = L("Нет данных температур")
                hardwareStatus.toolTip = nil
                hardwareStatus.textColor = .tertiaryLabelColor
            }
        case .warn:
            hardwareStatus.stringValue = hardwareSignal.sensor.map {
                String(format: L("Высокая: %@"), $0.text)
            } ?? L("Высокая температура")
            hardwareStatus.toolTip = hardwareSignal.sensor.map {
                String(format: L("Высокая температура: %@ · %@"), $0.name, $0.text)
            }
            hardwareStatus.textColor = Design.Color.levelWarn
        case .crit:
            hardwareStatus.stringValue = hardwareSignal.sensor.map {
                String(format: L("Перегрев: %@"), $0.text)
            } ?? L("Перегрев")
            hardwareStatus.toolTip = hardwareSignal.sensor.map {
                String(format: L("Перегрев: %@ · %@"), $0.name, $0.text)
            }
            hardwareStatus.textColor = Design.Color.levelCrit
        }
        // живая смена GPU (дискретная↔встроенная) — перекрашиваем строку, пока видна вкладка «Железо»
        if currentTab < tabOrder.count, tabOrder[currentTab] == "hardware" { paintGPU() }
        refreshAppsUpdatedLabel()      // «обновлено N с назад» в футере Приложений тикает каждую секунду
        // каталог-лента: read() ТОЛЬКО видимых строк (перф) + диагностика движка из уже собранных полей
        let visible = sensorsView.visibleIDs()
        let catRows = SensorCatalog.snapshot(visibleIDs: visible, record: true)
        sensorsView.updateCatalog(rows: catRows, components: c, energy: e)
        refreshHealthVerdict(battery: b, energy: e, sensors: sensors)   // одна слим-строка «всё ли в норме» в шапке
        refreshTabDots(battery: b, energy: e, sensors: sensors)         // тихие warn/crit-точки на вкладках
        // хелпер нужен только для ватт CPU/GPU/DRAM — статус с проверкой, что демон реально отдаёт данные
        let on = c.fresh
        compStatus.isHidden = on
        installBtn.isHidden = on
        if !on {
            if HelperInstall.powerdInstalled {
                compStatus.stringValue = L("Хелпер установлен, но данных нет (демон молчит) — переустанови.")
                installBtn.title = L("Переустановить хелпер…")
            } else {
                compStatus.stringValue = L("Раздел «Питание» (ватты CPU/GPU/DRAM) — нужен системный хелпер.")
                installBtn.title = L("Установить хелпер…")
            }
        }
    }

    /// Вердикт здоровья в шапке: цветная точка + слово ХУДШЕГО активного сигнала.
    /// Зеркалит язык вердикт-карты фаервола, но компактно (одна слим-строка, не меняет высоту).
    /// Сигналы (как в задании): перегрев температур (Design.tempLevel), высокий расход системы (>28 Вт),
    /// критический заряд (≤15%), форс-кулер (SensorsModel forced). Берём worst-of, с крошечной спецификой.
    /// Худший ТЕПЛОВОЙ сигнал по ЧЕСТНЫМ per-sensor порогам (не единый 70/85 → иначе Intel CPU = вечный крит).
    /// Возврат: уровень + датчик-источник (для подписи). Среди датчиков одного уровня берём самый горячий.
    private func worstTempSignal(_ temps: [Sensor]) -> (level: Design.Level, sensor: Sensor?) {
        var best: (Design.Level, Sensor)?
        for s in temps {
            let l = Design.sensorLevel(id: s.id, s.value)
            if best == nil || Design.rank(l) > Design.rank(best!.0)
                || (Design.rank(l) == Design.rank(best!.0) && s.value > best!.1.value) {
                best = (l, s)
            }
        }
        return (best?.0 ?? .ok, best?.1)
    }

    private func refreshHealthVerdict(battery b: BatteryInfo, energy e: EnergySnapshot, sensors: SensorsSnapshot) {
        // Худший тепловой сигнал по ЧЕСТНЫМ порогам датчика (CPU крит ≥100°, батарея ≥45° и т.д.).
        let (instTempLvl, hottest) = worstTempSignal(sensors.temps)
        // Устойчивость: крит-температуру показываем «Перегрев» только если держится ≥3 тика (~4–5с),
        // иначе мгновенный турбо-скачок кристалла флипал бы капсулу. До того — максимум «Греется».
        if instTempLvl == .crit { tempCritStreak += 1 } else { tempCritStreak = 0 }
        let tempLvl: Design.Level = (instTempLvl == .crit && tempCritStreak < 3) ? .warn : instTempLvl
        let critCharge = b.present && !b.charging && b.charge <= 15      // как кольцо/алерты: критический заряд
        // «Спокойный прибор» (совет по дизайну): ни высокий расход (40–70 Вт норма на ноуте), ни forced-кулеры
        // (у владельца с fan-кривой это ПОСТОЯННО) — НЕ фолт. Вердикт-warn остаётся ТОЛЬКО за реальной жарой
        // (Греется/Перегрев) → кольцо амбер редко и честно; ватты/обороты видны информативно в витальных.

        // worst-of: сначала crit, затем warn, иначе ok. КАПСУЛА = короткое слово (никогда не «…»),
        // ТУЛТИП (detail) = полная фраза с цифрой/сенсором — наведение раскрывает деталь (фикс «скрыто, наводишь — пусто»).
        // anchor — модуль-источник сигнала: спайн подсветит сегмент у него (жара/нагрузка → вкладки, заряд → шапка).
        let level: Design.Level
        let word: String                 // короткое слово в капсулу (≤ ширины пилюли, без усечения)
        let detail: String               // полная фраза в тултип капсулы
        let anchor: NSView?
        if tempLvl == .crit {
            level = .crit
            word = L("Перегрев")
            detail = hottest.map { String(format: L("Перегрев — %@ %@"), $0.name, $0.text) } ?? L("Перегрев")
            anchor = tabAreaView
        } else if critCharge {
            level = .crit
            word = L("Заряд")
            detail = String(format: L("Критический заряд — %d%%"), b.charge)
            anchor = headerTile
        } else if tempLvl == .warn {
            level = .warn
            word = L("Греется")
            detail = hottest.map { String(format: L("Греется — %@ %@"), $0.name, $0.text) } ?? L("Греется")
            anchor = tabAreaView
        } else {
            level = .ok
            word = L("Всё в норме")
            detail = L("Всё в норме")
            anchor = nil
        }
        lastVerdictLevel = level            // герой-шапка: тинт кольца берёт этот уровень на следующем тике
        let color: NSColor
        switch level {
        case .ok:   color = Design.Color.levelOK
        case .warn: color = Design.Color.levelWarn
        case .crit: color = Design.Color.levelCrit
        }
        healthDot.textColor = isDark ? color : (color.blended(withFraction: 0.18, of: .black) ?? color)
        if healthLabel.stringValue != word { healthLabel.stringValue = word }
        let tip = (level == .ok) ? nil : detail                // наведение раскрывает полную деталь (цифра/сенсор)
        // GUARD: не трогать toolTip если строка не изменилась — иначе каждый тик сбрасывает
        // ~1.5с таймер всплытия AppKit и подсказка «не успевает» показаться (первопричина бага).
        if lastVerdictTip != tip {
            verdictPill.toolTip = tip; healthLabel.toolTip = tip; healthDot.toolTip = tip
            lastVerdictTip = tip
        }
        // Кликабельная капсула (главный фикс): тап раскрывает деталь поповером, не завися от
        // капризного AppKit-таймера. .ok → инертна (нет pointingHand).
        verdictDetail = detail
        verdictLevelOK = (level == .ok)
        verdictPill.onClick = (level == .ok) ? nil : { [weak self] in self?.showVerdictDetail() }
        verdictPill.window?.invalidateCursorRects(for: verdictPill)
        let ax = "● " + detail                                // VoiceOver/AX читает полную фразу, не усечённое слово
        healthDot.setAccessibilityLabel(ax); healthLabel.setAccessibilityLabel(ax)

        _ = anchor        // V3: StatusSpine ретайрнут — anchor больше не подсвечивает сегмент шва
    }

    /// Клик по капсуле вердикта → стеклянный поповер с полной фразой (цифра/сенсор). Надёжнее
    /// тултипа: не зависит от AppKit-таймера всплытия. .ok — no-op (капсула инертна).
    private func showVerdictDetail() {
        guard !verdictLevelOK, !verdictDetail.isEmpty else { return }
        let vc = NSViewController()
        let host = NSView()
        host.wantsLayer = true
        let dark = isDark
        host.layer?.backgroundColor = Design.Color.controlFill(dark).cgColor
        let label = NSTextField(wrappingLabelWithString: verdictDetail)
        label.font = Design.Font.body
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = 240
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: host.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -10),
        ])
        vc.view = host
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .semitransient
        pop.contentSize = NSSize(width: 264, height: label.intrinsicContentSize.height + 20)
        pop.show(relativeTo: verdictPill.bounds, of: verdictPill, preferredEdge: .maxY)
    }

    /// Тихие warn/crit-точки на вкладках таб-бара: «Железо» — перегрев сенсора (Design.tempLevel),
    /// «Питание» — критический заряд (crit) или высокий расход системы (warn). Спокойная машина — точек нет.
    /// Берёт уже собранные снимки (не перечитывает SMC); оверлей не меняет высоту таб-бара.
    private func refreshTabDots(battery b: BatteryInfo, energy e: EnergySnapshot, sensors: SensorsSnapshot) {
        guard let bar = tabBar else { return }
        let hwLevel: Design.Level? = { let l = worstTempSignal(sensors.temps).level; return l == .ok ? nil : l }()
        let critCharge = b.present && !b.charging && b.charge <= 15      // как кольцо/алерты/вердикт
        // V3 «спокойный прибор»: высокий расход больше НЕ warn-точка на вкладке (на ноуте 40–70Вт норма) — только реальный crit.
        let pwrLevel: Design.Level? = critCharge ? .crit : nil
        for (i, id) in tabOrder.enumerated() {
            switch id {
            case "hardware": bar.setDot(i, hwLevel)
            case "flow":     bar.setDot(i, pwrLevel)
            default:         bar.setDot(i, nil)          // «Приложения» и прочее — спокойны
            }
        }
    }

    private func fmtW(_ v: Double?) -> String { v.map { String(format: L("%.2f Вт"), $0) } ?? "—" }

    private func rowView(id: String) -> NSView? {
        func find(_ v: NSView) -> NSView? {
            if v.identifier?.rawValue == id { return v }
            for s in v.subviews { if let r = find(s) { return r } }
            return nil
        }
        return find(view)
    }

    func updateApps(_ apps: [AppEnergy]) {
        AppSession.pushImpacts(apps)         // сессионная история impact (спарклайн) — из уже-собранного снимка
        let grouped = groupedApps(apps)
        appsLast = grouped
        refreshAppFlags()                    // освежаем гео-флаги в фоне (lsof не на main)
        renderAppRows(grouped, animateReorder: true)
        // футер-сводка (все данные уже собраны этим же снимком/тиком — ноль новых системных чтений)
        AppSession.pushTopTotal(apps.reduce(0) { $0 + $1.impact })
        appsUpdatedAt = Date()
        appsFootProcs.stringValue = PowerInfo.lastProcCount.map(String.init) ?? "—"
        // до первого сэмпла — честное «—», не выдуманный «0%»
        appsFootCPU.stringValue = SystemUsage.shared.cpuHistory.last.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
        appsFootMem.stringValue = SystemUsage.shared.ramHistory.last.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
        appsTotalSpark.setHistory(AppSession.topTotalHistory(), tint: Design.Color.accent(isDark))
        refreshAppsUpdatedLabel()
        // Число сгруппированных строк меняется от снимка к снимку — высота вкладки следует
        // фактическому списку, а не старому фиксированному резерву.
        updatePreferredSize()
    }

    /// `top` возвращает отдельные helper/web-content процессы. Для быстрого рейтинга это шум:
    /// объединяем их по имени приложения, суммируя расход, CPU, память и потоки.
    private func groupedApps(_ apps: [AppEnergy]) -> [AppEnergy] {
        var result: [String: AppEnergy] = [:]
        for app in apps {
            let resolved = Connections.resolveByName(app.name).name
            let display: String = {
                let candidates = [resolved, app.name]
                for candidate in candidates {
                    let lower = candidate.lowercased()
                    if lower == "code" || lower.hasPrefix("code ")
                        || lower.hasPrefix("code…") || lower.hasPrefix("visual studio code") {
                        return "Visual Studio Code"
                    }
                    if lower.hasPrefix("firefox") { return "Firefox" }
                    if lower.hasPrefix("google chrome helper") { return "Google Chrome" }
                    if lower.hasPrefix("safari web content") { return "Safari" }
                }
                return resolved.isEmpty ? app.name : resolved
            }()
            if var current = result[display] {
                current.impact += app.impact
                current.cpu = (current.cpu ?? 0) + (app.cpu ?? 0)
                current.memMB = (current.memMB ?? 0) + (app.memMB ?? 0)
                current.threads = (current.threads ?? 0) + (app.threads ?? 0)
                result[display] = current
            } else {
                result[display] = AppEnergy(name: display, impact: app.impact, cpu: app.cpu,
                                            memMB: app.memMB, threads: app.threads)
            }
        }
        return Array(result.values)
    }
    /// «обновлено только что / N с назад» — живёт на 1Гц-тике (данные приложений едут раз в ~5с).
    func refreshAppsUpdatedLabel() {
        guard let t = appsUpdatedAt else { appsUpdatedLabel.stringValue = ""; return }
        let s = Int(Date().timeIntervalSince(t).rounded())
        appsUpdatedLabel.stringValue = s <= 1 ? L("обновлено только что")
                                              : String(format: L("обновлено %d с назад"), s)
    }

    /// Ховер строки: замораживает/размораживает вертикальную пересортировку лидерборда (O4).
    /// Зовётся строкой из mouseEntered/mouseExited. По выходу — применяем отложенный снимок (если был),
    /// уже без «прыжка» под курсором. Гейт Motion.reduced: при reduced FLIP и так выключен — гейт инертен.
    func setRowHover(_ name: String?, entered: Bool) {
        if entered {
            hoveredRowName = name
        } else if hoveredRowName == name {
            hoveredRowName = nil
            if let pending = pendingAppsSnapshot {
                pendingAppsSnapshot = nil
                renderAppRows(pending, animateReorder: true)   // отложенная пересортировка — теперь курсор ушёл
            }
        }
    }

    /// Сбросить реестр переиспользуемых карточек (при переходе в досье/пустой-стейт/calm-floor).
    private func teardownAppRows() {
        appRows.values.forEach { $0.dismissOverlay() }      // D1: снять осиротевшие ховер-оверлеи ДО сноса строк (calm-floor/пусто/досье под курсором)
        appsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        appRows.removeAll(); appHeroName = nil; appsHeader = nil; appsVerdict = nil
        lastFlagCodes.removeAll()                           // O12: карточек нет — diff-кэш флагов недействителен
        hoveredRowName = nil; pendingAppsSnapshot = nil     // реестр сброшен — заморозка ховера недействительна
    }

    /// Достойный пустой/сборный плейсхолдер: нейтральный SF-символ над подписью, центр по H и V в
    /// зарезервированной высоте (266 — тот же пол host). Голый caption у левого края читался бы как
    /// «сломалось» в платном продукте. Без анимации появления (нет пульса под Motion.reduced).
    private func appsPlaceholder(symbol: String, text: String) -> NSView {
        let container = NSView()
        container.identifier = NSUserInterfaceItemIdentifier("appsPlaceholder")   // чтобы data-ветка могла снять «висящий» плейсхолдер
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: IW).isActive = true
        container.heightAnchor.constraint(equalToConstant: 260).isActive = true   // ≈ пол host, минус корешок секции

        let cfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        let iv = NSImageView()
        iv.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        iv.contentTintColor = .tertiaryLabelColor
        iv.translatesAutoresizingMaskIntoConstraints = false

        let l = NSTextField(labelWithString: text)
        l.font = Design.Font.caption; l.textColor = .tertiaryLabelColor
        l.alignment = .center

        let col = NSStackView(views: [iv, l])
        col.orientation = .vertical; col.alignment = .centerX; col.spacing = 8
        col.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(col)
        NSLayoutConstraint.activate([
            col.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            col.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    /// Отрисовка гибрида A+ГЕРОЙ из снимка энергии (без нового top/lsof). Зовут updateApps
    /// (новый снимок → animateReorder), гео-колбэк (флаги доехали → без reorder) и смена сортировки.
    /// animateReorder=true — включает FLIP-пересортировку по имени (переиспользуем вью, не сносим).
    private func renderAppRows(_ apps: [AppEnergy], animateReorder: Bool = false) {
        // ИНВАРИАНТ ДОСЬЕ: пока открыто — рисуем ЛИЦО досье (не лидерборд) на каждый снимок/колбэк.
        if let name = openDossierName {
            if apps.isEmpty { openDossierName = nil }     // idle Mac обнулил топ → безопасный возврат к лидерборду
            else { teardownAppRows(); renderDossierFace(name, apps: apps); return }
        }
        // Пустой/сборный стейт и calm-floor — плейсхолдер, реестр карточек сбрасываем.
        if apps.isEmpty {
            teardownAppRows()
            appsStack.addArrangedSubview(appsPlaceholder(symbol: "hourglass", text: L("сбор данных…")))
            return
        }
        // CALM FLOOR: на простаивающем Mac у топ-приложения крошечный impact — спокойный пустой-стейт.
        // impact — базовая метрика во всех режимах (для .net значение колонки всё равно impact), поэтому
        // держим calm-floor при ЛЮБОЙ сортировке: иначе «герой» промотирует шум с РАСХОД 0.0 в accent-кант.
        let topImpact = sortedApps(apps).first?.impact ?? 0
        if topImpact < 1.0 {
            teardownAppRows()
            appsStack.addArrangedSubview(appsPlaceholder(symbol: "moon.zzz", text: L("Ничего не нагружает")))
            return
        }

        // КРИТИЧНО: data-ветка НЕ зовёт teardownAppRows (переиспользует карточки через reorderStack), поэтому
        // «висящий» плейсхолдер (260pt hourglass, посеянный updateApps([]) на старте) оставался в стеке НАВСЕГДА
        // → вечный «сбор данных…» + скачущая вёрстка. Снимаем любой плейсхолдер перед сборкой лидерборда.
        appsStack.arrangedSubviews
            .filter { $0.identifier?.rawValue == "appsPlaceholder" }
            .forEach { $0.removeFromSuperview() }

        let ordered = Array(sortedApps(apps).prefix(6))
        // Знаменатель длины бара — максимум АКТИВНОЙ метрики (impact/CPU/сеть), чтобы бар кодировал
        // ту же величину, что число и порядок (в CPU/Сеть прежний impact-бар врал).
        let maxMetric = max(ordered.map { appSortMetric($0) }.max() ?? 1, 0.001)
        let targetNames = ordered.map { $0.name }
        let targetSet = Set(targetNames)

        // O4: строка под курсором раскрыта оверлеем, привязанным к её геометрии. FLIP двигает СЛОЙ —
        // оверлей отклеился бы, а под неподвижным курсором mouseExited не перевызвался. Пока ховер жив,
        // замораживаем вертикальную пересортировку/эвикт: обновляем ТОЛЬКО значения/бар/спарк/флаги НА
        // МЕСТЕ (порядок не трогаем), а последний снимок откладываем — применим по mouseExited.
        if animateReorder, hoveredRowName != nil, !appRows.isEmpty {
            pendingAppsSnapshot = apps
            for a in ordered {
                guard let card = appRows[a.name] else { continue }   // новые/переехавшие ждут разморозки
                configureCard(card, a: a, fraction: appSortMetric(a) / maxMetric, isHero: card.isHero, animateValue: true)
            }
            DispatchQueue.main.async { [weak self] in self?.applyAppRowTips() }
            return
        }

        // ВЫВОД-ВЕРДИКТ над лидербордом: #1 потребитель как ГОТОВЫЙ вывод, а не таблица для чтения
        // («Chrome больше всех расходует энергию») — это и есть преимущество над Мониторингом системы.
        if appsVerdict == nil {
            let v = NSTextField(labelWithString: "")
            v.font = Design.Font.headline; v.textColor = .labelColor
            // 2 строки с переносом: длинное имя процесса («WindowServer») + фраза не влезали в одну
            // строку IW и обрезались по хвосту («…больше всех рас…»), теряя сам вывод. Перенос держит
            // вердикт целым (и заполняет верх вкладки — цель L4), высоту вкладка вмещает.
            v.lineBreakMode = .byWordWrapping; v.maximumNumberOfLines = 2
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: IW).isActive = true
            v.preferredMaxLayoutWidth = IW
            appsVerdict = v
            appsStack.addArrangedSubview(v)
        }
        if let top = ordered.first { appsVerdict?.stringValue = appsVerdictText(top) }

        // Заголовок колонки + сегмент сортировки — строится один раз, живёт наверху стека.
        if appsHeader == nil {
            let h = appsColumnHeader()
            appsHeader = h
            appsStack.addArrangedSubview(h)
        } else {
            updateColumnHeaderEyebrow()
        }

        // Снять First-кадры существующих карточек ДО перестановки (для FLIP).
        let doFlip = animateReorder && !Motion.reduced
        var firstFrames: [String: CGRect] = [:]
        if doFlip { for (n, v) in appRows { firstFrames[n] = v.frame } }

        // Эвикт карточек, выпавших из топа.
        for (n, v) in appRows where !targetSet.contains(n) {
            v.dismissOverlay()          // O6: снести осиротевший ховер-оверлей вместе со строкой
            v.removeFromSuperview(); appRows[n] = nil
            lastFlagCodes[n] = nil      // O12: не течь diff-кэшем флагов
            if appHeroName == n { appHeroName = nil }
        }

        // Создать/обновить карточки НА МЕСТЕ и выставить целевой порядок в стеке.
        var newCardNames: [String] = []
        for (_, a) in ordered.enumerated() {
            let isHero = false
            let card: DossierRowView
            if let existing = appRows[a.name], (existing.isHero == isHero) {
                card = existing
            } else {
                appRows[a.name]?.removeFromSuperview()       // сменилась роль (герой↔строка) — пересоздать
                card = buildAppCard(a, isHero: isHero)
                appRows[a.name] = card
                newCardNames.append(a.name)
            }
            configureCard(card, a: a, fraction: appSortMetric(a) / maxMetric, isHero: isHero, animateValue: animateReorder)
        }
        appHeroName = nil

        // Целевой порядок arrangedSubviews: вердикт, header, затем карточки в порядке ordered.
        var order: [NSView] = []
        if let vd = appsVerdict { order.append(vd) }
        if let h = appsHeader { order.append(h) }
        for a in ordered { if let c = appRows[a.name] { order.append(c) } }
        reorderStack(appsStack, to: order)

        // O5: имя, что БЫЛО до пересортировки (есть First-кадр), но карточка пересоздана из-за смены
        // роли герой↔строка, — это ПЕРЕЕЗД, а не рождение. Даём ему FLIP от старого origin.y (а не
        // stagger-fade), иначе экс-герой и новый герой ХЛОПАЮТ, пока строки 2..6 плавно скользят.
        let trulyNewNames = newCardNames.filter { firstFrames[$0] == nil }

        // FLIP: Last-кадры после layout, анимируем Δ(First−Last) к нулю (соседи волной).
        if doFlip {
            appsStack.layoutSubtreeIfNeeded()
            for (n, v) in appRows {
                guard let first = firstFrames[n] else { continue }   // покрывает и переехавшего (пере)героя
                let dy = first.origin.y - v.frame.origin.y
                guard abs(dy) > 0.5 else { continue }
                let anim = CABasicAnimation(keyPath: "transform.translation.y")
                anim.fromValue = dy; anim.toValue = 0
                anim.duration = Design.Motion.durBase
                // O10: reorder на фирменной decelerate (без overshoot — 6 строк с перелётом-откатом читались «желе»).
                anim.timingFunction = Design.Motion.easeStandard
                v.layer?.add(anim, forKey: "flipReorder")
            }
        }
        // Каскад появления ТОЛЬКО по-настоящему новых карточек (stagger) — при первом заполнении/новых именах.
        if !Motion.reduced {
            for (i, n) in trulyNewNames.enumerated() {
                guard let v = appRows[n] else { continue }
                v.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Design.Motion.durSlow
                    ctx.timingFunction = Design.Motion.easeOut
                    v.animator().alphaValue = 1
                }
                let rise = CABasicAnimation(keyPath: "transform.translation.y")
                rise.fromValue = -6; rise.toValue = 0
                rise.beginTime = CACurrentMediaTime() + Double(i) * Design.Motion.stagger
                rise.duration = Design.Motion.durSlow
                rise.timingFunction = Design.Motion.easeOut
                rise.fillMode = .backwards
                v.layer?.add(rise, forKey: "stagger")
            }
        }
        // Тултипы на усекаемое — ПОСЛЕ layout (ширина известна только тогда).
        DispatchQueue.main.async { [weak self] in self?.applyAppRowTips() }
    }

    /// Переставить arrangedSubviews стека в целевой порядок без сноса вью (FLIP-совместимо).
    private func reorderStack(_ stack: NSStackView, to order: [NSView]) {
        for (i, v) in order.enumerated() {
            if v.superview == nil || !stack.arrangedSubviews.contains(v) {
                stack.insertArrangedSubview(v, at: min(i, stack.arrangedSubviews.count))
            } else if let cur = stack.arrangedSubviews.firstIndex(of: v), cur != i {
                stack.removeArrangedSubview(v)
                stack.insertArrangedSubview(v, at: min(i, stack.arrangedSubviews.count))
            }
        }
    }

    /// Капс-эйброу над колонкой значений + сегмент сортировки (Расход/CPU/Сеть) справа сверху.
    /// Вывод-вердикт «кто грузит» — фраза по активной сортировке + имя топ-приложения (честно: это #1
    /// по тому же критерию, что и лидерборд; ничего не выдумываем — только называем вывод словами).
    private func appsVerdictText(_ a: AppEnergy) -> String {
        switch appsSort {
        case .impact: return String(format: L("%@ расходует больше всего · %@"), a.name, fmtImpact(a.impact))
        case .cpu:    return String(format: L("%@ сильнее грузит CPU · %@"), a.name, a.cpu.map(fmtCPU) ?? "—")
        case .net:    return String(format: L("%@ активнее всех в сети · %d"), a.name, appNetCount(a))
        }
    }

    private func appsColumnHeader() -> NSView {
        let seg = makeAppsSortSegment()

        let row = NSStackView(views: [seg])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 0
        row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 3, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: IW).isActive = true
        return row
    }
    private func updateColumnHeaderEyebrow() {
        // Полноширинный сегмент сам объясняет активную метрику; отдельный обрезаемый эйброу больше не нужен.
    }
    private func findField(in v: NSView, id: String) -> NSTextField? {
        if let f = v as? NSTextField, f.identifier?.rawValue == id { return f }
        for s in v.subviews { if let r = findField(in: s, id: id) { return r } }
        return nil
    }

    /// Сегмент сортировки Расход/CPU/Сеть в стиле PillTabBar. Смена → пересортировка той же FLIP.
    private func makeAppsSortSegment() -> NSView {
        let labels = [L("Расход"), L("CPU"), L("Сеть")]
        let sel: Int = appsSort == .impact ? 0 : (appsSort == .cpu ? 1 : 2)
        let bar = PillTabBar(labels: labels, selected: sel)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: IW).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 26).isActive = true
        bar.setAccessibilityLabel(L("Сортировка расхода приложений"))
        bar.onSelect = { [weak self] i in
            guard let self = self else { return }
            let s: AppsSort = i == 0 ? .impact : (i == 1 ? .cpu : .net)
            guard s != self.appsSort else { return }
            self.appsSort = s
            self.renderAppRows(self.appsLast, animateReorder: true)   // та же FLIP-пересортировка
        }
        return bar
    }

    /// Флаг-вью страны-назначения (лидерборд). Тултип НАЗЫВАЕТ страну через GeoIP.name (правило).
    private func makeFlagView(for name: String, resolvedName: String, width: CGFloat) -> NSView {
        let key = resolvedName.lowercased()
        let alt = name.lowercased()
        let flag = appCountryFlags[key] ?? appCountryFlags[alt]
        let flagView: NSView
        if let flag = flag, flag != Self.lanGlobe {
            let f = NSTextField(labelWithString: flag)
            f.font = Design.Font.caption
            // тултип флага = ИМЯ показанной страны (не «усечение»): код из самого флага → GeoIP.name.
            f.toolTip = GeoIP.code(fromFlag: flag).map { GeoIP.name($0) } ?? L("Активное сетевое соединение в эту страну")
            flagView = f
        } else if flag == Self.lanGlobe {
            let g = NSImageView()
            g.image = NSImage(systemSymbolName: "globe", accessibilityDescription: L("Локальная сеть"))
            g.contentTintColor = .tertiaryLabelColor
            g.translatesAutoresizingMaskIntoConstraints = false
            g.widthAnchor.constraint(equalToConstant: 11).isActive = true
            g.heightAnchor.constraint(equalToConstant: 11).isActive = true
            g.toolTip = L("Соединение только в локальной сети")
            flagView = g
        } else {
            flagView = NSView()
        }
        flagView.translatesAutoresizingMaskIntoConstraints = false
        flagView.widthAnchor.constraint(equalToConstant: width).isActive = true
        return flagView
    }

    private func appIconView(_ a: AppEnergy, resolved: (icon: NSImage?, name: String), side: CGFloat) -> NSView {
        let iconView: NSView
        if let img = resolved.icon {
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            // Ж1: единый токен скругления app-иконки; герою (крупнее) — пропорционально больше.
            iv.layer?.cornerRadius = side >= 28 ? 6 : Design.Radius.appIcon
            iv.layer?.cornerCurve = .continuous
            iv.layer?.masksToBounds = true
            iv.image = img
            iconView = iv
        } else {
            iconView = systemProcessGlyph(a.name)
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: side).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: side).isActive = true
        return iconView
    }

    /// Строит новую карточку (герой или строку лидерборда) с ссылками на мутируемый контент.
    /// Контент наполняется отдельно в configureCard (чтобы FLIP-переиспользование обновляло НА МЕСТЕ).
    private func buildAppCard(_ a: AppEnergy, isHero: Bool) -> DossierRowView {
        let wrapper = DossierRowView()
        wrapper.owner = self
        wrapper.appName = a.name
        wrapper.isHero = isHero
        wrapper.canExpand = !isHero
        wrapper.barW = appsBarW
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.wantsLayer = true
        wrapper.layer?.cornerRadius = Design.Radius.chip
        wrapper.layer?.cornerCurve = .continuous
        wrapper.widthAnchor.constraint(equalToConstant: IW).isActive = true
        if isHero { buildHeroBody(wrapper, a: a) } else { buildRowBody(wrapper, a: a) }
        return wrapper
    }

    /// Тело строки лидерборда: [иконка][имя][спарклайн][бар][значение][флаг].
    private func buildRowBody(_ wrapper: DossierRowView, a: AppEnergy) {
        let resolved = Connections.resolveByName(a.name)
        let baseFill = Design.Color.controlFill(isDark).cgColor
        wrapper.baseFill = baseFill
        wrapper.layer?.backgroundColor = baseFill
        wrapper.layer?.borderWidth = 0

        let iconView = appIconView(a, resolved: resolved, side: 20)

        let name = NSTextField(labelWithString: resolved.name)
        name.font = Design.Font.caption
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.identifier = NSUserInterfaceItemIdentifier("rowName")
        name.setContentHuggingPriority(.init(1), for: .horizontal)
        name.setContentCompressionResistancePriority(.init(250), for: .horizontal)

        let spark = MiniSpark()
        spark.translatesAutoresizingMaskIntoConstraints = false
        spark.widthAnchor.constraint(equalToConstant: appsSparkW).isActive = true
        spark.heightAnchor.constraint(equalToConstant: 14).isActive = true
        wrapper.spark = spark

        let track = NSView()
        track.translatesAutoresizingMaskIntoConstraints = false
        track.wantsLayer = true
        track.layer?.backgroundColor = Design.Color.trackFill(isDark).cgColor
        track.layer?.cornerRadius = 3; track.layer?.cornerCurve = .continuous
        track.widthAnchor.constraint(equalToConstant: appsBarW).isActive = true
        track.heightAnchor.constraint(equalToConstant: 6).isActive = true
        let fill = NSView()
        fill.translatesAutoresizingMaskIntoConstraints = false
        fill.wantsLayer = true
        fill.layer?.backgroundColor = Design.Color.accent(isDark).cgColor
        fill.layer?.cornerRadius = 3; fill.layer?.cornerCurve = .continuous
        track.addSubview(fill)
        let fw = fill.widthAnchor.constraint(equalToConstant: 6)
        wrapper.fillWidth = fw
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fw,
        ])

        let val = NSTextField(labelWithString: "")
        val.font = Design.Font.numericBody
        val.textColor = .secondaryLabelColor
        val.alignment = .right
        val.wantsLayer = true                 // roll-up CATransition требует backing-слой
        val.translatesAutoresizingMaskIntoConstraints = false
        val.widthAnchor.constraint(equalToConstant: appsValW).isActive = true
        wrapper.valLabel = val

        let flag = makeFlagView(for: a.name, resolvedName: resolved.name, width: appsFlagW)
        let flagHost = NSView()
        flagHost.translatesAutoresizingMaskIntoConstraints = false
        flagHost.widthAnchor.constraint(equalToConstant: appsFlagW).isActive = true
        flagHost.addSubview(flag)
        NSLayoutConstraint.activate([
            flag.centerXAnchor.constraint(equalTo: flagHost.centerXAnchor),
            flag.centerYAnchor.constraint(equalTo: flagHost.centerYAnchor),
        ])
        wrapper.flagHost = flagHost

        let row = NSStackView(views: [iconView, name, spark, track, val, flagHost])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: wrapper.topAnchor),
            row.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        ])
    }

    /// Тело ГЕРОЯ: accent-кант, крупная иконка, имя + микро-строка CPU·MEM, полноширинный спарклайн,
    /// РАСХОД крупно справа, кластер флагов-назначений. Крупнее строк — «дорогая» плитка.
    private func buildHeroBody(_ wrapper: DossierRowView, a: AppEnergy) {
        let resolved = Connections.resolveByName(a.name)
        let accent = Design.Color.accent(isDark)
        let baseFill = Design.Color.glassTint(accent, isDark).cgColor
        wrapper.baseFill = baseFill
        wrapper.layer?.backgroundColor = baseFill
        wrapper.layer?.borderWidth = 1
        wrapper.layer?.borderColor = Design.Color.accentRim(isDark).cgColor   // Ж2: токен accentRim (app↔web-контракт)

        let iconView = appIconView(a, resolved: resolved, side: 28)

        let name = NSTextField(labelWithString: resolved.name)
        name.font = Design.Font.headline
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.identifier = NSUserInterfaceItemIdentifier("rowName")
        name.setContentHuggingPriority(.init(1), for: .horizontal)
        name.setContentCompressionResistancePriority(.init(250), for: .horizontal)

        let micro = NSTextField(labelWithString: "")
        micro.font = Design.Font.microStat
        micro.textColor = .tertiaryLabelColor
        micro.lineBreakMode = .byTruncatingTail
        micro.wantsLayer = true             // Ж6: CATransition crossfade требует backing-слой
        wrapper.microLine = micro
        let nameCol = NSStackView(views: [name, micro])
        nameCol.orientation = .vertical
        nameCol.alignment = .leading
        nameCol.spacing = 1

        // РАСХОД крупно + капс
        let valNum = NSTextField(labelWithString: "")
        valNum.font = Design.Font.numericLarge
        valNum.textColor = .labelColor
        valNum.alignment = .right
        valNum.wantsLayer = true              // roll-up CATransition требует backing-слой
        wrapper.valLabel = valNum
        let valCap = NSTextField(labelWithString: "")
        valCap.font = Design.Font.microStat
        valCap.textColor = .tertiaryLabelColor
        valCap.alignment = .right
        capsText(valCap, L("Расход"))
        let valueCluster = NSStackView(views: [valNum, valCap])
        valueCluster.orientation = .vertical
        valueCluster.alignment = .trailing
        valueCluster.spacing = 0

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        // O7: правый коридор героя = коридор строк. У строки справа флаг (appsFlagW) + spacing(8) ПОСЛЕ
        // числа; во heroTopRow флагов нет — компенсируем пустым pad той же ширины, чтобы правая кромка
        // ЧИСЛА героя (valNum) встала ровно над правой кромкой val строк (десятичная точка — в колонку).
        let valPad = NSView()
        valPad.translatesAutoresizingMaskIntoConstraints = false
        valPad.widthAnchor.constraint(equalToConstant: appsFlagW).isActive = true

        let topRow = NSStackView(views: [iconView, nameCol, spacer, valueCluster, valPad])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8

        // полноширинный спарклайн истории (Ж4: тяжелее линия — вес совпадает с тонкой строкой на глаз)
        let spark = MiniSpark()
        spark.heavy = true
        spark.translatesAutoresizingMaskIntoConstraints = false
        spark.heightAnchor.constraint(equalToConstant: 16).isActive = true   // Ж4: 18→16, ближе к строке (14)
        wrapper.spark = spark

        // кластер флагов-назначений (до 3) + тултип имени страны через GeoIP.name
        let flagHost = NSView()
        flagHost.translatesAutoresizingMaskIntoConstraints = false
        flagHost.heightAnchor.constraint(equalToConstant: 14).isActive = true
        wrapper.flagHost = flagHost

        let sparkRow = NSStackView(views: [spark, flagHost])
        sparkRow.orientation = .horizontal
        sparkRow.alignment = .centerY
        sparkRow.spacing = 8
        spark.setContentHuggingPriority(.init(1), for: .horizontal)

        let col = NSStackView(views: [topRow, sparkRow])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 6
        // O7: инсеты героя = инсеты строк (8/8) — левые края иконок и правый внутренний коридор совпадут.
        col.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        col.translatesAutoresizingMaskIntoConstraints = false
        topRow.widthAnchor.constraint(equalTo: col.widthAnchor, constant: -16).isActive = true
        sparkRow.widthAnchor.constraint(equalTo: col.widthAnchor, constant: -16).isActive = true

        wrapper.addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: wrapper.topAnchor),
            col.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            col.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            col.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        ])
    }

    /// Наполнить карточку данными снимка — НА МЕСТЕ (roll-up значения, анимация бара, спарклайн, флаги).
    private func configureCard(_ card: DossierRowView, a: AppEnergy, fraction: Double, isHero: Bool, animateValue: Bool) {
        let resolved = Connections.resolveByName(a.name)
        // спарклайн истории impact. Ж4: у героя accent-линия на accent-фоне теряла контраст — берём
        // accentBright, чтобы форма тренда читалась на тинте героя.
        let sparkTint = isHero ? Design.Color.accentBright(isDark) : Design.Color.accent(isDark)
        card.spark?.setHistory(AppSession.history(a.name), tint: sparkTint)

        // значение (roll-up / кросс-фейд при изменении). O11: направление push зависит от роста/падения —
        // растущее число въезжает снизу, падающее — сверху (иначе падение «въезжало сверху» неверно).
        let newVal = appValueText(a)
        if let val = card.valLabel {
            if val.stringValue != newVal {
                if animateValue && !Motion.reduced && !val.stringValue.isEmpty {
                    let t = CATransition()
                    t.type = .push
                    t.subtype = (leadingNumber(newVal) > leadingNumber(val.stringValue)) ? .fromBottom : .fromTop
                    t.duration = Design.Motion.durBase   // O9: одна длительность с баром (обе кодируют impact)
                    t.timingFunction = Design.Motion.easeStandard
                    val.layer?.add(t, forKey: "rollup")
                }
                val.stringValue = newVal
            }
        }

        // бар: анимируем ширину (не скачком). O9: та же длительность/кривая, что и roll-up — финишируют вместе.
        if let fw = card.fillWidth {
            let target = max(card.barW * CGFloat(min(max(fraction, 0), 1)), 6)
            if abs(fw.constant - target) > 0.5 {
                if animateValue && !Motion.reduced {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = Design.Motion.durBase
                        ctx.timingFunction = Design.Motion.easeStandard   // O9: раньше дефолтная линейная
                        fw.animator().constant = target
                    }
                } else { fw.constant = target }
            }
        }

        // микро-строка героя: CPU · MEM. Ж6: гоним через тот же crossfade, что и число (не голый щелчок под едущим числом).
        if isHero, let micro = card.microLine {
            var parts: [String] = []
            if let c = a.cpu { parts.append("CPU " + fmtCPU(c)) }
            if let m = a.memMB { parts.append(fmtMem(m)) }
            let newMicro = parts.joined(separator: "  ·  ")
            if micro.stringValue != newMicro {
                if animateValue && !Motion.reduced && !micro.stringValue.isEmpty {
                    let t = CATransition()
                    t.type = .fade
                    t.duration = Design.Motion.durBase
                    micro.layer?.add(t, forKey: "microfade")
                }
                micro.stringValue = newMicro
            }
            micro.isHidden = parts.isEmpty
        }

        // флаги: пересобираем flagHost ТОЛЬКО когда набор кодов реально изменился (O12) — иначе флаги
        // мигали каждый тик под плавно едущим числом/баром. Diff по последнему набору на карте.
        if let host = card.flagHost {
            let codes = AppSession.countryCodes(nameLower: a.name.lowercased())
            if lastFlagCodes[a.name] != codes {
                lastFlagCodes[a.name] = codes
                host.subviews.forEach { $0.removeFromSuperview() }
                if isHero {
                    populateHeroFlags(host, name: a.name)
                } else {
                    let flag = makeFlagView(for: a.name, resolvedName: resolved.name, width: appsFlagW)
                    host.addSubview(flag)
                    NSLayoutConstraint.activate([
                        flag.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                        flag.centerYAnchor.constraint(equalTo: host.centerYAnchor),
                    ])
                }
            }
        }

        // O14: у героя нет ховер-раскрытия и его setAccessibilityLabel мёртв (override возвращает a11yText),
        // поэтому «топ-приложение» несём префиксом самого a11yText, чтобы VoiceOver его объявил.
        // Ж12: потоки/страны иначе недостижимы без мыши (ховер-раскрытие) — сворачиваем в a11yText.
        var tail = ""
        if let t = a.threads { tail += ", " + String(format: L("%d потоков"), t) }
        let acodes = AppSession.countryCodes(nameLower: a.name.lowercased())
        if !acodes.isEmpty { tail += ", " + acodes.map { GeoIP.name($0) }.joined(separator: ", ") }
        let base = String(format: L("%@, расход %@, CPU %@, память %@, открыть досье"),
                          resolved.name, fmtImpact(a.impact),
                          a.cpu.map(fmtCPU) ?? "—", a.memMB.map(fmtMem) ?? "—") + tail
        card.a11yText = isHero ? (L("Топ-приложение по расходу") + ", " + base) : base
    }

    // O12: последний набор ISO-кодов страны на приложение — diff, чтобы не пересобирать флаги каждый тик.
    private var lastFlagCodes: [String: [String]] = [:]

    /// Ведущее число строки значения (для направления roll-up O11): "12.3" → 12.3, "45%" → 45, "—" → 0.
    private func leadingNumber(_ s: String) -> Double {
        var out = ""
        for ch in s {
            if ch.isNumber || ch == "." || (out.isEmpty && ch == "-") { out.append(ch) }
            else if !out.isEmpty { break }
        }
        return Double(out) ?? 0
    }

    /// Кластер флагов-назначений героя: до 3 флагов (тултип = имя страны через GeoIP.name) + «+N».
    private func populateHeroFlags(_ host: NSView, name: String) {
        let codes = AppSession.countryCodes(nameLower: name.lowercased())
        guard !codes.isEmpty else { return }
        let shown = Array(codes.prefix(3))
        var chips: [NSView] = []
        for code in shown {
            let f = NSTextField(labelWithString: GeoIP.flag(code))
            f.font = Design.Font.caption
            f.toolTip = GeoIP.name(code)          // флаг НАЗЫВАЕТ страну
            chips.append(f)
        }
        if codes.count > shown.count {
            let extra = NSTextField(labelWithString: "+\(codes.count - shown.count)")
            extra.font = Design.Font.microStat
            extra.textColor = .secondaryLabelColor
            // свёртка +N — тултип = имена свёрнутых стран через GeoIP.name
            extra.toolTip = codes.dropFirst(shown.count).map { GeoIP.name($0) }.joined(separator: ", ")
            chips.append(extra)
        }
        let stack = NSStackView(views: chips)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor),
        ])
    }

    /// ТУЛТИПЫ на усекаемое — ставятся ПОСЛЕ layout (ширина полей известна только тогда).
    private func applyAppRowTips() {
        for (_, card) in appRows {
            guard let nameField = findField(in: card, id: "rowName") else { continue }
            applyTruncTip(nameField, full: nameField.stringValue, avail: nameField.bounds.width)
            if let val = card.valLabel {
                applyTruncTip(val, full: val.stringValue, avail: val.bounds.width)
            }
            // O14: микро-строка героя (CPU · MEM) усекается byTruncatingTail, а герой не раскрывается —
            // это единственная дыра честности над ним. Тултип на усечение закрывает её.
            if let micro = card.microLine, !micro.isHidden {
                applyTruncTip(micro, full: micro.stringValue, avail: micro.bounds.width)
            }
        }
    }

    // MARK: - ДОСЬЕ ПРИЛОЖЕНИЯ (Batch D) — задняя грань плитки «Приложения»

    /// Открытие досье: фиксируем имя (инвариант перерендера), чистим кэш соединений, флипаем на
    /// заднюю грань, запускаем фоновой сбор conns. Грань рисуется в renderDossierFace через rebuild.
    func openDossier(for name: String) {
        guard openDossierName != name else { return }
        openDossierName = name
        dossierConns = []; dossierCountries = []; dossierHasLAN = false; dossierAppPath = nil
        dossierBusy = false        // новый open всегда стартует свою загрузку; прежний snapshot в полёте безвреден (отсечётся name-guard'ом в completion) — иначе busy мог застрять и грань вечно «сбор соединений…»
        flipApps(toDossier: true) { [weak self] in self?.renderAppRows(self?.appsLast ?? []) }
        loadDossierConns(name)
    }

    /// Назад-шеврон: сбрасываем состояние, флипаем обратно к лидерборду, VoiceOver-фокус на строку.
    @objc func closeDossier() {
        guard let was = openDossierName else { return }
        openDossierName = nil
        flipApps(toDossier: false) { [weak self] in
            guard let self = self else { return }
            self.renderAppRows(self.appsLast)
            // VoiceOver: вернуть фокус на исходную строку (по сырому имени), иначе на стек.
            let target: NSView? = self.appsStack.arrangedSubviews
                .compactMap { $0 as? DossierRowView }.first { $0.appName == was } ?? self.appsStack
            NSAccessibility.post(element: target as Any, notification: .focusedUIElementChanged)
        }
    }

    /// Рисует ЛИЦО досье в appsStack (зовётся из renderAppRows-диспетчера на каждый снимок/колбэк).
    /// impact берёт из свежего снимка; выпало из топа → последний известный из appsLast → «—».
    private func renderDossierFace(_ name: String, apps: [AppEnergy]) {
        appsStack.addArrangedSubview(dossierFace(name, apps: apps))
    }

    /// Лицо досье: вертикальный стек ≤ высоты лидерборда (~155pt). Прозрачный фон (плитка стеклянная).
    /// Блоки: A шапка (back/иконка/имя/значение-РАСХОД) · B страны · C хайрлайн · D соединения · E пилюли.
    private func dossierFace(_ name: String, apps: [AppEnergy]) -> NSView {
        let resolved = Connections.resolveByName(name)
        let impact = apps.first { $0.name == name }?.impact
            ?? appsLast.first { $0.name == name }?.impact      // выпал из топа → последний известный

        let face = NSStackView()
        face.orientation = .vertical
        face.alignment = .leading
        face.spacing = 6
        face.translatesAutoresizingMaskIntoConstraints = false
        face.widthAnchor.constraint(equalToConstant: IW).isActive = true
        face.setAccessibilityElement(true)
        face.setAccessibilityLabel(String(format: L("Досье приложения %@"), resolved.name))

        // --- A. Шапка ---
        let back = NSButton()
        back.isBordered = false
        back.bezelStyle = .regularSquare
        back.imagePosition = .imageOnly
        let backCfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        back.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: L("Назад к списку приложений"))?
            .withSymbolConfiguration(backCfg)
        back.contentTintColor = Design.Color.accent(isDark)
        back.target = self
        back.action = #selector(closeDossier)
        back.toolTip = L("Назад к списку приложений")
        back.setAccessibilityLabel(L("Назад к списку приложений"))
        back.translatesAutoresizingMaskIntoConstraints = false
        back.widthAnchor.constraint(equalToConstant: 22).isActive = true
        back.heightAnchor.constraint(equalToConstant: 22).isActive = true
        dossierBackButton = back

        let iconView: NSView
        if let img = resolved.icon {
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            iv.layer?.cornerRadius = Design.Radius.appIcon   // Ж1: единый токен скругления app-иконки
            iv.layer?.cornerCurve = .continuous
            iv.layer?.masksToBounds = true
            iv.image = img
            iconView = iv
        } else {
            iconView = systemProcessGlyph(name)
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 20).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let nameLabel = NSTextField(labelWithString: resolved.name)
        nameLabel.font = Design.Font.headline
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        // тултип имени досье — ТОЛЬКО если усечено (после layout, ширина известна лишь тогда)
        DispatchQueue.main.async { [weak self, weak nameLabel] in
            guard let self = self, let nameLabel = nameLabel else { return }
            self.applyTruncTip(nameLabel, full: resolved.name, avail: nameLabel.bounds.width)
        }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        // valueCluster: число РАСХОД + капс-эйброу. ЖЁСТКО «РАСХОД», НИКОГДА «Вт».
        // Ж9: приложение открыто, но в покое (impact ~0) → «—», а не «0.0» под капсом РАСХОД.
        let valNum = NSTextField(labelWithString: (impact.map { $0 < 0.05 ? "—" : String(format: "%.1f", $0) }) ?? "—")
        valNum.font = Design.Font.numericLarge
        valNum.textColor = .labelColor
        valNum.alignment = .right
        let valCap = NSTextField(labelWithString: "")
        valCap.font = Design.Font.microStat
        valCap.textColor = .tertiaryLabelColor
        valCap.alignment = .right
        capsText(valCap, L("Расход"))
        let valueCluster = NSStackView(views: [valNum, valCap])
        valueCluster.orientation = .vertical
        valueCluster.alignment = .trailing
        valueCluster.spacing = 0
        valueCluster.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView(views: [back, iconView, nameLabel, spacer, valueCluster])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 8)
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.widthAnchor.constraint(equalToConstant: IW).isActive = true
        face.addArrangedSubview(headerRow)

        // --- B. Кластер стран (дословная калька connRow) ---
        let geoRow = NSStackView()
        geoRow.orientation = .horizontal
        geoRow.alignment = .centerY
        geoRow.spacing = 4
        if dossierBusy && dossierConns.isEmpty && dossierCountries.isEmpty && !dossierHasLAN {
            let l = NSTextField(labelWithString: L("сбор соединений…"))
            l.font = Design.Font.caption; l.textColor = .tertiaryLabelColor
            geoRow.addArrangedSubview(l)
        } else if dossierCountries.isEmpty && !dossierHasLAN {
            let l = NSTextField(labelWithString: L("Нет активных соединений"))
            l.font = Design.Font.caption; l.textColor = .tertiaryLabelColor
            geoRow.addArrangedSubview(l)
        } else {
            let shown = dossierCountries.prefix(3)
            for c in shown {
                let l = NSTextField(labelWithString: c)   // "🇺🇸 США" — флаг уже в метке
                l.font = Design.Font.callout; l.lineBreakMode = .byTruncatingTail
                geoRow.addArrangedSubview(l)
            }
            if dossierCountries.count > shown.count {
                let extra = NSTextField(labelWithString: "+\(dossierCountries.count - shown.count)")
                extra.font = Design.Font.callout; extra.textColor = .secondaryLabelColor
                // свёртка +N: тултип = имена свёрнутых стран (метки уже содержат имя после флага)
                extra.toolTip = dossierCountries.dropFirst(shown.count).joined(separator: ", ")
                geoRow.addArrangedSubview(extra)
            }
            if dossierHasLAN && dossierCountries.count < 3 {
                let globe = NSImageView()
                globe.image = NSImage(systemSymbolName: "globe", accessibilityDescription: L("Локальная сеть"))
                globe.contentTintColor = .secondaryLabelColor
                globe.translatesAutoresizingMaskIntoConstraints = false
                globe.widthAnchor.constraint(equalToConstant: 13).isActive = true
                globe.heightAnchor.constraint(equalToConstant: 13).isActive = true
                let lan = NSTextField(labelWithString: L("Локальная сеть"))
                lan.font = Design.Font.callout; lan.textColor = .secondaryLabelColor
                geoRow.addArrangedSubview(globe)
                geoRow.addArrangedSubview(lan)
            }
        }
        face.addArrangedSubview(geoRow)

        // --- C/D. Хайрлайн + список соединений (до 3) — только если conns есть ---
        if !dossierConns.isEmpty {
            let rule = NSView()
            rule.wantsLayer = true
            rule.layer?.backgroundColor = Design.Color.hairline(isDark, 0.08).cgColor
            rule.translatesAutoresizingMaskIntoConstraints = false
            rule.widthAnchor.constraint(equalToConstant: IW).isActive = true
            rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
            face.addArrangedSubview(rule)

            for c in dossierConns.prefix(3) { face.addArrangedSubview(connDetailRow(c)) }
            if dossierConns.count > 3 {
                let more = NSTextField(labelWithString: String(format: L("ещё %d"), dossierConns.count - 3))
                more.font = Design.Font.caption; more.textColor = .tertiaryLabelColor
                face.addArrangedSubview(more)
            }
        }

        // --- E. Пилюли действий (только честные) ---
        face.addArrangedSubview(dossierPills())
        return face
    }

    /// Строка одного соединения: proto-бейдж · ip:port · флаг страны-назначения (исходящее).
    private func connDetailRow(_ c: NetConn) -> NSView {
        let proto = NSTextField(labelWithString: c.proto)
        proto.font = Design.Font.microStat
        proto.textColor = .tertiaryLabelColor
        proto.alignment = .center
        proto.wantsLayer = true
        proto.drawsBackground = false
        let protoWrap = NSView()
        protoWrap.wantsLayer = true
        protoWrap.layer?.backgroundColor = Design.Color.controlFill(isDark).cgColor
        protoWrap.layer?.cornerRadius = Design.Radius.chip
        protoWrap.layer?.cornerCurve = .continuous
        protoWrap.translatesAutoresizingMaskIntoConstraints = false
        protoWrap.addSubview(proto)
        proto.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            protoWrap.widthAnchor.constraint(equalToConstant: 28),
            proto.centerXAnchor.constraint(equalTo: protoWrap.centerXAnchor),
            proto.centerYAnchor.constraint(equalTo: protoWrap.centerYAnchor),
        ])

        let dest = NSTextField(labelWithString: c.label)
        dest.font = Design.Font.numericBody
        dest.textColor = .secondaryLabelColor
        dest.lineBreakMode = .byTruncatingMiddle
        dest.setContentHuggingPriority(.init(1), for: .horizontal)
        dest.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        // тултип ip:port — ТОЛЬКО если усечено (после layout)
        DispatchQueue.main.async { [weak self, weak dest] in
            guard let self = self, let dest = dest else { return }
            self.applyTruncTip(dest, full: c.label, avail: dest.bounds.width)
        }

        let flagView: NSView
        if let geo = GeoIP.label(for: c.remoteIP) {
            let f = NSTextField(labelWithString: geo)   // "🇺🇸 США"
            f.font = Design.Font.caption
            flagView = f
        } else {
            let g = NSImageView()                       // LAN/неизвестно → глобус, не фейк-флаг
            g.image = NSImage(systemSymbolName: "globe", accessibilityDescription: L("Локальная сеть"))
            g.contentTintColor = .tertiaryLabelColor
            g.translatesAutoresizingMaskIntoConstraints = false
            g.widthAnchor.constraint(equalToConstant: 11).isActive = true
            g.heightAnchor.constraint(equalToConstant: 11).isActive = true
            flagView = g
        }
        flagView.translatesAutoresizingMaskIntoConstraints = false
        flagView.widthAnchor.constraint(equalToConstant: appsFlagW).isActive = true

        let row = NSStackView(views: [protoWrap, dest, flagView])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: IW).isActive = true
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel("\(c.proto) \(c.label) \(GeoIP.label(for: c.remoteIP) ?? "")")
        return row
    }

    /// Пилюли действий досье: «Показать в Finder» (Free) и «Заблокировать входящие» (Pro/.netBlock).
    /// Демон/бинарь/несматченный (appPath==nil) → обе disabled с честным tooltip. Без блока исходящих.
    private func dossierPills() -> NSView {
        let path = dossierAppPath

        let finder = GlassButton(title: L("Показать в Finder"), symbol: "folder", cornerRadius: Design.Radius.chip)
        finder.onClick = { [weak self] in self?.revealDossierInFinder() }
        if path == nil { finder.isEnabled = false; finder.toolTip = L("Путь к приложению недоступен.") }

        let block = GlassButton(title: L("Заблокировать входящие"), symbol: "hand.raised.fill", accentText: true, cornerRadius: Design.Radius.chip)
        block.onClick = { [weak self] in self?.blockDossierIncoming() }
        if path == nil {
            block.isEnabled = false
            block.toolTip = L("Для системных процессов и демонов точечный блок через фаервол недоступен.")
        }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [finder, block, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: IW).isActive = true
        return row
    }

    /// Free-действие: показать .app в Finder. Всегда честно — только если путь известен.
    @objc private func revealDossierInFinder() {
        guard let path = dossierAppPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Pro-действие (.netBlock): блок ВХОДЯЩИХ через системный фаервол. Копирайт дословно из
    /// Settings.blockAppIncoming. НЕ блокирует исходящий (для этого нужен сетевой фильтр — честно).
    @objc private func blockDossierIncoming() {
        guard let path = dossierAppPath else { return }
        guard SettingsWindowController.shared.requirePro(.netBlock) else { return }   // канон из поповера (см. requirePro на makeCustomButton)
        let confirm = NSAlert()
        confirm.messageText = L("Заблокировать входящие?")
        confirm.informativeText = L("Системный фаервол запретит входящие соединения этому приложению (нужен пароль администратора). Это НЕ блокирует исходящий трафик — для этого нужен сетевой фильтр.")
        confirm.addButton(withTitle: L("Заблокировать")); confirm.addButton(withTitle: L("Отмена"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        let ok = Firewall.block(path)
        let done = NSAlert()
        done.messageText = ok ? L("Готово") : L("Не удалось")
        done.informativeText = ok ? L("Входящие для приложения заблокированы. Управление — в разделе «Фаервол».") : L("Не удалось применить правило фаервола.")
        done.runModal()
    }

    /// Фоновой сбор conns/стран для досье — СВОЙ snapshot, НЕ трогает refreshAppFlags. Корреляция
    /// по name.lowercased(). Guard openDossierName == name отбрасывает гонку «открыл A, доехал B».
    private func loadDossierConns(_ name: String) {
        guard !dossierBusy else { return }
        dossierBusy = true
        let needle = name.lowercased()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // ФОН: только lsof-сырьё (POSIX). Резолв имён (для матча по name) — на main (B1).
            let raw = Connections.rawSnapshot()
            DispatchQueue.main.async {
                guard let self = self, self.openDossierName == name else { self?.dossierBusy = false; return }
                // MAIN: AppKit-резолв, матч по name идентичен прежнему, гео (набор = 1 приложение — тривиально).
                let match = Connections.resolveOnMain(raw).first { $0.name.lowercased() == needle }
                let conns = match?.conns ?? []
                var seen = Set<String>(); var countries: [String] = []; var lan = false
                for c in conns {
                    if let g = GeoIP.label(for: c.remoteIP) { if seen.insert(g).inserted { countries.append(g) } }
                    else { lan = true }
                }
                self.dossierBusy = false
                self.dossierConns = conns
                self.dossierCountries = countries
                self.dossierHasLAN = lan
                self.dossierAppPath = match?.appPath
                self.renderAppRows(self.appsLast)        // данные доехали → перерисовать грань НА МЕСТЕ
            }
        }
    }

    /// Флип плитки «Приложения» на заднюю грань и обратно. Безопасный приём (без anchorPoint/
    /// doubleSided/полного оверта): контент-свап под кросс-фейдом + лёгкий Y-наклон 0.18рад.
    /// Motion.reduced → мгновенный rebuild + opacity 0→1 (кросс-фейд, без вращения). Высота инвариантна.
    private func flipApps(toDossier: Bool, rebuild: @escaping () -> Void) {
        guard !Motion.reduced, let layer = appsFlipHost?.layer else {
            rebuild()
            if let l = appsFlipHost?.layer {
                l.removeAllAnimations(); l.opacity = 1
                let op = CABasicAnimation(keyPath: "opacity")
                op.fromValue = 0; op.toValue = 1; op.duration = Design.Motion.durBase
                l.add(op, forKey: "dossierFade")
            }
            if toDossier { focusDossierBack() }
            return
        }
        let dir: CGFloat = toDossier ? 1 : -1
        let dur = Design.Motion.durFast            // 0.18 на фазу, Σ 0.36
        var persp = CATransform3DIdentity          // лёгкая перспектива — наклон читается объёмно
        persp.m34 = -1.0 / 600
        layer.sublayerTransform = persp
        layer.removeAllAnimations()

        // фаза 1: 0 → dir*0.18, opacity 1→0
        let rot1 = CABasicAnimation(keyPath: "transform.rotation.y")
        rot1.fromValue = 0; rot1.toValue = dir * 0.18
        rot1.timingFunction = Design.Motion.easeOut
        let op1 = CABasicAnimation(keyPath: "opacity")
        op1.fromValue = 1; op1.toValue = 0
        op1.timingFunction = Design.Motion.easeOut
        let g1 = CAAnimationGroup()
        g1.animations = [rot1, op1]; g1.duration = dur
        g1.fillMode = .forwards; g1.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self = self, let layer = self.appsFlipHost?.layer else { return }
            layer.removeAnimation(forKey: "dossierFlip1")   // ремень: прерванный флип не оставляет forwards-фил
            rebuild()
            // мгновенно перекинуть на зеркальный угол (грань уже подменена), фаза 2 вернёт к 0
            layer.transform = CATransform3DMakeRotation(-dir * 0.18, 0, 1, 0)
            layer.opacity = 0
            let rot2 = CABasicAnimation(keyPath: "transform.rotation.y")
            rot2.fromValue = -dir * 0.18; rot2.toValue = 0
            rot2.timingFunction = Design.Motion.easeIn
            let op2 = CABasicAnimation(keyPath: "opacity")
            op2.fromValue = 0; op2.toValue = 1
            op2.timingFunction = Design.Motion.easeIn
            let g2 = CAAnimationGroup()
            g2.animations = [rot2, op2]; g2.duration = dur
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                guard let layer = self?.appsFlipHost?.layer else { return }
                // КРИТИЧЕСКИЙ ФИКС «пустой экран после клика по приложению»: g1 висела с
                // fillMode=.forwards + isRemovedOnCompletion=false; когда g2 само-удалялась,
                // g1 снова клампила presentation-opacity слоя в 0 НАВСЕГДА (model=1, поэтому
                // код «не видел» проблему). Снимаем фил явно — как "close" в playOpenAnimation.
                layer.removeAnimation(forKey: "dossierFlip1")
                layer.transform = CATransform3DIdentity
                layer.sublayerTransform = CATransform3DIdentity   // Ж7: сбросить остаточную m34-перспективу (не копить грязь состояния)
                layer.opacity = 1
                if toDossier { self?.focusDossierBack() }
            }
            layer.add(g2, forKey: "dossierFlip2")
            layer.transform = CATransform3DIdentity
            layer.opacity = 1
            CATransaction.commit()
        }
        layer.add(g1, forKey: "dossierFlip1")
        CATransaction.commit()
    }

    /// VoiceOver: фокус на назад-кнопку при открытии досье.
    private func focusDossierBack() {
        NSAccessibility.post(element: dossierBackButton as Any, notification: .focusedUIElementChanged)
    }

    /// Нейтральный значок системного процесса/демона (нет .app-иконки): спокойный заполненный
    /// SF-глиф на стеклянной плитке (controlFill, tertiary tint) вместо пустого пунктирного контура.
    /// Читается как «системный процесс», а не «сломанная иконка». Глиф подбираем по имени процесса.
    private func systemProcessGlyph(_ proc: String) -> NSView {
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.backgroundColor = Design.Color.controlFill(isDark).cgColor
        tile.layer?.cornerRadius = Design.Radius.appIcon   // Ж1: единый токен (был хардкод 5)
        tile.layer?.cornerCurve = .continuous
        tile.translatesAutoresizingMaskIntoConstraints = false

        let glyph = NSImageView()
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        glyph.image = NSImage(systemSymbolName: systemProcessSymbol(proc), accessibilityDescription: L("Системный процесс"))?
            .withSymbolConfiguration(cfg)
        glyph.contentTintColor = .tertiaryLabelColor
        glyph.imageScaling = .scaleProportionallyDown
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        tile.toolTip = L("Системный процесс")
        return tile
    }

    /// Подбор нейтрального SF-символа по имени процесса: рендеры/оконный сервер → дисплей,
    /// сеть/конфиг → cpu, хелперы → terminal; всё прочее → шестерёнка (общий «системный»).
    private func systemProcessSymbol(_ proc: String) -> String {
        let n = proc.lowercased()
        if n.contains("window") || n.contains("display") || n.contains("render") { return "display" }
        if n.contains("helper") || n.contains("agent") { return "terminal" }
        if n.contains("config") || n.contains("network") || n.contains("net") { return "cpu" }
        return "gearshape.fill"
    }

    /// Маркер «есть соединения, но все — локальная сеть» (рисуем глоб вместо флага страны).
    private static let lanGlobe = "\u{1F310}"

    /// Освежает гео-флаги лидерборда: lsof-снимок в фоне (НЕ на main), коррелируем приложение
    /// с его соединениями по имени, берём самую частую не-LAN страну-назначение. Готово →
    /// если карта изменилась, перерисовываем строки (флаги «доедут» через кадр-другой).
    private func refreshAppFlags() {
        guard !appFlagsBusy else { return }
        appFlagsBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // ФОН: lsof-сырьё (POSIX) + гео по IP (GeoIP чистый). AppKit-резолв имён — на main (B1).
            let raw = Connections.rawSnapshot()
            var codeByIP: [String: String?] = [:]
            for rp in raw { for c in rp.conns where codeByIP[c.remoteIP] == nil {
                codeByIP[c.remoteIP] = GeoIP.countryCode(for: c.remoteIP)
            } }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.appFlagsBusy = false
                // MAIN: резолвим имена/иконки (безопасно), затем считаем гео из фон-карты codeByIP.
                var map: [String: String] = [:]
                var codesByApp: [String: Set<String>] = [:]   // nameLower → все ISO-коды за снимок (для AppSession)
                var netApps: [FirstConnAlert.NetApp] = []     // приложения с внешним соединением (для first-conn алерта)
                let resolved = Connections.resolveOnMain(raw)
                let now = Date()
                for app in resolved {
                    var tally: [String: Int] = [:]     // код страны → счётчик соединений
                    var hadConn = false
                    let key = app.name.lowercased()
                    let ident = app.appPath ?? app.name           // стабильная тождественность (как в радаре/леджере)
                    var rep: (label: String, code: String?)? = nil   // представительный внешний endpoint (ip:port)
                    for c in app.conns {
                        hadConn = true
                        let code = codeByIP[c.remoteIP] ?? nil
                        AppSession.noteConnection(appId: ident, app: app.name, endpoint: c.label, code: code, now: now)
                        if let code = code {
                            tally[code, default: 0] += 1
                            codesByApp[key, default: []].insert(code)
                        }
                        // Для first-conn: предпочитаем публичный endpoint (есть страна), иначе первый маршрутизируемый.
                        if FirstConnAlert.isRoutable(c.remoteIP), rep == nil || (rep?.code == nil && code != nil) {
                            rep = (c.label, code)
                        }
                    }
                    if let rep = rep {
                        netApps.append(FirstConnAlert.NetApp(id: ident, name: app.name, endpoint: rep.label, code: rep.code))
                    }
                    if let top = tally.max(by: { $0.value < $1.value })?.key {
                        map[key] = GeoIP.flag(top)              // самая частая страна-назначение
                    } else if hadConn {
                        map[key] = PopoverController.lanGlobe   // соединения есть, но только LAN/неизвестно
                    }
                }
                // Сессионное множество стран-назначений — коммитим на main (AppSession не thread-safe).
                for (key, codes) in codesByApp { AppSession.addCountries(key, codes: codes) }
                // Радар 2.0: заметить новое приложение в сети (наблюдение). Дешёвый выход, если фича выключена.
                FirstConnAlert.shared.consider(netApps, now: now)
                // История числа соединений за сессию (спарклайн радара) — толкаем ВСЕГДА, даже с закрытым
                // поповером: тренд копится непрерывно. total = уникальные ip:port по всем приложениям.
                AppSession.pushConnTotal(resolved.reduce(0) { $0 + $1.conns.count })
                // Радар «Приватности» — из ТОГО ЖЕ снимка (один lsof на оба). Рендерим только когда
                // поповер на экране (view.window != nil) — вне вкладки слои спят (см. viewDidMoveToWindow).
                if self.view.window != nil { self.privacyView.update(apps: resolved, codeByIP: codeByIP); self.mediaChipRefresh?() }
                guard map != self.appCountryFlags else { return }   // без изменений — не перерисовываем
                self.appCountryFlags = map
                self.renderAppRows(self.appsLast)   // флаги доехали → перерисовать строки из кэша
            }
        }
    }

    @objc private func refreshApps() {
        PowerInfo.topApps { [weak self] in self?.updateApps($0) }
    }

    @objc private func openSettings() {
        view.window?.close()                      // закрыть поповер
        SettingsWindowController.shared.open()
    }

    /// Аффорданс «Настроить поповер» из шапки (V3): открыть Настройки на разделе поповера
    /// (прозрачность фона / набор и порядок модулей / плотность / пресеты).
    @objc private func openPopoverSettings() {
        view.window?.close()
        SettingsWindowController.shared.open()
        SettingsWindowController.shared.selectByName("popover")
    }


    /// Эффективный потолок заряда: «Парусный» → верхний порог; «Лимит» → chargeLimit (<100).
    /// nil — лимита нет. Кольцо получает тик-метку, чип показывает «Лимит N%» (иначе скрыт).
    private func applyChargeLimit() {
        let limit: Int? = SettingsStore.chargeMode == "sail"
            ? SettingsStore.sailUpper
            : (SettingsStore.chargeLimit < 100 ? SettingsStore.chargeLimit : nil)
        ring.setLimit(limit)                            // тик-метка лимита на кольце; потолок теперь несёт дорожка заряда
    }

    @objc private func showInstall() {
        let alert = NSAlert()
        alert.messageText = L("Установить хелпер CPU/GPU/DRAM")
        alert.informativeText = L("Поставит небольшой root-демон (powermetrics), который раз в секунду снимает потребление по компонентам. Понадобится пароль администратора — один раз, через системный диалог.")
        alert.addButton(withTitle: L("Установить"))
        alert.addButton(withTitle: L("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let r = HelperInstall.runPrivileged("install-helper.sh", prompt: L("Kelvin устанавливает хелпер CPU/GPU/DRAM"))
        guard HelperInstall.presentFailureIfNeeded(r, title: L("Не удалось установить хелпер")) else { return }
        // ПРОВЕРКА: скрипт отработал — но реально ли демон отдаёт данные? Ждём свежий замер в ФОНЕ,
        // чтобы не вешать main на ~3.2с (beachball) между двумя алертами.
        DispatchQueue.global(qos: .userInitiated).async {
            var fresh = false
            for _ in 0..<8 { if PowerInfo.components().fresh { fresh = true; break }; Thread.sleep(forTimeInterval: 0.4) }
            DispatchQueue.main.async {
                let done = NSAlert()
                done.messageText = fresh ? L("Готово — хелпер работает") : L("Установлено, но данных пока нет")
                done.informativeText = fresh
                    ? L("Раздел «Питание» (ватты CPU/GPU/DRAM) появился во вкладке «Железо».")
                    : L("Демон поставлен, но пока молчит. Иногда нужно несколько секунд или перезапуск Mac; если не появится — переустанови.")
                done.runModal()
            }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let popover = NSPopover()
    private var popoverAnchor: NSWindow?     // неподвижный якорь поповера (фикс «съезда» в полноэкранном)
    private var postedMenuTracking = false   // послан ли begin-меню-трекинг (fullscreen-путь) — снять на закрытии
    let controller = PopoverController()
    var history: [Double] = []
    var tickTimer: Timer?
    var appsTimer: Timer?
    var idleTimer: Timer?
    let usbWatch = USBWatch()             // живой USB-ридер (lifetime-инстанс, рег. при старте)
    var idleDimmed = false
    var savedBacklight: Float = -1
    var nightTick = 0
    private let hardwareQueue = DispatchQueue(label: "com.trykelvin.kelvin.hardware",
                                              qos: .userInitiated)
    private var hardwareTickInFlight = false
    private var lastMenuTitle = ""        // чтобы не переустанавливать заголовок строки без изменений
    private var lastMenuImgKey = ""

    /// Мгновенно применить настройки строки меню: сброс кэша рендера → безусловная перерисовка
    /// СЕЙЧАС, не дожидаясь тика/смены сигнатуры. Раньше часть настроек «Общих» (стиль иконок
    /// Kelvin↔Системные в необъединённом виде и др.) не входила в триггер перерисовки и применялась
    /// только после перезапуска приложения. Зовётся наблюдателем BMMenuBarChanged.
    func refreshMenuBarNow() {
        lastMenuTitle = ""; lastMenuImgKey = ""
        let b = BatteryReader.read() ?? .absent
        let energy = menuBarNeedsEnergy ? EnergyModel.snapshot() : EnergySnapshot()
        updateMenuBar(b, energy)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Hardening.denyDebugger()              // релиз-only: затруднить lldb-attach к гейту лицензии
        if let btn = statusItem.button {
            btn.imagePosition = .imageLeading
            btn.title = " …"
            btn.action = #selector(statusClick)
            btn.target = self
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
            btn.wantsLayer = true                 // для лёгкой вспышки при автозамене
        }
        popover.behavior = .transient
        popover.contentViewController = controller
        buildMainMenu()                       // горячие клавиши ⌘C/⌘V/⌘Z в полях + ⌘,/⌘W/⌘Q в окнах
        AlertsEngine.shared.start()           // делегат Центра уведомлений (баннеры показываются и поверх активного приложения)
        // Радар 2.0: хук открытия радара из баннера «новое приложение в сети».
        FirstConnAlert.shared.showRadar = { [weak self] in self?.openRadarFromAlert() }

        tick()
        controller.updateApps([])
        refreshApps()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        appsTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in self?.refreshApps() }
        RunLoop.main.add(tickTimer!, forMode: .common)
        RunLoop.main.add(appsTimer!, forMode: .common)   // иначе рефреш приложений вставал во время трекинга меню/скролла

        // пересборка поповера при изменении его настроек (секция «Поповер»)
        NotificationCenter.default.addObserver(forName: Notification.Name("BMPopoverChanged"), object: nil, queue: .main) { [weak self] _ in
            guard let self, self.controller.isViewLoaded else { return }
            self.controller.buildModules()
        }

        // мгновенное применение настроек строки меню из секции «Общие» (без перезапуска)
        NotificationCenter.default.addObserver(forName: Notification.Name("BMMenuBarChanged"), object: nil, queue: .main) { [weak self] _ in
            self?.refreshMenuBarNow()
        }

        // авто-гашение подсветки клавы при простое
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.checkIdleBacklight() }

        // E1 — живой USB: регистрируем при СТАРТЕ (не при открытии поповера), чтобы счётчик был
        // верен в момент открытия. Колбэк на main: connect/disconnect → тик-пульс обода + сурфейс.
        usbWatch.onChange = { [weak self] ev in
            guard let self else { return }
            switch ev {
            case .connected:    self.controller.pulseUSB(connect: true)
            case .disconnected: self.controller.pulseUSB(connect: false)
            case .initialSync:  break   // стартовый засев — без пульса, только сурфейс
            }
            let name = self.usbWatch.devices.first?.name
            self.controller.setUSBCount(self.usbWatch.count, name: name)
        }
        usbWatch.start()

        // авто-переключатель раскладки + сниппеты — но платные авто-фичи поднимаем только при Pro
        LangSwitcher.shared.hotkeyKeycode = CGKeyCode(SettingsStore.langHotkey)
        LangSwitcher.shared.snippets = SettingsStore.parseSnippets(SettingsStore.snippetsRaw)
        LangSwitcher.shared.onFeedback = { [weak self] fb in self?.handleLangFeedback(fb) }
        applyProEntitlements()

        // Глобальный хоткей вызова поповера (Carbon, без Универсального доступа). Дефолт ⌥⌘B вкл.
        // Даёт вход в поповер поверх fullscreen, где иконка строки меню недостижима.
        GlobalHotkey.shared.onPressed = { [weak self] in
            self?.togglePopover(fromHotkey: true)        // колбэк уже на main (DispatchQueue.main.async внутри GlobalHotkey)
        }
        GlobalHotkey.shared.apply(
            enabled: SettingsStore.popoverHotkeyEnabled,
            keyCode: SettingsStore.popoverHotkeyKeyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(SettingsStore.popoverHotkeyMods)))

        // разовый перенос автозапуска со старого LaunchAgent на SMAppService
        // (только у установленного в /Applications приложения, не в dev-сборке)
        if LoginItem.available, !UserDefaults.standard.bool(forKey: "loginItem.migrated"),
           Bundle.main.bundlePath.hasPrefix("/Applications/") {
            LoginItem.set(true)
            UserDefaults.standard.set(true, forKey: "loginItem.migrated")
        }
        Licensing.shared.revalidate()        // тихо обновляем офлайн-grace, если есть лицензия

        // Инициализация системы отчётов о сбоях: отмечаем запуск в breadcrumbs
        CrashBreadcrumbStore.shared.appStarted()
        
        // Проверка наличия crash reports после предыдущего запуска
        checkForCrashReports()

        // welcome при первом запуске (но не во время скриншот-режимов)
        let env = ProcessInfo.processInfo.environment
        let screenshotMode = env["BM_SETTINGS"] != nil || env["BM_SHOWCASE"] != nil || env["BM_AUTOSHOW"] != nil
        if env["BM_ONBOARD"] != nil || (OnboardingWindowController.shouldShow && !screenshotMode) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                OnboardingWindowController.shared.present()
                if let w = OnboardingWindowController.shared.window { print("ONBOARD_WIN \(w.windowNumber)"); fflush(stdout) }
            }
        }
        // (Прощальный оффер по окончании триала УБРАН — коммерция снята, приложение бесплатно.
        //  presentTrialEnded() сохранён спящим для возможной реактивации.)
        if !screenshotMode { Updater.checkOnLaunch() }   // тихая проверка обновлений (не чаще раза в сутки)

        // прямое открытие настроек (для скриншот-проверки)
        if ProcessInfo.processInfo.environment["BM_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SettingsWindowController.shared.open()
                if let sec = ProcessInfo.processInfo.environment["BM_SETTINGS"], sec != "1" {
                    SettingsWindowController.shared.selectByName(sec)
                }
                if let w = SettingsWindowController.shared.window {
                    if ProcessInfo.processInfo.environment["BM_LIGHT"] != nil {
                        w.appearance = NSAppearance(named: .aqua)
                    }
                    print("SETTINGS_WIN \(w.windowNumber)")
                    fflush(stdout)
                }
            }
        }

        // витрина: весь UI в обычном окне (для экранного скриншота, т.к. слои/анимация
        // не видны в офскрин-рендере поповера).
        if ProcessInfo.processInfo.environment["BM_SHOWCASE"] != nil {
            let v = controller.view
            if ProcessInfo.processInfo.environment["BM_LIGHT"] != nil {
                v.appearance = NSAppearance(named: .aqua)
            }
            v.layoutSubtreeIfNeeded()
            let sz = v.fittingSize
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: max(sz.width, 300), height: max(sz.height, 500)),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
            win.title = "Kelvin"
            win.contentView = v
            win.center()
            win.level = .floating
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            // печатаем номер окна для screencapture -l (надёжно даже при перекрытии)
            print("SHOWCASE_WIN \(win.windowNumber)")
            fflush(stdout)
        }

        // отладочный автопоказ поповера для скриншот-проверки
        if ProcessInfo.processInfo.environment["BM_AUTOSHOW"] != nil {
            popover.behavior = .applicationDefined   // не закрывать при потере фокуса (для скриншота)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.togglePopover()
                if let w = self?.popover.contentViewController?.view.window { print("POPOVER_WIN \(w.windowNumber)"); fflush(stdout) }
                guard let path = ProcessInfo.processInfo.environment["BM_RENDER"] else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    guard let v = self?.controller.view else { return }
                    v.layoutSubtreeIfNeeded()
                    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                    v.cacheDisplay(in: v.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
        }
    }

    /// Рисованная батарея-template для строки меню (адаптируется к свету/тьме).
    /// Фирменный глиф меню-бара — вертикальный термо-столбик (а не клон Apple-батарейки):
    /// стеклянная капсула + колба, «ртуть» = уровень заряда, шкала-риски справа, при зарядке — молния-вырез.
    /// Template (монохром): узнаётся формой, система тинтует под свет/тьму/подсветку.
    /// Главная иконка строки меню по выбранному стилю (термометр / батарея) — обе charge-aware.
    func menuBarIcon(charge: Int, charging: Bool) -> NSImage {
        SettingsStore.mainIconStyle == "battery"
            ? menuBarBatteryIcon(charge: charge, charging: charging)
            : menuBarThermometerIcon(charge: charge, charging: charging)
    }

    /// Charge-aware батарея (горизонтальная): уровень заливки = заряд, молния-вырез при зарядке.
    private func menuBarBatteryIcon(charge: Int, charging: Bool) -> NSImage {
        let w: CGFloat = 16, h: CGFloat = 11
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let body = NSRect(x: 0.7, y: 1.6, width: w - 3.2, height: h - 3.2)
            NSColor.black.setStroke()
            let outline = NSBezierPath(roundedRect: body, xRadius: 2.2, yRadius: 2.2); outline.lineWidth = 1.1; outline.stroke()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: body.maxX + 0.6, y: h/2 - 1.7, width: 1.5, height: 3.4),
                         xRadius: 0.7, yRadius: 0.7).fill()                      // клемма
            let inset = body.insetBy(dx: 1.7, dy: 1.7)
            let fillW = inset.width * CGFloat(max(0, min(100, charge))) / 100
            if fillW > 0.5 {
                NSBezierPath(roundedRect: NSRect(x: inset.minX, y: inset.minY, width: fillW, height: inset.height),
                             xRadius: 1.0, yRadius: 1.0).fill()
            }
            if charging {                                                        // молния-вырез
                NSGraphicsContext.current?.compositingOperation = .clear
                let bx = body.midX, top = body.maxY - 1.1, bot = body.minY + 1.1, mid = body.midY
                let bolt = NSBezierPath()
                bolt.move(to: NSPoint(x: bx + 1.5, y: top))
                bolt.line(to: NSPoint(x: bx - 1.7, y: mid + 0.2))
                bolt.line(to: NSPoint(x: bx + 0.1, y: mid + 0.2))
                bolt.line(to: NSPoint(x: bx - 1.5, y: bot))
                bolt.line(to: NSPoint(x: bx + 1.9, y: mid - 0.2))
                bolt.line(to: NSPoint(x: bx + 0.1, y: mid - 0.2))
                bolt.close(); bolt.fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private func menuBarThermometerIcon(charge: Int, charging: Bool) -> NSImage {
        let w: CGFloat = 13, h: CGFloat = 16
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let cx: CGFloat = 4.8
            let stemW: CGFloat = 3.8, bulbR: CGFloat = 3.0
            let bulbCY: CGFloat = bulbR + 0.7                 // колба у низа
            let stemTop: CGFloat = h - 1.0

            // стекло: капсула-стержень + колба (обводка)
            let glass = NSBezierPath(roundedRect: NSRect(x: cx - stemW/2, y: bulbCY, width: stemW, height: stemTop - bulbCY),
                                     xRadius: stemW/2, yRadius: stemW/2)
            glass.appendOval(in: NSRect(x: cx - bulbR, y: bulbCY - bulbR, width: bulbR*2, height: bulbR*2))
            NSColor.black.setStroke(); glass.lineWidth = 1.1; glass.stroke()

            // ртуть: колба + столбик до уровня заряда
            let innerW: CGFloat = stemW - 1.8
            let colTopMax = stemTop - innerW/2
            let level = bulbCY + (colTopMax - bulbCY) * CGFloat(max(0, min(100, charge))) / 100
            let merc = NSBezierPath(roundedRect: NSRect(x: cx - innerW/2, y: bulbCY, width: innerW, height: max(0, level - bulbCY)),
                                    xRadius: innerW/2, yRadius: innerW/2)
            merc.appendOval(in: NSRect(x: cx - (bulbR - 0.9), y: bulbCY - (bulbR - 0.9), width: (bulbR - 0.9)*2, height: (bulbR - 0.9)*2))
            NSColor.black.setFill(); merc.fill()

            // шкала-риски справа
            let ticks = NSBezierPath(); ticks.lineWidth = 0.9; ticks.lineCapStyle = .round
            NSColor.black.setStroke()
            for i in 0..<3 {
                let ty = bulbCY + bulbR + 1.4 + CGFloat(i) * ((stemTop - bulbCY - bulbR - 2.2) / 2)
                ticks.move(to: NSPoint(x: cx + stemW/2 + 1.4, y: ty))
                ticks.line(to: NSPoint(x: cx + stemW/2 + 3.1, y: ty))
            }
            ticks.stroke()

            if charging {                                    // молния-вырез в столбике
                NSGraphicsContext.current?.compositingOperation = .clear
                let bx = cx, top = stemTop - 1.0, bot = bulbCY + bulbR - 0.4, mid = (top + bot)/2
                let bolt = NSBezierPath()
                bolt.move(to: NSPoint(x: bx + 1.3, y: top))
                bolt.line(to: NSPoint(x: bx - 1.5, y: mid + 0.3))
                bolt.line(to: NSPoint(x: bx + 0.1, y: mid + 0.3))
                bolt.line(to: NSPoint(x: bx - 1.3, y: bot))
                bolt.line(to: NSPoint(x: bx + 1.7, y: mid - 0.3))
                bolt.line(to: NSPoint(x: bx + 0.1, y: mid - 0.3))
                bolt.close(); bolt.fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Обновляет иконку строки меню по выбранному режиму (battery / cpu / ram).
    /// Основной показатель строки меню (строка + иконка + ключ иконки) — общий источник для
    /// классического и объединённого видов, чтобы они не расходились.
    private func menuBarPrimaryToken(_ b: BatteryInfo, _ e: EnergySnapshot) -> (token: String, image: NSImage, imgKey: String) {
        switch SettingsStore.menuBarMode {
        case "cpu":
            let v = SystemUsage.shared.cpu()
            return (figPad(String(format: "%.0f%%", v * 100), 4), usageBarImage(SystemUsage.shared.cpuHistory, value: v), "graph")
        case "ram":
            let v = SystemUsage.shared.ram()
            return (figPad(String(format: "%.0f%%", v * 100), 4), usageBarImage(SystemUsage.shared.ramHistory, value: v), "graph")
        default:
            if b.present {
                let token = figPad(SettingsStore.menuBarShowWatts ? String(format: "%.0fW", e.systemWatts > 0.1 ? e.systemWatts : b.watts) : "\(b.charge)%", 4)
                return (token, menuBarIcon(charge: b.charge, charging: b.charging), "b\(b.charge)\(b.charging)\(SettingsStore.mainIconStyle)")
            }
            // десктоп без АКБ — вместо фейкового заряда показываем загрузку CPU
            let v = SystemUsage.shared.cpu()
            return (figPad(String(format: "%.0f%%", v * 100), 4), usageBarImage(SystemUsage.shared.cpuHistory, value: v), "graph")
        }
    }

    private func updateMenuBar(_ b: BatteryInfo, _ energy: EnergySnapshot) {
        guard let btn = statusItem.button else { return }
        let prim = menuBarPrimaryToken(b, energy)
        // Объединённый вид: рисуем всё одной template-картинкой (моно, без семантического цвета —
        // зато ОС корректно тинтует для светлой/тёмной/подсветки). Перестраиваем только при смене подписи.
        if SettingsStore.menuBarCombined {
            let icons = SettingsStore.menuBarExtraIcons
            var cells: [(id: String?, token: String)] = [(menuBarPrimaryGlyphID(b), prim.token)]
            for id in SettingsStore.menuBarExtras.prefix(SettingsStore.menuBarExtraMax) {
                if let t = menuBarExtraToken(id, b, energy) { cells.append((id, t)) }
            }
            // подпись включает флаг иконок И стиль — переключение обязано перерисовать картинку
            let sig = "combined|\(icons ? "i" : "t")|\(SettingsStore.menuBarIconStyle)|" + cells.map { $0.token }.joined(separator: "|")
            if sig != lastMenuTitle {
                lastMenuTitle = sig
                lastMenuImgKey = "combined"
                btn.image = combinedMenuImage(cells, icons: icons)
                btn.imagePosition = .imageOnly
                btn.attributedTitle = NSAttributedString(string: "")
            }
            let human = menuBarTooltip(b, energy)
            btn.toolTip = human
            btn.setAccessibilityTitle(human)
            return
        }
        let primary = prim.token
        let image = prim.image
        let imgKey = prim.imgKey
        // картинка фикс-ширины (графику обновляем каждый тик; батарейку — лишь при смене заряда)
        if imgKey == "graph" || imgKey != lastMenuImgKey {
            lastMenuImgKey = imgKey; btn.image = image; btn.imagePosition = .imageLeading
        }
        // доп-показатели (курируемые, с лимитом). Ширина каждого токена СТАБИЛЬНА (фигурные пробелы +
        // моноширинные цифры), а заголовок переустанавливаем лишь при реальном изменении — поэтому
        // строка меню не «дёргается» при смене значений (особенно заметно в полноэкранном режиме).
        let extras = SettingsStore.menuBarExtras.prefix(SettingsStore.menuBarExtraMax)
            .compactMap { menuBarExtraToken($0, b, energy) }
        let parts = [primary] + extras
        let sig = parts.joined(separator: "|")
        if sig != lastMenuTitle { lastMenuTitle = sig; btn.attributedTitle = menuBarTitle(parts) }
        let human = menuBarTooltip(b, energy)
        btn.toolTip = human                            // живая подсказка при наведении
        btn.setAccessibilityTitle(human)               // VoiceOver: человеческая фраза вместо «42%/18W/56°»
    }
    /// Человеческая сводка для подсказки на иконке: заряд/состояние/время/ватты.
    private func menuBarTooltip(_ b: BatteryInfo, _ e: EnergySnapshot) -> String {
        let watt = e.systemWatts > 0.1 ? e.systemWatts : b.watts
        let w = "\(Int(watt.rounded())) \(L("Вт"))"
        let hint = " · \(L("правый клик: инструменты"))"
        guard b.present else { return "Kelvin · \(L("без батареи")) · \(w)\(hint)" }
        let state = b.charging ? L("зарядка") : (b.external ? L("от сети") : L("от батареи"))
        let mins = b.charging ? b.timeToFull : b.timeToEmpty
        let time = (mins > 0 && mins < 1200) ? " · \(b.charging ? L("до полного") : L("осталось")) \(mins/60):\(String(format: "%02d", mins % 60))" : ""
        return "Kelvin · \(b.charge)% (\(state)) · \(w)\(time)\(hint)"
    }
    /// Дополняет строку ведущими фигурными пробелами (ширина цифры) до стабильной ширины.
    private func figPad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : String(repeating: "\u{2007}", count: width - s.count) + s
    }
    /// Формат времени по локали (j → 12/24 ч автоматически), кэшируем — DateFormatter дорог в создании.
    private lazy var clockFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.setLocalizedDateFormatFromTemplate("jmm"); return f
    }()
    /// Короткая дата по локали: день недели + число + месяц («Чт 26 июн»).
    private lazy var dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = .current; f.setLocalizedDateFormatFromTemplate("EEEEEEdMMM"); return f
    }()
    /// Один доп-показатель строки меню в компактном виде (стабильной ширины), или nil если данных нет.
    private func menuBarExtraToken(_ id: String, _ b: BatteryInfo, _ e: EnergySnapshot) -> String? {
        switch id {
        case "watts":   let w = e.systemWatts > 0.1 ? e.systemWatts : b.watts; return figPad(String(format: "%.0fW", w), 4)
        case "cputemp": return e.cpuTemp.map { figPad(String(format: "%.0f°", $0), 4) }
        case "gputemp": return e.gpuTemp.map { figPad(String(format: "%.0f° G", $0), 6) }
        case "fan":     return e.fans.first.map { figPad(String(format: "%.1fk", $0 / 1000), 4) }
        case "cpu":     return figPad(String(format: "%.0f%% C", SystemUsage.shared.cpu() * 100), 6)
        case "ram":     return figPad(String(format: "%.0f%% R", SystemUsage.shared.ram() * 100), 6)
        case "net":     let nu = NetUsage.shared.sample(); return "↓\(NetUsage.fmtRate(nu.down)) ↑\(NetUsage.fmtRate(nu.up))"
        case "diskio":  let d = DiskUsage.shared.sample(); return "↓\(NetUsage.fmtRate(d.read)) ↑\(NetUsage.fmtRate(d.write))"
        case "diskfree": return DiskInfo.capacity().map { figPad(String(format: "%.0fG", Double($0.free) / 1e9), 5) }
        case "btbatt":  return BTPeripherals.cachedWorst().map { figPad(String(format: "%d%%", $0), 4) }
        case "clock":   return clockFmt.string(from: Date())
        case "date":    return dateFmt.string(from: Date())
        default:        return nil
        }
    }
    /// Собирает заголовок строки меню: моноширинные цифры, разделитель « · » приглушён.
    private func menuBarTitle(_ parts: [String]) -> NSAttributedString {
        let font = Design.Font.numericBody
        let s = NSMutableAttributedString(string: " ", attributes: [.font: font])
        for (i, p) in parts.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "  ·  ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])) }
            s.append(NSAttributedString(string: p, attributes: [.font: font]))
        }
        return s
    }
    /// Мини-график загрузки для строки меню (вертикальные бары, цвет по нагрузке).
    private func usageBarImage(_ history: [Double], value: Double) -> NSImage {
        let w: CGFloat = 30, h: CGFloat = 15
        let color: NSColor = value > 0.85 ? .systemRed : (value > 0.6 ? .systemOrange : .systemGreen)
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            let bars = Array(history.suffix(15))
            guard !bars.isEmpty else { return true }
            let bw = w / 15
            for (i, v) in bars.enumerated() {
                let bh = max(1.5, CGFloat(v) * (h - 2))
                let r = NSRect(x: CGFloat(i) * bw + 0.6, y: 1, width: bw - 1.2, height: bh)
                color.withAlphaComponent(0.35 + 0.55 * CGFloat(v)).setFill()
                NSBezierPath(roundedRect: r, xRadius: 0.8, yRadius: 0.8).fill()
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    /// Курируемые SF-глифы для показателей строки меню. Подобраны так, чтобы читаться при ~13pt
    /// в моно-template-картинке (тонкие глифы вроде «wind» отброшены в пользу плотных и узнаваемых).
    private static let menuBarGlyphs: [String: String] = [
        "battery":  "battery.100",
        "watts":    "bolt.fill",
        "cputemp":  "thermometer",
        "gputemp":  "thermometer",
        "fan":      "fanblades.fill",
        "cpu":      "cpu",
        "ram":      "memorychip",
        "net":      "arrow.up.arrow.down",
        "diskio":   "internaldrive",
        "diskfree": "internaldrive",
        "btbatt":   "wave.3.right",
        "clock":    "clock",
        "date":     "calendar",
    ]
    /// Глиф основной ячейки объединённого вида — по текущему режиму строки меню.
    private func menuBarPrimaryGlyphID(_ b: BatteryInfo) -> String? {
        switch SettingsStore.menuBarMode {
        case "cpu": return "cpu"
        case "ram": return "ram"
        default:    return b.present ? "battery" : "cpu"
        }
    }
    /// Убирает дублирующий хвостовой литер-суффикс (« G»/« C»/« R») когда глиф уже опознаёт метрику.
    private func stripGlyphSuffix(_ id: String, _ token: String) -> String {
        let drop: [String: String] = ["gputemp": " G", "cpu": " C", "ram": " R"]
        guard let suff = drop[id], token.hasSuffix(suff) else { return token }
        return String(token.dropLast(suff.count))
    }
    /// Шаблонная картинка SF-символа фиксированной высоты для строки меню (моно-template-тинт).
    private func menuBarGlyphImage(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return nil }
        img.isTemplate = true
        return img
    }
    /// Глиф показателя по выбранному стилю: kelvin (фирменный векторный) | system (SF Symbol).
    private func menuBarGlyph(forID id: String) -> NSImage? {
        if SettingsStore.menuBarIconStyle == "kelvin", let img = KelvinGlyph.image(id, size: 13) { return img }
        guard let name = Self.menuBarGlyphs[id] else { return nil }
        return menuBarGlyphImage(name)
    }

    /// Объединённый вид строки меню: основной показатель + доп-показатели как ячейки с тонкими
    /// разделителями в одной template-картинке (~22pt). isTemplate=true → ОС тинтует под светлую/тёмную/подсветку.
    /// Ширина каждой ячейки фиксирована (моно-цифры + бюджет по максимально-широкой строке), поэтому 9→100,
    /// 3-значные температуры и ↓1.2M никогда не «дёргают» строку. Цена: теряется зелёный/оранжевый/красный
    /// цвет нагрузки — корректный размен ради чёткого OS-тинта.
    /// При icons=true перед значением рисуется ведущий SF-глиф; ширину ячейки расширяем РОВНО на измеренную
    /// ширину глифа+зазор, чтобы инвариант «строка не дёргается» сохранялся.
    private func combinedMenuImage(_ cells: [(id: String?, token: String)], icons: Bool) -> NSImage {
        let font = Design.Font.mono(13, .semibold)
        let h: CGFloat = 22, padX: CGFloat = 5, gap: CGFloat = 8, iconGap: CGFloat = 3
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        // глиф ячейки (если иконки включены и для id есть символ) + его картинка/ширина
        func glyph(_ id: String?) -> (img: NSImage, w: CGFloat)? {
            guard icons, let id = id, let img = menuBarGlyph(forID: id) else { return nil }
            return (img, ceil(img.size.width))
        }
        // текст ячейки (со снятым дубль-суффиксом, если перед ним будет глиф)
        func text(_ c: (id: String?, token: String)) -> String {
            (icons && c.id != nil && Self.menuBarGlyphs[c.id!] != nil)
                ? stripGlyphSuffix(c.id!, c.token) : c.token
        }
        // фикс-ширина ячейки: бюджет по более широкой из (значение, эталон ширины токена этой длины) + глиф
        func textWidth(_ s: String) -> CGFloat {
            let probe = String(repeating: "0", count: max(s.count, 4))   // токены уже figPad-нуты под свою ширину
            let a = (s as NSString).size(withAttributes: attrs).width
            let b = (probe as NSString).size(withAttributes: attrs).width
            return ceil(max(a, b))
        }
        let glyphs = cells.map { glyph($0.id) }
        let texts = cells.map(text)
        let tWidths = texts.map(textWidth)
        // полная ширина ячейки = глиф + зазор + текст (если глиф есть)
        let widths: [CGFloat] = zip(tWidths, glyphs).map { tw, g in g == nil ? tw : g!.w + iconGap + tw }
        let total = padX * 2 + widths.reduce(0, +) + gap * CGFloat(max(0, cells.count - 1))
        let para = NSMutableParagraphStyle(); para.alignment = .center
        var cellAttrs = attrs; cellAttrs[.paragraphStyle] = para
        let img = NSImage(size: NSSize(width: max(1, ceil(total)), height: h), flipped: false) { _ in
            var x = padX
            for i in cells.indices {
                let w = widths[i]
                if i > 0 {     // тонкий разделитель-волосок (template-картинка его тоже тинтует)
                    NSColor.black.withAlphaComponent(0.28).setStroke()
                    let sep = NSBezierPath(); sep.lineWidth = 1
                    sep.move(to: NSPoint(x: x - gap / 2, y: 4)); sep.line(to: NSPoint(x: x - gap / 2, y: h - 4)); sep.stroke()
                }
                var tx = x, tw = w
                if let g = glyphs[i] {     // ведущий глиф ячейки — слева, по вертикали по центру
                    let gs = g.img.size
                    g.img.draw(in: NSRect(x: x, y: (h - gs.height) / 2, width: g.w, height: gs.height),
                               from: .zero, operation: .sourceOver, fraction: 1)
                    tx = x + g.w + iconGap; tw = w - g.w - iconGap
                }
                let p = texts[i]
                let vh = (p as NSString).size(withAttributes: cellAttrs).height
                (p as NSString).draw(in: NSRect(x: tx, y: (h - vh) / 2, width: tw, height: vh), withAttributes: cellAttrs)
                x += w + gap
            }
            return true
        }
        img.isTemplate = true     // ОС сама красит под светлую/тёмную/подсветку, как у menuBarIcon
        return img
    }

    // MARK: обратная связь автозамены языка/опечатки (звук + индикатор + вспышка иконки)
    private func handleLangFeedback(_ fb: LangSwitcher.Feedback) {
        let sound = SettingsStore.langFeedbackSound
        let hud = SettingsStore.langFeedbackHUD
        switch fb {
        case .layout(let toRU):
            if sound { playFeedbackSound("Morse") }
            if hud { FeedbackHUD.shared.show(symbol: "globe", text: toRU ? L("Русский") : "English", tint: .systemTeal) }
        case .spell(let original, let corrected, let id):
            if sound { playFeedbackSound("Pop") }
            if hud { CorrectionChoiceHUD.shared.show(original: original, corrected: corrected, id: id) }
        case .undo:
            if sound { playFeedbackSound("Tink") }
            if hud { FeedbackHUD.shared.show(symbol: "arrow.uturn.backward.circle.fill", text: L("Исходное слово возвращено"), tint: .systemOrange) }
        }
        if hud { flashStatusItem() }
    }
    private func playFeedbackSound(_ name: String) {
        let s = NSSound(named: name); s?.volume = 0.3; s?.play()
    }
    private func flashStatusItem() {
        guard !Motion.reduced, let layer = statusItem.button?.layer else { return }   // «Уменьшить движение» — без вспышки иконки
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1.0; a.toValue = 0.4
        a.autoreverses = true; a.duration = 0.13
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(a, forKey: "langflash")
    }

    /// Нужен ли строке меню тяжёлый EnergyModel.snapshot (только если выбран энергозависимый доп-показатель).
    private var menuBarNeedsEnergy: Bool {
        SettingsStore.menuBarExtras.prefix(SettingsStore.menuBarExtraMax)
            .contains { ["watts", "cputemp", "gputemp", "fan"].contains($0) }
    }

    /// Согласует платные авто-фичи с Pro-статусом. Зовётся на старте (и должно — при смене лицензии):
    /// если Pro потерян (триал истёк/деактивация) — гасит языковые автоматизации, чтобы не работали даром.
    /// Вентиляторы/charge-limit гасятся отдельно: при !isPro heartbeat аренды (refreshLease) не обновляется,
    /// и демон сам вернёт авто+BCLM100 по истечении lease-окна (15 мин); защита по кристаллу всё равно форсит макс при перегреве.
    func applyProEntitlements() {
        let pro = Licensing.shared.isPro
        LangSwitcher.shared.snippetsEnabled = pro && SettingsStore.snippetsEnabled
        LangSwitcher.shared.spellFixEnabled = pro && SettingsStore.spellFixEnabled
        let lm = SettingsStore.langMode
        LangSwitcher.shared.mode = pro ? ((lm == "auto") ? .auto : (lm == "hotkey" ? .hotkey : .off)) : .off
    }

    func tick() {
        ClipboardHistory.shared.poll()
        Caffeine.expireIfDue()                            // синхронизируем флаг с OS-таймаутом ассерции
        nightTick += 1
        if SettingsStore.nightKeepOn && NightShift.available && nightTick % 10 == 0 { NightShift.enableNow() }
        if nightTick % 120 == 0, Licensing.shared.isPro {
            hardwareQueue.async { FanController.refreshLease() }
        }
        guard !hardwareTickInFlight else { return }
        hardwareTickInFlight = true

        let tickNumber = nightTick
        let popoverOpen = popover.isShown
        let needEnergy = popoverOpen || menuBarNeedsEnergy
        let forcedNoBatt = ProcessInfo.processInfo.environment["BM_NOBATT"] != nil
        // Mach counters are cheap and their history remains main-owned.
        let cpuLoad = SystemUsage.shared.cpu()
        let ramLoad = SystemUsage.shared.ram()

        hardwareQueue.async { [weak self] in
            guard let self else { return }
            let battery = (forcedNoBatt ? nil : BatteryReader.read()) ?? .absent
            let energy = needEnergy ? EnergyModel.snapshot() : EnergySnapshot()
            if needEnergy { SessionEnergy.accumulate(energy) }
            let components = popoverOpen ? PowerInfo.components() : ComponentPower()
            let sensors = popoverOpen
                ? SensorsModel.snapshot(cpuLoad: cpuLoad, ramLoad: ramLoad, components: components)
                : SensorsSnapshot()
            if tickNumber % 15 == 0 {
                AlertsEngine.shared.evaluate(battery: battery, popoverOpen: popoverOpen,
                                             sampledCPULoad: cpuLoad)
            }
            let historyEnergy = tickNumber % 60 == 0 && !needEnergy ? EnergyModel.snapshot() : energy

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.hardwareTickInFlight = false
                self.applyHardwareFrame(battery: battery, energy: energy, historyEnergy: historyEnergy,
                                        components: components, sensors: sensors,
                                        popoverOpen: popoverOpen, tickNumber: tickNumber)
            }
        }
    }

    private func applyHardwareFrame(battery b: BatteryInfo, energy: EnergySnapshot,
                                    historyEnergy: EnergySnapshot, components: ComponentPower,
                                    sensors: SensorsSnapshot, popoverOpen: Bool, tickNumber: Int) {
        precondition(Thread.isMainThread)
        if b.present { checkFanAutoBySource(external: b.external) }

        if tickNumber % 60 == 0 {
            func temp(_ v: Double?) -> Double? { (v ?? 0) > 1 ? v : nil }
            History.shared.record(History.Sample(
                ts: Int64(Date().timeIntervalSince1970),
                charge: b.present ? Double(b.charge) : nil,
                health: (b.present && b.health > 1) ? b.health : nil,
                battTemp: b.present ? temp(b.temperature) : nil,
                cpuTemp: temp(historyEnergy.cpuTemp), gpuTemp: temp(historyEnergy.gpuTemp),
                systemW: historyEnergy.systemWatts > 0.1 ? historyEnergy.systemWatts : nil,
                fanRPM: historyEnergy.fans.max(), charging: b.charging), keepSeconds: 90 * 86400)
        }

        if popoverOpen || SettingsStore.menuBarExtras.prefix(SettingsStore.menuBarExtraMax).contains("btbatt") {
            BTPeripherals.refreshIfStale()
        }
        updateMenuBar(b, energy)
        if (popoverOpen || menuBarNeedsEnergy), b.present {
            history.append(energy.systemWatts > 0.1 ? energy.systemWatts : b.watts)
            if history.count > 90 { history.removeFirst() }
        }
        if popoverOpen {
            controller.update(battery: b, history: history, components: components,
                              energy: energy, sensors: sensors)
        }
    }

    private var lastPowerExternal: Bool? = nil
    /// Авто fan-профиль на смену источника: применяем профиль AC/battery ТОЛЬКО на реальном РЕБРЕ
    /// (первый тик — молча запоминаем, без применения). Требует Pro + включённую автоматику + демон.
    /// Реверт к системному авто при выходе/краше — по ЛИЗ-истечению (~15 мин), не мгновенно (демон).
    private func checkFanAutoBySource(external: Bool) {
        defer { lastPowerExternal = external }
        guard let prev = lastPowerExternal, prev != external else { return }   // только ребро; первый тик — молча
        guard SettingsStore.fanAutoBySource, Licensing.shared.isPro, FanController.daemonInstalled else { return }
        if AlertsEngine.shared.isBoostActive { return }                       // не перебивать аварийный форс кулеров
        FanController.applyProfileHeadless(named: external ? SettingsStore.fanProfileAC : SettingsStore.fanProfileBattery)
    }

    func refreshApps() {
        guard popover.isShown else { return }             // /usr/bin/top незачем спавнить при закрытом поповере
        PowerInfo.topApps { [weak self] in self?.controller.updateApps($0) }
    }

    func checkIdleBacklight() {
        guard KeyboardBacklight.available else { return }
        guard SettingsStore.idleBacklight else {
            if idleDimmed { KeyboardBacklight.set(max(0, savedBacklight)); idleDimmed = false }
            return
        }
        let idle = IdleTime.seconds()
        let threshold = Double(SettingsStore.idleSeconds)
        if idle >= threshold && !idleDimmed {
            let cur = KeyboardBacklight.get()
            if cur > 0.02 { savedBacklight = cur; KeyboardBacklight.set(0); idleDimmed = true }
        } else if idle < threshold && idleDimmed {
            KeyboardBacklight.set(max(0, savedBacklight)); idleDimmed = false
        }
    }

    // правый клик / ⌃-клик — меню инструментов; обычный — поповер
    @objc func statusClick() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || (e?.modifierFlags.contains(.control) ?? false) {
            showToolsMenu(from: nil)
        } else {
            togglePopover()
        }
    }

    private func menuIcon(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        img?.isTemplate = true                     // тинтуется цветом текста меню, в т.ч. при подсветке
        return img
    }
    @objc func openToolsFromFooter(_ sender: NSButton) { showToolsMenu(from: sender) }
    /// Меню инструментов. `anchor` = вью, под которой раскрывается меню; nil → status item
    /// в строке меню (правый клик). Из футера передаём кнопку «…», иначе меню всплывало бы
    /// у иконки наверху экрана, а не под нажатой кнопкой (и .transient-поповер закрывал бы его).
    private func showToolsMenu(from anchor: NSView?) {
        let btn: NSView
        if let anchor = anchor {
            btn = anchor
        } else {
            guard let sb = statusItem.button else { return }
            btn = sb
        }
        let m = NSMenu()
        // Тумблерные строки-«не закрывай меню» (custom-view): собираем для 1Гц-refresh во время tracking
        var liveRows: [MenuToggleRow] = []
        func toggleRow(in menu: NSMenu, _ title: String, _ symbol: String?,
                       state: @escaping () -> Bool, onToggle: @escaping () -> Void) {
            let row = MenuToggleRow(title: title, symbol: symbol, state: state, onToggle: onToggle)
            let it = NSMenuItem()
            it.view = row
            menu.addItem(it)
            liveRows.append(row)
        }
        func add(_ title: String, _ symbol: String?, _ on: Bool?, _ sel: Selector, enabled: Bool = true) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            it.image = symbol.flatMap { menuIcon($0) }
            if let on = on { it.state = on ? .on : .off }
            it.isEnabled = enabled
            m.addItem(it)
        }
        func head(_ title: String, _ symbol: String, _ submenu: NSMenu) {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.image = menuIcon(symbol)
            it.submenu = submenu
            m.addItem(it)
        }
        // Тумблеры «щёлкай подряд» — custom-view строки, меню НЕ закрывается (Caffeine/NightShift/Finder тоже)
        let caffMenu = NSMenu()
        buildCaffeineRows(into: caffMenu) { liveRows.append($0) }
        head(caffeineHeadTitle(), "cup.and.saucer.fill", caffMenu)
        head(sleepHeadTitle(), "moon.zzz.fill", sleepSubmenu())
        if NightShift.available {
            let nsMenu = NSMenu()
            buildNightShiftRows(into: nsMenu) { liveRows.append($0) }
            head(L("Night Shift"), "moon.fill", nsMenu)
        }
        if !FanController.fans().isEmpty { head(fanHeadTitle(), "fanblades.fill", fanQuickSubmenu()) }
        toggleRow(in: m, L("Тёмная тема"), "circle.lefthalf.filled",
                  state: { UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" },
                  onToggle: { [weak self] in
                      DarkModeToggle.toggle()
                      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                          guard let self else { return }
                          self.controller.view.appearance = nil
                          self.controller.view.needsDisplay = true
                          self.controller.buildModules()
                          self.refreshMenuBarNow()
                      }
                  })
        if WiFiToggle.available {
            toggleRow(in: m, "Wi-Fi", "wifi", state: { WiFiToggle.isOn }, onToggle: { WiFiToggle.toggle() })
        }
        if BluetoothToggle.available {
            toggleRow(in: m, "Bluetooth", "dot.radiowaves.right",
                      state: { BluetoothToggle.isOn }, onToggle: { BluetoothToggle.toggle() })
        }
        head(L("Разрешение экрана"), "display", displaySubmenu())
        if Firewall.available {
            m.addItem(.separator())
            add(L("Паника: блок всех входящих"), "exclamationmark.shield.fill", Firewall.enabled && Firewall.blockAll, #selector(togglePanic))
        }

        m.addItem(.separator())
        let finderMenu = NSMenu()
        buildFinderRows(into: finderMenu) { liveRows.append($0) }
        head(L("Finder и рабочий стол"), "folder.fill", finderMenu)
        head(L("Для разработчиков"), "hammer.fill", devToolsSubmenu())
        head(L("Gatekeeper и карантин"), "lock.shield.fill", securitySubmenu())

        let clips = ClipboardHistory.shared.items
        if !clips.isEmpty {
            m.addItem(.separator())
            let sub = NSMenu()
            for (i, s) in clips.prefix(12).enumerated() {
                let label = String(s.prefix(48)).replacingOccurrences(of: "\n", with: " ")
                let it = NSMenuItem(title: label, action: #selector(pasteClip(_:)), keyEquivalent: "")
                it.target = self; it.tag = i
                sub.addItem(it)
            }
            head(L("История буфера"), "doc.on.clipboard", sub)
        }

        m.addItem(.separator())
        // [обновления]
        add(L("Проверить обновления…"), "arrow.triangle.2.circlepath", nil, #selector(checkUpdatesFromMenu))
        add(L("Что нового…"), "sparkle.magnifyingglass", nil, #selector(checkUpdatesFromMenu))
        m.addItem(.separator())
        // [поддержка автора] — коммерция снята (июль 2026); приложение бесплатно, донат добровольный
        add(L("Поддержать Kelvin…"), "heart", nil, #selector(donateFromMenu))
        add(L("Обратная связь…"), "envelope", nil, #selector(sendFeedbackFromMenu))
        add(L("Благодарности / Лицензии…"), "heart.text.square", nil, #selector(openAboutFromMenu))
        m.addItem(.separator())
        add(L("Настройки…"), "gearshape", nil, #selector(openSettingsFromMenu))
        add(L("О программе Kelvin"), "info.circle", nil, #selector(openAboutFromMenu))
        add(L("Выйти из Kelvin"), "power", nil, #selector(NSApplication.terminate(_:)))
        // Если меню открыто из футера, поповер на экране и .transient закрыл бы его при
        // показе меню (потеря фокуса) — временно держим поповер открытым, восстанавливаем после.
        let fromFooter = anchor != nil
        if fromFooter { popover.behavior = .applicationDefined }
        (btn as? NSButton)?.highlight(true)            // нативная подсветка кнопки, пока открыто меню
        // 1Гц-refresh живых строк во время tracking (Wi-Fi/BT асинхронны, Finder-твики пишутся в фоне):
        // обычные таймеры в menu-tracking НЕ тикают → режим .eventTracking обязателен.
        let live = liveRows
        let refresher = Timer(timeInterval: 1.0, repeats: true) { _ in live.forEach { $0.refresh() } }
        RunLoop.main.add(refresher, forMode: .eventTracking)
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: btn.bounds.height), in: btn)
        refresher.invalidate()
        (btn as? NSButton)?.highlight(false)
        if fromFooter { popover.behavior = .transient }
    }
    // (toggleCaffeine/toggleNightShift-селекторы удалены — их работу выполняют MenuToggleRow-замыкания)

    /// «1 ч 05 мин», «5 мин», «42 с» — компактный остаток для пунктов меню.
    private func remainText(_ s: TimeInterval) -> String {
        let t = Int(s.rounded())
        if t >= 3600 { return String(format: L("%d ч %02d мин"), t / 3600, (t % 3600) / 60) }
        if t >= 60 { return String(format: L("%d мин"), (t + 59) / 60) }
        return String(format: L("%d с"), t)
    }

    // — Caffeine с длительностью —
    private func caffeineHeadTitle() -> String {
        if Caffeine.active, let r = Caffeine.remaining { return L("Не засыпать (Caffeine)") + " · " + remainText(r) }
        if Caffeine.active { return L("Не засыпать (Caffeine)") + " · " + L("бессрочно") }
        return L("Не засыпать (Caffeine)")
    }
    /// Caffeine-подменю строками-«не закрывай меню»: щёлкай режимы подряд, галочка обновляется на месте.
    /// «До времени…» остаётся нативным пунктом (открывает модал — меню обязано закрыться).
    private func buildCaffeineRows(into sub: NSMenu, collect: (MenuToggleRow) -> Void) {
        func row(_ title: String, state: @escaping () -> Bool, onToggle: @escaping () -> Void) {
            let r = MenuToggleRow(title: title, symbol: nil, state: state, onToggle: onToggle)
            let it = NSMenuItem(); it.view = r; sub.addItem(it); collect(r)
        }
        row(L("Выключено"), state: { !Caffeine.active }, onToggle: { Caffeine.stop() })
        sub.addItem(.separator())
        for (title, mins) in [(L("15 минут"), 15), (L("1 час"), 60), (L("2 часа"), 120)] {
            row(title, state: { Caffeine.active && abs((Caffeine.remaining ?? -1) - Double(mins) * 60) < 90 },
                onToggle: { Caffeine.start(seconds: TimeInterval(mins) * 60) })
        }
        let until = NSMenuItem(title: L("До времени…"), action: #selector(caffeineUntil), keyEquivalent: "")
        until.target = self
        sub.addItem(until)
        row(L("Бессрочно (пока Kelvin запущен)"),
            state: { Caffeine.active && Caffeine.deadline == nil },
            onToggle: { Caffeine.start() })
        if Caffeine.active, let r = Caffeine.remaining {
            sub.addItem(.separator())
            let info = NSMenuItem(title: String(format: L("Осталось: %@"), remainText(r)), action: nil, keyEquivalent: "")
            info.isEnabled = false
            sub.addItem(info)
        }
    }
    // (caffeineOff/For/Indefinite удалены — Caffeine-строки зовут API напрямую через MenuToggleRow)
    @objc private func caffeineUntil() {
        guard let secs = askUntilSeconds(L("Не засыпать до времени")) else { return }
        Caffeine.start(seconds: secs)
    }

    // — Таймер сна —
    private func sleepHeadTitle() -> String {
        if let r = SleepTimer.remaining { return L("Сон") + " · " + String(format: L("через %@"), remainText(r)) }
        return L("Сон")
    }
    private func sleepSubmenu() -> NSMenu {
        let sub = NSMenu()
        func item(_ title: String, _ sel: Selector, tag: Int = 0, on: Bool = false) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self; it.tag = tag; it.state = on ? .on : .off
            sub.addItem(it)
        }
        item(L("Уснуть сейчас"), #selector(sleepNow))
        item(L("Погасить экран"), #selector(displaySleepNow))
        sub.addItem(.separator())
        let armed = SleepTimer.isArmed
        for (title, mins) in [(L("Уснуть через 15 минут"), 15), (L("Уснуть через 30 минут"), 30), (L("Уснуть через 60 минут"), 60)] {
            item(title, #selector(sleepIn(_:)), tag: mins)
        }
        item(L("Уснуть через…"), #selector(sleepInCustom))
        if armed, let r = SleepTimer.remaining {
            sub.addItem(.separator())
            let info = NSMenuItem(title: String(format: L("Сон через %@"), remainText(r)), action: nil, keyEquivalent: "")
            info.isEnabled = false
            sub.addItem(info)
            item(L("Отменить таймер сна"), #selector(cancelSleep))
        }
        return sub
    }
    @objc private func sleepNow() { SleepTimer.sleepNow() }
    @objc private func displaySleepNow() { SleepTimer.displaySleepNow() }
    @objc private func sleepIn(_ sender: NSMenuItem) { SleepTimer.arm(minutes: sender.tag) }
    @objc private func cancelSleep() { SleepTimer.cancel() }
    @objc private func sleepInCustom() {
        guard let mins = askMinutes(L("Уснуть через"), suggestion: 45) else { return }
        SleepTimer.arm(minutes: mins)
    }

    /// Запросить число минут (1…1440). nil = отмена/пусто.
    private func askMinutes(_ title: String, suggestion: Int) -> Int? {
        let a = NSAlert(); a.messageText = title
        a.informativeText = L("Сработает, только пока Kelvin запущен.")
        let field = NSTextField(string: String(suggestion))
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: L("ОК")); a.addButton(withTitle: L("Отмена"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        guard let n = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), n >= 1 else { return nil }
        return min(n, 1440)
    }

    /// Запросить время «до HH:MM» и вернуть число секунд до него (сегодня или завтра).
    private func askUntilSeconds(_ title: String) -> TimeInterval? {
        let a = NSAlert(); a.messageText = title
        a.informativeText = L("Введите время в формате ЧЧ:ММ (24 ч). Удерживает, пока Kelvin запущен.")
        let now = Date()
        let cal = Calendar.current
        let hh = cal.component(.hour, from: now)
        let field = NSTextField(string: String(format: "%02d:%02d", (hh + 1) % 24, 0))
        field.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: L("ОК")); a.addButton(withTitle: L("Отмена"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let parts = field.stringValue.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        var comp = cal.dateComponents([.year, .month, .day], from: now)
        comp.hour = h; comp.minute = m; comp.second = 0
        guard var target = cal.date(from: comp) else { return nil }
        if target <= now { target = target.addingTimeInterval(86400) }   // уже прошло — на завтра
        return target.timeIntervalSince(now)
    }

    /// Night Shift строками-«не закрывай меню»: вкл/держать/теплота щёлкаются подряд.
    private func buildNightShiftRows(into sub: NSMenu, collect: (MenuToggleRow) -> Void) {
        func row(_ title: String, state: @escaping () -> Bool, onToggle: @escaping () -> Void) {
            let r = MenuToggleRow(title: title, symbol: nil, state: state, onToggle: onToggle)
            let it = NSMenuItem(); it.view = r; sub.addItem(it); collect(r)
        }
        row(L("Включён сейчас"), state: { NightShift.isOn }, onToggle: { NightShift.toggle() })
        row(L("Держать всегда включённым"), state: { SettingsStore.nightKeepOn },
            onToggle: { [weak self] in self?.toggleNightKeepOn() })
        sub.addItem(.separator())
        for (title, val) in [(L("Слабо"), Float(0.3)), (L("Средне"), 0.6), (L("Сильно"), 1.0)] {
            row(title, state: { abs(SettingsStore.nightStrength - val) < 0.05 },
                onToggle: {
                    SettingsStore.nightStrength = val
                    if NightShift.isOn || SettingsStore.nightKeepOn { NightShift.enableNow(strength: val) }
                    else { NightShift.setStrength(val) }
                })
        }
    }
    @objc private func toggleNightKeepOn() {
        SettingsStore.nightKeepOn.toggle()
        if SettingsStore.nightKeepOn { NightShift.enableNow() }   // включить сразу; tick будет удерживать
    }
    // (setNightStrength удалён — строки теплоты зовут API напрямую через MenuToggleRow)

    private func displaySubmenu() -> NSMenu {
        let sub = NSMenu()
        let cur = ScreenResolution.current()
        for mode in ScreenResolution.available() {
            let it = NSMenuItem(title: mode.label, action: #selector(applyResolution(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = mode
            if let c = cur, c.w == mode.w, c.h == mode.h { it.state = .on }
            sub.addItem(it)
        }
        if sub.items.isEmpty { sub.addItem(NSMenuItem(title: L("нет доступных режимов"), action: nil, keyEquivalent: "")) }
        return sub
    }
    @objc private func applyResolution(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? ScreenResolution.Mode else { return }
        _ = ScreenResolution.apply(mode)
    }
    // (toggleDark/WiFi/BT-селекторы удалены — верхнеуровневые тумблеры зовут API через MenuToggleRow)
    /// Finder-твики строками-«не закрывай меню» — ГЛАВНЫЙ сценарий владельца: 8 тумблеров подряд.
    /// toggle (defaults write + killall Finder) — В ФОНЕ (синхронный Process на main вешал tracking);
    /// галочку доведёт 1Гц-refresher меню.
    private func buildFinderRows(into sub: NSMenu, collect: (MenuToggleRow) -> Void) {
        for t in FinderTweaks.tweaks {
            let r = MenuToggleRow(title: t.title, symbol: nil,
                                  state: { FinderTweaks.isOn(t) },
                                  onToggle: { DispatchQueue.global(qos: .userInitiated).async { FinderTweaks.toggle(t) } })
            let it = NSMenuItem(); it.view = r; sub.addItem(it); collect(r)
        }
    }

    private func devToolsSubmenu() -> NSMenu {
        let sub = NSMenu()
        if !DevTools.brewInstalled {
            let it = NSMenuItem(title: L("⚙ Установить Homebrew (нужен для остального)"), action: #selector(installHomebrew), keyEquivalent: "")
            it.target = self
            sub.addItem(it)
            return sub
        }
        let head = NSMenuItem(title: L("✓ Homebrew установлен"), action: nil, keyEquivalent: "")
        head.isEnabled = false
        sub.addItem(head)
        sub.addItem(.separator())
        for cat in DevTools.categories {
            let catItem = NSMenuItem(title: L(cat.title), action: nil, keyEquivalent: "")
            let catMenu = NSMenu()
            for tool in cat.tools {
                let it = NSMenuItem(title: tool.name, action: #selector(installDevTool(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = tool
                it.state = DevTools.isInstalled(tool) ? .on : .off
                catMenu.addItem(it)
            }
            catItem.submenu = catMenu
            sub.addItem(catItem)
        }
        return sub
    }
    @objc private func installHomebrew() {
        let a = NSAlert()
        a.messageText = L("Установить Homebrew")
        a.informativeText = L("Откроется Терминал с официальным установщиком Homebrew. Он попросит пароль и подтверждение. После установки снова открой это меню — появятся инструменты.")
        a.addButton(withTitle: L("Открыть Терминал"))
        a.addButton(withTitle: L("Отмена"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        DevTools.runInTerminal(DevTools.homebrewInstall)
    }
    @objc private func installDevTool(_ sender: NSMenuItem) {
        guard let tool = sender.representedObject as? DevTools.Tool, let cmd = DevTools.installCommand(tool) else { return }
        let reinstall = DevTools.isInstalled(tool)
        let a = NSAlert()
        a.messageText = (reinstall ? L("Переустановить ") : L("Установить ")) + tool.name
        a.informativeText = String(format: L("Откроется Терминал с командой:\n\n%@\n\nПрогресс установки будет виден в окне."), cmd)
        a.addButton(withTitle: reinstall ? L("Переустановить") : L("Установить"))
        a.addButton(withTitle: L("Отмена"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        DevTools.runInTerminal(cmd)
    }

    private func securitySubmenu() -> NSMenu {
        let sub = NSMenu()
        let gk = SecurityTools.gatekeeperEnabled
        let gkItem = NSMenuItem(title: gk ? L("Gatekeeper: включён ✓") : L("Gatekeeper: выключен ⚠️"),
                                action: #selector(toggleGatekeeper), keyEquivalent: "")
        gkItem.target = self
        sub.addItem(gkItem)
        let q = NSMenuItem(title: L("Карантин новых загрузок"), action: #selector(toggleQuarantine), keyEquivalent: "")
        q.target = self; q.state = SecurityTools.quarantineOn ? .on : .off
        sub.addItem(q)
        sub.addItem(.separator())
        let clr = NSMenuItem(title: L("Снять карантин с приложения…"), action: #selector(clearQuarantinePick), keyEquivalent: "")
        clr.target = self
        sub.addItem(clr)
        return sub
    }
    @objc private func toggleGatekeeper() {
        let enabled = SecurityTools.gatekeeperEnabled
        let disabling = enabled
        let a = NSAlert()
        a.alertStyle = disabling ? .critical : .informational
        a.messageText = disabling ? L("Выключить Gatekeeper?") : L("Включить Gatekeeper?")
        a.informativeText = disabling
            ? L("⚠️ macOS перестанет проверять подпись приложений — запускаться сможет ЛЮБОЕ, включая вредоносное. Включи обратно, когда закончишь. Может понадобиться подтверждение в Системных настройках → Конфиденциальность и безопасность.")
            : L("Вернёт стандартную защиту: запуск только проверенных приложений.")
        a.addButton(withTitle: disabling ? L("Выключить") : L("Включить"))
        a.addButton(withTitle: L("Отмена"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let ok = SecurityTools.setGatekeeper(!enabled)
        let done = NSAlert()
        done.messageText = ok ? L("Готово") : L("Не удалось")
        done.informativeText = ok
            ? (disabling ? L("Gatekeeper выключен. Если «неизвестные» приложения всё ещё блокируются — выбери «Anywhere» в Системных настройках → Конфиденциальность и безопасность.")
                         : L("Gatekeeper включён — стандартная защита."))
            : L("Действие отменено или ошибка.")
        done.runModal()
    }
    @objc private func toggleQuarantine() {
        SecurityTools.setQuarantine(!SecurityTools.quarantineOn)
    }
    @objc private func clearQuarantinePick() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = L("Выбери приложение или файл, с которого снять карантин")
        panel.prompt = L("Снять карантин")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let r = SecurityTools.clearQuarantine(url.path)
        let a = NSAlert()
        a.messageText = r.ok ? L("Карантин снят") : L("Не удалось")
        a.informativeText = r.ok
            ? String(format: L("«%@» теперь запустится без блокировки."), url.lastPathComponent)
            : L("Не удалось снять карантин (отменено или нет прав).")
        a.runModal()
    }
    @objc private func togglePanic() {
        if Firewall.enabled && Firewall.blockAll {
            _ = Firewall.privileged(["--setblockall off"])     // выключить можно всегда (в т.ч. во Free)
        } else {
            guard SettingsWindowController.shared.requirePro(.firewall) else { return }   // включение фаервола — Pro
            _ = Firewall.privileged(["--setglobalstate on", "--setblockall on"])
        }
    }
    @objc private func openSettingsFromMenu() { SettingsWindowController.shared.open() }
    @objc private func openAboutFromMenu() { SettingsWindowController.shared.open(); SettingsWindowController.shared.selectByName("about") }
    @objc private func openProFromMenu() { SettingsWindowController.shared.open(); SettingsWindowController.shared.selectByName("license") }

    // MARK: — быстрые пресеты охлаждения из меню-бара (Авто/Тихо/Баланс/Максимум) + заряд-состояние —
    /// Заголовок пункта «Охлаждение · <текущее состояние>». Честно: без демона или в «Авто» — «система».
    private func fanHeadTitle() -> String {
        let base = L("Охлаждение")
        let id = SettingsStore.activeFanProfileName
        if !FanController.daemonInstalled || id == "auto" { return base + " · " + L("система") }
        return base + " · " + SettingsStore.builtinFanDisplay(id)
    }
    private func fanQuickSubmenu() -> NSMenu {
        let sub = NSMenu()
        // Заряд-состояние (инфо-строка, неактивна).
        let pctText = BatteryReader.systemChargePercent().map { "\($0)%" } ?? "—"
        let chargeLine: String
        switch SettingsStore.chargeMode {
        case "sail": chargeLine = String(format: L("Заряд %@ · поддержание %d–%d%%"), pctText, SettingsStore.sailLower, SettingsStore.sailUpper)
        default:     chargeLine = SettingsStore.chargeLimit < 100
                        ? String(format: L("Заряд %@ · лимит %d%%"), pctText, SettingsStore.chargeLimit)
                        : String(format: L("Заряд %@ · без лимита"), pctText)
        }
        let info = NSMenuItem(title: chargeLine, action: nil, keyEquivalent: "")
        info.isEnabled = false
        sub.addItem(info)
        sub.addItem(.separator())
        // Пресеты. Активным считаем: под управлением — активный профиль, иначе «Авто».
        let controlled = FanController.daemonInstalled && SettingsStore.activeFanProfileName != "auto"
        let effective = controlled ? SettingsStore.activeFanProfileName : "auto"
        let presets: [(id: String, title: String, sym: String)] = [
            ("auto", L("Авто (система)"), "a.circle"),
            ("quiet", L("Тихо"), "leaf"),
            ("balance", L("Баланс"), "speedometer"),
            ("turbo", L("Максимум"), "bolt.fill"),
        ]
        for p in presets {
            let it = NSMenuItem(title: p.title, action: #selector(applyFanQuick(_:)), keyEquivalent: "")
            it.target = self
            it.image = menuIcon(p.sym)
            it.representedObject = p.id
            it.state = (p.id == effective) ? .on : .off
            sub.addItem(it)
        }
        return sub
    }
    @objc private func applyFanQuick(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if id == "auto" {
            FanController.applyProfileHeadless(named: "auto")   // демон отпустит; без демона — уже система
            SettingsStore.activeFanProfileName = "auto"
            SettingsWindowController.shared.refreshPowerIfOpen()
            return
        }
        // Форс вентиляторов — Pro.
        guard Licensing.shared.isPro else { _ = SettingsWindowController.shared.requirePro(.fans); return }
        // Управление ещё не установлено — ведём в настройки (там ставится root-демон через диалог пароля).
        guard FanController.daemonInstalled else {
            SettingsWindowController.shared.open()
            SettingsWindowController.shared.selectByName("power")
            return
        }
        FanController.applyProfileHeadless(named: id)           // сам выставит activeFanProfileName
        SettingsWindowController.shared.refreshPowerIfOpen()
    }

    // MARK: пункты меню — обновления, поддержка автора, обратная связь
    @objc private func checkUpdatesFromMenu() { Updater.checkManually() }

    /// «Поддержать Kelvin» — донат автору (коммерция снята). URL-плейсхолдер в `Donate.url`.
    @objc private func donateFromMenu() { Donate.open() }

    // — ниже: спящие коммерческие обработчики (лицензирование отключено; сохранены для реактивации) —
    @objc private func buyProFromMenu() {                      // гейт: только не-Pro
        if let u = URL(string: Licensing.checkoutURL) { NSWorkspace.shared.open(u) }
    }

    @objc private func restorePurchaseFromMenu() {             // честно: почта восстановления
        let subj = "Kelvin — restore purchase".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let u = URL(string: "mailto:cambly.studio@gmail.com?subject=\(subj)") { NSWorkspace.shared.open(u) }
    }

    @objc private func sendFeedbackFromMenu() {
        if let u = AppConfig.mailto(subject: "Kelvin feedback (\(appVersion))") { NSWorkspace.shared.open(u) }
    }

    @objc private func openHelpFromMenu() {                    // trykelvin.com
        if let u = URL(string: Licensing.checkoutURL) { NSWorkspace.shared.open(u) }
    }

    @objc private func deactivateMacFromMenu() {               // гейт: только activated; с подтверждением
        let a = NSAlert()
        a.messageText = L("Деактивировать этот Mac?")
        a.informativeText = L("Освободит место лицензии (2 Mac на лицензию) — пригодится при продаже или замене компьютера. Pro-функции на этом Mac отключатся.")
        a.addButton(withTitle: L("Деактивировать")); a.addButton(withTitle: L("Отмена"))
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Licensing.shared.deactivate()
    }

    /// Менютрекинг-трюк: пока поповер открыт над fullscreen, держим системную строку меню
    /// «в состоянии трекинга меню», чтобы она не схлопывалась обратно и поповер не моргал.
    /// Обещание строго ограничено: только «поповер над fullscreen не моргает» (НЕ «иконка всегда видна»).
    private func postMenuTracking(begin: Bool) {
        let name = begin ? "com.apple.HIToolbox.beginMenuTrackingNotification"
                         : "com.apple.HIToolbox.endMenuTrackingNotification"
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name(name), object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Прощальный оффер при окончании пробного периода — ключевой момент воронки. Показывается один раз.
    @objc func presentTrialEnded() {
        Licensing.shared.markTrialEndedShown()
        let a = NSAlert()
        a.messageText = L("Пробный период Kelvin Pro закончился")
        a.informativeText = String(format: L("Мониторинг остаётся бесплатным навсегда. Управление вентиляторами, лимит заряда, фаервол, переключатель языка и другие Pro-функции теперь отключены. Разблокировать — разовая покупка %@, без подписки."), AppConfig.proPriceDisplay)
        a.addButton(withTitle: String(format: L("Купить за %@"), AppConfig.proPriceDisplay))
        a.addButton(withTitle: L("Ввести ключ"))
        a.addButton(withTitle: L("Продолжить бесплатно"))
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn:
            if let url = Licensing.checkoutURL(), let realURL = URL(string: url) {
                NSWorkspace.shared.open(realURL)
            } else {
                // Магазин не настроен — fallback на ввод ключа
                SettingsWindowController.shared.open()
                SettingsWindowController.shared.openLicenseEntry()
            }
        case .alertSecondButtonReturn: SettingsWindowController.shared.open(); SettingsWindowController.shared.openLicenseEntry()
        default: break
        }
    }

    /// Минимальное главное меню. У LSUIElement-агента оно не видно в строке Apple, но включает
    /// стандартные горячие клавиши: ⌘Z/⌘X/⌘C/⌘V/⌘A в полях ввода и ⌘,/⌘W/⌘M/⌘Q в окнах.
    /// Без него нельзя даже вставить купленный лицензионный ключ с клавиатуры (⌘V не работал).
    private func buildMainMenu() {
        let main = NSMenu()

        // — App —
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("О программе Kelvin"), action: #selector(openAboutFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        // Pro-лоск: для полноты/хоткеев в скрытом app-меню. Гейтинг статичен (меню строится один раз при старте).
        appMenu.addItem(withTitle: L("Проверить обновления…"), action: #selector(checkUpdatesFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Поддержать Kelvin…"), action: #selector(donateFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: L("Обратная связь…"), action: #selector(sendFeedbackFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Настройки…"), action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Скрыть Kelvin"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Выйти из Kelvin"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // — Правка — (target = nil → маршрутизация по responder chain к активному полю ввода)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L("Правка"))
        editMenu.addItem(withTitle: L("Отменить"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L("Повторить"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Вырезать"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Копировать"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Вставить"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Выбрать всё"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        // — Окно —
        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: L("Окно"))
        winMenu.addItem(withTitle: L("Свернуть"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: L("Закрыть"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = winMenu
        main.addItem(winItem)
        NSApp.windowsMenu = winMenu

        NSApp.mainMenu = main
    }
    @objc private func pasteClip(_ item: NSMenuItem) {
        let items = ClipboardHistory.shared.items
        if item.tag < items.count { ClipboardHistory.shared.copy(items[item.tag]) }
    }

    @objc func togglePopover() { togglePopover(fromHotkey: false) }   // совместимость со statusClick/селекторами

    func togglePopover(fromHotkey: Bool) {
        if popover.isShown {
            if Motion.reduced { popover.performClose(nil); return }
            controller.playCloseAnimation { [weak self] in self?.popover.performClose(nil) }
            return
        }
        // Из хоткея приложение может быть неактивным/в чужом fullscreen-спейсе — поднимаем себя.
        if fromHotkey { NSApp.activate(ignoringOtherApps: true) }

        // Экранный rect, к которому привяжем неподвижное прозрачное окно-якорь.
        // В полноэкранном режиме строка меню авто-скрывается и УТАСКИВАЕТ кнопку-якорь наверх:
        // при вызове из хоткея со скрытой строкой якорим к ФИКС-точке у верхней кромки экрана,
        // иначе поповер «съехал» бы частично за кромку.
        let screenRect: NSRect
        var overFullscreen = false                                                 // якоримся над fullscreen (строка скрыта)?
        if fromHotkey, let btn = statusItem.button, statusBarVisible(btn), let win = btn.window {
            screenRect = win.convertToScreen(btn.convert(btn.bounds, to: nil))   // строка видна — обычный якорь к кнопке
        } else if fromHotkey {
            screenRect = hotkeyAnchorRect()                                        // строка скрыта — фикс-точка у кромки
            overFullscreen = true
        } else if let btn = statusItem.button, let win = btn.window {
            screenRect = win.convertToScreen(btn.convert(btn.bounds, to: nil))    // клик по иконке — прежний путь
        } else { return }

        let w = NSWindow(contentRect: screenRect, styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .clear
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]  // показаться на fullscreen-спейсе
        w.orderFront(nil)
        popoverAnchor = w
        // Над fullscreen: держим системную строку «в трекинге меню», чтобы она не схлопнулась и поповер не моргал.
        if overFullscreen { postMenuTracking(begin: true); postedMenuTracking = true }
        let anchorView: NSView = w.contentView!

        popover.delegate = self
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        // Собственное окно NSPopover НЕ наследует поведение окна-якоря: над fullscreen без этого оно
        // уходит на дефолтный спейс и «не открывается». Явно разрешаем ему показаться на fullscreen-спейсе.
        if let pwin = popover.contentViewController?.view.window {
            pwin.collectionBehavior.insert(.canJoinAllSpaces)
            pwin.collectionBehavior.insert(.fullScreenAuxiliary)
            if overFullscreen { pwin.level = .statusBar }
        }
        tick()                                        // isShown уже true → первый полный апдейт сразу
        refreshApps()
        controller.refreshHistoryIfVisible()          // переоткрытие на вкладке «История» → перечитать из БД (selectTab не сработает на той же вкладке)
        popover.contentViewController?.view.window?.makeKey()
        DispatchQueue.main.async { [weak self] in self?.controller.playOpenAnimation() }
    }

    /// Открыть поповер на вкладке «Приватность» из баннера first-conn.
    func openRadarFromAlert() {
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown { togglePopover(fromHotkey: true) }
        controller.focusPrivacyTab()
    }

    /// Видна ли строка меню сейчас (т.е. кнопка в досягаемой позиции, не уехала за кромку).
    private func statusBarVisible(_ btn: NSStatusBarButton) -> Bool {
        guard let win = btn.window else { return false }
        let screenRect = win.convertToScreen(btn.convert(btn.bounds, to: nil))
        guard let scr = btn.window?.screen ?? NSScreen.main else { return false }
        // в fullscreen окно статус-бара уезжает над кромкой — верх кнопки выходит за экран
        return screenRect.maxY <= scr.frame.maxY + 1
    }

    /// Фикс-точка у верхней кромки экрана — под обычной позицией иконки (правый край).
    private func hotkeyAnchorRect() -> NSRect {
        // экран под курсором приоритетнее (мультимонитор): в чужом fullscreen key-окно — не наше
        let mouse = NSEvent.mouseLocation
        let scr = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
                  ?? NSScreen.main
        guard let scr else { return NSRect(x: 0, y: 0, width: 32, height: 24) }  // нет экранов (clamshell/реконфиг) → честная деградация вместо трапа
        let f = scr.frame
        let h: CGFloat = 24, wdt: CGFloat = 32, inset: CGFloat = 8
        let x = f.maxX - wdt - inset
        let y = f.maxY - h               // под верхней кромкой; поповер раскроется вниз (.minY)
        return NSRect(x: x, y: y, width: wdt, height: h)
    }

    /// Закрытие поповера (в т.ч. транзиентное по клику-вне) → убрать якорь-окно.
    func popoverDidClose(_ notification: Notification) {
        if postedMenuTracking { postMenuTracking(begin: false); postedMenuTracking = false }
        popoverAnchor?.close()
        popoverAnchor = nil
    }
    
    /// Проверка наличия crash reports и показ уведомления пользователю
    private func checkForCrashReports() {
        let pendingReports = CrashReportStore.scan().newReports
        guard !pendingReports.isEmpty else { return }
        
        // Показываем уведомление для первого найденного отчёта
        // (остальные будут показаны после обработки первого)
        let report = pendingReports.first!
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.showCrashNotification(for: report)
        }
    }
    
    /// Показать карточку уведомления о crash report
    private func showCrashNotification(for report: CrashReportStore.ReportMetadata) {
        // Проверяем, включена ли автоматическая отправка
        let autoSend = SettingsStore.autoSendCrashReports
        
        if autoSend {
            // Автоматическая отправка без показа UI
            try? CrashReportStore.updateState(for: report.fingerprint, to: .queued)
            CrashReportUploader.shared.enqueue(report)
        } else {
            // Показываем карточку с запросом согласия
            // Для этого используем простое alert-like окно поверх status bar
            let alert = NSAlert()
            alert.messageText = "Kelvin неожиданно завершил работу"
            alert.informativeText = "Мы нашли отчёт о сбое. Вы можете отправить обезличенный отчёт разработчику, чтобы помочь исправить эту ошибку."
            alert.addButton(withTitle: "Посмотреть")
            alert.addButton(withTitle: "Отправить")
            alert.addButton(withTitle: "Не отправлять")
            alert.alertStyle = .warning
            
            let modalResponse = alert.runModal()
            
            switch modalResponse {
            case .alertFirstButtonReturn: // Посмотреть
                // Открываем preview в отдельном окне
                openCrashPreviewWindow(for: report)
                
            case .alertSecondButtonReturn: // Отправить
                try? CrashReportStore.updateState(for: report.fingerprint, to: .consented)
                CrashReportUploader.shared.enqueue(report)
                
            case .alertThirdButtonReturn: // Не отправлять
                try? CrashReportStore.updateState(for: report.fingerprint, to: .declined)
                
            default:
                break
            }
        }
    }
    
    /// Открыть окно предпросмотра crash report
    private func openCrashPreviewWindow(for report: CrashReportStore.ReportMetadata) {
        // Санитизируем отчёт для показа
        let result = CrashReportSanitizer.sanitize(
            url: CrashReportStore.sourceURL(for: report),
            reportID: report.reportID,
            sourceFingerprint: report.fingerprint
        )
        guard case .success(let sanitized) = result, !sanitized.containsPII else { return }
        
        // Создаём простое текстовое окно для просмотра
        let textView = NSTextView()
        textView.isEditable = false
        textView.string = sanitized.jsonPreview
        
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        
        let contentSize = NSSize(width: 500, height: 400)
        textView.frame = NSRect(origin: .zero, size: contentSize)
        scrollView.frame = NSRect(origin: .zero, size: contentSize)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: contentSize.width + 40, height: contentSize.height + 80),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Отчёт о сбое — \(report.sourceFilename)"
        window.contentViewController = NSViewController()
        window.contentViewController?.view = scrollView
        window.center()
        window.makeKeyAndOrderFront(nil)
        
        // Добавляем кнопки действий
        // (упрощённая версия — в полной реализации нужен SwiftUI preview)
    }

    func applicationWillTerminate(_ notification: Notification) {
        usbWatch.stop()        // E1 teardown: релиз итераторов + снятие run-loop source + destroy порта
        GlobalHotkey.shared.teardown()   // снять Carbon-хоткей + хендлер без утечки
        
        // Ожидание завершения активных загрузок crash reports (до 5 секунд)
        CrashReportUploader.shared.waitForCompletion(timeout: 5.0)
    }
}

// Отладочный дамп: проверяет, что данные реально доходят до строк (без GUI).
if ProcessInfo.processInfo.environment["BM_DUMP"] != nil {
    if let b = BatteryReader.read() {
        print(String(format: "Заголовок:  %@ %d%%  /  %@", b.charging ? "🔌" : "🔋", b.charge, b.charging ? "зарядка" : "разряд"))
        print(String(format: "Расход:     %.1f Вт", b.watts))
        print(String(format: "Здоровье=%.0f%%  Циклы=%d  Темп=%.1f°C  Напр=%.2fВ  Ёмкость=%.0f/%.0f Вт·ч",
                     b.health, b.cycleCount, b.temperature, b.voltage, b.capacityWh, b.maxWh))
    }
    let c = PowerInfo.components()
    print(String(format: "Компоненты: fresh=%@ CPU=%@ GPU=%@ DRAM=%@ Package=%@ (возраст %.1fс)",
                 c.fresh ? "да" : "нет",
                 c.cpu.map { String(format: "%.2fВт", $0) } ?? "—",
                 c.gpu.map { String(format: "%.2fВт", $0) } ?? "—",
                 c.dram.map { String(format: "%.2fВт", $0) } ?? "—",
                 c.package.map { String(format: "%.2fВт", $0) } ?? "—",
                 c.ageSeconds))
    print("Топ приложений по энергии:")
    for a in PowerInfo.topAppsSync() { print(String(format: "   %-22@  %.1f", a.name as NSString, a.impact)) }

    let e = EnergyModel.snapshot()
    print("\n=== SMC энергопоток (hasSMC=\(e.hasSMC)) ===")
    print(String(format: "Батарея: %.2f В × %.2f А = %.1f Вт  (%@)", e.battVolts, e.battAmps, e.battWatts, e.charging ? "заряд" : "разряд"))
    print(String(format: "Адаптер: %.2f В × %.2f А = %.1f Вт  (%@)", e.adapterVolts, e.adapterAmps, e.adapterWatts, e.plugged ? "подключён" : "отключён"))
    print(String(format: "Система потребляет: %.1f Вт", e.systemWatts))
    print("Потребители (ток):")
    for r in e.rails { print(String(format: "   %-8@ %.3f А%@", r.name as NSString, r.amps, r.watts.map { String(format: "  (%.2f Вт)", $0) } ?? "")) }
    print(String(format: "CPU %@°C  GPU %@°C  Вентиляторы: %@ об/мин",
                 e.cpuTemp.map { String(format: "%.0f", $0) } ?? "—",
                 e.gpuTemp.map { String(format: "%.0f", $0) } ?? "—",
                 e.fans.map { String(format: "%.0f", $0) }.joined(separator: "/")))
    exit(0)
}

// Зонд SMC: ищем прямые power-ключи (ватты) для системы/адаптера/батареи.
if ProcessInfo.processInfo.environment["BM_SMCPROBE"] != nil {
    let smc = SMC()
    let keys = ["PSTR","PDTR","PPBR","PCTR","PGTR","PHPC","PC0C","PCPC","PCPG",
                "PG0R","PD0R","PZ0R","PDIN","Pp0R","PM0R","PB0R","PBLC","PSVR","PO0R",
                "B0AP","PC0R","PCPT","PCPL","PCTL","PMTR","PpAR",
                "VD0R","ID0R","VD0r","ID0r","VP0R","IP0R","AC-W","ACFP","ACID","ACIC","D0IR","D0VR","D0VX"]
    print("ключ  тип  размер  значение")
    for k in keys {
        if let p = smc.probe(k) {
            print(String(format: "%-5@ %-5@ %d  %@", k as NSString, p.type as NSString, p.size,
                         p.value.map { String(format: "%.3f", $0) } ?? "—(тип не декодир.)"))
        }
    }
    exit(0)
}

// Зонд дисплея: перечислить доступные разрешения (read-only, ничего не меняет).
if ProcessInfo.processInfo.environment["BM_DISPLAYS"] != nil {
    if let c = ScreenResolution.current() { print("текущее: \(c.w) × \(c.h)") }
    print("доступные режимы:")
    for m in ScreenResolution.available() {
        print("  \(m.w) × \(m.h)\(m.hidpi ? "  (HiDPI)" : "")   [pixel \(m.cg.pixelWidth)×\(m.cg.pixelHeight)]")
    }
    exit(0)
}

// Зонд загрузки CPU/RAM (read-only).
if ProcessInfo.processInfo.environment["BM_USAGE"] != nil {
    let u = SystemUsage.shared
    _ = u.cpu()                                   // первый замер задаёт базу
    usleep(400_000)
    let c = u.cpu(), r = u.ram()
    print(String(format: "CPU: %.0f%%   RAM: %.0f%%", c * 100, r * 100))
    print(String(format: "RAM физически: %.1f ГБ", Double(ProcessInfo.processInfo.physicalMemory) / 1e9))
    exit(0)
}

// Крипто-самотест привязки лицензии (BM_LICTEST): проверяет HMAC-подпись и привязку к железу БЕЗ Keychain
// (значит без модалки SecurityAgent на ad-hoc сборке). Подделка сообщения/тега обязана проваливаться.
if ProcessInfo.processInfo.environment["BM_LICTEST"] != nil {
    let hw = MachineID.hardwareUUID
    let msg = "KEY-1234|inst-abcd|1720000000.0"
    let t = MachineID.tag(msg)
    let good = MachineID.verify(msg, tag: t)
    let badMsg = MachineID.verify(msg + "x", tag: t)                                   // подделан текст → должно быть false
    let badTag = MachineID.verify(msg, tag: String(t.dropLast()) + (t.hasSuffix("0") ? "1" : "0"))  // подделан тег → false
    let pass = good && !badMsg && !badTag && !hw.isEmpty
    print("LICTEST hwUUID=\(hw.isEmpty ? "EMPTY" : "present") tagLen=\(t.count) good=\(good) badMsg=\(badMsg) badTag=\(badTag) => \(pass ? "PASS" : "FAIL")")
    fflush(stdout)
    exit(pass ? 0 : 1)
}

// Диагностика авто-переключения раскладки (BM_LANGTEST): доступ + режим + прогон детектора.
if ProcessInfo.processInfo.environment["BM_LANGTEST"] != nil {
    print("AXIsProcessTrusted = \(AXIsProcessTrusted())")
    print("langMode(defaults) = \(SettingsStore.langMode)")
    print("snippetsEnabled=\(SettingsStore.snippetsEnabled) spellFix=\(SettingsStore.spellFixEnabled) isPro=\(Licensing.shared.isPro)")
    let samples = ["ghbdtn", "нуддщ", "rjnbr", "ghtdtn", "vfvf", "ntcn", "qwerty", "привет"]
    for w in samples {
        let conv = LangDetect.shouldConvert(w)
        let flip = LayoutMap.flip(word: w)
        print("  \(w.padding(toLength: 10, withPad: " ", startingAt: 0)) shouldConvert=\(conv)  flip=\(flip)")
    }
    fflush(stdout)
    exit(0)
}

// Снапшот-рендер поповера (BM_SNAP=<dir>): офскрин PNG каждой вкладки, БЕЗ окна/Screen-Recording-TCC.
// Идёт ДО single-instance guard (иначе установленная копия владельца выкинула бы нас) и до app.run().
if let snapDir = ProcessInfo.processInfo.environment["BM_SNAP"] {
    let snapApp = NSApplication.shared
    snapApp.setActivationPolicy(.accessory)
    let light = ProcessInfo.processInfo.environment["BM_LIGHT"] != nil
    // Раскладка снапшота (in-memory, НЕ трогаем UserDefaults владельца):
    //  • BM_SNAP_MIN → минимум (battery+toggles+flow): тест «растягивается+пусто».
    //  • BM_SNAP_ALL → ВСЕ модули: тест, что каждый рендерится (вкл. опц. консоль/диск/BT).
    //  • по умолчанию → ДЕФОЛТ (defaultOn) = что реально видит владелец (макет-композиция, без большого блока).
    if ProcessInfo.processInfo.environment["BM_SNAP_MIN"] != nil {
        PopoverController.snapshotLayout = [PopoverItem(id: "battery", on: true),
                                            PopoverItem(id: "toggles", on: true),
                                            PopoverItem(id: "flow", on: true)]
    } else if ProcessInfo.processInfo.environment["BM_SNAP_ALL"] != nil {
        PopoverController.snapshotLayout = PopoverModules.all.map { PopoverItem(id: $0.id, on: true) }
    } else {
        PopoverController.snapshotLayout = PopoverModules.all.map { PopoverItem(id: $0.id, on: PopoverModules.defaultOn.contains($0.id)) }
    }
    let snapCtl = PopoverController()
    let shots = snapCtl.renderSnapshots(to: snapDir, light: light)
    // окно Настроек — все секции (офскрин, без показа). Поповер-PNG уже на диске, даже если тут упадёт.
    let sset = KelvinSettingsWindowController.shared.renderSectionsSnapshot(to: snapDir, light: light, prefix: "S")
    OnboardingWindowController.shared.renderSnapshot(to: snapDir, light: light)   // стартовое окно разрешений
    CorrectionChoiceHUD.shared.renderSnapshot(to: snapDir, light: light)
    // PDF-отчёт «здоровье Mac» — визуальная проверка самого документа (из живой истории).
    let rbatt = BatteryReader.read()
    let rhs = History.shared.series(.health, since: Int64(Date().timeIntervalSince1970) - Int64(30 * 86_400))
    let rins = BatteryHealth.analyze(battery: rbatt, healthSeries: rhs)
    let rpdf = Report.healthReportPDF(period: 30 * 86_400, battery: rbatt, insight: rins)
    try? rpdf.write(to: URL(fileURLWithPath: snapDir + "/report.pdf"))
    print("SNAP_DONE popover=\(shots) settings=\(sset) -> \(snapDir)")
    fflush(stdout)
    exit(0)
}

// Single-instance: если копия уже запущена (автозапуск + ручной запуск) — выходим.
let bundleID = Bundle.main.bundleIdentifier ?? "com.trykelvin.kelvin"
let selfPID = ProcessInfo.processInfo.processIdentifier
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != selfPID }
if !others.isEmpty { exit(0) }

Log.installCrashHandlers()
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
Log.app.notice("Kelvin запущен (pid \(selfPID, privacy: .public), версия \(appVersion, privacy: .public))")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
