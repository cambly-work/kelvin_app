import AppKit

/// Бренд-набор монохромных template-глифов Kelvin для строки меню. Единый «приборный»
/// язык: общая оптическая величина, скруглённые концы, согласованная толщина штриха.
/// Рисуются текущим цветом (template → система тинтует под свет/тьму/выделение).
enum KelvinGlyph {
    /// Какие параметры имеют кастомный глиф (иначе — фолбэк на SF Symbol).
    static let supported: Set<String> = ["battery", "watts", "cputemp", "gputemp", "fan",
                                         "cpu", "ram", "net", "diskio", "diskfree",
                                         "btbatt", "clock", "date"]

    static func image(_ id: String, size: CGFloat = 14) -> NSImage? {
        guard supported.contains(id) else { return nil }
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.black.set()
            draw(id, in: rect)
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Рисует глиф id в прямоугольнике r текущим установленным цветом (set до вызова).
    static func draw(_ id: String, in r: NSRect) {
        let s = min(r.width, r.height)
        let lw = max(1, s * 0.085)            // единый штрих ~8.5% размера
        switch id {
        case "cputemp", "gputemp": thermometer(r, s, lw)
        case "fan":                fan(r, s, lw)
        case "cpu":                chip(r, s, lw)
        case "ram":                ram(r, s, lw)
        case "net":                net(r, s, lw)
        case "diskio", "diskfree": disk(r, s, lw)
        case "watts":              bolt(r, s)
        case "clock":              clock(r, s, lw)
        case "date":               calendar(r, s, lw)
        case "btbatt":             bluetooth(r, s, lw)
        case "battery":            battery(r, s, lw)
        default:                   break
        }
    }

    // MARK: глифы

    private static func stroked(_ p: NSBezierPath, _ lw: CGFloat) {
        p.lineWidth = lw; p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke()
    }

    private static func thermometer(_ r: NSRect, _ s: CGFloat, _ lw: CGFloat) {
        let cx = r.midX
        let bulbR = s * 0.16
        let bulbCy = r.minY + s * 0.20
        let tubeW = s * 0.20
        let top = r.maxY - s * 0.10
        // трубка (контур-капсула)
        let tube = NSBezierPath(roundedRect: NSRect(x: cx - tubeW/2, y: bulbCy, width: tubeW, height: top - bulbCy),
                                xRadius: tubeW/2, yRadius: tubeW/2)
        stroked(tube, lw * 0.9)
        // колба
        NSBezierPath(ovalIn: NSRect(x: cx - bulbR, y: bulbCy - bulbR, width: bulbR*2, height: bulbR*2)).fill()
        // «ртуть» — заполненный столбик от колбы вверх
        let mW = tubeW * 0.42
        let mTop = bulbCy + (top - bulbCy) * 0.5
        NSBezierPath(roundedRect: NSRect(x: cx - mW/2, y: bulbCy, width: mW, height: mTop - bulbCy),
                     xRadius: mW/2, yRadius: mW/2).fill()
        // риски справа
        let tp = NSBezierPath()
        for i in 0..<3 {
            let ty = bulbCy + s*0.30 + CGFloat(i)*s*0.16
            tp.move(to: NSPoint(x: cx + tubeW*0.7, y: ty)); tp.line(to: NSPoint(x: cx + s*0.22, y: ty))
        }
        stroked(tp, lw * 0.7)
    }

    private static func fan(_ r: NSRect, _ s: CGFloat, _ lw: CGFloat) {
        let c = NSPoint(x: r.midX, y: r.midY)
        let R = s * 0.42, hub = s * 0.12
        func pt(_ ang: CGFloat, _ rad: CGFloat) -> NSPoint { NSPoint(x: c.x + cos(ang)*rad, y: c.y + sin(ang)*rad) }
        // 3 свёрнутые лопасти (асимметрия → ощущение вращения)
        for k in 0..<3 {
            let a = CGFloat(k) * .pi * 2 / 3 - .pi/2
            let p = NSBezierPath()
            p.move(to: pt(a - 0.34, hub))
            p.curve(to: pt(a + 0.42, R),                         // внешняя кромка, свёрнута вперёд
                    controlPoint1: pt(a - 0.18, R*0.95), controlPoint2: pt(a + 0.30, R*1.02))
            p.curve(to: pt(a + 0.34, hub),                       // обратно к ступице
                    controlPoint1: pt(a + 0.62, R*0.55), controlPoint2: pt(a + 0.6, hub*1.6))
            p.close()
            p.fill()
        }
        // ступица
        NSBezierPath(ovalIn: NSRect(x: c.x - hub, y: c.y - hub, width: hub*2, height: hub*2)).fill()
    }

    private static func chip(_ r: NSRect, _ s: CGFloat, _ lw: CGFloat) {
        let die = r.insetBy(dx: s*0.24, dy: s*0.24)
        // ножки
        let legs = NSBezierPath()
        let legLen = s*0.12
        for f in [CGFloat(0.32), 0.5, 0.68] {
            // верх/низ
            let x = r.minX + r.width*f
            legs.move(to: NSPoint(x: x, y: die.maxY)); legs.line(to: NSPoint(x: x, y: die.maxY + legLen))
            legs.move(to: NSPoint(x: x, y: die.minY)); legs.line(to: NSPoint(x: x, y: die.minY - legLen))
            // лево/право
            let y = r.minY + r.height*f
            legs.move(to: NSPoint(x: die.minX, y: y)); legs.line(to: NSPoint(x: die.minX - legLen, y: y))
            legs.move(to: NSPoint(x: die.maxX, y: y)); legs.line(to: NSPoint(x: die.maxX + legLen, y: y))
        }
        stroked(legs, lw*0.8)
        // корпус (контур) + внутренний квадрат
        stroked(NSBezierPath(roundedRect: die, xRadius: s*0.06, yRadius: s*0.06), lw)
        let inner = die.insetBy(dx: die.width*0.28, dy: die.height*0.28)
        stroked(NSBezierPath(roundedRect: inner, xRadius: s*0.03, yRadius: s*0.03), lw*0.8)
    }

    private static func ram(_ r: NSRect, _ s: CGFloat, _ lw: CGFloat) {
        let body = NSRect(x: r.minX + s*0.08, y: r.minY + s*0.30, width: r.width - s*0.16, height: s*0.40)
        stroked(NSBezierPath(roundedRect: body, xRadius: s*0.04, yRadius: s*0.04), lw)
        // вертикальные чипы
        let chips = NSBezierPath()
        for i in 1...4 {
            let x = body.minX + body.width * CGFloat(i)/5
            chips.move(to: NSPoint(x: x, y: body.minY + s*0.07)); chips.line(to: NSPoint(x: x, y: body.maxY - s*0.07))
        }
        stroked(chips, lw*0.7)
        // ножки
        let legs = NSBezierPath()
        for f in [CGFloat(0.3), 0.7] {
            let x = r.minX + r.width*f
            legs.move(to: NSPoint(x: x, y: body.minY)); legs.line(to: NSPoint(x: x, y: body.minY - s*0.12))
        }
        stroked(legs, lw*0.9)
    }

    private static func net(_ r: NSRect, _ s: CGFloat, _ lw: CGFloat) {
        // вниз-стрелка слева, вверх-стрелка справа
        func arrow(x: CGFloat, up: Bool) {
            let top = r.maxY - s*0.14, bot = r.minY + s*0.14
            let head = s*0.13
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x, y: bot)); p.line(to: NSPoint(x: x, y: top))
            let tipY = up ? top : bot
            let dir: CGFloat = up ? -1 : 1
            p.move(to: NSPoint(x: x - head, y: tipY + dir*head))
            p.line(to: NSPoint(x: x, y: tipY))
            p.line(to: NSPoint(x: x + head, y: tipY + dir*head))
            stroked(p, lw)
        }
        arrow(x: r.midX - s*0.16, up: false)
        arrow(x: r.midX + s*0.16, up: true)
    }

    private static func disk(_ r: NSRect, _ s: CGFloat, _ lw: CGFloat) {
        let box = r.insetBy(dx: s*0.14, dy: s*0.20)
        stroked(NSBezierPath(roundedRect: box, xRadius: s*0.07, yRadius: s*0.07), lw)
        // платтер
        let pr = box.width * 0.30
        let c = NSPoint(x: box.midX, y: box.midY)
        stroked(NSBezierPath(ovalIn: NSRect(x: c.x-pr, y: c.y-pr, width: pr*2, height: pr*2)), lw*0.8)
        NSBezierPath(ovalIn: NSRect(x: c.x-s*0.03, y: c.y-s*0.03, width: s*0.06, height: s*0.06)).fill()
    }

    private static func bolt(_ r: NSRect, _ s: CGFloat) {
        // молния (залитый полигон)
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX + s*0.56, y: r.maxY - s*0.06))
        p.line(to: NSPoint(x: r.minX + s*0.30, y: r.midY + s*0.04))
        p.line(to: NSPoint(x: r.minX + s*0.50, y: r.midY + s*0.04))
        p.line(to: NSPoint(x: r.minX + s*0.40, y: r.minY + s*0.06))
        p.line(to: NSPoint(x: r.minX + s*0.72, y: r.midY + s*0.10))
        p.line(to: NSPoint(x: r.minX + s*0.50, y: r.midY + s*0.10))
        p.close()
        p.fill()
    }

    private static func clock(_ r: NSRect, _ s: CGFloat, _ lw: CGFloat) {
        let box = r.insetBy(dx: s*0.14, dy: s*0.14)
        stroked(NSBezierPath(ovalIn: box), lw)
        let c = NSPoint(x: box.midX, y: box.midY)
        let h = NSBezierPath()
        h.move(to: c); h.line(to: NSPoint(x: c.x, y: c.y + box.height*0.28))           // часовая
        h.move(to: c); h.line(to: NSPoint(x: c.x + box.width*0.22, y: c.y))            // минутная
        stroked(h, lw)
    }

    private static func calendar(_ r: NSRect, _ s: CGFloat, _ lw: CGFloat) {
        let box = NSRect(x: r.minX + s*0.14, y: r.minY + s*0.10, width: r.width - s*0.28, height: s*0.66)
        stroked(NSBezierPath(roundedRect: box, xRadius: s*0.06, yRadius: s*0.06), lw)
        // верхняя планка
        let bar = NSBezierPath()
        bar.move(to: NSPoint(x: box.minX, y: box.maxY - s*0.16)); bar.line(to: NSPoint(x: box.maxX, y: box.maxY - s*0.16))
        stroked(bar, lw*0.9)
        // кольца
        let rings = NSBezierPath()
        for f in [CGFloat(0.34), 0.66] {
            let x = box.minX + box.width*f
            rings.move(to: NSPoint(x: x, y: box.maxY - s*0.04)); rings.line(to: NSPoint(x: x, y: box.maxY + s*0.10))
        }
        stroked(rings, lw)
    }

    private static func bluetooth(_ r: NSRect, _ s: CGFloat, _ lw: CGFloat) {
        let cx = r.midX, top = r.maxY - s*0.12, bot = r.minY + s*0.12, mid = r.midY
        let w = s*0.18
        let p = NSBezierPath()
        p.move(to: NSPoint(x: cx, y: bot)); p.line(to: NSPoint(x: cx, y: top))
        p.line(to: NSPoint(x: cx + w, y: mid + s*0.19))
        p.line(to: NSPoint(x: cx - w, y: mid - s*0.19))
        p.move(to: NSPoint(x: cx - w, y: mid + s*0.19))
        p.line(to: NSPoint(x: cx + w, y: mid - s*0.19))
        p.line(to: NSPoint(x: cx, y: bot))
        stroked(p, lw)
    }

    private static func battery(_ r: NSRect, _ s: CGFloat, _ lw: CGFloat) {
        let body = NSRect(x: r.minX + s*0.08, y: r.minY + s*0.30, width: r.width - s*0.24, height: s*0.40)
        stroked(NSBezierPath(roundedRect: body, xRadius: s*0.06, yRadius: s*0.06), lw)
        // клемма
        NSBezierPath(roundedRect: NSRect(x: body.maxX + s*0.02, y: body.midY - s*0.08, width: s*0.07, height: s*0.16),
                     xRadius: s*0.02, yRadius: s*0.02).fill()
        // уровень
        let fill = body.insetBy(dx: s*0.07, dy: s*0.07)
        NSBezierPath(roundedRect: NSRect(x: fill.minX, y: fill.minY, width: fill.width*0.6, height: fill.height),
                     xRadius: s*0.02, yRadius: s*0.02).fill()
    }
}
