import AppKit
import QuartzCore

/// Общий уровень качества для смысловых героев вкладок.
///
/// Карточка не диктует содержимое раздела: она лишь даёт ему ясный вердикт,
/// собственный символ и спокойную световую глубину. Основной визуал вкладки
/// (радар, рейтинг, временная шкала, поток энергии) остаётся уникальным.
final class TabStatusHeroView: NSView {
    private let surface = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let orb = CALayer()
    private let icon = NSImageView()
    private let eyebrow = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let metric = NSTextField(labelWithString: "")

    private var symbolName = "sparkles"
    private var tint = NSColor.systemTeal
    private var hasMetric = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 296, height: 88) }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        [eyebrow.stringValue, title.stringValue, subtitle.stringValue, metric.stringValue]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false

        surface.startPoint = CGPoint(x: 0, y: 0.5)
        surface.endPoint = CGPoint(x: 1, y: 0.5)
        surface.cornerRadius = 15
        surface.cornerCurve = .continuous
        surface.masksToBounds = true
        layer?.addSublayer(surface)

        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.locations = [0, 0.62, 1]
        glow.cornerRadius = 32
        surface.addSublayer(glow)

        orb.cornerRadius = 14
        orb.cornerCurve = .continuous
        surface.addSublayer(orb)

        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)

        eyebrow.font = Design.Font.sys(9, .medium)
        eyebrow.textColor = .secondaryLabelColor
        eyebrow.lineBreakMode = .byTruncatingTail

        title.font = Design.Font.sys(14, .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail

        subtitle.font = Design.Font.sys(10, .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        metric.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        metric.textColor = .labelColor
        metric.alignment = .right
        metric.lineBreakMode = .byTruncatingTail

        for view in [eyebrow, title, subtitle, metric] { addSubview(view) }
        restyle()
    }

    func set(
        symbol: String,
        eyebrow eyebrowText: String,
        title titleText: String,
        subtitle subtitleText: String,
        metric metricText: String? = nil,
        tint newTint: NSColor,
        animated: Bool = true
    ) {
        let oldTitle = title.stringValue
        symbolName = symbol
        tint = newTint
        eyebrow.stringValue = eyebrowText
        title.stringValue = titleText
        subtitle.stringValue = subtitleText
        metric.stringValue = metricText ?? ""
        hasMetric = !(metricText ?? "").isEmpty
        metric.isHidden = !hasMetric
        toolTip = titleText + (subtitleText.isEmpty ? "" : " · " + subtitleText)
        restyle()
        needsLayout = true

        guard animated, oldTitle != titleText, window != nil, !Motion.reduced else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = Design.Motion.durFast
        fade.timingFunction = Design.Motion.easeStandard
        for view in [title, subtitle, metric] { view.layer?.add(fade, forKey: "content") }
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = [1.0, 1.06, 1.0]
        pulse.duration = Design.Motion.durBase
        pulse.timingFunction = Design.Motion.easeStandard
        orb.add(pulse, forKey: "state")
    }

    override func layout() {
        super.layout()
        surface.frame = bounds
        glow.frame = CGRect(x: 0, y: 0, width: 88, height: bounds.height)
        orb.frame = CGRect(x: 14, y: (bounds.height - 44) / 2, width: 44, height: 44)
        icon.frame = CGRect(x: 25, y: (bounds.height - 22) / 2, width: 22, height: 22)

        let textX: CGFloat = 74
        let trailing: CGFloat = hasMetric ? 60 : 14
        let textWidth = max(90, bounds.width - textX - trailing)
        eyebrow.frame = CGRect(x: textX, y: bounds.height - 26, width: textWidth, height: 13)
        title.frame = CGRect(x: textX, y: bounds.height - 50, width: textWidth, height: 20)
        subtitle.frame = CGRect(x: textX, y: 13, width: textWidth, height: 14)
        metric.frame = CGRect(x: bounds.width - 60, y: (bounds.height - 28) / 2, width: 48, height: 28)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func restyle() {
        let color = Design.Color.resolved(tint, dark: isDark)
        let base = isDark ? NSColor.white.withAlphaComponent(0.046)
            : NSColor.black.withAlphaComponent(0.027)
        let tail = isDark ? NSColor.white.withAlphaComponent(0.020)
            : NSColor.black.withAlphaComponent(0.014)
        surface.colors = [
            color.withAlphaComponent(isDark ? 0.11 : 0.075).cgColor,
            base.cgColor,
            tail.cgColor,
        ]
        surface.locations = [0, 0.58, 1]
        surface.borderWidth = 0.6
        surface.borderColor = color.withAlphaComponent(isDark ? 0.22 : 0.16).cgColor
        glow.colors = [
            color.withAlphaComponent(isDark ? 0.30 : 0.20).cgColor,
            color.withAlphaComponent(isDark ? 0.08 : 0.05).cgColor,
            NSColor.clear.cgColor,
        ]
        orb.backgroundColor = color.withAlphaComponent(isDark ? 0.16 : 0.11).cgColor
        orb.borderWidth = 0.65
        orb.borderColor = color.withAlphaComponent(isDark ? 0.36 : 0.26).cgColor
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold))
        icon.contentTintColor = color
        metric.textColor = color
    }
}
