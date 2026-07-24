import AppKit

/// Вкладка «Приватность» — радар исходящих соединений: куда сейчас «звонит» ваш Mac.
///
/// ЧЕСТНОСТЬ (закон продукта):
///  • ТОЛЬКО НАБЛЮДЕНИЕ. Данные — локальный снимок соединений (lsof, POSIX), без перехвата
///    и без единого сетевого запроса самого Kelvin. Страна-назначение — офлайн-база GeoIP.
///  • GeoIP nil = приватный/зарезервированный адрес → узел «Локальная сеть» (не выдумываем страну).
///  • Радар — это ДИАГРАММА СВЯЗЕЙ, лишь стилизованная под радар: узлы стран расставлены по
///    объёму трафика (равномерно по кольцу), а НЕ по географии — координат у нас нет и мы их
///    не изобретаем. Радиус/угол не означают «где физически» сервер.
///  • Заблокировать исходящее нельзя — только увидеть. Блок входящих (фаервол) и доменов (hosts)
///    живёт в Настройках; сюда мы его не тащим, чтобы не обещать невозможного.
///
/// Визуальная ДНК — из FlowView: стеклянные узлы, «живые» бегунки по спицам (CAKeyframeAnimation
/// position, .paced) + затухание на концах, всё под `Motion.reduced`. Данные приходят из того же
/// фон-снимка, что кормит гео-флаги вкладки «Приложения» (один lsof на оба — без двойного опроса).
final class PrivacyView: NSView {

    // MARK: - Входная модель (агрегируется из снимка соединений; ТРИ основы — страны/приложения/порты)
    enum Basis { case country, app, ports }       // основа радара: узлы = страны, приложения ИЛИ слушающие порты

    /// Строка разбора: один эндпоинт с ведущим глифом (иконка приложения / флаг страны / индикатор порта).
    /// `accent` — маркер «виден в сети» (порты): красит ведущий глиф в accent, иначе нейтраль.
    struct DrillRow { let id: String; let icon: NSImage?; let flag: String?; let name: String; let ep: String; var accent: Bool = false }
    /// Узел радара: страна (flag) ИЛИ приложение (icon). rows — разбор (эндпоинты), subCount — вторая
    /// размерность для обзора (стран у приложения / приложений у страны).
    struct Node {
        let key: String
        let title: String
        let flag: String?          // страна: эмодзи-флаг / 🌐; приложение: nil
        let icon: NSImage?         // приложение: иконка; страна: nil
        let isLocal: Bool          // страна == локальная сеть (нейтральный тинт)
        let conns: Int
        let subCount: Int
        let rows: [DrillRow]
    }
    private struct Model { let nodes: [Node]; let totalConns: Int; let totalApps: Int; let realDests: Int }

    private static let lanGlobe = "\u{1F310}"     // 🌐 — «локальная сеть/неизвестно» (как во вкладке «Приложения»)
    private static let maxNodes = 8               // потолок узлов на кольце (перебор сворачивается в легенду)
    private static let legendRows = 5             // фикс-число строк легенды (высота вкладки не прыгает)

    // MARK: - Состояние
    private var model = Model(nodes: [], totalConns: 0, totalApps: 0, realDests: 0)
    private var basis: Basis = .country           // основа радара (сегмент «Страны / Приложения / Порты»)
    /// Текущая основа + колбэк смены — чтобы плитка обновляла подпись/сноску честно под режим (исход/порты).
    var currentBasis: Basis { basis }
    var onBasisChange: ((Basis) -> Void)?
    private var focus: String? = nil              // ключ узла под курсором — подсветка (ховер)
    private var selected: String? = nil           // клик-погружение: разбор узла в области легенды
    private static let backKey = "\u{0}back"      // ключ строки-заголовка разбора («‹ назад»)
    private var legendTop: CGFloat = 0            // метрики области легенды (чтобы перестраивать её без полного relayout)
    private var legendW: CGFloat = 0

    // MARK: - Постоянные слои
    private let scopeBg = CAGradientLayer()       // радиальная «подложка радара» (еле-заметный accent-тинт)
    private let ringsLayer = CALayer()            // концентрические дальномерные кольца
    private let sweepHost = CALayer()             // вращающийся луч-развёртка (radar sweep)
    private let sweepBeam = CAShapeLayer()        // сектор луча
    private let sweepEdge = CAShapeLayer()        // яркая передняя кромка луча
    private let centerDisc = CALayer()            // стеклянный «ваш Mac» в центре
    private let centerGlow = CALayer()            // мягкий ореол центра
    private let centerGlyph = CALayer()           // SF-глиф ноутбука
    private let centerCap = CATextLayer()         // подпись «ВАШ MAC» / имя страны в фокусе
    private let summaryLayer = CATextLayer()      // строка-читалка: N соед · M напр · K прил
    private let sparkFill = CAShapeLayer()        // заливка-площадь спарклайна соединений за сессию
    private let sparkLine = CAShapeLayer()        // линия спарклайна
    private let sparkDot = CALayer()              // текущее значение (голова графика)
    private let emptyLayer = CATextLayer()        // «тишина в эфире» / «сбор соединений…»
    private var hasLoaded = false                 // был ли хоть один update(): до него не заявляем «тишину» (ещё не мерили)
    // Сегмент «Страны / Приложения / Порты» (верхняя полоса)
    private let segTrack = CALayer()              // трек-пилюля сегмента
    private let segPill = CALayer()               // подвижная активная треть
    private let segCountry = CATextLayer()
    private let segApp = CATextLayer()
    private let segPorts = CATextLayer()
    private var segCountryRect = CGRect.zero
    private var segAppRect = CGRect.zero
    private var segPortsRect = CGRect.zero
    private let toast = CATextLayer()             // всплывашка «Скопировано» при клике по IP

    // MARK: - Динамические слои (перестраиваются на смену модели)
    private struct NodeUI {
        let key: String
        let node: Node
        let disc = CALayer()
        let flag = CATextLayer()      // страна: флаг-эмодзи
        let iconLayer = CALayer()     // приложение: иконка в диске
        let count = CATextLayer()
        let spokeCore = CAShapeLayer()
        let spokeGlow = CAShapeLayer()
        let particle = CALayer()
        var center = CGPoint.zero
        var radius: CGFloat = 13
    }
    private struct LegendUI {
        let key: String
        let flag = CATextLayer()
        let icon = CALayer()          // иконка приложения / глиф в строках разбора (в обзоре скрыта)
        let name = CATextLayer()
        let stat = CATextLayer()
        var rect = CGRect.zero
        var copyText: String?         // ip:port строки разбора — клик копирует
    }
    private var nodes: [NodeUI] = []
    private var legend: [LegendUI] = []

    // MARK: - Служебное
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }
    private var radarCenter = CGPoint.zero          // центр радара в координатах вида (для путей бегунков)
    private var lastFingerprint = ""                // отпечаток модели: пропускаем перестройку на неизменном тике
    private var lastApps: [AppNet] = []             // последний снимок — чтобы пересобрать модель при смене основы
    private var lastCodeByIP: [String: String?] = [:]
    private var iconCache: [String: CGImage] = [:]  // декодированные иконки приложений (id → CGImage), чтобы не рвать каждые 5с
    private var toastGen = 0                         // поколение всплывашки: старый блок скрытия не гасит новую
    private var track: NSTrackingArea?

    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        let root = layer!

        scopeBg.type = .radial
        scopeBg.startPoint = CGPoint(x: 0.5, y: 0.5)
        scopeBg.endPoint = CGPoint(x: 1, y: 1)
        root.addSublayer(scopeBg)

        ringsLayer.masksToBounds = false
        root.addSublayer(ringsLayer)

        sweepBeam.fillRule = .nonZero
        sweepEdge.fillColor = nil
        sweepEdge.lineCap = .round
        sweepHost.addSublayer(sweepBeam)
        sweepHost.addSublayer(sweepEdge)
        sweepHost.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        root.addSublayer(sweepHost)

        centerGlow.masksToBounds = false
        root.addSublayer(centerGlow)
        centerDisc.cornerCurve = .continuous
        centerDisc.borderWidth = 1
        centerDisc.masksToBounds = false
        root.addSublayer(centerDisc)
        centerGlyph.contentsGravity = .resizeAspect
        root.addSublayer(centerGlyph)

        styleText(centerCap, size: 8, weight: .semibold, align: .center)
        centerCap.string = attrCaps(L("Ваш MAC"), color: .secondaryLabelColor)
        root.addSublayer(centerCap)

        sparkFill.fillColor = nil
        sparkLine.fillColor = nil
        sparkLine.lineWidth = 1.5
        sparkLine.lineJoin = .round
        sparkLine.lineCap = .round
        sparkDot.cornerRadius = 2
        sparkDot.masksToBounds = false
        root.addSublayer(sparkFill)
        root.addSublayer(sparkLine)
        root.addSublayer(sparkDot)

        styleText(summaryLayer, size: 11, weight: .semibold, align: .center)
        root.addSublayer(summaryLayer)

        styleText(emptyLayer, size: 11, weight: .regular, align: .center)
        emptyLayer.string = L("Тишина в эфире — исходящих соединений нет")
        emptyLayer.foregroundColor = NSColor.tertiaryLabelColor.cgColor
        emptyLayer.isHidden = true
        root.addSublayer(emptyLayer)

        // сегмент «Страны / Приложения»
        segTrack.cornerRadius = Design.Radius.track
        segTrack.cornerCurve = .continuous
        segPill.cornerRadius = Design.Radius.pill
        segPill.cornerCurve = .continuous
        root.addSublayer(segTrack)
        root.addSublayer(segPill)
        styleText(segCountry, size: 10, weight: .semibold, align: .center)
        styleText(segApp, size: 10, weight: .semibold, align: .center)
        styleText(segPorts, size: 10, weight: .semibold, align: .center)
        segCountry.string = L("Страны")
        segApp.string = L("Приложения")
        segPorts.string = L("Порты")
        root.addSublayer(segCountry)
        root.addSublayer(segApp)
        root.addSublayer(segPorts)

        styleText(toast, size: 10, weight: .semibold, align: .center)
        toast.string = L("Скопировано")
        toast.cornerRadius = Design.Radius.chip
        toast.cornerCurve = .continuous
        toast.isHidden = true
        root.addSublayer(toast)
    }

    // MARK: - Приём данных

    /// Обновить радар из фон-снимка соединений. `codeByIP` — уже посчитанная в фоне карта IP→ISO
    /// (nil = приватный/локальный). Зовётся с main из refreshAppFlags (тот же снимок, что и флаги «Приложений»).
    func update(apps: [AppNet], codeByIP: [String: String?]) {
        hasLoaded = true                            // первый замер пришёл → теперь пустое = честная «тишина», а не «ещё не мерили»
        lastApps = apps; lastCodeByIP = codeByIP    // запоминаем снимок для мгновенной пересборки при смене основы
        let m = buildModel(apps, codeByIP)
        // Отпечаток видимого состава узлов (+ основа): эфемерные соединения «дрожат», но кольцо узлов
        // обычно то же самое → не рвём слои и бегунки каждые 5с (иначе синхронный «моргок» частиц).
        // subCount+realDests в отпечатке: для «Портов» ловит смену loopback↔reachable того же порта
        // (иначе застрял бы тинт/сводка «наружу»); для стран/приложений — стабильные деривативы, no-op.
        var fp = (basis == .country ? "c|" : basis == .app ? "a|" : "p|")
               + m.nodes.map { "\($0.key):\($0.conns):\($0.subCount):\($0.rows.count)" }.joined(separator: "|")
               + "#\(m.totalConns)#\(m.totalApps)#\(m.realDests)"
        // В режиме разбора отпечаток обязан ловить смену адресов выбранного узла (CDN-ротация ip:port
        // при том же счётчике) — иначе раскрытый разбор показывал бы мёртвый адрес.
        if let s = selected, let n = m.nodes.first(where: { $0.key == s }) {
            fp += "@" + n.rows.map { $0.ep }.joined(separator: ",")
        }
        guard fp != lastFingerprint else { return }
        lastFingerprint = fp
        model = m
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private struct Tri { let appId: String; let appName: String; let appIcon: NSImage?; let code: String?; let ep: String }
    private static let localKey = "\u{0}local"

    private func flagFor(_ code: String?) -> String { code == nil ? Self.lanGlobe : GeoIP.flag(code!) }
    private func countryName(_ code: String?) -> String { code == nil ? L("Локальная сеть") : GeoIP.name(code!) }

    private func buildModel(_ apps: [AppNet], _ codeByIP: [String: String?]) -> Model {
        var tris: [Tri] = []
        var appIds = Set<String>()
        var realCodes = Set<String>()
        for app in apps {
            let ident = app.appPath ?? app.name   // стабильная тождественность (как resolveOnMain), не только имя
            for c in app.conns {
                let code = (codeByIP[c.remoteIP] ?? nil)          // String?? → String?
                tris.append(Tri(appId: ident, appName: app.name, appIcon: app.icon, code: code, ep: c.label))
                appIds.insert(ident)
                if let code = code { realCodes.insert(code) }
            }
        }
        if basis == .ports {                                  // узлы = процессы со слушающими TCP-портами
            let nodes = nodesByPort(apps)
            let totalPorts = nodes.reduce(0) { $0 + $1.conns }        // всего открытых портов
            let reach = nodes.reduce(0) { $0 + $1.subCount }          // из них «наружу» (не-loopback)
            return Model(nodes: nodes, totalConns: totalPorts, totalApps: nodes.count, realDests: reach)
        }
        let nodes = basis == .country ? nodesByCountry(tris) : nodesByApp(tris)
        return Model(nodes: nodes, totalConns: tris.count, totalApps: appIds.count, realDests: realCodes.count)
    }

    /// Узлы = ПРОЦЕССЫ со слушающими TCP-портами. Разбор = их сокеты (● виден в сети / только этот Mac).
    /// isLocal (нейтральный тинт) = ВСЕ порты процесса на loopback; хоть один не-loopback → accent («поверхность»).
    private func nodesByPort(_ apps: [AppNet]) -> [Node] {
        var out: [Node] = []
        for app in apps where !app.listens.isEmpty {
            let id = app.appPath ?? app.name
            var seen = Set<String>()
            let uniq = app.listens.filter { seen.insert($0.proto + $0.label).inserted }
            let reachCount = uniq.filter { $0.reachable }.count
            let sorted = uniq.sorted {                                 // видимые в сети — вперёд, затем по порту
                if $0.loopback != $1.loopback { return !$0.loopback }
                if $0.port != $1.port { return $0.port < $1.port }
                return $0.label < $1.label
            }
            let rows = sorted.map { s -> DrillRow in
                var nm = s.reachable ? L("Виден в сети") : L("Только этот Mac")
                if let svc = PortServices.name(port: s.port) { nm += " · " + svc }   // обычный сервис номера (не проверка процесса)
                return DrillRow(id: id, icon: nil, flag: "\u{25CF}",
                                name: nm, ep: s.proto + "  " + s.label, accent: s.reachable)
            }
            out.append(Node(key: id, title: app.name, flag: nil, icon: app.icon,
                            isLocal: reachCount == 0, conns: uniq.count, subCount: reachCount, rows: rows))
        }
        out.sort {                                                     // «поверхность» (что-то наружу) — вперёд
            if ($0.subCount > 0) != ($1.subCount > 0) { return $0.subCount > 0 }
            if $0.conns != $1.conns { return $0.conns > $1.conns }
            return $0.key < $1.key
        }
        return out
    }

    /// Узлы = СТРАНЫ. Разбор = приложения (иконка) → их ip:port. Внешние вперёд, локаль в хвост.
    private func nodesByCountry(_ tris: [Tri]) -> [Node] {
        final class A { let name: String; let icon: NSImage?; var eps = Set<String>(); init(_ n: String, _ i: NSImage?) { name = n; icon = i } }
        final class C { var conns = 0; var apps: [String: A] = [:]; var code: String? = nil }
        var byCode: [String: C] = [:]
        for t in tris {
            let k = t.code ?? Self.localKey
            let c = byCode[k] ?? { let x = C(); x.code = t.code; byCode[k] = x; return x }()
            c.conns += 1
            let a = c.apps[t.appId] ?? { let x = A(t.appName, t.appIcon); c.apps[t.appId] = x; return x }()
            a.eps.insert(t.ep)
        }
        var out: [Node] = []
        for (k, c) in byCode {
            let appsSorted = c.apps.sorted { $0.value.eps.count != $1.value.eps.count ? $0.value.eps.count > $1.value.eps.count : $0.key < $1.key }
            var rows: [DrillRow] = []
            for (id, a) in appsSorted {
                for ep in a.eps.sorted() { rows.append(DrillRow(id: id, icon: a.icon, flag: nil, name: a.name, ep: ep)) }
            }
            out.append(Node(key: k, title: countryName(c.code), flag: flagFor(c.code), icon: nil,
                            isLocal: c.code == nil, conns: c.conns, subCount: c.apps.count, rows: rows))
        }
        // тай-брейк по уникальному ключу → детерминированный порядок кольца и стабильный отпечаток
        out.sort { if $0.isLocal != $1.isLocal { return !$0.isLocal }
                   if $0.conns != $1.conns { return $0.conns > $1.conns }
                   return $0.key < $1.key }
        return out
    }

    /// Узлы = ПРИЛОЖЕНИЯ. Разбор = их адреса (флаг страны) → ip:port. По объёму.
    private func nodesByApp(_ tris: [Tri]) -> [Node] {
        final class A { let name: String; let icon: NSImage?; var conns = 0; var countries = Set<String>()
                        var rows: [(code: String?, ep: String)] = []; init(_ n: String, _ i: NSImage?) { name = n; icon = i } }
        var byApp: [String: A] = [:]
        for t in tris {
            let a = byApp[t.appId] ?? { let x = A(t.appName, t.appIcon); byApp[t.appId] = x; return x }()
            a.conns += 1
            if let code = t.code { a.countries.insert(code) }
            a.rows.append((t.code, t.ep))
        }
        var out: [Node] = []
        for (id, a) in byApp {
            var seen = Set<String>()
            let uniq = a.rows.filter { seen.insert("\($0.code ?? "*")|\($0.ep)").inserted }
            let sorted = uniq.sorted {
                if ($0.code == nil) != ($1.code == nil) { return $0.code != nil }   // внешние вперёд
                if $0.code != $1.code { return countryName($0.code) < countryName($1.code) }
                return $0.ep < $1.ep
            }
            let rows = sorted.map { DrillRow(id: $0.code ?? Self.localKey, icon: nil, flag: flagFor($0.code), name: countryName($0.code), ep: $0.ep) }
            // isLocal = все адреса приложения локальные (нет внешних стран) → нейтральный тинт, как у стран
            out.append(Node(key: id, title: a.name, flag: nil, icon: a.icon, isLocal: a.countries.isEmpty,
                            conns: a.conns, subCount: a.countries.count, rows: rows))
        }
        out.sort { $0.conns != $1.conns ? $0.conns > $1.conns : $0.key < $1.key }
        return out
    }

    // MARK: - Раскладка (всё позиционируем здесь; координаты — от нижнего-левого, как в FlowView)

    override func layout() {
        super.layout()
        relayout()
    }

    private func relayout() {
        guard bounds.width > 40, bounds.height > 40 else { return }
        let W = bounds.width, H = bounds.height
        let gap: CGFloat = 6
        let topBand: CGFloat = 22                   // полоса под сегмент «Страны / Приложения»
        let legendH = CGFloat(Self.legendRows) * 20
        let summaryH: CGFloat = 20
        let sparkH: CGFloat = 16
        let radarH = max(120, H - topBand - legendH - summaryH - sparkH - gap * 3)
        let radarRect = CGRect(x: 0, y: (H - topBand) - radarH, width: W, height: radarH)
        let center = CGPoint(x: radarRect.midX, y: radarRect.midY)
        radarCenter = center
        let R = min(radarRect.width, radarRect.height) / 2
        let nodeR: CGFloat = 13
        let ringR = R - nodeR - 14                 // радиус кольца узлов (место под диск + счётчик)
        let centerR: CGFloat = 23

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyColors()

        // сегмент «Страны / Приложения» в верхней полосе
        layoutSegment(band: CGRect(x: 0, y: H - topBand, width: W, height: topBand))

        // подложка-радар
        scopeBg.frame = CGRect(x: center.x - R, y: center.y - R, width: R * 2, height: R * 2)
        scopeBg.cornerRadius = R

        // дальномерные кольца
        layoutRings(center: center, maxR: ringR + 6)

        // луч-развёртка
        sweepHost.frame = radarRect
        sweepHost.position = center
        layoutSweep(radius: ringR + 6)

        // центр — «ваш Mac»
        centerDisc.frame = CGRect(x: center.x - centerR, y: center.y - centerR, width: centerR * 2, height: centerR * 2)
        centerDisc.cornerRadius = centerR
        centerGlow.frame = centerDisc.frame.insetBy(dx: -8, dy: -8)
        centerGlow.cornerRadius = centerR + 8
        let gsz: CGFloat = 22
        centerGlyph.frame = CGRect(x: center.x - gsz / 2, y: center.y - gsz / 2 + 1, width: gsz, height: gsz)
        centerCap.frame = CGRect(x: center.x - 60, y: center.y - centerR - 13, width: 120, height: 11)

        // узлы + спицы
        rebuildNodes(center: center, ringR: ringR, nodeR: nodeR)

        // спарклайн соединений за сессию (полоса под радаром)
        let sparkRect = CGRect(x: 8, y: radarRect.minY - gap - sparkH, width: W - 16, height: sparkH)
        drawSparkline(in: sparkRect)

        // сводка
        let summaryY = sparkRect.minY - gap - summaryH
        summaryLayer.frame = CGRect(x: 0, y: summaryY, width: W, height: summaryH)
        summaryLayer.string = summaryString()

        // легенда (метрики запоминаем — клик-погружение перестраивает её без полного relayout)
        legendW = W
        legendTop = summaryY - gap
        rebuildLegend()

        // пустое состояние: ДО первого замера — «сбор соединений…» (не заявляем «тишину», ещё не мерили);
        // после — честный текст по основе (тишина в эфире / нет открытых портов).
        let empty = model.totalConns == 0
        if !hasLoaded {
            emptyLayer.string = L("Сбор соединений…")
            emptyLayer.isHidden = false
        } else {
            emptyLayer.string = basis == .ports ? L("Слушающих TCP-портов нет") : L("Тишина в эфире — исходящих соединений нет")
            emptyLayer.isHidden = !empty
        }
        emptyLayer.frame = CGRect(x: 12, y: center.y - ringR + 6, width: W - 24, height: 30)

        CATransaction.commit()

        // Живём только когда реально видны: скрытая плитка сохраняет frame и window (см. HardwareView) —
        // без этой проверки луч и бегунки крутились бы на другой вкладке впустую.
        if window != nil, !isHiddenOrHasHiddenAncestor { startAnimations() } else { stopAnimations() }
        applyFocusStyling()
        updateAccessibility()
    }

    private func layoutRings(center: CGPoint, maxR: CGFloat) {
        ringsLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let count = 3
        for i in 1...count {
            let r = maxR * CGFloat(i) / CGFloat(count)
            let ring = CAShapeLayer()
            ring.path = CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2), transform: nil)
            ring.fillColor = nil
            ring.lineWidth = 1
            ring.strokeColor = Design.Color.hairline(isDark, isDark ? 0.14 : 0.10).cgColor
            ringsLayer.addSublayer(ring)
        }
        // тонкие оси-кресты для «прицела»
        for (dx, dy) in [(CGFloat(1), CGFloat(0)), (CGFloat(0), CGFloat(1))] {
            let axis = CAShapeLayer()
            let p = CGMutablePath()
            p.move(to: CGPoint(x: center.x - maxR * dx, y: center.y - maxR * dy))
            p.addLine(to: CGPoint(x: center.x + maxR * dx, y: center.y + maxR * dy))
            axis.path = p
            axis.lineWidth = 1
            axis.strokeColor = Design.Color.hairline(isDark, isDark ? 0.08 : 0.06).cgColor
            ringsLayer.addSublayer(axis)
        }
    }

    private func layoutSweep(radius: CGFloat) {
        // сектор ~46° в собственных координатах sweepHost (центр = середина bounds)
        let c = CGPoint(x: sweepHost.bounds.midX, y: sweepHost.bounds.midY)
        let a0: CGFloat = 0, a1: CGFloat = .pi / 180 * 46
        let sec = CGMutablePath()
        sec.move(to: c)
        sec.addArc(center: c, radius: radius, startAngle: a0, endAngle: a1, clockwise: false)
        sec.closeSubpath()
        sweepBeam.path = sec
        let edge = CGMutablePath()
        edge.move(to: c)
        edge.addLine(to: CGPoint(x: c.x + cos(a1) * radius, y: c.y + sin(a1) * radius))
        sweepEdge.path = edge
        sweepEdge.lineWidth = 1.5
    }

    /// Сегмент «Страны / Приложения / Порты» — переключатель основы радара (три равные трети).
    private func layoutSegment(band: CGRect) {
        let segW = min(264, band.width - 24), segH: CGFloat = 18
        let x = band.midX - segW / 2, y = band.midY - segH / 2, third = segW / 3
        segTrack.frame = CGRect(x: x, y: y, width: segW, height: segH)
        segTrack.backgroundColor = Design.Color.tabTrack(isDark).cgColor
        segCountryRect = CGRect(x: x, y: y, width: third, height: segH)
        segAppRect = CGRect(x: x + third, y: y, width: third, height: segH)
        segPortsRect = CGRect(x: x + third * 2, y: y, width: segW - third * 2, height: segH)   // последняя треть — остаток
        let active = basis == .country ? segCountryRect : basis == .app ? segAppRect : segPortsRect
        segPill.frame = active.insetBy(dx: 2, dy: 2)
        segPill.backgroundColor = Design.Color.accentMuted(isDark).cgColor
        for (t, r, on) in [(segCountry, segCountryRect, basis == .country), (segApp, segAppRect, basis == .app), (segPorts, segPortsRect, basis == .ports)] {
            t.frame = CGRect(x: r.minX, y: r.midY - 6, width: r.width, height: 12)
            t.foregroundColor = (on ? NSColor.labelColor : NSColor.secondaryLabelColor).cgColor
        }
    }

    /// Кратко показать «Скопировано» у точки клика (обратная связь копирования IP).
    private func flashToast(at p: CGPoint) {
        toast.foregroundColor = NSColor.labelColor.cgColor
        toast.backgroundColor = Design.Color.controlFill(isDark).cgColor
        let w: CGFloat = 92, h: CGFloat = 16
        toast.frame = CGRect(x: min(max(p.x - w / 2, 4), bounds.width - w - 4), y: p.y + 3, width: w, height: h)
        toast.isHidden = false
        toast.removeAnimation(forKey: "toast")
        toastGen &+= 1
        let gen = toastGen
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [0, 1, 1, 0]; a.keyTimes = [0, 0.12, 0.72, 1]
        a.duration = 1.1; a.isRemovedOnCompletion = true
        CATransaction.begin()
        // прячет только САМАЯ свежая всплывашка (иначе старый блок гасит новую при быстром повторе)
        CATransaction.setCompletionBlock { [weak self] in guard let self, self.toastGen == gen else { return }; self.toast.isHidden = true }
        toast.add(a, forKey: "toast")
        CATransaction.commit()
    }

    /// Спарклайн общего числа соединений за сессию (тренд из AppSession.connHistory).
    private func drawSparkline(in rect: CGRect) {
        let hist = AppSession.connHistory()
        guard rect.width > 8, hist.count >= 2 else {
            sparkFill.isHidden = true; sparkLine.isHidden = true; sparkDot.isHidden = true
            return
        }
        sparkFill.isHidden = false; sparkLine.isHidden = false; sparkDot.isHidden = false
        let acc = Design.Color.accent(isDark)
        sparkLine.strokeColor = acc.withAlphaComponent(isDark ? 0.8 : 0.7).cgColor
        sparkFill.fillColor = acc.withAlphaComponent(isDark ? 0.12 : 0.10).cgColor
        sparkDot.backgroundColor = acc.cgColor

        let maxV = CGFloat(max(1, hist.max() ?? 1))
        let n = hist.count
        let dx = rect.width / CGFloat(max(1, n - 1))
        func pt(_ i: Int) -> CGPoint {
            let v = CGFloat(hist[i]) / maxV
            return CGPoint(x: rect.minX + CGFloat(i) * dx, y: rect.minY + 1 + v * (rect.height - 2))
        }
        let line = CGMutablePath()
        line.move(to: pt(0))
        for i in 1..<n { line.addLine(to: pt(i)) }
        sparkLine.path = line
        let fill = CGMutablePath()               // площадь под линией (к нижней кромке полосы)
        fill.move(to: CGPoint(x: rect.minX, y: rect.minY))
        for i in 0..<n { fill.addLine(to: pt(i)) }
        fill.addLine(to: CGPoint(x: rect.minX + CGFloat(n - 1) * dx, y: rect.minY))
        fill.closeSubpath()
        sparkFill.path = fill
        let head = pt(n - 1)                      // голова графика = текущее значение
        sparkDot.frame = CGRect(x: head.x - 2, y: head.y - 2, width: 4, height: 4)
    }

    private func rebuildNodes(center: CGPoint, ringR: CGFloat, nodeR: CGFloat) {
        nodes.forEach { n in
            [n.disc, n.flag, n.iconLayer, n.count, n.spokeCore, n.spokeGlow, n.particle].forEach { $0.removeFromSuperlayer() }
        }
        nodes.removeAll()
        let shown = Array(model.nodes.prefix(Self.maxNodes))
        guard !shown.isEmpty else { return }
        let n = shown.count
        let maxConns = max(1, shown.map { $0.conns }.max() ?? 1)
        for (i, nd) in shown.enumerated() {
            // равномерно по кольцу, старт сверху, по часовой (диаграмма связей, не карта)
            let ang = CGFloat.pi / 2 - CGFloat(i) / CGFloat(n) * 2 * .pi
            let pt = CGPoint(x: center.x + cos(ang) * ringR, y: center.y + sin(ang) * ringR)
            // радиус диска ∝ объёму трафика (шкала честная: больше соединений → крупнее узел)
            let r = (nodeR - 2) + 6 * CGFloat(Double(nd.conns) / Double(maxConns))   // 11…17
            var ui = NodeUI(key: nd.key, node: nd)
            ui.center = pt
            ui.radius = r

            // спица (ореол под низом, ядро сверху) — путь центр→узел
            let path = CGMutablePath()
            path.move(to: center)
            path.addLine(to: pt)
            for s in [ui.spokeGlow, ui.spokeCore] { s.path = path; s.fillColor = nil; s.lineCap = .round }
            ui.spokeGlow.lineWidth = 5
            ui.spokeCore.lineWidth = 1.5
            layer?.addSublayer(ui.spokeGlow)
            layer?.addSublayer(ui.spokeCore)

            // бегунок
            ui.particle.frame = CGRect(x: pt.x - 2.5, y: pt.y - 2.5, width: 5, height: 5)
            ui.particle.cornerRadius = 2.5
            ui.particle.masksToBounds = false
            layer?.addSublayer(ui.particle)

            // узел-диск
            ui.disc.frame = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
            ui.disc.cornerRadius = r
            ui.disc.cornerCurve = .continuous
            ui.disc.borderWidth = 1
            layer?.addSublayer(ui.disc)

            if let flag = nd.flag {                 // основа «Страны» — флаг-эмодзи в диске
                styleText(ui.flag, size: 14, weight: .regular, align: .center)
                ui.flag.string = flag
                ui.flag.frame = CGRect(x: pt.x - r, y: pt.y - 8, width: r * 2, height: 16)
                layer?.addSublayer(ui.flag)
            } else {                                // основа «Приложения» — иконка в диске
                let isz = r * 1.3
                ui.iconLayer.frame = CGRect(x: pt.x - isz / 2, y: pt.y - isz / 2, width: isz, height: isz)
                ui.iconLayer.contentsGravity = .resizeAspect
                ui.iconLayer.contentsScale = scale
                ui.iconLayer.cornerRadius = Design.Radius.appIcon
                ui.iconLayer.cornerCurve = .continuous
                ui.iconLayer.masksToBounds = true
                ui.iconLayer.contents = iconFor(nd.key, nd.icon)
                layer?.addSublayer(ui.iconLayer)
            }

            styleText(ui.count, size: 9, weight: .semibold, align: .center)
            ui.count.string = "\(nd.conns)"
            ui.count.frame = CGRect(x: pt.x - 14, y: pt.y - r - 11, width: 28, height: 11)
            layer?.addSublayer(ui.count)

            nodes.append(ui)
        }
        colorNodes()
    }

    private func rebuildLegend() {
        legend.forEach { l in [l.flag, l.icon, l.name, l.stat].forEach { $0.removeFromSuperlayer() } }
        legend.removeAll()
        guard legendW > 0 else { return }
        // выбранный узел мог исчезнуть на новом снимке → возвращаемся к обзору
        if let s = selected, !model.nodes.contains(where: { $0.key == s }) { selected = nil }
        if let s = selected, let nd = model.nodes.first(where: { $0.key == s }) {
            renderDetail(nd)
        } else {
            renderOverview()
        }
    }

    /// Ведущий глиф строки: флаг-эмодзи (основа «Приложения» / страна) ИЛИ иконка (основа «Страны» / приложение).
    private func setLeading(_ ui: LegendUI, flag: String?, icon: NSImage?, id: String) {
        if let flag = flag {
            ui.flag.string = flag; ui.icon.isHidden = true
        } else {
            ui.icon.contents = iconFor(id, icon); ui.icon.isHidden = false
        }
    }
    private func subStat(_ conns: Int, _ sub: Int) -> String {
        switch basis {
        case .country: return String(format: L("%d соед. · %d прил."), conns, sub)
        case .app:     return String(format: L("%d соед. · %d стран"), conns, sub)
        case .ports:   return String(format: L("%d порт. · %d наружу"), conns, sub)
        }
    }

    /// Пустой каркас строки легенды (3 колонки: флаг · имя · стат) на слоте i.
    private func makeRow(_ key: String, _ i: Int, statW: CGFloat = 120) -> LegendUI {
        let W = legendW, rowH: CGFloat = 20
        let y = legendTop - CGFloat(i + 1) * rowH + 3
        var ui = LegendUI(key: key)
        ui.rect = CGRect(x: 0, y: y - 3, width: W, height: rowH)
        styleText(ui.flag, size: 13, weight: .regular, align: .center)
        styleText(ui.name, size: 12, weight: .regular, align: .left)
        styleText(ui.stat, size: 11, weight: .medium, align: .right)
        ui.flag.frame = CGRect(x: 6, y: y, width: 20, height: 15)
        ui.icon.frame = CGRect(x: 6, y: y - 1, width: 16, height: 16)   // иконка приложения (разбор) — в слоте флага
        ui.icon.contentsGravity = .resizeAspect
        ui.icon.contentsScale = scale
        ui.icon.cornerRadius = Design.Radius.appIcon
        ui.icon.cornerCurve = .continuous
        ui.icon.masksToBounds = true
        ui.icon.isHidden = true
        ui.name.frame = CGRect(x: 30, y: y, width: (W - 6 - statW) - 6 - 30, height: 15)  // 6px жёлоб до стата
        ui.stat.frame = CGRect(x: W - 6 - statW, y: y, width: statW, height: 15)
        return ui
    }
    private func addRow(_ ui: LegendUI) {
        layer?.addSublayer(ui.flag); layer?.addSublayer(ui.icon); layer?.addSublayer(ui.name); layer?.addSublayer(ui.stat)
        legend.append(ui)
    }

    /// Обзор: топ-узлы (клик по строке → погружение в разбор этого узла).
    private func renderOverview() {
        let nds = model.nodes
        let slots = Self.legendRows
        let extra = nds.count - slots
        for i in 0..<slots {
            // строка-«ещё N» инертна (пустой ключ): она не должна тайком открывать разбор
            let ui = makeRow((i == slots - 1 && extra > 0) ? "" : (i < nds.count ? nds[i].key : ""), i)
            if i == slots - 1 && extra > 0 {
                ui.flag.string = "…"
                ui.name.string = String(format: L("ещё %d узлов"), extra + 1)
                ui.name.foregroundColor = NSColor.tertiaryLabelColor.cgColor
                ui.stat.string = ""
            } else if i < nds.count {
                let nd = nds[i]
                setLeading(ui, flag: nd.flag, icon: nd.icon, id: nd.key)
                ui.name.string = nd.title
                ui.name.foregroundColor = (nd.isLocal ? NSColor.secondaryLabelColor : NSColor.labelColor).cgColor
                ui.stat.string = subStat(nd.conns, nd.subCount)
                ui.stat.foregroundColor = NSColor.secondaryLabelColor.cgColor
            } else {
                ui.flag.string = ""; ui.name.string = ""; ui.stat.string = ""
            }
            addRow(ui)
        }
    }

    /// Разбор узла: заголовок «‹ узел» + строки «глиф — имя — ip:port» (честный адрес из lsof, клик копирует).
    private func renderDetail(_ nd: Node) {
        // заголовок (клик → назад к обзору)
        let h = makeRow(Self.backKey, 0)
        setLeading(h, flag: nd.flag, icon: nd.icon, id: nd.key)
        h.name.string = "‹  " + nd.title
        h.name.foregroundColor = NSColor.labelColor.cgColor
        h.stat.string = subStat(nd.conns, nd.subCount)
        h.stat.foregroundColor = NSColor.secondaryLabelColor.cgColor
        addRow(h)

        let rows = nd.rows                            // уже отсортированы построителем модели
        let cap = Self.legendRows - 1                 // слоты под адреса (минус строка-заголовок)
        let overflow = rows.count > cap
        let showN = overflow ? cap - 1 : min(rows.count, cap)   // последний слот резервируем под «+N» при переполнении
        for k in 0..<cap {
            var ui = makeRow("", k + 1, statW: 150)   // адресу нужно больше места, чем сводке обзора
            if k < showN {
                let row = rows[k]
                setLeading(ui, flag: row.flag, icon: row.icon, id: row.id)   // иконка приложения / флаг страны / ● порта
                if basis == .ports {                                        // ● красим: accent = виден в сети, иначе нейтраль
                    ui.flag.foregroundColor = (row.accent ? Design.Color.accent(isDark) : Design.Color.neutralNode(isDark)).cgColor
                }
                ui.name.string = row.name
                ui.name.foregroundColor = (basis == .ports && !row.accent ? NSColor.secondaryLabelColor : NSColor.labelColor).cgColor
                ui.stat.string = row.ep
                ui.stat.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                ui.stat.truncationMode = .middle      // длинный IPv6 не должен «съедать» :порт с правого края
                ui.stat.foregroundColor = NSColor.secondaryLabelColor.cgColor
                ui.copyText = row.ep                  // клик по строке → копировать ip:port
            } else if k == showN && overflow {
                ui.flag.string = "…"
                ui.name.string = String(format: L("ещё %d адресов"), rows.count - showN)
                ui.name.foregroundColor = NSColor.tertiaryLabelColor.cgColor
            }
            addRow(ui)
        }
    }

    // MARK: - Цвет

    private func applyColors() {
        let acc = Design.Color.accent(isDark)
        scopeBg.colors = [acc.withAlphaComponent(isDark ? 0.10 : 0.07).cgColor,
                          acc.withAlphaComponent(0).cgColor]
        sweepBeam.fillColor = acc.withAlphaComponent(isDark ? 0.10 : 0.08).cgColor
        sweepEdge.strokeColor = acc.withAlphaComponent(isDark ? 0.45 : 0.35).cgColor

        centerDisc.backgroundColor = Design.Color.glassTint(acc, isDark).cgColor
        centerDisc.borderColor = Design.Color.surfaceRim(isDark).cgColor
        centerGlow.backgroundColor = nil
        centerGlow.shadowColor = acc.cgColor
        centerGlow.shadowOffset = .zero
        centerGlow.shadowRadius = 12
        centerGlow.shadowOpacity = isDark ? 0.55 : 0.4
        centerGlyph.contents = symbolCG("laptopcomputer", size: 22, color: acc)
    }

    private func colorNodes() {
        let acc = Design.Color.accent(isDark)
        let neutral = Design.Color.neutralNode(isDark)
        for ui in nodes {
            let tint = ui.node.isLocal ? neutral : acc
            ui.disc.backgroundColor = Design.Color.glassTint(tint, isDark).cgColor
            ui.disc.borderColor = Design.Color.surfaceRim(isDark).cgColor
            ui.spokeCore.strokeColor = tint.withAlphaComponent(isDark ? 0.7 : 0.6).cgColor
            ui.spokeGlow.strokeColor = tint.withAlphaComponent(isDark ? 0.16 : 0.12).cgColor
            ui.count.foregroundColor = NSColor.secondaryLabelColor.cgColor
            ui.particle.backgroundColor = tint.cgColor
            ui.particle.shadowColor = tint.cgColor
            ui.particle.shadowOffset = .zero
            ui.particle.shadowRadius = 3
            ui.particle.shadowOpacity = 0.9
        }
    }

    // MARK: - Анимации (луч + бегунки; всё под Motion.reduced)

    private func startAnimations() {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return }
        // луч-развёртка (идемпотентно: не перезапускаем, если уже крутится)
        if Motion.reduced {
            sweepHost.removeAnimation(forKey: "spin")
            sweepHost.transform = CATransform3DMakeRotation(.pi / 6, 0, 0, 1)   // статичный луч
        } else if sweepHost.animation(forKey: "spin") == nil {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0; spin.toValue = -Double.pi * 2
            spin.duration = 6.0
            spin.repeatCount = .infinity
            spin.isRemovedOnCompletion = false
            sweepHost.add(spin, forKey: "spin")
        }
        // бегунки по спицам (перепривязываем к текущим — узлы могли перестроиться)
        for ui in nodes { animateParticle(ui) }
    }

    /// Погасить живость (луч + бегунки). Зовётся при уходе с вкладки и закрытии поповера.
    func stopAnimations() {
        sweepHost.removeAnimation(forKey: "spin")
        for ui in nodes { ui.particle.removeAnimation(forKey: "flow"); ui.particle.removeAnimation(forKey: "obod") }
        toast.removeAnimation(forKey: "toast"); toast.isHidden = true   // не оставлять «Скопировано» висеть при уходе/закрытии
    }

    private func animateParticle(_ ui: NodeUI) {
        let dur = max(1.3, 2.6 - Double(min(ui.node.conns, 10)) * 0.1)
        // «Порты» = входящая поверхность → бегунок идёт узел→центр (внутрь), иначе центр→узел (исходящее).
        let (from, to) = basis == .ports ? (ui.center, radarCenter) : (radarCenter, ui.center)
        let path = CGMutablePath()
        path.move(to: from)
        path.addLine(to: to)
        if Motion.reduced {
            ui.particle.position = CGPoint(x: (radarCenter.x + ui.center.x) / 2, y: (radarCenter.y + ui.center.y) / 2)
            ui.particle.opacity = 1
            return
        }
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.calculationMode = .paced
        move.duration = dur
        move.repeatCount = .infinity
        move.fillMode = .both
        move.isRemovedOnCompletion = false
        ui.particle.add(move, forKey: "flow")

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 1.0, 1.0, 0.0]
        fade.keyTimes = [0.0, 0.18, 0.82, 1.0]
        fade.duration = dur
        fade.repeatCount = .infinity
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        fade.timingFunction = CAMediaTimingFunction(name: .linear)
        ui.particle.add(fade, forKey: "obod")
    }

    /// Мягкий вход при показе вкладки — лёгкий «пинг» центра и (пере)запуск живости.
    func animateIn() {
        guard window != nil else { return }
        startAnimations()
        guard !Motion.reduced else { return }
        let pulse = CABasicAnimation(keyPath: "transform.scale")
        pulse.fromValue = 0.86; pulse.toValue = 1.0
        pulse.duration = Design.Motion.durSlow
        pulse.timingFunction = Design.Motion.overshoot
        centerDisc.add(pulse, forKey: "in")
        centerGlyph.add(pulse, forKey: "in")
        for (i, ui) in nodes.enumerated() {
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0; a.toValue = 1
            a.beginTime = CACurrentMediaTime() + Double(i) * Design.Motion.stagger
            a.duration = Design.Motion.durBase
            a.fillMode = .both
            ui.disc.add(a, forKey: "in"); ui.flag.add(a, forKey: "in"); ui.iconLayer.add(a, forKey: "in"); ui.count.add(a, forKey: "in")
        }
    }

    // MARK: - Ховер-интерактив (подсветка направления под курсором)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = track { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t); track = t
    }

    override func mouseMoved(with event: NSEvent) {
        guard selected == nil else { return }        // в режиме разбора ховер-подсветка молчит
        let p = convert(event.locationInWindow, from: nil)
        var hit: String? = nil
        for ui in nodes where hypot(p.x - ui.center.x, p.y - ui.center.y) <= ui.radius + 5 { hit = ui.key; break }
        if hit == nil { for l in legend where !l.key.isEmpty && l.rect.contains(p) { hit = l.key; break } }
        if hit != focus { focus = hit; applyFocusStyling() }
    }
    override func mouseExited(with event: NSEvent) { if focus != nil { focus = nil; applyFocusStyling() } }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // сегмент «Страны / Приложения / Порты»
        if segCountryRect.contains(p) { setBasis(.country); return }
        if segAppRect.contains(p) { setBasis(.app); return }
        if segPortsRect.contains(p) { setBasis(.ports); return }
        // клик по строке-адресу в разборе → копировать ip:port
        if selected != nil, let l = legend.first(where: { $0.copyText != nil && $0.rect.contains(p) }), let ip = l.copyText {
            let pb = NSPasteboard.general; pb.clearContents(); pb.setString(ip, forType: .string)
            flashToast(at: CGPoint(x: p.x, y: l.rect.maxY))
            return
        }
        var hit: String? = nil
        for ui in nodes where hypot(p.x - ui.center.x, p.y - ui.center.y) <= ui.radius + 6 { hit = ui.key; break }
        if hit == nil { for l in legend where !l.key.isEmpty && l.rect.contains(p) { hit = l.key; break } }
        if hit == Self.backKey { setSelected(nil); return }          // строка-заголовок разбора → назад
        if let h = hit { setSelected(selected == h ? nil : h) }      // узел/строка → тоггл
        else if selected != nil, !legend.contains(where: { $0.rect.contains(p) }) { setSelected(nil) }  // клик ВНЕ строк разбора → закрыть
    }

    /// Переключить основу радара (страны ↔ приложения). Пересобираем модель из последнего снимка сразу
    /// (не ждём следующего тика), иначе радар остался бы на старой основе до ~5с.
    func setBasis(_ b: Basis) {                 // internal: снапшот-режим переключает сегменты (Страны/Приложения/Порты)
        guard b != basis else { return }
        basis = b
        selected = nil
        focus = nil
        lastFingerprint = ""
        model = buildModel(lastApps, lastCodeByIP)
        needsLayout = true
        layoutSubtreeIfNeeded()
        onBasisChange?(b)               // плитка меняет подпись/сноску под режим (исходящие ↔ порты)
    }

    /// Клик-погружение в направление (или выход). Перестраивает ТОЛЬКО легенду — радар и бегунки не трогаем.
    private func setSelected(_ s: String?) {
        let valid = (s != nil && model.nodes.contains { $0.key == s }) ? s : nil
        guard valid != selected else { return }
        selected = valid
        focus = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        rebuildLegend()
        CATransaction.commit()
        applyFocusStyling()
        updateAccessibility()
    }

    private func applyFocusStyling() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Design.Motion.durFast)
        let f = selected ?? focus                    // клик перебивает ховер
        for ui in nodes {
            let on = (f == nil || ui.key == f)
            ui.disc.opacity = on ? 1 : 0.4
            ui.flag.opacity = on ? 1 : 0.4       // flag/iconLayer взаимоисключающие — гасим оба (no-op для пустого)
            ui.iconLayer.opacity = on ? 1 : 0.4
            ui.count.opacity = on ? 1 : 0.4
            ui.spokeCore.opacity = on ? 1 : 0.25
            ui.spokeGlow.opacity = (f != nil && ui.key == f) ? 1 : (f == nil ? 1 : 0.25)
            ui.particle.opacity = on ? 1 : 0.15
        }
        // в обзоре подсвечиваем строку под фокусом; в разборе легенда — это детали, не гасим
        if selected == nil {
            for l in legend where !l.key.isEmpty {
                let on = (f == nil || l.key == f)
                l.flag.opacity = on ? 1 : 0.4; l.icon.opacity = on ? 1 : 0.4; l.name.opacity = on ? 1 : 0.4; l.stat.opacity = on ? 1 : 0.4
            }
        } else {
            for l in legend { l.flag.opacity = 1; l.icon.opacity = 1; l.name.opacity = 1; l.stat.opacity = 1 }
        }
        // центр-подпись показывает имя направления в фокусе, иначе «ВАШ MAC»
        if let f = f, let d = nodes.first(where: { $0.key == f })?.node {
            centerCap.string = attrCaps(d.title, color: .labelColor)
        } else {
            centerCap.string = attrCaps(L("Ваш MAC"), color: .secondaryLabelColor)
        }
        CATransaction.commit()
    }

    /// VoiceOver: радар — статичный текст со сводкой и топ-направлениями (слои сами по себе немые).
    private func updateAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(L("Приватность · радар"))
        let real = model.realDests
        let (c1, c2, c3) = basis == .ports
            ? (L("порт."), L("наружу"), L("проц."))
            : (L("соед."), L("напр."), L("прил."))
        var v = "\(model.totalConns) " + c1 + ", \(real) " + c2 + ", \(model.totalApps) " + c3
        // caveat про интернет обязан ехать вместе с озвученным счётчиком «наружу» (сноска — отдельный
        // a11y-элемент, VoiceOver её не приложит) — иначе «1 наружу» звучит как ложная тревога.
        if basis == .ports { v += ". " + L("Видно в сети ≠ доступно из интернета") }
        let top = model.nodes.prefix(3).map { "\($0.title) \($0.conns)" }.joined(separator: ", ")
        if !top.isEmpty { v += ". " + top }
        setAccessibilityValue(v)
    }

    // MARK: - Жизненный цикл слоёв

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lastFingerprint = ""            // смена окна → следующий тик обязан перестроить слои
        selected = nil                  // переоткрытие поповера начинается с обзора, не с разбора
        if window == nil { stopAnimations() } else { needsLayout = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    // MARK: - Хелперы

    private func summaryString() -> NSAttributedString {
        let s = NSMutableAttributedString()
        func seg(_ n: Int, _ cap: String, first: Bool) {
            if !first { s.append(sepAttr()) }
            s.append(NSAttributedString(string: "\(n) ", attributes: [
                .font: Design.Font.numericBody, .foregroundColor: NSColor.labelColor]))
            s.append(NSAttributedString(string: cap, attributes: [
                .font: Design.Font.microStat, .foregroundColor: NSColor.secondaryLabelColor,
                .kern: Design.Font.capsKern]))
        }
        // «НАПР.» = внешние направления (страны). «Локальная сеть» — узел, но НЕ направление наружу:
        // иначе при чисто локальном трафике честнее «0 НАПР», а не «1».
        // В основе «Порты»: ПОРТ. = всего открытых, НАРУЖУ = видимых в сети (не-loopback), ПРОЦ. = процессов.
        let (c1, c2, c3) = basis == .ports
            ? (L("порт."), L("наружу"), L("проц."))
            : (L("соед."), L("напр."), L("прил."))
        seg(model.totalConns, c1, first: true)
        seg(model.realDests, c2, first: false)
        seg(model.totalApps, c3, first: false)
        return s
    }
    private func sepAttr() -> NSAttributedString {
        NSAttributedString(string: "   ·   ", attributes: [
            .font: Design.Font.numericBody, .foregroundColor: NSColor.tertiaryLabelColor])
    }

    /// Микро-подпись радара (обычный регистр, без апперкейса/кернинга — единый V3-регистр, без «дашборд-CAPS»).
    private func attrCaps(_ s: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: Design.Font.sys(8, .semibold), .foregroundColor: color])
    }

    private func styleText(_ l: CATextLayer, size: CGFloat, weight: NSFont.Weight, align: CATextLayerAlignmentMode) {
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        l.fontSize = size
        l.alignmentMode = align
        l.truncationMode = .end
        l.contentsScale = scale
        l.foregroundColor = NSColor.labelColor.cgColor
    }

    private func cgImage(_ img: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: img.size == .zero ? CGSize(width: 32, height: 32) : img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Иконка строки разбора с кэшем по стабильному id (иначе декодим NSWorkspace-иконку каждые 5с).
    /// Демон без .app-иконки → нейтральный SF-глиф (не выдаём за настоящее приложение).
    private func iconFor(_ id: String, _ img: NSImage?) -> CGImage? {
        if let img = img {
            if let c = iconCache[id] { return c }
            if let c = cgImage(img) { iconCache[id] = c; return c }
        }
        return symbolCG("app.dashed", size: 12, color: .tertiaryLabelColor)
    }

    private func symbolCG(_ name: String, size: CGFloat, color: NSColor) -> CGImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
        let img = NSImage(size: base.size)
        img.lockFocus()
        color.set()
        let r = NSRect(origin: .zero, size: base.size)
        base.draw(in: r)
        r.fill(using: .sourceAtop)
        img.unlockFocus()
        var rect = CGRect(origin: .zero, size: base.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
