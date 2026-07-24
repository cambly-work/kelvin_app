import AppKit

/// UI-компоненты раздела «Охлаждение и питание» (L2 редизайна):
///  • FanCurveView   — редактор кривой t°→обороты с перетаскиваемыми узлами и бегущим маркером температуры;
///  • LiveTraceView  — живой график «цель vs факт» во времени (ring-buffer);
///  • FanBar         — гейдж вентилятора: факт-заливка в диапазоне мин–макс + метка ЦЕЛИ на треке.
/// Рисуют через draw(_:) (NSBezierPath) — надёжно и тема-зависимо (Design.Color.*). Данные подаёт Settings.

private func clampD(_ v: Double, _ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(v, lo), hi) }
private func clampC(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { Swift.min(Swift.max(v, lo), hi) }

// MARK: - Кривая температура → обороты (перетаскиваемые узлы)

final class FanCurveView: NSView {
    /// Точки кривой (temp °C → rpm). Держатся в temp-порядке при драге (монотонность обеспечивается клампом соседей).
    var points: [CurvePoint] = [] { didSet { needsDisplay = true } }
    var tempRange: ClosedRange<Double> = 20...100
    var rpmRange: ClosedRange<Double> = 1200...6000
    /// Текущая температура ведущего датчика — бегущий вертикальный маркер (nil → не рисуем).
    var currentTemp: Double? { didSet { needsDisplay = true } }
    /// Отдаётся при каждом изменении узла (live). Значения уже в temp-порядке и монотонны по rpm.
    var onChange: (([CurvePoint]) -> Void)?

    private var dragIndex: Int?
    private let padL: CGFloat = 40, padR: CGFloat = 12, padT: CGFloat = 12, padB: CGFloat = 18

    override var isFlipped: Bool { false }                 // y вверх — как на графике
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 160) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func plot() -> NSRect {
        NSRect(x: padL, y: padB, width: max(1, bounds.width - padL - padR), height: max(1, bounds.height - padT - padB))
    }
    private func toPoint(_ temp: Double, _ rpm: Double) -> NSPoint {
        let r = plot()
        let tx = (temp - tempRange.lowerBound) / max(1, tempRange.upperBound - tempRange.lowerBound)
        let ry = (rpm - rpmRange.lowerBound) / max(1, rpmRange.upperBound - rpmRange.lowerBound)
        return NSPoint(x: r.minX + clampC(CGFloat(tx), 0, 1) * r.width,
                       y: r.minY + clampC(CGFloat(ry), 0, 1) * r.height)
    }
    private func toValue(_ p: NSPoint) -> (temp: Double, rpm: Double) {
        let r = plot()
        let tx = clampD(Double((p.x - r.minX) / r.width), 0, 1)
        let ry = clampD(Double((p.y - r.minY) / r.height), 0, 1)
        return (tempRange.lowerBound + tx * (tempRange.upperBound - tempRange.lowerBound),
                rpmRange.lowerBound + ry * (rpmRange.upperBound - rpmRange.lowerBound))
    }

    override func draw(_ dirty: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let r = plot()
        let accent = Design.Color.accent(dark)

        // фон-плитка
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Design.Radius.chip, yRadius: Design.Radius.chip)
        Design.Color.controlFill(dark).setFill(); bg.fill()

        // горизонтальная сетка + подписи rpm (мин/сред/макс)
        Design.Color.hairline(dark, 0.10).setStroke()
        let grid = NSBezierPath(); grid.lineWidth = 1
        for i in 0...4 {
            let y = r.minY + r.height * CGFloat(i) / 4
            grid.move(to: NSPoint(x: r.minX, y: y)); grid.line(to: NSPoint(x: r.maxX, y: y))
        }
        grid.stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
                                                     .foregroundColor: NSColor.tertiaryLabelColor]
        for (frac, val) in [(1.0, rpmRange.upperBound), (0.5, (rpmRange.lowerBound + rpmRange.upperBound) / 2), (0.0, rpmRange.lowerBound)] {
            let y = r.minY + r.height * CGFloat(frac)
            let s = "\(Int(val))" as NSString
            s.draw(at: NSPoint(x: 2, y: y - 5), withAttributes: attrs)
        }

        guard points.count >= 2 else {
            let hint = "Добавьте точки кривой" as NSString
            hint.draw(at: NSPoint(x: r.minX + 8, y: r.midY - 6), withAttributes: attrs)
            return
        }
        let sorted = points.sorted { $0.temp < $1.temp }

        // бегущий маркер текущей температуры (под кривой)
        if let t = currentTemp {
            let x = toPoint(t, rpmRange.lowerBound).x
            Design.Color.levelWarn.withAlphaComponent(0.85).setStroke()
            let mk = NSBezierPath(); mk.lineWidth = 1.5
            mk.move(to: NSPoint(x: x, y: r.minY)); mk.line(to: NSPoint(x: x, y: r.maxY)); mk.stroke()
        }

        // линия кривой
        let line = NSBezierPath(); line.lineWidth = 2; line.lineJoinStyle = .round
        for (i, pt) in sorted.enumerated() {
            let p = toPoint(Double(pt.temp), Double(pt.rpm))
            if i == 0 { line.move(to: p) } else { line.line(to: p) }
        }
        accent.setStroke(); line.stroke()

        // узлы + подпись значения
        for pt in sorted {
            let p = toPoint(Double(pt.temp), Double(pt.rpm))
            let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
            accent.setFill(); dot.fill()
            NSColor.white.withAlphaComponent(0.9).setStroke(); dot.lineWidth = 1.5; dot.stroke()
            let lbl = "\(pt.temp)°" as NSString
            lbl.draw(at: NSPoint(x: p.x - 8, y: r.minY - 14), withAttributes: attrs)
        }
    }

    override func mouseDown(with e: NSEvent) {
        let pt = convert(e.locationInWindow, from: nil)
        dragIndex = nil
        var best = CGFloat.greatestFiniteMagnitude
        for (i, p) in points.enumerated() {
            let sp = toPoint(Double(p.temp), Double(p.rpm))
            let d = hypot(sp.x - pt.x, sp.y - pt.y)
            if d < 16, d < best { best = d; dragIndex = i }
        }
    }
    override func mouseDragged(with e: NSEvent) {
        guard let i = dragIndex, i < points.count else { return }
        let pt = convert(e.locationInWindow, from: nil)
        var (t, rpm) = toValue(pt)
        // монотонность: temp/rpm тащимого узла зажаты между соседями по temp-порядку (горячее не медленнее).
        let order = points.indices.sorted { points[$0].temp < points[$1].temp }
        if let pos = order.firstIndex(of: i) {
            if pos > 0 { let lo = points[order[pos - 1]]; t = Swift.max(t, Double(lo.temp)); rpm = Swift.max(rpm, Double(lo.rpm)) }
            if pos < order.count - 1 { let hi = points[order[pos + 1]]; t = Swift.min(t, Double(hi.temp)); rpm = Swift.min(rpm, Double(hi.rpm)) }
        }
        points[i].temp = Int(t.rounded()); points[i].rpm = Int(rpm.rounded())
        needsDisplay = true
        onChange?(points.sorted { $0.temp < $1.temp })
    }
    override func mouseUp(with e: NSEvent) { dragIndex = nil }
}

// MARK: - Живой график «цель vs факт»

final class LiveTraceView: NSView {
    struct Sample { var target: Double; var actual: Double }
    private var buf: [Sample] = []
    private let cap = 120
    var rpmRange: ClosedRange<Double> = 0...6000
    /// Короткий красный пульс при срабатывании алерта (форс-макс).
    var alertPulse = false

    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 84) }

    func push(target: Double, actual: Double) {
        buf.append(Sample(target: target, actual: actual))
        if buf.count > cap { buf.removeFirst(buf.count - cap) }
        needsDisplay = true
    }
    func reset() { buf.removeAll(); needsDisplay = true }

    override func draw(_ dirty: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Design.Radius.chip, yRadius: Design.Radius.chip)
        Design.Color.controlFill(dark).setFill(); bg.fill()
        guard buf.count >= 2 else { return }
        let r = bounds.insetBy(dx: 6, dy: 6)
        func y(_ v: Double) -> CGFloat {
            let f = (v - rpmRange.lowerBound) / max(1, rpmRange.upperBound - rpmRange.lowerBound)
            return r.minY + clampC(CGFloat(f), 0, 1) * r.height
        }
        func x(_ i: Int) -> CGFloat { r.minX + r.width * CGFloat(i) / CGFloat(max(1, cap - 1)) }
        // цель — пунктир, факт — сплошная (трейлит за целью → видно разгон)
        let tgt = NSBezierPath(); tgt.lineWidth = 1.5
        let dash: [CGFloat] = [3, 3]; tgt.setLineDash(dash, count: 2, phase: 0)
        let act = NSBezierPath(); act.lineWidth = 2; act.lineJoinStyle = .round
        for (i, s) in buf.enumerated() {
            let xi = x(i + (cap - buf.count))
            if i == 0 { tgt.move(to: NSPoint(x: xi, y: y(s.target))); act.move(to: NSPoint(x: xi, y: y(s.actual))) }
            else { tgt.line(to: NSPoint(x: xi, y: y(s.target))); act.line(to: NSPoint(x: xi, y: y(s.actual))) }
        }
        Design.Color.neutralNode(dark).setStroke(); tgt.stroke()
        (alertPulse ? Design.Color.levelCrit : Design.Color.accent(dark)).setStroke(); act.stroke()
    }
}

// MARK: - Гейдж вентилятора: факт-заливка + метка ЦЕЛИ

final class FanBar: NSView {
    var minRPM: Double = 0
    var maxRPM: Double = 6000
    var actual: Double = 0
    var target: Double?          // метка цели на треке (nil = без цели / система)
    var forced = false           // ручной форс → оранжевый
    init() { super.init(frame: .zero); wantsLayer = true; translatesAutoresizingMaskIntoConstraints = false }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 220, height: 10) }

    override func draw(_ dirty: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let r = bounds
        let track = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        Design.Color.trackFill(dark).setFill(); track.fill()
        let span = max(1, maxRPM - minRPM)
        let frac = clampC(CGFloat((actual - minRPM) / span), 0.02, 1)
        let fillR = NSRect(x: 0, y: 0, width: r.width * frac, height: r.height)
        let fill = NSBezierPath(roundedRect: fillR, xRadius: r.height / 2, yRadius: r.height / 2)
        (forced ? Design.Color.levelWarn : Design.Color.accent(dark)).setFill(); fill.fill()
        if let t = target {
            let tf = clampC(CGFloat((t - minRPM) / span), 0, 1)
            let x = r.width * tf
            let mk = NSBezierPath(rect: NSRect(x: max(0, x - 1), y: -2, width: 2, height: r.height + 4))
            Design.Color.hairline(dark, 0.9).setFill(); mk.fill()
        }
    }
}

// MARK: - Пункт меню с замыканием (для мультивыбора датчиков)

/// NSMenuItem, который на клик зовёт замыкание (без target/action-церемоний). Используется
/// компактным дропдауном выбора нескольких датчиков (max-of) в редакторе кривой.
final class ClosureMenuItem: NSMenuItem {
    private var handler: () -> Void = {}
    convenience init(title: String, checked: Bool, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
        self.state = checked ? .on : .off
        self.handler = handler
    }
    @objc private func fire() { handler() }
}
