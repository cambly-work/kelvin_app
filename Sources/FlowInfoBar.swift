import AppKit
import QuartzCore

/// Три спокойных факта под energy scene.
///
/// Это контекст расхода, а не ещё одна панель приборов: яркость экрана,
/// накопленная энергия и наиболее активное приложение.
final class FlowInfoBar: NSView {

    struct Feed {
        var hasBattery = true
        var cycleCount = 0
        var health = 0.0
        var capacityWh = 0.0
        var onBattery = false
        var topApp: String?
        var screenBrightness: Float = -1
        var brightnessDelta: Float = 0
    }

    var detailSink: ((String?) -> Void)?

    private final class Cell: NSView {
        let id: String
        let icon = CALayer()
        let caption = CATextLayer()
        let value = CATextLayer()
        var onHover: ((String?) -> Void)?
        var detail = ""

        private var hovering = false
        private var tracking: NSTrackingArea?

        init(id: String) {
            self.id = id
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = 11
            layer?.cornerCurve = .continuous
            icon.contentsGravity = .resizeAspect
            layer?.addSublayer(icon)
            layer?.addSublayer(caption)
            layer?.addSublayer(value)
            applyTypography()
            restyle()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override var isFlipped: Bool { true }

        private var isDark: Bool {
            effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }

        private func resolved(_ color: NSColor) -> NSColor {
            Design.Color.resolved(color, dark: isDark)
        }

        private func applyTypography() {
            let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            caption.font = NSFont.systemFont(ofSize: 8.5, weight: .medium)
            caption.fontSize = 8.5
            caption.contentsScale = scale
            caption.truncationMode = .end
            caption.foregroundColor = resolved(.tertiaryLabelColor).cgColor

            value.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            value.fontSize = 10.5
            value.contentsScale = scale
            value.truncationMode = .end
            value.foregroundColor = resolved(.labelColor).cgColor
            icon.contentsScale = scale
        }

        override func layout() {
            super.layout()
            icon.frame = CGRect(x: 9, y: 9, width: 13, height: 13)
            caption.frame = CGRect(x: 27, y: 9, width: bounds.width - 35, height: 12)
            value.frame = CGRect(x: 9, y: 29, width: bounds.width - 18, height: 15)
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            applyTypography()
            restyle()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) {
            hovering = true
            restyle(animated: true)
            onHover?(id)
        }

        override func mouseExited(with event: NSEvent) {
            hovering = false
            restyle(animated: true)
            onHover?(nil)
        }

        func set(caption captionText: String, value valueText: String, symbol: String, tint: NSColor, detail: String) {
            caption.string = captionText
            value.string = valueText
            value.foregroundColor = resolved(valueText == "—" ? .tertiaryLabelColor : .labelColor).cgColor
            icon.contents = Self.symbol(symbol, color: tint, pointSize: 12)
            self.detail = detail
            setAccessibilityLabel(captionText + " " + valueText)
            toolTip = detail
        }

        private func restyle(animated: Bool = false) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(animated && !Motion.reduced ? Design.Motion.durFast : 0)
            let base = isDark ? NSColor.white.withAlphaComponent(0.032) : NSColor.black.withAlphaComponent(0.022)
            let hover = Design.Color.accent(isDark).withAlphaComponent(isDark ? 0.10 : 0.075)
            layer?.backgroundColor = (hovering ? hover : base).cgColor
            layer?.borderWidth = 0.5
            layer?.borderColor = (hovering
                ? Design.Color.accent(isDark).withAlphaComponent(0.28)
                : (isDark ? NSColor.white.withAlphaComponent(0.075) : NSColor.black.withAlphaComponent(0.055))).cgColor
            CATransaction.commit()
        }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

        private static func symbol(_ name: String, color: NSColor, pointSize: CGFloat) -> CGImage? {
            guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
            let configuration: NSImage.SymbolConfiguration
            if #available(macOS 12, *) {
                configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
                    .applying(.init(paletteColors: [color]))
            } else {
                configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
            }
            let image = base.withSymbolConfiguration(configuration) ?? base
            var rect = CGRect(origin: .zero, size: image.size)
            return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        }
    }

    private var feed = Feed()
    private let row = NSStackView()
    private let brightnessCell = Cell(id: "brightness")
    private let energyCell = Cell(id: "energy")
    private let topAppCell = Cell(id: "topapp")
    private var hoveredID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { L("Сводка за сессию") }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func commonInit() {
        wantsLayer = true
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 7
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        for cell in [brightnessCell, energyCell, topAppCell] {
            cell.translatesAutoresizingMaskIntoConstraints = false
            cell.onHover = { [weak self] id in self?.hover(id) }
            row.addArrangedSubview(cell)
        }
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    func update(_ newFeed: Feed) {
        feed = newFeed
        let accent = Design.Color.accent(isDark)

        let brightnessAvailable = newFeed.screenBrightness.isFinite && newFeed.screenBrightness >= 0
        let brightness = brightnessAvailable
            ? "\(Int((min(1, newFeed.screenBrightness) * 100).rounded()))%"
            : "—"
        let brightnessTrend: String
        if newFeed.brightnessDelta > 0.02 { brightnessTrend = L("Растёт") }
        else if newFeed.brightnessDelta < -0.02 { brightnessTrend = L("Снижается") }
        else { brightnessTrend = L("Стабильно") }
        brightnessCell.set(
            caption: L("Экран"),
            value: brightness,
            symbol: "sun.max.fill",
            tint: brightnessAvailable ? .systemYellow : Design.Color.resolved(.tertiaryLabelColor, dark: isDark),
            detail: brightness == "—"
                ? L("Яркость экрана недоступна")
                : L("Яркость экрана") + " · " + brightness + " · " + brightnessTrend
        )

        let app = newFeed.topApp?.trimmingCharacters(in: .whitespacesAndNewlines)
        let appText = (app?.isEmpty == false) ? app! : "—"
        topAppCell.set(
            caption: L("Потребитель"),
            value: appText,
            symbol: "app.fill",
            tint: accent,
            detail: appText == "—" ? L("Ждём первый снимок приложений") : L("Активнее всего сейчас") + " · " + appText
        )

        let energy = SessionEnergy.wattHours >= 0.1
            ? String(format: L("%.1f Вт·ч"), SessionEnergy.wattHours)
            : "—"
        energyCell.set(
            caption: L("За сессию"),
            value: energy,
            symbol: "bolt.fill",
            tint: accent,
            detail: energy == "—" ? L("Собираем расход за текущую сессию") : L("Энергия за текущую сессию") + " · " + energy
        )

        if hoveredID != nil { emitDetail() }
    }

    private func hover(_ id: String?) {
        hoveredID = id
        emitDetail()
    }

    private func emitDetail() {
        guard let hoveredID else {
            detailSink?(nil)
            return
        }
        let cell: Cell?
        switch hoveredID {
        case "brightness": cell = brightnessCell
        case "topapp": cell = topAppCell
        case "energy": cell = energyCell
        default: cell = nil
        }
        detailSink?(cell?.detail)
    }
}
