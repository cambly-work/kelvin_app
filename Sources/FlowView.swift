import AppKit
import QuartzCore

/// Живая energy scene для вкладки «Питание».
///
/// Визуал показывает только честную топологию `адаптер → Mac ↔ батарея` и один
/// общий замер системы. Компонентные CPU/GPU/DRAM-ватты намеренно исключены:
/// они приходят из другого источника и не складываются в достоверный баланс.
final class FlowView: NSView, NSViewToolTipOwner {

    // MARK: - Public API

    var detailSink: ((String?) -> Void)?

    func update(
        _ snapshot: EnergySnapshot,
        components: ComponentPower? = nil,
        hasBattery: Bool = true,
        batteryCharge: Int? = nil,
        externalPower: Bool? = nil,
        batteryCharging: Bool? = nil
    ) {
        let oldExternal = effectiveExternalPower
        let oldFlow = effectiveBatteryFlow

        self.snapshot = snapshot
        self.hasBattery = hasBattery
        self.batteryCharge = batteryCharge
        externalPowerOverride = externalPower
        batteryChargingOverride = batteryCharging
        _ = components // API совместим; component power не участвует в presentation.

        needsLayout = true
        layoutSubtreeIfNeeded()
        refresh(animated: hasPresentedData)

        if hasPresentedData, window != nil,
           oldExternal != effectiveExternalPower || oldFlow != effectiveBatteryFlow {
            animateSourceEvent()
        }
        hasPresentedData = true
    }

    func setUSBCount(_ count: Int, name: String?) {
        usbCount = max(0, count)
        usbFirstName = name
    }

    func pulseObod(connect: Bool) {
        guard !Motion.reduced else { return }
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = connect ? [1.0, 1.08, 1.0] : [1.0, 0.94, 1.0]
        pulse.keyTimes = [0, 0.5, 1]
        pulse.duration = connect ? 0.34 : 0.26
        pulse.timingFunction = Design.Motion.easeStandard
        sourceOrb.add(pulse, forKey: "eventPulse")
        sourceHalo.add(pulse, forKey: "eventPulse")
    }

    func focusNode(_ key: String) {
        let mapped: RegionKey
        switch key {
        case "Адаптер", "Источник": mapped = .source
        case "Батарея": mapped = .battery
        case "Система": mapped = .system
        default: mapped = .hero
        }
        selectedRegion = selectedRegion == mapped ? nil : mapped
        restyleRegions(animated: true)
        emitDetail()
    }

    // MARK: - State

    private var snapshot = EnergySnapshot()
    private var hasBattery = true
    private var batteryCharge: Int?
    private var externalPowerOverride: Bool?
    private var batteryChargingOverride: Bool?
    private var hasPresentedData = false
    private var usbCount = 0
    private var usbFirstName: String?

    private enum RegionKey: String { case hero, scene, source, system, battery }

    private struct Region {
        let key: RegionKey
        var rect: CGRect
        let surface: CALayer?
    }

    private var regions: [Region] = []
    private var hoveredRegion: RegionKey?
    private var selectedRegion: RegionKey?
    private var trackingAreaRef: NSTrackingArea?
    private var lastTooltipBounds: CGRect = .null

    // MARK: - Header layers

    private let heroSurface = CALayer()
    private let sourceHalo = CAGradientLayer()
    private let sourceOrb = CALayer()
    private let sourceIcon = CALayer()
    private let statusTitle = CATextLayer()
    private let statusSubtitle = CATextLayer()
    private let measurementSurface = CALayer()
    private let measurementTag = CATextLayer()
    private let trendTag = CATextLayer()

    // MARK: - Energy scene layers

    private let sceneSurface = CAGradientLayer()
    private let sceneTitle = CATextLayer()
    private let sceneStatus = CATextLayer()
    private let sourceStreamBase = CAShapeLayer()
    private let sourceStreamActive = CAShapeLayer()
    private let batteryStreamBase = CAShapeLayer()
    private let batteryStreamActive = CAShapeLayer()
    private let sourceArrow = CAShapeLayer()
    private let batteryArrow = CAShapeLayer()
    private let sourceParticle = CAShapeLayer()
    private let batteryParticle = CAShapeLayer()

    private final class NodeUI {
        let key: RegionKey
        let surface = CALayer()
        let icon = CALayer()
        let caption = CATextLayer()
        let value = CATextLayer()
        let stateDot = CAShapeLayer()

        init(key: RegionKey) {
            self.key = key
            surface.cornerCurve = .continuous
            surface.masksToBounds = false
            icon.contentsGravity = .resizeAspect
            caption.truncationMode = .end
            value.truncationMode = .end
            value.alignmentMode = .center
            caption.alignmentMode = .center
            stateDot.strokeColor = nil
            surface.addSublayer(icon)
            surface.addSublayer(caption)
            surface.addSublayer(value)
            surface.addSublayer(stateDot)
        }
    }

    private let adapterNode = NodeUI(key: .source)
    private let systemNode = NodeUI(key: .system)
    private let batteryNode = NodeUI(key: .battery)
    private var nodes: [NodeUI] { [adapterNode, systemNode, batteryNode] }

    // MARK: - Lifecycle

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 316, height: 188) }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { statusTitleText }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false

        heroSurface.cornerRadius = 15
        heroSurface.cornerCurve = .continuous
        heroSurface.masksToBounds = true
        layer?.addSublayer(heroSurface)

        sourceHalo.type = .radial
        sourceHalo.startPoint = CGPoint(x: 0.5, y: 0.5)
        sourceHalo.endPoint = CGPoint(x: 1, y: 1)
        sourceHalo.locations = [0, 0.54, 1]
        sourceHalo.cornerRadius = 30
        heroSurface.addSublayer(sourceHalo)

        sourceOrb.cornerRadius = 22
        sourceOrb.cornerCurve = .continuous
        sourceOrb.masksToBounds = true
        sourceIcon.contentsGravity = .resizeAspect
        sourceOrb.addSublayer(sourceIcon)
        heroSurface.addSublayer(sourceOrb)

        configureText(statusTitle, size: 17, weight: .semibold, color: .labelColor)
        configureText(statusSubtitle, size: 10.5, weight: .regular, color: .secondaryLabelColor)
        configureText(measurementTag, size: 8.5, weight: .semibold, color: .secondaryLabelColor)
        measurementTag.alignmentMode = .center
        configureText(trendTag, size: 9, weight: .medium, color: .tertiaryLabelColor)
        trendTag.alignmentMode = .right
        measurementSurface.cornerRadius = 8
        measurementSurface.cornerCurve = .continuous

        for item in [statusTitle, statusSubtitle, measurementSurface, measurementTag, trendTag] {
            heroSurface.addSublayer(item)
        }

        sceneSurface.cornerRadius = 15
        sceneSurface.cornerCurve = .continuous
        sceneSurface.masksToBounds = true
        sceneSurface.startPoint = CGPoint(x: 0, y: 0.5)
        sceneSurface.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(sceneSurface)

        configureText(sceneTitle, size: 9.5, weight: .medium, color: .secondaryLabelColor)
        configureText(sceneStatus, size: 9.5, weight: .medium, color: .secondaryLabelColor)
        sceneStatus.alignmentMode = .right
        layer?.addSublayer(sceneTitle)
        layer?.addSublayer(sceneStatus)

        for stream in [sourceStreamBase, sourceStreamActive, batteryStreamBase, batteryStreamActive] {
            stream.fillColor = nil
            stream.lineCap = .round
            stream.lineJoin = .round
            layer?.addSublayer(stream)
        }
        sourceStreamBase.lineWidth = 5
        batteryStreamBase.lineWidth = 5
        sourceStreamActive.lineWidth = 2.5
        batteryStreamActive.lineWidth = 2.5

        for arrow in [sourceArrow, batteryArrow] {
            arrow.strokeColor = nil
            layer?.addSublayer(arrow)
        }
        for particle in [sourceParticle, batteryParticle] {
            particle.path = CGPath(ellipseIn: CGRect(x: -3, y: -3, width: 6, height: 6), transform: nil)
            particle.opacity = 0
            layer?.addSublayer(particle)
        }

        for node in nodes {
            node.surface.cornerRadius = node.key == .system ? 15 : 13
            configureText(node.caption, size: 8.5, weight: .medium, color: .tertiaryLabelColor)
            configureText(
                node.value,
                size: node.key == .system ? 16 : 11,
                weight: .semibold,
                color: .labelColor,
                mono: node.key == .system
            )
            layer?.addSublayer(node.surface)
        }

        refresh(animated: false)
        updateContentsScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard bounds.width > 240, bounds.height > 160 else { return }

        let heroRect = rectFromTop(x: 0, top: 0, width: bounds.width, height: 70)
        let sceneRect = rectFromTop(x: 0, top: 78, width: bounds.width, height: 110)
        heroSurface.frame = heroRect
        sceneSurface.frame = sceneRect

        sourceHalo.frame = CGRect(x: 3, y: 2, width: 66, height: 66)
        sourceOrb.frame = CGRect(x: 12, y: 13, width: 44, height: 44)
        sourceIcon.frame = CGRect(x: 11, y: 11, width: 22, height: 22)
        statusTitle.frame = CGRect(x: 70, y: 39, width: 160, height: 23)
        statusSubtitle.frame = CGRect(x: 70, y: 17, width: heroRect.width - 178, height: 17)
        measurementSurface.frame = CGRect(x: heroRect.width - 74, y: 42, width: 62, height: 18)
        measurementTag.frame = measurementSurface.frame
        trendTag.frame = CGRect(x: heroRect.width - 104, y: 18, width: 92, height: 13)

        sceneTitle.frame = CGRect(x: 12, y: sceneRect.maxY - 22, width: 98, height: 13)
        sceneStatus.frame = CGRect(x: sceneRect.maxX - 194, y: sceneRect.maxY - 22, width: 182, height: 13)

        let nodeY = sceneRect.minY + 12
        adapterNode.surface.frame = CGRect(x: 8, y: nodeY + 5, width: 76, height: 62)
        systemNode.surface.frame = CGRect(x: 116, y: nodeY, width: 84, height: 72)
        batteryNode.surface.frame = CGRect(x: bounds.width - 84, y: nodeY + 5, width: 76, height: 62)
        layoutNode(adapterNode)
        layoutNode(systemNode)
        layoutNode(batteryNode)
        layoutStreams()

        regions = [
            Region(key: .hero, rect: heroRect, surface: heroSurface),
            Region(key: .scene, rect: sceneRect, surface: sceneSurface),
            Region(key: .source, rect: adapterNode.surface.frame, surface: adapterNode.surface),
            Region(key: .system, rect: systemNode.surface.frame, surface: systemNode.surface),
            Region(key: .battery, rect: batteryNode.surface.frame, surface: batteryNode.surface),
        ]
        restyleRegions(animated: false)
        if lastTooltipBounds != bounds {
            rebuildToolTips()
            lastTooltipBounds = bounds
        }
    }

    private func rectFromTop(x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: x, y: bounds.height - top - height, width: width, height: height)
    }

    private func layoutNode(_ node: NodeUI) {
        let height = node.surface.bounds.height
        let iconSize: CGFloat = node.key == .system ? 17 : 14
        node.icon.frame = CGRect(x: (node.surface.bounds.width - iconSize) / 2,
                                 y: height - iconSize - 9,
                                 width: iconSize,
                                 height: iconSize)
        node.caption.frame = CGRect(x: 5, y: height - iconSize - 24,
                                    width: node.surface.bounds.width - 10, height: 12)
        node.value.frame = CGRect(x: 4, y: 8, width: node.surface.bounds.width - 8,
                                  height: node.key == .system ? 20 : 15)
        node.stateDot.frame = CGRect(x: node.surface.bounds.width - 12, y: height - 12, width: 5, height: 5)
        node.stateDot.path = CGPath(ellipseIn: node.stateDot.bounds, transform: nil)
    }

    private func layoutStreams() {
        let sourceStart = CGPoint(x: adapterNode.surface.frame.maxX + 2, y: adapterNode.surface.frame.midY)
        let sourceEnd = CGPoint(x: systemNode.surface.frame.minX - 2, y: systemNode.surface.frame.midY)
        let batteryStart = CGPoint(x: systemNode.surface.frame.maxX + 2, y: systemNode.surface.frame.midY)
        let batteryEnd = CGPoint(x: batteryNode.surface.frame.minX - 2, y: batteryNode.surface.frame.midY)

        let sourcePath = curvedPath(from: sourceStart, to: sourceEnd)
        let batteryPath = curvedPath(from: batteryStart, to: batteryEnd)
        sourceStreamBase.path = sourcePath
        sourceStreamActive.path = sourcePath
        batteryStreamBase.path = batteryPath
        batteryStreamActive.path = batteryPath

        sourceArrow.path = arrowPath(
            at: midpoint(sourceStart, sourceEnd),
            forward: true
        )
        batteryArrow.path = arrowPath(
            at: midpoint(batteryStart, batteryEnd),
            forward: effectiveBatteryFlow != .discharging
        )
    }

    private func curvedPath(from start: CGPoint, to end: CGPoint, reversed: Bool = false) -> CGPath {
        let path = CGMutablePath()
        let a = reversed ? end : start
        let b = reversed ? start : end
        path.move(to: a)
        let lift: CGFloat = 3
        path.addCurve(
            to: b,
            control1: CGPoint(x: a.x + (b.x - a.x) * 0.34, y: a.y + lift),
            control2: CGPoint(x: a.x + (b.x - a.x) * 0.66, y: b.y + lift)
        )
        return path
    }

    private func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 + 2)
    }

    private func arrowPath(at point: CGPoint, forward: Bool) -> CGPath {
        let direction: CGFloat = forward ? 1 : -1
        let size: CGFloat = 3.8
        let path = CGMutablePath()
        path.move(to: CGPoint(x: point.x + direction * size, y: point.y))
        path.addLine(to: CGPoint(x: point.x - direction * size, y: point.y + size * 0.72))
        path.addLine(to: CGPoint(x: point.x - direction * size, y: point.y - size * 0.72))
        path.closeSubpath()
        return path
    }

    // MARK: - Refresh

    private func refresh(animated: Bool) {
        guard layer != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let accent = stateAccent
        heroSurface.backgroundColor = surfaceColor(strength: 0.050).cgColor
        heroSurface.borderWidth = 0.6
        heroSurface.borderColor = rimColor.cgColor
        sourceHalo.colors = [
            accent.withAlphaComponent(isDark ? 0.30 : 0.20).cgColor,
            accent.withAlphaComponent(isDark ? 0.10 : 0.07).cgColor,
            NSColor.clear.cgColor,
        ]
        sourceOrb.backgroundColor = accent.withAlphaComponent(isDark ? 0.17 : 0.13).cgColor
        sourceOrb.borderWidth = 0.75
        sourceOrb.borderColor = accent.withAlphaComponent(isDark ? 0.38 : 0.28).cgColor
        sourceIcon.contents = symbolImage(sourceSymbol, color: accent, pointSize: 19)

        statusTitle.string = statusTitleText
        statusSubtitle.string = statusSubtitleText
        statusTitle.foregroundColor = resolved(.labelColor).cgColor
        statusSubtitle.foregroundColor = resolved(.secondaryLabelColor).cgColor
        measurementTag.string = measurementText
        measurementSurface.backgroundColor = measurementColor.withAlphaComponent(isDark ? 0.12 : 0.08).cgColor
        measurementSurface.borderWidth = 0.5
        measurementSurface.borderColor = measurementColor.withAlphaComponent(0.24).cgColor
        measurementTag.foregroundColor = measurementColor.cgColor
        trendTag.string = trendWord
        trendTag.foregroundColor = trendColor.cgColor

        sceneSurface.colors = [
            accent.withAlphaComponent(isDark ? 0.075 : 0.045).cgColor,
            surfaceColor(strength: isDark ? 0.025 : 0.018).cgColor,
            batteryAccent.withAlphaComponent(isDark ? 0.065 : 0.04).cgColor,
        ]
        sceneSurface.locations = [0, 0.52, 1]
        sceneSurface.borderWidth = 0.6
        sceneSurface.borderColor = rimColor.cgColor
        sceneTitle.string = L("Поток энергии")
        sceneStatus.string = flowSummary
        sceneTitle.foregroundColor = resolved(.secondaryLabelColor).cgColor
        sceneStatus.foregroundColor = resolved(.tertiaryLabelColor).cgColor

        refreshNodes()
        refreshStreams()
        CATransaction.commit()

        needsLayout = true
        restyleRegions(animated: animated)
        if animated { animateFlowParticles() }
    }

    private func refreshNodes() {
        let adapterActive = effectiveExternalPower
        setNode(
            adapterNode,
            symbol: "powerplug.fill",
            caption: L("Адаптер"),
            value: adapterValue,
            tint: adapterActive ? stateAccent : resolved(.tertiaryLabelColor),
            active: adapterActive
        )

        let systemValue = displayedWatts.map { String(format: L("%.0f Вт"), $0) } ?? "—"
        setNode(
            systemNode,
            symbol: "macbook",
            caption: L("Система"),
            value: systemValue,
            tint: stateAccent,
            active: displayedWatts != nil
        )

        let batteryValue = batteryCharge.map { "\($0)%" } ?? "—"
        setNode(
            batteryNode,
            symbol: batterySymbol,
            caption: hasBattery ? batteryShortState : L("Без батареи"),
            value: batteryValue,
            tint: batteryAccent,
            active: hasBattery
        )
    }

    private func setNode(
        _ node: NodeUI,
        symbol: String,
        caption: String,
        value: String,
        tint: NSColor,
        active: Bool
    ) {
        node.icon.contents = symbolImage(symbol, color: tint, pointSize: node.key == .system ? 15 : 12)
        node.caption.string = caption
        node.value.string = value
        node.caption.foregroundColor = resolved(.tertiaryLabelColor).cgColor
        node.value.foregroundColor = resolved(active ? .labelColor : .tertiaryLabelColor).cgColor
        node.stateDot.fillColor = tint.withAlphaComponent(active ? 0.95 : 0.30).cgColor
        node.surface.backgroundColor = surfaceColor(strength: node.key == .system ? 0.060 : 0.038).cgColor
        node.surface.borderWidth = node.key == .system ? 0.75 : 0.5
        node.surface.borderColor = (node.key == .system
            ? stateAccent.withAlphaComponent(isDark ? 0.25 : 0.18)
            : rimColor).cgColor
        node.surface.opacity = active || node.key == .system ? 1 : 0.58
    }

    private func refreshStreams() {
        let inactive = resolved(.tertiaryLabelColor).withAlphaComponent(isDark ? 0.14 : 0.10)
        sourceStreamBase.strokeColor = inactive.cgColor
        batteryStreamBase.strokeColor = inactive.cgColor

        sourceStreamActive.strokeColor = stateAccent.withAlphaComponent(0.90).cgColor
        sourceStreamActive.isHidden = !effectiveExternalPower
        sourceArrow.fillColor = stateAccent.cgColor
        sourceArrow.isHidden = !effectiveExternalPower

        batteryStreamActive.strokeColor = batteryAccent.withAlphaComponent(0.90).cgColor
        batteryStreamActive.isHidden = !hasBattery || effectiveBatteryFlow == .idle
        batteryArrow.fillColor = batteryAccent.cgColor
        batteryArrow.isHidden = !hasBattery || effectiveBatteryFlow == .idle
        sourceParticle.fillColor = stateAccent.cgColor
        batteryParticle.fillColor = batteryAccent.cgColor
        layoutStreams()
    }

    // MARK: - Flow animation

    private func animateFlowParticles() {
        guard !Motion.reduced else { return }
        if effectiveExternalPower, let path = sourceStreamActive.path {
            animateParticle(sourceParticle, along: path)
        }
        if hasBattery, effectiveBatteryFlow != .idle {
            let start = CGPoint(x: systemNode.surface.frame.maxX + 2, y: systemNode.surface.frame.midY)
            let end = CGPoint(x: batteryNode.surface.frame.minX - 2, y: batteryNode.surface.frame.midY)
            let path = curvedPath(from: start, to: end, reversed: effectiveBatteryFlow == .discharging)
            animateParticle(batteryParticle, along: path)
        }
    }

    private func animateParticle(_ particle: CAShapeLayer, along path: CGPath) {
        particle.removeAnimation(forKey: "travel")
        let position = CAKeyframeAnimation(keyPath: "position")
        position.path = path
        position.calculationMode = .paced

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 0.9, 0.9, 0]
        opacity.keyTimes = [0, 0.18, 0.82, 1]

        let group = CAAnimationGroup()
        group.animations = [position, opacity]
        group.duration = 0.72
        group.timingFunction = Design.Motion.easeStandard
        particle.add(group, forKey: "travel")
    }

    private func animateSourceEvent() {
        pulseObod(connect: effectiveExternalPower)
        guard !Motion.reduced else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.3
        fade.toValue = 1
        fade.duration = 0.30
        fade.timingFunction = Design.Motion.easeStandard
        statusTitle.add(fade, forKey: "sourceChange")
        statusSubtitle.add(fade, forKey: "sourceChange")
    }

    // MARK: - Interaction

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = regions.reversed().first(where: { $0.rect.contains(point) })?.key
        guard hit != hoveredRegion else { return }
        hoveredRegion = hit
        restyleRegions(animated: true)
        emitDetail()
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredRegion != nil else { return }
        hoveredRegion = nil
        restyleRegions(animated: true)
        emitDetail()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = regions.reversed().first(where: { $0.rect.contains(point) })?.key else {
            selectedRegion = nil
            restyleRegions(animated: true)
            emitDetail()
            return
        }
        selectedRegion = selectedRegion == hit ? nil : hit
        restyleRegions(animated: true)
        emitDetail()
    }

    private func restyleRegions(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated && !Motion.reduced ? Design.Motion.durFast : 0)
        CATransaction.setAnimationTimingFunction(Design.Motion.easeStandard)
        for region in regions {
            guard let surface = region.surface else { continue }
            let active = region.key == hoveredRegion || region.key == selectedRegion
            if active {
                surface.borderColor = stateAccent.withAlphaComponent(isDark ? 0.38 : 0.28).cgColor
                if region.key != .scene {
                    surface.backgroundColor = stateAccent.withAlphaComponent(isDark ? 0.105 : 0.075).cgColor
                }
            } else if let node = nodes.first(where: { $0.key == region.key }) {
                node.surface.backgroundColor = surfaceColor(strength: node.key == .system ? 0.060 : 0.038).cgColor
                node.surface.borderColor = (node.key == .system
                    ? stateAccent.withAlphaComponent(isDark ? 0.25 : 0.18)
                    : rimColor).cgColor
            } else if region.key == .hero {
                surface.backgroundColor = surfaceColor(strength: 0.050).cgColor
                surface.borderColor = rimColor.cgColor
            }
        }
        CATransaction.commit()
    }

    private func emitDetail() {
        guard let key = hoveredRegion ?? selectedRegion else {
            detailSink?(nil)
            return
        }
        detailSink?(detail(for: key))
    }

    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        guard let key = regions.reversed().first(where: { $0.rect.contains(point) })?.key else { return "" }
        return detail(for: key)
    }

    private func rebuildToolTips() {
        removeAllToolTips()
        for region in regions where !region.rect.isEmpty { addToolTip(region.rect, owner: self, userData: nil) }
    }

    private func detail(for key: RegionKey) -> String {
        switch key {
        case .hero:
            var result = statusTitleText + " · " + statusSubtitleText
            if let watts = displayedWatts {
                result += " · " + String(format: L("%.0f Вт"), watts)
                result += " · " + (measurementIsDirect ? L("прямой датчик") : L("оценка по источнику питания"))
            }
            if usbCount > 0 { result += " · " + String(format: L("USB-устройства: %d"), usbCount) }
            return result

        case .scene:
            return flowSummary + " · " + trendWord

        case .source:
            if effectiveExternalPower {
                if let rated = snapshot.adapterRatedWatts {
                    return String(format: L("Адаптер подключён · номинал %d Вт"), rated)
                }
                return L("Адаптер подключён")
            }
            return L("Адаптер не подключён")

        case .system:
            guard let watts = displayedWatts else { return L("Данные о мощности недоступны") }
            return String(format: L("Расход %.0f Вт"), watts) + " · " + measurementText + " · " + trendWord

        case .battery:
            guard hasBattery else { return L("Батарея не обнаружена") }
            let percent = batteryCharge.map { "\($0)% · " } ?? ""
            let usb = usbFirstName.map { " · USB: \($0)" } ?? ""
            return percent + batteryStateLong + usb
        }
    }

    // MARK: - Presentation semantics

    private var effectiveExternalPower: Bool { externalPowerOverride ?? snapshot.plugged }

    private var effectiveBatteryFlow: BatteryFlow {
        if snapshot.battFlow != .idle { return snapshot.battFlow }
        if batteryChargingOverride == true { return .charging }
        if hasBattery, !effectiveExternalPower { return .discharging }
        return .idle
    }

    private var displayedWatts: Double? {
        let value = snapshot.systemWatts
        return value.isFinite && value > 0.1 ? value : nil
    }

    private var measurementIsDirect: Bool {
        guard let value = snapshot.systemWattsMeasured else { return false }
        return value.isFinite && value > 0.05
    }

    private var measurementText: String {
        guard displayedWatts != nil else { return L("Без измерения") }
        return measurementIsDirect ? L("Датчик") : L("Оценка")
    }

    private var measurementColor: NSColor {
        displayedWatts == nil ? resolved(.tertiaryLabelColor) : stateAccent
    }

    private var statusTitleText: String {
        guard effectiveExternalPower else { return hasBattery ? L("От батареи") : L("Питание") }
        if hasBattery, effectiveBatteryFlow == .charging { return L("Зарядка") }
        return L("От сети")
    }

    private var statusSubtitleText: String {
        guard effectiveExternalPower else {
            return hasBattery ? L("Mac питается от батареи") : L("Источник питания не определён")
        }
        guard hasBattery else { return L("Mac питается от сети") }
        switch effectiveBatteryFlow {
        case .charging: return L("Mac питается от адаптера")
        case .discharging: return L("Батарея дополняет адаптер")
        case .idle: return L("Mac питается от адаптера")
        }
    }

    private var sourceSymbol: String {
        effectiveExternalPower ? "powerplug.fill" : (hasBattery ? "battery.75" : "bolt.slash.fill")
    }

    private var adapterValue: String {
        guard effectiveExternalPower else { return "—" }
        return L("От сети")
    }

    private var batteryShortState: String {
        switch effectiveBatteryFlow {
        case .charging: return L("заряд")
        case .discharging: return L("разряд")
        case .idle: return L("ожидание")
        }
    }

    private var batteryStateLong: String {
        switch effectiveBatteryFlow {
        case .charging: return L("Батарея заряжается")
        case .discharging: return L("Батарея питает Mac")
        case .idle: return effectiveExternalPower ? L("Батарея не используется") : L("Батарея питает Mac")
        }
    }

    private var batterySymbol: String {
        switch effectiveBatteryFlow {
        case .charging: return "battery.100.bolt"
        case .discharging: return "battery.75"
        case .idle: return "battery.100"
        }
    }

    private var trendWord: String {
        if displayedWatts == nil { return L("Наблюдаем") }
        if snapshot.loadDelta > 1.2 { return L("Растёт") }
        if snapshot.loadDelta < -1.2 { return L("Снижается") }
        return L("Стабильно")
    }

    private var trendColor: NSColor {
        if abs(snapshot.loadDelta) <= 1.2 { return resolved(.tertiaryLabelColor) }
        return snapshot.loadDelta > 0 ? stateAccent : resolved(.secondaryLabelColor)
    }

    private var flowSummary: String {
        guard effectiveExternalPower else { return hasBattery ? L("Батарея → Mac") : L("Источник не определён") }
        switch effectiveBatteryFlow {
        case .charging: return L("Адаптер → Mac → батарея")
        case .discharging: return L("Адаптер + батарея → Mac")
        case .idle: return L("Адаптер → Mac")
        }
    }

    // MARK: - Colors and symbols

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func resolved(_ color: NSColor) -> NSColor { Design.Color.resolved(color, dark: isDark) }

    private var stateAccent: NSColor {
        if hasBattery, let charge = batteryCharge, !effectiveExternalPower {
            if charge <= 15 { return resolved(Design.Color.levelCrit) }
            if charge <= 35 { return resolved(Design.Color.levelWarn) }
            return resolved(Design.Color.levelOK)
        }
        if effectiveExternalPower, effectiveBatteryFlow == .discharging {
            return resolved(Design.Color.levelWarn)
        }
        return resolved(Design.Color.accent(isDark))
    }

    private var batteryAccent: NSColor {
        if effectiveBatteryFlow == .charging { return resolved(Design.Color.accent(isDark)) }
        guard let charge = batteryCharge else { return resolved(.secondaryLabelColor) }
        if charge <= 15 { return resolved(Design.Color.levelCrit) }
        if charge <= 35 { return resolved(Design.Color.levelWarn) }
        return resolved(Design.Color.levelOK)
    }

    private func surfaceColor(strength: CGFloat) -> NSColor {
        isDark ? NSColor.white.withAlphaComponent(strength)
            : NSColor.black.withAlphaComponent(strength * 0.68)
    }

    private var rimColor: NSColor {
        isDark ? NSColor.white.withAlphaComponent(0.085)
            : NSColor.black.withAlphaComponent(0.065)
    }

    private func configureText(
        _ layer: CATextLayer,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor,
        mono: Bool = false
    ) {
        let font = mono
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        layer.font = font
        layer.fontSize = size
        layer.foregroundColor = resolved(color).cgColor
        layer.truncationMode = .end
        layer.isWrapped = false
    }

    private func symbolImage(_ name: String, color: NSColor, pointSize: CGFloat) -> CGImage? {
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

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let textLayers = [statusTitle, statusSubtitle, measurementTag, trendTag, sceneTitle, sceneStatus]
            + nodes.flatMap { [$0.caption, $0.value] }
        textLayers.forEach { $0.contentsScale = scale }
        let allLayers: [CALayer] = [
            heroSurface, sourceHalo, sourceOrb, sourceIcon, measurementSurface, sceneSurface,
            sourceStreamBase, sourceStreamActive, batteryStreamBase, batteryStreamActive,
            sourceArrow, batteryArrow, sourceParticle, batteryParticle,
        ]
        allLayers.forEach { $0.contentsScale = scale }
        for node in nodes {
            node.surface.contentsScale = scale
            node.icon.contentsScale = scale
            node.stateDot.contentsScale = scale
        }
    }
}
