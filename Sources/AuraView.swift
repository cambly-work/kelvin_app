import AppKit

/// Живая аура состояния: мягкий радиальный цветной свет у верхней кромки поповера — «лицо»
/// термо-прибора. Цвет = тепловой режим (спокоен→бирюза, нагрузка→янтарь, жара→красный),
/// меняется МЕДЛЕННЫМ кросс-фейдом (≈1.6с) и только при устойчивой смене режима — без «гирлянды».
/// Лежит ПОД слоями контента (тинтует стекло сверху). Уважает «Уменьшить движение».
final class AuraView: NSView {
    private let grad = CAGradientLayer()

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        grad.type = .radial
        grad.startPoint = CGPoint(x: 0.5, y: 1.0)      // центр свечения — верх-середина
        grad.endPoint = CGPoint(x: 1.18, y: 0.05)      // радиус — к нижне-правому углу (эллипс сверху)
        layer?.addSublayer(grad)
    }

    /// СОЛИД-ТЁМНЫЙ ФОН прибора: перекрывает полупрозрачный системный материал, чтобы аура читалась
    /// как ЧЁТКОЕ свечение, а не грязно-коричневая муть. В тёмной теме — глубокий графит (макет #0e1317),
    /// в светлой — мягкая светлая подложка (чуть-чуть материала просвечивает для глубины).
    func applyBase(dark: Bool, opacity: CGFloat = 0.94) {
        let a = min(0.98, max(0.18, opacity))    // пол 0.18 — глубокое стекло (V5), но не полностью прозрачный (читаемость)
        layer?.backgroundColor = (dark
            ? NSColor(srgbRed: 0.050, green: 0.066, blue: 0.086, alpha: a)                    // тёмный прибор
            : NSColor(srgbRed: 0.92, green: 0.93, blue: 0.95, alpha: min(0.96, a * 0.96))).cgColor
    }

    override func layout() {
        super.layout()
        // Вид пришпилен ко ВСЕМ кромкам контейнера (не влияет на размер поповера), а свечение
        // держим ФИКС-полосой сверху (≈320pt) — иначе на высоком поповере радиус растянулся бы на всю панель.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let band: CGFloat = 400
        let h = min(band, bounds.height)
        grad.frame = CGRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)   // верхняя полоса (y-up)
        CATransaction.commit()
    }

    private func colors(_ c: NSColor) -> [CGColor] {
        // V3: тихий шёпот сверху (спека ≤8–15%), а не заливка — иначе цвет мутит стекло. Пик у самой
        // кромки быстро гаснет к 0. Спокойное состояние = еле-заметный бренд-тинт; жара = внятное свечение.
        [c.withAlphaComponent(0.16).cgColor,
         c.withAlphaComponent(0.055).cgColor,
         c.withAlphaComponent(0).cgColor]
    }

    /// Перекрасить ауру. animated — медленный кросс-фейд (смена режима); false — мгновенно (старт/тема).
    func setColor(_ c: NSColor, animated: Bool) {
        let to = colors(c)
        if animated, grad.colors != nil, !Motion.reduced {
            let a = CABasicAnimation(keyPath: "colors")
            a.fromValue = grad.colors
            a.toValue = to
            a.duration = 1.6
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            grad.add(a, forKey: "recolor")
        }
        grad.colors = to
    }
}
