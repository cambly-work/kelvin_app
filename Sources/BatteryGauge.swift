import AppKit

/// Рисованный индикатор батареи: корпус, контакт, градиентная заливка ∝ заряду,
/// мягкое свечение и молния при зарядке. Цвет зависит от уровня/состояния.
final class BatteryGauge: NSView {
    private(set) var charge: Int = 0
    private(set) var charging = false

    func set(charge: Int, charging: Bool) {
        guard charge != self.charge || charging != self.charging else { return }
        self.charge = charge; self.charging = charging
        needsDisplay = true
    }

    private func levelColor() -> NSColor {
        if charging { return Design.Color.chargeTeal }   // бирюза (B3-токен, calibratedRGB — общий с ChargeTrack)
        switch charge {
        case ..<15: return Design.Color.chargeCrit       // красный
        case ..<35: return Design.Color.chargeWarn       // жёлтый
        default:    return Design.Color.chargeOK          // зелёный
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds.insetBy(dx: 2, dy: 2)
        let capW = b.width * 0.05
        let bodyH = b.height * 0.66
        let body = CGRect(x: b.minX, y: b.midY - bodyH/2, width: b.width - capW - 3, height: bodyH)
        let r = bodyH * 0.30
        let color = levelColor()

        // контакт
        let cap = CGRect(x: body.maxX + 2, y: body.midY - bodyH*0.22, width: capW, height: bodyH*0.44)
        NSColor.secondaryLabelColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: cap, xRadius: capW*0.4, yRadius: capW*0.4).fill()

        // корпус (контур)
        let outline = NSBezierPath(roundedRect: body, xRadius: r, yRadius: r)
        outline.lineWidth = 1.5
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke()
        outline.stroke()

        // заливка
        let inset = body.insetBy(dx: 2.5, dy: 2.5)
        let frac = max(0.04, min(1.0, CGFloat(charge) / 100))   // верхний кламп: заливка не вылезает за корпус
        let fillRect = CGRect(x: inset.minX, y: inset.minY, width: inset.width * frac, height: inset.height)
        let fr = max(1.0, r - 1.5)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: fr, yRadius: fr)

        NSGraphicsContext.saveGraphicsState()
        // свечение
        let glow = NSShadow(); glow.shadowColor = color.withAlphaComponent(0.7)
        glow.shadowBlurRadius = 8; glow.shadowOffset = .zero
        glow.set()
        let grad = NSGradient(starting: color.blended(withFraction: 0.18, of: .white) ?? color,
                              ending: color.blended(withFraction: 0.30, of: .black) ?? color)
        grad?.draw(in: fillPath, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // блик сверху
        let shineRect = CGRect(x: fillRect.minX, y: fillRect.midY, width: fillRect.width, height: fillRect.height/2)
        if fillRect.width > 3 {
            NSColor.white.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: shineRect.insetBy(dx: 1, dy: 1), xRadius: fr, yRadius: fr).fill()
        }

        // молния при зарядке
        if charging, let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: bodyH*0.7, weight: .black)
            let img = bolt.withSymbolConfiguration(cfg) ?? bolt
            let sz = img.size
            let p = CGRect(x: body.midX - sz.width/2, y: body.midY - sz.height/2, width: sz.width, height: sz.height)
            NSColor.white.set()
            img.isTemplate = true
            img.draw(in: p, from: .zero, operation: .sourceOver, fraction: 0.95)
        }
    }
}
