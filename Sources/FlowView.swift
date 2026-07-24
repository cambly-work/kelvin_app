import AppKit
import QuartzCore

/// Интерактивная анимированная схема энергопотоков.
/// Источники (адаптер/батарея) → система → потребители. По проводам бегут
/// светящиеся «дышащие» частицы тока (кол-во/скорость ∝ амперам). Узлы пульсируют
/// под нагрузкой. Наведение подсвечивает, клик — фокусирует поток, есть тултипы.
final class FlowView: NSView, NSViewToolTipOwner {

    private final class NodeUI {
        let key: String
        var rect: CGRect
        var accent: NSColor
        var pulse: Double = 0
        var appliedPulse: Double = -1     // последняя «корзина» нагрузки, под которую поставлен пульс
        let container = CALayer()
        let icon = CALayer()
        let title = CATextLayer()
        let value = CATextLayer()
        // — облик B «живой прибор»: мини-гейдж узла (дуга 270° как HeroGauge) + бар «доля в системе». —
        // Узел больше не карточка-чип, а ОСМЫСЛЕННЫЙ мини-прибор на едином стеклянном поле.
        let gaugeTrack = CAShapeLayer()   // дуга-трек (номинал адаптера / шкала потребителя); скрыт у источников без шкалы
        let gaugeFill = CAShapeLayer()    // заливка дуги — живой замер (отдача адаптера / нагрузка узла)
        // (бары «доля в системе» удалены V6: правило all-or-none — у «Прочее» ватт нет никогда,
        //  значит полоска была бы то у одних, то у других → читалась артефактом рендера)
        var appliedGaugeFrac: Double = .nan
        init(key: String, rect: CGRect, accent: NSColor) { self.key = key; self.rect = rect; self.accent = accent }
    }
    private struct WireGeom {
        var path: CGPath                 // var: при съезде узла провод переустремляется к новой цели
        var amps: Double
        var color: NSColor               // var: цвет провода АКБ меняется заряд↔разряд (teal↔green)
        let fromKey: String
        let toKey: String
        var start: CGPoint = .zero       // старт провода — чтобы дот не висел в (0,0) до анимации
        let glow = CAShapeLayer()        // мягкое свечение под проводом
        let grad = CAGradientLayer()     // цветной поток (нейтраль у хаба → цвет у узла)
        let core = CAShapeLayer()        // маска градиента — сама линия
        let socket = CAShapeLayer()      // «муфта»-воротник на ободе кольца: провод ВТЕКАЕТ в прибор, а не приклеен (V5)
        var hubPoint: CGPoint = .zero    // точка входа в обод (для дуги муфты и подрезки glow)
        var hubAtStart = false           // хаб-конец в НАЧАЛЕ пути (потребители; реверс-провод АКБ на заряде)
        var touchesRing = true           // конец сидит на ободе кольца (муфта/подрезка); стабы шины — нет (V6)
        var hoverTinted = false          // провод сейчас подсвечен бирюзой (наведён его узел) — чтобы не перекрашивать каждый restyle
    }

    private var snapshot = EnergySnapshot()
    /// Свежие ватты по компонентам железа (CPU/GPU/DRAM) — кладём прямо на узлы вместо плейсхолдеров.
    private var components: ComponentPower?
    private var nodes: [NodeUI] = []
    private var nodeViews: [FlowNodeView] = []   // прозрачные оверлеи: VoiceOver + клавиатура (мышь проходит насквозь)
    private var hasBattery = true        // false на десктопе — узел/провод «Батарея» не строим
    private var wires: [WireGeom] = []
    private var hovered: String?
    private var focusedKey: String?
    /// Колбэк живого разбора узла под курсором/в фокусе (одна строка) — для подписи под схемой.
    var detailSink: ((String?) -> Void)?
    /// Структурная сигнатура (наличие АКБ + набор шин) — её смена требует полной пересборки
    /// (другой НАБОР узлов нельзя анимировать). А смена ПОДКЛЮЧЕНИЯ/ЗАРЯДА (stateSig) —
    /// не пересобирает, а оживляет: выживший источник съезжает к центру, уходящий — отступает.
    private var structSig = ""
    private var stateSig = ""
    /// Провода, которые сейчас растворяются (отключённый адаптер) — restyle их не трогает,
    /// иначе вернул бы непрозрачность к 1 и сломал затухание.
    private var fadingOutWires: Set<String> = []
    /// Поколение затухания провода адаптера: completion сверяет его, чтобы дребезг plug/unplug
    /// (болтающийся MagSafe) не дропал провод досрочно чужим завершением.
    private var fadeGen = 0
    /// Первое обновление после появления вью (поповер открылся): топологию ставим МГНОВЕННО, без
    /// анимации — иначе смена подключения, случившаяся при закрытом поповере, дёрнулась бы прямо
    /// поверх анимации всплытия. Анимируем только ЖИВЫЕ переключения при открытом поповере.
    private var pendingFirstSync = true
    private let scale: CGFloat = 2

    // (Верхняя полоса-сводка «Адаптер · Система · АКБ» УДАЛЕНА в V6 по решению владельца:
    //  дублировала узлы схемы — 71 и 77 Вт стояли на экране дважды, а колонка «АКБ» висела
    //  НАД потребителями (пространственная ложь). Все три числа несёт сама схема.)

    // MARK: узел баланса — машинный стеклянный циферблат внутри хаба «Система»
    /// Кольцо БАЛАНСА мощности внутри node("Система").container — зеркалит грамматику ChargeRing
    /// (центр = иконка хаба, старт сверху, по часовой), но несёт ДРУГУЮ честную величину: мгновенный
    /// баланс «вход покрывает расход». TRACK — полный тонкий круг (ссылка «расход»). INPUT — дуга
    /// покрытия (вход/расход): сходится в полный круг, когда вход покрывает потребление. DEFICIT —
    /// зелёная дуга непокрытого остатка, ТОЛЬКО на разряде (вклад батареи = разрыв в кольце, закон
    /// сохранения как форма). TICK — волосок примирения PSTR-vs-баланс (только когда есть сырой PSTR).
    private let balRingTrack = CAShapeLayer()       // полный тонкий круг — ссылка «расход»
    private let balRingInput = CAShapeLayer()       // дуга покрытия входом (нейтраль→бирюза, сходится)
    private let balRingDeficit = CAShapeLayer()     // дуга дефицита (зелёная) — только разряд
    private let balRingTick = CAShapeLayer()         // волосок примирения PSTR↔баланс
    private let balRingFocusPt = CAShapeLayer()      // бирюзовая точка обода под наведённым потребителем
    private var builtBalRing = false
    private var appliedCoverage: Double = .nan       // последняя применённая доля покрытия (для покоя анимации)
    /// Хвост-дуга сейчас = «расхождение замеров» (нейтраль), а не дефицит-разряд (зелёный).
    private var deficitIsMismatch = false
    private let balRingLineW: CGFloat = 4            // V6: 3 → 4 — дуги покрытия/дефицита различимы, кольцо читается прибором
    private var appliedPulsePace: Double = .nan       // период «тик-пульса» обода (для покоя — не перезапускаем)

    // MARK: единое стеклянное поле + живая аура глубины (облик B «организм»)
    /// Единое стеклянное поле под всей схемой: растворяет рамки узлов-плиток и перегородки в ОДНО
    /// непрерывное поле — узлы сидят НА нём дискретными мини-приборами, не в отдельных карточках.
    private let field = CALayer()
    private var builtField = false
    /// ОБЩАЯ ШИНА потребителей (V6, поправка разведчика к К1): ствол от правой точки обода +
    /// вертикальный хребет вдоль столбца потребителей. Структура (шасси прибора), НЕ данные —
    /// рисуется тихой нейтралью фикс-толщины; данные несут стабы-отводы (толщина ∝ ток) и гейджи.
    private let busLine = CAShapeLayer()
    private let busSocket = CAShapeLayer()   // муфта-воротник ствола шины на ободе кольца
    /// Аура ГЛУБИНЫ сердца ∝ loadDelta: радиальное свечение из центра кольца, раздувается на рост
    /// нагрузки, опадает на спад. «Явно живое» — агрессивный коэффициент (делитель 6 Вт). Дедбэнд в
    /// слое данных (loadDelta=0 у равновесия) → у нуля аура статична, прибор не «дышит сам по себе».
    private let depthAura = CAGradientLayer()
    private var appliedAuraBucket: Double = .nan
    /// Последняя яркость — чтобы пинговать wipe только на РЕАЛЬНОЕ движение ползунка (дельта уже с дедбэндом).
    private var lastBrightnessPing: Float = -2
    /// Последняя «корзина» loadDelta — пульс-волну по руслам пускаем при пересечении корзины ВВЕРХ (скачок).
    private var appliedLoadBucket: Double = .nan

    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.masksToBounds = false }
    required init?(coder: NSCoder) { super.init(coder: coder); wantsLayer = true }
    override var isFlipped: Bool { false }

    // VoiceOver: вью — группа «Схема энергопотока», её элементы — узлы (FlowNodeView ниже).
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { L("Схема энергопотока") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited], owner: self))
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        structSig = ""                          // заставить пересобрать с новыми цветами (полная пересборка)
        update(snapshot, components: components, hasBattery: hasBattery)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // поповер открылся/переоткрылся — первую смену состояния показать мгновенно (не анимировать)
        if window != nil { pendingFirstSync = true }
    }

    /// Потребители в ПОКАЗЫВАЕМОМ порядке: CPU сверху (герой расхода), затем GPU, Память, Прочее.
    /// Порядок фиксированный (не live-сортировка по амперам) — узлы не скачут между тиками.
    private var orderedRails: [RailFlow] {
        let prio = ["CPU": 0, "GPU": 1, "Память": 2]
        return snapshot.rails.enumerated().sorted {
            (prio[$0.element.name] ?? 3, $0.offset) < (prio[$1.element.name] ?? 3, $1.offset)
        }.map { $0.element }
    }

    // MARK: обновление
    func update(_ s: EnergySnapshot, components c: ComponentPower? = nil, hasBattery: Bool = true) {
        snapshot = s
        self.components = c
        self.hasBattery = hasBattery
        // СТРУКТУРА: наличие АКБ + набор шин-потребителей — другой набор узлов нельзя анимировать.
        let struc = (hasBattery ? "B" : "-") + orderedRails.map { $0.name }.joined(separator: ",")
        // СОСТОЯНИЕ: подключение + НАПРАВЛЕНИЕ ПОТОКА батареи (с гистерезисом, не сырой charging) —
        // иначе сигнатура дёргалась бы заряд↔разряд каждую секунду у равновесия на адаптере (B1).
        let state = (s.plugged ? "A" : "-") + battFlowTag(s.battFlow)
        if struc != structSig || nodes.isEmpty {
            structSig = struc; stateSig = state
            rebuildLayout()
        } else if state != stateSig {
            let wasPlugged = stateSig.hasPrefix("A")
            stateSig = state
            // Оживляем ТОЛЬКО смену ПОДКЛЮЧЕНИЯ на НОУТЕ (есть АКБ — выживший источник съезжает к центру),
            // при живом открытом поповере. Чистую смену заряда (charging↔discharging — другой цвет/направление
            // провода АКБ), первое обновление после открытия поповера и десктоп (нет АКБ — анимировать нечего)
            // ставим МГНОВЕННО полной пересборкой — точное конечное состояние.
            if hasBattery, !pendingFirstSync, s.plugged != wasPlugged {
                animateState(toPlugged: s.plugged)
            } else {
                rebuildLayout()
            }
        }
        pendingFirstSync = false
        refreshValues()
        updateBalanceRing()  // кольцо баланса в хабе: покрытие входом + дефицит-разряд + тик примирения
        updateNodeGauges()   // мини-гейджи узлов-приборов (адаптер-резервуар/батарея/потребители)
        updateLiveAura()     // аура глубины сердца ∝ loadDelta (явно живая отзывчивость)
        syncFlows()          // СНАЧАЛА свежие амперы/толщины — волна ниже меряет по ним, не по прошлому тику
        updateLoadWave()     // пульс-волна по руслам на СКАЧОК нагрузки
        updateBrightnessPing()  // причинный wipe на движение ползунка яркости (отдельный канал)
        applyPulses()
        restyle()
    }

    // MARK: NET — знаковый поток батареи (для строки примирения systemDetail)
    /// + заряд / − разряд / 0 равновесие (из battFlow с гистерезисом, B1).
    private func netWatts() -> Double {
        switch snapshot.battFlow {
        case .charging:    return snapshot.battWatts
        case .discharging: return -snapshot.battWatts
        case .idle:        return 0
        }
    }
    /// Подпись NET со знаком: «+12 Вт» заряд / «−18 Вт» разряд / «0 Вт» равновесие.
    private func netLabel() -> String {
        let n = netWatts()
        if abs(n) < 0.5 { return String(format: L("%.0f Вт"), 0.0) }
        let sign = n > 0 ? "+" : "−"
        return sign + String(format: L("%.0f Вт"), abs(n))
    }

    // MARK: узел баланса — кольцо «вход покрывает расход» внутри хаба «Система»
    /// Центр кольца баланса в координатах контейнера хаба (= центр иконки) и радиус — фиксируем при
    /// пересборке хаба, обновления значений/темы перечитывают их без новой геометрии.
    private var balRingCenter: CGPoint = .zero
    private var balRingRadius: CGFloat = 0

    /// Прикрепляет слои кольца баланса к контейнеру хаба (зовётся из rebuildLayout при создании «Системы»).
    /// Геометрия (центр у иконки, полный круг сверху по часовой) — зеркало ChargeRing; материал —
    /// утопленный стеклянный циферблат: 1px rim-bevel + accentInk-тень (как prog.shadowColor в ChargeRing).
    private func attachBalanceRing(to container: CALayer, iconCenter: CGPoint) {
        // радиус — плотный циферблат вокруг иконки хаба, с запасом до краёв узкого контейнера
        let maxR = min(iconCenter.x, container.bounds.width - iconCenter.x) - 2
        balRingCenter = iconCenter
        balRingRadius = max(14, min(maxR, 26))     // крупное сердце (облик B)
        let c = balRingCenter, r = balRingRadius
        let ring = CGMutablePath()
        ring.addArc(center: c, radius: r, startAngle: .pi/2, endAngle: .pi/2 - 2 * .pi, clockwise: true)

        for l in [balRingTrack, balRingInput, balRingDeficit] {
            l.fillColor = nil
            l.path = ring
            l.lineWidth = balRingLineW
            l.frame = container.bounds
        }
        balRingInput.lineCap = .round
        balRingDeficit.lineCap = .round
        balRingTrack.lineCap = .round
        // материал: утопленный стеклянный циферблат —
        //   • внутренняя accentInk-тень на дуге входа (как prog.shadowColor у ChargeRing) — «врезано»;
        balRingInput.shadowColor = Design.Color.accentInk(isDark).cgColor
        balRingInput.shadowOffset = .zero
        balRingInput.shadowRadius = 2.5
        balRingInput.shadowOpacity = 0.5
        //   • 1px rim-bevel на треке: белёсый блик чуть НИЖЕ обода (shadowOffset вниз) — машинная кромка.
        balRingTrack.shadowColor = Design.Color.rimHighlight(isDark, isDark ? 0.5 : 0.55).cgColor
        balRingTrack.shadowOffset = CGSize(width: 0, height: -1)
        balRingTrack.shadowRadius = 0.5
        balRingTrack.shadowOpacity = 1
        balRingTick.fillColor = nil
        balRingTick.lineCap = .butt
        balRingTick.isHidden = true
        // точка обода под наведённым потребителем — маленький бирюзовый кружок на окружности кольца
        balRingFocusPt.strokeColor = nil
        balRingFocusPt.frame = container.bounds
        balRingFocusPt.isHidden = true
        // порядок: трек (низ) → дефицит → вход (бирюза поверх) → тик примирения → точка фокуса; rim-bevel — отдельным слоем
        container.addSublayer(balRingTrack)
        container.addSublayer(balRingDeficit)
        container.addSublayer(balRingInput)
        container.addSublayer(balRingTick)
        container.addSublayer(balRingFocusPt)
        builtBalRing = true
        appliedCoverage = .nan
        updateBalanceRing()
    }

    // MARK: единое стеклянное поле + мини-гейджи узлов (облик B)
    /// Единое стеклянное поле под всей областью узлов: surfaceFill + 1px rim + elevation. Создаём один
    /// раз, переразмеряем по geom() при каждой пересборке. Узлы рисуются НА нём, без своих карточек.
    private func buildField() {
        guard let g = geom() else { return }
        let frame = CGRect(x: 2, y: 1, width: g.W - 4, height: g.H - 2)
        if !builtField {
            builtField = true
            field.cornerRadius = Design.Radius.tile
            field.cornerCurve = .continuous
            field.masksToBounds = false
            if let host = layer { host.insertSublayer(field, at: 0) }   // под провода/узлы/шину
        }
        field.frame = frame
        // V4 «единая поверхность»: собственная заливка/кромка/тень поля СНЯТЫ — это был единственный
        // «ящик в ящике» поповера (paintCards глушит стекло всех плиток, а внутри Flow жила вторая
        // карточка → «блок не в стиле»). Слой остаётся хостом depthAura.
        field.backgroundColor = nil
        field.borderWidth = 0
        field.shadowOpacity = 0
        // аура глубины — внутри поля, радиальный градиент из центра кольца; раздувается под loadDelta
        if depthAura.superlayer == nil { field.addSublayer(depthAura) }
        depthAura.type = .radial
        depthAura.startPoint = CGPoint(x: 0.5, y: 0.5)
        depthAura.endPoint = CGPoint(x: 1, y: 1)
        depthAura.opacity = 0
    }

    /// Прикрепляет мини-гейдж узла (дуга 270°, грамматика HeroGauge) к контейнеру. Трек — шкала/номинал,
    /// заливка — живой замер. У адаптера БЕЗ номинала трек скрыт (честно: нет резервуара).
    private func attachNodeGauge(_ n: NodeUI, in rect: CGRect) {
        // слой = весь контейнер (как balRing/shareBar), путь — в АБСОЛЮТНЫХ координатах контейнера:
        // иначе frame=rect + путь у rect.mid дали бы двойное смещение и дуга ушла бы за край.
        for l in [n.gaugeTrack, n.gaugeFill] {
            l.fillColor = nil
            l.lineCap = .round
            l.frame = n.container.bounds
            n.container.addSublayer(l)
        }
        let r = rect.width/2 - 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let path = CGMutablePath()
        // дуга 270°: старт нижне-левый (225°) по часовой до нижне-правого (−45°) — как HeroGauge
        path.addArc(center: c, radius: r, startAngle: .pi * 1.25, endAngle: -.pi * 0.25, clockwise: true)
        n.gaugeTrack.path = path; n.gaugeFill.path = path
        // трек тише заливки (2 против 3) — шкала-ссылка шепчет, живой замер ведёт (оптический паритет с кольцом хаба)
        n.gaugeTrack.lineWidth = 2; n.gaugeFill.lineWidth = 3
        n.gaugeFill.strokeEnd = 0
        n.appliedGaugeFrac = .nan
    }

    /// Доля заливки мини-гейджа узла [0,1] + цвет. Семантика по узлу (адаптер-резервуар/батарея/потребитель).
    private func gaugeFrac(for key: String) -> (frac: Double, hasTrack: Bool, color: NSColor)? {
        let s = snapshot
        switch key {
        case "Адаптер":
            guard s.plugged else { return (0, false, neutralNode) }
            // РЕЗЕРВУАР: трек = номинал, заливка = живая отдача, зазор = ЗАПАС. Без номинала — нет трека.
            if let rated = s.adapterRatedWatts, rated > 0 {
                return (max(0, min(1, s.adapterWatts / Double(rated))), true, accent(for: "Адаптер"))
            }
            // честно гаснет резервуар: показываем замер как полную заливку без шкалы-резервуара
            return (min(1, s.adapterWatts / 100), false, accent(for: "Адаптер"))
        case "Батарея":
            // вклад/направление: заряд бирюзой, разряд зелёным; шкала /40 Вт (как loadFor)
            let frac = min(s.battWatts / 40, 1)
            return (s.battFlow == .idle ? 0 : frac, true, accent(for: "Батарея"))
        default:
            // потребитель: ватты (CPU/GPU) шкала /25, либо ток (Память/Прочее) шкала /1.2
            guard let r = s.rails.first(where: { $0.name == key }) else { return nil }
            let col = node(key).map { displayAccent(for: $0) } ?? neutralNode
            if let w = componentWatts(for: key) ?? r.watts {
                return (min(w / 25, 1), true, col)
            }
            return (min(r.amps / 1.2, 1), true, col)
        }
    }

    /// Обновляет мини-гейдж каждого узла-прибора (зовётся из update).
    private func updateNodeGauges() {
        for n in nodes where n.key != "Система" {
            guard let g = gaugeFrac(for: n.key) else {
                n.gaugeTrack.isHidden = true; n.gaugeFill.isHidden = true
                continue
            }
            n.gaugeTrack.isHidden = false; n.gaugeFill.isHidden = false
            n.gaugeTrack.strokeColor = (g.hasTrack ? Design.Color.trackFill(isDark)
                                                   : Design.Color.trackFill(isDark).withAlphaComponent(0.0)).cgColor
            n.gaugeFill.strokeColor = g.color.withAlphaComponent(isDark ? 0.95 : 0.9).cgColor
            animateGauge(n, to: g.frac)
        }
    }
    private func animateGauge(_ n: NodeUI, to frac: Double) {
        if Motion.reduced || abs(frac - n.appliedGaugeFrac) < 0.004 {
            n.gaugeFill.strokeEnd = CGFloat(frac); n.appliedGaugeFrac = frac; return
        }
        let from = n.gaugeFill.presentation()?.strokeEnd ?? n.gaugeFill.strokeEnd
        n.appliedGaugeFrac = frac
        n.gaugeFill.strokeEnd = CGFloat(frac)
        let a = CABasicAnimation(keyPath: "strokeEnd")
        a.fromValue = from; a.toValue = frac
        a.duration = Design.Motion.durValue; a.timingFunction = Design.Motion.easeStandard
        n.gaugeFill.add(a, forKey: "g")
    }

    /// Аура ГЛУБИНЫ сердца ∝ loadDelta (явно живая отзывчивость). Радиус/непрозрачность раздуваются на
    /// рост нагрузки, опадают на спад. Под reduced — статичный радиус ∝ |loadDelta| (величина, не движение).
    private func updateLiveAura() {
        guard builtField, let sys = node("Система") else { depthAura.opacity = 0; return }
        let delta = snapshot.loadDelta                          // знаковый, ПОСЛЕ дедбэнда (0 у равновесия)
        let amp = max(0, min(1, abs(delta) / 6.0))              // «явно живое»: делитель 6 Вт → полная амплитуда
        // центр ауры = центр кольца в координатах поля (field.frame смещён на (2,1) от вью)
        let c = hubRingCenter()
        let cx = c.x - field.frame.minX, cy = c.y - field.frame.minY
        let radius: CGFloat = 22 + CGFloat(amp) * 46            // 22…68 px
        // знак дельты задаёт цвет: рост → бирюза (накал), спад → нейтральный мягкий (остывание)
        let col = (delta >= 0 ? focusAccent : neutralNode).withAlphaComponent(isDark ? 0.30 : 0.22)
        let bucket = (Double(amp) * 12).rounded() / 12 * (delta >= 0 ? 1 : -1)
        let targetOpacity: Float = amp < 0.04 ? 0 : Float(0.25 + amp * 0.75)
        // позиционируем градиент как круг radius вокруг центра
        depthAura.frame = CGRect(x: cx - radius, y: cy - radius, width: radius*2, height: radius*2)
        depthAura.colors = [col.cgColor, col.withAlphaComponent(0).cgColor]
        depthAura.cornerRadius = radius
        _ = sys
        if Motion.reduced {
            depthAura.opacity = targetOpacity          // величина читается статикой, без анимации
            appliedAuraBucket = bucket
            return
        }
        guard abs(bucket - appliedAuraBucket) > 0.001 else { return }
        appliedAuraBucket = bucket
        let from = depthAura.presentation()?.opacity ?? depthAura.opacity
        depthAura.opacity = targetOpacity
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from; a.toValue = targetOpacity
        a.duration = Design.Motion.durSlow; a.timingFunction = Design.Motion.easeStandard
        depthAura.add(a, forKey: "aura")
    }

    /// Вход для дуги ПОКРЫТИЯ (бирюза) — мощность СЕТИ, которой адаптер покрывает расход.
    /// На разряде АКБ в покрытие НЕ входит: его долю показывает ЗЕЛЁНАЯ дуга дефицита (разрыв в кольце =
    /// вклад батареи, закон сохранения как форма). Иначе бирюза заняла бы весь круг и зелёному не осталось
    /// бы места — зелёная щель никогда бы не появилась, и кольцо лгало бы про источник.
    ///   • на адаптере (заряд/равновесие): вход = adapterWatts (адаптер ≥ расхода → кольцо сходится в бирюзу);
    ///   • на разряде / без адаптера: вход = adapterWatts (0 без сети) → остаток до 1 закрывает зелёный дефицит.
    private func inputWatts() -> Double { snapshot.adapterWatts }

    /// Обновляет кольцо баланса: дуга покрытия (вход/расход, сходится при полном покрытии), зелёная
    /// дуга дефицита (только разряд = вклад АКБ как разрыв в кольце) и волосок примирения PSTR↔баланс.
    private func updateBalanceRing() {
        guard builtBalRing else { return }
        let s = snapshot
        let consumption = max(s.systemWatts, 0.001)
        let coverage = max(0, min(1, inputWatts() / consumption))   // доля расхода, покрытая входом [0,1]

        refreshBalRingColors()
        animateCoverage(to: coverage)

        // DEFICIT: непокрытый остаток. На РАЗРЯДЕ — зелёная дуга (вклад батареи, закон сохранения).
        // На РАВНОВЕСИИ при подключённом адаптере разрыв кольца — НЕ вклад невидимого источника, а
        // расхождение независимых замеров (PDTR-вход и PSTR-расход — разные цепи/калибровки): рисуем
        // его ЧЕСТНО нейтральным полупрозрачным штрихом, а словами объясняет systemDetail/тултип хаба.
        if s.battFlow == .discharging, coverage < 0.999 {
            deficitIsMismatch = false
            balRingDeficit.isHidden = false
            // зелёный — тот же charge-семантический цвет, что у провода разряда (accent(for:"Батарея"))
            balRingDeficit.strokeColor = accent(for: "Батарея").withAlphaComponent(isDark ? 0.95 : 0.9).cgColor
            // дефицит занимает хвост круга ПОСЛЕ дуги входа: strokeStart = coverage … strokeEnd = 1
            balRingDeficit.strokeStart = CGFloat(coverage)
            balRingDeficit.strokeEnd = 1
        } else if s.plugged, coverage < 0.995 {
            deficitIsMismatch = true
            balRingDeficit.isHidden = false
            balRingDeficit.strokeColor = neutralNode.withAlphaComponent(isDark ? 0.35 : 0.3).cgColor
            balRingDeficit.strokeStart = CGFloat(coverage)
            balRingDeficit.strokeEnd = 1
        } else {
            balRingDeficit.isHidden = true
        }
        updateBalanceTick()
        updateObodPulse()
    }

    /// (Вечный «тик-пульс» кольца УДАЛЁН по решению владельца V5: кольцо «Система» — спокойный
    ///  статичный прибор без движущихся элементов. Разовый USB-пинг pulseObod остаётся — он событийный.)
    private func updateObodPulse() {
        guard builtBalRing else { return }
        let rings = [balRingTrack, balRingDeficit, balRingInput, balRingTick]
        rings.forEach { $0.removeAnimation(forKey: "obodPulse") }   // снять пульс у уже-построенных колец (миграция)
        appliedPulsePace = .nan
    }

    /// Трансформ масштаба ВОКРУГ центра балансного кольца (anchorPoint слоёв 0.5,0.5 →
    /// центр масштаба = смещение центра кольца относительно центра bounds). Копия математики
    /// из updateObodPulse, вынесенная в метод, чтобы её переиспользовал pulseObod.
    private func balRingScale(_ s: CGFloat) -> CATransform3D {
        let b = balRingTrack.bounds.size
        let dx = balRingCenter.x - b.width/2, dy = balRingCenter.y - b.height/2
        var t = CATransform3DMakeTranslation(dx, dy, 0)
        t = CATransform3DScale(t, s, s, 1)
        return CATransform3DTranslate(t, -dx, -dy, 0)
    }

    /// E1 — ТИК-ПУЛЬС обода на событии USB-подключения/отключения. Конечный (не бесконечный)
    /// импульс, КОМПОНУЕТСЯ с дыханием (forKey ≠ "obodPulse" → CA складывает трансформы).
    /// Амплитуда умеренная (sotto-voce инструмент): приход 1.028 «надувается», уход 0.984 тише.
    /// Гало-пинг (только connect) — транзиентный слой, самоудаляется (дисциплина dropWire).
    func pulseObod(connect: Bool) {
        guard builtBalRing, !Motion.reduced else { return }   // десктоп без кольца / reduced → no-op
        let rings = [balRingTrack, balRingDeficit, balRingInput, balRingTick]
        let tick = CAKeyframeAnimation(keyPath: "transform")
        if connect {
            tick.values = [balRingScale(1.0), balRingScale(1.028), balRingScale(1.0)]
            tick.keyTimes = [0, 0.32, 1.0]
            tick.duration = Design.Motion.durValue            // 0.45 — swell+settle
        } else {
            tick.values = [balRingScale(1.0), balRingScale(0.984), balRingScale(1.0)]
            tick.keyTimes = [0, 0.4, 1.0]
            tick.duration = Design.Motion.durSlow             // 0.42 — dip+recover (уход тише)
        }
        tick.timingFunction = Design.Motion.easeStandard
        tick.isRemovedOnCompletion = true; tick.fillMode = .removed
        rings.forEach { $0.add(tick, forKey: "obodTick") }    // ≠ "obodPulse" → дыхание не прерывается

        guard connect, let host = nodes.first(where: { $0.key == "Система" })?.container else { return }
        // PLUG-ДРАМА: заметный radial-wipe бирюзой из сердца (сильнее sotto-voce гало) — «энергия пришла».
        radialWipe(on: host, amplitude: 1.0, color: focusAccent, duration: 0.6)
        // гало-пинг: копия пути трека, расходится и гаснет. focusAccent (бирюза = взаимодействие),
        // НИКОГДА оранж (адаптер) / зелёный (батарея). Самоудаляется в completion.
        let halo = CAShapeLayer()
        halo.path = balRingTrack.path
        halo.frame = balRingTrack.frame
        halo.bounds = balRingTrack.bounds
        halo.position = balRingTrack.position
        halo.anchorPoint = balRingTrack.anchorPoint
        halo.fillColor = nil
        halo.strokeColor = focusAccent.cgColor
        halo.lineWidth = balRingLineW
        halo.opacity = 0
        host.addSublayer(halo)
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = balRingScale(1.0); grow.toValue = balRingScale(1.4)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.7; fade.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [grow, fade]
        g.duration = 0.55
        g.timingFunction = Design.Motion.easeOut
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak halo] in halo?.removeFromSuperlayer() }
        halo.add(g, forKey: "haloPing")
        CATransaction.commit()
    }

    // MARK: явно живая отзывчивость — пульс-волна нагрузки + причинный wipe яркости + plug-драма

    /// ПУЛЬС-ВОЛНА по руслам на СКАЧОК нагрузки: бегущее утолщение от сердца к потребителям. Пускаем
    /// при пересечении корзины loadDelta ВВЕРХ (рост) — кинестетика на нагрузку. Одна волна, конечная,
    /// самоудаляется. Под reduced — no-op (отклик читается величиной гейджей/ауры).
    private func updateLoadWave() {
        let delta = snapshot.loadDelta
        let bucket = (max(0, delta) / 3).rounded()           // корзина по 3 Вт роста
        defer { appliedLoadBucket = bucket }
        guard !Motion.reduced, !appliedLoadBucket.isNaN else { return }
        guard bucket > appliedLoadBucket, delta > 0 else { return }   // только РОСТ нагрузки, скачок вверх
        pulseLoadWave()
    }
    /// Бегущее утолщение core.lineWidth по руслам ОТ сердца к потребителям (направление A — кинестетика).
    private func pulseLoadWave() {
        for w in wires where w.fromKey == "Система" && !wireIsDead(w.amps) {   // живые стабы хаб→потребитель
            let base = wireWidth(w.amps)
            let a = CAKeyframeAnimation(keyPath: "lineWidth")
            a.values = [base, base * 1.7, base]
            a.keyTimes = [0, 0.45, 1.0]
            a.duration = 1.1                                 // конечная волна ~1с (flowDuration ушёл вместе с бегунками)
            a.timingFunction = Design.Motion.easeStandard
            a.isRemovedOnCompletion = true; a.fillMode = .removed
            w.core.add(a, forKey: "loadWave")
            // ореол синхронно толстеет — волна «дышит» по всему руслу
            let g = CAKeyframeAnimation(keyPath: "lineWidth")
            g.values = [base + 5, base * 1.7 + 7, base + 5]
            g.keyTimes = [0, 0.45, 1.0]
            g.duration = a.duration; g.timingFunction = a.timingFunction
            g.isRemovedOnCompletion = true; g.fillMode = .removed
            w.glow.add(g, forKey: "loadWave")
        }
    }

    /// Причинный канал ЯРКОСТИ: на реальное движение ползунка (brightnessDelta ≠ 0 после дедбэнда) —
    /// одиночный radial-wipe бирюзой по сердцу (заметный «толчок»), отдельно от темпа потока. Под reduced — no-op.
    private func updateBrightnessPing() {
        let db = snapshot.brightnessDelta
        guard db != 0 else { return }
        // не пинговать дважды на одно и то же значение (тик повторяет снапшот при churn)
        let b = snapshot.screenBrightness
        guard b != lastBrightnessPing else { return }
        lastBrightnessPing = b
        guard !Motion.reduced, builtField, let sys = node("Система")?.container else { return }
        let amp = max(0, min(1, Double(abs(db)) * 3))
        radialWipe(on: sys, amplitude: amp, color: focusAccent, duration: Design.Motion.durValue)
    }

    /// Radial-wipe: расходящееся бирюзовое кольцо из центра сердца (plug-драма / яркость-толчок).
    /// Транзиентный слой, самоудаляется. amplitude масштабирует яркость/охват.
    private func radialWipe(on host: CALayer, amplitude: Double, color: NSColor, duration: CFTimeInterval) {
        guard balRingRadius > 0 else { return }
        let ring = CAShapeLayer()
        ring.path = balRingTrack.path
        ring.frame = balRingTrack.frame
        ring.bounds = balRingTrack.bounds
        ring.position = balRingTrack.position
        ring.anchorPoint = balRingTrack.anchorPoint
        ring.fillColor = nil
        ring.strokeColor = color.withAlphaComponent(0.9).cgColor
        ring.lineWidth = balRingLineW
        ring.opacity = 0
        host.addSublayer(ring)
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = balRingScale(1.0)
        grow.toValue = balRingScale(1.0 + CGFloat(0.6 + amplitude * 0.9))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = Float(0.5 + amplitude * 0.45); fade.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [grow, fade]
        g.duration = duration
        g.timingFunction = Design.Motion.easeOut
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak ring] in ring?.removeFromSuperlayer() }
        ring.add(g, forKey: "wipe")
        CATransaction.commit()
    }

    // MARK: E1 — честный счётчик USB-периферии (БЕЗ ватт/тока — невозможно показать фейк)
    private let usbCountLayer = CATextLayer()
    private var builtUSBCount = false
    private var appliedUSBCount = -1
    private func buildUSBCount() {
        guard !builtUSBCount, layer != nil else { return }
        builtUSBCount = true
        usbCountLayer.font = Design.Font.microStat
        usbCountLayer.fontSize = Design.Font.microStat.pointSize
        usbCountLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
        usbCountLayer.contentsScale = scale
        usbCountLayer.alignmentMode = .right
        usbCountLayer.truncationMode = .end
        usbCountLayer.isHidden = true
        layer?.addSublayer(usbCountLayer)
    }
    /// Честная строка-счётчик: «USB-устройства: N». Имя первого — в tooltip-данных. БЕЗ ватт.
    func setUSBCount(_ n: Int, name: String?) {
        buildUSBCount()
        usbCountLayer.isHidden = (n <= 0)
        guard n > 0 else { appliedUSBCount = n; return }
        // моно-ЦИФРЫ: при 9→10 строка не прыгает шириной (живое число вкладки)
        usbCountLayer.string = NSAttributedString(string: String(format: L("USB-устройства: %d"), n),
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
                         .foregroundColor: NSColor.secondaryLabelColor])
        let W = bounds.width, H = bounds.height
        let w: CGFloat = 120
        usbCountLayer.frame = CGRect(x: W - 14 - w, y: H - 15, width: w, height: 11)   // верх-право, от края 14pt — не липнет к кромке поповера
        // крошечный kick при смене счётчика (грамматика arriveNode/moveNode), под !Motion.reduced
        if n != appliedUSBCount, appliedUSBCount >= 0, !Motion.reduced {
            let kick = CAKeyframeAnimation(keyPath: "transform.scale")
            kick.values = [1.0, 1.06, 1.0]; kick.keyTimes = [0, 0.4, 1.0]
            kick.duration = Design.Motion.durFast
            kick.timingFunction = Design.Motion.easeStandard
            usbCountLayer.add(kick, forKey: "usbKick")
        }
        appliedUSBCount = n
    }

    /// Угол слота потребителя на ободе. V6: все потребители питаются через ОБЩУЮ ШИНУ, выходящую
    /// из правой точки обода (0°) — точка фокуса честно показывает «ток уходит в шину здесь».
    private func consumerRingAngle(forKey key: String) -> CGFloat? {
        guard snapshot.rails.contains(where: { $0.name == key }) else { return nil }
        return 0
    }

    /// Цвета кольца баланса под фокус/тему (без переанимации покрытия — зовётся и из restyle на ховере).
    /// Цепочка фокуса (без новой машины состояний, по hovered/focusedKey):
    ///   • хаб «Система» или АДАПТЕР под курсором/в фокусе → дуга ВХОДА (его вклад) загорается бирюзой;
    ///   • БАТАРЕЯ на разряде → её сектор = ЗЕЛЁНАЯ дуга дефицита (ярче); на заряде сектора нет;
    ///   • ПОТРЕБИТЕЛЬ → бирюзовая ТОЧКА обода в его слоте веера, трек приглушается (вход остаётся нейтральным);
    ///   • иначе — дуга входа нейтральная, трек обычный.
    private func refreshBalRingColors() {
        guard builtBalRing else { return }
        let key = hovered ?? focusedKey
        let isHub = key == "Система"
        let isAdapter = key == "Адаптер"
        let isBatt = key == "Батарея"
        let isConsumer = key != nil && !isHub && !isAdapter && !isBatt

        // дуга ВХОДА: бирюза, когда светим хаб или адаптер (его вклад); в покое — светлее трека
        // (V6: явная дельта дуги покрытия — иначе кольцо при полном покрытии читалось простой окружностью)
        let inLit = isHub || isAdapter
        let inColor = inLit ? focusAccent : NSColor(white: isDark ? 0.62 : 0.35, alpha: 1)
        balRingInput.strokeColor = inColor.withAlphaComponent(isDark ? 0.95 : 0.9).cgColor
        balRingInput.shadowColor = Design.Color.accentInk(isDark).cgColor

        // дуга ДЕФИЦИТА (зелёная) ярче, когда светим батарею на разряде (её сектор);
        // нейтральный штрих «расхождение замеров» ховером не красится — это не источник
        if !balRingDeficit.isHidden {
            if deficitIsMismatch {
                balRingDeficit.strokeColor = neutralNode.withAlphaComponent(isDark ? 0.35 : 0.3).cgColor
            } else {
                let dischargeLit = isBatt || isHub
                let battC = accent(for: "Батарея")
                balRingDeficit.strokeColor = battC.withAlphaComponent(dischargeLit ? 1.0 : (isDark ? 0.95 : 0.9)).cgColor
            }
        }

        // трек: приглушаем остаток кольца, когда выделен потребитель (фокус — на его точке обода)
        let trackC = Design.Color.trackFill(isDark)
        balRingTrack.strokeColor = (isConsumer ? trackC.withAlphaComponent(isDark ? 0.6 : 0.55) : trackC).cgColor

        updateFocusPoint(forConsumer: isConsumer ? key : nil)
    }

    /// Бирюзовая точка на ободе под наведённым потребителем — «вот сюда уходит ток этого потребителя».
    private func updateFocusPoint(forConsumer key: String?) {
        guard let key, let ang = consumerRingAngle(forKey: key) else { balRingFocusPt.isHidden = true; return }
        let c = balRingCenter, r = balRingRadius
        let p = CGPoint(x: c.x + cos(ang) * r, y: c.y + sin(ang) * r)
        let rad: CGFloat = 3
        balRingFocusPt.path = CGPath(ellipseIn: CGRect(x: p.x - rad, y: p.y - rad, width: 2*rad, height: 2*rad), transform: nil)
        balRingFocusPt.fillColor = focusAccent.withAlphaComponent(isDark ? 0.95 : 0.9).cgColor
        balRingFocusPt.shadowColor = focusAccent.cgColor
        balRingFocusPt.shadowOffset = .zero
        balRingFocusPt.shadowRadius = 3
        balRingFocusPt.shadowOpacity = 0.9
        balRingFocusPt.isHidden = false
    }

    /// Плавно (как balFill) ведём дугу покрытия — PSTR/B0AP/PDTR независимы и дрожат у равновесия.
    private func animateCoverage(to coverage: Double) {
        balRingInput.strokeStart = 0
        if Motion.reduced || abs(coverage - appliedCoverage) < 0.005 {
            balRingInput.strokeEnd = CGFloat(coverage)
            appliedCoverage = coverage
            return
        }
        let from = balRingInput.presentation()?.strokeEnd ?? balRingInput.strokeEnd
        appliedCoverage = coverage
        balRingInput.strokeEnd = CGFloat(coverage)
        let a = CABasicAnimation(keyPath: "strokeEnd")
        a.fromValue = from
        a.toValue = coverage
        a.duration = Design.Motion.durSlow
        a.timingFunction = Design.Motion.easeStandard
        balRingInput.add(a, forKey: "cov")
    }

    /// Волосок примирения (1.5px) на ободе, где садится PSTR-замер относительно баланса-расхода.
    /// Малый зазор → тик у дуги (калибровано); расхождение → видимая щель. Рисуем ТОЛЬКО при наличии
    /// сырого PSTR (иначе примирять нечего — скрываем, честность). Угол = доля PSTR/баланс по тому же
    /// кругу (старт сверху, по часовой), как маркёр лимита в ChargeRing.
    private func updateBalanceTick() {
        let s = snapshot
        guard let measured = s.systemWattsRaw, measured > 0.05 else { balRingTick.isHidden = true; return }
        let balance = max(s.systemWattsBalance, 0.001)
        let frac = max(0, min(1, measured / balance))           // где садится замер на шкале баланса
        balRingTick.isHidden = false
        let c = balRingCenter, r = balRingRadius
        let ang = CGFloat.pi/2 - 2 * .pi * frac                  // тот же ход, что у дуги (сверху, по часовой)
        let dir = CGPoint(x: cos(ang), y: sin(ang))
        let half = balRingLineW/2 + 0.5     // V6: короткий волосок (был +1.5 — читался «царапиной» над числом)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: c.x + dir.x * (r - half), y: c.y + dir.y * (r - half)))
        p.addLine(to: CGPoint(x: c.x + dir.x * (r + half), y: c.y + dir.y * (r + half)))
        balRingTick.path = p
        balRingTick.lineWidth = 1.5
        balRingTick.strokeColor = Design.Color.rimHighlight(isDark, isDark ? 0.85 : 0.7).cgColor
    }

    // MARK: иконки/цвета
    /// Тег направления потока АКБ для сигнатуры состояния (стабилен — из battFlow с гистерезисом).
    private func battFlowTag(_ f: BatteryFlow) -> String {
        switch f { case .charging: return "c"; case .discharging: return "d"; case .idle: return "i" }
    }
    /// Провод АКБ направлен «к батарее» только при заряде; разряд/равновесие — от батареи к системе.
    private var battWireReversed: Bool { snapshot.battFlow == .charging }

    private func icon(for key: String) -> String {
        switch key {
        case "Адаптер": return "powerplug.fill"
        case "Батарея": return snapshot.battFlow == .charging ? "battery.100.bolt" : "battery.75"
        case "Система": return "macbook"
        case "Память":  return "memorychip.fill"
        case "CPU":     return "cpu.fill"
        case "GPU":     return "cpu"
        default:        return "ellipsis.circle.fill"
        }
    }
    /// Нейтральный цвет (Система/потребители/Прочее/отключённый адаптер) — токен Design (плотнее в свете).
    private var neutralNode: NSColor { Design.Color.neutralNode(isDark) }
    /// Бренд-бирюза взаимодействия — её надевает ТОЛЬКО узел в фокусе/под курсором (см. `displayAccent`).
    private var focusAccent: NSColor { Design.Color.accent(isDark) }
    /// Базовый цвет узла = СЕМАНТИКА данных (адаптер/АКБ) либо НЕЙТРАЛЬ. Декоративной «радуги» нет:
    /// потребители CPU/GPU/Память/Прочее — нейтральное стекло (бренд-закон Design.swift:7).
    private func accent(for key: String) -> NSColor {
        let c: NSColor
        switch key {
        case "Адаптер": guard snapshot.plugged else { return neutralNode }; c = .systemOrange
        // АКБ: заряд — бирюза, разряд — зелёный, равновесие (.idle) — нейтраль (спокойный провод, B1)
        case "Батарея":
            switch snapshot.battFlow {
            case .charging: c = .systemTeal
            case .discharging: c = .systemGreen
            case .idle: return neutralNode
            }
        default:        return neutralNode               // CPU/GPU/Память/Прочее/Система — нейтральные
        }
        // в светлой теме притемняем яркие акценты, иначе заголовки/обводка теряются на светлом фоне
        return isDark ? c : (c.blended(withFraction: 0.26, of: .black) ?? c)
    }
    /// Цвет, которым узел РИСУЕТСЯ прямо сейчас: нейтральный узел под курсором/в фокусе надевает
    /// бренд-бирюзу (интерактив), семантические узлы (адаптер/АКБ) свой цвет данных не меняют.
    private func displayAccent(for node: NodeUI) -> NSColor {
        let base = node.accent
        guard base == neutralNode else { return base }            // семантику данных не перекрашиваем
        let lit = node.key == hovered || node.key == focusedKey
        return lit ? focusAccent : base
    }
    private var cardFill: CGColor {
        (isDark ? NSColor(white: 1, alpha: 0.09) : NSColor(white: 0, alpha: 0.045)).cgColor
    }
    /// Заливка узла — мягкий accent-тинт (цветной стеклянный чип в духе Control Center).
    private func nodeFill(_ acc: NSColor) -> CGColor {
        Design.Color.glassTint(acc, isDark).cgColor   // в светлой теме насыщеннее, иначе сливается
    }
    /// Нейтральный конец провода (у хаба) — тихий серый. V6: нейтраль опущена (0.66 → 0.44) —
    /// яркость вкладки принадлежит ЦИФРАМ, а не проводке (закон «цвет = только данные»).
    private var neutralWire: NSColor { isDark ? NSColor(white: 0.44, alpha: 1) : NSColor(white: 0.5, alpha: 1) }
    /// Толщина провода ∝ ток, зажата 2.0–4.5 (V6: толщина — данные, не декорация).
    /// Ноль тока (< 0.05 А) — честный волосок 1px: мёртвый поток НЕ рисуется полнотелой трубой.
    private func wireWidth(_ amps: Double) -> CGFloat {
        amps < 0.05 ? 1.0 : CGFloat(min(2.0 + amps*1.4, 4.5))
    }
    /// Провод с «мёртвым» током — приглушается целиком (без glow, полупрозрачный).
    private func wireIsDead(_ amps: Double) -> Bool { amps < 0.05 }
    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    // MARK: раскладка
    /// Общие константы колонок + позиции узлов. Главное: позиции ИСТОЧНИКОВ зависят от `plugged`,
    /// поэтому одна и та же математика годится и для полной пересборки, и для анимации съезда к центру.
    private struct Geom {
        let W: CGFloat, H: CGFloat
        let pad: CGFloat = 6
        let leftW: CGFloat = 82, leftH: CGFloat = 48
        let sysW: CGFloat = 74, sysH: CGFloat = 84    // крупнее: сердце-кольцо «Система» по центру (облик B)
        let colW: CGFloat = 82
        let srcGap: CGFloat = 26
        let sep: CGFloat = 52       // V6: 66 → 52 — левый треугольник собран (дыра между АКБ и адаптером ушла)
        var cy: CGFloat { H/2 }
        var leftEdge: CGFloat { pad + leftW }
        var sysX: CGFloat { leftEdge + srcGap }
        var colX: CGFloat { W - colW - pad }
        var sysRect: CGRect { CGRect(x: sysX, y: cy - sysH/2, width: sysW, height: sysH) }
        /// АКБ: одинокий источник (отключён адаптер) — по центру; иначе ВЕРХНИЙ слот.
        /// FlowView НЕ flipped (ось Y вверх): «верх» = cy + sep. Прежний `cy − sep` писался во
        /// flipped-логике и ставил АКБ ВНИЗ, при том что её якорь на ободе — верхняя точка (130°):
        /// провод шёл наискось и КРЕСТИЛСЯ с проводом адаптера (жалоба владельца). Слот = якорь.
        func batt(plugged: Bool) -> CGRect {
            let yc = plugged ? cy + sep : cy
            return CGRect(x: pad, y: yc - leftH/2, width: leftW, height: leftH)
        }
        /// Адаптер: на десктопе (нет АКБ) — по центру; на ноуте — НИЖНИЙ слот (якорь обода 230°).
        func adapt(hasBattery: Bool) -> CGRect {
            let yc = hasBattery ? cy - sep : cy
            return CGRect(x: pad, y: yc - leftH/2, width: leftW, height: leftH)
        }
    }
    private func geom() -> Geom? {
        // V6: полоса-сводка удалена — схема занимает всю высоту вью
        let g = Geom(W: bounds.width, H: bounds.height)
        return (g.W > 60 && g.H > 60) ? g : nil
    }

    private func rebuildLayout() {
        nodes.forEach { $0.container.removeFromSuperlayer() }
        wires.forEach { w in
            w.glow.removeFromSuperlayer(); w.grad.removeFromSuperlayer(); w.socket.removeFromSuperlayer()
        }
        nodeViews.forEach { $0.removeFromSuperview() }
        nodes = []; wires = []; nodeViews = []
        removeAllToolTips()
        guard let g = geom() else { return }
        let H = g.H
        buildField()                 // единое стеклянное поле под схему (организм, не набор карточек)

        // Колонки: слева источники, по центру — хаб «Система», справа потребители.
        // Хаб смещён чуть влево, чтобы главный «веер» провода хаб→потребители был длиннее.
        let colW = g.colW
        let colX = g.colX
        // АКБ съезжает к центру, когда адаптер отключён (одинокий источник); адаптер по центру на десктопе.
        let batt  = g.batt(plugged: snapshot.plugged)
        let adapt = g.adapt(hasBattery: hasBattery)
        let sys = g.sysRect
        let rails = orderedRails
        let n = max(rails.count, 1)
        let gap: CGFloat = 12                             // больше воздуха между потребителями
        let rowH: CGFloat = min(54, (H - CGFloat(n-1)*gap)/CGFloat(n))
        let total = CGFloat(n)*rowH + CGFloat(n-1)*gap
        var y = (H + total)/2 - rowH

        var defs: [(String, CGRect)] = [("Адаптер", adapt), ("Система", sys)]
        if hasBattery { defs.append(("Батарея", batt)) }
        for r in rails { defs.append((r.name, CGRect(x: colX, y: y, width: colW, height: rowH))); y -= rowH + gap }

        for (key, rect) in defs {
            let acc = accent(for: key)
            let node = NodeUI(key: key, rect: rect, accent: acc)
            let c = node.container
            c.frame = rect
            c.cornerRadius = 14
            c.cornerCurve = .continuous
            // ОРГАНИЗМ-ПРИВИВКА: узлы БЕЗ рамки/фона/тени-карточки — они сидят на едином стеклянном
            // поле (field) как дискретные мини-приборы. Контейнер остаётся координатным носителем слоёв.
            c.backgroundColor = nil
            c.borderWidth = 0
            c.shadowColor = acc.cgColor; c.shadowOffset = .zero; c.shadowRadius = 9; c.shadowOpacity = 0

            if key == "Система" {
                // СЕРДЦЕ-ГЕРОЙ (V6): кольцо по центру контейнера. Внутри — крупный моно-расход
                // («77» 21pt + « Вт» шёпотом, атрибут-строку ставит refreshValues) и микроподпись
                // «система» под числом. Кольцо-циферблат само несёт идентичность хаба.
                let cy = rect.height / 2
                node.value.alignmentMode = .center
                node.value.contentsScale = scale
                node.value.truncationMode = .end
                node.value.frame = CGRect(x: 3, y: cy - 7, width: rect.width - 6, height: 26)
                node.value.isWrapped = false
                c.addSublayer(node.value)
                styleText(node.title, size: 8, weight: .regular, color: .tertiaryLabelColor)
                node.title.alignmentMode = .center
                node.title.string = L("система")
                // подпись зауженным слоем по центру — 8pt-текст не дотягивается до обода (хорда ≈44px)
                node.title.frame = CGRect(x: (rect.width - 48)/2, y: cy - 19, width: 48, height: 10)
                c.addSublayer(node.title)
                attachBalanceRing(to: c, iconCenter: CGPoint(x: rect.width/2, y: cy))
            } else {
                // мини-прибор: слева мини-гейдж (дуга 270°), справа заголовок над числом.
                // V6-иерархия ПРИБОРА: число ведёт (12pt semibold labelColor, моно-цифры),
                // имя шепчет (9pt regular secondaryLabel) — у прибора первична величина.
                let gz: CGFloat = min(rect.height - 6, 24)
                let gx: CGFloat = 3, gy = (rect.height - gz)/2
                attachNodeGauge(node, in: CGRect(x: gx, y: gy, width: gz, height: gz))
                let textX = gx + gz + 5
                let tw = rect.width - textX - 3
                // мини-иконка внутри гейджа (по центру дуги)
                let isz: CGFloat = 10
                node.icon.frame = CGRect(x: gx + (gz - isz)/2, y: gy + (gz - isz)/2 - 1, width: isz, height: isz)
                node.icon.contentsGravity = .resizeAspect
                node.icon.contentsScale = scale
                node.icon.contents = symbolCG(icon(for: key), acc, isz)
                c.addSublayer(node.icon)
                let titleH: CGFloat = 12, valH: CGFloat = 15
                let blockH = titleH + 1 + valH
                let topY = (rect.height + blockH)/2
                styleText(node.title, size: 9, weight: .regular, color: .secondaryLabelColor)
                node.title.frame = CGRect(x: textX, y: topY - titleH, width: tw, height: titleH)
                c.addSublayer(node.title)
                styleText(node.value, size: 12, weight: .semibold, color: .labelColor, mono: true)
                node.value.frame = CGRect(x: textX, y: topY - titleH - 1 - valH, width: tw, height: valH)
                node.value.isWrapped = false
                c.addSublayer(node.value)
            }

            layer?.addSublayer(c)
            nodes.append(node)
            addToolTip(rect, owner: self, userData: nil)

            // прозрачный оверлей для VoiceOver/клавиатуры (мышь идёт насквозь к FlowView)
            let nv = FlowNodeView(key: key)
            nv.frame = rect
            nv.onActivate = { [weak self] k in self?.focusNode(k) }
            addSubview(nv)
            nodeViews.append(nv)
        }
        // цепочка Tab между узлами
        for (i, nv) in nodeViews.enumerated() { nv.nextKeyView = nodeViews[(i + 1) % nodeViews.count] }

        let sysN = node("Система")!
        // оба источника втыкаются в ЛЕВУЮ полуокружность ОБОДА кольца (АКБ — верхний-левый сектор,
        // адаптер — нижний-левый): провод сходится в прибор-циферблат, а не упирается в плоскую грань.
        if hasBattery, let battN = node("Батарея") {
            let e = battWireEnds(battRect: battN.rect, sysRect: sysN.rect)
            addWire(from: e.from, to: e.to,
                    amps: abs(snapshot.battAmps), color: accent(for: "Батарея"),
                    reversed: battWireReversed, fromKey: "Батарея", toKey: "Система")
        }
        if snapshot.plugged, let adN = node("Адаптер") {
            let e = adapterWireEnds(adaptRect: adN.rect, sysRect: sysN.rect)
            addWire(from: e.from, to: e.to,
                    amps: snapshot.adapterAmps, color: .systemOrange, reversed: false, fromKey: "Адаптер", toKey: "Система")
        }
        // Потребители (V6, поправка разведчика к К1): не веер из четырёх труб, а ОБЩАЯ ШИНА —
        // ствол из правой точки обода (0°) → вертикальный хребет вдоль столбца, от хребта короткие
        // стабы-отводы к узлам. Стабы несут ДАННЫЕ (толщина ∝ ток), шина — структура (тихая нейтраль).
        buildBus(rails: rails, colX: colX)
        for r in rails {
            guard let cn = node(r.name) else { continue }
            addWire(from: CGPoint(x: busSpineX(colX: colX), y: cn.rect.midY), to: aIn(cn.rect),
                    amps: r.amps, color: accent(for: r.name), reversed: false,
                    fromKey: "Система", toKey: r.name, touchesRing: false)
        }
        // провода вставляются insertSublayer(at:0) → опускаются ПОД поле. Возвращаем поле в самый низ,
        // чтобы русла/узлы рисовались НА стекле (организм), а не под ним; шина — сразу над полем,
        // ПОД стабами/узлами (структура лежит глубже данных).
        if field.superlayer === layer { layer?.insertSublayer(field, at: 0) }
        if busLine.superlayer === layer {
            layer?.insertSublayer(busLine, at: 1)
            layer?.insertSublayer(busSocket, at: 2)
        }
    }

    /// x вертикального хребта шины — чуть левее столбца потребителей.
    private func busSpineX(colX: CGFloat) -> CGFloat { colX - 12 }

    /// Строит общую шину потребителей: ствол (обод → хребет на высоте центра кольца) + вертикальный
    /// хребет по центрам узлов + муфта-воротник ствола на ободе. Пустые rails — шина скрыта.
    private func buildBus(rails: [RailFlow], colX: CGFloat) {
        let centers = rails.compactMap { node($0.name)?.rect.midY }
        guard !centers.isEmpty else { busLine.path = nil; busSocket.path = nil; return }
        let spineX = busSpineX(colX: colX)
        let c = hubRingCenter()
        let p = CGMutablePath()
        p.move(to: ringPoint(angle: 0))
        p.addLine(to: CGPoint(x: spineX, y: c.y))
        if let top = centers.max(), let bot = centers.min(), top > bot {
            p.move(to: CGPoint(x: spineX, y: bot))
            p.addLine(to: CGPoint(x: spineX, y: top))
        }
        busLine.path = p
        busLine.fillColor = nil
        busLine.lineWidth = 2
        busLine.lineCap = .round
        busLine.strokeColor = neutralWire.withAlphaComponent(isDark ? 0.32 : 0.3).cgColor
        if busLine.superlayer == nil { layer?.insertSublayer(busLine, at: 0) }
        // муфта ствола на ободе — той же грамматики, что у проводов-источников
        let r = balRingRadius > 0 ? balRingRadius : 12
        let halfSpan = (busLine.lineWidth / 2 + 2) / r
        let arc = CGMutablePath()
        arc.addArc(center: c, radius: r, startAngle: -halfSpan, endAngle: halfSpan, clockwise: false)
        busSocket.path = arc
        busSocket.fillColor = nil
        busSocket.lineCap = .round
        busSocket.lineWidth = max(balRingLineW, busLine.lineWidth + 2.5)   // воротник по толщине ствола, не колодка
        busSocket.strokeColor = neutralWire.withAlphaComponent(isDark ? 0.5 : 0.45).cgColor
        if busSocket.superlayer == nil { layer?.insertSublayer(busSocket, above: busLine) }
    }

    // MARK: анимация подключения/отключения адаптера
    /// Подключили/отключили блок питания — НЕ пересобираем схему, а оживляем её: выживший источник
    /// (АКБ) съезжает к центру или возвращается в верхний слот, провод адаптера прорастает/втягивается,
    /// сам адаптер мягко набирает/теряет «энергию». Все геометрии-модели (node.rect, оверлеи VoiceOver,
    /// тултипы, путь провода) синхронно переезжают на финальные значения — поэтому конечное состояние
    /// идентично rebuildLayout для той же топологии (повторный структурный rebuild не «прыгнет»).
    private func animateState(toPlugged plugged: Bool) {
        guard hasBattery, let g = geom(), let sysN = node("Система") else { return }
        let reduce = Motion.reduced
        // PLUG/UNPLUG ДРАМАТИЧНО: бирюзовый radial-wipe из сердца на connect, втягивание на disconnect.
        if !reduce {
            if plugged { radialWipe(on: sysN.container, amplitude: 1.0, color: focusAccent, duration: 0.6) }
            else { radialWipe(on: sysN.container, amplitude: 0.5, color: neutralNode, duration: Design.Motion.durSlow) }
        }

        // 1) АКБ: новый прямоугольник (центр ↔ верхний слот) + синхронный переезд модели/оверлея/тултипа.
        if let battN = node("Батарея") {
            let target = g.batt(plugged: plugged)
            // кивок «теперь я несу всё» — только когда АКБ становится единственным источником (отключение)
            moveNode(battN, to: target, animated: !reduce, kick: !plugged)
            // провод АКБ переустремляется к хабу из новой точки; цвет/направление — под текущий заряд
            // (подключение часто включает зарядку: green→teal — перекрашиваем без пересборки).
            if let wi = wires.firstIndex(where: { $0.fromKey == "Батарея" }) {
                let battColor = accent(for: "Батарея")
                wires[wi].color = battColor
                applyWireColor(wires[wi], color: battColor)
                wires[wi].hoverTinted = false   // покраска затёрла тинт — restyle вернёт бирюзу, если узел под курсором
                let e = battWireEnds(battRect: target, sysRect: sysN.rect)
                retargetWire(wi, from: e.from, to: e.to, reversed: battWireReversed, animated: !reduce)
            }
        }

        // 2) Адаптер: провод прорастает (подключение) или втягивается+исчезает (отключение).
        if let adN = node("Адаптер") {
            if plugged {
                // быстрый ре-плаг: провод мог ещё таять (не удалён) — отменяем удаление и проявляем заново;
                // иначе строим новый у целевой геометрии. В обоих случаях — fade-in.
                fadingOutWires.remove("Адаптер")   // снимаем «удаляется» → restyle/syncFlows снова им владеют
                fadeGen += 1                       // висящий completion старого затухания больше не властен
                if !wires.contains(where: { $0.fromKey == "Адаптер" }) {
                    let e = adapterWireEnds(adaptRect: adN.rect, sysRect: sysN.rect)
                    addWire(from: e.from, to: e.to, amps: snapshot.adapterAmps,
                            color: .systemOrange, reversed: false, fromKey: "Адаптер", toKey: "Система")
                    if !reduce, let wi = wires.firstIndex(where: { $0.fromKey == "Адаптер" }) {
                        wires[wi].glow.opacity = 0; wires[wi].grad.opacity = 0   // старт невидимым (без вспышки)
                    }
                    // addWire кладёт слои insertSublayer(at:0) — НИЖЕ поля/шины; вернуть порядок стекла,
                    // как в rebuildLayout, иначе аура глубины накрывала бы новый провод у обода
                    if field.superlayer === layer { layer?.insertSublayer(field, at: 0) }
                    if busLine.superlayer === layer {
                        layer?.insertSublayer(busLine, at: 1)
                        layer?.insertSublayer(busSocket, at: 2)
                    }
                }
                if let wi = wires.firstIndex(where: { $0.fromKey == "Адаптер" }) {
                    fadeWire(wi, toVisible: true, animated: !reduce)
                }
                arriveNode(adN, animated: !reduce)
            } else {
                // отключение: провод тает и удаляется; сам узел остаётся (нейтральный, как в rebuildLayout)
                if let wi = wires.firstIndex(where: { $0.fromKey == "Адаптер" }) {
                    fadingOutWires.insert("Адаптер")
                    fadeGen += 1
                    let gen = fadeGen   // поколение ЭТОГО затухания: дребезг plug/unplug не даст чужому
                                        // completion досрочно дропнуть провод посреди нового растворения
                    fadeWire(wi, toVisible: false, animated: !reduce) { [weak self] in
                        guard let self, self.fadeGen == gen,
                              self.fadingOutWires.contains("Адаптер") else { return }   // ре-плаг/новое затухание отменили
                        self.fadingOutWires.remove("Адаптер")
                        self.dropWire(fromKey: "Адаптер")
                    }
                }
                recedeNode(adN, animated: !reduce)
            }
        }
    }

    /// Переезд узла на новый rect: анимируем слой-контейнер + ОБЯЗАТЕЛЬНО двигаем модель (node.rect),
    /// оверлей VoiceOver/клавиатуры и зону тултипа — иначе наведение/доступность рассинхронятся с картинкой.
    private func moveNode(_ n: NodeUI, to target: CGRect, animated: Bool, kick: Bool) {
        let newCenter = CGPoint(x: target.midX, y: target.midY)
        n.rect = target                                   // модель: hit-test, тултип, расчёты проводов
        if let i = nodes.firstIndex(where: { $0 === n }), i < nodeViews.count, nodeViews[i].key == n.key {
            nodeViews[i].frame = target                   // оверлей VoiceOver/клавиатуры едет следом
        } else if let nv = nodeViews.first(where: { $0.key == n.key }) {
            nv.frame = target
        }
        rebuildToolTips()                                 // зоны тултипов — по новым rect
        n.container.removeAnimation(forKey: "move")       // отменяем незавершённый переезд (быстрый ре-плаг)
        n.container.removeAnimation(forKey: "kick")
        if !animated {
            n.container.position = newCenter
            return
        }
        let from = n.container.presentation()?.position ?? n.container.position
        n.container.position = newCenter
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: from)
        move.toValue = NSValue(point: newCenter)
        move.duration = Design.Motion.durSlow
        move.timingFunction = Design.Motion.easeStandard
        n.container.add(move, forKey: "move")
        if kick {
            // «теперь я несу всё» — лёгкий уверенный кивок масштабом (~6%), не пружина
            let pop = CAKeyframeAnimation(keyPath: "transform.scale")
            pop.values = [1.0, 1.06, 1.0]
            pop.keyTimes = [0, 0.5, 1]
            pop.duration = 0.28
            pop.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            n.container.add(pop, forKey: "kick")
        }
    }

    /// Провод переустремляется к новым концам: кадр градиента фиксируем объединением старого и нового
    /// bbox (иначе маска «прыгнет»), морфим path у glow и core, обновляем модель, после — пересоздаём
    /// частицы под новый путь (до этого они бегут по старому — короткий хвост, допустимо).
    private func retargetWire(_ i: Int, from: CGPoint, to: CGPoint, reversed: Bool, animated: Bool) {
        let newPath = wirePath(from: from, to: to, reversed: reversed)
        let oldPath = wires[i].path
        let lw = wireWidth(wires[i].amps)
        let union = oldPath.boundingBoxOfPath.union(newPath.boundingBoxOfPath).insetBy(dx: -lw - 8, dy: -lw - 8)
        wires[i].path = newPath
        wires[i].start = reversed ? to : from
        wires[i].hubPoint = (wires[i].toKey == "Система") ? to : from
        wires[i].hubAtStart = reversed || (wires[i].fromKey == "Система")
        if !animated {
            applyWireGeometry(&wires[i], path: newPath, bbFrame: union)
            return
        }
        // снимаем старые path-значения слоёв ДО морфинга (для fromValue)
        let glowFrom = wires[i].glow.presentation()?.path ?? oldPath
        var tOld = CGAffineTransform(translationX: -union.minX, y: -union.minY)
        let coreOldLocal = oldPath.copy(using: &tOld) ?? oldPath
        applyWireGeometry(&wires[i], path: newPath, bbFrame: union)   // ставит финальные path + кадр
        let key = wires[i].fromKey
        // обе анимации path — в одной транзакции (морф целен; частиц больше нет — V5)
        _ = key
        CATransaction.begin()
        let glowAnim = CABasicAnimation(keyPath: "path")
        glowAnim.fromValue = glowFrom
        glowAnim.toValue = newPath
        glowAnim.duration = Design.Motion.durSlow
        glowAnim.timingFunction = Design.Motion.easeStandard
        wires[i].glow.add(glowAnim, forKey: "morph")
        let coreAnim = CABasicAnimation(keyPath: "path")
        coreAnim.fromValue = coreOldLocal
        coreAnim.toValue = wires[i].core.path
        coreAnim.duration = Design.Motion.durSlow
        coreAnim.timingFunction = Design.Motion.easeStandard
        wires[i].core.add(coreAnim, forKey: "morph")
        CATransaction.commit()
    }

    /// Проявление/растворение провода (glow+grad) при подключении/отключении адаптера.
    private func fadeWire(_ i: Int, toVisible: Bool, animated: Bool, done: (() -> Void)? = nil) {
        let target: Float = toVisible ? 1 : 0
        let layers: [CALayer] = [wires[i].glow, wires[i].grad, wires[i].socket]
        if !animated {
            layers.forEach { $0.opacity = target }
            done?()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        for l in layers {
            let from = l.presentation()?.opacity ?? (toVisible ? 0 : l.opacity)
            l.opacity = target
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = from
            a.toValue = target
            a.duration = Design.Motion.durBase
            a.timingFunction = toVisible ? Design.Motion.easeIn : Design.Motion.easeOut
            l.add(a, forKey: "fade")
        }
        CATransaction.commit()
    }

    /// Узел «прибывает» (адаптер подключили): мягкое появление energy — короткий поп масштаба.
    private func arriveNode(_ n: NodeUI, animated: Bool) {
        n.container.removeAnimation(forKey: "kick")
        guard animated else { return }
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.92, 1.04, 1.0]
        pop.keyTimes = [0, 0.6, 1]
        pop.duration = 0.30
        pop.beginTime = CACurrentMediaTime() + 0.06          // чип «приземляется» чуть позже, чем стартует провод
        pop.fillMode = .backwards
        pop.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        n.container.add(pop, forKey: "kick")
    }

    /// Узел «теряет энергию» (адаптер отключили): едва заметный провал масштаба и возврат.
    private func recedeNode(_ n: NodeUI, animated: Bool) {
        n.container.removeAnimation(forKey: "kick")
        guard animated else { return }
        let dip = CAKeyframeAnimation(keyPath: "transform.scale")
        dip.values = [1.0, 0.95, 1.0]
        dip.keyTimes = [0, 0.5, 1]
        dip.duration = 0.26
        dip.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        n.container.add(dip, forKey: "kick")
    }

    /// Удаляет слои провода из суперслоя и из модели (после растворения при отключении).
    private func dropWire(fromKey: String) {
        guard let i = wires.firstIndex(where: { $0.fromKey == fromKey }) else { return }
        let w = wires[i]
        w.glow.removeFromSuperlayer(); w.grad.removeFromSuperlayer(); w.socket.removeFromSuperlayer()
        wires.remove(at: i)
    }

    /// Перестроить зоны тултипов под текущие node.rect (после переезда узлов).
    private func rebuildToolTips() {
        removeAllToolTips()
        for n in nodes { addToolTip(n.rect, owner: self, userData: nil) }
    }

    private func aOut(_ r: CGRect) -> CGPoint { CGPoint(x: r.maxX, y: r.midY) }
    private func aIn(_ r: CGRect) -> CGPoint { CGPoint(x: r.minX, y: r.midY) }

    // MARK: концы проводов на ОБОДЕ кольца баланса
    /// Центр кольца баланса в координатах ВЬЮ (= центр хаба + локальный центр кольца). Слои кольца —
    /// сублои контейнера хаба, поэтому локальный balRingCenter сдвигаем на origin прямоугольника хаба.
    private func hubRingCenter() -> CGPoint {
        guard let sys = node("Система") else { return .zero }
        return CGPoint(x: sys.rect.minX + balRingCenter.x, y: sys.rect.minY + balRingCenter.y)
    }
    /// Точка на окружности обода под углом θ (мат. отсчёт от +x, CCW; +y — вверх, как у вью).
    /// Все хаб-концы проводов «втыкаются» в обод кольца, а не в плоскую грань — провод сходится в прибор.
    private func ringPoint(angle: CGFloat) -> CGPoint {
        let c = hubRingCenter(), r = balRingRadius > 0 ? balRingRadius : 12
        return CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r)
    }
    /// Угол слота ИСТОЧНИКА на ЛЕВОЙ полуокружности обода: АКБ — верхний-левый (~135°),
    /// адаптер — нижний-левый (~225°); на десктопе без АКБ адаптер по центру левой грани (180°).
    private func sourceRingAngle(_ key: String) -> CGFloat {
        switch key {
        case "Батарея": return .pi * 0.72                       // ~130° — верхний левый сектор
        case "Адаптер": return hasBattery ? .pi * 1.28 : .pi    // ~230° / ровно влево на десктопе
        default:        return .pi
        }
    }
    /// Концы провода АКБ→Система: выход из правой грани АКБ → точка на ободе кольца (верхний-левый сектор).
    private func battWireEnds(battRect: CGRect, sysRect: CGRect) -> (from: CGPoint, to: CGPoint) {
        (aOut(battRect), ringPoint(angle: sourceRingAngle("Батарея")))
    }
    /// Концы провода Адаптер→Система: выход из правой грани адаптера → точка на ободе (нижний-левый сектор;
    /// на десктопе без АКБ — ровно левая точка обода).
    private func adapterWireEnds(adaptRect: CGRect, sysRect: CGRect) -> (from: CGPoint, to: CGPoint) {
        (aOut(adaptRect), ringPoint(angle: sourceRingAngle("Адаптер")))
    }

    private func node(_ key: String) -> NodeUI? { nodes.first { $0.key == key } }

    /// Кривая провода: move + ОДИН кубический сегмент (всегда одинаковая структура — поэтому
    /// морфинг пути «path» при съезде узла валиден: одинаковое число контрольных точек).
    private func wirePath(from: CGPoint, to: CGPoint, reversed: Bool) -> CGPath {
        let a = reversed ? to : from, b = reversed ? from : to
        let p = CGMutablePath()
        p.move(to: a)
        let mx = (a.x + b.x)/2
        p.addCurve(to: b, control1: CGPoint(x: mx, y: a.y), control2: CGPoint(x: mx, y: b.y))
        return p
    }
    private func addWire(from: CGPoint, to: CGPoint, amps: Double, color: NSColor, reversed: Bool, fromKey: String, toKey: String, touchesRing: Bool = true) {
        let a = reversed ? to : from
        let p = wirePath(from: from, to: to, reversed: reversed)
        var w = WireGeom(path: p, amps: amps, color: color, fromKey: fromKey, toKey: toKey, start: a)
        w.hubPoint = (toKey == "Система") ? to : from
        w.hubAtStart = reversed || (fromKey == "Система")
        w.touchesRing = touchesRing
        w.glow.fillColor = nil
        w.glow.lineCap = .round
        w.glow.shadowRadius = 4
        w.glow.shadowOffset = .zero
        layer?.insertSublayer(w.glow, at: 0)
        // градиент-поток: нейтрально-мягкий у хаба → насыщенный у цветного узла
        w.core.fillColor = nil
        w.core.strokeColor = NSColor.black.cgColor      // маска — важна только альфа
        w.core.lineCap = .round
        w.grad.mask = w.core
        w.grad.startPoint = CGPoint(x: 0, y: 0.5)
        w.grad.endPoint   = CGPoint(x: 1, y: 0.5)
        layer?.insertSublayer(w.grad, above: w.glow)
        // муфта: утолщённая дуга по окружности обода вокруг точки входа — «фитинг», закрывающий шов
        w.socket.fillColor = nil
        w.socket.lineCap = .round
        layer?.insertSublayer(w.socket, above: w.grad)
        applyWireColor(w, color: color)
        wires.append(w)
        applyWireGeometry(&wires[wires.count - 1], path: p, bbFrame: nil)
    }

    /// Цвет провода: ореол-свечение + градиент потока (нейтраль у хаба → насыщенный у цветного узла).
    /// Вынесено отдельно, т.к. провод АКБ перекрашивается при заряд↔разряд (teal↔green) без пересборки.
    private func applyWireColor(_ w: WireGeom, color: NSColor) {
        // V6: свечение вдвое тише — яркость вкладки у цифр, не у проводки
        w.glow.strokeColor = color.withAlphaComponent(isDark ? 0.10 : 0.08).cgColor
        w.glow.shadowColor = color.cgColor
        w.glow.shadowOpacity = isDark ? 0.25 : 0.12
        let near = neutralWire.withAlphaComponent(isDark ? 0.42 : 0.4)   // конец у хаба — шёпот
        let far  = color.withAlphaComponent(0.95)                        // конец у цветного узла
        // у провода левый конец = меньший x: источник (слева)→хаб; хаб (слева)→потребитель (справа).
        // Полная яркость — только ПОСЛЕДНИЕ ~35% у узла (три стопа), остальное — тихая нейтраль.
        let isSource = (w.toKey == "Система")
        w.grad.colors = isSource ? [far.cgColor, near.cgColor, near.cgColor]
                                 : [near.cgColor, near.cgColor, far.cgColor]
        w.grad.locations = isSource ? [0, 0.35, 1] : [0, 0.65, 1]
        w.socket.strokeColor = near.cgColor          // муфта того же нейтрального конца, что провод у хаба
    }

    /// Узловой конец провода (не-хаб): для источника — fromKey, для потребителя — toKey.
    private func wireNodeEnd(_ w: WireGeom) -> String { w.toKey == "Система" ? w.fromKey : w.toKey }

    /// Подсветка наведённого провода: провод узла под курсором надевает ТОТ ЖЕ цвет, что и сам узел
    /// (displayAccent: нейтральный потребитель/покоящаяся АКБ → бирюза; семантический адаптер/АКБ — свой
    /// цвет данных не меняет). Не-наведённые провода держат базовый цвет. Перекрашиваем ТОЛЬКО на смене
    /// состояния (флаг hoverTinted) — без churn каждый restyle.
    private func applyHoverTint(_ i: Int) {
        let w = wires[i]
        let nodeEnd = wireNodeEnd(w)
        // тинтуем, только если у узла-конца нейтральная база (его displayAccent даёт бирюзу под курсором);
        // семантический провод (адаптер-оранж / АКБ заряд-разряд) на ховере цвет не меняет — бренд-закон.
        let neutralEnd = (node(nodeEnd)?.accent == neutralNode) || accent(for: nodeEnd) == neutralNode
        let wantTint = (nodeEnd == hovered) && neutralEnd
        guard wantTint != w.hoverTinted else { return }
        wires[i].hoverTinted = wantTint
        applyWireColor(w, color: wantTint ? focusAccent : w.color)
    }

    /// Геометрия одного провода под путь `path`: glow.path в координатах вью, маска-ядро в локальных
    /// координатах градиента, толщина ∝ ток. `bbFrame` ≠ nil фиксирует кадр градиента (объединение
    /// старого и нового bbox) — это нужно при морфинге пути, иначе кадр прыгал бы вместе с маской.
    private func applyWireGeometry(_ w: inout WireGeom, path p: CGPath, bbFrame: CGRect?) {
        let lw = wireWidth(w.amps)
        w.glow.path = p
        w.glow.lineWidth = lw + 5
        // подрезаем glow у хаб-конца: round-cap выпирал ВНУТРЬ кольца пятном («приклеено»).
        // Только у проводов, сидящих на ободе (touchesRing); стабы шины кольца не касаются.
        let bbox = p.boundingBoxOfPath
        let approxLen = max(1, hypot(bbox.width, bbox.height) * 1.15)
        let cut = w.touchesRing ? min(0.25, Double((lw + 5) / 2 / approxLen)) : 0
        let hubAtStart = w.hubAtStart
        w.glow.strokeStart = hubAtStart ? CGFloat(cut) : 0
        w.glow.strokeEnd = hubAtStart ? 1 : CGFloat(1 - cut)
        let bb = bbFrame ?? bbox.insetBy(dx: -lw - 8, dy: -lw - 8)
        var t = CGAffineTransform(translationX: -bb.minX, y: -bb.minY)
        let local = p.copy(using: &t) ?? p
        w.core.path = local
        w.core.lineWidth = lw
        w.grad.frame = bb
        // муфта-дуга на ободе: центр/радиус кольца, ±(полширины провода + 2pt) вдоль окружности.
        // Стабы шины (touchesRing=false) муфты не носят — их «муфта» = busSocket ствола.
        let c = hubRingCenter()
        let r = balRingRadius > 0 ? balRingRadius : 12
        if w.touchesRing, c != .zero {
            let ang = atan2(w.hubPoint.y - c.y, w.hubPoint.x - c.x)
            let halfSpan = (lw / 2 + 2) / r
            let arc = CGMutablePath()
            arc.addArc(center: c, radius: r, startAngle: ang - halfSpan, endAngle: ang + halfSpan, clockwise: false)
            w.socket.path = arc
            // муфта следует толщине СВОЕГО провода (толщина = данные), а не фикс-колодка;
            // у мёртвого волоска муфты нет — жирный воротник на 1px-нити ломал грамматику
            w.socket.lineWidth = max(balRingLineW, lw + 2.5)
            w.socket.isHidden = wireIsDead(w.amps)
        } else {
            w.socket.path = nil
        }
    }

    // MARK: индикация потока — ОДИН спокойный «бегунок» на провод (не россыпь частиц).
    // Скорость задаётся МОДУЛЕМ NET (поток батареи): тихо при равновесии, заметнее под нагрузкой.
    // (Бегунки-частицы УДАЛЕНЫ по решению владельца V5: «убрать движущиеся элементы, неуместно».
    //  Кинетику потока несёт только живая ТОЛЩИНА русла (syncFlows) — спокойный прибор.)
    private func ampsForWire(_ w: WireGeom) -> Double {
        switch w.fromKey {
        case "Батарея": return abs(snapshot.battAmps)
        case "Адаптер":
            // ЧЕСТНЫЙ поток адаптера — от ИЗМЕРЕННОЙ отдачи (PDTR ватт), а не от сырого ID0R,
            // который на этой модели врёт: при реальных 60 Вт adapterAmps≈0 давал тонкий «мёртвый»
            // провод рядом с числом «60 Вт». Эквивалентный ток = ватты / напряжение шины.
            let v = snapshot.adapterVolts > 5 ? snapshot.adapterVolts : 20   // PD-шина ~20 В, если В неизвестно
            return snapshot.adapterWatts > 0.5 ? snapshot.adapterWatts / v : 0
        default:        return snapshot.rails.first { $0.name == w.toKey }?.amps ?? 0
        }
    }
    private func syncFlows() {
        for i in wires.indices {
            if fadingOutWires.contains(wires[i].fromKey) { continue }   // растворяемый провод не трогаем
            let amps = ampsForWire(wires[i])
            wires[i].amps = amps
            let lw = wireWidth(amps)
            wires[i].core.lineWidth = lw            // живая толщина русла под ток — единственная кинетика потока (V5)
            wires[i].glow.lineWidth = lw + 5
            if wires[i].touchesRing {
                // муфта живёт вместе с проводом: толщина следом за током, у волоска — скрыта
                wires[i].socket.lineWidth = max(balRingLineW, lw + 2.5)
                wires[i].socket.isHidden = wireIsDead(amps)
            }
        }
    }

    // MARK: пульсация узлов под нагрузкой
    private func loadFor(_ key: String) -> Double {
        let s = snapshot
        switch key {
        case "Батарея": return min(s.battWatts/40, 1)
        case "Адаптер": return s.plugged ? min(s.adapterWatts/40, 1) : 0
        case "Система": return min(s.systemWatts/40, 1)
        default:        return min((s.rails.first { $0.name == key }?.amps ?? 0)/1.2, 1)
        }
    }
    private func applyPulses() {
        for node in nodes { node.pulse = loadFor(node.key) }
    }
    private func addPulse(_ node: NodeUI) {
        // КЛЮЧЕВОЕ: НЕ пересоздаём анимацию на каждом обновлении данных (раз в ~1с),
        // иначе тень скачком падает в 0 и стартует заново → дёрганая «сильная» пульсация.
        // Переустанавливаем только когда нагрузка реально сменила корзину (~0.1).
        let bucket = (node.pulse * 10).rounded() / 10
        if node.container.animation(forKey: "pulse") != nil, abs(bucket - node.appliedPulse) < 0.001 { return }
        node.appliedPulse = bucket
        node.container.removeAnimation(forKey: "pulse")
        guard node.pulse > 0.08 else { node.container.shadowOpacity = 0; return }
        // узкая полоса свечения, НЕ гаснущая в ноль — еле заметное «дыхание», а не вспышка
        let lo: Float = 0.05
        let hi = lo + Float(0.14 * node.pulse)      // потолок ~0.19 — очень мягко
        if Motion.reduced {                          // «Уменьшить движение» — ровное свечение по нагрузке, без пульса
            node.container.shadowOpacity = (lo + hi) / 2
            return
        }
        let a = CABasicAnimation(keyPath: "shadowOpacity")
        a.fromValue = lo
        a.toValue = hi
        a.duration = 3.0 - 0.6*node.pulse           // 2.4–3.0 с — медленно
        a.autoreverses = true; a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        node.container.shadowOpacity = lo
        node.container.add(a, forKey: "pulse")
    }

    // MARK: значения
    private func refreshValues() {
        let s = snapshot
        // АТОМАРНО, без имплицитного ~0.25с crossfade CATextLayer: иначе число узла «Адаптер» и
        // колонка полосы доплывали в разные моменты кадра → владелец видел «дублируются и расходятся».
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for node in nodes {
            node.accent = accent(for: node.key)               // база (семантика/нейтраль) — для проводов
            let disp = displayAccent(for: node)               // отображение: бирюза у узла под курсором/в фокусе
            node.title.foregroundColor = titleColor(for: node).cgColor
            if node.key != "Система" {
                node.icon.contents = symbolCG(icon(for: node.key), disp, node.icon.bounds.width > 1 ? node.icon.bounds.width : 16)
            }
            node.value.foregroundColor = NSColor.labelColor.cgColor   // V6: число ведёт — полный labelColor
            switch node.key {
            case "Батарея":
                node.title.string = L("Батарея")
                node.value.string = String(format: L("%.0f Вт"), s.battWatts)   // В·А — в тултипе
                // мёртвый поток АКБ — число шёпотом, как её провод-волосок (единая грамматика сна)
                if wireIsDead(abs(s.battAmps)) { node.value.foregroundColor = NSColor.tertiaryLabelColor.cgColor }
            case "Адаптер":
                node.title.string = L("Адаптер")
                // РЕЗЕРВУАР-грамматика: «41/67 Вт» (живой замер / номинал). Без номинала — просто замер.
                if s.plugged, let rated = s.adapterRatedWatts {
                    node.value.string = adapterReservoirAttr(give: s.adapterWatts, rated: rated)
                } else {
                    node.value.string = s.plugged ? String(format: L("%.0f Вт"), s.adapterWatts) : "—"
                    if !s.plugged { node.value.foregroundColor = NSColor.tertiaryLabelColor.cgColor }   // «—» спит
                }
            case "Система":
                node.value.string = hubValueAttr(s.systemWatts)
            default:
                if let r = s.rails.first(where: { $0.name == node.key }) {
                    node.title.string = L(node.key)
                    // приоритет ЧЕСТНЫХ ватт: powermetrics (CPU/GPU/DRAM, свежие) → шина SMC (V·A) → ток.
                    // «Прочее» ватт не имеет никогда — остаётся в амперах с честным суффиксом «А».
                    if let w = componentWatts(for: node.key) ?? r.watts {
                        node.value.string = String(format: L("%.1f Вт"), w)
                    } else {
                        node.value.string = String(format: L("%.2f А"), r.amps)
                    }
                    // спит ⇔ его провод-волосок: ОДИН предикат (амперы рейла) для числа и провода,
                    // иначе ватты сравнивались бы с амперным порогом и поверхности расходились
                    if wireIsDead(r.amps) { node.value.foregroundColor = NSColor.tertiaryLabelColor.cgColor }
                }
            }
        }
        // VoiceOver: метка оверлея = живой человекочитаемый разбор узла
        for nv in nodeViews { nv.axLabel = detailLine(for: nv.key) }
    }

    /// Цвет заголовка узла (V6): имя — всегда шёпот secondaryLabel; бирюзу надевает только
    /// НЕЙТРАЛЬНЫЙ узел под курсором/в фокусе (интерактив). Семантический цвет (янтарь/зелёный)
    /// имени не даётся — он принадлежит ДАННЫМ: заливке гейджа, иконке и проводу.
    private func titleColor(for node: NodeUI) -> NSColor {
        guard node.key != "Система" else { return .tertiaryLabelColor }   // «система» — микроподпись
        let lit = (node.key == hovered || node.key == focusedKey) && node.accent == neutralNode
        return lit ? focusAccent : .secondaryLabelColor
    }

    /// Атрибут-строка сердца: «77» крупно (21pt, моно-цифры) + « Вт» шёпотом — единица не кричит.
    private func hubValueAttr(_ watts: Double) -> NSAttributedString {
        let a = NSMutableAttributedString()
        a.append(NSAttributedString(string: String(format: "%.0f", watts), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 21, weight: .semibold),
            .foregroundColor: NSColor.labelColor]))
        a.append(NSAttributedString(string: " " + L("Вт"), attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor]))
        return a
    }

    /// Резервуар-грамматика значения адаптера: «41» крупно (живая отдача, моно) + «/67 Вт» шёпотом
    /// (номинал, без пробела перед слэшем и с единицей ОДИН раз). Зазор = запас (виден и на гейдже).
    private func adapterReservoirAttr(give: Double, rated: Int) -> NSAttributedString {
        let a = NSMutableAttributedString()
        a.append(NSAttributedString(string: String(format: "%.0f", give), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        a.append(NSAttributedString(string: String(format: L("/%d Вт"), rated), attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]))
        return a
    }

    /// Реальные ватты компонента по имени шины — ТОЛЬКО если сэмпл свежий и значение известно
    /// (иначе nil → показываем ток, без фейковых нулей). Память ↔ DRAM-рейл powermetrics.
    private func componentWatts(for key: String) -> Double? {
        guard let c = components, c.fresh else { return nil }
        switch key {
        case "CPU":    return c.cpu
        case "GPU":    return c.gpu
        case "Память": return c.dram
        default:       return nil
        }
    }

    // MARK: фокус/наведение — единый restyle
    private func active(_ key: String) -> Bool {
        guard let f = focusedKey else { return true }
        return key == f || ["Система", "Батарея", "Адаптер"].contains(key)
    }
    private func restyle() {
        CATransaction.begin(); CATransaction.setAnimationDuration(Motion.reduced ? 0 : Design.Motion.durBase)
        for node in nodes {
            let on = active(node.key)
            let hover = node.key == hovered
            let disp = displayAccent(for: node)               // бирюза у узла под курсором/в фокусе, иначе база
            node.container.opacity = on ? 1 : 0.35
            node.title.foregroundColor = titleColor(for: node).cgColor
            if node.key != "Система" {
                node.icon.contents = symbolCG(icon(for: node.key), disp, node.icon.bounds.width > 1 ? node.icon.bounds.width : 16)
            }
            node.container.shadowColor = disp.cgColor          // ореол наведения идёт за отображаемым цветом
            // узел-прибор на едином поле: наведение/фокус — лёгкий подъём масштаба + подсветка гейджа
            node.container.transform = CATransform3DMakeScale(hover ? 1.06 : 1, hover ? 1.06 : 1, 1)
            if hover { node.container.removeAnimation(forKey: "pulse"); node.appliedPulse = -1 }
            else { addPulse(node) }
        }
        for i in wires.indices {
            let w = wires[i]
            if fadingOutWires.contains(w.fromKey) { continue }   // не мешаем затуханию отключённого адаптера
            let on = focusedKey == nil || w.toKey == focusedKey || w.fromKey == focusedKey || w.toKey == "Система"
            let dead = wireIsDead(w.amps)                        // мёртвый ток: волосок без свечения, полупрозрачен
            w.grad.opacity = on ? (dead ? 0.5 : 1) : 0.06        // 0.5 — волосок ДОЖИВАЕТ до обода, связь читается
            w.glow.opacity = (on && !dead) ? 1 : 0.0
            // подсветка провода наведённого узла: НЕЙТРАЛЬНЫЙ (потребительский) провод его узла надевает
            // бирюзу (как сам узел/точка обода); семантический провод (адаптер-оранж / АКБ) свой цвет не меняет.
            applyHoverTint(i)
        }
        refreshBalRingColors()      // дуга входа загорается бирюзой, когда хаб под курсором/в фокусе
        CATransaction.commit()
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hit = nodes.first { $0.rect.contains(p) }?.key
        guard hit != hovered else { return }
        hovered = hit; restyle(); emitDetail()
    }
    override func mouseExited(with event: NSEvent) {
        guard hovered != nil else { return }
        hovered = nil; restyle(); emitDetail()
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hit = nodes.first { $0.rect.contains(p) }?.key
        focusedKey = (hit == focusedKey) ? nil : hit     // повторный клик снимает фокус
        restyle(); emitDetail()
    }
    /// Активация узла с клавиатуры/VoiceOver — как клик: фокусирует поток (повторно — снимает).
    func focusNode(_ key: String) {
        focusedKey = (key == focusedKey) ? nil : key
        restyle(); emitDetail()
    }
    private func emitDetail() {
        let key = hovered ?? focusedKey
        detailSink?(key.map { detailLine(for: $0) })
    }
    /// Локализованное слово состояния потока АКБ (из battFlow с гистерезисом — честно про равновесие).
    private func battFlowWord(_ f: BatteryFlow) -> String {
        switch f {
        case .charging: return L("заряд")
        case .discharging: return L("разряд")
        case .idle: return L("равновесие")
        }
    }
    /// Одна строка разбора узла (для подписи под схемой).
    private func detailLine(for key: String) -> String {
        let s = snapshot
        switch key {
        case "Батарея": return String(format: L("Батарея · %.1f В · %.2f А · %.0f Вт · %@"), s.battVolts, abs(s.battAmps), s.battWatts, battFlowWord(s.battFlow))
        case "Адаптер": return s.plugged ? adapterDetail(s) : L("Адаптер не подключён")
        case "Система": return systemDetail(s)
        default:
            guard let r = s.rails.first(where: { $0.name == key }) else { return L(key) }
            // тот же приоритет ватт, что у ЧИСЛА узла (componentWatts ?? r.watts) — две поверхности
            // не имеют права показывать разные величины для одного узла
            if let w = componentWatts(for: key) ?? r.watts {
                let pct = s.systemWatts > 0.5 ? w / s.systemWatts * 100 : 0
                return String(format: L("%@ · %.2f А · %.1f Вт · %.0f%% системы"), L(key), r.amps, w, pct)
            }
            return String(format: L("%@ · %.2f А"), L(key), r.amps)
        }
    }

    /// Разбор узла «Система» — строка ПРИМИРЕНИЯ под схемой: вход адаптера, честный расход (PSTR),
    /// знаковый баланс потока АКБ. Те же три величины, что и в верхней полосе, — сводим их в одну
    /// читаемую строку, чтобы пользователь видел, как вход и расход сходятся (закон сохранения).
    /// Без адаптера ВХОД опускаем (его нет) — показываем расход и баланс.
    private func systemDetail(_ s: EnergySnapshot) -> String {
        let bal = netLabel()        // знаковая подпись баланса («+12 Вт» / «−18 Вт» / «0 Вт»)
        if s.plugged {
            var line = String(format: L("Вход %.0f Вт · Расход %.0f Вт · Баланс %@"), s.adapterWatts, s.systemWatts, bal)
            if let gap = measurementGap() {
                line += " · " + String(format: L("расхождение замеров %.0f Вт"), gap)
            }
            return line
        }
        return String(format: L("Расход %.0f Вт · Баланс %@"), s.systemWatts, bal)
    }

    /// Зазор между независимыми замерами входа (PDTR) и расхода (PSTR) на равновесии, когда батарея
    /// не участвует: это НЕ поток, а калибровочное расхождение двух цепей — и кольцо, и слова зовут
    /// его по имени. nil, когда объяснять нечего (разряд/заряд/зазор в пределах шума).
    private func measurementGap() -> Double? {
        let s = snapshot
        guard s.plugged, s.battFlow != .discharging else { return nil }
        let gap = s.systemWatts - s.adapterWatts
        return gap > 1 ? gap : nil
    }

    /// Разбор узла «Адаптер» (только когда подключён). Номинал (паспорт PD) и живой замер отдачи —
    /// ДВЕ РАЗНЫЕ величины рядом: видно запас/недобор. Номинала нет → честно показываем только замер.
    /// Имя/модель сюда НЕ префиксуем: это однострочный лейбл с обрезкой хвоста, а имя адаптера у Apple
    /// часто длинное и само несёт ватты («96W USB-C Power Adapter») — оно бы (а) дублировало номинал и
    /// (б) выдавило «даёт M Вт» в обрез. Имя живёт в тултипе как заголовок, где есть место.
    private func adapterDetail(_ s: EnergySnapshot) -> String {
        if let rated = s.adapterRatedWatts {
            let reserve = max(0, Double(rated) - s.adapterWatts)
            return String(format: L("Адаптер %d Вт · даёт %.0f Вт"), rated, s.adapterWatts)
                 + " · " + String(format: L("запас %.0f Вт"), reserve)
        }
        return String(format: L("Адаптер · %.0f В · %.1f А · %.0f Вт"), s.adapterVolts, s.adapterAmps, s.adapterWatts)
    }

    /// Тултип узла «Адаптер»: заголовок (имя или «Адаптер»), затем номинал-и-замер либо живой замер.
    /// Глагол и точность отдачи едины с inline-разбором (даёт %.0f Вт), чтобы две поверхности не
    /// показывали разные числа для одной величины; имя-заголовок несёт модель, тело — паспорт+замер.
    private func adapterTooltip(_ s: EnergySnapshot) -> String {
        let title = s.adapterName ?? L("Адаптер")
        var t: String
        if let rated = s.adapterRatedWatts {
            t = title + "\n" + String(format: L("номинал %d Вт · даёт %.0f Вт"), rated, s.adapterWatts)
        } else {
            t = title + "\n" + String(format: L("%.0f В · %.1f А · %.0f Вт"), s.adapterVolts, s.adapterAmps, s.adapterWatts)
        }
        if let verdict = adapterHealth(s) { t += "\n" + verdict }
        return t
    }

    /// Честный вердикт «тянет ли адаптер»: только когда ПОДКЛЮЧЁН. Берём ДЕБАУНС-поле `battFlow`
    /// (гистерезис: .discharging лишь после 3 сэмплов реального разряда) — НЕ сырой `charging`+battWatts:
    /// на равновесии знак тока B0AC дрожит в минус (артефакт КПД заряда), battWatts большой, но батарея
    /// НЕ разряжается → сырой сигнал давал ЛОЖНУЮ тревогу «не покрывает». battFlow это гасит.
    private func adapterHealth(_ s: EnergySnapshot) -> String? {
        guard s.plugged else { return nil }
        switch s.battFlow {
        case .discharging: return "⚠ " + L("не покрывает нагрузку — батарея разряжается")
        case .charging:    return L("тянет нагрузку и заряжает")
        case .idle:        return L("держит систему (батарея не расходуется)")
        }
    }

    // MARK: тултипы
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let node = nodes.first(where: { $0.rect.contains(point) }) else { return "" }
        let s = snapshot
        switch node.key {
        case "Батарея": return String(format: L("Батарея — %@\n%.2f В · %.2f А · %.1f Вт"), battFlowWord(s.battFlow), s.battVolts, abs(s.battAmps), s.battWatts)
        case "Адаптер": return s.plugged ? adapterTooltip(s) : L("Адаптер не подключён")
        case "Система":
            var t = String(format: L("Система потребляет %.1f Вт"), s.systemWatts)
            if let gap = measurementGap() {
                t += "\n" + String(format: L("расхождение замеров входа и расхода %.0f Вт"), gap)
            }
            return t
        default:
            if let r = s.rails.first(where: { $0.name == node.key }) {
                // единый приоритет ватт с числом узла (componentWatts ?? r.watts)
                let w = componentWatts(for: node.key) ?? r.watts
                return w.map { String(format: L("%@\n%.3f А · %.2f Вт"), L(node.key), r.amps, $0) } ?? String(format: L("%@\n%.3f А"), L(node.key), r.amps)
            }
            return L(node.key)
        }
    }

    // MARK: утилиты
    private func styleText(_ t: CATextLayer, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) {
        // mono = моно-ЦИФРЫ (tabular): живые числа не дрожат по ширине при апдейте
        let f = mono ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                     : NSFont.systemFont(ofSize: size, weight: weight)
        t.font = f; t.fontSize = size
        t.foregroundColor = color.cgColor
        t.contentsScale = scale
        t.truncationMode = .end
    }
    private func symbolCG(_ name: String, _ color: NSColor, _ pt: CGFloat) -> CGImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .semibold).applying(.init(paletteColors: [color]))
        let img = base.withSymbolConfiguration(cfg) ?? base
        var r = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }
}

/// Прозрачный оверлей над узлом схемы: даёт VoiceOver (роль кнопки + живая метка) и клавиатуру
/// (Tab + Space/Enter + focus ring), НЕ перехватывая мышь (hitTest → nil) — рисование/наведение
/// остаются на FlowView.
private final class FlowNodeView: NSView {
    let key: String
    var axLabel = ""
    var onActivate: ((String) -> Void)?
    init(key: String) { self.key = key; super.init(frame: .zero); focusRingType = .default }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }      // мышь проходит насквозь к FlowView
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { onActivate?(key) }   // Space / Return
        else { super.keyDown(with: event) }
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14).fill() }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { axLabel }
    override func accessibilityPerformPress() -> Bool { onActivate?(key); return true }
}
