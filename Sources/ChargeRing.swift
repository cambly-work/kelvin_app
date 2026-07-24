import AppKit
import QuartzCore

/// Кольцо заряда в духе Apple Health/Watch: серый трек + дуга прогресса с закруглением,
/// процент в центре. Дуга умеет «прорисовываться» при открытии (animateIn).
final class ChargeRing: NSView {
    /// Живой «маяк» кольца по направлению потока батареи (EnergySnapshot.battFlow):
    /// charging — яркая дуга + молния + свип + шиммер; discharging — обычная дуга;
    /// held — равновесие на адаптере (двигатель ловит, UI наконец показывает): приглушённая дуга, свип погашен.
    enum Mode { case charging, discharging, held }
    private let track = CAShapeLayer()
    private let prog = CAShapeLayer()
    private let marker = CAShapeLayer()                          // тик-метка лимита заряда на треке
    private let shimmer = CAGradientLayer()                     // сдержанный блик вдоль дуги на зарядке
    private let shimmerMask = CAShapeLayer()                    // маска блика — повторяет дугу прогресса
    private let pct = NSTextField(labelWithString: "—")
    private let bolt = CALayer()
    private(set) var charge = 0
    private var charging = false
    private var mode: Mode = .discharging
    private let lineW: CGFloat = 10        // V2: толще — кольцо-герой
    /// Альфа дуги в режиме .held (равновесие на адаптере): приглушённая, чтобы кольцо «успокоилось».
    private let heldAlpha: CGFloat = 0.6
    /// Доля лимита заряда (0…1) для метки-тика на кольце; nil — лимита нет, метка скрыта.
    private var limitFrac: CGFloat?

    var accent: NSColor = .systemGreen { didSet { applyAccent() } }
    /// Применить акцент к дуге/тени/молнии под текущую тему. Вынесено из didSet, чтобы
    /// viewDidChangeEffectiveAppearance мог перекрасить дугу СРАЗУ (а не ждать следующего set ~1с),
    /// иначе маркёр уже новой темы соседствовал бы со старотемной дугой.
    private func applyAccent() {
        // .held приглушает дугу (равновесие); прочие режимы — полный акцент. Это ПРЯМОЕ присвоение
        // strokeColor (как и было), НЕ CABasicAnimation на цвет — свип/set не задеваются.
        prog.strokeColor = (mode == .held ? accent.withAlphaComponent(heldAlpha) : accent).cgColor
        // V2 кольцо-герой: ЦВЕТНОЕ свечение в цвете дуги (как в макете) — не тусклая ink-тень.
        prog.shadowColor = accent.cgColor
        renderBolt()                                              // молния перекрашивается под акцент кольца
    }
    private let boltSide: CGFloat = 14

    override init(frame: NSRect) { super.init(frame: frame); commonInit() }
    required init?(coder: NSCoder) { super.init(coder: coder); commonInit() }

    private func commonInit() {
        wantsLayer = true
        layer?.masksToBounds = false
        for l in [track, prog] { l.fillColor = nil; l.lineCap = .round }
        prog.strokeEnd = 0
        prog.shadowOffset = .zero; prog.shadowRadius = 7; prog.shadowOpacity = 0.32    // V3 «спокойный прибор»: мягкая глубина, не неон-бум
        marker.fillColor = nil; marker.lineCap = .butt; marker.isHidden = true   // короткий радиальный тик лимита
        layer?.addSublayer(track)
        layer?.addSublayer(prog)
        layer?.addSublayer(marker)

        // Шиммер: узкий световой блик, маскированный дугой прогресса. Анимируем ПОЛОЖЕНИЕ градиента,
        // НЕ strokeColor (тот правит set ~:120). Виден только на зарядке, гасится Motion.reduced.
        shimmerMask.fillColor = nil; shimmerMask.lineCap = .round
        shimmer.isHidden = true
        shimmer.mask = shimmerMask
        layer?.addSublayer(shimmer)

        bolt.contentsGravity = .resizeAspect
        bolt.contentsScale = (window?.backingScaleFactor ?? 2)
        bolt.isHidden = true                                         // видна только при зарядке
        layer?.addSublayer(bolt)

        pct.font = Design.Font.numericHero        // V3: SF Pro Rounded (нативный «прибор»)
        pct.alignment = .center
        pct.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pct)
        NSLayoutConstraint.activate([
            pct.centerXAnchor.constraint(equalTo: centerXAnchor),
            pct.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
        ])
    }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        track.frame = bounds; prog.frame = bounds; marker.frame = bounds
        // молния — маленький значок под процентом, по центру внутренней области кольца
        bolt.frame = CGRect(x: bounds.midX - boltSide/2,
                            y: bounds.midY - boltSide - 11,
                            width: boltSide, height: boltSide)
        bolt.contentsScale = window?.backingScaleFactor ?? bolt.contentsScale
        let r = min(bounds.width, bounds.height)/2 - lineW/2 - 1
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        // полный круг, старт сверху (π/2), по часовой → strokeEnd рисует от 12 часов
        let path = CGMutablePath()
        path.addArc(center: c, radius: r, startAngle: .pi/2, endAngle: .pi/2 - 2 * .pi, clockwise: true)
        track.path = path; prog.path = path
        track.lineWidth = lineW; prog.lineWidth = lineW
        // шиммер-слой и его маска повторяют геометрию дуги (маска — линия по тому же пути)
        shimmer.frame = bounds
        shimmerMask.frame = bounds; shimmerMask.path = path; shimmerMask.lineWidth = lineW
        shimmerMask.strokeColor = NSColor.black.cgColor
        updateTrackColor()
        updateMarker()
        if mode == .charging, !Motion.reduced { startShimmer() }   // пересборка слоёв при ресайзе — перезапустить блик
    }

    /// Короткий радиальный тик на треке во фракции лимита — кольцо превращается в шкалу-датчик.
    /// Та же геометрия, что у трека (центр/радиус): тик перекрывает толщину линии чуть с запасом.
    private func updateMarker() {
        guard let frac = limitFrac else { marker.isHidden = true; return }
        marker.isHidden = false
        let r = min(bounds.width, bounds.height)/2 - lineW/2 - 1
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        // угол вдоль трека: старт сверху (π/2), по часовой на 2π·frac (как strokeEnd прогресса)
        let ang = CGFloat.pi/2 - 2 * .pi * frac
        let dir = CGPoint(x: cos(ang), y: sin(ang))
        let half = lineW/2 + 1.5                                  // тик чуть длиннее толщины линии
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x + dir.x * (r - half), y: c.y + dir.y * (r - half)))
        p.addLine(to: CGPoint(x: c.x + dir.x * (r + half), y: c.y + dir.y * (r + half)))
        marker.path = p
        marker.lineWidth = 2
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        marker.strokeColor = Design.Color.accentBright(dark).cgColor   // яркая бирюза — лимит виден поверх трека/дуги
    }

    /// Выставить долю лимита заряда (limit/100). `nil`/100 → метка скрыта (без лимита).
    func setLimit(_ percent: Int?) {
        let f: CGFloat? = (percent.map { $0 < 100 ? CGFloat(max(0, $0)) / 100 : nil } ?? nil)
        guard f != limitFrac else { return }
        limitFrac = f
        updateMarker()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateTrackColor()
        applyAccent()                               // дуга/тень/молния — перекрасить СРАЗУ, не ждать следующего set ~1с
        updateMarker()                              // тик лимита — accentBright тоже тема-зависим
        if mode == .charging, !Motion.reduced { startShimmer() }   // блик тоже тема-зависим — перекрасить под новую тему
    }
    private func updateTrackColor() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        track.strokeColor = Design.Color.trackFill(dark).cgColor
    }

    /// Живой «маяк»: режим выводится из стабильного потока батареи (battFlow с гистерезисом) и факта
    /// подключения к адаптеру. charging → яркая дуга + молния + свип + шиммер; idle на адаптере →
    /// .held (приглушённая дуга, свип/молния погашены — равновесие, которое двигатель ловит); иначе
    /// .discharging (цвет уровня заряда/расхода задаёт вызывающий — мы лишь рисуем).
    func set(charge: Int, charging: Bool, flow: BatteryFlow, plugged: Bool, accent: NSColor) {
        self.charge = charge; self.charging = charging
        switch flow {
        case .charging:    mode = .charging
        case .idle where plugged: mode = .held
        default:           mode = .discharging
        }
        self.accent = accent                                       // didSet применит heldAlpha по текущему mode
        pct.stringValue = "\(charge)%"
        pct.textColor = .labelColor
        // смена значения — неявная плавная анимация strokeEnd, под reduced — мгновенно (как HardwareView:104)
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.reduced ? 0 : Design.Motion.durValue)
        prog.strokeEnd = CGFloat(max(0, min(100, charge))) / 100
        CATransaction.commit()
        bolt.isHidden = (mode != .charging)                        // молния — только на зарядке (.held/разряд — без неё)
        renderBolt()
        applyBeacon()                                              // шиммер живёт только на зарядке (gate Motion.reduced)
    }

    /// Шиммер — единственный декоративный жест маяка: на зарядке запускаем, иначе гасим.
    /// Анимируем ПОЛОЖЕНИЕ градиента, не strokeColor (тот правит set/accent ~:120). Gate Motion.reduced.
    private func applyBeacon() {
        if mode == .charging, !Motion.reduced { startShimmer() } else { stopShimmer() }
    }

    /// Запуск сдержанного блика вдоль дуги (масштабированный градиент ездит по маске-дуге, ~1.0s).
    /// Идемпотентен: если блик уже идёт — не перезапускаем (layout зовёт его при ресайзе слоёв).
    private func startShimmer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        shimmer.isHidden = false
        // узкая световая полоса: прозрачно → блик → прозрачно (диагональ вдоль дуги)
        let glow = Design.Color.rimHighlight(dark, dark ? 0.55 : 0.42)
        shimmer.colors = [NSColor.clear.cgColor, glow.cgColor, NSColor.clear.cgColor]
        shimmer.locations = [0.0, 0.5, 1.0]
        shimmer.startPoint = CGPoint(x: 0, y: 0)
        shimmer.endPoint = CGPoint(x: 1, y: 1)
        guard shimmer.animation(forKey: "shimmerSweep") == nil else { return }   // уже бежит — не дёргаем
        // двигаем locations: блик проезжает дугу один раз за цикл, с паузой между проходами
        let a = CAKeyframeAnimation(keyPath: "locations")
        a.values = [[-0.6, -0.3, 0.0], [0.0, 0.5, 1.0], [1.0, 1.3, 1.6], [1.0, 1.3, 1.6]]
        a.keyTimes = [0.0, 0.45, 0.9, 1.0]
        a.duration = 1.0
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shimmer.add(a, forKey: "shimmerSweep")
    }
    private func stopShimmer() {
        shimmer.removeAnimation(forKey: "shimmerSweep")
        shimmer.isHidden = true
    }

    /// Рендерит `bolt.fill` в `bolt.contents`, тонируя под акцент кольца (на зарядке — яркая бирюза).
    private func renderBolt() {
        guard !bolt.isHidden,
              let base = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil) else { return }
        let img: NSImage
        if #available(macOS 12, *) {
            let cfg = NSImage.SymbolConfiguration(pointSize: boltSide, weight: .bold).applying(.init(paletteColors: [accent]))
            img = base.withSymbolConfiguration(cfg) ?? base
        } else {
            img = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: boltSide, weight: .bold)) ?? base
        }
        var r = CGRect(origin: .zero, size: img.size)
        bolt.contents = img.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }

    /// Прорисовать дугу с нуля (для появления поповера).
    func animateIn() {
        let frac = CGFloat(max(0, min(100, charge))) / 100
        prog.strokeEnd = frac
        guard mode != .held else { return }        // .held — равновесие: свип погашен, сразу конечная дуга
        guard !Motion.reduced else { return }      // «Уменьшить движение» — без свипа, сразу конечное состояние
        let a = CABasicAnimation(keyPath: "strokeEnd")
        a.fromValue = 0; a.toValue = frac
        a.duration = Design.Motion.durSweep   // B3: было 0.75 (durSweep — «прорисовка кольца», значение то же)
        a.timingFunction = Design.Motion.easeStandard   // свип читается «дороже» фирменной кривой
        prog.add(a, forKey: "sweep")
    }

    // MARK: VoiceOver — индикатор уровня заряда с контекстом (заряд/состояние/критичность)
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .levelIndicator }
    override func accessibilityLabel() -> String? { L("Заряд батареи") }
    override func accessibilityValue() -> Any? {
        let state = charging ? L(", зарядка") : ""
        let crit = (!charging && charge <= 20) ? L(", критический уровень") : ""
        return String(format: L("%d процентов"), charge) + state + crit
    }
}
