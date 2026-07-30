import AppKit
import QuartzCore

/// V7 — компактный инженерный индикатор энергопотока для popover.
///
/// Визуальная модель:
///   1. одна сводка: расход системы + текущий режим питания;
///   2. одна линейная схема: адаптер → система ↔ батарея;
///   3. компактный список потребителей с честными единицами и долями;
///   4. одна строка баланса внизу.
///
/// Постоянные декоративные анимации отсутствуют. Движение используется только как
/// подтверждение события: подключение/отключение адаптера, смена направления батареи,
/// существенное изменение нагрузки и активация узла.
final class FlowView: NSView, NSViewToolTipOwner {

    // MARK: - Public API

    /// Однострочный разбор узла под курсором либо зафиксированного кликом/клавиатурой.
    var detailSink: ((String?) -> Void)?

    /// Обновляет данные без пересоздания слоёв, пока не изменился набор потребителей.
    func update(_ snapshot: EnergySnapshot,
                components: ComponentPower? = nil,
                hasBattery: Bool = true) {
        let oldPlugged = previousPlugged
        let oldBatteryTag = previousBatteryTag

        self.snapshot = snapshot
        self.components = components
        self.hasBattery = hasBattery

        let newTopology = topologySignature()
        if newTopology != topologySig || nodes.isEmpty {
            topologySig = newTopology
            rebuildTopology()
        }

        needsLayout = true
        layoutSubtreeIfNeeded()
        refresh(animated: !pendingFirstSync)

        if !pendingFirstSync, window != nil {
            if let oldPlugged, oldPlugged != snapshot.plugged {
                animateAdapterEvent(connected: snapshot.plugged)
            }
            let newTag = batteryFlowTag(snapshot.battFlow)
            if let oldBatteryTag, oldBatteryTag != newTag {
                animateBatteryDirectionChange()
            }
        }

        previousPlugged = snapshot.plugged
        previousBatteryTag = batteryFlowTag(snapshot.battFlow)
        pendingFirstSync = false
    }

    /// Показывает честный счётчик USB-устройств без выдуманной мощности.
    func setUSBCount(_ count: Int, name: String?) {
        usbCount = max(0, count)
        usbFirstName = name
        refreshUSBText()
    }

    /// Совместимость с прежним API. В V7 это короткий событийный импульс центрального узла,
    /// а не анимация сложного кольца.
    func pulseObod(connect: Bool) {
        guard !Motion.reduced, let system = node("Система") else { return }
        pulse(layer: system.container,
              scale: connect ? 1.055 : 0.975,
              duration: connect ? 0.34 : 0.26)
        pulse(layer: headerValue,
              scale: connect ? 1.035 : 0.985,
              duration: connect ? 0.34 : 0.26)
    }

    /// Клавиатура/VoiceOver используют ту же фиксацию, что и клик.
    func focusNode(_ key: String) {
        focusedKey = (focusedKey == key) ? nil : key
        restyle(animated: true)
        emitDetail()
    }

    // MARK: - Presentation objects

    private enum NodeKind {
        case adapter
        case system
        case battery
        case load
    }

    private final class NodeUI {
        let key: String
        let kind: NodeKind
        var rect: CGRect = .zero

        let container = CALayer()
        let icon = CALayer()
        let title = CATextLayer()
        let value = CATextLayer()
        let auxiliary = CATextLayer()
        let stateDot = CAShapeLayer()
        let barTrack = CAShapeLayer()
        let barFill = CAShapeLayer()
        let separator = CAShapeLayer()

        var lastValueToken = ""
        var lastTitleToken = ""
        var lastAuxiliaryToken = ""
        var lastSymbolToken = ""
        var appliedBarFraction: Double = .nan

        init(key: String, kind: NodeKind) {
            self.key = key
            self.kind = kind

            container.cornerCurve = .continuous
            container.masksToBounds = false

            icon.contentsGravity = .resizeAspect

            for text in [title, value, auxiliary] {
                text.truncationMode = .end
                text.isWrapped = false
            }

            barTrack.fillColor = nil
            barTrack.lineCap = .round
            barFill.fillColor = nil
            barFill.lineCap = .round

            separator.fillColor = nil
            separator.lineWidth = 1

            container.addSublayer(icon)
            container.addSublayer(title)
            container.addSublayer(value)
            container.addSublayer(auxiliary)
            container.addSublayer(stateDot)
            container.addSublayer(barTrack)
            container.addSublayer(barFill)
            container.addSublayer(separator)
        }
    }

    private final class EdgeUI {
        let line = CAShapeLayer()
        let arrow = CAShapeLayer()
        var start: CGPoint = .zero
        var end: CGPoint = .zero

        init() {
            line.fillColor = nil
            line.lineCap = .round
            arrow.lineWidth = 0
        }
    }

    // MARK: - Model state

    private var snapshot = EnergySnapshot()
    private var components: ComponentPower?
    private var hasBattery = true

    private var topologySig = ""
    private var previousPlugged: Bool?
    private var previousBatteryTag: String?
    private var pendingFirstSync = true

    private var hoveredKey: String?
    private var focusedKey: String?

    private var usbCount = 0
    private var usbFirstName: String?
    private var lastHeaderValueToken = ""

    private var nodes: [NodeUI] = []
    private var nodeViews: [FlowNodeView] = []

    private let adapterEdge = EdgeUI()
    private let batteryEdge = EdgeUI()

    private var trackingAreaRef: NSTrackingArea?
    private var lastLayoutBounds: CGRect = .null

    // MARK: - Static chrome

    private let headerTitle = CATextLayer()
    private let headerStatus = CATextLayer()
    private let headerValue = CATextLayer()
    private let headerStatusDot = CAShapeLayer()
    private let usbLayer = CATextLayer()
    private let headerDivider = CAShapeLayer()
    private let loadsTitle = CATextLayer()
    private let footerText = CATextLayer()

    // MARK: - Geometry

    private struct Metrics {
        let width: CGFloat
        let height: CGFloat
        let compact: Bool
        let tiny: Bool
        let padding: CGFloat
        let headerHeight: CGFloat
        let topologyHeight: CGFloat
        let sectionHeight: CGFloat
        let footerHeight: CGFloat
        let verticalGap: CGFloat
        let rowHeight: CGFloat
        let rowCount: Int

        init(bounds: CGRect, rowCount: Int) {
            width = bounds.width
            height = bounds.height
            compact = bounds.height < 248
            tiny = bounds.height < 220
            padding = tiny ? 6 : (compact ? 8 : 10)
            headerHeight = tiny ? 38 : (compact ? 42 : 48)
            topologyHeight = tiny ? 38 : (compact ? 42 : 50)
            sectionHeight = tiny ? 12 : (compact ? 14 : 16)
            footerHeight = tiny ? 15 : (compact ? 17 : 19)
            verticalGap = tiny ? 3 : (compact ? 5 : 7)
            self.rowCount = max(rowCount, 1)

            let reserved = padding * 2
                + headerHeight
                + topologyHeight
                + sectionHeight
                + footerHeight
                + verticalGap * 4
            let available = max(18 * CGFloat(self.rowCount), height - reserved)
            rowHeight = max(tiny ? 15 : 18,
                            min(tiny ? 20 : (compact ? 24 : 28),
                                available / CGFloat(self.rowCount)))
        }

        func rectFromTop(x: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
            CGRect(x: x, y: self.height - top - height, width: width, height: height)
        }
    }

    override var intrinsicContentSize: NSSize {
        let rows = max(orderedRails.count, 1)
        return NSSize(width: 390, height: 158 + CGFloat(rows) * 26)
    }

    // MARK: - Lifecycle

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
        layer?.masksToBounds = false
        buildStaticChrome()
    }

    override var isFlipped: Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { L("Схема энергопотока") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pendingFirstSync = true
        updateContentsScale()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidatePresentationTokens()
        refresh(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func layout() {
        super.layout()
        guard bounds.width > 220, bounds.height > 150 else { return }

        let metrics = Metrics(bounds: bounds, rowCount: orderedRails.count)
        layoutStaticChrome(metrics)
        layoutTopology(metrics)
        layoutLoadRows(metrics)
        layoutEdges()
        layoutAccessibilityViews()

        if lastLayoutBounds != bounds {
            rebuildToolTips()
            lastLayoutBounds = bounds
        }
    }

    // MARK: - Topology construction

    private var orderedRails: [RailFlow] {
        let priority = ["CPU": 0, "GPU": 1, "Память": 2]
        return snapshot.rails.enumerated().sorted {
            (priority[$0.element.name] ?? 3, $0.offset)
                < (priority[$1.element.name] ?? 3, $1.offset)
        }.map(\.element)
    }

    private func topologySignature() -> String {
        (hasBattery ? "B|" : "-|" )
            + orderedRails.map(\.name).joined(separator: ",")
    }

    private func rebuildTopology() {
        nodes.forEach { $0.container.removeFromSuperlayer() }
        nodeViews.forEach { $0.removeFromSuperview() }
        nodes.removeAll(keepingCapacity: true)
        nodeViews.removeAll(keepingCapacity: true)
        removeAllToolTips()
        lastLayoutBounds = .null

        appendNode(key: "Адаптер", kind: .adapter)
        appendNode(key: "Система", kind: .system)
        if hasBattery { appendNode(key: "Батарея", kind: .battery) }
        for rail in orderedRails { appendNode(key: rail.name, kind: .load) }

        for (index, view) in nodeViews.enumerated() where !nodeViews.isEmpty {
            view.nextKeyView = nodeViews[(index + 1) % nodeViews.count]
        }

        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func appendNode(key: String, kind: NodeKind) {
        let node = NodeUI(key: key, kind: kind)
        configureNodeLayers(node)
        layer?.addSublayer(node.container)
        nodes.append(node)

        let accessibilityView = FlowNodeView(key: key)
        accessibilityView.onActivate = { [weak self] key in self?.focusNode(key) }
        addSubview(accessibilityView)
        nodeViews.append(accessibilityView)
    }

    private func buildStaticChrome() {
        guard let root = layer else { return }

        configureText(headerTitle, size: 10, weight: .semibold, color: .secondaryLabelColor)
        configureText(headerStatus, size: 10, weight: .regular, color: .secondaryLabelColor)
        configureText(headerValue, size: 23, weight: .semibold, color: .labelColor, mono: true)
        headerValue.alignmentMode = .right

        configureText(usbLayer, size: 9, weight: .medium, color: .tertiaryLabelColor, mono: true)
        usbLayer.alignmentMode = .right
        usbLayer.isHidden = true

        configureText(loadsTitle, size: 9, weight: .semibold, color: .tertiaryLabelColor)
        configureText(footerText, size: 9, weight: .regular, color: .secondaryLabelColor, mono: true)
        footerText.alignmentMode = .left

        headerStatusDot.strokeColor = nil
        headerDivider.fillColor = nil
        headerDivider.lineWidth = 1

        root.addSublayer(headerTitle)
        root.addSublayer(headerStatus)
        root.addSublayer(headerValue)
        root.addSublayer(headerStatusDot)
        root.addSublayer(usbLayer)
        root.addSublayer(headerDivider)
        root.addSublayer(loadsTitle)
        root.addSublayer(footerText)

        root.addSublayer(adapterEdge.line)
        root.addSublayer(adapterEdge.arrow)
        root.addSublayer(batteryEdge.line)
        root.addSublayer(batteryEdge.arrow)

        updateContentsScale()
    }

    private func configureNodeLayers(_ node: NodeUI) {
        configureText(node.title, size: 9, weight: .medium, color: .secondaryLabelColor)
        configureText(node.value, size: 11, weight: .semibold, color: .labelColor, mono: true)
        configureText(node.auxiliary, size: 9, weight: .regular, color: .tertiaryLabelColor, mono: true)

        node.stateDot.strokeColor = nil
        node.separator.strokeColor = separatorColor.cgColor
        node.barTrack.strokeColor = trackColor.cgColor
        node.barFill.strokeColor = accentColor.cgColor

        updateContentsScale(node)
    }

    // MARK: - Layout

    private func layoutStaticChrome(_ m: Metrics) {
        let p = m.padding
        let valueWidth: CGFloat = m.compact ? 102 : 116

        headerTitle.frame = m.rectFromTop(
            x: p,
            top: p,
            width: max(80, m.width - p * 2 - valueWidth),
            height: 13
        )
        headerStatusDot.frame = m.rectFromTop(x: p, top: p + 23, width: 7, height: 7)
        headerStatusDot.path = CGPath(ellipseIn: headerStatusDot.bounds, transform: nil)
        headerStatus.frame = m.rectFromTop(
            x: p + 12,
            top: p + 20,
            width: max(90, m.width - p * 2 - valueWidth - 12),
            height: 14
        )
        headerValue.frame = m.rectFromTop(
            x: m.width - p - valueWidth,
            top: p + 2,
            width: valueWidth,
            height: 30
        )
        usbLayer.frame = m.rectFromTop(
            x: max(p, m.width - p - valueWidth - 100),
            top: p + 28,
            width: 96,
            height: 11
        )

        let dividerY = m.height - (p + m.headerHeight)
        let dividerPath = CGMutablePath()
        dividerPath.move(to: CGPoint(x: p, y: dividerY))
        dividerPath.addLine(to: CGPoint(x: m.width - p, y: dividerY))
        headerDivider.path = dividerPath
        headerDivider.strokeColor = separatorColor.cgColor

        let topologyTop = p + m.headerHeight + m.verticalGap
        let loadsTop = topologyTop + m.topologyHeight + m.verticalGap
        loadsTitle.frame = m.rectFromTop(
            x: p,
            top: loadsTop,
            width: m.width - p * 2,
            height: m.sectionHeight
        )

        footerText.frame = m.rectFromTop(
            x: p,
            top: m.height - p - m.footerHeight,
            width: m.width - p * 2,
            height: m.footerHeight
        )
    }

    private func layoutTopology(_ m: Metrics) {
        guard let adapter = node("Адаптер"), let system = node("Система") else { return }

        let p = m.padding
        let top = p + m.headerHeight + m.verticalGap
        let gap: CGFloat = m.compact ? 8 : 10
        let centerWidth: CGFloat = m.tiny ? 62 : (m.compact ? 70 : 78)
        let availableForSources = m.width - p * 2 - centerWidth - gap * 2
        let sourceWidth: CGFloat
        if hasBattery {
            sourceWidth = max(68, min(118, availableForSources / 2))
        } else {
            sourceWidth = max(82, min(118, availableForSources * 0.48))
        }

        if hasBattery, let battery = node("Батарея") {
            adapter.rect = m.rectFromTop(x: p, top: top, width: sourceWidth, height: m.topologyHeight)
            system.rect = m.rectFromTop(
                x: (m.width - centerWidth) / 2,
                top: top,
                width: centerWidth,
                height: m.topologyHeight
            )
            battery.rect = m.rectFromTop(
                x: m.width - p - sourceWidth,
                top: top,
                width: sourceWidth,
                height: m.topologyHeight
            )
            layoutSourceNode(adapter, metrics: m)
            layoutSystemNode(system, metrics: m)
            layoutSourceNode(battery, metrics: m)
        } else {
            adapter.rect = m.rectFromTop(x: p, top: top, width: sourceWidth, height: m.topologyHeight)
            system.rect = m.rectFromTop(
                x: min(m.width - p - centerWidth, adapter.rect.maxX + gap + (m.width - p - adapter.rect.maxX - gap - centerWidth) / 2),
                top: top,
                width: centerWidth,
                height: m.topologyHeight
            )
            layoutSourceNode(adapter, metrics: m)
            layoutSystemNode(system, metrics: m)
        }
    }

    private func layoutSourceNode(_ node: NodeUI, metrics m: Metrics) {
        let r = node.rect
        node.container.frame = r
        node.container.cornerRadius = 9

        let iconSize: CGFloat = m.compact ? 14 : 16
        node.icon.frame = CGRect(x: 8, y: (r.height - iconSize) / 2, width: iconSize, height: iconSize)
        node.stateDot.frame = CGRect(x: r.width - 11, y: r.height - 11, width: 5, height: 5)
        node.stateDot.path = CGPath(ellipseIn: node.stateDot.bounds, transform: nil)

        let textX = 8 + iconSize + 7
        node.title.frame = CGRect(x: textX, y: r.height - 18, width: r.width - textX - 13, height: 12)
        node.value.frame = CGRect(x: textX, y: 8, width: r.width - textX - 6, height: 15)
        node.auxiliary.frame = .zero

        node.barTrack.isHidden = true
        node.barFill.isHidden = true
        node.separator.isHidden = true
    }

    private func layoutSystemNode(_ node: NodeUI, metrics m: Metrics) {
        let r = node.rect
        node.container.frame = r
        node.container.cornerRadius = 9

        let iconSize: CGFloat = m.compact ? 17 : 19
        node.icon.frame = CGRect(x: (r.width - iconSize) / 2,
                                 y: r.height / 2 - iconSize / 2 + 6,
                                 width: iconSize,
                                 height: iconSize)
        node.title.alignmentMode = .center
        node.title.frame = CGRect(x: 3, y: 7, width: r.width - 6, height: 12)
        node.value.frame = .zero
        node.auxiliary.frame = .zero
        node.stateDot.frame = .zero

        node.barTrack.isHidden = true
        node.barFill.isHidden = true
        node.separator.isHidden = true
    }

    private func layoutLoadRows(_ m: Metrics) {
        let p = m.padding
        let topologyTop = p + m.headerHeight + m.verticalGap
        let loadsTop = topologyTop + m.topologyHeight + m.verticalGap
        var rowTop = loadsTop + m.sectionHeight

        let loadNodes = nodes.filter { $0.kind == .load }
        for node in loadNodes {
            node.rect = m.rectFromTop(x: p, top: rowTop, width: m.width - p * 2, height: m.rowHeight)
            layoutLoadNode(node, metrics: m)
            rowTop += m.rowHeight
        }
    }

    private func layoutLoadNode(_ node: NodeUI, metrics m: Metrics) {
        let r = node.rect
        node.container.frame = r
        node.container.cornerRadius = 6

        let iconSize: CGFloat = m.compact ? 11 : 12
        let iconX: CGFloat = 3
        node.icon.frame = CGRect(x: iconX, y: (r.height - iconSize) / 2, width: iconSize, height: iconSize)

        let titleX = iconX + iconSize + 7
        let titleWidth: CGFloat = m.compact ? 66 : 78
        node.title.frame = CGRect(x: titleX, y: (r.height - 13) / 2, width: titleWidth, height: 13)

        let auxiliaryWidth: CGFloat = 34
        let valueWidth: CGFloat = m.compact ? 58 : 66
        let rightPadding: CGFloat = 2
        node.auxiliary.alignmentMode = .right
        node.auxiliary.frame = CGRect(
            x: r.width - rightPadding - auxiliaryWidth,
            y: (r.height - 12) / 2,
            width: auxiliaryWidth,
            height: 12
        )
        node.value.alignmentMode = .right
        node.value.frame = CGRect(
            x: node.auxiliary.frame.minX - 4 - valueWidth,
            y: (r.height - 14) / 2,
            width: valueWidth,
            height: 14
        )

        let barX = titleX + titleWidth + 7
        let barEnd = node.value.frame.minX - 8
        let barWidth = max(18, barEnd - barX)
        let barY = r.height / 2
        let barPath = CGMutablePath()
        barPath.move(to: CGPoint(x: barX, y: barY))
        barPath.addLine(to: CGPoint(x: barX + barWidth, y: barY))
        node.barTrack.path = barPath
        node.barFill.path = barPath
        node.barTrack.lineWidth = m.compact ? 3 : 4
        node.barFill.lineWidth = m.compact ? 3 : 4
        node.barTrack.isHidden = false
        node.barFill.isHidden = false

        let separatorPath = CGMutablePath()
        separatorPath.move(to: CGPoint(x: titleX, y: 0.5))
        separatorPath.addLine(to: CGPoint(x: r.width, y: 0.5))
        node.separator.path = separatorPath
        node.separator.isHidden = false
        node.stateDot.frame = .zero
    }

    private func layoutEdges() {
        guard let adapter = node("Адаптер"), let system = node("Система") else { return }

        let adapterStart = CGPoint(x: adapter.rect.maxX + 2, y: adapter.rect.midY)
        let adapterEnd = CGPoint(x: system.rect.minX - 2, y: system.rect.midY)
        setEdgeGeometry(adapterEdge, start: adapterStart, end: adapterEnd,
                        forward: true, arrowVisible: snapshot.plugged)

        if hasBattery, let battery = node("Батарея") {
            let batteryStart = CGPoint(x: system.rect.maxX + 2, y: system.rect.midY)
            let batteryEnd = CGPoint(x: battery.rect.minX - 2, y: battery.rect.midY)
            let charging = snapshot.battFlow == .charging
            let idle = snapshot.battFlow == .idle
            setEdgeGeometry(batteryEdge, start: batteryStart, end: batteryEnd,
                            forward: charging, arrowVisible: !idle)
            batteryEdge.line.isHidden = false
            batteryEdge.arrow.isHidden = idle
        } else {
            batteryEdge.line.isHidden = true
            batteryEdge.arrow.isHidden = true
        }
    }

    private func setEdgeGeometry(_ edge: EdgeUI,
                                 start: CGPoint,
                                 end: CGPoint,
                                 forward: Bool,
                                 arrowVisible: Bool) {
        edge.start = start
        edge.end = end

        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)
        edge.line.path = path

        let midpoint = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let direction: CGFloat = forward ? 1 : -1
        let size: CGFloat = 4.5
        let arrow = CGMutablePath()
        arrow.move(to: CGPoint(x: midpoint.x + direction * size, y: midpoint.y))
        arrow.addLine(to: CGPoint(x: midpoint.x - direction * size, y: midpoint.y + size * 0.72))
        arrow.addLine(to: CGPoint(x: midpoint.x - direction * size, y: midpoint.y - size * 0.72))
        arrow.closeSubpath()
        edge.arrow.path = arrow
        edge.arrow.isHidden = !arrowVisible
    }

    private func layoutAccessibilityViews() {
        for (index, node) in nodes.enumerated() where index < nodeViews.count {
            nodeViews[index].frame = node.rect
        }
    }

    // MARK: - Refresh

    private func refresh(animated: Bool) {
        guard layer != nil else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        refreshResolvedColors()
        refreshHeader(animated: animated)
        refreshTopologyNodes()
        refreshLoadNodes(animated: animated)
        refreshFooter()
        refreshEdges()
        refreshUSBText()
        refreshAccessibilityLabels()
        CATransaction.commit()

        restyle(animated: false)
    }

    private func refreshResolvedColors() {
        headerTitle.foregroundColor = resolvedColor(.secondaryLabelColor).cgColor
        headerValue.foregroundColor = resolvedColor(.labelColor).cgColor
        usbLayer.foregroundColor = resolvedColor(.tertiaryLabelColor).cgColor
        loadsTitle.foregroundColor = resolvedColor(.tertiaryLabelColor).cgColor
        headerDivider.strokeColor = separatorColor.cgColor

        for node in nodes {
            node.title.foregroundColor = resolvedColor(.secondaryLabelColor).cgColor
            node.auxiliary.foregroundColor = resolvedColor(.tertiaryLabelColor).cgColor
            node.separator.strokeColor = separatorColor.cgColor
            node.barTrack.strokeColor = trackColor.cgColor
        }
    }

    private func refreshHeader(animated: Bool) {
        headerTitle.string = L("СИСТЕМА ПИТАНИЯ")
        loadsTitle.string = L("НАГРУЗКА")

        let status = powerStatus()
        headerStatus.string = status.text
        headerStatus.foregroundColor = resolvedColor(status.textColor).cgColor
        headerStatusDot.fillColor = status.dotColor.cgColor

        let valueToken = String(format: "%.0f", snapshot.systemWatts)
        let oldToken = lastHeaderValueToken
        if oldToken != valueToken {
            lastHeaderValueToken = valueToken
            headerValue.string = systemValueAttributed(snapshot.systemWatts)
        }

        if animated,
           !Motion.reduced,
           !oldToken.isEmpty,
           oldToken != valueToken,
           abs(snapshot.loadDelta) > 0.5 {
            let animation = CAKeyframeAnimation(keyPath: "transform.scale")
            animation.values = [1.0, 1.025, 1.0]
            animation.keyTimes = [0, 0.45, 1]
            animation.duration = 0.22
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            headerValue.add(animation, forKey: "valueTick")
        }
    }

    private func refreshTopologyNodes() {
        if let adapter = node("Адаптер") {
            setText(adapter.title, node: adapter, token: L("Адаптер"), slot: \NodeUI.lastTitleToken)
            setText(adapter.value, node: adapter,
                    attributed: adapterValueAttributed(),
                    token: adapterValueToken())
            adapter.stateDot.fillColor = adapterStatusColor.cgColor
            updateSymbol(adapter, name: "powerplug.fill", color: adapterStatusColor, pointSize: 15)
        }

        if let system = node("Система") {
            setText(system.title, node: system, token: L("Система"), slot: \NodeUI.lastTitleToken)
            updateSymbol(system, name: "macbook", color: neutralIconColor, pointSize: 18)
        }

        if let battery = node("Батарея") {
            setText(battery.title, node: battery, token: L("Батарея"), slot: \NodeUI.lastTitleToken)
            setText(battery.value, node: battery,
                    attributed: batteryValueAttributed(),
                    token: batteryValueToken())
            let color = batteryStatusColor
            battery.stateDot.fillColor = color.cgColor
            let symbol = snapshot.battFlow == .charging ? "battery.100.bolt" : "battery.75"
            updateSymbol(battery, name: symbol, color: color, pointSize: 15)
        }
    }

    private func refreshLoadNodes(animated: Bool) {
        let rows = orderedRails
        let maxAmps = max(1.2, rows.map(\.amps).max() ?? 1.2)

        for node in nodes where node.kind == .load {
            guard let rail = rows.first(where: { $0.name == node.key }) else { continue }

            setText(node.title, node: node, token: L(node.key), slot: \NodeUI.lastTitleToken)
            updateSymbol(node,
                         name: symbolName(for: node.key),
                         color: neutralIconColor,
                         pointSize: 11)

            if let watts = componentWatts(for: node.key) ?? rail.watts {
                let value = String(format: L("%.1f Вт"), watts)
                setText(node.value, node: node, token: value, slot: \NodeUI.lastValueToken)

                let fraction = snapshot.systemWatts > 0.5
                    ? max(0, min(1, watts / snapshot.systemWatts))
                    : 0
                let percent = snapshot.systemWatts > 0.5
                    ? String(format: "%.0f%%", fraction * 100)
                    : "—"
                setText(node.auxiliary, node: node, token: percent, slot: \NodeUI.lastAuxiliaryToken)
                updateBar(node, fraction: fraction, animated: animated)
            } else {
                let value = String(format: L("%.2f А"), rail.amps)
                setText(node.value, node: node, token: value, slot: \NodeUI.lastValueToken)
                setText(node.auxiliary, node: node, token: "—", slot: \NodeUI.lastAuxiliaryToken)
                updateBar(node,
                          fraction: max(0, min(1, rail.amps / maxAmps)),
                          animated: animated)
            }

            let sleeping = rail.amps < 0.05
            node.value.foregroundColor = resolvedColor(
                sleeping ? .tertiaryLabelColor : .labelColor
            ).cgColor
            node.barFill.strokeColor = (sleeping ? neutralIconColor : accentColor).withAlphaComponent(sleeping ? 0.25 : 0.9).cgColor
            node.barTrack.strokeColor = trackColor.cgColor
            node.separator.strokeColor = separatorColor.cgColor
        }
    }

    private func refreshFooter() {
        footerText.string = balanceLine()
        footerText.foregroundColor = resolvedColor(footerColor).cgColor
    }

    private func refreshEdges() {
        let adapterAmps = measuredAdapterAmps()
        adapterEdge.line.lineWidth = flowLineWidth(adapterAmps)
        adapterEdge.line.strokeColor = (snapshot.plugged ? adapterStatusColor : disabledColor)
            .withAlphaComponent(snapshot.plugged ? 0.72 : 0.35).cgColor
        adapterEdge.line.lineDashPattern = snapshot.plugged ? nil : [3, 3]
        adapterEdge.arrow.fillColor = adapterStatusColor.cgColor
        adapterEdge.arrow.isHidden = !snapshot.plugged

        if hasBattery {
            let batteryAmps = abs(snapshot.battAmps)
            batteryEdge.line.lineWidth = flowLineWidth(batteryAmps)
            batteryEdge.line.strokeColor = batteryStatusColor
                .withAlphaComponent(snapshot.battFlow == .idle ? 0.30 : 0.72).cgColor
            batteryEdge.line.lineDashPattern = snapshot.battFlow == .idle ? [3, 3] : nil
            batteryEdge.arrow.fillColor = batteryStatusColor.cgColor
            batteryEdge.arrow.isHidden = snapshot.battFlow == .idle
        }

        layoutEdges()
    }

    private func refreshUSBText() {
        usbLayer.isHidden = usbCount <= 0 || bounds.width < 330
        guard usbCount > 0 else { return }
        usbLayer.string = String(format: L("USB: %d"), usbCount)
    }

    private func refreshAccessibilityLabels() {
        for view in nodeViews {
            view.axLabel = detailLine(for: view.key)
        }
    }

    // MARK: - Styling and interaction

    private func restyle(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration((animated && !Motion.reduced) ? 0.16 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))

        for node in nodes {
            let hovered = node.key == hoveredKey
            let focused = node.key == focusedKey
            let related = focusedKey == nil || node.key == focusedKey || node.kind == .system

            node.container.opacity = related ? 1 : (node.kind == .load ? 0.48 : 0.72)
            node.container.backgroundColor = nodeBackground(node, hovered: hovered, focused: focused).cgColor
            node.container.borderWidth = (hovered || focused) ? 1 : (node.kind == .load ? 0 : 0.5)
            node.container.borderColor = (hovered || focused ? accentColor : separatorColor).cgColor

            if node.kind == .load {
                node.container.transform = CATransform3DIdentity
            } else {
                node.container.transform = CATransform3DMakeScale(hovered ? 1.018 : 1,
                                                                  hovered ? 1.018 : 1,
                                                                  1)
            }
        }

        let adapterActive = hoveredKey == "Адаптер" || focusedKey == "Адаптер"
        adapterEdge.line.opacity = adapterActive ? 1 : 0.82
        adapterEdge.arrow.opacity = adapterActive ? 1 : 0.88

        let batteryActive = hoveredKey == "Батарея" || focusedKey == "Батарея"
        batteryEdge.line.opacity = batteryActive ? 1 : 0.82
        batteryEdge.arrow.opacity = batteryActive ? 1 : 0.88

        CATransaction.commit()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = nodes.first(where: { $0.rect.contains(point) })?.key
        guard hit != hoveredKey else { return }
        hoveredKey = hit
        restyle(animated: true)
        emitDetail()
    }

    override func mouseExited(with event: NSEvent) {
        guard hoveredKey != nil else { return }
        hoveredKey = nil
        restyle(animated: true)
        emitDetail()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let key = nodes.first(where: { $0.rect.contains(point) })?.key else {
            focusedKey = nil
            restyle(animated: true)
            emitDetail()
            return
        }
        focusNode(key)
    }

    private func emitDetail() {
        let key = hoveredKey ?? focusedKey
        detailSink?(key.map { detailLine(for: $0) })
    }

    // MARK: - Event animations

    private func animateAdapterEvent(connected: Bool) {
        pulseObod(connect: connected)

        if connected {
            animateTravel(on: adapterEdge,
                          color: adapterStatusColor,
                          forward: true,
                          duration: 0.42)
        } else if !Motion.reduced {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0.35
            fade.duration = 0.26
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            adapterEdge.line.add(fade, forKey: "disconnect")
        }
    }

    private func animateBatteryDirectionChange() {
        guard hasBattery, snapshot.battFlow != .idle else { return }
        animateTravel(on: batteryEdge,
                      color: batteryStatusColor,
                      forward: snapshot.battFlow == .charging,
                      duration: 0.40)
    }

    private func animateTravel(on edge: EdgeUI,
                               color: NSColor,
                               forward: Bool,
                               duration: CFTimeInterval) {
        guard !Motion.reduced, let root = layer else { return }

        let pulseLayer = CAShapeLayer()
        let path = CGMutablePath()
        let start = forward ? edge.start : edge.end
        let end = forward ? edge.end : edge.start
        path.move(to: start)
        path.addLine(to: end)

        pulseLayer.path = path
        pulseLayer.fillColor = nil
        pulseLayer.strokeColor = color.withAlphaComponent(0.95).cgColor
        pulseLayer.lineWidth = max(2.5, edge.line.lineWidth + 1)
        pulseLayer.lineCap = .round
        pulseLayer.strokeStart = 0
        pulseLayer.strokeEnd = 0.18
        root.addSublayer(pulseLayer)

        let startAnimation = CABasicAnimation(keyPath: "strokeStart")
        startAnimation.fromValue = 0
        startAnimation.toValue = 0.82

        let endAnimation = CABasicAnimation(keyPath: "strokeEnd")
        endAnimation.fromValue = 0.18
        endAnimation.toValue = 1

        let group = CAAnimationGroup()
        group.animations = [startAnimation, endAnimation]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = true

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak pulseLayer] in
            pulseLayer?.removeFromSuperlayer()
        }
        pulseLayer.add(group, forKey: "travel")
        CATransaction.commit()
    }

    private func pulse(layer: CALayer, scale: CGFloat, duration: CFTimeInterval) {
        guard !Motion.reduced else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1.0, scale, 1.0]
        animation.keyTimes = [0, 0.5, 1]
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "eventPulse")
    }

    // MARK: - Text and engineering semantics

    private struct PowerStatusPresentation {
        let text: String
        let dotColor: NSColor
        let textColor: NSColor
    }

    private func powerStatus() -> PowerStatusPresentation {
        if !snapshot.plugged {
            if hasBattery {
                return .init(text: L("Работа от батареи"),
                             dotColor: batteryStatusColor,
                             textColor: .secondaryLabelColor)
            }
            return .init(text: L("Внешнее питание не обнаружено"),
                         dotColor: .systemOrange,
                         textColor: isDark ? .systemOrange : darker(.systemOrange))
        }

        if let rated = snapshot.adapterRatedWatts,
           Double(rated) > 0,
           snapshot.adapterWatts / Double(rated) >= 0.90,
           snapshot.battFlow != .discharging {
            return .init(text: L("Адаптер почти на пределе"),
                         dotColor: .systemOrange,
                         textColor: isDark ? .systemOrange : darker(.systemOrange))
        }

        switch snapshot.battFlow {
        case .discharging:
            return .init(text: L("Адаптер не покрывает нагрузку"),
                         dotColor: .systemOrange,
                         textColor: isDark ? .systemOrange : darker(.systemOrange))
        case .charging:
            return .init(text: L("Питание стабильно · батарея заряжается"),
                         dotColor: .systemGreen,
                         textColor: .secondaryLabelColor)
        case .idle:
            return .init(text: L("Питание стабильно"),
                         dotColor: .systemGreen,
                         textColor: .secondaryLabelColor)
        }
    }

    private func balanceLine() -> String {
        if snapshot.plugged {
            var line = String(format: L("Вход %.0f Вт · Расход %.0f Вт"),
                              snapshot.adapterWatts,
                              snapshot.systemWatts)
            if hasBattery {
                line += " · " + L("АКБ") + " " + netLabel()
            }
            if let gap = measurementGap() {
                line += " · " + String(format: L("Δ замеров %.0f Вт"), gap)
            }
            return line
        }

        if hasBattery {
            return String(format: L("Расход %.0f Вт · АКБ %@"),
                          snapshot.systemWatts,
                          netLabel())
        }
        return String(format: L("Расход %.0f Вт"), snapshot.systemWatts)
    }

    private func adapterValueToken() -> String {
        if !snapshot.plugged { return "offline" }
        if let rated = snapshot.adapterRatedWatts {
            return "\(Int(snapshot.adapterWatts.rounded()))/\(rated)"
        }
        return "\(Int(snapshot.adapterWatts.rounded()))"
    }

    private func adapterValueAttributed() -> NSAttributedString {
        guard snapshot.plugged else {
            return NSAttributedString(string: "—", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: resolvedColor(.tertiaryLabelColor)
            ])
        }

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: String(format: "%.0f", snapshot.adapterWatts),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: resolvedColor(.labelColor)
            ]
        ))

        if let rated = snapshot.adapterRatedWatts {
            result.append(NSAttributedString(
                string: String(format: L(" / %d Вт"), rated),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .regular),
                    .foregroundColor: resolvedColor(.tertiaryLabelColor)
                ]
            ))
        } else {
            result.append(NSAttributedString(
                string: " " + L("Вт"),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .regular),
                    .foregroundColor: resolvedColor(.tertiaryLabelColor)
                ]
            ))
        }
        return result
    }

    private func batteryValueToken() -> String {
        "\(batteryFlowTag(snapshot.battFlow)):\(Int(snapshot.battWatts.rounded()))"
    }

    private func batteryValueAttributed() -> NSAttributedString {
        let signed = netWatts()
        let number: String
        if abs(signed) < 0.5 {
            number = "0"
        } else {
            number = (signed > 0 ? "+" : "−") + String(format: "%.0f", abs(signed))
        }

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: number,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: snapshot.battFlow == .idle
                    ? resolvedColor(.tertiaryLabelColor)
                    : resolvedColor(.labelColor)
            ]
        ))
        result.append(NSAttributedString(
            string: " " + L("Вт") + " · " + batteryFlowWord(snapshot.battFlow),
            attributes: [
                .font: NSFont.systemFont(ofSize: 8.5, weight: .regular),
                .foregroundColor: resolvedColor(.tertiaryLabelColor)
            ]
        ))
        return result
    }

    private func systemValueAttributed(_ watts: Double) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: String(format: "%.0f", watts),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 23, weight: .semibold),
                .foregroundColor: resolvedColor(.labelColor)
            ]
        ))
        result.append(NSAttributedString(
            string: " " + L("Вт"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .regular),
                .foregroundColor: resolvedColor(.tertiaryLabelColor)
            ]
        ))
        return result
    }

    private func setText(_ layer: CATextLayer,
                         node: NodeUI,
                         token: String,
                         slot: ReferenceWritableKeyPath<NodeUI, String>) {
        guard node[keyPath: slot] != token else { return }
        node[keyPath: slot] = token
        layer.string = token
    }

    private func setText(_ layer: CATextLayer,
                         node: NodeUI,
                         attributed: NSAttributedString,
                         token: String) {
        guard node.lastValueToken != token else { return }
        node.lastValueToken = token
        layer.string = attributed
    }

    private func updateBar(_ node: NodeUI, fraction: Double, animated: Bool) {
        let target = max(0, min(1, fraction))
        if node.appliedBarFraction.isNaN || Motion.reduced || !animated {
            node.barFill.strokeEnd = CGFloat(target)
            node.appliedBarFraction = target
            return
        }
        guard abs(target - node.appliedBarFraction) >= 0.004 else { return }

        let from = node.barFill.presentation()?.strokeEnd ?? node.barFill.strokeEnd
        node.barFill.strokeEnd = CGFloat(target)
        node.appliedBarFraction = target

        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = from
        animation.toValue = target
        animation.duration = 0.28
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        node.barFill.add(animation, forKey: "value")
    }

    // MARK: - Detail and tooltips

    private func detailLine(for key: String) -> String {
        switch key {
        case "Адаптер":
            return snapshot.plugged ? adapterDetail() : L("Адаптер не подключён")

        case "Система":
            var text = balanceLine()
            if usbCount > 0 {
                text += " · " + String(format: L("USB-устройства: %d"), usbCount)
            }
            return text

        case "Батарея":
            return String(format: L("Батарея · %.1f В · %.2f А · %.0f Вт · %@"),
                          snapshot.battVolts,
                          abs(snapshot.battAmps),
                          snapshot.battWatts,
                          batteryFlowWord(snapshot.battFlow))

        default:
            guard let rail = snapshot.rails.first(where: { $0.name == key }) else { return L(key) }
            if let watts = componentWatts(for: key) ?? rail.watts {
                let percent = snapshot.systemWatts > 0.5 ? watts / snapshot.systemWatts * 100 : 0
                return String(format: L("%@ · %.2f А · %.1f Вт · %.0f%% системы"),
                              L(key), rail.amps, watts, percent)
            }
            return String(format: L("%@ · %.2f А"), L(key), rail.amps)
        }
    }

    private func adapterDetail() -> String {
        if let rated = snapshot.adapterRatedWatts {
            let reserve = max(0, Double(rated) - snapshot.adapterWatts)
            return String(format: L("Адаптер %d Вт · отдаёт %.0f Вт · запас %.0f Вт"),
                          rated,
                          snapshot.adapterWatts,
                          reserve)
        }
        return String(format: L("Адаптер · %.0f В · %.1f А · %.0f Вт"),
                      snapshot.adapterVolts,
                      snapshot.adapterAmps,
                      snapshot.adapterWatts)
    }

    func view(_ view: NSView,
              stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint,
              userData data: UnsafeMutableRawPointer?) -> String {
        guard let key = nodes.first(where: { $0.rect.contains(point) })?.key else { return "" }
        var text = detailLine(for: key)
        if key == "Система", let usbFirstName, usbCount > 0 {
            text += "\n" + String(format: L("Первое USB-устройство: %@"), usbFirstName)
        }
        return text
    }

    private func rebuildToolTips() {
        removeAllToolTips()
        for node in nodes where !node.rect.isEmpty {
            addToolTip(node.rect, owner: self, userData: nil)
        }
    }

    // MARK: - Data helpers

    private func componentWatts(for key: String) -> Double? {
        guard let components, components.fresh else { return nil }
        switch key {
        case "CPU": return components.cpu
        case "GPU": return components.gpu
        case "Память": return components.dram
        default: return nil
        }
    }

    private func netWatts() -> Double {
        switch snapshot.battFlow {
        case .charging: return snapshot.battWatts
        case .discharging: return -snapshot.battWatts
        case .idle: return 0
        }
    }

    private func netLabel() -> String {
        let watts = netWatts()
        if abs(watts) < 0.5 { return String(format: L("%.0f Вт"), 0.0) }
        let sign = watts > 0 ? "+" : "−"
        return sign + String(format: L("%.0f Вт"), abs(watts))
    }

    private func measurementGap() -> Double? {
        guard snapshot.plugged, snapshot.battFlow != .discharging else { return nil }
        let gap = snapshot.systemWatts - snapshot.adapterWatts
        return gap > 1 ? gap : nil
    }

    private func measuredAdapterAmps() -> Double {
        let volts = snapshot.adapterVolts > 5 ? snapshot.adapterVolts : 20
        return snapshot.adapterWatts > 0.5 ? snapshot.adapterWatts / volts : 0
    }

    private func flowLineWidth(_ amps: Double) -> CGFloat {
        amps < 0.05 ? 1 : min(3.4, 1.5 + CGFloat(amps) * 0.72)
    }

    private func batteryFlowTag(_ flow: BatteryFlow) -> String {
        switch flow {
        case .charging: return "charging"
        case .discharging: return "discharging"
        case .idle: return "idle"
        }
    }

    private func batteryFlowWord(_ flow: BatteryFlow) -> String {
        switch flow {
        case .charging: return L("заряд")
        case .discharging: return L("разряд")
        case .idle: return L("равновесие")
        }
    }

    private func symbolName(for key: String) -> String {
        switch key {
        case "CPU": return "cpu.fill"
        case "GPU": return "cpu"
        case "Память": return "memorychip.fill"
        default: return "ellipsis.circle.fill"
        }
    }

    private func node(_ key: String) -> NodeUI? {
        nodes.first { $0.key == key }
    }

    // MARK: - Colors

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func resolvedColor(_ color: NSColor) -> NSColor {
        Design.Color.resolved(color, dark: isDark)
    }

    private var accentColor: NSColor {
        Design.Color.accent(isDark)
    }

    private var neutralIconColor: NSColor {
        Design.Color.neutralNode(isDark)
    }

    private var trackColor: NSColor {
        isDark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.09)
    }

    private var separatorColor: NSColor {
        isDark ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.085)
    }

    private var disabledColor: NSColor {
        isDark ? NSColor(white: 0.55, alpha: 1) : NSColor(white: 0.48, alpha: 1)
    }

    private var adapterStatusColor: NSColor {
        guard snapshot.plugged else { return disabledColor }
        return isDark ? .systemOrange : darker(.systemOrange)
    }

    private var batteryStatusColor: NSColor {
        let color: NSColor
        switch snapshot.battFlow {
        case .charging: color = .systemTeal
        case .discharging: color = .systemGreen
        case .idle: color = disabledColor
        }
        return isDark ? color : darker(color)
    }

    private var footerColor: NSColor {
        snapshot.plugged && snapshot.battFlow == .discharging
            ? (isDark ? .systemOrange : darker(.systemOrange))
            : .secondaryLabelColor
    }

    private func nodeBackground(_ node: NodeUI, hovered: Bool, focused: Bool) -> NSColor {
        if hovered || focused {
            return accentColor.withAlphaComponent(isDark ? 0.12 : 0.08)
        }
        if node.kind == .load {
            return .clear
        }
        return isDark
            ? NSColor(white: 1, alpha: 0.045)
            : NSColor(white: 0, alpha: 0.028)
    }

    private func darker(_ color: NSColor) -> NSColor {
        color.blended(withFraction: 0.22, of: .black) ?? color
    }

    private func invalidatePresentationTokens() {
        lastHeaderValueToken = ""
        for node in nodes {
            node.lastValueToken = ""
            node.lastTitleToken = ""
            node.lastAuxiliaryToken = ""
            node.lastSymbolToken = ""
        }
    }

    // MARK: - Symbols and scale

    private struct SymbolKey: Hashable {
        let name: String
        let pointSize: Int
        let color: String
    }

    private var symbolCache: [SymbolKey: CGImage] = [:]

    private func updateSymbol(_ node: NodeUI,
                              name: String,
                              color: NSColor,
                              pointSize: CGFloat) {
        let colorToken = colorCacheToken(color)
        let token = "\(name)|\(Int(pointSize.rounded()))|\(colorToken)"
        guard node.lastSymbolToken != token else { return }
        node.lastSymbolToken = token
        node.icon.contents = cachedSymbol(name: name, color: color, pointSize: pointSize)
    }

    private func cachedSymbol(name: String,
                              color: NSColor,
                              pointSize: CGFloat) -> CGImage? {
        let key = SymbolKey(name: name,
                            pointSize: Int(pointSize.rounded()),
                            color: colorCacheToken(color))
        if let image = symbolCache[key] { return image }

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
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        symbolCache[key] = cgImage
        return cgImage
    }

    private func colorCacheToken(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return color.description }
        return String(format: "%.3f,%.3f,%.3f,%.3f",
                      rgb.redComponent,
                      rgb.greenComponent,
                      rgb.blueComponent,
                      rgb.alphaComponent)
    }

    private func configureText(_ layer: CATextLayer,
                               size: CGFloat,
                               weight: NSFont.Weight,
                               color: NSColor,
                               mono: Bool = false) {
        let font = mono
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        layer.font = font
        layer.fontSize = size
        layer.foregroundColor = resolvedColor(color).cgColor
        layer.truncationMode = .end
        layer.isWrapped = false
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2

        for text in [headerTitle, headerStatus, headerValue, usbLayer, loadsTitle, footerText] {
            text.contentsScale = scale
        }
        adapterEdge.line.contentsScale = scale
        adapterEdge.arrow.contentsScale = scale
        batteryEdge.line.contentsScale = scale
        batteryEdge.arrow.contentsScale = scale

        for node in nodes { updateContentsScale(node) }
    }

    private func updateContentsScale(_ node: NodeUI) {
        let scale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        node.container.contentsScale = scale
        node.icon.contentsScale = scale
        node.title.contentsScale = scale
        node.value.contentsScale = scale
        node.auxiliary.contentsScale = scale
        node.stateDot.contentsScale = scale
        node.barTrack.contentsScale = scale
        node.barFill.contentsScale = scale
        node.separator.contentsScale = scale
    }
}

/// Прозрачный оверлей: клавиатура и VoiceOver используют те же узлы, что мышь.
/// Мышь проходит к FlowView, поэтому визуальный hit-test остаётся единым.
private final class FlowNodeView: NSView {
    let key: String
    var axLabel = ""
    var onActivate: ((String) -> Void)?

    init(key: String) {
        self.key = key
        super.init(frame: .zero)
        focusRingType = .default
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 {
            onActivate?(key)
        } else {
            super.keyDown(with: event)
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                     xRadius: 7,
                     yRadius: 7).fill()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { axLabel }

    override func accessibilityPerformPress() -> Bool {
        onActivate?(key)
        return true
    }
}
