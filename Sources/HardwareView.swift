import AppKit
import QuartzCore

// MARK: — Геройный показатель шапки «Железа» (крупная цифра + тонкая полоска-уровень)

/// V4 (владелец: «круги с цифрами не очень красиво»): вместо дуги-кольца — плиточная грамматика
/// Control Center: КРУПНАЯ цифра, подпись под ней, тонкая 2pt полоска-андерлайн (цвет = уровень,
/// длина = доля шкалы). Два стиля: .hero (CPU/GPU, display-размер) и .chip (компакт: ГОРЯЧЕЕ/Вт/Турбо).
/// API set(...) сохранён 1-в-1 — applyGauges не меняется.
final class HeroGauge: NSView {
    enum Kind { case temp, watt, turbo, turboWarn }   // turbo = доля номинала (турбо/троттл), Warn = троттлинг под нагрузкой
    enum Style { case hero, chip }
    private let style: Style
    private let track = CALayer()          // подложка полоски
    private let fill = CALayer()           // заливка-доля (цвет = уровень)
    private let valueText = NSTextField(labelWithString: "—")
    private let capText = NSTextField(labelWithString: "")
    private var frac: CGFloat = 0
    private var kind: Kind = .temp
    private var accent: NSColor = .systemTeal
    private var axValue = "—"

    init(style: Style) { self.style = style; super.init(frame: .zero); commonInit() }
    override init(frame: NSRect) { self.style = .hero; super.init(frame: frame); commonInit() }
    required init?(coder: NSCoder) { self.style = .hero; super.init(coder: coder); commonInit() }
    override var isFlipped: Bool { false }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false
        track.cornerRadius = 1; fill.cornerRadius = 1
        layer?.addSublayer(track)
        layer?.addSublayer(fill)

        // Герой — display-цифра (20pt mono semibold), чип — тихая 12pt. Цифре больше не тесно в кольце.
        valueText.font = style == .hero ? Design.Font.mono(20, .semibold) : Design.Font.numericBody
        valueText.alignment = .left
        valueText.maximumNumberOfLines = 1
        valueText.lineBreakMode = .byClipping
        valueText.cell?.usesSingleLineMode = true
        valueText.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueText)
        capText.font = Design.Font.sys(style == .hero ? 11 : 9, .regular)
        capText.textColor = .tertiaryLabelColor
        capText.alignment = .left
        capText.maximumNumberOfLines = 1
        capText.lineBreakMode = .byTruncatingTail
        capText.translatesAutoresizingMaskIntoConstraints = false
        addSubview(capText)
        if style == .hero {
            NSLayoutConstraint.activate([
                valueText.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                valueText.topAnchor.constraint(equalTo: topAnchor, constant: 2),
                valueText.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
                capText.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                capText.topAnchor.constraint(equalTo: valueText.bottomAnchor, constant: 1),
                capText.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            ])
        } else {
            // чип: значение и подпись в одну строку (значение слева, подпись за ним «шёпотом»)
            NSLayoutConstraint.activate([
                valueText.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
                valueText.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
                capText.leadingAnchor.constraint(equalTo: valueText.trailingAnchor, constant: 5),
                capText.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
                capText.firstBaselineAnchor.constraint(equalTo: valueText.firstBaselineAnchor),
            ])
        }
    }

    override func layout() {
        super.layout()
        // полоска-уровень у нижней кромки: подложка во всю ширину, заливка = доля
        let barH: CGFloat = 2
        let w = bounds.width - 4
        track.frame = CGRect(x: 2, y: 1, width: w, height: barH)
        fill.frame = CGRect(x: 2, y: 1, width: w * frac, height: barH)
        updateColors()
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        track.backgroundColor = Design.Color.trackFill(isDark).cgColor
        fill.backgroundColor = accent.cgColor
    }

    /// Подать значение в гейдж. value — число (°C или Вт), text — готовая подпись цифры в центре,
    /// cap — подпись снизу. Цвет/доля дуги вычисляются по kind.
    /// level — ЧЕСТНЫЙ per-sensor уровень (Design.sensorLevel по id датчика); передаёт вызывающий,
    /// т.к. только он знает id. Без него (nil) для .temp падаем на общий Design.tempLevel.
    func set(value: Double?, text: String, cap: String, kind: Kind, level: Design.Level? = nil) {
        self.kind = kind
        capText.stringValue = cap
        axValue = text
        guard let v = value, v.isFinite else {
            valueText.stringValue = "—"
            frac = 0
            CATransaction.begin(); CATransaction.setDisableActions(true)
            fill.frame.size.width = 0; CATransaction.commit()
            return
        }
        valueText.stringValue = text
        switch kind {
        case .temp:
            frac = CGFloat(max(0, min(1, (v - 35) / 60)))     // 35°→0, 95°→1 (как чипы)
            let raw: NSColor
            switch level ?? Design.tempLevel(v) {             // честный порог датчика: CPU крит ≥100°, не ≥85°
            case .ok:   raw = Design.Color.levelOK
            case .warn: raw = Design.Color.levelWarn
            case .crit: raw = Design.Color.levelCrit
            }
            accent = isDark ? raw : (raw.blended(withFraction: 0.18, of: .black) ?? raw)
        case .watt:
            frac = CGFloat(max(0, min(1, v / 60)))            // 0..60 Вт шкала системы
            accent = Design.Color.accent(isDark)
        case .turbo:
            frac = CGFloat(max(0, min(1, v)))                 // доля номинала: 100%+ = полная дуга
            accent = Design.Color.accent(isDark)
        case .turboWarn:                                      // троттлинг: та же дуга, но оранжевая
            frac = CGFloat(max(0, min(1, v)))
            let o = Design.Color.levelWarn
            accent = isDark ? o : (o.blended(withFraction: 0.18, of: .black) ?? o)
        }
        valueText.textColor = .labelColor
        fill.backgroundColor = accent.cgColor
        // смена значения — плавная анимация ширины полоски (durValue), под reduced — мгновенно
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.reduced ? 0 : Design.Motion.durValue)
        fill.frame.size.width = max(0, (bounds.width - 4)) * frac
        CATransaction.commit()
    }

    /// Свип полоски с нуля при открытии вкладки (аналог прежнего дугового sweep).
    func animateIn() {
        let target = max(0, (bounds.width - 4)) * frac
        guard !Motion.reduced else { fill.frame.size.width = target; return }
        fill.frame.size.width = target
        let a = CABasicAnimation(keyPath: "bounds.size.width")
        a.fromValue = 0; a.toValue = target
        a.duration = Design.Motion.durSweep
        a.timingFunction = Design.Motion.easeStandard
        fill.add(a, forKey: "sweep")
    }

    // VoiceOver: индикатор уровня (роль/подпись/значение, как ChargeRing)
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .levelIndicator }
    override func accessibilityLabel() -> String? { capText.stringValue }
    override func accessibilityValue() -> Any? { axValue }
}

// MARK: — Строка каталога (класс-глиф + имя/FourCC + спарклайн + значение справа)

/// Одна строка скролл-ленты. Кликабельна (тап-пин), даёт VoiceOver и hover→разбор.
/// Геометрия трассы-спарклайна клонирует renderTrace из SensorsView (встыковые сегменты + кромка).
final class CatalogRowView: NSView {
    let id: String
    private let cls: SensorClass
    private let isRaw: Bool
    private let glyph = CALayer()
    private let nameLayer = CATextLayer()
    private let valueLayer = CATextLayer()
    private let trace = CALayer()
    private let line = CAShapeLayer()
    private let pinDot = CATextLayer()
    private let scale: CGFloat = 2

    var onHover: ((String?) -> Void)?
    var onClick: ((String) -> Void)?
    var axLabel = ""
    private(set) var pinned = false

    init(id: String, cls: SensorClass, isRaw: Bool) {
        self.id = id; self.cls = cls; self.isRaw = isRaw
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Design.Radius.hwTile; layer?.cornerCurve = .continuous   // B3: было 6
        layer?.masksToBounds = false

        glyph.contentsGravity = .resizeAspect; glyph.contentsScale = scale
        layer?.addSublayer(glyph)
        nameLayer.contentsScale = scale; nameLayer.truncationMode = .end; nameLayer.isWrapped = false
        layer?.addSublayer(nameLayer)
        valueLayer.contentsScale = scale; valueLayer.alignmentMode = .right
        valueLayer.truncationMode = .end; valueLayer.isWrapped = false
        layer?.addSublayer(valueLayer)
        trace.masksToBounds = false
        layer?.addSublayer(trace)
        line.fillColor = nil; line.lineWidth = 0.75; line.lineJoin = .round; line.lineCap = .round
        line.contentsScale = scale; line.isHidden = true
        trace.addSublayer(line)
        pinDot.contentsScale = scale; pinDot.alignmentMode = .right; pinDot.isHidden = true
        layer?.addSublayer(pinDot)
        focusRingType = .default
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    override func layout() {
        super.layout()
        let h = bounds.height, w = bounds.width
        let isz: CGFloat = 12
        glyph.frame = CGRect(x: 4, y: (h - isz) / 2, width: isz, height: isz)
        // значение справа (моноширинно), спарклайн слева от него
        let valW: CGFloat = 70
        // высота слоёв 16 (было 13) — 12-13pt шрифт с нижними выносными («р»/«у»/«ф») больше не клиппится снизу
        valueLayer.frame = CGRect(x: w - valW - 2, y: (h - 16) / 2, width: valW, height: 16)
        let traceW: CGFloat = 34, traceH: CGFloat = 12
        trace.frame = CGRect(x: w - valW - traceW - 8, y: (h - traceH) / 2, width: traceW, height: traceH)
        let nameX = 4 + isz + 6
        nameLayer.frame = CGRect(x: nameX, y: (h - 16) / 2, width: trace.frame.minX - nameX - 6, height: 16)
        pinDot.frame = CGRect(x: w - valW - 2, y: 1, width: valW, height: 8)
    }

    private func capsTint() -> NSColor {
        switch cls {
        case .temp:  return isDark ? .systemOrange : (NSColor.systemOrange.blended(withFraction: 0.2, of: .black) ?? .systemOrange)
        case .volt:  return isDark ? .systemYellow : (NSColor.systemYellow.blended(withFraction: 0.2, of: .black) ?? .systemYellow)
        case .curr:  return isDark ? .systemTeal : (NSColor.systemTeal.blended(withFraction: 0.2, of: .black) ?? .systemTeal)
        case .power: return isDark ? .systemOrange : (NSColor.systemOrange.blended(withFraction: 0.2, of: .black) ?? .systemOrange)
        case .fan:   return isDark ? .systemTeal : (NSColor.systemTeal.blended(withFraction: 0.2, of: .black) ?? .systemTeal)
        case .batt:  return isDark ? .systemGreen : (NSColor.systemGreen.blended(withFraction: 0.2, of: .black) ?? .systemGreen)
        case .other: return .secondaryLabelColor
        }
    }
    private func glyphSymbol() -> String {
        switch cls {
        case .temp:  return "thermometer.medium"
        case .volt:  return "bolt.fill"
        case .curr:  return "bolt.horizontal.fill"
        case .power: return "powerplug.fill"
        case .fan:   return "fanblades.fill"
        case .batt:  return "battery.50"
        case .other: return "number"
        }
    }

    private var glyphSet = false                 // глиф растеризуется один раз (не каждый тик)
    private var lastAppliedText = ""             // скип-кэш: неизменившаяся строка не перерисовывается
    private var lastHistLast: Double?
    private var lastHistFirst: Double?           // первый+count в ключе: окно истории сдвигается и при стабильном значении
    private var lastHistCount = -1

    func apply(_ row: CatalogRow, pinned: Bool, animate: Bool) {
        // СКИП неизменившихся: у большинства видимых строк значение стабильно между тиками —
        // без раннего выхода каждая перерисовывала attrString+трассу ежесекундно (вклад во фризы).
        // В ключе и КРАЯ истории (first/count): иначе трасса замирала бы, пока старый пик уезжает из окна.
        if glyphSet, lastAppliedText == row.text, lastHistLast == row.history.last,
           lastHistFirst == row.history.first, lastHistCount == row.history.count, self.pinned == pinned { return }
        self.pinned = pinned
        lastAppliedText = row.text
        lastHistLast = row.history.last
        lastHistFirst = row.history.first
        lastHistCount = row.history.count
        let tint = capsTint()
        let nameStr = row.key.displayName
        let nameFont: NSFont = isRaw ? Design.Font.numericBody : Design.Font.body
        let nameColor: NSColor = row.key.decodable ? .labelColor : .tertiaryLabelColor
        nameLayer.font = nameFont; nameLayer.fontSize = nameFont.pointSize
        nameLayer.string = nameStr
        nameLayer.foregroundColor = nameColor.cgColor
        valueLayer.font = Design.Font.numericBody; valueLayer.fontSize = Design.Font.numericBody.pointSize
        valueLayer.string = valueAttr(row)
        if !glyphSet { glyph.contents = symbolCG(glyphSymbol(), tint, 12); glyphSet = true }
        pinDot.string = pinned ? NSAttributedString(string: "•",
            attributes: [.font: Design.Font.numericMicro, .foregroundColor: tint]) : nil
        pinDot.isHidden = !pinned
        axLabel = axText(row)
        CATransaction.begin()
        CATransaction.setAnimationDuration((animate && !Motion.reduced) ? Design.Motion.durValue : 0)
        renderTrace(row.history, tint, decodable: row.key.decodable)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        glyphSet = false; lastAppliedText = ""    // тинт тема-зависим — глиф и строка перерастеризуются
    }

    /// Значение right-aligned: число метрикой, единица «шёпотом» (tertiary). Недекодируемое — приглушённо целиком.
    private func valueAttr(_ row: CatalogRow) -> NSAttributedString {
        let p = NSMutableParagraphStyle(); p.alignment = .right; p.lineBreakMode = .byTruncatingTail
        guard row.key.decodable, row.value != nil else {
            // Недекодируемое: длинная фраза «значение не декодируется» рвалась в 70pt-колонке →
            // показываем «—», полное объяснение остаётся в hover-разборе (rowDetail/axText).
            return NSAttributedString(string: "—", attributes: [
                .font: Design.Font.numericBody, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: p])
        }
        // отделяем единицу (последнее слово после пробела) — печатаем её шёпотом
        let t = row.text
        let a = NSMutableAttributedString()
        if let sp = t.lastIndex(of: " ") {
            let num = String(t[..<sp]); let unit = String(t[t.index(after: sp)...])
            a.append(NSAttributedString(string: num + " ", attributes: [
                .font: Design.Font.numericBody, .foregroundColor: NSColor.labelColor, .paragraphStyle: p]))
            a.append(NSAttributedString(string: unit, attributes: [
                .font: Design.Font.numericMicro, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: p]))
        } else {
            a.append(NSAttributedString(string: t, attributes: [
                .font: Design.Font.numericBody, .foregroundColor: NSColor.labelColor, .paragraphStyle: p]))
        }
        return a
    }

    private func axText(_ row: CatalogRow) -> String {
        if !row.key.decodable {
            return "\(row.key.fourCC) · " + L("сырой ключ · значение не декодируется")
        }
        let prefix = row.key.isRaw ? row.key.fourCC + " · " : row.key.displayName + " · "
        return prefix + row.text
    }

    /// Мини-спарклайн сессии (встыковые сегменты + кромка) — клон грамматики renderTrace из SensorsView.
    private func renderTrace(_ hist: [Double], _ base: NSColor, decodable: Bool) {
        let band = trace.bounds
        let W = band.width, H = band.height
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var segs = trace.sublayers?.filter { $0 !== line } ?? []
        guard W > 1, decodable, hist.count >= 2 else {
            segs.forEach { $0.isHidden = true }
            line.isHidden = true
            return
        }
        let lo = hist.min() ?? 0, hi = hist.max() ?? 1
        let span = max(hi - lo, 0.0001)
        func norm(_ v: Double) -> CGFloat { CGFloat(max(0, min(1, (v - lo) / span))) }
        let count = hist.count
        let segW = W / CGFloat(count)
        let segWidth = segW + 0.5
        let minBar: CGFloat = 1
        while segs.count < count { let l = CALayer(); trace.insertSublayer(l, below: line); segs.append(l) }
        for i in count..<segs.count { segs[i].isHidden = true }
        let edge = CGMutablePath()
        for (i, v) in hist.enumerated() {
            let seg = segs[i]; seg.isHidden = false; seg.removeAllAnimations()
            let hgt = max(minBar, norm(v) * H)
            let x = CGFloat(i) * segW
            let wd = (i == count - 1) ? max(W - x, segWidth) : segWidth
            seg.frame = CGRect(x: x, y: H - hgt, width: wd, height: hgt)
            seg.backgroundColor = base.withAlphaComponent(0.55).cgColor
            if i == 0 { edge.move(to: CGPoint(x: x, y: H - hgt)) } else { edge.addLine(to: CGPoint(x: x, y: H - hgt)) }
            edge.addLine(to: CGPoint(x: x + segW, y: H - hgt))
        }
        line.path = edge; line.strokeColor = base.cgColor; line.isHidden = false
    }

    // hover + click + VoiceOver
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { setHover(true); onHover?(id) }
    override func mouseExited(with event: NSEvent) { setHover(false); onHover?(nil) }
    override func mouseDown(with event: NSEvent) { onClick?(id) }
    private var hoverOn = false
    /// Снять подсветку извне (скролл увозит строку из-под неподвижного курсора — mouseExited НЕ приходит,
    /// строка «залипала» цветной). Идемпотентно: no-op, если подсветки нет.
    func clearHover() { setHover(false) }
    private func setHover(_ on: Bool) {
        guard on != hoverOn else { return }                 // идемпотентность: O(строк) только на первом кадре скролла
        hoverOn = on
        CATransaction.begin(); CATransaction.setAnimationDuration(Motion.reduced ? 0 : Design.Motion.durFast)
        layer?.backgroundColor = on ? capsTint().withAlphaComponent(isDark ? 0.10 : 0.12).cgColor : NSColor.clear.cgColor
        CATransaction.commit()
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { onHover?(id); return true }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: Design.Radius.hwTile, yRadius: Design.Radius.hwTile).fill() }   // B3: было 6
    override var focusRingMaskBounds: NSRect { bounds }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { axLabel + (pinned ? " · " + L("открепить") : " · " + L("закрепить")) }

    private func symbolCG(_ name: String, _ color: NSColor, _ pt: CGFloat) -> CGImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .semibold).applying(.init(paletteColors: [color]))
        let img = base.withSymbolConfiguration(cfg) ?? base
        var r = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }
}

// MARK: — Заголовок секции / строка диагностики (лёгкие плоские вью документа)

private final class SectionHeaderView: NSView {
    private let label = CATextLayer()
    private let chevron = CATextLayer()
    let key: String
    var collapsible = false
    var onToggle: (() -> Void)?
    private let scale: CGFloat = 2
    init(key: String, title: String) {
        self.key = key
        super.init(frame: .zero); wantsLayer = true
        // V3: секц-заголовки обычным регистром (как sectionLabel поповера) — без CAPS/kern «самодельного дашборда».
        let hFont = Design.Font.sys(11, .medium)
        label.contentsScale = scale; label.truncationMode = .end
        label.font = hFont; label.fontSize = hFont.pointSize
        label.foregroundColor = NSColor.secondaryLabelColor.cgColor
        label.string = NSAttributedString(string: title,
            attributes: [.font: hFont, .foregroundColor: NSColor.secondaryLabelColor])
        layer?.addSublayer(label)
        chevron.contentsScale = scale; chevron.foregroundColor = NSColor.tertiaryLabelColor.cgColor
        chevron.font = Design.Font.micro; chevron.fontSize = Design.Font.micro.pointSize
        chevron.isHidden = true
        layer?.addSublayer(chevron)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    func setExpanded(_ e: Bool) {
        chevron.isHidden = !collapsible
        chevron.string = NSAttributedString(string: e ? "▾" : "▸",
            attributes: [.font: Design.Font.micro, .foregroundColor: NSColor.tertiaryLabelColor])
    }
    override func layout() {
        super.layout()
        label.frame = CGRect(x: 2, y: bounds.height - 14, width: bounds.width - 16, height: 12)
        chevron.frame = CGRect(x: bounds.width - 12, y: bounds.height - 14, width: 12, height: 12)
    }
    override func mouseDown(with event: NSEvent) { if collapsible { onToggle?() } }
    override func isAccessibilityElement() -> Bool { collapsible }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { (label.string as? NSAttributedString)?.string }
}

private final class EngineRowView: NSView {
    private let labelLayer = CATextLayer()
    private let valueLayer = CATextLayer()
    private let scale: CGFloat = 2
    init(_ row: EngineRow) {
        super.init(frame: .zero); wantsLayer = true
        labelLayer.contentsScale = scale; labelLayer.truncationMode = .end
        labelLayer.font = Design.Font.caption; labelLayer.fontSize = Design.Font.caption.pointSize
        labelLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
        labelLayer.string = row.label
        layer?.addSublayer(labelLayer)
        valueLayer.contentsScale = scale; valueLayer.alignmentMode = .right
        valueLayer.truncationMode = .end; valueLayer.font = Design.Font.numericMicro
        valueLayer.fontSize = Design.Font.numericMicro.pointSize
        valueLayer.foregroundColor = NSColor.tertiaryLabelColor.cgColor
        valueLayer.string = row.value
        layer?.addSublayer(valueLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    /// Обновление значения на месте (без пересоздания вью каждый тик).
    func update(_ row: EngineRow) {
        labelLayer.string = row.label
        CATransaction.begin(); CATransaction.setDisableActions(true)
        valueLayer.string = row.value
        CATransaction.commit()
    }
    override func layout() {
        super.layout()
        labelLayer.frame = CGRect(x: 4, y: (bounds.height - 12) / 2, width: bounds.width * 0.5, height: 12)
        valueLayer.frame = CGRect(x: bounds.width * 0.42, y: (bounds.height - 12) / 2, width: bounds.width * 0.58 - 4, height: 12)
    }
}

// MARK: — Документ скролла (flipped, растёт)

private final class FlippedDoc: NSView {
    override var isFlipped: Bool { true }
}

// MARK: — Главный гибридный вид «Железо»

final class HardwareView: NSView {
    // фикс-высоты областей (контракт B0): корневой intrinsic фиксирован → maxH вкладки стабилен.
    // panelH — ПОТОЛОК (по умолчанию); фактическую высоту панели задаёт хост через setPanelHeight,
    // чтобы вкладка «Железо» вместе с GPU-хромом не делала поповер выше остальных вкладок (Д3).
    static let panelH: CGFloat = 340
    private let minPanelH: CGFloat = 160     // не схлопываем ленту в полоску, даже если потолок низкий
    private var panelHeight: CGFloat = panelH
    private var panelHeightConstraint: NSLayoutConstraint?
    private let IW: CGFloat = 272
    private let headerH: CGFloat = 78        // ряд из 5 гейджей (CPU/GPU/ГОРЯЧЕЕ/Вт/ТУРБО)
    private let searchH: CGFloat = 26

    /// Разбор под панелью (как и у SensorsView) — наведение строки/гейджа → детали.
    var detailSink: ((String) -> Void)?

    // V4: [CPU-герой, GPU-герой, чип-ГОРЯЧЕЕ, чип-Вт, чип-Турбо] — индексы те же, applyGauges не меняется
    private let gauges: [HeroGauge] = [HeroGauge(style: .hero), HeroGauge(style: .hero),
                                       HeroGauge(style: .chip), HeroGauge(style: .chip), HeroGauge(style: .chip)]
    private let search = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let doc = FlippedDoc()

    private var rowViews: [String: CatalogRowView] = [:]
    private var headerViews: [SectionHeaderView] = []
    private var engineViews: [EngineRowView] = []
    private var placeholder: NSTextField?

    private var lastSnapshot = SensorsSnapshot()
    private var lastComponents = ComponentPower()
    private var lastEnergy = EnergySnapshot()

    // секции в фикс-порядке (контракт); .other = РАСШИРЕННЫЕ (аккордеон, свёрнут)
    private var expandedRaw = false
    private var pinned: [String] = (UserDefaults.standard.array(forKey: "hardware.pinned") as? [String]) ?? []
    private var query = ""
    private var hovered: String?

    private let rowH: CGFloat = 24     // было 22 — +2 воздуха, чтобы текст датчиков не подрезался снизу
    private let headH: CGFloat = 20
    private let engRowH: CGFloat = 16

    override init(frame: NSRect) { super.init(frame: frame); commonInit() }
    required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }
    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: IW, height: panelHeight) }

    /// Хост задаёт фактическую высоту панели (скролл-viewport = высота − шапка-гейджи − поиск).
    /// Гейджи/поиск приколоты к верху, скролл прижат низом → уменьшение высоты ужимает именно ленту,
    /// а лента продолжает скроллить в фикс-высоте. Не ниже minPanelH.
    func setPanelHeight(_ h: CGFloat) {
        let clamped = max(minPanelH, h)
        guard abs(clamped - panelHeight) > 0.5 else { return }
        panelHeight = clamped
        panelHeightConstraint?.constant = clamped
        invalidateIntrinsicContentSize()
    }
    /// Текущая ФАКТИЧЕСКАЯ высота панели. Хост (buildModules) обязан считать «хром» вкладки от неё,
    /// а НЕ от статической panelH: panelHeight персистентна и дрейфует между ребилдами, поэтому расчёт
    /// от константы 340 заставлял поповер осциллировать (чётный тумбл — норма, нечётный — раздув +100pt).
    var currentPanelHeight: CGFloat { panelHeight }
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { L("Сенсоры") }

    private func commonInit() {
        wantsLayer = true; layer?.masksToBounds = false
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: IW).isActive = true
        let hc = heightAnchor.constraint(equalToConstant: panelHeight)
        hc.isActive = true
        panelHeightConstraint = hc

        // — шапка V4: 2 героя (CPU/GPU, крупная цифра) слева + столбик 3 тихих чипов (ГОРЯЧЕЕ/Вт/Турбо) справа —
        let heroPair = NSStackView(views: [gauges[0], gauges[1]])
        heroPair.distribution = .fillEqually; heroPair.spacing = 8
        heroPair.translatesAutoresizingMaskIntoConstraints = false
        heroPair.widthAnchor.constraint(equalToConstant: 168).isActive = true
        let chipCol = NSStackView(views: [gauges[2], gauges[3], gauges[4]])
        chipCol.orientation = .vertical; chipCol.spacing = 2; chipCol.alignment = .leading
        chipCol.distribution = .fillEqually
        chipCol.translatesAutoresizingMaskIntoConstraints = false
        for c in [gauges[2], gauges[3], gauges[4]] { c.widthAnchor.constraint(equalToConstant: 96).isActive = true }
        let gaugeRow = NSStackView(views: [heroPair, chipCol])
        gaugeRow.spacing = 8
        gaugeRow.alignment = .centerY
        gaugeRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gaugeRow)

        // — строка поиска + счётчик —
        search.placeholderString = L("Поиск по сенсорам")
        search.translatesAutoresizingMaskIntoConstraints = false
        search.controlSize = .small
        search.font = Design.Font.caption
        search.target = self; search.action = #selector(searchChanged)
        addSubview(search)
        countLabel.font = Design.Font.microStat; countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .right; countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        // — скролл —
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .allowed
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        addSubview(scroll)
        // Сброс hover при СКРОЛЛЕ: mouseExited не приходит, когда строка уезжает из-под неподвижного
        // курсора → подсветка «залипала» (жалоба владельца). Идемпотентный clearHover делает это O(1)
        // после первого кадра. Стандартное поведение macOS-списков: hover гаснет до движения мыши.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.rowViews.values.forEach { $0.clearHover() }
            self.setHover(nil)                              // и строку разбора внизу — к сводке
        }

        NSLayoutConstraint.activate([
            gaugeRow.topAnchor.constraint(equalTo: topAnchor),
            gaugeRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            gaugeRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            gaugeRow.heightAnchor.constraint(equalToConstant: headerH),

            search.topAnchor.constraint(equalTo: gaugeRow.bottomAnchor, constant: 4),
            search.leadingAnchor.constraint(equalTo: leadingAnchor),
            search.heightAnchor.constraint(equalToConstant: searchH),
            countLabel.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            countLabel.leadingAnchor.constraint(equalTo: search.trailingAnchor, constant: 6),
            countLabel.widthAnchor.constraint(equalToConstant: 64),

            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @objc private func searchChanged() {
        query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        relayout(animate: !Motion.reduced)
    }

    // MARK: построение строк (один раз/при смене состава) + раскладка

    private struct Section { let key: String; let title: String; let cls: SensorClass?; let collapsible: Bool }
    private static let sectionDefs: [Section] = [
        Section(key: "temp",  title: L("Температуры"), cls: .temp,  collapsible: false),
        Section(key: "volt",  title: L("Вольтажи"),    cls: .volt,  collapsible: false),
        Section(key: "curr",  title: L("Токи"),        cls: .curr,  collapsible: false),
        Section(key: "power", title: L("Питание"),     cls: .power, collapsible: false),
        Section(key: "fan",   title: L("Вентиляторы"), cls: .fan,   collapsible: false),
        Section(key: "batt",  title: L("Нагрузка"),    cls: .batt,  collapsible: false),
        Section(key: "raw",   title: L("Сырые ключи"), cls: nil,    collapsible: true),   // ВСЕ некураторские (любой класс), свёрнуто
    ]

    /// ЛЕНИВОЕ создание вью строки: раньше ensureRows строил вью на ВСЕ ~600 ключей (сотни CALayer +
    /// NSTrackingArea) — AppKit пересчитывал сотни tracking-областей на каждый скролл → «курсор залипает».
    /// Теперь вью материализуется только когда строка реально размещается (именованные + пины + раскрытое сырьё).
    private func makeRow(_ id: String) -> CatalogRowView? {
        if let rv = rowViews[id] { return rv }
        guard let key = SensorCatalog.catalog().first(where: { $0.id == id }) else { return nil }
        let rv = CatalogRowView(id: key.id, cls: key.cls, isRaw: key.isRaw)
        rv.translatesAutoresizingMaskIntoConstraints = false
        rv.onHover = { [weak self] id in self?.setHover(id) }
        rv.onClick = { [weak self] id in self?.togglePin(id) }
        doc.addSubview(rv)
        rowViews[key.id] = rv
        // Немедленное первичное наполнение (одноразовое чтение при материализации): иначе до первого
        // тика строка стояла бы ПУСТОЙ (имя/значение ставит только apply) — некрасивый первый кадр.
        let row = SensorCatalog.row(for: key, record: false)
        lastRows[key.id] = row
        rv.apply(row, pinned: pinned.contains(key.id), animate: false)
        return rv
    }

    /// Заголовки секций/движка (лёгкие, один раз). Строки каталога создаются ЛЕНИВО в placeRow.
    private func ensureRows() {
        guard headerViews.isEmpty else { return }
        // заголовки секций
        for def in Self.sectionDefs {
            let hv = SectionHeaderView(key: def.key, title: def.title)
            hv.collapsible = def.collapsible
            hv.setExpanded(def.key == "raw" ? expandedRaw : true)
            if def.collapsible {
                hv.onToggle = { [weak self] in
                    guard let self else { return }
                    self.expandedRaw.toggle()
                    hv.setExpanded(self.expandedRaw)
                    self.relayout(animate: !Motion.reduced)
                }
            }
            doc.addSubview(hv)
            headerViews.append(hv)
        }
        // заголовок ЗАКРЕПЛЁННЫЕ + ДВИЖОК — создаются в общем списке через placeholders в relayout
        let pinHeader = SectionHeaderView(key: "pinned", title: L("Закреплённые"))
        doc.addSubview(pinHeader); headerViews.append(pinHeader)
        let engHeader = SectionHeaderView(key: "engine", title: L("Движок"))
        doc.addSubview(engHeader); headerViews.append(engHeader)
    }

    /// Видимые id строк (для tick: read() ТОЛЬКО их). = строки в documentVisibleRect, не скрытые.
    func visibleIDs() -> Set<String> {
        // вкладка не на экране (скрыта/без окна) — скрытая плитка сохраняет frame, поэтому
        // documentVisibleRect остаётся непустым; без этого гейта каталог читал бы SMC на чужих
        // вкладках (~15 read()/тик впустую). Пустой Set → snapshot() не зовёт ни одного read().
        guard window != nil && !isHiddenOrHasHiddenAncestor else { return [] }
        let vis = scroll.documentVisibleRect
        var out = Set<String>()
        for (id, rv) in rowViews where !rv.isHidden {
            if rv.frame.intersects(vis) { out.insert(id) }
        }
        return out
    }

    private func header(_ key: String) -> SectionHeaderView? { headerViews.first { $0.key == key } }

    /// Раскладка документа сверху-вниз по фикс-порядку секций; фильтр по query; аккордеон сырых.
    private func relayout(animate: Bool) {
        ensureRows()
        // все строки/заголовки сначала прячем — покажем только размещённые
        rowViews.values.forEach { $0.isHidden = true }
        headerViews.forEach { $0.isHidden = true }
        engineViews.forEach { $0.isHidden = true }

        let cat = SensorCatalog.catalog()
        func matches(_ k: CatalogKey) -> Bool {
            guard !query.isEmpty else { return true }
            return k.fourCC.lowercased().contains(query)
                || k.displayName.lowercased().contains(query)
                || SensorClass.titleFor(k.cls).lowercased().contains(query)
        }

        var y: CGFloat = 0
        let W = doc.bounds.width > 1 ? doc.bounds.width : (scroll.bounds.width > 1 ? scroll.bounds.width : IW)

        func placeHeader(_ key: String) {
            guard let hv = header(key) else { return }
            hv.isHidden = false
            hv.frame = CGRect(x: 0, y: y, width: W, height: headH)
            hv.needsLayout = true
            y += headH
        }
        func placeRow(_ id: String) {
            guard let rv = makeRow(id) else { return }   // ленивое создание: вью есть только у размещаемых строк
            rv.isHidden = false
            rv.frame = CGRect(x: 0, y: y, width: W, height: rowH)
            rv.needsLayout = true
            y += rowH
        }

        // Подчистка «мёртвых» пинов: id, которого больше нет в каталоге (датчик пропал), был бы
        // невидим и неубираем через UI — выкидываем его из закреплённых (query-независимо).
        let stalePruned = pinned.filter { id in cat.contains { $0.id == id } }
        if stalePruned.count != pinned.count {
            pinned = stalePruned
            UserDefaults.standard.set(pinned, forKey: "hardware.pinned")
        }

        // 1) ЗАКРЕПЛЁННЫЕ (если есть и проходят фильтр поиска)
        let pinnedShown = pinned.filter { id in cat.contains { $0.id == id && matches($0) } }
        if !pinnedShown.isEmpty {
            placeHeader("pinned")
            for id in pinnedShown { placeRow(id) }
        }

        // 2) секции: основные показывают ТОЛЬКО именованные датчики (без сырья/дублей → чисто «в тему»),
        //    «Сырые ключи» — ВСЕ некураторские FourCC (любой класс), свёрнуто (мусор не мозолит глаз).
        // Закреплённые исключаем из обычных секций — иначе одна и та же вью строки размещалась бы
        // дважды (в «Закреплённые» и в своей секции), второе размещение перетирало первое → под
        // «Закреплённые» пусто (жалоба владельца: «закреплённые невидимы и не убираются»).
        let pinnedSet = Set(pinned)
        for def in Self.sectionDefs {
            let keys: [CatalogKey]
            if let cls = def.cls {
                keys = cat.filter { $0.cls == cls && !$0.isRaw && matches($0) && !pinnedSet.contains($0.id) }
            } else {
                keys = cat.filter { $0.isRaw && matches($0) && !pinnedSet.contains($0.id) }
            }
            guard !keys.isEmpty else { continue }
            let hv = header(def.key)
            hv?.isHidden = false
            hv?.frame = CGRect(x: 0, y: y, width: W, height: headH)
            hv?.needsLayout = true
            y += headH
            if def.key == "raw" && !expandedRaw && query.isEmpty {
                continue   // сырые свёрнуты по умолчанию (но при активном поиске — показываем)
            }
            for k in keys { placeRow(k.id) }
        }

        // 3) ДВИЖОК (диагностика) — только без активного поиска
        if query.isEmpty {
            placeHeader("engine")
            ensureEngineViews()
            for ev in engineViews {
                ev.isHidden = false
                ev.frame = CGRect(x: 0, y: y, width: W, height: engRowH)
                y += engRowH
            }
        }

        // 4) плейсхолдер «ничего не найдено»
        let anyShown = rowViews.values.contains { !$0.isHidden }
        if !anyShown && !query.isEmpty {
            let ph = ensurePlaceholder()
            ph.isHidden = false
            ph.frame = NSRect(x: 8, y: y, width: W - 16, height: 18)
            y += 18 + 6
        } else { placeholder?.isHidden = true }

        let docH = max(y + 8, scroll.contentSize.height)
        if animate {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Design.Motion.durBase
                doc.animator().frame = NSRect(x: 0, y: 0, width: W, height: docH)
            }
        } else {
            doc.frame = NSRect(x: 0, y: 0, width: W, height: docH)
        }
        updateCount(cat)
    }

    private func updateCount(_ cat: [CatalogKey]) {
        if query.isEmpty {
            // по умолчанию считаем ИМЕНОВАННЫЕ датчики (не 660 сырых ключей — это и есть «мусор» на виду)
            let n = cat.filter { !$0.isRaw }.count
            countLabel.stringValue = "\(n) " + SettingsStore.plural(n, L("датчик"), L("датчика"), L("датчиков"))
        } else {
            // при поиске — совпадение ТЕМИ ЖЕ тремя ветками, что и relayout.matches (иначе счётчик врал «0»)
            let n = cat.filter { k in
                k.fourCC.lowercased().contains(query)
                    || k.displayName.lowercased().contains(query)
                    || SensorClass.titleFor(k.cls).lowercased().contains(query)
            }.count
            countLabel.stringValue = "\(n) " + SettingsStore.plural(n, L("ключ"), L("ключа"), L("ключей"))
        }
    }

    private func ensurePlaceholder() -> NSTextField {
        if let p = placeholder { return p }
        let l = NSTextField(labelWithString: L("ничего не найдено"))
        l.font = Design.Font.caption; l.textColor = .tertiaryLabelColor
        l.isBezeled = false; l.drawsBackground = false; l.isEditable = false
        doc.addSubview(l); placeholder = l
        return l
    }

    /// Диагностические строки движка: создаём один раз, дальше обновляем значения на месте (без пересоздания/мерцания).
    private func ensureEngineViews() {
        let rows = SensorCatalog.engineDiagnostics(components: lastComponents, energy: lastEnergy)
        if engineViews.count != rows.count {
            engineViews.forEach { $0.removeFromSuperview() }
            engineViews = rows.map { let ev = EngineRowView($0); doc.addSubview(ev); return ev }
        } else {
            for (ev, r) in zip(engineViews, rows) { ev.update(r) }
        }
    }

    // MARK: вход данных

    /// Геройные гейджи питаются из кураторского снимка (как раньше SensorsView.update).
    func update(_ s: SensorsSnapshot) {
        lastSnapshot = s
        applyGauges()
        emitDetail()
    }

    /// Последний снимок каждой строки (для hover-разбора БЕЗ синхронного SMC-syscall на main:
    /// раньше каждый mouseEntered читал SMC — серия чтений при проводке мыши = «залипание» курсора).
    private var lastRows: [String: CatalogRow] = [:]

    /// Каталог-строки + диагностика. Зовётся из тика. read() уже выполнен слоем данных ТОЛЬКО для видимых id.
    func updateCatalog(rows: [CatalogRow], components: ComponentPower, energy: EnergySnapshot) {
        lastComponents = components; lastEnergy = energy
        ensureRows()
        // первая раскладка — после того, как скролл получил ширину (иначе документ нулевой)
        if doc.frame.height < 1 { relayout(animate: false) }
        let pinnedSet = Set(pinned)
        for row in rows {                                  // значения видимых строк (read() уже сделан слоем данных)
            lastRows[row.key.id] = row                     // кэш для hover-разбора (без новых SMC-чтений)
            rowViews[row.key.id]?.apply(row, pinned: pinnedSet.contains(row.key.id), animate: true)
        }
        // диагностика движка — обновляем значения НА МЕСТЕ (без полного релэйаута/мерцания каждый тик)
        if !engineViews.isEmpty { ensureEngineViews() }
    }

    private func applyGauges() {
        let temps = lastSnapshot.temps
        let cpu = temps.first { $0.id == "cpu" }
        let gpu = temps.first { $0.id == "gpu" }
        // «ГОРЯЧЕЕ» раньше = max по ВСЕМ → почти всегда сам CPU (дубль гейджа CPU). Честный дедуп:
        // самый горячий датчик СРЕДИ ОСТАЛЬНЫХ (не CPU/GPU, они уже слева) + подпись его именем —
        // так гейдж несёт НОВУЮ инфу (напр. «ПАМЯТЬ 55°»), а не повторяет CPU.
        let shownIDs: Set<String> = ["cpu", "cpupkg", "gpu"]
        let hot = temps.filter { !shownIDs.contains($0.id) }.max { $0.value < $1.value }
        // системный ватт (PSTR) или честный fallback CPU+GPU (без DRAM/прочего) —
        // при fallback подпись честно помечает источник, не выдавая частичное за полный ватт
        let partial = !(lastEnergy.systemWatts > 0.1)
        let watts = partial ? ((lastComponents.cpu ?? 0) + (lastComponents.gpu ?? 0))
                            : lastEnergy.systemWatts

        gauges[0].set(value: cpu?.value, text: cpu?.text ?? "—", cap: "CPU", kind: .temp,
                      level: cpu.map { Design.sensorLevel(id: "cpu", $0.value) })
        gauges[1].set(value: gpu?.value, text: gpu?.text ?? "—", cap: "GPU", kind: .temp,
                      level: gpu.map { Design.sensorLevel(id: "gpu", $0.value) })
        gauges[2].set(value: hot?.value, text: hot.map { String(format: "%.0f°", $0.value) } ?? "—",
                      cap: hot.map { $0.name } ?? L("Прочее"), kind: .temp,
                      level: hot.map { Design.sensorLevel(id: $0.id, $0.value) })
        gauges[3].set(value: watts > 0 ? watts : nil,
                      text: watts > 0 ? String(format: "%.0f", watts) : "—",
                      cap: (partial && watts > 0) ? L("CPU+GPU Вт") : L("Вт"), kind: .watt)
        // ТУРБО: частота как доля номинала (powermetrics System Average). Троттлинг честно — только когда
        // низкая частота ПРИ ВЫСОКОЙ нагрузке (иначе низкая частота = простой/энергосбережение, не троттл).
        // Гейт на свежесть сэмпла: устаревший power.txt → «—», не показываем протухший турбо/троттл.
        let ff = lastComponents.fresh ? lastComponents.freqFraction : nil
        let load = SystemUsage.shared.cpu()               // 0..1, кэш-за-тик
        let throttling = (ff ?? 1) < 0.90 && load > 0.75
        gauges[4].set(value: ff, text: ff.map { String(format: "%.0f%%", $0 * 100) } ?? "—",
                      cap: throttling ? L("Троттл") : L("Частота"),   // «Турбо 117%» было непонятно; тултип объясняет >100%
                      kind: throttling ? .turboWarn : .turbo)
        // Честное пояснение >100% (иначе «ТУРБО 134%» читается как ошибка): это доля базовой частоты.
        gauges[4].toolTip = throttling
            ? L("Частота ниже базовой при высокой нагрузке — троттлинг.")
            : L("Частота как доля базовой; выше 100% — турбо-буст (это норма).")
    }

    /// Свип гейджей при показе вкладки.
    func animateIn() { gauges.forEach { $0.animateIn() } }

    // MARK: пины

    private func togglePin(_ id: String) {
        if let i = pinned.firstIndex(of: id) {
            pinned.remove(at: i)
        } else {
            pinned.append(id)
            flyToPin(id)
        }
        UserDefaults.standard.set(pinned, forKey: "hardware.pinned")
        relayout(animate: !Motion.reduced)
    }

    /// fly-to-pin: дубль-слой строки летит к секции ЗАКРЕПЛЁННЫЕ (вверх). Под reduced — мгновенно.
    private func flyToPin(_ id: String) {
        guard !Motion.reduced, let rv = rowViews[id], let host = doc.layer else { return }
        let ghost = CALayer()
        ghost.frame = rv.frame                          // rv — прямой сабвью doc, frame уже в координатах doc
        ghost.backgroundColor = Design.Color.accent(isDark).withAlphaComponent(0.18).cgColor
        ghost.cornerRadius = Design.Radius.hwTile   // B3: было 6 (совпадает со скруглением плитки-источника)
        host.addSublayer(ghost)
        let from = ghost.position
        let to = CGPoint(x: ghost.position.x, y: 12)
        let a = CABasicAnimation(keyPath: "position")
        a.fromValue = from; a.toValue = to
        a.duration = Design.Motion.durBase
        a.timingFunction = Design.Motion.overshoot
        CATransaction.begin()
        CATransaction.setCompletionBlock { ghost.removeFromSuperlayer() }
        ghost.opacity = 0; ghost.position = to
        ghost.add(a, forKey: "fly")
        let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
        fade.duration = Design.Motion.durBase
        ghost.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    // MARK: hover → разбор

    private func setHover(_ id: String?) {
        guard id != hovered else { return }
        hovered = id
        emitDetail()
    }
    private func emitDetail() {
        if let id = hovered {
            // Из КЭША последнего тика — ноль SMC-syscall'ов в hover (свежее значение доедет следующим тиком).
            // Строка вне кэша (сырьё, ещё не тикнувшее) — единственный случай прямого чтения.
            if let row = lastRows[id] ?? SensorCatalog.row(id, record: false) { detailSink?(rowDetail(row)) }
        } else {
            detailSink?(summary())
        }
    }
    private func rowDetail(_ row: CatalogRow) -> String {
        let name = row.key.isRaw ? row.key.fourCC : row.key.displayName
        if !row.key.decodable {
            return "\(row.key.fourCC) · \(row.key.smcType) · " + L("сырой ключ · значение не декодируется")
        }
        let raw = row.key.isRaw ? " · " + row.key.fourCC : ""
        return "\(name) · \(row.text)\(raw) · \(row.key.smcType)"
    }
    private func summary() -> String {
        var parts: [String] = []
        if let cpu = lastSnapshot.temps.first(where: { $0.id == "cpu" }) { parts.append("CPU \(cpu.text)") }
        if let gpu = lastSnapshot.temps.first(where: { $0.id == "gpu" }) { parts.append("GPU \(gpu.text)") }
        let n = SensorCatalog.catalog().filter { !$0.isRaw }.count   // именованные датчики (не 660 сырых)
        if n > 0 { parts.append("\(n) " + SettingsStore.plural(n, L("датчик"), L("датчика"), L("датчиков"))) }
        return parts.isEmpty ? L("наведи на сенсор — покажу разбор") : parts.joined(separator: " · ")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyGauges()
    }
    override func layout() {
        super.layout()
        if doc.frame.width != scroll.contentSize.width && scroll.contentSize.width > 1 {
            relayout(animate: false)
        }
    }
}
