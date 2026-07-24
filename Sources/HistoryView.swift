import AppKit

/// Простой честный линейный график истории: рисует РЕАЛЬНО снятые точки, авто-масштаб по Y, 3 сетки-линии
/// с подписями, мягкая заливка под линией. Пусто/мало точек → текст «накопление данных» (не выдумываем кривую).
/// drawRect (не CALayer) — рендерится и в офскрин-снапшоте, и статичен между обновлениями данных.
final class HistoryChart: NSView {
    private var pts: [(x: Double, y: Double)] = []
    private var lineColor: NSColor = .systemTeal
    private var unit: String = ""
    private var emptyText: String = ""
    private var yCap: Double?          // потолок оси Y (например 100 для %-метрики) — чтобы не рисовать «107%»
    private var yFloor: Double?        // пол оси Y (например 0 для %-метрики) — чтобы не рисовать «-6%»
    /// Порог разрыва: снимок раз в минуту (60с) → интервал > 150с между соседними точками = пропуск
    /// (сон/закрытый поповер). Линию через такой пропуск не ведём.
    static let gapSeconds: Double = 150

    private var hoverX: CGFloat?               // x курсора (скраб-кроссхейр); nil — не наводим
    private var scrubArea: NSTrackingArea?
    // Форматтер скраб-подписи кэшируем (создавался на КАЖДОЕ движение курсора → лишние аллокации);
    // пересобираем только при смене языка.
    private var scrubDF: DateFormatter?
    private var scrubDFLocale = ""
    private func scrubFormatter() -> DateFormatter {
        let loc = I18n.current.rawValue
        if let df = scrubDF, scrubDFLocale == loc { return df }
        let df = DateFormatter(); df.dateFormat = "d MMM HH:mm"; df.locale = Locale(identifier: loc)
        scrubDF = df; scrubDFLocale = loc
        return df
    }

    func set(points: [(x: Double, y: Double)], color: NSColor, unit: String, yCap: Double? = nil, yFloor: Double? = nil, empty: String) {
        pts = points; lineColor = color; self.unit = unit; self.yCap = yCap; self.yFloor = yFloor; emptyText = empty
        needsDisplay = true
    }

    // MARK: — скраб-кроссхейр (наведение → точное значение + время реально снятой точки) —
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = scrubArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(ta); scrubArea = ta
    }
    override func mouseMoved(with event: NSEvent) { hoverX = convert(event.locationInWindow, from: nil).x; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hoverX = nil; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let area = bounds.insetBy(dx: 8, dy: 8)
        guard area.width > 4, area.height > 4 else { return }

        // пусто/одна точка — честное состояние «накопление», без выдуманной линии
        guard pts.count >= 2 else {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11),
                                                        .foregroundColor: NSColor.tertiaryLabelColor]
            let s = emptyText as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: area.midX - sz.width / 2, y: area.midY - sz.height / 2), withAttributes: attrs)
            return
        }

        // Оси по ВСЕМ реальным точкам (консистентно между сегментами разрыва).
        let xs = pts.map { $0.x }, ys = pts.map { $0.y }
        let minX = xs.min()!, maxX = xs.max()!
        var minY = ys.min()!, maxY = ys.max()!
        if maxY - minY < 1e-6 { minY -= 1; maxY += 1 }          // плоская линия — не делим на ноль
        let pad = (maxY - minY) * 0.12; minY -= pad; maxY += pad
        if let cap = yCap { maxY = min(maxY, cap) }             // %-метрика: верх оси не выше 100
        if let floor = yFloor { minY = max(minY, floor) }       // %-метрика: низ оси не ниже 0 (заряд не бывает «-6%»)
        let spanX = max(maxX - minX, 1e-6), spanY = max(maxY - minY, 1e-6)
        func px(_ x: Double) -> CGFloat { area.minX + CGFloat((x - minX) / spanX) * area.width }
        func py(_ y: Double) -> CGFloat { area.minY + CGFloat((y - minY) / spanY) * area.height }

        // сетка (линии) — ПОД графиком; подписи значений уйдут ПОВЕРХ линии (иначе плотная кривая их затирает)
        let grid = NSColor.tertiaryLabelColor.withAlphaComponent(0.18)
        for frac in [0.0, 0.5, 1.0] as [Double] {
            let y = py(minY + spanY * frac)
            grid.setStroke()
            let g = NSBezierPath(); g.move(to: NSPoint(x: area.minX, y: y)); g.line(to: NSPoint(x: area.maxX, y: y))
            g.lineWidth = 0.5; g.stroke()
        }

        // РАЗРЫВЫ (честность-в-пикселях): снимок раз в минуту → соседние РЕАЛЬНЫЕ точки с интервалом
        // > gapSeconds означают сон/закрытый поповер — линию через пустоту НЕ ведём (иначе выдумываем
        // данные, которых не было). Делим ряд на непрерывные сегменты и рисуем каждый отдельно.
        var segments: [[(x: Double, y: Double)]] = []
        var cur: [(x: Double, y: Double)] = [pts[0]]
        for i in 1..<pts.count {
            if pts[i].x - pts[i - 1].x > Self.gapSeconds { segments.append(cur); cur = [] }
            cur.append(pts[i])
        }
        if !cur.isEmpty { segments.append(cur) }

        // Прореживание — НА КАЖДЫЙ сегмент (месяц непрерывной работы = ~43k точек: сегмент-на-точку дорого
        // и невидимо). Бакеты по ширине, держим min+max каждого — огибающая честная (реальные экстремумы).
        for seg in segments {
            let p = Self.decimate(seg, width: area.width)
            guard let f = p.first else { continue }
            if p.count == 1 {                                    // одиночный снимок между двумя пропусками — точка, не линия
                let d = NSBezierPath(ovalIn: NSRect(x: px(f.x) - 1.5, y: py(f.y) - 1.5, width: 3, height: 3))
                lineColor.setFill(); d.fill()
                continue
            }
            let line = NSBezierPath()
            line.move(to: NSPoint(x: px(f.x), y: py(f.y)))
            for q in p.dropFirst() { line.line(to: NSPoint(x: px(q.x), y: py(q.y))) }
            // мягкая заливка под линией сегмента
            let fill = line.copy() as! NSBezierPath
            fill.line(to: NSPoint(x: px(p.last!.x), y: area.minY))
            fill.line(to: NSPoint(x: px(f.x), y: area.minY)); fill.close()
            lineColor.withAlphaComponent(0.10).setFill(); fill.fill()
            lineColor.setStroke(); line.lineWidth = 1.5; line.lineJoinStyle = .round; line.stroke()
        }

        // подписи значений (низ/сред/верх) — ПОВЕРХ линии, с подложкой, чтобы читались на плотной кривой
        let labAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .backgroundColor: NSColor.windowBackgroundColor.withAlphaComponent(0.72)]
        for frac in [0.0, 0.5, 1.0] as [Double] {
            let yv = minY + spanY * frac
            let s = String(format: " %.0f%@ ", yv, unit) as NSString
            let h = s.size(withAttributes: labAttrs).height
            let y = min(py(yv) + 1, bounds.maxY - h)          // верхняя подпись не обрезается краем вида
            s.draw(at: NSPoint(x: area.minX, y: y), withAttributes: labAttrs)
        }

        // СКРАБ-КРОССХЕЙР: под курсором находим БЛИЖАЙШУЮ РЕАЛЬНУЮ точку и показываем её значение+время.
        // Честно: читаем ровно снятый сэмпл, ничего не интерполируем. Если курсор над пропуском (ближайшая
        // точка далеко по экрану) — не показываем (там данных не было).
        if let hx = hoverX, hx >= area.minX - 2, hx <= area.maxX + 2 {
            let dataX = minX + Double((hx - area.minX) / area.width) * spanX
            if let near = pts.min(by: { abs($0.x - dataX) < abs($1.x - dataX) }) {
                let nx = px(near.x), ny = py(near.y)
                if abs(nx - hx) <= 24 {                         // над пропуском ближайшая точка далеко → скрываем
                    NSColor.tertiaryLabelColor.withAlphaComponent(0.5).setStroke()
                    let cross = NSBezierPath(); cross.move(to: NSPoint(x: nx, y: area.minY)); cross.line(to: NSPoint(x: nx, y: area.maxY))
                    cross.lineWidth = 0.75; cross.stroke()
                    let dot = NSBezierPath(ovalIn: NSRect(x: nx - 2.5, y: ny - 2.5, width: 5, height: 5))
                    lineColor.setFill(); dot.fill()
                    NSColor.windowBackgroundColor.setStroke(); dot.lineWidth = 1; dot.stroke()
                    let df = scrubFormatter()
                    let tip = " " + String(format: "%.0f%@", near.y, unit) + " · " + df.string(from: Date(timeIntervalSince1970: near.x)) + " "
                    let tipS = tip as NSString
                    let tsz = tipS.size(withAttributes: labAttrs)
                    let tx = min(max(area.minX, nx - tsz.width / 2), area.maxX - tsz.width)
                    let ty = min(ny + 8, bounds.maxY - tsz.height)
                    tipS.draw(at: NSPoint(x: tx, y: ty), withAttributes: labAttrs)
                }
            }
        }
    }

    /// Прорядить ряд до ~ширины графика, сохраняя огибающую: для каждого бакета берём min и max точки в
    /// порядке по x (времени). Экстремумы реальны — ничего не выдумываем. Ниже порога возвращаем как есть.
    private static func decimate(_ src: [(x: Double, y: Double)], width: CGFloat) -> [(x: Double, y: Double)] {
        let maxPts = max(64, Int(width * 2))
        let n = src.count
        guard n > maxPts else { return src }
        let buckets = maxPts / 2
        var out: [(x: Double, y: Double)] = []
        out.reserveCapacity(buckets * 2 + 2)
        for b in 0..<buckets {
            let lo = b * n / buckets
            let hi = min((b + 1) * n / buckets, n)
            guard lo < hi else { continue }
            var minI = lo, maxI = lo
            for i in lo..<hi {
                if src[i].y < src[minI].y { minI = i }
                if src[i].y > src[maxI].y { maxI = i }
            }
            if minI <= maxI { out.append(src[minI]); if maxI != minI { out.append(src[maxI]) } }
            else { out.append(src[maxI]); out.append(src[minI]) }
        }
        return out
    }
}
