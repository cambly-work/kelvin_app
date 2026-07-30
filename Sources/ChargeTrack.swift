import AppKit

/// Горизонтальная «дорожка заряда» в духе AlDente — приборная капсула 0…100%:
/// текущая заливка ∝ заряду (цвет уровня, как у BatteryGauge), перетаскиваемая
/// бирюзовая ручка-потолок с маркёр-линией (та же грамматика, что у тика кольца),
/// «призрачная зона» за потолком (заряд, который мы решили НЕ набирать), и парусная
/// полоса (sailLower…sailUpper) в режиме «Парус». Под баром — компактный 3-сегментный
/// переключатель режима (Выкл/Лимит/Парус) и чип «До 100%» (top-up).
///
/// Управление едино-маршрутизировано через `ChargeControl` (Pro-гейт + запись json +
/// установка демона + кросс-синк через BMPopoverChanged). Free ВИДИТ живой прибор;
/// захват ручки/смена режима в Pro триггерит канонический $19-апселл и откатывает UI.
/// BCLM пишет только демон (честность) — бар отражает РЕАЛЬНО применённое состояние.
final class ChargeTrack: NSView {

    // MARK: - Геометрия
    static let barHeight: CGFloat = 22          // высота полосы-дорожки (строка 2 плитки батареи)
    static let switchHeight: CGFloat = 22       // высота строки режима под баром
    private let rowGap: CGFloat = 8
    private let detentPct = 80                   // магнитный детент-сладкая точка долговечности
    private let minLimit = 50                    // нижний клампинг потолка/нижней парусной границы
    private let maxLimit = 100

    // MARK: - Состояние (рендер-снимок; JSON тут не читаем)
    private var charge = 0
    private var charging = false
    private var flow: BatteryFlow = .idle
    private var limit = 100                      // текущий потолок (limit-режим)
    private var mode = "limit"                   // "limit" | "sail"
    private var sailUpper = 80
    private var sailLower = 70
    private var pro = false
    private var topUpActive = false
    private var controlReady = false

    // MARK: - Перетаскивание
    private enum Grip { case none, limit, sailUpper, sailLower }
    private var dragging: Grip = .none
    private var dragValue = 0                     // живое значение во время drag (%)

    // MARK: - Подвью
    private let bar = BarView()
    private let modeSwitch: PillTabBar
    private let topUpChip = NSButton()
    private var bubble: NSTextField?              // транзиентный пузырь значения над ручкой

    // Disclosure «регулировка из шапки» (владелец: «лимит никак не отрегулировать отсюда»):
    // клик по «Лимит»/«Парус» раскрывает ДРАГ-БАР (весь код давно написан — воскрешаем в иерархию)
    // + ряд пресетов 60/70/80/90 (в Парусе пресеты скрыты — на баре две ручки границ).
    private let presetRow = NSStackView()
    private var presetButtons: [NSButton] = []
    private static let presetValues = [60, 70, 80, 90]
    private(set) var expanded = false
    var onHeightChanged: (() -> Void)?
    private var collapsedC: [NSLayoutConstraint] = []   // низ = modeSwitch (бар скрыт)
    private var barC: [NSLayoutConstraint] = []          // бар под переключателем
    private var presetTailC: [NSLayoutConstraint] = []   // низ = пресеты (режим «Лимит»)
    private var barTailC: [NSLayoutConstraint] = []      // низ = бар (режим «Парус», без пресетов)

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    override init(frame: NSRect) {
        modeSwitch = PillTabBar(labels: [L("Выкл"), L("Лимит"), L("Парус")], selected: 1)
        super.init(frame: frame)
        wantsLayer = true
        modeSwitch.translatesAutoresizingMaskIntoConstraints = false
        modeSwitch.onSelect = { [weak self] idx in self?.modeSegmentChanged(idx) }
        // повторный тап по активному «Лимит»/«Парус» — раскрыть/спрятать регулировку
        modeSwitch.onReselect = { [weak self] idx in if idx != 0 { self?.setExpanded(!(self?.expanded ?? false)) } }
        addSubview(modeSwitch)

        // драг-бар: возвращён в иерархию (по умолчанию скрыт — раскрывается кликом, НЕ всегда-видимый
        // «ползунок»-дубль кольца, который владелец отверг в V3)
        bar.owner = self
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = true
        addSubview(bar)

        presetRow.orientation = .horizontal
        presetRow.spacing = 6
        presetRow.translatesAutoresizingMaskIntoConstraints = false
        presetRow.isHidden = true
        for v in Self.presetValues {
            let b = NSButton()
            b.isBordered = false
            b.bezelStyle = .inline
            b.wantsLayer = true
            b.layer?.cornerRadius = Design.Radius.chip
            b.layer?.cornerCurve = .continuous
            b.tag = v
            b.target = self
            b.action = #selector(presetTapped(_:))
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.heightAnchor.constraint(equalToConstant: 18).isActive = true
            presetButtons.append(b)
            presetRow.addArrangedSubview(b)
        }
        addSubview(presetRow)

        topUpChip.isBordered = false
        topUpChip.bezelStyle = .inline
        topUpChip.wantsLayer = true
        topUpChip.layer?.cornerRadius = Design.Radius.chip
        topUpChip.layer?.cornerCurve = .continuous
        topUpChip.target = self
        topUpChip.action = #selector(topUpTapped)
        topUpChip.translatesAutoresizingMaskIntoConstraints = false
        topUpChip.setContentHuggingPriority(.required, for: .horizontal)
        topUpChip.toolTip = L("Зарядить до 100% сейчас")
        addSubview(topUpChip)

        NSLayoutConstraint.activate([
            modeSwitch.topAnchor.constraint(equalTo: topAnchor),
            modeSwitch.leadingAnchor.constraint(equalTo: leadingAnchor),
            modeSwitch.heightAnchor.constraint(equalToConstant: Self.switchHeight),

            topUpChip.centerYAnchor.constraint(equalTo: modeSwitch.centerYAnchor),
            topUpChip.trailingAnchor.constraint(equalTo: trailingAnchor),
            topUpChip.heightAnchor.constraint(equalToConstant: 18),
            // переключатель занимает левую часть строки, чип — правый край; зазор ≥8
            modeSwitch.trailingAnchor.constraint(lessThanOrEqualTo: topUpChip.leadingAnchor, constant: -8),
            modeSwitch.widthAnchor.constraint(equalToConstant: 168),
        ])
        collapsedC = [modeSwitch.bottomAnchor.constraint(equalTo: bottomAnchor)]
        barC = [
            bar.topAnchor.constraint(equalTo: modeSwitch.bottomAnchor, constant: rowGap),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight),
        ]
        presetTailC = [
            presetRow.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            presetRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            presetRow.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        barTailC = [bar.bottomAnchor.constraint(equalTo: bottomAnchor)]
        NSLayoutConstraint.activate(collapsedC)
        styleTopUp()
        stylePresets()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Раскрыть/спрятать регулировку (бар + пресеты). Меняет собственную высоту — хост подрастит поповер.
    func setExpanded(_ e: Bool) {
        guard e != expanded else { applyLayoutState(); return }
        expanded = e
        applyLayoutState()
        onHeightChanged?()
    }
    private func applyLayoutState() {
        NSLayoutConstraint.deactivate(collapsedC + barC + presetTailC + barTailC)
        bar.isHidden = !expanded
        let showPresets = expanded && mode != "sail"
        presetRow.isHidden = !showPresets
        if !expanded {
            NSLayoutConstraint.activate(collapsedC)
        } else {
            NSLayoutConstraint.activate(barC)
            NSLayoutConstraint.activate(showPresets ? presetTailC : barTailC)
            stylePresets()
        }
    }

    /// Чипы-пресеты: активный = текущий лимит (заливка accent + светлый текст), прочие — accentMuted.
    private func stylePresets() {
        let dark = isDark
        for b in presetButtons {
            let active = (mode != "sail") && (limit == b.tag)
            b.layer?.backgroundColor = (active ? Design.Color.accent(dark).withAlphaComponent(dark ? 0.85 : 0.9)
                                               : Design.Color.accentMuted(dark)).cgColor
            b.attributedTitle = NSAttributedString(string: " \(b.tag)% ", attributes: [
                .font: Design.Font.microStat,
                .foregroundColor: active ? NSColor.white : Design.Color.accent(dark)])
        }
    }

    @objc private func presetTapped(_ sender: NSButton) {
        ChargeControl.setLimit(sender.tag)          // Pro-гейт + запись json внутри (единый путь)
        limit = ChargeControl.limit                  // читаем РЕАЛЬНО применённое (Free → апселл, лимит не сменился)
        stylePresets()
        bar.needsDisplay = true
        updateAccessibilityValue()
    }

    override var isFlipped: Bool { false }

    // MARK: - Публичный API (вызывается из update() рядом с ring.set)

    /// Залить бар реальным состоянием заряда + потолок/режим/паруса + Pro-флаг.
    /// JSON не читаем — только рендер. Значения берёт вызывающий из SettingsStore/ChargeControl.
    func set(charge: Int, charging: Bool, flow: BatteryFlow,
             limit: Int, mode: String, sailUpper: Int, sailLower: Int,
             topUpActive: Bool, controlReady: Bool, pro: Bool) {
        self.charge = max(0, min(100, charge))
        self.charging = charging
        self.flow = flow
        self.topUpActive = topUpActive
        self.controlReady = controlReady
        self.pro = pro
        // во время активного drag НЕ перетираем потолок/паруса/режим живым тиком (1Гц update),
        // иначе ручка «дёргалась» бы назад к сохранённому значению до коммита.
        guard dragging == .none else { bar.needsDisplay = true; return }
        let prevMode = self.mode
        self.limit = limit
        self.mode = mode
        self.sailUpper = sailUpper
        self.sailLower = sailLower
        let prepared = mode == "sail" || limit < 100 || topUpActive
        toolTip = prepared && !controlReady
            ? L("Настройки подготовлены; подключите системное управление, чтобы они начали работать.")
            : nil
        bar.alphaValue = prepared && !controlReady ? 0.62 : 1
        // сегмент переключателя: Выкл(0)=limit@100, Лимит(1)=limit<100, Парус(2)=sail
        let seg = mode == "sail" ? 2 : (limit < 100 ? 1 : 0)
        if modeSwitch.selectedIndex != seg { modeSwitch.select(seg, animated: false) }
        refreshTopUpVisibility()
        if expanded {
            if prevMode != mode { applyLayoutState(); onHeightChanged?() }   // лимит↔парус: пресеты показать/спрятать
            else { stylePresets() }                                          // лимит мог смениться из Настроек
        }
        bar.needsDisplay = true
        updateAccessibilityValue()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        bar.needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        styleTopUp()
        bar.needsDisplay = true
    }

    // MARK: - Top-Up чип

    private func refreshTopUpVisibility() {
        // показываем только при активном потолке (mode==sail || limit<100) — зеркало Settings.
        let active = (mode == "sail") || (limit < 100)
        topUpChip.isHidden = !active
        styleTopUp()
    }
    private func styleTopUp() {
        let dark = isDark
        let acc = topUpActive ? Design.Color.accentBright(dark) : Design.Color.accent(dark)
        topUpChip.layer?.backgroundColor = (topUpActive
            ? acc.withAlphaComponent(dark ? 0.30 : 0.34)
            : Design.Color.accentMuted(dark)).cgColor
        topUpChip.attributedTitle = NSAttributedString(string: " " + L("До 100%") + " ", attributes: [
            .font: Design.Font.microStat,
            .foregroundColor: acc,
            .kern: Design.Font.capsKern])
    }

    @objc private func topUpTapped() {
        // Pro-гейт внутри ChargeControl.topUp(); при отказе апселл уже показан, состояние не меняем.
        if ChargeControl.topUp() { /* BMPopoverChanged пересоберёт бар */ }
    }

    // MARK: - Переключатель режима (3 сегмента)

    private func modeSegmentChanged(_ idx: Int) {
        // idx: 0=Выкл, 1=Лимит, 2=Парус — единый путь через ChargeControl (Pro-гейт внутри).
        let ok: Bool
        switch idx {
        case 0:  ok = ChargeControl.setMode("off")
        case 2:  ok = ChargeControl.setMode("sail")
        default: ok = ChargeControl.setMode("limit")
        }
        if !ok {
            // Pro-гейт сорвался (апселл показан) — вернуть сегмент к фактическому состоянию.
            let seg = ChargeControl.mode == "sail" ? 2 : (ChargeControl.limit < 100 ? 1 : 0)
            modeSwitch.select(seg, animated: false)
            return
        }
        // Успех: мгновенный локальный снимок (1Гц-тик подтвердит) + disclosure — включил режим → сразу регулируй.
        limit = ChargeControl.limit
        mode = ChargeControl.mode
        if expanded && idx != 0 {
            // уже раскрыт, сменился лимит↔парус: guard в setExpanded не уведомил бы хост —
            // перестраиваем явно И дёргаем высоту (пресеты появились/спрятались = ±24pt)
            applyLayoutState()
            onHeightChanged?()
        } else {
            setExpanded(idx != 0)
        }
        bar.needsDisplay = true
    }

    // MARK: - Геометрия дорожки (общая для рисунка и хит-теста)

    /// Внутренний прямоугольник шкалы внутри бара (без контакт-нуба справа).
    fileprivate func scaleRect(in b: NSRect) -> NSRect {
        let r = b.insetBy(dx: 2, dy: 2)
        let capW = r.width * 0.05
        return CGRect(x: r.minX, y: r.minY, width: r.width - capW - 3, height: r.height)
    }
    /// x-координата для доли 0…1 внутри шкалы (с учётом скругления капсулы).
    fileprivate func x(for frac: CGFloat, in scale: NSRect) -> CGFloat {
        scale.minX + scale.width * max(0, min(1, frac))
    }
    /// Обратное: доля 0…1 из x.
    private func frac(forX px: CGFloat, in scale: NSRect) -> CGFloat {
        guard scale.width > 0 else { return 0 }
        return max(0, min(1, (px - scale.minX) / scale.width))
    }

    // MARK: - Перетаскивание (логика; вызывается из BarView)

    fileprivate func barMouseDown(_ event: NSEvent) {
        let scale = scaleRect(in: bar.bounds)
        let p = bar.convert(event.locationInWindow, from: nil)
        let slop: CGFloat = 14

        // какую ручку схватили? в парусе сначала верхняя, затем нижняя.
        let grip: Grip
        if mode == "sail" {
            let xu = x(for: CGFloat(sailUpper) / 100, in: scale)
            let xl = x(for: CGFloat(sailLower) / 100, in: scale)
            if abs(p.x - xu) <= slop { grip = .sailUpper }
            else if abs(p.x - xl) <= slop { grip = .sailLower }
            else { grip = .none }
        } else {
            let xl = x(for: CGFloat(limit) / 100, in: scale)
            grip = abs(p.x - xl) <= slop ? .limit : .none
        }
        guard grip != .none else { return }

        // Pro-гейт ПЕРВЫМ: Free видит прибор, но захват — момент апселла. Ручка остаётся на месте.
        if !pro { ChargeControl.requireProGate(); return }

        dragging = grip
        dragValue = currentValue(of: grip)
        showBubble(value: dragValue, grip: grip, scale: scale)
        bar.needsDisplay = true
    }

    fileprivate func barMouseDragged(_ event: NSEvent) {
        guard dragging != .none else { return }
        let scale = scaleRect(in: bar.bounds)
        let p = bar.convert(event.locationInWindow, from: nil)
        var pct = Int((frac(forX: p.x, in: scale) * 100).rounded())
        pct = snap(pct)                                       // шаг 5% + магнитный детент 80%
        pct = clamp(pct, for: dragging)
        switch dragging {
        case .limit:     limit = pct
        case .sailUpper: sailUpper = pct
        case .sailLower: sailLower = pct
        case .none:      break
        }
        dragValue = pct
        showBubble(value: pct, grip: dragging, scale: scale)
        bar.needsDisplay = true                               // живой перерисовываем; json НЕ пишем
    }

    fileprivate func barMouseUp(_ event: NSEvent) {
        guard dragging != .none else { return }
        let g = dragging
        dragging = .none
        // КОММИТ — единый путь через ChargeControl (запись json + демон + синк).
        // После коммита читаем РЕАЛЬНО применённое (Free-отказ откатывает — бар честен сразу, не через тик).
        switch g {
        case .limit:
            ChargeControl.setLimit(dragValue); limit = ChargeControl.limit
        case .sailUpper:
            let r = ChargeControl.setSail(upper: dragValue, lower: sailLower); sailUpper = r.upper; sailLower = r.lower
        case .sailLower:
            let r = ChargeControl.setSail(upper: sailUpper, lower: dragValue); sailUpper = r.upper; sailLower = r.lower
        case .none:      break
        }
        stylePresets()
        hideBubble()
        bar.needsDisplay = true
        // commit → BMPopoverChanged → пересборка с реально применённым состоянием (честность).
    }

    private func currentValue(of g: Grip) -> Int {
        switch g {
        case .limit:     return limit
        case .sailUpper: return sailUpper
        case .sailLower: return sailLower
        case .none:      return limit
        }
    }
    /// Шаг 5% + магнитный детент на 80% (сладкая точка долговечности).
    private func snap(_ pct: Int) -> Int {
        let stepped = Int((Double(pct) / 5).rounded()) * 5
        return abs(stepped - detentPct) <= 2 ? detentPct : stepped
    }
    /// Клампинг с тем же ±5-зазором парусной полосы, что в Settings.
    private func clamp(_ pct: Int, for g: Grip) -> Int {
        switch g {
        case .limit:     return max(minLimit, min(maxLimit, pct))
        case .sailUpper: return max(sailLower + 5, min(90, pct))
        case .sailLower: return max(minLimit, min(sailUpper - 5, pct))
        case .none:      return pct
        }
    }

    // MARK: - Пузырь значения (транзиентный, gate Motion.reduced)

    private func showBubble(value: Int, grip: Grip, scale: NSRect) {
        let b: NSTextField
        if let existing = bubble { b = existing }
        else {
            b = NSTextField(labelWithString: "")
            b.font = Design.Font.numericBody
            b.alignment = .center
            b.wantsLayer = true
            b.layer?.cornerRadius = Design.Radius.pill
            b.layer?.cornerCurve = .continuous
            b.drawsBackground = false
            b.isBezeled = false
            b.translatesAutoresizingMaskIntoConstraints = true
            addSubview(b)
            bubble = b
        }
        let dark = isDark
        b.textColor = Design.Color.accentBright(dark)
        b.layer?.backgroundColor = Design.Color.glassTint(Design.Color.accent(dark), dark).cgColor
        b.stringValue = " \(value)% "
        b.sizeToFit()
        var f = b.frame
        f.size.width += 10; f.size.height = 16
        // bubble живёт в координатах контейнера; scale/cx — в координатах бара (его minX==0).
        // Плавает НАД ручкой = выше верхней кромки бара (masksToBounds=false → не режется).
        let cx = bar.frame.minX + x(for: CGFloat(value) / 100, in: scale)
        f.origin.x = min(max(0, cx - f.width / 2), bounds.width - f.width)
        f.origin.y = bar.frame.maxY + 2
        b.frame = f
        b.isHidden = false
    }
    private func hideBubble() {
        guard let b = bubble else { return }
        guard !Motion.reduced else { b.isHidden = true; return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Design.Motion.durValue
            b.animator().alphaValue = 0
        }, completionHandler: { [weak b] in b?.isHidden = true; b?.alphaValue = 1 })
    }

    // MARK: - VoiceOver (бар = один .slider; режим/чип остаются отдельными AX-элементами)

    /// Значение для VoiceOver: потолок (limit) или верхний парус — то, что двигают инкрементом.
    fileprivate func axValueInt() -> Int { mode == "sail" ? sailUpper : limit }
    private func updateAccessibilityValue() {
        NSAccessibility.post(element: bar, notification: .valueChanged)
    }
    /// Шаг ±5 через ChargeControl (Pro-гейт с апселлом при попытке). В парусе двигает sailUpper.
    fileprivate func axStep(_ delta: Int) -> Bool {
        if mode == "sail" {
            let v = max(sailLower + 5, min(90, sailUpper + delta))
            _ = ChargeControl.setSail(upper: v, lower: sailLower)
        } else {
            let v = max(minLimit, min(maxLimit, (limit == 100 && delta < 0 ? 100 : limit) + delta))
            ChargeControl.setLimit(v)
        }
        return true
    }

    // MARK: - Рисующая подвью (отделена, чтобы мышь шла к логике ChargeTrack)

    /// Внутренняя рисующая полоса. Хит-тест/рисунок делегируются обратно в ChargeTrack.
    /// Она же — единственный AX-.slider дорожки (режим/чип остаются отдельными AX-элементами).
    final class BarView: NSView {
        weak var owner: ChargeTrack?
        override var isFlipped: Bool { false }
        override func mouseDown(with event: NSEvent) { owner?.barMouseDown(event) }
        override func mouseDragged(with event: NSEvent) { owner?.barMouseDragged(event) }
        override func mouseUp(with event: NSEvent) { owner?.barMouseUp(event) }
        override func draw(_ dirtyRect: NSRect) { owner?.drawBar(in: bounds) }

        // VoiceOver: бар = регулируемый слайдер потолка заряда (без мыши через ±5).
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .slider }
        override func accessibilityLabel() -> String? { L("Лимит заряда") }
        override func accessibilityValue() -> Any? {
            String(format: L("%d процентов"), owner?.axValueInt() ?? 100)
        }
        override func accessibilityPerformIncrement() -> Bool { owner?.axStep(+5) ?? false }
        override func accessibilityPerformDecrement() -> Bool { owner?.axStep(-5) ?? false }
    }

    // MARK: - Рисунок дорожки

    /// Цвет уровня заряда — копия BatteryGauge.levelColor() (единственное санкционированное
    /// семантическое исключение бренд-закона: красный/жёлтый/зелёный — это ДАННЫЕ заряда).
    private func levelColor() -> NSColor {
        if charging { return Design.Color.chargeTeal }   // бирюза (B3-токен, calibratedRGB)
        switch charge {
        case ..<15: return Design.Color.chargeCrit       // красный
        case ..<35: return Design.Color.chargeWarn       // жёлтый
        default:    return Design.Color.chargeOK          // зелёный
        }
    }

    fileprivate func drawBar(in bounds: NSRect) {
        let dark = isDark
        let scale = scaleRect(in: bounds)
        let r = Design.Radius.track

        // — трек-капсула (фон шкалы 0…100)
        let track = NSBezierPath(roundedRect: scale, xRadius: r, yRadius: r)
        Design.Color.trackFill(dark).setFill()
        track.fill()

        // — контакт-нуб справа (как у BatteryGauge): крошечный «пин» батареи
        let capW = scale.width * 0.05
        let capH = scale.height * 0.5
        let cap = CGRect(x: scale.maxX + 2, y: scale.midY - capH / 2, width: max(2, capW * 0.7), height: capH)
        NSColor.secondaryLabelColor.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: cap, xRadius: 1.5, yRadius: 1.5).fill()

        // клипуем заливки скруглением трека
        NSGraphicsContext.saveGraphicsState()
        track.addClip()

        // — текущая заливка ∝ заряду: ПЛОСКИЙ приглушённый цвет уровня (V5 «в тему с поповером»):
        //   без градиента/свечения/блика — та же спокойная грамматика, что трек таб-бара и полоски гейджей.
        let chFrac = max(0.0, CGFloat(charge) / 100)
        let fillW = scale.width * chFrac
        if fillW > 0.5 {
            let fillRect = CGRect(x: scale.minX, y: scale.minY, width: fillW, height: scale.height)
            levelColor().withAlphaComponent(dark ? 0.55 : 0.5).setFill()
            NSBezierPath(rect: fillRect).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        track.addClip()

        if mode == "sail" {
            drawSailBand(scale: scale, dark: dark)
        } else {
            drawGhostZone(scale: scale, ceiling: dragValueOrLimit(), dark: dark)
        }
        NSGraphicsContext.restoreGraphicsState()

        // — детент-тик 80% (поверх трека, под ручкой): слабая бирюза-засечка
        drawDetentTick(scale: scale, dark: dark)

        // — ручка(и) потолка: маркёр-линия + грип-пилюля (та же грамматика, что у тика кольца)
        if mode == "sail" {
            drawHandle(at: sailValue(.sailUpper), scale: scale, bounds: bounds, dark: dark)
            drawHandle(at: sailValue(.sailLower), scale: scale, bounds: bounds, dark: dark)
        } else {
            drawHandle(at: dragValueOrLimit(), scale: scale, bounds: bounds, dark: dark)
        }

        // (молния на заливке убрана — V5: заряд уже показан кольцом и знаком «АКБ», без дублей-декора)
    }

    /// Текущий потолок для рисунка: во время drag — живое значение, иначе сохранённый лимит.
    private func dragValueOrLimit() -> Int { dragging == .limit ? dragValue : limit }
    private func sailValue(_ g: Grip) -> Int {
        if dragging == g { return dragValue }
        return g == .sailUpper ? sailUpper : sailLower
    }

    /// «Призрачная зона» за потолком → правый край: плоский controlFill (заряд, который мы решили НЕ набирать).
    private func drawGhostZone(scale: NSRect, ceiling: Int, dark: Bool) {
        guard ceiling < 100 else { return }
        let gx = x(for: CGFloat(ceiling) / 100, in: scale)
        let zone = CGRect(x: gx, y: scale.minY, width: scale.maxX - gx, height: scale.height)
        Design.Color.controlFill(dark).setFill()
        NSBezierPath(rect: zone).fill()
        // тонкая волосяная кромка у потолка
        Design.Color.hairline(dark, 0.25).setStroke()
        let edge = NSBezierPath()
        edge.move(to: CGPoint(x: gx, y: scale.minY)); edge.line(to: CGPoint(x: gx, y: scale.maxY))
        edge.lineWidth = 1; edge.stroke()
        // при активном top-up — пунктирный намёк «временно 100%» (честно: потолок снят на ~1ч)
        if topUpActive {
            let dash = NSBezierPath()
            dash.move(to: CGPoint(x: gx + 3, y: scale.midY)); dash.line(to: CGPoint(x: scale.maxX - 3, y: scale.midY))
            dash.lineWidth = 1.5
            dash.setLineDash([3, 3], count: 2, phase: 0)
            Design.Color.accentBright(dark).withAlphaComponent(0.55).setStroke()
            dash.stroke()
        }
    }

    /// Парусная полоса sailLower…sailUpper: стеклянный accent-тинт + контур; за верхней
    /// границей — та же призрачная зона. Текущая заливка уже нарисована ПОД полосой (видно «парус»).
    private func drawSailBand(scale: NSRect, dark: Bool) {
        let lo = sailValue(.sailLower), up = sailValue(.sailUpper)
        let xl = x(for: CGFloat(lo) / 100, in: scale)
        let xu = x(for: CGFloat(up) / 100, in: scale)
        let band = CGRect(x: xl, y: scale.minY, width: max(0, xu - xl), height: scale.height)
        let bandColor = controlReady ? Design.Color.accent(dark) : NSColor.secondaryLabelColor
        Design.Color.glassTint(bandColor, dark).setFill()
        NSBezierPath(rect: band).fill()
        // Пунктирная ось диапазона поддержания (та же грамматика, что у top-up-намёка): читается как
        // «здесь заряд гуляет между границами», а не как сплошная заливка-уровень (AlDente-ясность).
        if band.width > 8 {
            let dash = NSBezierPath()
            dash.move(to: CGPoint(x: xl + 3, y: scale.midY)); dash.line(to: CGPoint(x: xu - 3, y: scale.midY))
            dash.lineWidth = 1.5
            dash.setLineDash([3, 3], count: 2, phase: 0)
            (controlReady ? Design.Color.accentBright(dark) : NSColor.secondaryLabelColor)
                .withAlphaComponent(0.6).setStroke()
            dash.stroke()
        }
        // призрачная зона за верхней границей
        drawGhostZone(scale: scale, ceiling: up, dark: dark)
    }

    private func drawDetentTick(scale: NSRect, dark: Bool) {
        let dx = x(for: CGFloat(detentPct) / 100, in: scale)
        let tick = NSBezierPath()
        tick.move(to: CGPoint(x: dx, y: scale.minY + 3)); tick.line(to: CGPoint(x: dx, y: scale.maxY - 3))
        tick.lineWidth = 1
        Design.Color.accent(dark).withAlphaComponent(0.30).setStroke()
        tick.stroke()
    }

    /// Ручка-потолок: 2px accentBright маркёр-линия на всю высоту трека + вертикальная грип-пилюля.
    private func drawHandle(at pct: Int, scale: NSRect, bounds: NSRect, dark: Bool) {
        let hx = x(for: CGFloat(pct) / 100, in: scale)
        let acc = controlReady ? Design.Color.accentBright(dark) : NSColor.secondaryLabelColor

        // маркёр-линия (та же грамматика, что у тика кольца: accentBright, 2px)
        let line = NSBezierPath()
        line.move(to: CGPoint(x: hx, y: scale.minY)); line.line(to: CGPoint(x: hx, y: scale.maxY))
        line.lineWidth = 2
        acc.setStroke(); line.stroke()

        // грип-пилюля поверх трека (≈6×высота+бевел)
        let gw: CGFloat = 6
        let gh: CGFloat = scale.height + 4
        let grip = CGRect(x: hx - gw / 2, y: scale.midY - gh / 2, width: gw, height: gh)
        let gp = NSBezierPath(roundedRect: grip, xRadius: Design.Radius.pill, yRadius: Design.Radius.pill)
        acc.setFill(); gp.fill()
        // световой бевел-кромка
        Design.Color.rimHighlight(dark, 0.4).setStroke()
        gp.lineWidth = 1; gp.stroke()
    }
}
