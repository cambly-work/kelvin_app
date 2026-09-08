import AppKit

/// Инженерный график реальной истории.
///
/// Основные правила:
/// - рисуются только фактически снятые точки;
/// - пропуски длиннее `gapSeconds` разрывают линию;
/// - большие ряды прореживаются min/max-бакетами с сохранением реальных экстремумов;
/// - статическая часть графика кэшируется, поэтому движение scrub-кроссхейра не пересчитывает историю;
/// - поиск ближайшего сэмпла выполняется бинарно;
/// - клик фиксирует точку, ←/→ перемещают фиксацию, Escape снимает её.
///
/// Внешний API предыдущей версии сохранён.
final class HistoryChart: NSView {

    /// История снимается примерно раз в минуту. Интервал > 150 секунд означает,
    /// что между точками данных не было: сон, закрытый popover или остановка сбора.
    static let gapSeconds: Double = 150

    // MARK: - Internal models

    private struct Sample {
        let x: Double
        let y: Double
    }

    private struct Axis {
        let min: Double
        let max: Double
        let ticks: [Double]

        var span: Double { Swift.max(max - min, 1e-9) }
    }

    private struct PlotModel {
        let bounds: CGRect
        let plotRect: CGRect
        let axis: Axis
        let minX: Double
        let maxX: Double
        let segments: [Range<Int>]
        let renderedSegments: [[Sample]]
        let yLabels: [String]
        let startLabel: String
        let endLabel: String

        var spanX: Double { Swift.max(maxX - minX, 1e-9) }

        func xPosition(_ x: Double) -> CGFloat {
            plotRect.minX + CGFloat((x - minX) / spanX) * plotRect.width
        }

        func yPosition(_ y: Double) -> CGFloat {
            let clamped = min(max(y, axis.min), axis.max)
            return plotRect.minY + CGFloat((clamped - axis.min) / axis.span) * plotRect.height
        }

        func dataX(for viewX: CGFloat) -> Double {
            let f = min(max((viewX - plotRect.minX) / max(plotRect.width, 1), 0), 1)
            return minX + Double(f) * spanX
        }
    }

    private struct StaticCacheKey: Equatable {
        let widthPixels: Int
        let heightPixels: Int
        let sampleRevision: UInt64
        let styleRevision: UInt64
        let appearanceName: String
        let locale: String
    }

    // MARK: - Data

    private var samples: [Sample] = []
    private var lineColor: NSColor = .systemTeal
    private var unit = ""
    private var emptyText = ""
    private var yCap: Double?
    private var yFloor: Double?

    private var sampleRevision: UInt64 = 0
    private var styleRevision: UInt64 = 0

    // MARK: - Cached rendering

    private var plotModel: PlotModel?
    private var staticImage: NSImage?
    private var staticCacheKey: StaticCacheKey?

    // MARK: - Scrub state

    private var hoverX: CGFloat?
    private var pinnedTimestamp: Double?
    private var trackingAreaRef: NSTrackingArea?

    // MARK: - Formatters

    private var formatterLocale = ""
    private var scrubDateFormatter: DateFormatter?
    private var axisDateFormatters: [String: DateFormatter] = [:]
    private var numberFormatterCache: [Int: NumberFormatter] = [:]

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
        focusRingType = .default
    }

    override var isFlipped: Bool { false }

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 128)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        invalidateStaticCache()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidateStaticCache()
    }

    override func layout() {
        super.layout()
        if plotModel?.bounds.size != bounds.size {
            invalidateStaticCache()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: - Public API

    /// Заменяет набор точек и оформление графика.
    ///
    /// Перед сохранением точки:
    /// - фильтруются от NaN/∞;
    /// - сортируются по времени;
    /// - одинаковые timestamp схлопываются, остаётся последнее значение.
    ///
    /// Если данные и оформление не изменились, перерисовка не запускается.
    func set(
        points: [(x: Double, y: Double)],
        color: NSColor,
        unit: String,
        yCap: Double? = nil,
        yFloor: Double? = nil,
        empty: String
    ) {
        let normalized = Self.normalize(points)
        let dataChanged = !Self.sameSamples(samples, normalized)
        let styleChanged =
            !lineColor.isEqual(color)
            || self.unit != unit
            || self.yCap != yCap
            || self.yFloor != yFloor
            || emptyText != empty

        guard dataChanged || styleChanged else { return }

        let pinned = pinnedTimestamp

        samples = normalized
        lineColor = color
        self.unit = unit
        self.yCap = yCap
        self.yFloor = yFloor
        emptyText = empty

        if dataChanged {
            sampleRevision &+= 1
            if let pinned, !samples.contains(where: { $0.x == pinned }) {
                pinnedTimestamp = nil
            }
        }
        if styleChanged {
            styleRevision &+= 1
        }

        invalidateStaticCache()
        updateAccessibility()
    }

    // MARK: - Tracking and interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .activeInActiveApp,
                .mouseMoved,
                .mouseEnteredAndExited,
                .inVisibleRect
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard hoverX != nil else { return }
        hoverX = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        updateHover(with: event)

        guard let model = currentPlotModel(),
              let index = scrubIndex(in: model, at: hoverX)
        else {
            pinnedTimestamp = nil
            needsDisplay = true
            return
        }

        let timestamp = samples[index].x
        pinnedTimestamp = pinnedTimestamp == timestamp ? nil : timestamp
        needsDisplay = true
        updateAccessibility()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Escape
            pinnedTimestamp = nil
            hoverX = nil
            needsDisplay = true
            updateAccessibility()

        case 123: // Left
            movePinnedSelection(by: -1)

        case 124: // Right
            movePinnedSelection(by: 1)

        case 49, 36: // Space / Return
            if let model = currentPlotModel(),
               let index = scrubIndex(in: model, at: hoverX) {
                let timestamp = samples[index].x
                pinnedTimestamp = pinnedTimestamp == timestamp ? nil : timestamp
                needsDisplay = true
                updateAccessibility()
            }

        default:
            super.keyDown(with: event)
        }
    }

    private func updateHover(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard hoverX != point.x else { return }
        hoverX = point.x
        needsDisplay = true
    }

    private func movePinnedSelection(by delta: Int) {
        guard !samples.isEmpty else { return }

        let currentIndex: Int
        if let pinnedTimestamp,
           let index = Self.binarySearchExact(samples, x: pinnedTimestamp) {
            currentIndex = index
        } else if let model = currentPlotModel(),
                  let index = scrubIndex(in: model, at: hoverX) {
            currentIndex = index
        } else {
            currentIndex = delta > 0 ? -1 : samples.count
        }

        let target = min(max(currentIndex + delta, 0), samples.count - 1)
        pinnedTimestamp = samples[target].x
        hoverX = nil
        needsDisplay = true
        updateAccessibility()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard bounds.width > 8, bounds.height > 8 else { return }

        let locale = I18n.current.rawValue
        refreshFormattersIfNeeded(locale: locale)

        let image = cachedStaticImage(locale: locale)
        image.draw(
            in: bounds,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )

        guard let model = plotModel else { return }
        drawScrubOverlay(in: model)
    }

    private func cachedStaticImage(locale: String) -> NSImage {
        let scale = backingScale
        let key = StaticCacheKey(
            widthPixels: max(1, Int((bounds.width * scale).rounded(.up))),
            heightPixels: max(1, Int((bounds.height * scale).rounded(.up))),
            sampleRevision: sampleRevision,
            styleRevision: styleRevision,
            appearanceName: effectiveAppearance.name.rawValue,
            locale: locale
        )

        if staticCacheKey == key, let staticImage {
            return staticImage
        }

        let model = makePlotModel()
        plotModel = model

        let image = renderStaticImage(model: model, scale: scale)
        staticImage = image
        staticCacheKey = key
        return image
    }

    private func renderStaticImage(model: PlotModel?, scale: CGFloat) -> NSImage {
        let pixelWidth = max(1, Int((bounds.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((bounds.height * scale).rounded(.up)))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: bounds.size)
        }

        rep.size = bounds.size

        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return image
        }

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.current = previous }

        NSColor.clear.setFill()
        NSBezierPath(rect: bounds).fill()

        if let model {
            drawStaticPlot(model)
        } else {
            drawEmptyState()
        }

        context.flushGraphics()

        return image
    }

    private func drawStaticPlot(_ model: PlotModel) {
        drawGridAndAxes(model)
        drawSegments(model)
        drawAxisLabels(model)
    }

    private func drawEmptyState() {
        let area = bounds.insetBy(dx: 12, dy: 12)
        let text = emptyText.isEmpty ? L("Накопление данных") : emptyText
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let size = attributed.size()
        let point = NSPoint(
            x: area.midX - size.width / 2,
            y: area.midY - size.height / 2
        )
        attributed.draw(at: point)

        if samples.count == 1, let sample = samples.first {
            let secondary = valueString(sample.y, axisSpan: 1) + unit
            let secondaryAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let s = NSAttributedString(string: secondary, attributes: secondaryAttrs)
            let ss = s.size()
            s.draw(at: NSPoint(x: area.midX - ss.width / 2, y: point.y - 17))
        }
    }

    private func drawGridAndAxes(_ model: PlotModel) {
        let scale = backingScale
        let hairline = max(1 / scale, 0.5)

        let gridColor = NSColor.separatorColor.withAlphaComponent(isDark ? 0.24 : 0.30)
        gridColor.setStroke()

        for tick in model.axis.ticks {
            let y = aligned(model.yPosition(tick), scale: scale)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: model.plotRect.minX, y: y))
            line.line(to: NSPoint(x: model.plotRect.maxX, y: y))
            line.lineWidth = hairline
            line.stroke()
        }

        let vertical = NSColor.separatorColor.withAlphaComponent(isDark ? 0.10 : 0.14)
        vertical.setStroke()
        for fraction in [0.0, 0.5, 1.0] as [CGFloat] {
            let x = aligned(model.plotRect.minX + model.plotRect.width * fraction, scale: scale)
            let line = NSBezierPath()
            line.move(to: NSPoint(x: x, y: model.plotRect.minY))
            line.line(to: NSPoint(x: x, y: model.plotRect.maxY))
            line.lineWidth = hairline
            line.stroke()
        }
    }

    private func drawSegments(_ model: PlotModel) {
        for segment in model.renderedSegments {
            guard let first = segment.first else { continue }

            if segment.count == 1 {
                let x = model.xPosition(first.x)
                let y = model.yPosition(first.y)
                let dot = NSBezierPath(
                    ovalIn: NSRect(x: x - 1.75, y: y - 1.75, width: 3.5, height: 3.5)
                )
                lineColor.setFill()
                dot.fill()
                continue
            }

            let line = NSBezierPath()
            line.move(to: NSPoint(
                x: model.xPosition(first.x),
                y: model.yPosition(first.y)
            ))

            for sample in segment.dropFirst() {
                line.line(to: NSPoint(
                    x: model.xPosition(sample.x),
                    y: model.yPosition(sample.y)
                ))
            }

            guard let fill = line.copy() as? NSBezierPath else { continue }
            if let last = segment.last {
                fill.line(to: NSPoint(
                    x: model.xPosition(last.x),
                    y: model.plotRect.minY
                ))
                fill.line(to: NSPoint(
                    x: model.xPosition(first.x),
                    y: model.plotRect.minY
                ))
                fill.close()
            }

            NSGraphicsContext.saveGraphicsState()
            fill.addClip()
            let gradient = NSGradient(
                starting: lineColor.withAlphaComponent(isDark ? 0.18 : 0.14),
                ending: lineColor.withAlphaComponent(0.015)
            )
            gradient?.draw(in: model.plotRect, angle: -90)
            NSGraphicsContext.restoreGraphicsState()

            lineColor.setStroke()
            line.lineWidth = 1.5
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            line.stroke()
        }
    }

    private func drawAxisLabels(_ model: PlotModel) {
        let yFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let xFont = NSFont.systemFont(ofSize: 9, weight: .regular)

        let yAttrs: [NSAttributedString.Key: Any] = [
            .font: yFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let xAttrs: [NSAttributedString.Key: Any] = [
            .font: xFont,
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        for (index, tick) in model.axis.ticks.enumerated() {
            let label = model.yLabels[index] as NSString
            let size = label.size(withAttributes: yAttrs)
            let rawY = model.yPosition(tick) - size.height / 2
            let y = min(max(rawY, model.plotRect.minY - 1), model.plotRect.maxY - size.height + 1)
            label.draw(
                at: NSPoint(
                    x: model.plotRect.minX - size.width - 7,
                    y: y
                ),
                withAttributes: yAttrs
            )
        }

        let start = model.startLabel as NSString
        let end = model.endLabel as NSString
        let endSize = end.size(withAttributes: xAttrs)
        let y = max(1, model.plotRect.minY - 16)

        start.draw(
            at: NSPoint(x: model.plotRect.minX, y: y),
            withAttributes: xAttrs
        )
        end.draw(
            at: NSPoint(x: model.plotRect.maxX - endSize.width, y: y),
            withAttributes: xAttrs
        )

    }

    private func drawScrubOverlay(in model: PlotModel) {
        let index: Int?

        if let hoverIndex = scrubIndex(in: model, at: hoverX) {
            index = hoverIndex
        } else if let pinnedTimestamp {
            index = Self.binarySearchExact(samples, x: pinnedTimestamp)
        } else {
            index = nil
        }

        guard let index else { return }

        let sample = samples[index]
        let x = model.xPosition(sample.x)
        let y = model.yPosition(sample.y)
        let scale = backingScale

        let guideColor = NSColor.secondaryLabelColor.withAlphaComponent(isDark ? 0.50 : 0.38)
        guideColor.setStroke()

        let vertical = NSBezierPath()
        vertical.move(to: NSPoint(x: aligned(x, scale: scale), y: model.plotRect.minY))
        vertical.line(to: NSPoint(x: aligned(x, scale: scale), y: model.plotRect.maxY))
        vertical.lineWidth = max(1 / scale, 0.5)
        vertical.stroke()

        let horizontal = NSBezierPath()
        horizontal.move(to: NSPoint(x: model.plotRect.minX, y: aligned(y, scale: scale)))
        horizontal.line(to: NSPoint(x: model.plotRect.maxX, y: aligned(y, scale: scale)))
        horizontal.lineWidth = max(1 / scale, 0.5)
        horizontal.setLineDash([2, 3], count: 2, phase: 0)
        horizontal.stroke()

        let outer = NSBezierPath(
            ovalIn: NSRect(x: x - 4, y: y - 4, width: 8, height: 8)
        )
        NSColor.windowBackgroundColor.setFill()
        outer.fill()

        let dot = NSBezierPath(
            ovalIn: NSRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)
        )
        lineColor.setFill()
        dot.fill()

        drawScrubBubble(sample: sample, point: NSPoint(x: x, y: y), model: model)
    }

    private func drawScrubBubble(sample: Sample, point: NSPoint, model: PlotModel) {
        let value = valueString(sample.y, axisSpan: model.axis.span) + unit
        let date = scrubFormatter().string(
            from: Date(timeIntervalSince1970: sample.x)
        )
        let text = "\(value)  ·  \(date)"
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
        )

        let textSize = attributed.size()
        let horizontalPadding: CGFloat = 7
        let verticalPadding: CGFloat = 4
        let bubbleSize = NSSize(
            width: textSize.width + horizontalPadding * 2,
            height: textSize.height + verticalPadding * 2
        )

        var x = point.x - bubbleSize.width / 2
        x = min(max(x, model.plotRect.minX), model.plotRect.maxX - bubbleSize.width)

        var y = point.y + 10
        if y + bubbleSize.height > model.plotRect.maxY {
            y = point.y - bubbleSize.height - 10
        }
        y = min(max(y, model.plotRect.minY), model.plotRect.maxY - bubbleSize.height)

        let rect = NSRect(origin: NSPoint(x: x, y: y), size: bubbleSize)
        let bubble = NSBezierPath(
            roundedRect: rect,
            xRadius: 6,
            yRadius: 6
        )

        NSColor.controlBackgroundColor.withAlphaComponent(isDark ? 0.96 : 0.94).setFill()
        bubble.fill()

        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        bubble.lineWidth = max(1 / backingScale, 0.5)
        bubble.stroke()

        attributed.draw(
            at: NSPoint(
                x: rect.minX + horizontalPadding,
                y: rect.minY + verticalPadding
            )
        )
    }

    // MARK: - Plot model

    private func makePlotModel() -> PlotModel? {
        guard samples.count >= 2 else { return nil }

        let minX = samples.first!.x
        let maxX = samples.last!.x
        let axis = Self.makeAxis(
            values: samples.map(\.y),
            hardFloor: yFloor,
            hardCap: yCap
        )

        let yLabels = axis.ticks.map {
            valueString($0, axisSpan: axis.span) + unit
        }
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let maxYLabelWidth = yLabels
            .map { ($0 as NSString).size(withAttributes: [.font: labelFont]).width }
            .max() ?? 0

        let leftMargin = min(max(maxYLabelWidth + 10, 36), 76)
        let rightMargin: CGFloat = 8
        let bottomMargin: CGFloat = 20
        let topMargin: CGFloat = 8

        let plotRect = CGRect(
            x: leftMargin,
            y: bottomMargin,
            width: max(1, bounds.width - leftMargin - rightMargin),
            height: max(1, bounds.height - bottomMargin - topMargin)
        )

        let segmentRanges = Self.segmentRanges(samples)
        let rendered = segmentRanges.map { range in
            let segment = Array(samples[range])
            return Self.decimate(segment, width: plotRect.width)
        }

        return PlotModel(
            bounds: bounds,
            plotRect: plotRect,
            axis: axis,
            minX: minX,
            maxX: maxX,
            segments: segmentRanges,
            renderedSegments: rendered,
            yLabels: yLabels,
            startLabel: axisDateString(minX, span: maxX - minX),
            endLabel: axisDateString(maxX, span: maxX - minX)
        )
    }

    private func currentPlotModel() -> PlotModel? {
        if let plotModel, plotModel.bounds.size == bounds.size {
            return plotModel
        }
        let model = makePlotModel()
        plotModel = model
        return model
    }

    private func invalidateStaticCache() {
        staticImage = nil
        staticCacheKey = nil
        plotModel = nil
        needsDisplay = true
    }

    // MARK: - Scrub lookup

    /// Возвращает ближайший реальный сэмпл, но только внутри непрерывного сегмента.
    /// В пустом временном промежутке scrub ничего не показывает.
    private func scrubIndex(in model: PlotModel, at viewX: CGFloat?) -> Int? {
        guard let viewX,
              viewX >= model.plotRect.minX - 2,
              viewX <= model.plotRect.maxX + 2,
              !samples.isEmpty
        else {
            return nil
        }

        let dataX = model.dataX(for: viewX)
        let pixelTolerance: CGFloat = 18

        for range in model.segments {
            guard let first = range.first, let last = range.last else { continue }

            let firstX = samples[first].x
            let lastX = samples[last].x
            let firstPX = model.xPosition(firstX)
            let lastPX = model.xPosition(lastX)

            guard viewX >= firstPX - pixelTolerance,
                  viewX <= lastPX + pixelTolerance
            else {
                continue
            }

            let index = Self.nearestIndex(
                samples,
                x: dataX,
                in: range
            )
            guard abs(model.xPosition(samples[index].x) - viewX) <= pixelTolerance else {
                continue
            }
            return index
        }

        return nil
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }

    override func accessibilityLabel() -> String? {
        L("График истории")
    }

    override func accessibilityValue() -> Any? {
        guard let last = samples.last else {
            return emptyText
        }

        var text = valueString(last.y, axisSpan: plotModel?.axis.span ?? 1) + unit
        text += " · " + scrubFormatter().string(
            from: Date(timeIntervalSince1970: last.x)
        )

        if let pinnedTimestamp,
           let index = Self.binarySearchExact(samples, x: pinnedTimestamp) {
            let selected = samples[index]
            text += " · " + L("выбрано") + " "
                + valueString(selected.y, axisSpan: plotModel?.axis.span ?? 1)
                + unit
        }

        return text
    }

    override func accessibilityHelp() -> String? {
        L("Наведите курсор для точного значения. Клик фиксирует точку. Стрелки перемещают выбор, Escape снимает его.")
    }

    private func updateAccessibility() {
        NSAccessibility.post(
            element: self,
            notification: .valueChanged
        )
    }

    // MARK: - Formatting

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    private func refreshFormattersIfNeeded(locale: String) {
        guard formatterLocale != locale else { return }
        formatterLocale = locale
        scrubDateFormatter = nil
        axisDateFormatters.removeAll()
        numberFormatterCache.removeAll()
        invalidateStaticCache()
    }

    private func scrubFormatter() -> DateFormatter {
        if let scrubDateFormatter {
            return scrubDateFormatter
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: I18n.current.rawValue)
        formatter.setLocalizedDateFormatFromTemplate("d MMM HH:mm")
        scrubDateFormatter = formatter
        return formatter
    }

    private func axisDateString(_ timestamp: Double, span: Double) -> String {
        let template: String
        if span <= 24 * 60 * 60 {
            template = "HH:mm"
        } else if span <= 7 * 24 * 60 * 60 {
            template = "d MMM HH:mm"
        } else {
            template = "d MMM"
        }

        let formatter: DateFormatter
        if let cached = axisDateFormatters[template] {
            formatter = cached
        } else {
            let new = DateFormatter()
            new.locale = Locale(identifier: I18n.current.rawValue)
            new.setLocalizedDateFormatFromTemplate(template)
            axisDateFormatters[template] = new
            formatter = new
        }

        return formatter.string(
            from: Date(timeIntervalSince1970: timestamp)
        )
    }

    private func valueString(_ value: Double, axisSpan: Double) -> String {
        let digits: Int
        if axisSpan < 1 {
            digits = 2
        } else if axisSpan < 10 {
            digits = 1
        } else {
            digits = 0
        }

        if let formatter = numberFormatterCache[digits],
           let result = formatter.string(from: NSNumber(value: value)) {
            return result
        }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: I18n.current.rawValue)
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = digits
        formatter.usesGroupingSeparator = false
        numberFormatterCache[digits] = formatter

        return formatter.string(from: NSNumber(value: value))
            ?? String(format: "%.*f", digits, value)
    }

    private func aligned(_ coordinate: CGFloat, scale: CGFloat) -> CGFloat {
        (coordinate * scale).rounded() / scale
    }

    // MARK: - Data preparation

    private static func normalize(
        _ input: [(x: Double, y: Double)]
    ) -> [Sample] {
        let valid = input.enumerated()
            .filter { $0.element.x.isFinite && $0.element.y.isFinite }
            .sorted {
                if $0.element.x == $1.element.x {
                    return $0.offset < $1.offset
                }
                return $0.element.x < $1.element.x
            }

        var output: [Sample] = []
        output.reserveCapacity(valid.count)

        for item in valid {
            let sample = Sample(x: item.element.x, y: item.element.y)
            if let last = output.last, last.x == sample.x {
                output[output.count - 1] = sample
            } else {
                output.append(sample)
            }
        }

        return output
    }

    private static func sameSamples(
        _ lhs: [Sample],
        _ rhs: [Sample]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for index in lhs.indices {
            if lhs[index].x != rhs[index].x || lhs[index].y != rhs[index].y {
                return false
            }
        }
        return true
    }

    private static func segmentRanges(
        _ samples: [Sample]
    ) -> [Range<Int>] {
        guard !samples.isEmpty else { return [] }

        var ranges: [Range<Int>] = []
        var start = 0

        for index in 1..<samples.count {
            if samples[index].x - samples[index - 1].x > gapSeconds {
                ranges.append(start..<index)
                start = index
            }
        }

        ranges.append(start..<samples.count)
        return ranges
    }

    /// Min/max-прореживание по временным бакетам.
    ///
    /// Первая и последняя точки сегмента сохраняются всегда. В каждом внутреннем
    /// бакете сохраняются реальные minimum и maximum в исходном временном порядке.
    private static func decimate(
        _ source: [Sample],
        width: CGFloat
    ) -> [Sample] {
        let budget = max(96, Int(width * 2))
        guard source.count > budget, source.count > 2 else {
            return source
        }

        let interiorCount = source.count - 2
        let bucketCount = max(1, (budget - 2) / 2)
        var output: [Sample] = []
        output.reserveCapacity(bucketCount * 2 + 2)
        output.append(source[0])

        for bucket in 0..<bucketCount {
            let lower = 1 + bucket * interiorCount / bucketCount
            let upper = 1 + (bucket + 1) * interiorCount / bucketCount
            guard lower < upper else { continue }

            var minIndex = lower
            var maxIndex = lower

            for index in lower..<upper {
                if source[index].y < source[minIndex].y {
                    minIndex = index
                }
                if source[index].y > source[maxIndex].y {
                    maxIndex = index
                }
            }

            if minIndex < maxIndex {
                output.append(source[minIndex])
                output.append(source[maxIndex])
            } else if maxIndex < minIndex {
                output.append(source[maxIndex])
                output.append(source[minIndex])
            } else {
                output.append(source[minIndex])
            }
        }

        output.append(source[source.count - 1])

        var deduplicated: [Sample] = []
        deduplicated.reserveCapacity(output.count)
        for sample in output {
            if let last = deduplicated.last,
               last.x == sample.x,
               last.y == sample.y {
                continue
            }
            deduplicated.append(sample)
        }
        return deduplicated
    }

    // MARK: - Axis

    private static func makeAxis(
        values: [Double],
        hardFloor: Double?,
        hardCap: Double?
    ) -> Axis {
        guard let rawMin = values.min(),
              let rawMax = values.max()
        else {
            return Axis(min: 0, max: 1, ticks: [0, 0.5, 1])
        }

        var minValue = rawMin
        var maxValue = rawMax

        if abs(maxValue - minValue) < 1e-9 {
            let expansion = max(abs(maxValue) * 0.08, 1)
            minValue -= expansion
            maxValue += expansion
        } else {
            let padding = (maxValue - minValue) * 0.10
            minValue -= padding
            maxValue += padding
        }

        if let hardFloor {
            minValue = max(minValue, hardFloor)
        }
        if let hardCap {
            maxValue = min(maxValue, hardCap)
        }

        if minValue >= maxValue {
            if let hardFloor, let hardCap, hardFloor < hardCap {
                minValue = hardFloor
                maxValue = hardCap
            } else {
                let center = min(max(rawMin, hardFloor ?? -Double.greatestFiniteMagnitude),
                                 hardCap ?? Double.greatestFiniteMagnitude)
                let expansion = max(abs(center) * 0.08, 1)
                minValue = hardFloor.map { max(center - expansion, $0) } ?? center - expansion
                maxValue = hardCap.map { min(center + expansion, $0) } ?? center + expansion
            }
        }

        let rawRange = max(maxValue - minValue, 1e-9)
        let step = niceNumber(rawRange / 2, round: true)

        var niceMin = floor(minValue / step) * step
        var niceMax = ceil(maxValue / step) * step

        if let hardFloor {
            niceMin = max(niceMin, hardFloor)
        }
        if let hardCap {
            niceMax = min(niceMax, hardCap)
        }

        if niceMin >= niceMax {
            niceMin = minValue
            niceMax = maxValue
        }

        return Axis(
            min: niceMin,
            max: niceMax,
            ticks: [
                niceMin,
                (niceMin + niceMax) / 2,
                niceMax
            ]
        )
    }

    private static func niceNumber(
        _ value: Double,
        round: Bool
    ) -> Double {
        guard value > 0, value.isFinite else { return 1 }

        let exponent = floor(log10(value))
        let fraction = value / pow(10, exponent)
        let niceFraction: Double

        if round {
            if fraction < 1.5 {
                niceFraction = 1
            } else if fraction < 3 {
                niceFraction = 2
            } else if fraction < 7 {
                niceFraction = 5
            } else {
                niceFraction = 10
            }
        } else {
            if fraction <= 1 {
                niceFraction = 1
            } else if fraction <= 2 {
                niceFraction = 2
            } else if fraction <= 5 {
                niceFraction = 5
            } else {
                niceFraction = 10
            }
        }

        return niceFraction * pow(10, exponent)
    }

    // MARK: - Binary search

    private static func nearestIndex(
        _ samples: [Sample],
        x: Double,
        in range: Range<Int>
    ) -> Int {
        var low = range.lowerBound
        var high = range.upperBound

        while low < high {
            let mid = low + (high - low) / 2
            if samples[mid].x < x {
                low = mid + 1
            } else {
                high = mid
            }
        }

        if low <= range.lowerBound {
            return range.lowerBound
        }
        if low >= range.upperBound {
            return range.upperBound - 1
        }

        let left = low - 1
        let right = low
        return abs(samples[left].x - x) <= abs(samples[right].x - x)
            ? left
            : right
    }

    private static func binarySearchExact(
        _ samples: [Sample],
        x: Double
    ) -> Int? {
        var low = 0
        var high = samples.count

        while low < high {
            let mid = low + (high - low) / 2
            if samples[mid].x < x {
                low = mid + 1
            } else {
                high = mid
            }
        }

        guard low < samples.count, samples[low].x == x else {
            return nil
        }
        return low
    }
}
