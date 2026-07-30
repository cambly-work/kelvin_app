import AppKit
import QuartzCore

// MARK: - Shared helpers

private extension NSColor {
    func hardwareAdjusted(isDark: Bool) -> NSColor {
        guard !isDark else { return self }
        return blended(withFraction: 0.18, of: .black) ?? self
    }
}

private final class HardwareCGImageBox: NSObject {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// Небольшой общий кэш SF Symbols для строк таблицы. В исходной версии каждый экземпляр строки
/// растеризовал символ самостоятельно; при прокрутке и смене темы это давало лишнюю работу на main.
private enum HardwareSymbolCache {
    private static let cache = NSCache<NSString, HardwareCGImageBox>()

    static func image(_ name: String, color: NSColor, pointSize: CGFloat, scale: CGFloat) -> CGImage? {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let key = String(
            format: "%@|%.1f|%.2f|%.3f|%.3f|%.3f|%.3f",
            name,
            pointSize,
            scale,
            rgb.redComponent,
            rgb.greenComponent,
            rgb.blueComponent,
            rgb.alphaComponent
        ) as NSString
        if let cached = cache.object(forKey: key) { return cached.image }

        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config: NSImage.SymbolConfiguration
        if #available(macOS 12, *) {
            config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
                .applying(.init(paletteColors: [color]))
        } else {
            config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        }
        let image = base.withSymbolConfiguration(config) ?? base
        var proposed = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return nil }
        cache.setObject(HardwareCGImageBox(cg), forKey: key)
        return cg
    }
}

// MARK: - Header metric

/// Компактный приборный показатель шапки.
///
/// `.hero` используется для CPU/GPU: подпись, крупное значение и тонкая шкала.
/// `.chip` используется для вторичных метрик: значение и название в одну строку.
/// Публичный API `set(...)` сохранён, поэтому вызывающий код менять не требуется.
final class HeroGauge: NSView {
    enum Kind { case temp, watt, turbo, turboWarn }
    enum Style { case hero, chip }

    private let style: Style
    private let surface = CALayer()
    private let track = CALayer()
    private let fill = CALayer()
    private let valueText = NSTextField(labelWithString: "—")
    private let capText = NSTextField(labelWithString: "")

    private var fraction: CGFloat = 0
    private var accent: NSColor = .systemTeal
    private var axValue = "—"

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        commonInit()
    }

    override init(frame frameRect: NSRect) {
        style = .hero
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        style = .hero
        super.init(coder: coder)
        commonInit()
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false

        surface.cornerCurve = .continuous
        surface.cornerRadius = style == .hero ? 8 : 6
        layer?.addSublayer(surface)

        track.cornerRadius = 1
        fill.cornerRadius = 1
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.addSublayer(track)
        layer?.addSublayer(fill)

        valueText.font = style == .hero ? Design.Font.mono(19, .semibold) : Design.Font.numericBody
        valueText.textColor = .labelColor
        valueText.maximumNumberOfLines = 1
        valueText.lineBreakMode = .byClipping
        valueText.cell?.usesSingleLineMode = true
        valueText.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueText)

        capText.font = Design.Font.sys(style == .hero ? 10 : 9, style == .hero ? .medium : .regular)
        capText.textColor = .secondaryLabelColor
        capText.maximumNumberOfLines = 1
        capText.lineBreakMode = .byTruncatingTail
        capText.cell?.usesSingleLineMode = true
        capText.translatesAutoresizingMaskIntoConstraints = false
        addSubview(capText)

        switch style {
        case .hero:
            capText.alignment = .left
            valueText.alignment = .left
            NSLayoutConstraint.activate([
                capText.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                capText.topAnchor.constraint(equalTo: topAnchor, constant: 5),
                capText.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),

                valueText.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                valueText.topAnchor.constraint(equalTo: capText.bottomAnchor, constant: -1),
                valueText.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            ])
        case .chip:
            valueText.alignment = .left
            capText.alignment = .right
            NSLayoutConstraint.activate([
                valueText.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
                valueText.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
                valueText.widthAnchor.constraint(greaterThanOrEqualToConstant: 27),

                capText.leadingAnchor.constraint(greaterThanOrEqualTo: valueText.trailingAnchor, constant: 5),
                capText.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
                capText.firstBaselineAnchor.constraint(equalTo: valueText.firstBaselineAnchor),
            ])
        }

        updateAppearance()
    }

    override func layout() {
        super.layout()
        let barHeight: CGFloat = 2
        let inset: CGFloat = style == .hero ? 8 : 7
        let width = max(0, bounds.width - inset * 2)

        surface.frame = bounds
        track.frame = CGRect(x: inset, y: 3, width: width, height: barHeight)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.position = CGPoint(x: inset, y: 3 + barHeight / 2)
        fill.bounds = CGRect(x: 0, y: 0, width: width * fraction, height: barHeight)
        CATransaction.commit()

        updateAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        surface.backgroundColor = (isDark
            ? NSColor.white.withAlphaComponent(style == .hero ? 0.055 : 0.035)
            : NSColor.black.withAlphaComponent(style == .hero ? 0.035 : 0.025)).cgColor
        surface.borderWidth = 0.5
        surface.borderColor = (isDark
            ? NSColor.white.withAlphaComponent(0.07)
            : NSColor.black.withAlphaComponent(0.06)).cgColor
        track.backgroundColor = Design.Color.trackFill(isDark).cgColor
        fill.backgroundColor = accent.cgColor
    }

    /// Обновляет значение и уровень. Порог температуры может быть передан вызывающим через `level`,
    /// поскольку только он знает идентификатор конкретного сенсора.
    func set(value: Double?, text: String, cap: String, kind: Kind, level: Design.Level? = nil) {
        capText.stringValue = cap
        axValue = text

        guard let value, value.isFinite else {
            valueText.stringValue = "—"
            valueText.textColor = .tertiaryLabelColor
            setFraction(0, animated: false)
            return
        }

        valueText.stringValue = text
        valueText.textColor = .labelColor

        switch kind {
        case .temp:
            fraction = CGFloat(max(0, min(1, (value - 35) / 60)))
            let raw: NSColor
            switch level ?? Design.tempLevel(value) {
            case .ok: raw = Design.Color.levelOK
            case .warn: raw = Design.Color.levelWarn
            case .crit: raw = Design.Color.levelCrit
            }
            accent = raw.hardwareAdjusted(isDark: isDark)

        case .watt:
            fraction = CGFloat(max(0, min(1, value / 60)))
            accent = Design.Color.accent(isDark)

        case .turbo:
            fraction = CGFloat(max(0, min(1, value)))
            accent = Design.Color.accent(isDark)

        case .turboWarn:
            fraction = CGFloat(max(0, min(1, value)))
            accent = Design.Color.levelWarn.hardwareAdjusted(isDark: isDark)
        }

        fill.backgroundColor = accent.cgColor
        setFraction(fraction, animated: true)
    }

    private func setFraction(_ value: CGFloat, animated: Bool) {
        fraction = max(0, min(1, value))
        let available = max(0, bounds.width - (style == .hero ? 16 : 14))
        let target = available * fraction
        let current = fill.presentation()?.bounds.width ?? fill.bounds.width

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var bounds = fill.bounds
        bounds.size.width = target
        fill.bounds = bounds
        CATransaction.commit()

        guard animated, !Motion.reduced, abs(current - target) > 0.5 else { return }
        let animation = CABasicAnimation(keyPath: "bounds.size.width")
        animation.fromValue = current
        animation.toValue = target
        animation.duration = Design.Motion.durValue
        animation.timingFunction = Design.Motion.easeStandard
        fill.add(animation, forKey: "value")
    }

    func animateIn() {
        let available = max(0, bounds.width - (style == .hero ? 16 : 14))
        let target = available * fraction
        guard !Motion.reduced, target > 0 else {
            setFraction(fraction, animated: false)
            return
        }
        fill.removeAnimation(forKey: "sweep")
        let animation = CABasicAnimation(keyPath: "bounds.size.width")
        animation.fromValue = 0
        animation.toValue = target
        animation.duration = Design.Motion.durSweep
        animation.timingFunction = Design.Motion.easeStandard
        fill.add(animation, forKey: "sweep")
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .levelIndicator }
    override func accessibilityLabel() -> String? { capText.stringValue }
    override func accessibilityValue() -> Any? { axValue }
}

// MARK: - Sparkline

/// Один fill-path + один stroke-path вместо отдельного CALayer на каждый сэмпл.
/// Даже длинная история теперь всегда стоит двух слоёв и не раздувает layer tree при скролле.
private final class SensorSparklineView: NSView {
    private let fillLayer = CAShapeLayer()
    private let lineLayer = CAShapeLayer()
    private var history: [Double] = []
    private var tint: NSColor = .secondaryLabelColor
    private var decodable = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = true
        lineLayer.fillColor = nil
        lineLayer.lineWidth = 1
        lineLayer.lineCap = .round
        lineLayer.lineJoin = .round
        layer?.addSublayer(fillLayer)
        layer?.addSublayer(lineLayer)
    }

    func apply(history: [Double], tint: NSColor, decodable: Bool) {
        self.history = history
        self.tint = tint
        self.decodable = decodable
        needsLayout = true
    }

    override func layout() {
        super.layout()
        redraw()
    }

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard decodable, history.count >= 2, bounds.width > 2, bounds.height > 2 else {
            fillLayer.path = nil
            lineLayer.path = nil
            return
        }

        let finite = history.filter(\.isFinite)
        guard finite.count >= 2, let low = finite.min(), let high = finite.max() else {
            fillLayer.path = nil
            lineLayer.path = nil
            return
        }

        let span = max(high - low, 0.0001)
        let width = bounds.width
        let height = bounds.height
        let topInset: CGFloat = 1
        let bottomInset: CGFloat = 1
        let drawableHeight = max(1, height - topInset - bottomInset)
        let step = width / CGFloat(max(history.count - 1, 1))

        func point(index: Int, value: Double) -> CGPoint {
            let normalized = CGFloat(max(0, min(1, (value - low) / span)))
            return CGPoint(
                x: CGFloat(index) * step,
                y: height - bottomInset - normalized * drawableHeight
            )
        }

        let line = CGMutablePath()
        var firstPoint: CGPoint?
        var lastPoint: CGPoint?
        for (index, value) in history.enumerated() where value.isFinite {
            let p = point(index: index, value: value)
            if firstPoint == nil {
                firstPoint = p
                line.move(to: p)
            } else {
                line.addLine(to: p)
            }
            lastPoint = p
        }

        guard let firstPoint, let lastPoint else {
            fillLayer.path = nil
            lineLayer.path = nil
            return
        }

        let fill = CGMutablePath()
        fill.move(to: CGPoint(x: firstPoint.x, y: height))
        fill.addLine(to: firstPoint)
        fill.addPath(line)
        fill.addLine(to: CGPoint(x: lastPoint.x, y: height))
        fill.closeSubpath()

        fillLayer.frame = bounds
        lineLayer.frame = bounds
        fillLayer.path = fill
        fillLayer.fillColor = tint.withAlphaComponent(0.12).cgColor
        lineLayer.path = line
        lineLayer.strokeColor = tint.withAlphaComponent(0.85).cgColor
    }
}

// MARK: - Sensor row

/// Переиспользуемая строка NSTableView. Один клик выбирает сенсор для разбора;
/// отдельная кнопка pin делает действие очевидным и больше не превращает всю строку в скрытый переключатель.
final class CatalogRowView: NSView {
    private let glyph = CALayer()
    private let nameLayer = CATextLayer()
    private let rawLayer = CATextLayer()
    private let valueLayer = CATextLayer()
    private let sparkline = SensorSparklineView()
    private let pinButton = NSButton()

    private(set) var id = ""
    private var sensorClass: SensorClass = .other
    private var isRaw = false
    private var row: CatalogRow?
    private var hoverOn = false
    private var selectedOn = false
    private(set) var pinned = false
    private var tracking: NSTrackingArea?
    private var lastSignature = ""
    private var lastHistoryFirst: Double?
    private var lastHistoryLast: Double?
    private var lastHistoryCount = -1

    var onHover: ((String?) -> Void)?
    var onActivate: ((String) -> Void)?
    var onPin: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    convenience init(id: String, cls: SensorClass, isRaw: Bool) {
        self.init(frame: .zero)
        configure(id: id, cls: cls, isRaw: isRaw)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override var isFlipped: Bool { true }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func resolved(_ color: NSColor) -> NSColor {
        Design.Color.resolved(color, dark: isDark)
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func commonInit() {
        wantsLayer = true
        layer?.cornerRadius = Design.Radius.hwTile
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false
        focusRingType = .default

        glyph.contentsGravity = .resizeAspect
        layer?.addSublayer(glyph)

        for textLayer in [nameLayer, rawLayer, valueLayer] {
            textLayer.truncationMode = .end
            textLayer.isWrapped = false
            layer?.addSublayer(textLayer)
        }
        valueLayer.alignmentMode = .right

        sparkline.translatesAutoresizingMaskIntoConstraints = true
        addSubview(sparkline)

        pinButton.isBordered = false
        pinButton.bezelStyle = .inline
        pinButton.imagePosition = .imageOnly
        pinButton.contentTintColor = .tertiaryLabelColor
        pinButton.target = self
        pinButton.action = #selector(pinPressed)
        pinButton.toolTip = L("Закрепить сенсор")
        pinButton.setAccessibilityLabel(L("Закрепить сенсор"))
        addSubview(pinButton)

        updateLayerScale()
        updateVisualState(animated: false)
    }

    func configure(id: String, cls: SensorClass, isRaw: Bool) {
        let identityChanged = self.id != id || sensorClass != cls || self.isRaw != isRaw
        self.id = id
        sensorClass = cls
        self.isRaw = isRaw
        if identityChanged {
            lastSignature = ""
            lastHistoryFirst = nil
            lastHistoryLast = nil
            lastHistoryCount = -1
            row = nil
            updateGlyph()
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onHover = nil
        onActivate = nil
        onPin = nil
        hoverOn = false
        selectedOn = false
        row = nil
        id = ""
        lastSignature = ""
        lastHistoryFirst = nil
        lastHistoryLast = nil
        lastHistoryCount = -1
        updateVisualState(animated: false)
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let width = bounds.width
        let glyphSize: CGFloat = 13
        let pinWidth: CGFloat = 20
        let valueWidth: CGFloat = 68
        let sparkWidth: CGFloat = 42
        let textHeight: CGFloat = 16

        glyph.frame = CGRect(x: 6, y: (height - glyphSize) / 2, width: glyphSize, height: glyphSize)
        pinButton.frame = CGRect(x: width - valueWidth - pinWidth - 2, y: (height - 18) / 2, width: 18, height: 18)
        valueLayer.frame = CGRect(x: width - valueWidth - 3, y: (height - textHeight) / 2, width: valueWidth, height: textHeight)
        sparkline.frame = CGRect(
            x: pinButton.frame.minX - sparkWidth - 5,
            y: (height - 14) / 2,
            width: sparkWidth,
            height: 14
        )

        let nameX: CGFloat = 25
        let availableName = max(20, sparkline.frame.minX - nameX - 6)
        if isRaw {
            let rawWidth = min(42, availableName * 0.38)
            rawLayer.frame = CGRect(x: nameX, y: (height - textHeight) / 2, width: rawWidth, height: textHeight)
            nameLayer.frame = CGRect(
                x: rawLayer.frame.maxX + 5,
                y: (height - textHeight) / 2,
                width: max(8, availableName - rawWidth - 5),
                height: textHeight
            )
        } else {
            rawLayer.frame = .zero
            nameLayer.frame = CGRect(x: nameX, y: (height - textHeight) / 2, width: availableName, height: textHeight)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let newArea = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(newArea)
        tracking = newArea
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateGlyph()
        lastSignature = ""
        if let row { apply(row, pinned: pinned, selected: selectedOn, animate: false) }
        updateVisualState(animated: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayerScale()
        updateGlyph()
    }

    private func updateLayerScale() {
        let scale = backingScale
        glyph.contentsScale = scale
        nameLayer.contentsScale = scale
        rawLayer.contentsScale = scale
        valueLayer.contentsScale = scale
        sparkline.layer?.contentsScale = scale
    }

    private func tint() -> NSColor {
        let color: NSColor
        switch sensorClass {
        case .temp: color = .systemOrange
        case .volt: color = .systemYellow
        case .curr: color = .systemTeal
        case .power: color = .systemOrange
        case .fan: color = .systemTeal
        case .batt: color = .systemGreen
        case .other: color = .secondaryLabelColor
        }
        return color.hardwareAdjusted(isDark: isDark)
    }

    private func glyphName() -> String {
        switch sensorClass {
        case .temp: return "thermometer.medium"
        case .volt: return "bolt.fill"
        case .curr: return "waveform.path.ecg"
        case .power: return "powerplug.fill"
        case .fan: return "fanblades.fill"
        case .batt: return "battery.50"
        case .other: return "number"
        }
    }

    private func updateGlyph() {
        glyph.contents = HardwareSymbolCache.image(
            glyphName(),
            color: tint(),
            pointSize: 12,
            scale: backingScale
        )
    }

    func apply(_ row: CatalogRow, pinned: Bool, selected: Bool, animate: Bool) {
        self.row = row
        self.pinned = pinned
        selectedOn = selected

        let signature = row.text + "|" + row.key.displayName + "|" + row.key.fourCC + "|" + String(row.key.decodable)
        let historyChanged = lastHistoryFirst != row.history.first
            || lastHistoryLast != row.history.last
            || lastHistoryCount != row.history.count

        if signature != lastSignature {
            lastSignature = signature
            renderText(row)
        }
        if historyChanged {
            lastHistoryFirst = row.history.first
            lastHistoryLast = row.history.last
            lastHistoryCount = row.history.count
            sparkline.apply(history: row.history, tint: tint(), decodable: row.key.decodable)
        }

        updatePin()
        updateVisualState(animated: animate)
        setAccessibilityLabel(accessibilityText(row))
    }

    private func renderText(_ row: CatalogRow) {
        let nameFont = isRaw ? Design.Font.caption : Design.Font.body
        nameLayer.font = nameFont
        nameLayer.fontSize = nameFont.pointSize
        nameLayer.foregroundColor = resolved(
            row.key.decodable ? .labelColor : .tertiaryLabelColor
        ).cgColor
        nameLayer.string = row.key.displayName

        rawLayer.font = Design.Font.numericMicro
        rawLayer.fontSize = Design.Font.numericMicro.pointSize
        rawLayer.foregroundColor = resolved(.tertiaryLabelColor).cgColor
        rawLayer.string = isRaw ? row.key.fourCC : nil
        rawLayer.isHidden = !isRaw

        valueLayer.font = Design.Font.numericBody
        valueLayer.fontSize = Design.Font.numericBody.pointSize
        valueLayer.string = valueAttributedString(row)
    }

    private func valueAttributedString(_ row: CatalogRow) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byTruncatingTail

        guard row.key.decodable, row.value != nil else {
            return NSAttributedString(string: "—", attributes: [
                .font: Design.Font.numericBody,
                .foregroundColor: resolved(.tertiaryLabelColor),
                .paragraphStyle: paragraph,
            ])
        }

        let attributed = NSMutableAttributedString()
        let text = row.text
        if let split = text.lastIndex(of: " ") {
            let number = String(text[..<split])
            let unit = String(text[text.index(after: split)...])
            attributed.append(NSAttributedString(string: number + " ", attributes: [
                .font: Design.Font.numericBody,
                .foregroundColor: resolved(.labelColor),
                .paragraphStyle: paragraph,
            ]))
            attributed.append(NSAttributedString(string: unit, attributes: [
                .font: Design.Font.numericMicro,
                .foregroundColor: resolved(.tertiaryLabelColor),
                .paragraphStyle: paragraph,
            ]))
        } else {
            attributed.append(NSAttributedString(string: text, attributes: [
                .font: Design.Font.numericBody,
                .foregroundColor: resolved(.labelColor),
                .paragraphStyle: paragraph,
            ]))
        }
        return attributed
    }

    private func updatePin() {
        let symbol = pinned ? "pin.fill" : "pin"
        pinButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        pinButton.contentTintColor = pinned ? tint() : .tertiaryLabelColor
        pinButton.alphaValue = pinned || hoverOn || selectedOn ? 1 : 0
        let label = pinned ? L("Открепить сенсор") : L("Закрепить сенсор")
        pinButton.toolTip = label
        pinButton.setAccessibilityLabel(label)
    }

    func setSelected(_ selected: Bool, animated: Bool) {
        guard selected != selectedOn else { return }
        selectedOn = selected
        updateVisualState(animated: animated)
    }

    func clearHover() {
        guard hoverOn else { return }
        hoverOn = false
        updateVisualState(animated: false)
    }

    private func updateVisualState(animated: Bool) {
        let background: NSColor
        if selectedOn {
            background = Design.Color.accent(isDark).withAlphaComponent(isDark ? 0.14 : 0.10)
        } else if hoverOn {
            background = tint().withAlphaComponent(isDark ? 0.09 : 0.075)
        } else {
            background = .clear
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(animated && !Motion.reduced ? Design.Motion.durFast : 0)
        layer?.backgroundColor = background.cgColor
        CATransaction.commit()
        updatePin()
    }

    private func accessibilityText(_ row: CatalogRow) -> String {
        let name = row.key.isRaw ? row.key.fourCC + ", " + row.key.displayName : row.key.displayName
        let value = row.key.decodable ? row.text : L("значение не декодируется")
        let pinState = pinned ? L("закреплён") : L("не закреплён")
        return "\(name), \(value), \(pinState)"
    }

    @objc private func pinPressed() {
        guard !id.isEmpty else { return }
        onPin?(id)
    }

    override func mouseEntered(with event: NSEvent) {
        hoverOn = true
        updateVisualState(animated: true)
        if !id.isEmpty { onHover?(id) }
    }

    override func mouseExited(with event: NSEvent) {
        hoverOn = false
        updateVisualState(animated: true)
        onHover?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard !id.isEmpty else { return }
        onActivate?(id)
    }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36: // Return
            if !id.isEmpty { onActivate?(id) }
        case 49: // Space
            if !id.isEmpty { onPin?(id) }
        default:
            super.keyDown(with: event)
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: Design.Radius.hwTile,
            yRadius: Design.Radius.hwTile
        ).fill()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        guard !id.isEmpty else { return false }
        onActivate?(id)
        return true
    }
}

// MARK: - Section and diagnostics rows

private final class SectionHeaderView: NSView {
    private let titleField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")
    private let disclosure = NSButton()

    private(set) var key = ""
    private var collapsible = false
    private var expanded = true
    var onToggle: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    convenience init(key: String, title: String) {
        self.init(frame: .zero)
        configure(key: key, title: title, count: 0, collapsible: false, expanded: true)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override var isFlipped: Bool { true }

    private func commonInit() {
        titleField.font = Design.Font.sys(11, .medium)
        titleField.textColor = .secondaryLabelColor
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1
        addSubview(titleField)

        countField.font = Design.Font.numericMicro
        countField.textColor = .tertiaryLabelColor
        countField.alignment = .right
        addSubview(countField)

        disclosure.isBordered = false
        disclosure.bezelStyle = .inline
        disclosure.imagePosition = .imageOnly
        disclosure.contentTintColor = .tertiaryLabelColor
        disclosure.target = self
        disclosure.action = #selector(toggle)
        addSubview(disclosure)
    }

    func configure(key: String, title: String, count: Int, collapsible: Bool, expanded: Bool) {
        self.key = key
        self.collapsible = collapsible
        self.expanded = expanded
        titleField.stringValue = title
        countField.stringValue = count > 0 ? "\(count)" : ""
        disclosure.isHidden = !collapsible
        disclosure.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )
        let action = expanded ? L("Свернуть раздел") : L("Развернуть раздел")
        disclosure.toolTip = action
        disclosure.setAccessibilityLabel(action)
        setAccessibilityLabel("\(title), \(count)")
    }

    override func layout() {
        super.layout()
        disclosure.frame = CGRect(x: 2, y: (bounds.height - 14) / 2, width: 14, height: 14)
        let leading: CGFloat = collapsible ? 19 : 5
        countField.frame = CGRect(x: bounds.width - 37, y: (bounds.height - 14) / 2, width: 32, height: 14)
        titleField.frame = CGRect(
            x: leading,
            y: (bounds.height - 15) / 2,
            width: max(20, countField.frame.minX - leading - 5),
            height: 15
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard collapsible else { return }
        toggle()
    }

    @objc private func toggle() {
        guard collapsible, !key.isEmpty else { return }
        onToggle?(key)
    }

    override func isAccessibilityElement() -> Bool { collapsible }
    override func accessibilityRole() -> NSAccessibility.Role? { collapsible ? .button : .staticText }
    override func accessibilityPerformPress() -> Bool {
        guard collapsible else { return false }
        toggle()
        return true
    }
}

private final class EngineRowView: NSView {
    private let labelField = NSTextField(labelWithString: "")
    private let valueField = NSTextField(labelWithString: "")
    private var lastLabel = ""
    private var lastValue = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    convenience init(_ row: EngineRow) {
        self.init(frame: .zero)
        update(row)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override var isFlipped: Bool { true }

    private func commonInit() {
        labelField.font = Design.Font.caption
        labelField.textColor = .secondaryLabelColor
        labelField.lineBreakMode = .byTruncatingTail
        addSubview(labelField)

        valueField.font = Design.Font.numericMicro
        valueField.textColor = .tertiaryLabelColor
        valueField.alignment = .right
        valueField.lineBreakMode = .byTruncatingHead
        addSubview(valueField)
    }

    func update(_ row: EngineRow) {
        if row.label != lastLabel {
            lastLabel = row.label
            labelField.stringValue = row.label
        }
        if row.value != lastValue {
            lastValue = row.value
            valueField.stringValue = row.value
        }
        setAccessibilityLabel("\(row.label), \(row.value)")
    }

    override func layout() {
        super.layout()
        let height: CGFloat = 14
        labelField.frame = CGRect(x: 6, y: (bounds.height - height) / 2, width: bounds.width * 0.49, height: height)
        valueField.frame = CGRect(
            x: bounds.width * 0.43,
            y: (bounds.height - height) / 2,
            width: bounds.width * 0.57 - 6,
            height: height
        )
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
}

// MARK: - Hardware view

/// Профессиональная V5 вкладки «Железо».
///
/// Основное отличие от прежней реализации — нативная переиспользуемая таблица вместо растущего
/// documentView с сотнями постоянных строк. Это уменьшает layer tree, tracking areas и стоимость
/// скролла, при этом внешний API HardwareView сохранён.
final class HardwareView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let panelH: CGFloat = 280

    private enum Layout {
        static let intrinsicWidth: CGFloat = 272
        static let minimumPanelHeight: CGFloat = 198
        static let headerHeight: CGFloat = 72
        static let searchHeight: CGFloat = 24
        static let searchGap: CGFloat = 7
        static let tableGap: CGFloat = 6
        static let sensorRowHeight: CGFloat = 26
        static let sectionRowHeight: CGFloat = 22
        static let engineRowHeight: CGFloat = 18
        static let emptyRowHeight: CGFloat = 42
    }

    private struct SectionDefinition {
        let key: String
        let title: String
        let sensorClass: SensorClass?
        let rawOnly: Bool
        let defaultExpanded: Bool
    }

    private enum ListItem {
        case section(key: String, title: String, count: Int, expanded: Bool, collapsible: Bool)
        case sensor(id: String)
        case engine(index: Int)
        case empty(String)
    }

    private static let sectionDefinitions: [SectionDefinition] = [
        .init(key: "temp", title: L("Температуры"), sensorClass: .temp, rawOnly: false, defaultExpanded: false),
        .init(key: "fan", title: L("Вентиляторы"), sensorClass: .fan, rawOnly: false, defaultExpanded: false),
        .init(key: "power", title: L("Питание"), sensorClass: .power, rawOnly: false, defaultExpanded: false),
        .init(key: "volt", title: L("Вольтажи"), sensorClass: .volt, rawOnly: false, defaultExpanded: false),
        .init(key: "curr", title: L("Токи"), sensorClass: .curr, rawOnly: false, defaultExpanded: false),
        .init(key: "batt", title: L("Нагрузка"), sensorClass: .batt, rawOnly: false, defaultExpanded: false),
        .init(key: "raw", title: L("Сырые ключи"), sensorClass: nil, rawOnly: true, defaultExpanded: false),
    ]

    /// Наведение и выбранная строка отправляют сюда точный инженерный разбор.
    var detailSink: ((String) -> Void)?

    private let gauges: [HeroGauge] = [
        HeroGauge(style: .hero),
        HeroGauge(style: .hero),
        HeroGauge(style: .chip),
        HeroGauge(style: .chip),
        HeroGauge(style: .chip),
    ]

    private let search = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private let table = NSTableView()

    private var panelHeight: CGFloat = panelH
    private var panelHeightConstraint: NSLayoutConstraint?
    private var scrollObserver: NSObjectProtocol?
    private var pendingSearch: DispatchWorkItem?

    private let catalog: [CatalogKey]
    private let catalogByID: [String: CatalogKey]
    private let searchIndex: [String: String]

    private var items: [ListItem] = []
    private var engineRows: [EngineRow] = []
    private var expandedSections: Set<String>
    private var pinned: [String]
    private var query = ""
    private var hoveredID: String?
    private var selectedID: String?

    private var lastSnapshot = SensorsSnapshot()
    private var lastComponents = ComponentPower()
    private var lastEnergy = EnergySnapshot()
    private var lastRows: [String: CatalogRow] = [:]

    override init(frame frameRect: NSRect) {
        let catalog = SensorCatalog.catalog()
        self.catalog = catalog
        catalogByID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        searchIndex = Dictionary(uniqueKeysWithValues: catalog.map { key in
            let blob = [key.fourCC, key.displayName, SensorClass.titleFor(key.cls)]
                .joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
            return (key.id, blob)
        })

        let storedExpanded = UserDefaults.standard.array(forKey: "hardware.expandedSections") as? [String]
        if let storedExpanded {
            expandedSections = Set(storedExpanded)
        } else {
            expandedSections = Set(Self.sectionDefinitions.filter(\.defaultExpanded).map(\.key))
        }
        pinned = UserDefaults.standard.array(forKey: "hardware.pinned") as? [String] ?? []

        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        let catalog = SensorCatalog.catalog()
        self.catalog = catalog
        catalogByID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        searchIndex = Dictionary(uniqueKeysWithValues: catalog.map { key in
            let blob = [key.fourCC, key.displayName, SensorClass.titleFor(key.cls)]
                .joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
            return (key.id, blob)
        })

        let storedExpanded = UserDefaults.standard.array(forKey: "hardware.expandedSections") as? [String]
        if let storedExpanded {
            expandedSections = Set(storedExpanded)
        } else {
            expandedSections = Set(Self.sectionDefinitions.filter(\.defaultExpanded).map(\.key))
        }
        pinned = UserDefaults.standard.array(forKey: "hardware.pinned") as? [String] ?? []

        super.init(coder: coder)
        commonInit()
    }

    deinit {
        pendingSearch?.cancel()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Layout.intrinsicWidth, height: panelHeight)
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { L("Сенсоры") }

    func setPanelHeight(_ height: CGFloat) {
        let clamped = max(Layout.minimumPanelHeight, height)
        guard abs(clamped - panelHeight) > 0.5 else { return }
        panelHeight = clamped
        panelHeightConstraint?.constant = clamped
        invalidateIntrinsicContentSize()
    }

    var currentPanelHeight: CGFloat { panelHeight }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false
        translatesAutoresizingMaskIntoConstraints = false

        widthAnchor.constraint(equalToConstant: Layout.intrinsicWidth).isActive = true
        let heightConstraint = heightAnchor.constraint(equalToConstant: panelHeight)
        heightConstraint.isActive = true
        panelHeightConstraint = heightConstraint

        prunePinnedSensors()
        buildHeader()
        buildSearch()
        buildTable()
        rebuildItems(preserveSelection: false)
    }

    private func buildHeader() {
        let firstRow = NSStackView(views: [gauges[0], gauges[1]])
        firstRow.orientation = .horizontal
        firstRow.distribution = .fillEqually
        firstRow.spacing = 6

        let secondRow = NSStackView(views: [gauges[2], gauges[3], gauges[4]])
        secondRow.orientation = .horizontal
        secondRow.distribution = .fillEqually
        secondRow.spacing = 6

        let header = NSStackView(views: [firstRow, secondRow])
        header.orientation = .vertical
        header.distribution = .fill
        header.spacing = 5
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Layout.headerHeight),
            firstRow.heightAnchor.constraint(equalToConstant: 43),
            secondRow.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    private func buildSearch() {
        search.placeholderString = L("Поиск по сенсорам")
        search.controlSize = .small
        search.font = Design.Font.caption
        search.sendsWholeSearchString = false
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false
        addSubview(search)

        countLabel.font = Design.Font.microStat
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .right
        countLabel.lineBreakMode = .byClipping
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: topAnchor, constant: Layout.headerHeight + Layout.searchGap),
            search.leadingAnchor.constraint(equalTo: leadingAnchor),
            search.heightAnchor.constraint(equalToConstant: Layout.searchHeight),

            countLabel.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            countLabel.widthAnchor.constraint(equalToConstant: 58),
            countLabel.leadingAnchor.constraint(equalTo: search.trailingAnchor, constant: 6),
        ])
    }

    private func buildTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hardware.main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.focusRingType = .none
        table.delegate = self
        table.dataSource = self
        table.rowSizeStyle = .custom
        table.usesAlternatingRowBackgroundColors = false

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .allowed
        scroll.horizontalScrollElasticity = .none
        scroll.hasHorizontalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.clearVisibleHover()
            self.hoveredID = nil
            self.emitDetail()
        }

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(
                equalTo: search.bottomAnchor,
                constant: Layout.tableGap
            ),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: Search

    func controlTextDidChange(_ obj: Notification) {
        pendingSearch?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.query = self.normalized(self.search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            self.rebuildItems(preserveSelection: true)
        }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func normalized(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }

    private func matches(_ key: CatalogKey) -> Bool {
        query.isEmpty || (searchIndex[key.id]?.contains(query) ?? false)
    }

    // MARK: List model

    private func prunePinnedSensors() {
        let valid = pinned.filter { catalogByID[$0] != nil }
        guard valid != pinned else { return }
        pinned = valid
        UserDefaults.standard.set(pinned, forKey: "hardware.pinned")
    }

    private func rebuildItems(preserveSelection: Bool) {
        let oldSelection = preserveSelection ? selectedID : nil
        var result: [ListItem] = []
        let pinnedSet = Set(pinned)

        let visiblePinned = pinned.compactMap { catalogByID[$0] }.filter(matches)
        if !visiblePinned.isEmpty {
            result.append(.section(
                key: "pinned",
                title: L("Закреплённые"),
                count: visiblePinned.count,
                expanded: true,
                collapsible: false
            ))
            result.append(contentsOf: visiblePinned.map { .sensor(id: $0.id) })
        }

        for definition in Self.sectionDefinitions {
            let keys = catalog.filter { key in
                guard !pinnedSet.contains(key.id), matches(key) else { return false }
                if definition.rawOnly { return key.isRaw }
                return !key.isRaw && key.cls == definition.sensorClass
            }
            guard !keys.isEmpty else { continue }

            let expanded = query.isEmpty ? expandedSections.contains(definition.key) : true
            result.append(.section(
                key: definition.key,
                title: definition.title,
                count: keys.count,
                expanded: expanded,
                collapsible: true
            ))
            if expanded { result.append(contentsOf: keys.map { .sensor(id: $0.id) }) }
        }

        if query.isEmpty {
            engineRows = SensorCatalog.engineDiagnostics(components: lastComponents, energy: lastEnergy)
            let expanded = expandedSections.contains("engine")
            result.append(.section(
                key: "engine",
                title: L("Диагностика движка"),
                count: engineRows.count,
                expanded: expanded,
                collapsible: true
            ))
            if expanded {
                result.append(contentsOf: engineRows.indices.map { .engine(index: $0) })
            }
        }

        let hasSensor = result.contains {
            if case .sensor = $0 { return true }
            return false
        }
        if !hasSensor, !query.isEmpty {
            result.append(.empty(L("Ничего не найдено")))
        }

        items = result
        table.reloadData()
        updateCount()

        selectedID = oldSelection.flatMap { id in
            items.contains {
                if case .sensor(let itemID) = $0 { return itemID == id }
                return false
            } ? id : nil
        }
        refreshVisibleSelection(animated: false)
        emitDetail()
    }

    private func toggleSection(_ key: String) {
        if expandedSections.contains(key) {
            expandedSections.remove(key)
        } else {
            expandedSections.insert(key)
        }
        UserDefaults.standard.set(Array(expandedSections).sorted(), forKey: "hardware.expandedSections")
        rebuildItems(preserveSelection: true)
    }

    private func updateCount() {
        if query.isEmpty {
            let count = catalog.filter { !$0.isRaw }.count
            countLabel.stringValue = "\(count) " + SettingsStore.plural(
                count,
                L("датчик"),
                L("датчика"),
                L("датчиков")
            )
        } else {
            let count = catalog.filter(matches).count
            countLabel.stringValue = "\(count) " + SettingsStore.plural(
                count,
                L("ключ"),
                L("ключа"),
                L("ключей")
            )
        }
    }

    // MARK: Table data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard items.indices.contains(row) else { return Layout.sensorRowHeight }
        switch items[row] {
        case .section: return Layout.sectionRowHeight
        case .sensor: return Layout.sensorRowHeight
        case .engine: return Layout.engineRowHeight
        case .empty: return Layout.emptyRowHeight
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard items.indices.contains(row) else { return false }
        if case .sensor = items[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard items.indices.contains(index) else { return nil }

        switch items[index] {
        case let .section(key, title, count, expanded, collapsible):
            let identifier = NSUserInterfaceItemIdentifier("hardware.section")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? SectionHeaderView
                ?? SectionHeaderView(frame: .zero)
            view.identifier = identifier
            view.configure(
                key: key,
                title: title,
                count: count,
                collapsible: collapsible,
                expanded: expanded
            )
            view.onToggle = { [weak self] key in self?.toggleSection(key) }
            return view

        case .sensor(let id):
            guard let key = catalogByID[id] else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("hardware.sensor")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? CatalogRowView
                ?? CatalogRowView(frame: .zero)
            view.identifier = identifier
            view.configure(id: key.id, cls: key.cls, isRaw: key.isRaw)
            view.onHover = { [weak self] id in self?.setHover(id) }
            view.onActivate = { [weak self] id in self?.selectSensor(id) }
            view.onPin = { [weak self] id in self?.togglePin(id) }

            let row = lastRows[id] ?? SensorCatalog.row(for: key, record: false)
            lastRows[id] = row
            view.apply(
                row,
                pinned: pinned.contains(id),
                selected: selectedID == id,
                animate: false
            )
            return view

        case .engine(let rowIndex):
            guard engineRows.indices.contains(rowIndex) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("hardware.engine")
            let view = tableView.makeView(withIdentifier: identifier, owner: self) as? EngineRowView
                ?? EngineRowView(frame: .zero)
            view.identifier = identifier
            view.update(engineRows[rowIndex])
            return view

        case .empty(let text):
            let identifier = NSUserInterfaceItemIdentifier("hardware.empty")
            let field = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField
                ?? NSTextField(labelWithString: "")
            field.identifier = identifier
            field.stringValue = text
            field.font = Design.Font.caption
            field.textColor = .tertiaryLabelColor
            field.alignment = .center
            field.maximumNumberOfLines = 1
            return field
        }
    }

    // MARK: Visible sampling

    /// Возвращает только реально видимые sensor-id. NSTableView уже виртуализирует строки, поэтому
    /// раскрытие сотен raw-ключей не создаёт сотни tracking areas и не заставляет читать их все.
    func visibleIDs() -> Set<String> {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return [] }
        let range = table.rows(in: table.visibleRect)
        guard range.location != NSNotFound, range.length > 0 else { return [] }

        var result = Set<String>()
        let upperBound = min(items.count, range.location + range.length)
        for index in range.location..<upperBound {
            if case .sensor(let id) = items[index] { result.insert(id) }
        }
        return result
    }

    // MARK: Data input

    func update(_ snapshot: SensorsSnapshot) {
        lastSnapshot = snapshot
        applyGauges()
        emitDetail()
    }

    func updateCatalog(rows: [CatalogRow], components: ComponentPower, energy: EnergySnapshot) {
        lastComponents = components
        lastEnergy = energy

        for row in rows { lastRows[row.key.id] = row }
        refreshVisibleRows(with: rows)

        if query.isEmpty, expandedSections.contains("engine") {
            let newRows = SensorCatalog.engineDiagnostics(components: components, energy: energy)
            let countChanged = newRows.count != engineRows.count
            engineRows = newRows
            if countChanged {
                rebuildItems(preserveSelection: true)
            } else {
                refreshVisibleEngineRows()
            }
        }

        applyGauges()
        emitDetail()
    }

    private func refreshVisibleRows(with rows: [CatalogRow]) {
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.key.id, $0) })
        table.enumerateAvailableRowViews { [weak self] rowView, rowIndex in
            guard let self,
                  self.items.indices.contains(rowIndex),
                  case .sensor(let id) = self.items[rowIndex],
                  let view = rowView.subviews.first(where: { $0 is CatalogRowView }) as? CatalogRowView,
                  let row = byID[id] ?? self.lastRows[id]
            else { return }

            view.apply(
                row,
                pinned: self.pinned.contains(id),
                selected: self.selectedID == id,
                animate: true
            )
        }
    }

    private func refreshVisibleEngineRows() {
        table.enumerateAvailableRowViews { [weak self] rowView, rowIndex in
            guard let self,
                  self.items.indices.contains(rowIndex),
                  case .engine(let engineIndex) = self.items[rowIndex],
                  self.engineRows.indices.contains(engineIndex),
                  let view = rowView.subviews.first(where: { $0 is EngineRowView }) as? EngineRowView
            else { return }
            view.update(self.engineRows[engineIndex])
        }
    }

    private func applyGauges() {
        let temperatures = lastSnapshot.temps
        let cpu = temperatures.first { $0.id == "cpu" }
        let gpu = temperatures.first { $0.id == "gpu" }

        let partialPower = !(lastEnergy.systemWatts > 0.1)
        let watts = partialPower
            ? (lastComponents.cpu ?? 0) + (lastComponents.gpu ?? 0)
            : lastEnergy.systemWatts

        gauges[0].set(
            value: cpu?.value,
            text: cpu?.text ?? "—",
            cap: "CPU",
            kind: .temp,
            level: cpu.map { Design.sensorLevel(id: "cpu", $0.value) }
        )
        gauges[1].set(
            value: gpu?.value,
            text: gpu?.text ?? "—",
            cap: "GPU",
            kind: .temp,
            level: gpu.map { Design.sensorLevel(id: "gpu", $0.value) }
        )
        let frequencyFraction = lastComponents.freqFraction
        let frequencyText: String = {
            guard let mhz = lastComponents.freqMHz else { return "—" }
            return mhz >= 1_000 ? String(format: "%.2f", mhz / 1_000) : String(format: "%.0f", mhz)
        }()
        gauges[2].set(
            value: frequencyFraction.map { min(max($0, 0), 1.25) / 1.25 },
            text: frequencyText,
            cap: lastComponents.freqMHz.map { $0 >= 1_000 ? L("CPU, ГГц") : L("CPU, МГц") } ?? L("Частота CPU"),
            kind: .turbo,
            level: nil
        )
        if let fraction = frequencyFraction, let mhz = lastComponents.freqMHz {
            gauges[2].toolTip = String(
                format: L("Средняя частота CPU: %.0f МГц · %.0f%% от номинальной. Устойчивая частота ниже номинальной при высокой загрузке может указывать на троттлинг."),
                mhz,
                fraction * 100
            )
        } else {
            gauges[2].toolTip = L("Частота доступна после установки системного помощника powermetrics.")
        }
        gauges[3].set(
            value: watts > 0 ? watts : nil,
            text: watts > 0 ? String(format: "%.0f", watts) : "—",
            cap: partialPower && watts > 0 ? L("CPU+GPU Вт") : L("Система, Вт"),
            kind: .watt
        )

        let fanRPM = lastSnapshot.fans.map(\.value).max()
        gauges[4].set(
            value: fanRPM.map { min($0 / 6_000, 1) },
            text: fanRPM.map { String(format: "%.0f", $0) } ?? "—",
            cap: L("Кулер, об/мин"),
            kind: .turbo
        )
        gauges[4].toolTip = L("Максимальная скорость среди активных вентиляторов.")
    }

    func animateIn() {
        gauges.forEach { $0.animateIn() }
    }

    // MARK: Pinning and selection

    private func togglePin(_ id: String) {
        guard catalogByID[id] != nil else { return }
        if let index = pinned.firstIndex(of: id) {
            pinned.remove(at: index)
        } else {
            pinned.append(id)
        }
        UserDefaults.standard.set(pinned, forKey: "hardware.pinned")
        rebuildItems(preserveSelection: true)
    }

    private func selectSensor(_ id: String) {
        selectedID = selectedID == id ? nil : id
        refreshVisibleSelection(animated: true)
        emitDetail()
    }

    private func refreshVisibleSelection(animated: Bool) {
        table.enumerateAvailableRowViews { [weak self] rowView, rowIndex in
            guard let self,
                  self.items.indices.contains(rowIndex),
                  case .sensor(let id) = self.items[rowIndex],
                  let view = rowView.subviews.first(where: { $0 is CatalogRowView }) as? CatalogRowView
            else { return }
            view.setSelected(self.selectedID == id, animated: animated)
        }
    }

    // MARK: Hover and detail

    private func setHover(_ id: String?) {
        guard hoveredID != id else { return }
        hoveredID = id
        emitDetail()
    }

    private func clearVisibleHover() {
        table.enumerateAvailableRowViews { rowView, _ in
            if let view = rowView.subviews.first(where: { $0 is CatalogRowView }) as? CatalogRowView {
                view.clearHover()
            }
        }
    }

    private func emitDetail() {
        let id = hoveredID ?? selectedID
        if let id,
           let row = lastRows[id] ?? catalogByID[id].map({ SensorCatalog.row(for: $0, record: false) }) {
            lastRows[id] = row
            detailSink?(rowDetail(row))
        } else {
            detailSink?(summary())
        }
    }

    private func rowDetail(_ row: CatalogRow) -> String {
        let key = row.key
        let name = key.isRaw ? key.fourCC : key.displayName
        if !key.decodable {
            return "\(key.fourCC) · \(key.smcType) · " + L("сырой ключ · значение не декодируется")
        }
        let rawSuffix = key.isRaw ? " · \(key.fourCC)" : ""
        return "\(name) · \(row.text)\(rawSuffix) · \(key.smcType)"
    }

    private func summary() -> String {
        var parts: [String] = []
        if let cpu = lastSnapshot.temps.first(where: { $0.id == "cpu" }) {
            parts.append("CPU \(cpu.text)")
        }
        if let gpu = lastSnapshot.temps.first(where: { $0.id == "gpu" }) {
            parts.append("GPU \(gpu.text)")
        }

        if lastEnergy.systemWatts > 0.1 {
            parts.append(String(format: L("Система %.0f Вт"), lastEnergy.systemWatts))
        }

        let namedCount = catalog.filter { !$0.isRaw }.count
        if namedCount > 0 {
            parts.append("\(namedCount) " + SettingsStore.plural(
                namedCount,
                L("датчик"),
                L("датчика"),
                L("датчиков")
            ))
        }
        return parts.isEmpty ? L("Наведи на сенсор, чтобы увидеть разбор") : parts.joined(separator: " · ")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyGauges()
        table.reloadData()
        refreshVisibleSelection(animated: false)
    }
}
