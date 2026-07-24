import AppKit

/// Живой спарклайн расхода (Вт). Хранит историю, рисует заливку под кривой.
final class GraphView: NSView {
    private var samples: [Double] = []
    var accentColor: NSColor = .systemGreen

    func push(_ value: Double, keep: Int = 90) {
        samples.append(value)
        if samples.count > keep { samples.removeFirst(samples.count - keep) }
        needsDisplay = true
    }

    func setHistory(_ values: [Double]) {
        samples = values
        needsDisplay = true
    }

    /// «Красивый» потолок шкалы: округление вверх до 1/2/5·10ⁿ (как в дашбордах), не ниже 2 Вт.
    private func niceCeil(_ v: Double) -> Double {
        let x = max(v, 2)
        let e = floor(log10(x)); let base = pow(10, e); let f = x / base
        let nice: Double = f <= 1 ? 1 : (f <= 2 ? 2 : (f <= 5 ? 5 : 10))
        return nice * base
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (dark ? NSColor(white: 1, alpha: 0.04) : NSColor(white: 0, alpha: 0.035)).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Design.Radius.graphBg, yRadius: Design.Radius.graphBg).fill()

        guard samples.count > 1 else { return }
        let realMax = samples.max() ?? 1
        let maxV = niceCeil(realMax)                                       // приборный потолок (≥ пика)
        let n = samples.count, w = bounds.width, h = bounds.height
        let gutter: CGFloat = 26, padR: CGFloat = 8, padTop: CGFloat = 11, padBot: CGFloat = 11
        let plotH = h - padTop - padBot

        func point(_ i: Int) -> NSPoint {
            let x = gutter + (w - gutter - padR) * CGFloat(i) / CGFloat(n - 1)
            let y = padBot + plotH * CGFloat(samples[i] / maxV)
            return NSPoint(x: x, y: y)
        }
        func gridY(_ f: CGFloat) -> CGFloat { padBot + plotH * f }

        // сетка: базовая линия + 50% + потолок (hairline) + Y-подписи (потолок и середина)
        for (f, a) in [(CGFloat(0), 0.10), (0.5, 0.05), (1.0, 0.05)] {
            Design.Color.hairline(dark, dark ? a : a + 0.01).setStroke()
            let g = NSBezierPath(); g.lineWidth = 0.5
            g.move(to: NSPoint(x: gutter, y: gridY(f))); g.line(to: NSPoint(x: w - padR, y: gridY(f))); g.stroke()
        }
        let labAttr: [NSAttributedString.Key: Any] = [.font: Design.Font.numericMicro, .foregroundColor: NSColor.tertiaryLabelColor]
        func yLabel(_ value: Double, _ f: CGFloat) {
            let s = String(format: "%.0f", value) as NSString
            let sz = s.size(withAttributes: labAttr)
            s.draw(at: NSPoint(x: gutter - 5 - sz.width, y: gridY(f) - sz.height/2), withAttributes: labAttr)
        }
        yLabel(maxV, 1.0); yLabel(maxV/2, 0.5)

        // ЧЕСТНО: прямые сегменты между РЕАЛЬНЫМИ сэмплами, без сглаживания. Гладкая кривая (монотонная
        // кубическая) выдумывала бы значения МЕЖДУ точками и искажала пики — iStat намеренно убрал все
        // сглаженные графики. Линейная ломаная показывает ровно то, что снято (ось Y уже авто-масштаб).
        let pts = (0..<n).map { point($0) }
        let line = NSBezierPath()
        line.move(to: pts[0])
        for i in 1..<n { line.line(to: pts[i]) }

        // мягкая заливка под кривой — затухает к низу (трёхступенчато, без «мутного» блока)
        let fill = line.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: point(n-1).x, y: padBot))
        fill.line(to: NSPoint(x: point(0).x, y: padBot))
        fill.close()
        NSGraphicsContext.saveGraphicsState()
        fill.addClip()
        NSGradient(colors: [accentColor.withAlphaComponent(0.26), accentColor.withAlphaComponent(0.06), accentColor.withAlphaComponent(0)],
                   atLocations: [0, 0.55, 1], colorSpace: .sRGB)?.draw(in: bounds, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // bevel-блик: тонкий светлый дубль чуть ниже линии — добавляет «дорогой» объём кривой
        let bevel = line.copy() as! NSBezierPath
        let xf = AffineTransform(translationByX: 0, byY: 0.5); bevel.transform(using: xf)
        bevel.lineWidth = 1.0; bevel.lineCapStyle = .round; bevel.lineJoinStyle = .round
        Design.Color.rimHighlight(dark, 0.12).setStroke()       // bevel-блик: dark .12 / light ≈ .10
        bevel.stroke()

        // линия с лёгким свечением
        line.lineWidth = 2.0
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow(); glow.shadowColor = accentColor.withAlphaComponent(dark ? 0.42 : 0.28)
        glow.shadowBlurRadius = 3; glow.shadowOffset = .zero; glow.set()   // тоньше свечение — линия читается чётче
        accentColor.setStroke()
        line.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // текущее значение — точка с мягким ореолом
        let last = point(n-1)
        accentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: NSRect(x: last.x-5, y: last.y-5, width: 10, height: 10)).fill()
        accentColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: last.x-2.8, y: last.y-2.8, width: 5.6, height: 5.6)).fill()

        // единица измерения шкалы — верхний-правый угол (там пусто; не конфликтует с Y-числами слева)
        let unit = L("Вт") as NSString
        let usz = unit.size(withAttributes: labAttr)
        unit.draw(at: NSPoint(x: w - padR - usz.width, y: h - usz.height - 1), withAttributes: labAttr)
    }
}
