import AppKit
import CoreAudio   // AudioDeviceID для плитки «Звук · вывод» (переключение системного вывода)
import ServiceManagement  // SMAppService.unregister() для --unregister-privileged-service

// MARK: - UI поповера

final class PopoverController: NSViewController {
    private let CW: CGFloat = 328       // современный popover: больше воздуха, без тесных трёхколоночных строк
    private let IW: CGFloat = 296       // ширина контента внутри плитки
    private let FW: CGFloat = 316       // полноширинный energy canvas с узким полем 6px
    private let appsBarW: CGFloat = 64  // лидерборд: энергобар сужен с 84 → имя дышит (не truncate)
    private let appsValW: CGFloat = 30  // колонка значения (поджата с 34); шапка садится над ней
    private let appsFlagW: CGFloat = 16 // колонка флага страны-назначения
    private let appsSparkW: CGFloat = 44 // мини-спарклайн истории impact между именем и баром
    private let fixedFooterHeight: CGFloat = 43
    private var cards: [NSView] = []    // ссылки на карточки для смены темы
    /// Снапшот-режим (BM_SNAP): вместо пользовательской раскладки строим все модули (чтобы отснять всё),
    /// НЕ трогая UserDefaults владельца. nil в обычной работе.
    static var snapshotLayout: [PopoverItem]? = nil
    private let root = NSStackView()    // вертикальный стек модулей-плиток
    private var footer: NSView!         // нижние кнопки (строятся один раз)
    private var ccToggles: [CCToggle] = []   // плитка быстрых переключателей
    private var tabTiles: [Int: NSView] = [:]   // вкладки тяжёлых секций (индекс → плитка)
    private var tabOrder: [String] = []      // id вкладок в порядке таб-бара (для адресных warn/crit-точек)
    private var tabBar: PillTabBar?          // кастомный сегмент-контрол вкладок
    private let tabTitleLabel = NSTextField(labelWithString: "")   // имя активной вкладки (иконки-вкладки без подписей)
    private var currentTab = 0               // активная вкладка (для направления кросс-фейда)
    private var tabContainer: NSView?               // контейнер вкладок; в иерархии ТОЛЬКО показанная вкладка → адаптивная высота
    private weak var controlPanel: PopoverControlPanel?
    private static let topIDs: Set<String> = ["battery", "toggles", "batteryStats", "disk", "btbattery", "audio"]   // компактный верх
    /// Read-only стат-модули: смежный их прогон сливается в ОДНУ консоль-плитку с волосяными швами.
    private static let statIDs: Set<String> = ["batteryStats", "disk", "btbattery"]
    private static let tabIDs: Set<String> = ["flow", "hardware", "apps", "privacy", "maintenance", "history", "health"]   // секции-вкладки
    /// Ярлык вкладки — резолвим L() СВЕЖИМ при каждой сборке таб-бара (buildModules), а не один раз:
    /// иначе static let замораживал бы язык первого показа и вкладки не переводились бы при смене языка.
    private static func tabLabel(_ id: String) -> String {
        switch id {
        case "flow":        return L("Питание")
        case "hardware":    return L("Железо")
        case "apps":        return L("Приложения")
        case "privacy":     return L("Приватность")
        case "maintenance": return L("Обслуживание")
        case "history":     return L("История")
        case "health":      return L("Здоровье")
        default:            return id
        }
    }
    /// SF-иконка вкладки — таб-бар переходит на иконки при 5+ вкладках (текст не влезает), имя = tooltip.
    private static func tabIcon(_ id: String) -> String {
        switch id {
        case "flow":        return "bolt.fill"
        case "hardware":    return "cpu"
        case "apps":        return "square.grid.2x2.fill"
        case "privacy":     return "shield.lefthalf.filled"
        case "maintenance": return "wrench.and.screwdriver.fill"
        case "history":     return "chart.line.uptrend.xyaxis"
        case "health":      return "heart.fill"
        default:            return "square"
        }
    }
    // БЕЗОПАСНЫЙ isDark (Big Sur fix): читаем appearance КОРНЕВОГО контейнера через слабую ссылку,
    // а не `view` контроллера — прямое чтение `view` само запускает loadView(). Если это происходит
    // ВНУТРИ loadView (через appearance-callback), получаем бесконечную рекурсию. Ссылку ставим
    // сразу после создания container'а; до неё (или без view) берём системный appearance.
    // (viewIfLoaded недоступен при deployment target macOS 11 — используем собственную weak-ссылку.)
    private weak var appearanceSourceView: NSView?
    private var isDark: Bool {
        let appearance = appearanceSourceView?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    /// Reentrancy-гард loadView(): если что-то запросит view во время сборки, гасим вложенный вход.
    private var isBuildingView = false
    /// Regression-хук (assert): глубина вложенности loadView() должна быть 1. Не в release-билде.
    private var loadViewDepth = 0
    /// Бирюза зарядки = фирменный акцент Kelvin (единый бренд-токен, тема-зависимый).
    private var chargeAccent: NSColor { SettingsStore.brandAccent(dark: isDark) }
    private let ring = ChargeRing()
    private let chargeTrack = ChargeTrack()              // AlDente-дорожка заряда (строка 2 плитки): драг-потолок + паруса + режим
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusSub = NSTextField(labelWithString: "")
    // «Живой термо-прибор» (V2): дышащая аура состояния + топ-бар шапки (бренд + температура ядра).
    private let auraView = AuraView()                             // радиальный цвет-режим у верхней кромки поповера
    private let statSysVal = NSTextField(labelWithString: "—")
    private var statSysCap = NSTextField(labelWithString: "CPU")
    private let statBatVal = NSTextField(labelWithString: "—")
    // Четвёртая виталь — универсальная загрузка RAM. Ватт батареи убран: рядом с общим расходом
    // он выглядел как противоречащее число, хотя физически это другой замер.
    private var statBatCap = NSTextField(labelWithString: "RAM")
    // Витальные-приборы: CPU/Темп/Кулер/RAM. Темп тинтуется по режиму.
    private let statTempVal = NSTextField(labelWithString: "—")
    private var statTempCap = NSTextField(labelWithString: L("Темп."))
    private let statFanVal = NSTextField(labelWithString: "—")
    private var statFanCap = NSTextField(labelWithString: L("Вент."))
    private let graph = GraphView()
    private let flowView = FlowView(frame: .zero)
    private let flowInfoBar = FlowInfoBar(frame: .zero)
    private let thermalLabel = NSTextField(labelWithString: "")
    private var flowDetail: String?          // разбор узла под курсором (интерактив схемы)
    // V6: термосводка CPU°/GPU°/кулеров удалена (дублировала шапку поповера и вкладку «Железо») —
    // строка теперь ТОЛЬКО живой разбор узла/виджета под курсором, в покое пуста (высота стабильна).
    private func applyThermalLabel() {
        thermalLabel.stringValue = flowDetail ?? ""
        thermalLabel.textColor = .secondaryLabelColor
    }
    private let cellsLabel = NSTextField(labelWithString: "—")
    private var metric: [String: NSTextField] = [:]
    /// Фиксированные слоты строк Bluetooth-плитки (иконка + имя + заряд). Кол-во строк
    /// постоянно — высота поповера не прыгает при подключении/отключении устройств.
    private struct BTSlot { let row: NSStackView; let icon: NSImageView; let name: NSTextField; let value: NSTextField }
    private var btSlots: [BTSlot] = []
    /// Фиксированные слоты плитки «Звук · вывод»: иконка + имя устройства + галка (текущий дефолт).
    /// Клик по не-текущему слоту → сделать его выводом по умолчанию (Pro). Кол-во слотов постоянно.
    private struct AudioSlot { let row: PopoverActionRow; let icon: NSImageView; let name: NSTextField; let check: NSImageView; var deviceID: AudioDeviceID? }
    private var audioSlots: [AudioSlot] = []
    // Вкладка «История» V5 = карточка батареи (владелец: «30 дней CPU — мутные данные»).
    // Пилюли метрик/диапазонов удалены; SQLite пишет все метрики как прежде (90 дней — PDF/тренд/CSV).
    private var historyChart: HistoryChart?
    private let historyHero = TabStatusHeroView()
    private let historyFooter = NSTextField(labelWithString: "")
    private let historyDegrade = NSTextField(labelWithString: "")   // строка деталей тренда под графиком
    private let historyVerdict = NSTextField(labelWithString: "")   // ГОТОВЫЙ ВЫВОД («АКБ стабильна» / «теряет N%/мес»)
    private let histCardHealth = NSTextField(labelWithString: "—")  // три крупных числа карточки
    private let histCardCycles = NSTextField(labelWithString: "—")
    private let histCardTrend = NSTextField(labelWithString: "—")

    // Advisor (Health Center) UI elements
    private let healthHero = TabStatusHeroView()
    private let healthFindingsContainer = NSStackView()
    private var lastAdvisorResult: AdvisorResult?
    private var advisorDismissalStore = AdvisorDismissalStore()
    private var latestAdvisorBattery: BatteryInfo?
    private var latestAdvisorEnergy = EnergySnapshot()
    private var latestAdvisorSensors = SensorsSnapshot()
    private var preferredSizeWorkItem: DispatchWorkItem?

    private let compStatus = NSTextField(labelWithString: "")
    private var comp: [String: NSTextField] = [:]
    private var installBtn = GlassButton(title: L("Установить хелпер…"), symbol: "arrow.down.circle")
    private let sensorsView = HardwareView(frame: .zero)
    private let hardwareHero = TabStatusHeroView()
    private let sensorDetail = NSTextField(labelWithString: "")
    private let privacyView = PrivacyView(frame: .zero)   // вкладка «Приватность» — радар соединений
    private var vpnChipRefresh: (() -> Void)?             // обновление VPN-чипа (при показе вкладки/после действия)

    private let appsStack = NSStackView()
    // Лидерборд приложений: имя (lowercased) → флаг страны-назначения активного соединения
    // («жрёт батарею И звонит домой» — приватность-сигнал). Считаем lsof в фоне, тут только кэш.
    private var appCountryFlags: [String: String] = [:]
    private var appsLast: [AppEnergy] = []     // последний снимок энергии — для перерисовки при приходе флагов
    // Футер вкладки «Приложения»: честная сводка из УЖЕ собранных данных (top-сводка/SystemUsage/AppSession) —
    // заполняет высоту вкладки (не «урезала» поповер) и даёт системный контекст под лидербордом.
    private let appsFootProcs = NSTextField(labelWithString: "—")
    private let appsFootCPU = NSTextField(labelWithString: "—")
    private let appsFootMem = NSTextField(labelWithString: "—")
    private let hardwareStatus = NSTextField(labelWithString: "")
    private let appsTotalSpark = MiniSpark()
    private let appsUpdatedLabel = NSTextField(labelWithString: "")
    private var appsUpdatedAt: Date?
    private var appFlagsBusy = false           // защита от наслоения фоновых lsof-снимков

    // ДОСЬЕ (Batch D): тап по строке лидерборда → флип на заднюю грань = досье приложения.
    // Состояние openDossier — ИНВАРИАНТ перерендера: пока задано, renderAppRows рисует ЛИЦО
    // досье (не лидерборд) и обновляет его НА МЕСТЕ — живой снимок/гео-колбэк не сносят флип.
    private var openDossierName: String? = nil       // сырое a.name (ключ корреляции); nil = лидерборд
    private var dossierConns: [NetConn] = []          // соединения приложения (свой snapshot, НЕ из refreshAppFlags)
    private var dossierCountries: [String] = []       // уникальные гео-метки "🇺🇸 США" в порядке появления
    private var dossierHasLAN = false                 // были conns без гео (LAN/неизвестно)
    private var dossierAppPath: String? = nil         // путь к .app (Finder/блок); nil у демонов/несматченных
    private var dossierBusy = false                   // защита от наслоения фоновых snapshot для досье
    private weak var dossierBackButton: NSView?       // для VoiceOver-фокуса при открытии
    private weak var appsFlipHost: NSView?            // обёртка appsStack — на ней крутим/фейдим флип

    // ГИБРИД A+ГЕРОЙ: FLIP-переиспользование строк по имени (НЕ removeFromSuperview каждый тик).
    private var appsSort: AppEnergySort = .impact      // сегмент сортировки: Расход / CPU / Сеть
    private var appRows: [String: DossierRowView] = [:]  // сырое имя → живая карточка (герой ⊂ этого же словаря)
    private var appHeroName: String?                    // имя карточки, отрисованной как ГЕРОЙ
    private var hoveredRowName: String?                 // строка под курсором: замораживаем reorder, чтобы она не уехала при клике
    private var pendingAppsSnapshot: [AppEnergy]?       // отложенный снимок, пришедший под ховером — применим по mouseExited
    private weak var appsHeader: NSView?                // шапка колонки + сегмент сортировки (переиспользуем)
    private weak var appsVerdict: NSTextField?         // вывод-вердикт «кто грузит» над лидербордом (переиспользуем)
    private var tempCritStreak = 0                     // устойчивость крит-температуры: мгновенный скачок ≠ «Перегрев»
    private var lastVerdictLevel: Design.Level = .ok   // резолвнутый уровень вердикта → тинт кольца (герой-шапка)
    private var lastAuraColor: NSColor? = nil          // аура строго следует кольцу; guard не перезапускает fade каждый тик

    private static func sectionLabel(_ s: String) -> NSTextField {
        // V3 (совет по типографике): заголовки секций — ОБЫЧНЫЙ регистр, без трекинга, вторичный цвет.
        // CAPS-подписи = сильнейший «самодельный-дашборд» тэлл; у Control Center капса нет. Строки уже в нужном регистре.
        let l = NSTextField(labelWithString: s)
        l.font = Design.Font.sys(11, .medium)
        l.textColor = .secondaryLabelColor
        return l
    }
    /// Динамическая подпись (меняется в update()): V3 — без трекинга/капса, регистр берём из строки.
    private func capsText(_ field: NSTextField, _ s: String) {
        field.stringValue = s
    }

    // MARK: — честные форматтеры вкладки «Приложения»

    /// MEM в человекочитаемом виде: <1024 МБ → «N МБ», иначе → «N.N ГБ».
    private func fmtMem(_ mb: Double) -> String {
        AppEnergyFormatting.memory(
            megabytes: mb,
            megabytesFormat: L("%.0f МБ"),
            gigabytesFormat: L("%.1f ГБ")
        )
    }
    /// impact — безразмерный (НАГРУЗКА/РАСХОД), НИКОГДА «Вт».
    private func fmtImpact(_ v: Double) -> String { AppEnergyFormatting.impact(v) }
    private func fmtCPU(_ c: Double) -> String { AppEnergyFormatting.cpu(c) }

    /// Значение колонки по текущей сортировке (для строки/героя): impact/CPU%/impact.
    private func appValueText(_ a: AppEnergy) -> String {
        AppEnergyPresentation.valueText(
            for: a,
            sort: appsSort,
            networkCount: appNetCount
        )
    }
    /// Число направлений (уникальных стран) исходящих соединений приложения за сессию — метрика режима «Сеть».
    private func appNetCount(_ a: AppEnergy) -> Int {
        AppSession.countryCodes(nameLower: a.name.lowercased()).count
    }
    /// Величина АКТИВНОГО сорта — длина энергобара и значение колонки берут ЕЁ, а не всегда impact:
    /// иначе в режимах CPU/Сеть бар противоречил и числу, и порядку строк.
    private func appSortMetric(_ a: AppEnergy) -> Double {
        AppEnergyPresentation.metric(
            for: a,
            sort: appsSort,
            networkCount: appNetCount
        )
    }

    /// Отсортированный снимок по текущему сегменту (Расход/CPU/Сеть). tie-break — impact.
    private func sortedApps(_ apps: [AppEnergy]) -> [AppEnergy] {
        AppEnergyPresentation.sorted(
            apps,
            by: appsSort,
            networkCount: appNetCount
        )
    }

    /// ТУЛТИП-ХЕЛПЕР (правило): ставит full ТОЛЬКО если текст реально усечён (изм. ширина > доступной).
    /// Иначе toolTip = nil (не плодим пустой зуд). Зовётся ПОСЛЕ layout (иначе avail неизвестна).
    private func applyTruncTip(_ field: NSTextField, full: String, avail: CGFloat) {
        let measured = (full as NSString).size(withAttributes: [.font: field.font ?? Design.Font.caption]).width
        field.toolTip = (avail > 0 && measured > avail + 0.5) ? full : nil
    }

    override func loadView() {
        // КРИТИЧНО ПОРЯДКУ (Big Sur fix): присваиваем корневой view ДО любой настройки
        // NSVisualEffectView. Присвоение material/blendingMode/state может синхронно вызвать
        // viewDidChangeEffectiveAppearance → onAppearanceChange → applyTheme → чтение isDark →
        // (если view ещё не присвоен) повторный loadView → переполнение стека. Поэтому container
        // становится self.view первым, а тяжёлая сборка идёт под reentrancy-гардом.
        let container = GlassContainer()
        view = container
        appearanceSourceView = container    // isDark читает appearance отсюда, не трогая `view`.
        // Reentrancy-страховка: если что-то снова запросит view во время этой сборки, мы не уйдём
        // в рекурсию — view уже присвоен (минимальный GlassContainer), а вложенную сборку гасим.
        guard !isBuildingView else {
            Log.app.fault("Recursive popover view construction blocked")
            return
        }
        isBuildingView = true
        defer { isBuildingView = false }

        // Regression-хук (debug/snapshot): глубина loadView должна быть ровно 1. assert ловит
        // регрессию появления рекурсии на раннем этапе, не ломая release-сборку.
        loadViewDepth += 1
        assert(loadViewDepth == 1, "PopoverController.loadView() re-entered")
        defer { loadViewDepth -= 1 }

        configureLeaves()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 9
        root.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false
        buildFooter()

        // Стеклянный фон (NSVisualEffectView) — нативный «glass» для Sequoia.
        // onAppearanceChange подключаем В САМОМ КОНЦЕ сборки (после buildModules): пока он nil,
        // синхронный viewDidChangeEffectiveAppearance от material/state безопасно игнорируется.
        container.material = .popover
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        // V3: контент в ВЕРТИКАЛЬНОМ скролле → с любым набором модулей поповер влезает и ЛИСТАЕТСЯ.
        // Высоту берём от НАТУРАЛЬНОГО контента (updatePreferredSize от root.fittingSize): короткая вкладка →
        // короткий поповер (пустота внизу уходит), контент выше экрана → скролл. Скролл ПРОЗРАЧНЫЙ (стекло/аура сквозят).
        let scroll = NSScrollView()
        scroll.contentView = TopClipView()          // перевёрнутый клип → контент СВЕРХУ (не якорится к низу)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.documentView = root
        let footerHost = NSView()
        footerHost.translatesAutoresizingMaskIntoConstraints = false
        let footerSeam = HairlineView()
        footerSeam.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        footerHost.addSubview(footerSeam)
        footerHost.addSubview(footer)
        container.addSubview(scroll)
        container.addSubview(footerHost)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: footerHost.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerHost.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footerHost.heightAnchor.constraint(equalToConstant: fixedFooterHeight),
            footerSeam.topAnchor.constraint(equalTo: footerHost.topAnchor),
            footerSeam.leadingAnchor.constraint(equalTo: footerHost.leadingAnchor, constant: 14),
            footerSeam.trailingAnchor.constraint(equalTo: footerHost.trailingAnchor, constant: -14),
            footerSeam.heightAnchor.constraint(equalToConstant: 1),
            footer.centerXAnchor.constraint(equalTo: footerHost.centerXAnchor),
            footer.centerYAnchor.constraint(equalTo: footerHost.centerYAnchor, constant: 1),
            // документ (root) = ширина viewport (без гориз. скролла), высота НАТУРАЛЬНАЯ (верт. скролл)
            root.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            root.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        // Дышащая аура состояния (V2 «живой термо-прибор») — ПОД контентом, у верхней кромки: тинтует
        // стекло цветом теплового режима. Перекрашивается медленно при смене вердикта (refreshHealthVerdict).
        auraView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(auraView, positioned: .below, relativeTo: scroll)
        // Пришпилено ко ВСЕМ кромкам контейнера → аура НИКОГДА не влияет на fittingSize/размер поповера
        // (баг «растягивается при тоггле»); свечение концентрируется вверху через фикс-полосу в AuraView.layout().
        NSLayoutConstraint.activate([
            auraView.topAnchor.constraint(equalTo: container.topAnchor),
            auraView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            auraView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            auraView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        // view уже присвоен в самом верху loadView — это намеренно. isDark читает
        // view.effectiveAppearance; стартовый фон+цвет ауры ставим здесь, на собранной иерархии.
        auraView.applyBase(dark: isDark, opacity: CGFloat(SettingsStore.popoverOpacity))
        auraView.setColor(Design.Color.stateColor(.ok, isDark), animated: false)
        buildModules()

        // onAppearanceChange подключаем ПОСЛЕ полной сборки иерархии: callback не обращается к
        // self.view во время loadView, а isDark теперь безопасно читает уже загруженный view.
        // Дополнительно GlassContainer сам откладывает вызов в async (защита от синхронного
        // реентера из material/appearance).
        container.onAppearanceChange = { [weak self, weak container] in
            guard let self,
                  let container,
                  self.appearanceSourceView === container
            else { return }
            self.applyTheme()
        }
    }

    /// Одноразовая настройка постоянных вью-листьев (шрифты, фикс-размеры).
    private func configureLeaves() {
        ring.translatesAutoresizingMaskIntoConstraints = false
        // Компактный приборный якорь: статус читается мгновенно, но не отнимает
        // половину первого экрана у выбранного рабочего раздела.
        ring.widthAnchor.constraint(equalToConstant: 70).isActive = true
        ring.heightAnchor.constraint(equalToConstant: 70).isActive = true
        statusTitle.font = Design.Font.headline; statusTitle.alignment = .right
        statusSub.font = Design.Font.caption; statusSub.textColor = .secondaryLabelColor; statusSub.alignment = .right
        statusSub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.heightAnchor.constraint(equalToConstant: 60).isActive = true   // выше — место под оси/сетку/подписи
        graph.widthAnchor.constraint(equalToConstant: FW).isActive = true
        flowView.translatesAutoresizingMaskIntoConstraints = false
        flowView.heightAnchor.constraint(equalToConstant: 244).isActive = true
        flowView.widthAnchor.constraint(equalToConstant: FW).isActive = true
        flowView.detailSink = { [weak self] detail in self?.flowDetail = detail; self?.applyThermalLabel() }
        flowInfoBar.translatesAutoresizingMaskIntoConstraints = false
        flowInfoBar.heightAnchor.constraint(equalToConstant: 58).isActive = true
        flowInfoBar.widthAnchor.constraint(equalToConstant: FW).isActive = true
        flowInfoBar.detailSink = { [weak self] detail in
            // полоса делит сток-подпись со схемой: её разбор перебивает термо-сводку, как и разбор узла
            self?.flowDetail = detail; self?.applyThermalLabel()
        }
        thermalLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)   // цвет ставит applyThermalLabel (один ранг)
        sensorsView.translatesAutoresizingMaskIntoConstraints = false
        sensorsView.detailSink = { [weak self] d in self?.sensorDetail.stringValue = d }
        sensorDetail.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        sensorDetail.textColor = .secondaryLabelColor; sensorDetail.lineBreakMode = .byTruncatingTail
        compStatus.font = .systemFont(ofSize: 10); compStatus.textColor = .secondaryLabelColor
        compStatus.lineBreakMode = .byWordWrapping; compStatus.maximumNumberOfLines = 2
        installBtn.onClick = { [weak self] in self?.showInstall() }
        appsStack.orientation = .vertical; appsStack.alignment = .leading; appsStack.spacing = 5
        privacyView.translatesAutoresizingMaskIntoConstraints = false
        privacyView.heightAnchor.constraint(equalToConstant: 348).isActive = true   // +18 под спарклайн-полосу
        privacyView.widthAnchor.constraint(equalToConstant: FW).isActive = true
    }
    private func buildFooter() {
        func iconBtn(_ symbol: String, _ target: AnyObject?, _ action: Selector, _ tip: String) -> NSButton {
            let b = FooterIconButton(title: "", target: target, action: action)
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)  // единый вес со шкалой символов
            b.imageScaling = .scaleProportionallyDown
            b.isBordered = false
            b.contentTintColor = .secondaryLabelColor
            b.toolTip = tip
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 28).isActive = true
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
            b.setup()
            return b
        }
        // «второй мозг» продукта (Caffeine/Night Shift/фаервол/dev/безопасность) больше не спрятан
        // только за правым кликом — даём ему видимую точку входа в футере.
        let tools = iconBtn("ellipsis.circle", NSApp.delegate, #selector(AppDelegate.openToolsFromFooter), L("Инструменты"))
        let settings = iconBtn("gearshape", self, #selector(openSettings), L("Настройки"))
        let quit = iconBtn("power", NSApp, #selector(NSApplication.terminate(_:)), L("Выйти"))
        let f = NSStackView(views: [spacer(), tools, settings, quit])
        f.spacing = 8
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: CW).isActive = true
        footer = f
    }

    /// Пересобирает поповер: компактный верх (battery/toggles/stats) стопкой,
    /// тяжёлые секции (flow/hardware/apps) — через сегмент-контрол, по одной за раз.
    /// Обновить подписи статических элементов при смене языка. Вызывается из buildModules().
    private func relocalizeStatic() {
        statSysCap.stringValue = "CPU"
        statBatCap.stringValue = "RAM"
        statTempCap.stringValue = L("Темп.")
        statFanCap.stringValue = L("Вент.")
        installBtn.title = L("Установить хелпер…")
        for v in (footer as? NSStackView)?.subviews ?? [] {
            if let b = v as? FooterIconButton, let sel = b.action {
                if sel == #selector(AppDelegate.openToolsFromFooter) { b.toolTip = L("Инструменты") }
                else if sel == #selector(openSettings) { b.toolTip = L("Настройки") }
                else if sel == #selector(NSApplication.terminate(_:)) { b.toolTip = L("Выйти") }
            }
        }
    }

    func buildModules() {
        relocalizeStatic()
        cards.removeAll(); ccToggles = []; tabTiles = [:]; btSlots = []; tabContainer = nil
        controlPanel = nil
        // прогреваем сенсоры данными ДО замера высоты вкладок — иначе пустая панель
        // дала бы заниженную высоту контейнера и обрезала бы низ. record:false — прогрев НЕ пишет
        // в кольцо трассы (ребилд по BMPopoverChanged иначе впрыснул бы внеплановый кадр); 1Гц-тик владеет историей.
        sensorsView.update(SensorsModel.snapshot(cpuLoad: SystemUsage.shared.cpu(),
                                                 ramLoad: SystemUsage.shared.ram(),
                                                 components: PowerInfo.components(), record: false))
        for v in root.arrangedSubviews { root.removeArrangedSubview(v); v.removeFromSuperview() }
        // десктоп без АКБ — прячем батарейные модули (кольцо/статистику), остальное остаётся
        let noBattery = ProcessInfo.processInfo.environment["BM_NOBATT"] != nil || BatteryReader.read() == nil
        // .filter на РЕЗУЛЬТАТ ??, а не только на фолбэк: иначе снапшот-дефолт с on:false-модулями строил бы
        // ВСЕ (консоль/диск/BT) и снимок не совпал бы с тем, что реально видит владелец. No-op для MIN/ALL/шиппинга.
        var layout = (Self.snapshotLayout ?? SettingsStore.popoverLayout).filter { $0.on }
        if noBattery { layout = layout.filter { $0.id != "battery" && $0.id != "batteryStats" } }

        // Новая иерархия: компактная шапка → свёрнутое управление → активная вкладка.
        // Переключатели и звук больше не отнимают первый экран; дополнительные read-only
        // модули остаются доступными, но идут после главного раздела.
        let topItems = layout.filter { Self.topIDs.contains($0.id) }
        let controlIDs = topItems.map(\.id).filter { $0 == "toggles" || $0 == "audio" }
        let auxiliaryIDs = topItems.map(\.id).filter { Self.statIDs.contains($0) }
        var placedLead = false
        if topItems.contains(where: { $0.id == "battery" }), let battery = buildModule("battery") {
            root.addArrangedSubview(battery)
            placedLead = true
        }
        if !controlIDs.isEmpty {
            root.addArrangedSubview(buildControlPanel(ids: controlIDs))
            placedLead = true
        }

        let tabs = layout.filter { Self.tabIDs.contains($0.id) }
        tabOrder = tabs.map { $0.id }                 // запоминаем порядок для адресных warn/crit-точек
        if !tabs.isEmpty {
            if placedLead { root.addArrangedSubview(sectionDivider()) }   // делитель перед главным экраном
            // дефолт — последняя открытая вкладка (BM_TAB переопределяет для дебага)
            let savedID = UserDefaults.standard.string(forKey: "popover.lastTabID")
            let initTab = ProcessInfo.processInfo.environment["BM_TAB"].flatMap { Int($0) }
                ?? savedID.flatMap { id in tabs.firstIndex(where: { $0.id == id }) }
                ?? UserDefaults.standard.integer(forKey: "popover.lastTab")
            let sel = min(max(initTab, 0), tabs.count - 1)
            currentTab = sel
            let bar = PillTabBar(labels: tabs.map { Self.tabLabel($0.id) }, icons: tabs.map { Self.tabIcon($0.id) }, selected: sel)
            bar.onSelect = { [weak self] idx in self?.selectTab(idx) }
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: CW).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 32).isActive = true
            bar.pillColor = Design.Color.accent(isDark)   // «Спокойный прибор»: навигация НЕ красится состоянием — всегда бирюза
            tabBar = bar
            root.addArrangedSubview(bar)
            // При 5+ пользовательских вкладках таб-бар переходит на иконки, поэтому только
            // в этом режиме показываем текстовое имя. В продуктовом дефолте подписи уже в табах.
            if tabs.count >= 5 {
                tabTitleLabel.font = Design.Font.calloutEmph
                tabTitleLabel.textColor = .secondaryLabelColor
                tabTitleLabel.alignment = .left
                tabTitleLabel.stringValue = Self.tabLabel(tabs[sel].id)
                tabTitleLabel.translatesAutoresizingMaskIntoConstraints = false
                tabTitleLabel.widthAnchor.constraint(equalToConstant: CW).isActive = true
                root.addArrangedSubview(tabTitleLabel)
            }
            // Контейнер вкладок: в иерархии держим ТОЛЬКО ПОКАЗАННУЮ вкладку → его высота = её высоте
            // (истинно адаптивно; скрытые вкладки НЕ в иерархии → не раздувают fittingSize/высоту поповера →
            // пустота под короткими вкладками исчезает). Switch/снапшот переставляют вкладку (showTab).
            let container = NSView()
            container.translatesAutoresizingMaskIntoConstraints = false
            container.widthAnchor.constraint(equalToConstant: CW).isActive = true
            tabContainer = container
            // Временно строим плитки для кэша. Каждая вкладка сохраняет собственную естественную
            // высоту: короткие «Приложения» и «Железо» больше не растягиваются по самому высокому соседу.
            for (i, item) in tabs.enumerated() {
                if let tile = buildModule(item.id) {
                    tile.translatesAutoresizingMaskIntoConstraints = false
                    container.addSubview(tile)
                    NSLayoutConstraint.activate([
                        tile.topAnchor.constraint(equalTo: container.topAnchor),
                        tile.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                        tile.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    ])
                    tabTiles[i] = tile
                    tile.layoutSubtreeIfNeeded()
                }
            }
            // Оставляем в контейнере ТОЛЬКО показанную вкладку → контейнер = её высоте (адаптивно).
            for (_, t) in tabTiles { t.removeFromSuperview() }
            showTab(sel)
            root.addArrangedSubview(container)
        }
        if !auxiliaryIDs.isEmpty {
            if !tabs.isEmpty || placedLead { root.addArrangedSubview(sectionDivider()) }
            // Все вспомогательные факты объединяются в одну спокойную консоль после главной вкладки.
            root.addArrangedSubview(auxiliaryIDs.count > 1
                ? buildStatGroupTile(auxiliaryIDs)
                : (buildModule(auxiliaryIDs[0]) ?? NSView()))
        }
        paintCards()
        auraView.applyBase(dark: isDark, opacity: CGFloat(SettingsStore.popoverOpacity))   // прозрачность фона из настроек
        settlePreferredSize()
    }
    /// Смена вкладки с кросс-фейдом: уходящая плитка гаснет со сдвигом по X в сторону движения,
    /// приходящая — проявляется с противоположной. Высоту НЕ трогаем (контейнер фиксирован).
    /// Снапшот-рендер (BM_SNAP): офскрин `cacheDisplay` → PNG, БЕЗ окна и без Screen-Recording-TCC.
    /// Рендерит верх+каждую вкладку. Между кадрами прокачиваем run loop, чтобы async-данные (радар/чипы/
    /// сенсоры/аудио — они грузятся с фона на main) успели долиться. Возвращает число снятых кадров.
    func renderSnapshots(to dir: String, light: Bool) -> Int {
        _ = self.view                                   // триггерим loadView
        if light { self.view.appearance = NSAppearance(named: .aqua) }
        // Офскрин-окно (НИКОГДА не показываем): даёт view.window != nil, чтобы window-гейтнутые апдейты
        // (радар приватности/гео-флаги/чипы — они применяются лишь при наличии окна) реально сработали.
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 900),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        if light { win.appearance = NSAppearance(named: .aqua) }
        win.contentViewController = self
        buildModules()
        // Наполняем данными КАК настоящий тик: несколько апдейтов (история кольца/flow) + apps-лидерборд.
        // BM_NOBATT обязан подменять и данные, а не только скрывать шапку: иначе desktop-снапшот
        // случайно рисует аккумулятор хостового Mac и не проверяет честный fallback «Без батареи».
        let forcedNoBattery = ProcessInfo.processInfo.environment["BM_NOBATT"] != nil
        var hist: [Double] = []
        for _ in 0..<6 {
            let b = (forcedNoBattery ? nil : BatteryReader.read()) ?? .absent
            let e = EnergyModel.snapshot()
            let c = PowerInfo.components()
            let sensors = SensorsModel.snapshot(cpuLoad: SystemUsage.shared.cpu(),
                                                ramLoad: SystemUsage.shared.ram(),
                                                components: c)
            hist.append(e.systemWatts > 0.1 ? e.systemWatts : b.watts)
            if hist.count > 90 { hist.removeFirst() }
            update(battery: b, history: hist, components: c, energy: e, sensors: sensors)
            pumpRunLoop(0.4)
        }
        refreshApps()                                   // apps-лидерборд (через `top`, async)
        pumpRunLoop(3.0)
        var n = 0
        func shot(_ name: String) {
            self.view.layoutSubtreeIfNeeded()
            let sz = self.root.fittingSize        // полный скролл-контент + закреплённый футер
            win.setContentSize(NSSize(width: max(sz.width, CW), height: max(sz.height + fixedFooterHeight, 120)))
            self.view.layoutSubtreeIfNeeded()
            let r = self.view.bounds
            guard r.width > 1, r.height > 1, let rep = self.view.bitmapImageRepForCachingDisplay(in: r) else { return }
            self.view.cacheDisplay(in: r, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: String(format: "%@/%02d_%@.png", dir, n, name)))
                n += 1
            }
        }
        let order = tabOrder
        if order.isEmpty {
            shot("popover")
        } else {
            for (i, tid) in order.enumerated() {
                currentTab = i
                showTab(i)                               // в контейнере только показанная вкладка (адаптивная высота)
                // Snapshot должен проходить тот же путь визуального состояния, что и живой selectTab:
                // иначе на всех PNG оставались заголовок и подсветка первой вкладки «Питание».
                tabTitleLabel.stringValue = Self.tabLabel(tid)
                tabBar?.select(i, animated: false)
                if tid == "hardware" { sensorsView.animateIn() }
                if tid == "apps" { refreshApps() }
                if tid == "history" { refreshHistory() }
                if tid == "health" { refreshAdvisor() }
                if tid == "privacy" {                  // радар снимаем во ВСЕХ трёх сегментах (Страны/Приложения/Порты)
                    vpnChipRefresh?(); mediaChipRefresh?()
                    for (bname, b) in [("countries", PrivacyView.Basis.country), ("apps", PrivacyView.Basis.app), ("ports", PrivacyView.Basis.ports)] {
                        privacyView.setBasis(b); privacyView.animateIn()
                        updatePreferredSize(); pumpRunLoop(1.5)
                        shot("privacy_" + bname)
                    }
                    continue
                }
                updatePreferredSize()
                pumpRunLoop(2.5)                        // тик данных этой вкладки (apps-лидерборд/flow медленнее)
                shot(tid)
                if tid == "flow", ProcessInfo.processInfo.environment["BM_FLOW_DETAILS"] != nil {
                    for (suffix, node) in [("source", "Адаптер"), ("system", "Система"), ("battery", "Батарея")] {
                        flowView.focusNode(node)
                        pumpRunLoop(0.15)
                        shot("flow_" + suffix)
                    }
                }
            }
        }
        return n
    }
    /// Ручная прокачка главного run loop N секунд — исполняет отложенные/фон→main блоки без `app.run()`.
    private func pumpRunLoop(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }

    /// Показать вкладку i: в контейнере остаётся ТОЛЬКО она (пин top+bottom+leading+trailing = контейнер),
    /// прочие убраны из иерархии → высота контейнера = высоте показанной вкладки (адаптивно, без пустоты внизу).
    private func showTab(_ i: Int) {
        guard let container = tabContainer, let tile = tabTiles[i] else { return }
        for (k, t) in tabTiles where k != i && t.superview != nil { t.removeFromSuperview() }
        if tile.superview !== container {
            tile.removeFromSuperview()
            container.addSubview(tile)
            NSLayoutConstraint.activate([
                tile.topAnchor.constraint(equalTo: container.topAnchor),
                tile.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                tile.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                tile.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        tile.isHidden = false
    }

    private func selectTab(_ sel: Int) {
        guard sel != currentTab else { return }
        let prev = currentTab
        currentTab = sel
        UserDefaults.standard.set(sel, forKey: "popover.lastTab")   // legacy fallback для старой версии
        if sel < tabOrder.count {
            UserDefaults.standard.set(tabOrder[sel], forKey: "popover.lastTabID")
        }
        if sel < tabOrder.count { tabTitleLabel.stringValue = Self.tabLabel(tabOrder[sel]) }  // имя вкладки текстом (обычный регистр)
        // оживление тяжёлых вкладок
        if sel < tabOrder.count, tabOrder[sel] == "hardware" {
            DispatchQueue.main.async { [weak self] in self?.sensorsView.animateIn() }
        }
        if sel < tabOrder.count, tabOrder[sel] == "privacy" {
            DispatchQueue.main.async { [weak self] in self?.privacyView.animateIn(); self?.vpnChipRefresh?(); self?.mediaChipRefresh?() }
        }
        if prev < tabOrder.count, tabOrder[prev] == "privacy" { privacyView.stopAnimations() }
        if sel < tabOrder.count, tabOrder[sel] == "history" { DispatchQueue.main.async { [weak self] in self?.refreshHistory() } }
        if sel < tabOrder.count, tabOrder[sel] == "health" { DispatchQueue.main.async { [weak self] in self?.refreshAdvisor() } }
        // Адаптивный свап: в контейнере остаётся только показанная вкладка → поповер ресайзится под неё
        // (пустота под короткими вкладками исчезает). Уходящая убирается из иерархии — cross-fade скрытой не нужен.
        showTab(sel)
        settlePreferredSize()
        // Проявление новой вкладки со сдвигом в сторону движения (кроме «Уменьшить движение»).
        if !Motion.reduced, let inL = tabTiles[sel]?.layer {
            inL.removeAllAnimations()
            inL.opacity = 1; inL.transform = CATransform3DIdentity
            let dir: CGFloat = sel > prev ? 1 : -1
            let op = CABasicAnimation(keyPath: "opacity"); op.fromValue = 0; op.toValue = 1
            let tx = CABasicAnimation(keyPath: "transform.translation.x"); tx.fromValue = 6 * dir; tx.toValue = 0
            let g = CAAnimationGroup(); g.animations = [op, tx]; g.duration = Design.Motion.durBase; g.timingFunction = Design.Motion.easeIn
            inL.add(g, forKey: "tabIn")
        }
    }
    private func updatePreferredSize() {
        guard isViewLoaded else { return }
        view.layoutSubtreeIfNeeded()
        // Высоту берём от НАТУРАЛЬНОГО контента (root), а не от раздутого view.fittingSize (скролл его не отражает).
        // Кап по видимой высоте экрана: выше кэпа контент ЛИСТАЕТСЯ, ниже — поповер ровно по контенту (адаптивно).
        let sz = root.fittingSize
        // До появления окна `view.window?.screen` nil. В мультимониторной конфигурации берём экран
        // под курсором, иначе вторичный небольшой дисплей наследовал высоту основного.
        let mouse = NSEvent.mouseLocation
        let targetScreen = view.window?.screen
            ?? NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        let screenH = targetScreen?.visibleFrame.height ?? 900
        let cap = max(300, screenH - 72)
        preferredContentSize = NSSize(width: sz.width, height: min(sz.height + fixedFooterHeight, cap))
    }

    /// Auto Layout вкладки и async-контент не обязаны стабилизироваться в тот же run-loop pass.
    /// Два коротких повторных измерения устраняют первое «обрезанное» открытие, которое раньше
    /// случайно исправлялось scroll-событием. Последний вызов побеждает — без очереди resize-анимаций.
    private func settlePreferredSize() {
        preferredSizeWorkItem?.cancel()
        view.needsLayout = true
        root.needsLayout = true
        tabContainer?.needsLayout = true
        view.layoutSubtreeIfNeeded()
        root.layoutSubtreeIfNeeded()
        updatePreferredSize()

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.view.needsLayout = true
            self.root.needsLayout = true
            self.tabContainer?.needsLayout = true
            self.view.layoutSubtreeIfNeeded()
            self.root.layoutSubtreeIfNeeded()
            self.updatePreferredSize()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self else { return }
                self.view.layoutSubtreeIfNeeded()
                self.root.layoutSubtreeIfNeeded()
                self.updatePreferredSize()
            }
        }
        preferredSizeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: item)
    }
    private func buildModule(_ id: String) -> NSView? {
        switch id {
        case "battery":      return buildBatteryTile()
        case "flow":         return buildFlowTile()
        case "batteryStats": return buildBatteryStatsTile()
        case "hardware":     return buildHardwareTile()
        case "apps":         return buildAppsTile()
        case "privacy":      return buildPrivacyTile()
        case "maintenance":  return buildMaintenanceTile()
        case "disk":         return buildDiskTile()
        case "btbattery":    return buildBTBatteryTile()
        case "history":      return buildHistoryTile()
        case "health":       return buildHealthTile()
        default:             return nil
        }
    }

    /// Внутренний контент стат-модуля (без glass-обёртки) — для консоль-группы.
    private func statContent(for id: String) -> NSView? {
        switch id {
        case "batteryStats": return buildBatteryStatsContent()
        case "disk":         return buildDiskContent()
        case "btbattery":    return buildBTBatteryContent()
        default:             return nil
        }
    }

    /// Консоль-карта: смежный прогон стат-модулей в ОДНОЙ glass-плитке с волосяными швами между рядами.
    /// Высота РЕКЛАМИРУЕТСЯ обратно (один отступ вместо N плиточных) — никогда не растёт.
    private func buildStatGroupTile(_ run: [String]) -> NSView {
        var rows: [NSView] = []
        for (i, id) in run.enumerated() {
            guard let content = statContent(for: id) else { continue }
            if i > 0 { rows.append(divider()) }            // шов между модулями группы
            rows.append(content)
        }
        let stack = vstack(rows, 12)
        return glassTile(stack)
    }

    /// Витальные: компактная полоса CPU/Темп/Кулер/RAM с равными ячейками и hairline-разделителями.
    private func buildVitalsStrip() -> NSView {
        let pairs: [(NSTextField, NSTextField)] = [(statSysVal, statSysCap), (statTempVal, statTempCap),
                                                   (statFanVal, statFanCap), (statBatVal, statBatCap)]
        var cells: [NSView] = []
        var views: [NSView] = []
        for (i, (val, cap)) in pairs.enumerated() {
            if i > 0 { views.append(vitalDivider()) }
            let cell = vitalCell(val, cap)
            cells.append(cell); views.append(cell)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal; row.distribution = .fill; row.spacing = 0; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        for c in cells.dropFirst() { c.widthAnchor.constraint(equalTo: cells[0].widthAnchor).isActive = true }
        // V3: БЕЗ обрамляющей панели (бордюр карточки читался как ещё один шов) — 4 ячейки на единой
        // поверхности, разделённые только волосяными вертикалями (vitalDivider). Вертикальный воздух даёт
        // spacing родительского vstack шапки.
        row.widthAnchor.constraint(equalToConstant: IW).isActive = true
        return row
    }
    private func vitalCell(_ val: NSTextField, _ cap: NSTextField) -> NSView {
        val.font = Design.Font.mono(16, .semibold); val.alignment = .center
        cap.font = Design.Font.sys(11, .regular); cap.textColor = .tertiaryLabelColor; cap.alignment = .center   // V3: обычный регистр, 11pt
        let s = vstack([val, cap], 2); s.alignment = .centerX
        return s
    }
    private func vitalDivider() -> NSView {
        let d = NSView(); d.wantsLayer = true
        d.layer?.backgroundColor = Design.Color.hairline(isDark, 0.10).cgColor
        d.translatesAutoresizingMaskIntoConstraints = false
        d.widthAnchor.constraint(equalToConstant: 1).isActive = true
        d.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return d
    }
    /// Волосяной делитель СЕКЦИЙ (V3 «единая поверхность»): 0.5pt линия во всю ширину модуля (CW),
    /// разделяет модули на одной стеклянной панели вместо «плавающих» карточек (грамматика Control Center).
    private func sectionDivider() -> NSView {
        let d = NSView(); d.wantsLayer = true
        d.layer?.backgroundColor = Design.Color.hairline(isDark, isDark ? 0.10 : 0.12).cgColor
        d.translatesAutoresizingMaskIntoConstraints = false
        d.widthAnchor.constraint(equalToConstant: CW).isActive = true
        d.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return d
    }

    private func buildBatteryTile() -> NSView {
        // hero (V3): кольцо-заряд + статус словами, СЛЕВА-выровнено рядом (грамматика макета).
        // Вердикт-пилюля/слово («Нагрузка»/«Греется») ретайрнуты — владелец: слова лишние; состояние
        // несут тихая аура + тинт кольца. statusTitle/Sub теперь left-align (были right у прежней капсулы).
        statusTitle.alignment = .left
        statusSub.alignment = .left
        let statusCol = vstack([statusTitle, statusSub], 3); statusCol.alignment = .leading
        let hero = NSStackView(views: [ring, statusCol, spacer()])
        hero.alignment = .centerY
        hero.spacing = 14
        // Собственный воздух hero нужен именно вокруг круглого прибора: общий inset плитки
        // отделяет секцию от краёв, а эти поля не дают кольцу слипнуться с текстом и витальными.
        hero.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 3, right: 4)
        hero.translatesAutoresizingMaskIntoConstraints = false
        hero.widthAnchor.constraint(equalToConstant: IW).isActive = true
        // Витальные CPU/Темп/Кулер/RAM без бордюра, только с hairline-разделителями.
        let vitals = buildVitalsStrip()
        // строка режима заряда Выкл/Лимит/Парус — ЧИСТЫЙ сегмент; жирная полоса-дубль (ChargeTrack.bar,
        // дублировала % кольца — владелец звал её «ползунком») убрана из ChargeTrack.
        chargeTrack.translatesAutoresizingMaskIntoConstraints = false
        chargeTrack.widthAnchor.constraint(equalToConstant: IW).isActive = true
        // disclosure лимита меняет высоту дорожки → поповер должен подрасти/ужаться следом
        chargeTrack.onHeightChanged = { [weak self] in
            self?.view.layoutSubtreeIfNeeded()
            self?.updatePreferredSize()
        }
        // Настройка уже доступна в постоянном футере; отдельная пустая top-bar строка
        // убрана, чтобы активная вкладка поднялась выше первого экрана.
        return glassTile(vstack([hero, vitals, chargeTrack], 10), chrome: false)
    }
    private func buildFlowTile() -> NSView {
        // Главная вкладка: честный баланс источников + встроенный интерактивный инспектор.
        // Три нижних фактора дают контекст расхода, не притворяясь суммой общего ваттажа.
        glassTile(vstack([flowView, flowInfoBar], 8), hInset: 6, fill: true)
    }
    /// Обёртка фиксированной ширины с левым отступом — для выравнивания текста при узком поле плитки.
    private func padLeading(_ v: NSView, _ inset: CGFloat, width: CGFloat) -> NSView {
        let c = NSView(); c.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(v); v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            c.widthAnchor.constraint(equalToConstant: width),
            v.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: inset),
            v.topAnchor.constraint(equalTo: c.topAnchor),
            v.bottomAnchor.constraint(equalTo: c.bottomAnchor),
            v.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -inset),
        ])
        return c
    }
    /// Вкладка «Приватность» — радар исходящих соединений (PrivacyView) + честная сноска.
    /// Данные приходят из refreshAppFlags (тот же lsof-снимок, что кормит флаги «Приложений»).
    private func buildPrivacyTile() -> NSView {
        let sub = NSTextField(labelWithString: "")
        sub.font = Design.Font.caption; sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byWordWrapping; sub.maximumNumberOfLines = 2
        sub.preferredMaxLayoutWidth = FW - 20
        let note = NSTextField(labelWithString: "")
        note.font = Design.Font.sys(9, .regular); note.textColor = .tertiaryLabelColor
        note.lineBreakMode = .byWordWrapping; note.maximumNumberOfLines = 6   // «Порты»-сноска длиннее (оговорка про метки) — не режем
        note.preferredMaxLayoutWidth = FW - 20
        // Подпись/сноска зависят от основы: исходящие (страны/приложения) ↔ входящая поверхность (порты).
        // Честность: для портов явно оговариваем «видно в сети ≠ доступно из интернета».
        func applyBasis(_ b: PrivacyView.Basis) {
            if b == .ports {
                sub.stringValue = L("Какие порты открыты на этом Mac — слушающие TCP-сокеты и их видимость.")
                note.stringValue = L("Только наблюдение (lsof). «Наружу» — привязка к сетевому адресу (виден в вашей сети), «только этот Mac» — loopback. Видно в сети ≠ доступно из интернета: NAT и фаервол могут не пускать. Метка сервиса — обычное назначение номера порта, а не проверка того, что реально слушает.")
            } else {
                sub.stringValue = L("Куда сейчас звонит ваш Mac — исходящие соединения и их страны.")
                note.stringValue = L("Только наблюдение: локальный снимок (lsof), без перехвата и без сети. Страна — офлайн-база. Блокировать исходящее нельзя; блок входящих и доменов — в Настройках.")
            }
        }
        applyBasis(privacyView.currentBasis)                        // старт с текущей основы (переживает переоткрытие)
        privacyView.onBasisChange = { applyBasis($0) }
        return glassTile(vstack([padLeading(sub, 10, width: FW),
                                 padLeading(buildMediaChip(), 10, width: FW),
                                 padLeading(buildVPNChip(), 10, width: FW),
                                 privacyView,
                                 padLeading(note, 10, width: FW)], 8), hInset: 6, fill: true)
    }

    private var mediaChipRefresh: (() -> Void)?
    /// Чип «камера/микрофон используются» — FDA-free live-детект (CoreAudio/CoreMediaIO). Честно БЕЗ имени
    /// приложения (публичного API нет): красный = активно, серый = не активно.
    private func buildMediaChip() -> NSView {
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let label = NSTextField(labelWithString: L("проверка…"))
        label.font = Design.Font.body; label.lineBreakMode = .byTruncatingTail; label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [icon, label])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: FW - 20).isActive = true
        row.toolTip = L("какое приложение — из этого API не видно")   // честная граница: устройство активно, имя не выдаём
        func apply(_ s: MediaSensors.State) {
            let sym: String, color: NSColor, text: String
            if s.camera && s.mic { sym = "video.fill"; color = .systemRed; text = L("Камера и микрофон используются") }
            else if s.camera     { sym = "video.fill"; color = .systemRed; text = L("Камера используется") }
            else if s.mic        { sym = "mic.fill";   color = .systemRed; text = L("Микрофон используется") }
            else                 { sym = "video.slash"; color = .tertiaryLabelColor; text = L("Камера и микрофон не активны") }
            icon.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            icon.contentTintColor = color
            label.stringValue = text; label.textColor = s.any ? .labelColor : .secondaryLabelColor
        }
        mediaChipRefresh = { MediaSensors.read { apply($0) } }   // фон-чтение → apply на main
        mediaChipRefresh?()
        return row
    }

    /// VPN-чип: честный статус (free) + connect/disconnect системного профиля (Pro).
    /// «Защищён» только когда именованный профиль Connected; иначе — маршрут по умолчанию (голый utun ≠ VPN).
    private func buildVPNChip() -> NSView {
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let label = NSTextField(labelWithString: L("проверка…"))
        label.font = Design.Font.body; label.lineBreakMode = .byTruncatingTail; label.textColor = .secondaryLabelColor
        let btn = GlassButton(title: L("Подключить"), symbol: "lock.fill")
        btn.isHidden = true
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [icon, label, spacer, btn])
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: FW - 20).isActive = true

        func sym(_ name: String, _ color: NSColor) {
            icon.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
            icon.contentTintColor = color
        }
        func apply(_ s: VPN.Status) {                               // UI-правки на main (status читается в фоне)
            if let a = s.active {                                   // именованный профиль Connected → защищён
                sym("lock.fill", .systemGreen)
                label.stringValue = String(format: L("VPN активен: %@"), a.name); label.textColor = .labelColor
                btn.title = L("Отключить"); btn.isHidden = false
                btn.onClick = { [weak self] in
                    guard SettingsCoordinator.requirePro(.vpn) else { return }
                    VPN.disconnect(a.name)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.vpnChipRefresh?() }
                }
            } else if let target = s.profiles.first(where: { $0.enabled }) ?? s.profiles.first {   // есть профиль, отключён
                sym("lock.open", .systemOrange)
                label.stringValue = L("Без VPN")                       // коротко (не влезало «…маршрут через en0» рядом с кнопкой)
                label.toolTip = String(format: L("Маршрут по умолчанию через %@"), s.defaultInterface)   // деталь маршрута — на ховере
                label.textColor = .secondaryLabelColor
                btn.title = s.profiles.count > 1 ? String(format: L("Подключить: %@"), target.name) : L("Подключить")
                btn.isHidden = false
                btn.onClick = { [weak self] in
                    guard SettingsCoordinator.requirePro(.vpn) else { return }
                    VPN.connect(target.name)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.vpnChipRefresh?() }
                }
            } else {                                                // системных профилей нет
                sym("lock.slash", .tertiaryLabelColor)
                label.stringValue = L("Нет системных VPN-профилей"); label.textColor = .tertiaryLabelColor
                btn.isHidden = true
            }
        }
        vpnChipRefresh = { VPN.status { apply($0) } }               // фон-чтение → apply на main (не блокируем открытие)
        vpnChipRefresh?()
        return row
    }

    /// Вкладка «Обслуживание» — read-only постура (XProtect/SIP/FileVault), всё без root.
    /// Строки-плейсхолдеры синхронно (высота корректна), постура читается В ФОНЕ и заполняет их на main.
    private func buildMaintenanceTile() -> NSView {
        let hero = TabStatusHeroView()
        hero.set(
            symbol: "checkmark.shield.fill",
            eyebrow: L("Системная проверка"),
            title: L("Проверяем защиту и стабильность"),
            subtitle: L("Собираем факты macOS"),
            metric: "…",
            tint: Design.Color.accent(isDark),
            animated: false
        )
        struct Row { let view: NSView; let icon: NSImageView; let value: NSTextField }
        func makeRow(_ title: String) -> Row {
            let iv = NSImageView(); iv.imageScaling = .scaleProportionallyDown
            iv.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            iv.contentTintColor = .tertiaryLabelColor
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 18).isActive = true
            let t = NSTextField(labelWithString: title); t.font = Design.Font.body; t.textColor = .labelColor
            t.lineBreakMode = .byTruncatingTail
            t.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let v = NSTextField(labelWithString: L("проверка…")); v.font = Design.Font.numericBody; v.alignment = .right
            v.textColor = .tertiaryLabelColor
            // Статус остаётся одной компактной правой колонкой. Полная строка
            // доступна в tooltip; перенос ломал вертикальный ритм вкладки.
            v.lineBreakMode = .byTruncatingTail; v.maximumNumberOfLines = 1
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
            let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let r = NSStackView(views: [iv, t, spacer, v])
            r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 8
            r.translatesAutoresizingMaskIntoConstraints = false
            r.widthAnchor.constraint(equalToConstant: IW).isActive = true
            return Row(view: r, icon: iv, value: v)
        }
        // unknown/neutral = серо (не зелёный «ок»); level=nil без neutral = зелёный «в норме». Честность закон #1.
        func setRow(_ row: Row, _ value: String, _ level: Design.Level?, symbol: String, unknown: Bool = false, neutral: Bool = false) {
            let grey = unknown || neutral
            row.value.stringValue = value
            row.value.toolTip = value
            row.value.textColor = grey ? .tertiaryLabelColor
                : (level == nil ? .secondaryLabelColor : (level == .crit ? .systemRed : .systemOrange))
            row.icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
            row.icon.contentTintColor = grey ? .tertiaryLabelColor
                : (level == .crit ? .systemRed : (level == .warn ? .systemOrange : .systemGreen))
        }
        let xp = makeRow("XProtect")
        let sip = makeRow("SIP")
        let fv = makeRow("FileVault")
        let boot = makeRow("Boot-args")
        let upd = makeRow(L("Обновления macOS"))
        let mem = makeRow(L("Память"))
        let therm = makeRow(L("Термонагрузка"))
        let sleep = makeRow(L("Сон"))
        let crash = makeRow(L("Сбои · 7 дней"))
        let note = NSTextField(labelWithString: L("Только чтение. Факты из системных утилит (csrutil, fdesetup, XProtect, pmset) — без root."))
        note.font = Design.Font.sys(9, .regular); note.textColor = .tertiaryLabelColor
        note.lineBreakMode = .byWordWrapping; note.maximumNumberOfLines = 2
        note.preferredMaxLayoutWidth = IW

        Maintenance.posture { p in
            let xpUnknown = p.xprotect == nil
            setRow(xp, p.xprotect.map { L("сигнатуры ") + $0 } ?? "—", nil,
                   symbol: xpUnknown ? "questionmark.circle" : "checkmark.shield.fill", unknown: xpUnknown)
            setRow(sip, p.sip.label, p.sip.level,
                   symbol: p.sip.level == nil ? "lock.fill" : "exclamationmark.shield.fill")
            let fvUnknown = p.fileVault == nil
            let fvLevel: Design.Level? = p.fileVault == false ? .warn : nil
            let fvVal = fvUnknown ? "—" : (p.fileVault! ? L("включено") : L("выключено"))
            setRow(fv, fvVal, fvLevel,
                   symbol: fvUnknown ? "questionmark.circle" : (fvLevel == nil ? "lock.fill" : "lock.open.fill"), unknown: fvUnknown)
            // boot-args: ВСЕГДА нейтрально-серо (факт без вердикта по флагам — «no verdict» политика);
            // стандартно → «стандартные», кастом → verbatim (заполненный флажок как маркер «есть что-то»).
            let ba = p.bootArgs
            setRow(boot, ba == nil ? L("стандартные") : L("настроены"), nil,
                   symbol: ba == nil ? "flag" : "flag.fill", neutral: true)
            boot.value.toolTip = ba ?? L("стандартные")
            // обновления macOS: атрибуция самой ОС. Патч в текущей ОС → warn (актуально применим); апгрейд ОС
            // (major) → НЕЙТРАЛЬ (валидный выбор, не «тревога»). «нет» — тоже нейтраль (не зелёное «защищены»).
            let df = DateFormatter(); df.dateFormat = "d MMM"; df.locale = Locale(identifier: I18n.current.rawValue)
            let ups = p.pendingUpdates
            if let sel = ups.first(where: { !$0.major }) ?? ups.first {   // предпочитаем не-major патч
                let extra = ups.count - 1
                let val = extra > 0 ? String(format: L("%@ +%d"), sel.name, extra) : sel.name
                if sel.major {
                    setRow(upd, String(format: L("доступно обновление ОС: %@"), val), nil, symbol: "arrow.up.circle", neutral: true)
                } else {
                    setRow(upd, val, .warn, symbol: "arrow.down.circle.fill")
                }
            } else if let ch = p.updateChecked, Date().timeIntervalSince(ch) < 14 * 86400 {
                setRow(upd, String(format: L("нет (проверено %@)"), df.string(from: ch)), nil, symbol: "checkmark.circle", neutral: true)
            } else {
                setRow(upd, String(format: L("проверка: %@"), p.updateChecked.map { df.string(from: $0) } ?? L("никогда")),
                       nil, symbol: "questionmark.circle", neutral: true)
            }
            // память: ЧЕСТНО показываем ДАВЛЕНИЕ (метрика ядра), а не «% занято» (высокий used на macOS — норма).
            // green только для измеренного «в норме»; повышенное→orange, критическое→red, неизвестно→серо.
            let ms = p.memory
            let mLabel: String; let mLevel: Design.Level?; var mGrey = false
            switch ms.pressure {
            case .normal:   mLabel = L("в норме");     mLevel = nil
            case .warning:  mLabel = L("повышенное");  mLevel = .warn
            case .critical: mLabel = L("критическое"); mLevel = .crit
            case .unknown:  mLabel = "—";              mLevel = nil; mGrey = true
            }
            // своп в работе при «норме» → НЕ зелёно-успокаивающе (наш же код зовёт своп признаком нехватки):
            // гасим зелёный в нейтраль, текст остаётся честным. Зелёный только при норме И нулевом свопе.
            if ms.pressure == .normal && ms.swapUsed > 0 { mGrey = true }
            let swapStr = ms.swapUsed > 0 ? " · " + String(format: L("своп %.1f ГБ"), Double(ms.swapUsed) / 1e9) : ""
            setRow(mem, mLabel + swapStr, mLevel,
                   symbol: ms.pressure == .unknown ? "questionmark.circle" : "memorychip", neutral: mGrey)
            mem.view.toolTip = L("Давление памяти (не «% занято»): ядро само сообщает, реально ли не хватает RAM. Своп в работе — признак нехватки.")
            // здоровье/стабильность — зелёный ТОЛЬКО для .nominal; fair/unknown нейтрально-серые
            setRow(therm, p.thermal.label, p.thermal.level,
                   symbol: p.thermal == .unknown ? "questionmark.circle" : (p.thermal.level == nil ? "thermometer.medium" : "thermometer.sun.fill"),
                   neutral: p.thermal == .fair || p.thermal == .unknown)
            let blocked = !p.sleepBlockers.isEmpty
            setRow(sleep, blocked ? p.sleepBlockers.prefix(3).joined(separator: ", ") : L("ничто не мешает"), nil,
                   symbol: blocked ? "powersleep" : "moon.zzz.fill", neutral: blocked)
            let crashed = p.crashes7d > 0
            let crashVal = crashed ? "\(p.crashes7d)" + (p.latestCrash.map { " · " + $0 } ?? "") : "0"
            setRow(crash, crashed ? "\(p.crashes7d)" : "0", nil,
                   symbol: crashed ? "exclamationmark.triangle" : "checkmark.circle", neutral: crashed)
            crash.value.toolTip = crashVal

            var attention = 0
            if p.sip.level != nil { attention += 1 }
            if p.fileVault == false { attention += 1 }
            if p.pendingUpdates.contains(where: { !$0.major }) { attention += 1 }
            switch p.memory.pressure {
            case .warning, .critical: attention += 1
            case .normal, .unknown: break
            }
            if p.thermal.level != nil { attention += 1 }
            if !p.sleepBlockers.isEmpty { attention += 1 }
            if p.crashes7d > 0 { attention += 1 }
            let critical = p.sip.level == .crit || p.memory.pressure == .critical || p.thermal.level == .crit
            let unknown = p.xprotect == nil || p.fileVault == nil
            let heroTitle: String
            let heroMetric: String
            let heroTint: NSColor
            let heroSymbol: String
            if attention > 0 {
                heroTitle = String(format: L("Требуют внимания: %d"), attention)
                heroMetric = "\(attention)"
                heroTint = critical ? Design.Color.levelCrit : Design.Color.levelWarn
                heroSymbol = critical ? "exclamationmark.shield.fill" : "checkmark.shield.fill"
            } else if unknown {
                heroTitle = L("Проверка частично недоступна")
                heroMetric = "—"
                heroTint = .secondaryLabelColor
                heroSymbol = "questionmark.shield"
            } else {
                heroTitle = L("Защита и стабильность в норме")
                heroMetric = "OK"
                heroTint = Design.Color.levelOK
                heroSymbol = "checkmark.shield.fill"
            }
            hero.set(
                symbol: heroSymbol,
                eyebrow: L("Системная проверка"),
                title: heroTitle,
                subtitle: L("Защита · память · обновления"),
                metric: heroMetric,
                tint: heroTint
            )
        }
        return glassTile(vstack([
            hero, Self.sectionLabel(L("Обслуживание · защита")), xp.view, sip.view, fv.view, boot.view, upd.view,
            Self.sectionLabel(L("Здоровье и стабильность")), mem.view, therm.view, sleep.view, crash.view,
            note,
        ], 10), fill: true)
    }
    private func buildBatteryStatsTile() -> NSView { glassTile(buildBatteryStatsContent()) }
    /// Внутренний контент «Батарея» (без glass-обёртки) — для одиночной плитки И консоль-группы.
    private func buildBatteryStatsContent() -> NSView {
        // «Темп. АКБ» (не просто «Темп») — развести с витальной «Темп» (та = CPU): разные датчики, разные числа.
        let battRow = NSStackView(views: [battStat("Здоровье", L("Здоровье")), battStat("Циклы", L("Циклы")), battStat("Температура", L("Темп. АКБ"))])
        battRow.distribution = .fillEqually; battRow.spacing = 8
        battRow.translatesAutoresizingMaskIntoConstraints = false
        battRow.widthAnchor.constraint(equalToConstant: IW).isActive = true
        // Возраст АКБ (дата + циклы/ресурс) — метрика-строка; заполняется в апдейте, пустая скрыта.
        let age = NSTextField(labelWithString: ""); age.font = Design.Font.sys(10, .regular); age.textColor = .secondaryLabelColor
        age.lineBreakMode = .byTruncatingTail; metric["battAge"] = age
        // «Почему не заряжается» — видна ТОЛЬКО когда воткнут+не заряжается+не полный (иначе скрыта).
        let why = NSTextField(labelWithString: ""); why.font = Design.Font.sys(10, .regular); why.textColor = .systemOrange
        why.lineBreakMode = .byWordWrapping; why.maximumNumberOfLines = 2; why.preferredMaxLayoutWidth = IW
        why.isHidden = true; metric["battWhy"] = why
        return vstack([Self.sectionLabel(L("Батарея")), battRow, age, why], 10)
    }

    /// Возраст АКБ из literal-даты (если парсится yyyy-MM-dd) + циклы/ресурс. Дата НЕ утверждается точной («≈»).
    private func batteryAgeLine(_ b: BatteryInfo) -> String {
        var parts: [String] = []
        if let d = b.manufactureDate {
            var s = String(format: L("АКБ %@"), d)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            if let date = f.date(from: d) {
                let months = Calendar.current.dateComponents([.month], from: date, to: Date()).month ?? 0
                if months > 0 { s += String(format: L(" · ≈%.1f г."), Double(months) / 12.0) }
            }
            parts.append(s)
        }
        if let rated = b.ratedCycles {
            parts.append(String(format: L("%d / %d циклов (%.0f%%)"), b.cycleCount, rated, Double(b.cycleCount) / Double(rated) * 100))
        } else {
            parts.append(String(format: L("%d циклов"), b.cycleCount))
        }
        return parts.joined(separator: " · ")
    }

    /// Честная причина «не заряжается». НАШИ причины (лимит/парус) заявляем ТОЛЬКО когда демон РЕАЛЬНО стоит
    /// (иначе BCLM никто не пишет — приписывать себе нельзя) И лимит сейчас НЕ поднят top-up/будильником.
    /// heat-паузу НЕ атрибутируем: демон решает по TB0T, а мы видим лишь Temperature АКБ — они расходятся.
    /// Причина ОС — недокументированный код literal (смысл не выдумываем).
    private func batteryWhyNotCharging(_ b: BatteryInfo) -> String? {
        guard b.present, b.external, !b.charging, b.charge < 100 else { return nil }
        if FanController.daemonInstalled, !ChargeControl.isTopUpActive, !inChargeAlarmWindow() {
            if SettingsStore.chargeMode == "sail", b.charge >= SettingsStore.sailUpper - 2 {
                return String(format: L("Не заряжается: парусный режим %d–%d%% (Kelvin)"), SettingsStore.sailLower, SettingsStore.sailUpper)
            }
            if SettingsStore.chargeLimit < 100, b.charge >= SettingsStore.chargeLimit - 2 {
                return String(format: L("Не заряжается: лимит %d%% (Kelvin)"), SettingsStore.chargeLimit)
            }
        }
        if let r = b.notChargingReason, r != 0 {
            return String(format: L("Не заряжается: система приостановила заряд (код %d)"), r)
        }
        return nil
    }

    /// Активно ли сейчас суточное окно планового дозаряда (тогда демон поднимает BCLM=100 — лимит не держит).
    private func inChargeAlarmWindow() -> Bool {
        guard SettingsStore.chargeAlarmOn else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let target = SettingsStore.chargeAlarmTargetMin, lead = SettingsStore.chargeAlarmLeadMin
        let start = (target - lead + 1440) % 1440
        return start <= target ? (now >= start && now <= target) : (now >= start || now <= target)
    }
    /// Диск: свободно / занято % / ввод-вывод (R/W) + живая скорость сети (↓/↑).
    /// Сеть локальна (NetUsage сэмплит счётчики интерфейса, без телеметрии). Постоянное число строк.
    private func buildDiskTile() -> NSView { glassTile(buildDiskContent()) }
    /// Внутренний контент «Диск» (без glass-обёртки) — для одиночной плитки И консоль-группы.
    private func buildDiskContent() -> NSView {
        let diskRow = NSStackView(views: [battStat("diskFree", L("Свободно")),
                                          battStat("diskUsed", L("Занято"))])
        diskRow.distribution = .fillEqually; diskRow.spacing = 8
        diskRow.translatesAutoresizingMaskIntoConstraints = false
        diskRow.widthAnchor.constraint(equalToConstant: IW).isActive = true
        // В/В диска — СВОЯ полноширинная строка: «↓1.2M ↑850K» в 1/3-колонке обрезалось до «↓1.2M ↑85».
        let ioVal = NSTextField(labelWithString: "↓0 ↑0")
        metric["diskIO"] = ioVal
        let ioRow = miniStat(ioVal, NSTextField(labelWithString: L("Диск · В/В")))
        ioRow.widthAnchor.constraint(equalToConstant: IW).isActive = true
        // строка скорости сети: значение «↓1.2M ↑850K» + подпись (тот же miniStat-язык, на всю ширину)
        let netVal = NSTextField(labelWithString: "↓0 ↑0")
        metric["netRate"] = netVal
        let netRow = miniStat(netVal, NSTextField(labelWithString: L("Сеть")))
        netRow.widthAnchor.constraint(equalToConstant: IW).isActive = true
        // честное раскрытие purgeable: часть «свободного» (по Finder) — очищаемый кэш/снимки, не свободно сейчас
        let purge = NSTextField(labelWithString: "")
        purge.font = Design.Font.sys(9, .regular); purge.textColor = .tertiaryLabelColor
        purge.lineBreakMode = .byWordWrapping; purge.maximumNumberOfLines = 2
        purge.preferredMaxLayoutWidth = IW; purge.isHidden = true
        metric["diskPurge"] = purge
        refreshDisk()                                   // первичное заполнение до первого тика
        return vstack([Self.sectionLabel(L("Диск")), diskRow, purge, ioRow, netRow], 10)
    }
    /// Живые значения диска: ёмкость (мгновенно) + свежая скорость R/W. Зовётся из update() каждый тик.
    private func refreshDisk() {
        guard metric["diskFree"] != nil else { return }   // плитка не построена
        DiskUsage.shared.sample()                          // освежаем дельту R/W, как net
        if let cap = DiskInfo.capacity(), cap.total > 0 {
            metric["diskFree"]?.stringValue = String(format: "%.0f", Double(cap.free) / 1e9) + " " + L("ГБ")
            let usedPct = Double(cap.total - cap.free) / Double(cap.total) * 100
            metric["diskUsed"]?.stringValue = String(format: "%.0f%%", usedPct)
            if cap.purgeable >= 500_000_000 {           // раскрываем только если очищаемого заметно (≥0.5 ГБ)
                metric["diskPurge"]?.stringValue = String(format: L("из них ≈%.1f ГБ очищаемые (purgeable): кэш и снимки — Finder считает их свободными, поэтому «занято» тоже занижено"), Double(cap.purgeable) / 1e9)
                metric["diskPurge"]?.isHidden = false
            } else {
                metric["diskPurge"]?.isHidden = true
            }
        } else {
            metric["diskFree"]?.stringValue = "—"
            metric["diskUsed"]?.stringValue = "—"
            metric["diskPurge"]?.isHidden = true
        }
        metric["diskIO"]?.stringValue = "↓\(NetUsage.fmtRate(DiskUsage.shared.read)) ↑\(NetUsage.fmtRate(DiskUsage.shared.write))"
        let net = NetUsage.shared.sample()              // локальный замер ↓/↑ (как net-чип в меню-баре)
        metric["netRate"]?.stringValue = "↓\(NetUsage.fmtRate(net.down)) ↑\(NetUsage.fmtRate(net.up))"
    }
    /// Bluetooth-периферия: список подключённых устройств с зарядом (L/R/кейс или одно %).
    /// ФИКСИРОВАННОЕ число строк-слотов — высота поповера не прыгает; лишние слоты пустеют.
    /// Кэш читается мгновенно, тяжёлый system_profiler освежается вне main (refreshIfStale).
    private func buildBTBatteryTile() -> NSView { glassTile(buildBTBatteryContent(), fill: false) }   // V3: топ-модуль ХУГАЕТ контент (fill:true растягивался на слабину .fill-стека → пустой провал)
    /// Внутренний контент Bluetooth (без glass-обёртки) — для одиночной плитки И консоль-группы.
    private func buildBTBatteryContent() -> NSView {
        let slotCount = 4                                  // AirPods + мышь + клава + трекпад; хвостовые пустые слоты схлопываются
        btSlots = []
        var rows: [NSView] = [Self.sectionLabel(L("Bluetooth"))]
        for _ in 0..<slotCount {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.contentTintColor = .secondaryLabelColor
            icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            let name = NSTextField(labelWithString: "")
            name.font = Design.Font.caption
            name.textColor = .labelColor
            name.lineBreakMode = .byTruncatingTail
            let value = NSTextField(labelWithString: "")
            value.font = Design.Font.numericBody
            value.textColor = .secondaryLabelColor
            value.alignment = .right
            let row = NSStackView(views: [icon, name, spacer(), value])
            row.alignment = .centerY; row.spacing = 7
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: IW).isActive = true
            btSlots.append(BTSlot(row: row, icon: icon, name: name, value: value))
            rows.append(row)
        }
        refreshBT()                                        // первичное заполнение из кэша до первого тика
        return vstack(rows, 6)
    }
    /// Живые значения Bluetooth: читаем кэш синхронно, рисуем по фиксированным слотам и
    /// подкидываем неблокирующее обновление кэша. Зовётся из update() каждый тик (no-op без плитки).
    private func refreshBT() {
        guard !btSlots.isEmpty else { return }             // плитка не построена
        let devs = BTPeripherals.cached()
        for (i, slot) in btSlots.enumerated() {
            if i < devs.count {
                let d = devs[i]
                slot.icon.image = NSImage(systemSymbolName: d.icon, accessibilityDescription: nil)
                slot.icon.isHidden = false
                slot.name.stringValue = d.name
                slot.name.textColor = .labelColor
                slot.value.stringValue = btValueString(d)
                slot.row.isHidden = false
            } else if i == 0 && devs.isEmpty {
                // единственная строка-состояние «нет устройств»
                slot.icon.image = nil; slot.icon.isHidden = true
                slot.name.stringValue = L("нет устройств")
                slot.name.textColor = .tertiaryLabelColor
                slot.value.stringValue = ""
                slot.row.isHidden = false
            } else {
                // хвостовые пустые слоты СХЛОПЫВАЕМ (как в «Звук») — без мёртвого вертикального провала
                slot.row.isHidden = true
            }
        }
        // освежаем кэш вне main; по готовности — перерисовываем слоты, пока поповер на экране
        // (у контроллера есть window только когда поповер показан — иначе незачем перерисовывать)
        BTPeripherals.refreshIfStale { [weak self] in
            if self?.view.window != nil { self?.refreshBT() }
        }
    }
    /// Компактная подпись заряда устройства: «Л84 П86 К72» для AirPods или одно «84%».
    private func btValueString(_ d: BTPeripheral) -> String {
        if d.main == nil && (d.left != nil || d.right != nil || d.caseLvl != nil) {
            var parts: [String] = []
            if let l = d.left    { parts.append(L("Лев.") + " \(l)") }
            if let r = d.right   { parts.append(L("Прав.") + " \(r)") }
            if let c = d.caseLvl { parts.append(L("Кейс") + " \(c)") }
            return parts.joined(separator: "  ")
        }
        if let m = d.main { return "\(m)%" }
        return d.worst.map { "\($0)%" } ?? "—"
    }

    /// Плитка «Звук · вывод»: строки-устройства, текущее с галкой; клик по другому → сделать выводом
    /// по умолчанию (Pro). ЧЕСТНОСТЬ: меняем СИСТЕМНЫЙ вывод по умолчанию, не «маршрутизируем весь звук».
    /// Вкладка «Здоровье» — Центр здоровья Mac (Kelvin Advisor).
    /// Показывает общий статус и список рекомендаций.
    private func buildHealthTile() -> NSView {
        healthHero.set(
            symbol: "heart.text.square.fill",
            eyebrow: L("Центр здоровья"),
            title: L("Проверяем Mac"),
            subtitle: L("Собираем рекомендации"),
            metric: "…",
            tint: Design.Color.accent(isDark),
            animated: false
        )
        
        healthFindingsContainer.orientation = .vertical
        healthFindingsContainer.spacing = 0
        healthFindingsContainer.translatesAutoresizingMaskIntoConstraints = false
        healthFindingsContainer.widthAnchor.constraint(equalToConstant: IW).isActive = true
        healthFindingsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        healthFindingsContainer.addArrangedSubview(healthMessageRow(
            symbol: "ellipsis.circle",
            title: L("Анализ продолжается"),
            detail: L("Рекомендации появятся после проверки"),
            tint: Design.Color.accent(isDark)
        ))
        
        let refreshBtn = GlassButton(title: "", symbol: "arrow.clockwise", cornerRadius: Design.Radius.chip)
        refreshBtn.toolTip = L("Обновить")
        refreshBtn.translatesAutoresizingMaskIntoConstraints = false
        refreshBtn.widthAnchor.constraint(equalToConstant: 28).isActive = true
        refreshBtn.heightAnchor.constraint(equalToConstant: 28).isActive = true
        refreshBtn.onClick = { [weak self] in self?.refreshAdvisor() }

        let sectionRow = NSStackView(views: [Self.sectionLabel(L("Рекомендации")), spacer(), refreshBtn])
        sectionRow.alignment = .centerY
        sectionRow.translatesAutoresizingMaskIntoConstraints = false
        sectionRow.widthAnchor.constraint(equalToConstant: IW).isActive = true

        let content = vstack([healthHero, sectionRow, healthFindingsContainer], 8)
        return glassTile(content, fill: false)
    }

    private func healthMessageRow(symbol: String, title: String, detail: String, tint: NSColor) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        icon.contentTintColor = tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Design.Font.sys(11, .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = Design.Font.sys(9.5, .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        let text = vstack([titleLabel, detailLabel], 2)
        text.alignment = .leading

        let row = NSStackView(views: [icon, text, spacer()])
        row.alignment = .centerY
        row.spacing = 9
        row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        row.wantsLayer = true
        row.layer?.cornerRadius = 11
        row.layer?.cornerCurve = .continuous
        row.layer?.backgroundColor = (isDark
            ? NSColor.white.withAlphaComponent(0.032)
            : NSColor.black.withAlphaComponent(0.022)).cgColor
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: IW).isActive = true
        row.heightAnchor.constraint(equalToConstant: 50).isActive = true
        row.setAccessibilityLabel(title + " · " + detail)
        return row
    }

    private func buildAudioContent() -> NSView {
        let slotCount = 3                                  // быстрый выбор; полный список остаётся в системных настройках
        audioSlots = []
        var rows: [NSView] = [Self.sectionLabel(L("Звук · вывод"))]
        for _ in 0..<slotCount {
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.imageScaling = .scaleProportionallyDown
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 16).isActive = true
            let name = NSTextField(labelWithString: "")
            name.font = Design.Font.body; name.textColor = .labelColor
            name.lineBreakMode = .byTruncatingTail
            let check = NSImageView()
            check.translatesAutoresizingMaskIntoConstraints = false
            check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
            check.contentTintColor = Design.Color.accent(isDark)
            check.widthAnchor.constraint(equalToConstant: 16).isActive = true
            check.isHidden = true
            let row = PopoverActionRow()
            [icon, name, spacer(), check].forEach { row.addArrangedSubview($0) }
            row.orientation = .horizontal
            row.alignment = .centerY; row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: IW).isActive = true
            audioSlots.append(AudioSlot(row: row, icon: icon, name: name, check: check, deviceID: nil))
            rows.append(row)
        }
        let note = NSTextField(labelWithString: L("Меняет системный вывод по умолчанию. Приложение со своим выбором устройства это не трогает."))
        note.font = Design.Font.sys(9, .regular); note.textColor = .tertiaryLabelColor
        note.lineBreakMode = .byWordWrapping; note.maximumNumberOfLines = 3
        note.preferredMaxLayoutWidth = IW
        metric["audioNote"] = note                         // refreshAudio дописывает честное раскрытие переполнения
        rows.append(note)
        refreshAudio()                                     // первичное заполнение до первого тика
        return vstack(rows, 6)
    }
    /// Живые значения аудио: перечисление устройств вне main, отрисовка по фиксированным слотам.
    /// Зовётся из update() каждый тик (no-op без плитки). Ловит и hot-plug, и смену дефолта извне.
    private func refreshAudio() {
        guard !audioSlots.isEmpty else { return }          // плитка не построена
        AudioDevices.outputs { [weak self] devs in
            guard let self = self, !self.audioSlots.isEmpty else { return }
            for i in self.audioSlots.indices {
                let slot = self.audioSlots[i]
                if i < devs.count {
                    let d = devs[i]
                    self.audioSlots[i].deviceID = d.id
                    slot.icon.image = NSImage(systemSymbolName: d.isCurrent ? "hifispeaker.fill" : "hifispeaker", accessibilityDescription: nil)
                    slot.icon.contentTintColor = d.isCurrent ? Design.Color.accent(self.isDark) : .secondaryLabelColor
                    slot.icon.isHidden = false
                    slot.name.stringValue = d.name
                    slot.name.textColor = d.isCurrent ? .labelColor : .secondaryLabelColor
                    slot.check.isHidden = !d.isCurrent
                    slot.row.accessibilityText = L("Звук · вывод") + " · " + d.name + (d.isCurrent ? " · ✓" : "")
                    slot.row.onPress = d.isCurrent ? nil : { [weak self, weak row = slot.row] in
                        self?.audioSlotClicked(row)
                    }
                    slot.row.isHidden = false
                } else if i == 0 {
                    self.audioSlots[i].deviceID = nil
                    slot.icon.image = nil; slot.icon.isHidden = true
                    slot.name.stringValue = L("нет устройств вывода")
                    slot.name.textColor = .tertiaryLabelColor
                    slot.check.isHidden = true
                    slot.row.accessibilityText = L("нет устройств вывода")
                    slot.row.onPress = nil
                    slot.row.isHidden = false
                } else {
                    self.audioSlots[i].deviceID = nil
                    slot.row.onPress = nil
                    slot.row.isHidden = true
                }
            }
            // честно раскрываем, если устройств больше, чем слотов (без «тихого капа»)
            let base = L("Меняет системный вывод по умолчанию. Приложение со своим выбором устройства это не трогает.")
            if devs.count > self.audioSlots.count {
                self.metric["audioNote"]?.stringValue = base + " " + String(format: L("+%d ещё — в Настройках звука."), devs.count - self.audioSlots.count)
            } else {
                self.metric["audioNote"]?.stringValue = base
            }
        }
    }
    /// Клик по слоту: не-текущий → сделать выводом по умолчанию (Pro-гейт). Текущий = no-op (без гейта).
    private func audioSlotClicked(_ row: PopoverActionRow?) {
        guard let row, let slot = audioSlots.first(where: { $0.row === row }), let id = slot.deviceID else { return }
        if slot.check.isHidden == false { return }         // уже текущий вывод — клик ничего не меняет
        guard Licensing.shared.isPro else { _ = SettingsCoordinator.requirePro(.audioSwitch); return }
        if AudioDevices.setDefaultOutput(id) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refreshAudio() }
        }
    }

    /// Вкладка «История» V5 = КАРТОЧКА БАТАРЕИ (решение владельца: «30 дней CPU — мутные данные»):
    /// вердикт-вывод + три крупных числа (Здоровье/Циклы/Тренд) + ОДИН маленький график заряда за
    /// сегодня + экспорт CSV/PDF. Данные в SQLite пишутся как прежде (90 дней — для PDF и тренда).
    private func buildHistoryTile() -> NSView {
        historyHero.set(
            symbol: "clock.arrow.circlepath",
            eyebrow: L("История батареи"),
            title: L("Собираем локальную историю"),
            subtitle: L("До 90 дней · локально"),
            tint: Design.Color.accent(isDark),
            animated: false
        )

        // Три крупных числа — та же miniStat-грамматика, что футер «Приложений»/консоль.
        let numsRow = NSStackView(views: [miniStat(histCardHealth, NSTextField(labelWithString: L("Здоровье"))),
                                          miniStat(histCardCycles, NSTextField(labelWithString: L("Циклы"))),
                                          miniStat(histCardTrend, NSTextField(labelWithString: L("Тренд")))])
        numsRow.distribution = .fillEqually; numsRow.spacing = 8
        numsRow.translatesAutoresizingMaskIntoConstraints = false
        numsRow.widthAnchor.constraint(equalToConstant: IW).isActive = true

        // Один маленький график: заряд за сегодня (24 ч) — «как жила батарея сегодня».
        let chartCap = Self.sectionLabel(L("Заряд сегодня"))
        let chart = HistoryChart()
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 72).isActive = true
        chart.widthAnchor.constraint(equalToConstant: IW).isActive = true
        historyChart = chart

        historyFooter.font = Design.Font.sys(9, .regular); historyFooter.textColor = .tertiaryLabelColor
        historyFooter.lineBreakMode = .byWordWrapping; historyFooter.maximumNumberOfLines = 2
        historyFooter.preferredMaxLayoutWidth = IW

        // строка деталей (здоровье/циклы текстом — дубль чисел в компакте не нужен; оставляем тренд-детали)
        historyDegrade.font = Design.Font.sys(10, .regular); historyDegrade.textColor = .secondaryLabelColor
        historyDegrade.alignment = .left
        historyDegrade.lineBreakMode = .byWordWrapping; historyDegrade.maximumNumberOfLines = 2
        historyDegrade.preferredMaxLayoutWidth = IW
        historyDegrade.translatesAutoresizingMaskIntoConstraints = false
        historyDegrade.widthAnchor.constraint(equalToConstant: IW).isActive = true

        let exportBtn = GlassButton(title: L("Экспорт CSV"), symbol: "square.and.arrow.up", cornerRadius: Design.Radius.chip)
        exportBtn.onClick = { [weak self] in self?.exportHistoryCSV() }
        let pdfBtn = GlassButton(title: L("PDF-отчёт"), symbol: "doc.richtext", cornerRadius: Design.Radius.chip)
        pdfBtn.onClick = { [weak self] in self?.exportHealthReportPDF() }
        let btnRow = NSStackView(views: [exportBtn, pdfBtn])
        btnRow.spacing = 8

        refreshHistory()
        return glassTile(vstack([historyHero, numsRow,
                                 chartCap, chart, historyDegrade, historyFooter, btnRow], 10), fill: true)
    }

    /// Экспорт истории выбранного периода в CSV-файл (Pro). Данные уже собраны `History.exportCSV`.
    private func exportHistoryCSV() {
        guard Licensing.shared.isPro else { _ = SettingsCoordinator.requirePro(.history); return }
        let since = Int64(Date().timeIntervalSince1970) - 30 * 86_400   // карточка без выбора диапазона → полный отчёт за 30д
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "kelvin-history.csv"       // расширение задаёт тип (без импорта UTI)
        panel.title = L("Экспорт истории")
        NSApp.activate(ignoringOtherApps: true)                 // поповер мог потерять фокус — поднимаем панель поверх
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            History.shared.exportCSV(since: since) { csv in
                DispatchQueue.global(qos: .utility).async {
                    try? csv.write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    /// PDF-отчёт «Здоровье Mac за месяц» (Pro). Строит из локальной истории + текущей батареи.
    private func exportHealthReportPDF() {
        guard Licensing.shared.isPro else { _ = SettingsCoordinator.requirePro(.history); return }
        let period: TimeInterval = 30 * 86_400
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "kelvin-health-report.pdf"
        panel.title = L("Отчёт о здоровье Mac")
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let b = BatteryReader.read()
                let hs = History.shared.series(.health, since: Int64(Date().timeIntervalSince1970) - Int64(period))
                let insight = BatteryHealth.analyze(battery: b, healthSeries: hs)
                let data = Report.healthReportPDF(period: period, battery: b, insight: insight)
                try? data.write(to: url)
            }
        }
    }

    /// Обновить карточку деградации АКБ (тренд/циклы/прогноз). Читает историю health за ≤90д — независимо
    /// от выбранного диапазона графика (честный полный анализ). Скрывается на десктопе (нет АКБ).
    private func refreshDegrade(battery b: BatteryInfo?, series: [(ts: Int64, v: Double)]) {
        let ins = BatteryHealth.analyze(battery: b, healthSeries: series)
        guard ins.present, let h = ins.health else {
            historyDegrade.stringValue = ""; historyDegrade.isHidden = true
            historyVerdict.stringValue = ""; historyVerdict.isHidden = true
            histCardHealth.stringValue = "—"; histCardCycles.stringValue = "—"; histCardTrend.stringValue = "—"
            historyHero.set(
                symbol: "battery.0",
                eyebrow: L("История батареи"),
                title: L("Батарея не обнаружена"),
                subtitle: L("История появится после накопления данных"),
                tint: .secondaryLabelColor
            )
            return
        }
        historyDegrade.isHidden = false
        // Три крупных числа карточки: Здоровье / Циклы / Тренд (честно «—», пока тренд не измерим)
        histCardHealth.stringValue = String(format: "%.0f%%", h)
        histCardCycles.stringValue = ins.cycles.map(String.init) ?? "—"
        if ins.enough, let spm = ins.slopePerMonth {
            histCardTrend.stringValue = spm < -0.15 ? String(format: "%.1f%%/мес", spm) : L("стабильно")
        } else {
            histCardTrend.stringValue = "—"
        }
        // Вердикт-фраза (главный вывод, headline над графиком). Слово «стабильна» честно ограничено
        // порогом шума −0.15%/мес (обоснован в BatteryHealth) — не заявляем точность выше измеримой.
        historyVerdict.isHidden = false
        if ins.enough, let spm = ins.slopePerMonth {
            if spm < -0.15 {
                historyVerdict.stringValue = String(format: L("АКБ теряет ~%.1f%% в месяц"), abs(spm))
            } else {
                historyVerdict.stringValue = L("АКБ стабильна — деградации не видно")
            }
        } else {
            historyVerdict.stringValue = L("Вывод о деградации появится через ~2 недели наблюдений")
        }
        let historyTint: NSColor = h < 60 ? Design.Color.levelCrit
            : (h < 80 ? Design.Color.levelWarn : Design.Color.accent(isDark))
        historyHero.set(
            symbol: h < 80 ? "battery.50" : "battery.100",
            eyebrow: L("История батареи"),
            title: historyVerdict.stringValue,
            subtitle: L("До 90 дней · локально"),
            tint: historyTint
        )
        // Детали под графиком: ресурс циклов (числа Здоровье/Циклы/Тренд уже вынесены крупно — не дублируем)
        if let cy = ins.cycles, let rated = ins.ratedCycles, rated > 0 {
            historyDegrade.stringValue = String(format: L("Ресурс: %d из ~%d циклов (%.0f%%)"), cy, rated, Double(cy) / Double(rated) * 100)
        } else {
            historyDegrade.stringValue = ""
        }
    }

    /// Обновить карточку батареи: мини-график заряда за 24 ч + вердикт/числа (refreshDegrade).
    private func refreshHistory() {
        guard let chart = historyChart else { return }                 // вкладка не построена
        let now = Int64(Date().timeIntervalSince1970)
        History.shared.dashboard(chargeSince: now - 86_400, healthSince: now - 90 * 86_400) { [weak self, weak chart] data in
            guard let self, let chart else { return }
            chart.set(points: data.charge.map { (x: Double($0.ts), y: $0.v) }, color: self.chargeAccent, unit: "%",
                  yCap: 100, yFloor: 0,
                  empty: L("накопление данных — график появится, когда наберётся история"))
        if let earliest = data.earliest {
            let df = DateFormatter(); df.dateFormat = "d MMM HH:mm"; df.locale = Locale(identifier: I18n.current.rawValue)
            let n = data.count
            let pts = I18n.pluralPoints(n)
            historyFooter.stringValue = String(format: L("Данные с %@ · %d %@ · снимок раз в минуту, локально"),
                                               df.string(from: Date(timeIntervalSince1970: TimeInterval(earliest))), n, pts)
        } else {
            historyFooter.stringValue = L("История пуста — Kelvin снимает метрики раз в минуту, пока запущен. Загляни позже.")
        }
            self.refreshDegrade(battery: data.battery, series: data.health)
        }
    }
    /// Освежить историю, если открыта её вкладка (переоткрытие поповера на «Истории» — selectTab не сработает на той же вкладке).
    func refreshHistoryIfVisible() {
        if currentTab < tabOrder.count, tabOrder[currentTab] == "history" { refreshHistory() }
    }
    
    /// Обновить Advisor (Центр здоровья Mac) — собрать снимок данных, проанализировать, отрисовать.
    @objc private func refreshAdvisor() {
        guard healthHero.superview != nil else { return }  // плитка не построена
        let battery = latestAdvisorBattery
        let energy = latestAdvisorEnergy
        let sensors = latestAdvisorSensors
        let chargeLimit = ChargeControl.limit
        let chargeMode = ChargeControl.mode
        let heatProtection = SettingsStore.heatProtect
        let fanHelperInstalled = FanController.daemonInstalled
        let chargeHelperInstalled = HelperInstall.fandInstalled

        // Анализируем вне main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let memory = MemoryInfo.read()
            let disk = DiskInfo.capacity()
            let posture = Maintenance.posture()
            let cpuSensor = sensors.temps.first { $0.id == "cpu" }
            let gpuSensor = sensors.temps.first { $0.id == "gpu" }
            let snapshot = AdvisorSnapshot(
                batteryPresent: battery?.present ?? false,
                batteryChargePercent: battery?.charge,
                batteryHealthPercent: battery?.displayHealth,
                batteryCycles: battery?.cycleCount,
                batteryRatedCycles: battery?.ratedCycles ?? 1000,
                batteryTemperature: battery?.temperature,
                batteryCharging: battery?.charging ?? false,
                batteryExternalConnected: energy.plugged,
                chargeLimitEnabled: chargeHelperInstalled && chargeLimit < 100,
                chargeLimitValue: chargeLimit,
                sailModeActive: chargeHelperInstalled && chargeMode == "sail",
                heatProtectionActive: chargeHelperInstalled && heatProtection,
                cpuTemperature: cpuSensor?.value,
                gpuTemperature: gpuSensor?.value,
                cpuTemperatureKeys: cpuSensor.map { [$0.id] },
                cpuLoad: 0,
                thermalPressure: nil,
                memoryPressure: memory.pressure,
                memoryTotalRAM: memory.totalRAM,
                memorySwapUsed: memory.swapUsed,
                diskFreeBytes: disk?.free,
                diskTotalBytes: disk?.total,
                uptime: ProcessInfo.processInfo.systemUptime,
                recentCrashesCount: posture.crashes7d,
                crashSummary: posture.crashSummary,
                fanHelperInstalled: fanHelperInstalled,
                chargeHelperInstalled: chargeHelperInstalled
            )
            let result = AdvisorEngine.shared.analyze(snapshot)
            
            DispatchQueue.main.async {
                guard let self = self else { return }
                let visibleFindings = result.findings.filter {
                    !self.advisorDismissalStore.isDismissed(
                        $0.dismissKey,
                        criticalOverride: $0.severity == .critical
                    )
                }
                let visibleResult = AdvisorResult(
                    findings: visibleFindings,
                    analyzedAt: result.analyzedAt,
                    snapshotVersion: result.snapshotVersion
                )
                self.lastAdvisorResult = visibleResult
                
                // Обновляем вердикт героя
                let rawStatus = visibleResult.statusText.lowercased()
                let verdict = rawStatus.prefix(1).uppercased() + rawStatus.dropFirst()
                let heroTint: NSColor = {
                    switch visibleResult.maxSeverity {
                    case .critical: return Design.Color.levelCrit
                    case .warning: return Design.Color.levelWarn
                    case .notice: return Design.Color.levelWarn
                    case .info: return Design.Color.levelOK
                    }
                }()
                let count = visibleResult.findings.count
                let timeFormatted = DateFormatter.localizedString(from: result.analyzedAt, dateStyle: .none, timeStyle: .short)
                let meta = count > 0
                    ? String(format: L("%d рекомендаций · %@"), count, timeFormatted)
                    : String(format: L("Анализ: %@"), timeFormatted)
                self.healthHero.set(
                    symbol: visibleResult.findings.isEmpty ? "checkmark.shield.fill" : "heart.text.square.fill",
                    eyebrow: L("Центр здоровья"),
                    title: String(verdict),
                    subtitle: meta,
                    metric: visibleResult.findings.isEmpty ? "OK" : "\(count)",
                    tint: heroTint
                )
                
                // Очищаем контейнер
                self.healthFindingsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
                
                // Popover — краткая сводка, а не отчёт: только три наиболее важные находки.
                if visibleResult.findings.isEmpty {
                    self.healthFindingsContainer.addArrangedSubview(self.healthMessageRow(
                        symbol: "checkmark.circle.fill",
                        title: L("Рекомендаций нет"),
                        detail: L("Сейчас всё выглядит хорошо"),
                        tint: Design.Color.levelOK
                    ))
                } else {
                    for finding in visibleResult.findings.prefix(3) {
                        let card = self.buildAdvisorCard(finding)
                        self.healthFindingsContainer.addArrangedSubview(card)
                    }
                }
                if visibleResult.findings.count > 3 {
                    let more = GlassButton(title: String(
                        format: L("Ещё %d — открыть обслуживание"),
                        visibleResult.findings.count - 3
                    ), symbol: "arrow.right", cornerRadius: Design.Radius.chip)
                    more.translatesAutoresizingMaskIntoConstraints = false
                    more.widthAnchor.constraint(equalToConstant: self.IW).isActive = true
                    more.onClick = { [weak self] in self?.openHealthMaintenance() }
                    self.healthFindingsContainer.addArrangedSubview(more)
                }
                self.settlePreferredSize()
            }
        }
    }

    private func openHealthMaintenance() {
        if let index = tabOrder.firstIndex(of: "maintenance") {
            selectTab(index)
        } else {
            view.window?.close()
            SettingsCoordinator.open(section: "maintenance")
        }
    }
    
    /// Построить карточку рекомендации.
    private func buildAdvisorCard(_ finding: AdvisorFinding) -> NSView {
        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: finding.category.icon, accessibilityDescription: finding.category.label)
        iconView.contentTintColor = {
            switch finding.severity {
            case .critical: return Design.Color.levelCrit
            case .warning: return Design.Color.levelWarn
            case .notice: return Design.Color.accent(isDark)
            case .info: return .secondaryLabelColor
            }
        }()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 18).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 18).isActive = true
        
        let titleLabel = NSTextField(labelWithString: finding.title)
        titleLabel.font = Design.Font.sys(12, .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        let expLabel = NSTextField(labelWithString: finding.explanation)
        expLabel.font = Design.Font.sys(10, .regular)
        expLabel.textColor = .secondaryLabelColor
        expLabel.lineBreakMode = .byWordWrapping
        expLabel.maximumNumberOfLines = 2

        let text = NSStackView(views: [titleLabel, expLabel])
        text.orientation = .vertical
        text.spacing = 2

        let metric = NSTextField(labelWithString: finding.metric ?? "")
        metric.font = Design.Font.sys(10, .medium)
        metric.textColor = .tertiaryLabelColor
        metric.alignment = .right

        let actionable = finding.detailsDestination != nil || finding.action != nil
        var rowViews: [NSView] = [iconView, text, spacer(), metric]
        if actionable {
            let chevron = NSImageView()
            chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: L("Подробнее"))
            chevron.contentTintColor = .tertiaryLabelColor
            chevron.translatesAutoresizingMaskIntoConstraints = false
            chevron.widthAnchor.constraint(equalToConstant: 10).isActive = true
            rowViews.append(chevron)
        }

        let row = PopoverActionRow(frame: .zero)
        rowViews.forEach(row.addArrangedSubview)
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 8, left: 2, bottom: 8, right: 2)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: IW).isActive = true
        row.heightAnchor.constraint(equalToConstant: 58).isActive = true
        if actionable {
            row.accessibilityText = [finding.title, finding.explanation, finding.metric]
                .compactMap { $0 }
                .joined(separator: " · ")
            row.onPress = { [weak self] in self?.openAdvisorFinding(id: finding.id) }
        }
        return row
    }

    private func openAdvisorFinding(id: String) {
        guard let finding = lastAdvisorResult?.findings.first(where: { $0.id == id }) else { return }
        if let destination = finding.detailsDestination {
            openAdvisorDetails(destination: destination)
            return
        }
        guard let action = finding.action else { return }
        switch action {
        case .enableChargeLimit, .enableHeatProtection:
            openAdvisorDetails(destination: "power")
        case .activateFanProfile:
            openAdvisorDetails(destination: "cooling")
        case .openSettings(let section), .openPopoverSection(let section):
            openAdvisorDetails(destination: section)
        case .revealApplication(let appName):
            view.window?.close()
            let workspace = NSWorkspace.shared
            if let appURL = workspace.urlForApplication(withBundleIdentifier: appName) {
                workspace.open(appURL)
            } else {
                let appURL = URL(fileURLWithPath: "/Applications/\(appName).app")
                if FileManager.default.fileExists(atPath: appURL.path) { workspace.open(appURL) }
            }
        }
    }
    
    /// Открыть подробности рекомендации.
    private func openAdvisorDetails(destination: String) {
        if let idx = tabOrder.firstIndex(of: destination) {
            if idx != currentTab { selectTab(idx) }
            return
        }
        view.window?.close()
        SettingsCoordinator.open(section: destination)
    }
    
    /// Открыть/подсветить вкладку «Приватность» (из баннера first-conn). Поповер уже показан вызывающим.
    func focusPrivacyTab() {
        guard let idx = tabOrder.firstIndex(of: "privacy") else { return }
        if idx != currentTab { selectTab(idx) }
        tabBar?.select(idx, animated: false)
    }
    private func buildHardwareTile() -> NSView {
        // ватты CPU/GPU/DRAM приходят из хелпера; температуры/вентиляторы/нагрузка — без него.
        comp = [:]
        hardwareHero.set(
            symbol: "cpu",
            eyebrow: L("Тепловая картина"),
            title: L("Собираем данные датчиков"),
            subtitle: L("Температуры · частоты · охлаждение"),
            tint: Design.Color.accent(isDark),
            animated: false
        )
        let hw: [NSView] = [hardwareHero, gpuStatusView(), sensorsView,
                            compStatus, installBtn]
        return glassTile(vstack(hw, 8), fill: true)
    }

    /// Короткое имя GPU без вендорного префикса (для компактной строки «спит»).
    private func shortGPU(_ name: String) -> String {
        var s = name
        for p in ["NVIDIA GeForce ", "AMD Radeon ", "Intel ", "Apple "] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        return s
    }

    private let gpuLine = NSTextField(labelWithString: "")   // живой индикатор активной GPU (перекрашивается в тике)
    private func gpuStatusView() -> NSView {
        gpuLine.lineBreakMode = .byTruncatingTail
        gpuLine.translatesAutoresizingMaskIntoConstraints = false
        gpuLine.widthAnchor.constraint(equalToConstant: IW).isActive = true
        paintGPU()
        guard GPUInfo.switchable else { return gpuLine }

        // Дополнительная read-only строка с текущей политикой переключения.
        let policy = NSTextField(labelWithString: "")
        policy.font = Design.Font.caption
        policy.textColor = .secondaryLabelColor
        policy.translatesAutoresizingMaskIntoConstraints = false
        policy.widthAnchor.constraint(equalToConstant: IW).isActive = true
        gpuPolicyLabel = policy
        paintGPUPolicy()

        return vstack([gpuLine, policy], 6)
    }

    private weak var gpuPolicyLabel: NSTextField?

    /// Обновить read-only строку текущей политики GPU для вкладки «Железо».
    private func paintGPUPolicy() {
        // Не fallback на GPUInfo.mode(): sync fork+exec pmset на main. selectedMode
        // загружается async; до загрузки показываем «—».
        let mode = GPUController.shared.selectedMode
        gpuPolicyLabel?.stringValue = String(format: L("Политика: %@"), mode?.shortTitle ?? "—")
    }

    /// Перекрасить строку GPU по ТЕКУЩЕЙ активной карте (живая смена дискретная↔встроенная).
    private func paintGPU() {
        let gpus = GPUInfo.all()
        let active = GPUInfo.active()
        let f11 = Design.Font.caption
        if let a = active {
            let s = NSMutableAttributedString()
            s.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: NSColor.systemGreen, .font: f11]))
            s.append(NSAttributedString(string: a.name, attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: 11, weight: .semibold)]))
            if let other = gpus.first(where: { $0.registryID != a.registryID }) {
                s.append(NSAttributedString(string: "   ·  " + String(format: L("%@ спит"), shortGPU(other.name)), attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: f11]))
            }
            gpuLine.attributedStringValue = s
        } else {
            gpuLine.font = f11
            gpuLine.stringValue = gpus.first?.name ?? "—"
        }
    }
    private func buildAppsTile() -> NSView {
        // appsStack заворачиваем в host: флип (вращение/фейд) крутим на host, НЕ на appsStack и
        // НЕ на плитке (тень glassTile не трогаем). sectionLabel — статичный корешок секции.
        let host = NSView()
        host.wantsLayer = true
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(appsStack)
        appsStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            appsStack.topAnchor.constraint(equalTo: host.topAnchor),
            appsStack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            appsStack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            appsStack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        appsFlipHost = host
        // Рейтинг не должен «дышать» по высоте, когда top временно вернул меньше
        // процессов или helper-процессы объединились в одно приложение.
        host.heightAnchor.constraint(greaterThanOrEqualToConstant: 226).isActive = true
        // Компактная системная сводка завершает рейтинг и не конкурирует с ним отдельным графиком.
        let statsRow = NSStackView(views: [miniStat(appsFootProcs, NSTextField(labelWithString: L("Процессов"))),
                                           miniStat(appsFootCPU, NSTextField(labelWithString: L("CPU всего"))),
                                           miniStat(appsFootMem, NSTextField(labelWithString: L("Память")))])
        statsRow.distribution = .fillEqually; statsRow.spacing = 8
        statsRow.translatesAutoresizingMaskIntoConstraints = false
        statsRow.widthAnchor.constraint(equalToConstant: IW).isActive = true
        appsUpdatedLabel.font = Design.Font.sys(10, .regular)
        appsUpdatedLabel.textColor = .tertiaryLabelColor
        let seam = RimLightView()
        seam.translatesAutoresizingMaskIntoConstraints = false
        seam.widthAnchor.constraint(equalToConstant: IW).isActive = true
        seam.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return glassTile(vstack([host, seam, statsRow, appsUpdatedLabel], 7))
    }

    // MARK: компактный Control Center — быстрые действия + вывод звука по запросу
    private func buildControlPanel(ids: [String]) -> NSView {
        var sections: [NSView] = []
        func appendSection(_ view: NSView) {
            if !sections.isEmpty { sections.append(divider()) }
            sections.append(view)
        }
        if ids.contains("toggles") { appendSection(buildTogglesContent()) }
        if ids.contains("audio") { appendSection(buildAudioContent()) }
        let content = vstack(sections, 12)
        let environment = ProcessInfo.processInfo.environment
        let initiallyExpanded = environment["BM_CONTROLS_OPEN"] != nil
            || (environment["BM_SNAP"] == nil && SettingsStore.popoverControlsExpanded)
        let panel = PopoverControlPanel(
            title: L("Быстрые действия"),
            summary: "",
            content: content,
            expanded: initiallyExpanded
        )
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.widthAnchor.constraint(equalToConstant: CW).isActive = true
        panel.onExpansionChanged = { [weak self] expanded in
            SettingsStore.popoverControlsExpanded = expanded
            guard let self else { return }
            self.view.layoutSubtreeIfNeeded()
            self.root.layoutSubtreeIfNeeded()
            self.settlePreferredSize()
        }
        controlPanel = panel
        return panel
    }

    // MARK: плитка быстрых переключателей (Control Center) — встроенные + свои кнопки, по раскладке
    /// Контент переключателей без внешней плитки — используется внутри раскрываемого Control Center.
    private func buildTogglesContent() -> NSView {
        var buttons: [CCToggle] = []
        for item in SettingsStore.toggleLayout where item.on {
            if item.id.hasPrefix("custom:") {
                let cid = String(item.id.dropFirst("custom:".count))
                if let c = SettingsStore.customToggles.first(where: { $0.id == cid }) { buttons.append(makeCustomButton(c)) }
            } else if let def = QuickToggleRegistry.def(item.id), def.available() {
                buttons.append(makeBuiltinToggle(def))
            }
        }
        var rows: [NSView] = [Self.sectionLabel(L("Переключатели"))]
        if buttons.isEmpty {
            let l = NSTextField(labelWithString: L("включи в Настройки → Переключатели"))
            l.font = Design.Font.caption; l.textColor = .tertiaryLabelColor
            rows.append(l)
        }
        // ЖЁСТКАЯ сетка 2×N: ячейка ровно (IW−8)/2. `.fillEqually` НЕ гарантирует равенство
        // (equal-size стека не required и проигрывает текстовой геометрии CCToggle — «Wi-Fi» + длинная
        // подпись давали 57/207pt, «как влазит текст»). Required-ширина каждой ячейки решает.
        let cellW = (IW - 8) / 2
        var i = 0
        while i < buttons.count {
            let second: NSView
            if i + 1 < buttons.count {
                second = buttons[i + 1]
            } else {
                // нечётный последний: держим половину сетки, правая ячейка пустая — грид читается ровно
                second = NSView()
                second.translatesAutoresizingMaskIntoConstraints = false
            }
            buttons[i].widthAnchor.constraint(equalToConstant: cellW).isActive = true
            second.widthAnchor.constraint(equalToConstant: cellW).isActive = true
            let row = NSStackView(views: [buttons[i], second])
            row.distribution = .fill; row.spacing = 8
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: IW).isActive = true
            rows.append(row)
            i += 2
        }
        return vstack(rows, 8)
    }
    private func makeBuiltinToggle(_ def: QuickToggleDef) -> CCToggle {
        let t = CCToggle(id: def.id, icon: def.icon, title: def.label, accent: def.accent)
        t.toolTip = def.tooltip ?? def.label            // фикс-ячейка сетки режет длинные подписи «…» — полное имя в тултипе
        t.isBuiltin = true
        t.isMomentaryAction = def.isMomentaryAction
        t.stateProvider = def.isMomentaryAction ? nil : def.isOn
        t.isOn = def.isMomentaryAction ? false : def.isOn()
        t.onClick = { [weak self] in
            def.toggle()
            if !def.isMomentaryAction {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.refreshToggles() }
            }
        }
        ccToggles.append(t)
        return t
    }
    private func makeCustomButton(_ c: CustomToggle) -> CCToggle {
        let t = CCToggle(id: "custom:\(c.id)", icon: c.icon.isEmpty ? "bolt.fill" : c.icon, title: c.label, accent: c.accent)
        t.isOn = false                                  // мгновенное действие, не состояние
        t.isMomentaryAction = true
        // Pro-гейт на КЛИК, а не только на создание: после даунгрейда в Free кнопка не должна исполнять bash.
        t.onClick = {
            guard Licensing.shared.isPro else { _ = SettingsCoordinator.requirePro(.customToggles); return }
            CustomCommand.run(c.command)
        }
        return t
    }
    func refreshToggles() { ccToggles.forEach { $0.refresh() } }

    private func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        return v
    }
    /// Мини-показатель: крупное моноширинное значение + капс-подпись под ним.
    private func miniStat(_ val: NSTextField, _ cap: NSTextField) -> NSStackView {
        val.font = Design.Font.numericLarge
        val.alignment = .left
        cap.font = Design.Font.sys(11, .regular)       // как витальные подписи: единый регистр/кегль (убит 9pt-CAPS «двух эпох»)
        cap.textColor = .tertiaryLabelColor
        cap.lineBreakMode = .byTruncatingTail
        let s = vstack([val, cap], 2)
        s.alignment = .leading
        return s
    }
    /// Мини-показатель батареи: значение кладём в metric[key], чтобы update() обновлял его как раньше.
    private func battStat(_ key: String, _ caption: String) -> NSStackView {
        let val = NSTextField(labelWithString: "—")
        metric[key] = val
        return miniStat(val, NSTextField(labelWithString: caption))
    }
    private func validMin(_ m: Int) -> Int? { (m > 0 && m < 1200) ? m : nil }
    private func fmtHM(_ mins: Int) -> String {
        mins >= 60 ? String(format: "%d:%02d", mins/60, mins%60) : String(format: L("%d мин"), mins)
    }
    /// Вертикальный стек контента карточки.
    private func vstack(_ views: [NSView], _ spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }
    /// Стеклянная плитка (Control Center / Liquid Glass): непрерывные скругления,
    /// frosted-fill поверх размытого фона поповера, мягкая тень-глубина вместо рамки.
    private func glassTile(_ inner: NSView, radius: CGFloat = Design.Radius.tile, hInset: CGFloat = 16,
                           fill: Bool = false, chrome: Bool = true) -> NSView {
        let tile = NSView()
        tile.identifier = NSUserInterfaceItemIdentifier(chrome ? "workSurface" : "chromeFree")
        tile.wantsLayer = true
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.layer?.cornerRadius = radius
        tile.layer?.cornerCurve = .continuous
        tile.layer?.borderWidth = 0.75                 // мягкая световая кромка (glass rim), не хайрлайн
        Design.Elevation.tile(tile.layer!, dark: isDark)   // e1: тень-глубина из токена
        tile.addSubview(inner)
        inner.translatesAutoresizingMaskIntoConstraints = false
        // fill: контент прижат к ВЕРХУ (bottom — «не ниже»), чтобы карточку можно было
        // растянуть на всю высоту вкладки без расползания строк (для таб-плиток).
        let bottom = fill
            ? inner.bottomAnchor.constraint(lessThanOrEqualTo: tile.bottomAnchor, constant: -14)
            : inner.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -14)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: tile.topAnchor, constant: 14),
            bottom,
            inner.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: hInset),
            inner.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -hInset),
        ])
        cards.append(tile)
        return tile
    }
    /// Спокойная иерархия Control Center: единая blur-панель остаётся базой, а контентные
    /// группы получают очень тихую поверхность и световой кант. Это отделяет смысловые
    /// блоки без тяжёлых рамок и «карточки в карточке».
    private func paintCards() {
        for c in cards {
            let chrome = c.identifier?.rawValue == "workSurface"
            c.layer?.backgroundColor = chrome
                ? (isDark ? NSColor.white.withAlphaComponent(0.035)
                          : NSColor.black.withAlphaComponent(0.025)).cgColor
                : NSColor.clear.cgColor
            c.layer?.borderWidth = chrome ? 0.5 : 0
            c.layer?.borderColor = chrome
                ? Design.Color.hairline(isDark, isDark ? 0.08 : 0.06).cgColor
                : NSColor.clear.cgColor
            c.layer?.shadowOpacity = 0
        }
    }
    func applyTheme() {
        paintCards()
        tabBar?.applyTheme()
        graph.needsDisplay = true
        ring.needsLayout = true
        auraView.applyBase(dark: isDark, opacity: CGFloat(SettingsStore.popoverOpacity))
        // Цветовые токены различаются между темами — следующий update синхронно
        // пересчитает и кольцо, и ауру, не сохраняя старотемный CGColor.
        lastAuraColor = nil
    }

    /// Один цветовой источник для кольца и фонового свечения. Сравнение в sRGB
    /// предотвращает повторный запуск длинного cross-fade на каждом секундном тике.
    private func syncAura(to color: NSColor, animated: Bool) {
        let resolved = color.usingColorSpace(.sRGB) ?? color
        if let previous = lastAuraColor?.usingColorSpace(.sRGB),
           previous.isEqual(resolved) {
            return
        }
        lastAuraColor = resolved
        auraView.setColor(resolved, animated: animated, intensity: 0.18, duration: 0.72)
    }

    /// Цвет системной стрелки/рамки NSPopover. Контент рисует AuraView, но стрелка
    /// принадлежит отдельному окну AppKit и сама ауру не наследует.
    func popoverChromeColor() -> NSColor {
        let base = isDark
            ? NSColor(calibratedWhite: 0.13, alpha: 1)
            : NSColor(calibratedWhite: 0.96, alpha: 1)
        let aura = Design.Color.stateColor(lastVerdictLevel, isDark)
        return base.blended(withFraction: isDark ? 0.14 : 0.08, of: aura) ?? base
    }
    /// Консоль-включение (power-up): СЕКВЕНЦИЯ вместо одновременного всплытия —
    /// (1) шов прорисовывается сверху вниз, (2) ряды-плитки оседают со стаггером 0.045
    /// (перекрывая хвост шва, чтобы было снапово), (3) кольцо свипует дугой.
    func playOpenAnimation() {
        // СБРОС заморозки каскада закрытия: playCloseAnimation оставляет "close" на корневом
        // view.layer (fillMode .forwards + isRemovedOnCompletion false) — без снятия на открытии
        // корневой слой остаётся на opacity 0 и ВЕСЬ контент поповера невидим на повторном показе.
        view.layer?.removeAnimation(forKey: "close")
        view.layer?.opacity = 1
        // свип геройных гейджей «Железа», если поповер открылся на этой вкладке
        if currentTab < tabOrder.count, tabOrder[currentTab] == "hardware" {
            DispatchQueue.main.async { [weak self] in self?.sensorsView.animateIn() }
        }
        // оживление радара, если поповер открылся на вкладке «Приватность»
        if currentTab < tabOrder.count, tabOrder[currentTab] == "privacy" {
            DispatchQueue.main.async { [weak self] in self?.privacyView.animateIn(); self?.vpnChipRefresh?(); self?.mediaChipRefresh?() }
        }
        guard !Motion.reduced else { ring.animateIn(); return }   // «Уменьшить движение» — без всплытия/прорисовки
        // Плитки оседают со стаггером сразу с открытия.
        // Только РАЗМЕЩЁННЫЕ в иерархии карточки: замер вкладок кладёт в cards все до 6 таб-плиток,
        // но показана одна — 5 отсоединённых «съедали» слоты стаггера и раздували задержку видимой вкладки.
        let live = cards.filter { $0.superview != nil }
        for (i, c) in live.enumerated() {
            guard let lyr = c.layer else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1
            let move = CABasicAnimation(keyPath: "transform.translation.y")
            move.fromValue = -14; move.toValue = 0          // y вверх → старт чуть ниже, всплывает
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.985; scale.toValue = 1.0    // материя «надувается» на месте
            let g = CAAnimationGroup()
            g.animations = [fade, move, scale]
            g.duration = Design.Motion.durSlow
            g.beginTime = CACurrentMediaTime() + Double(i) * Design.Motion.stagger
            g.timingFunction = Design.Motion.easeStandard   // фирменная decelerate-кривая
            g.fillMode = .backwards
            lyr.add(g, forKey: "in")
        }
        ring.animateIn()                                          // 3) кольцо свипует (длинный свип сам читается последним)
    }
    /// Каскад ЗАКРЫТИЯ: цельный fade корневого слоя контента + лёгкое оседание вниз —
    /// зеркало открытия (которое всплывает с −y). Держим ≤ durBase, чтобы системный teardown
    /// .transient-окна не обрезал. Анимируем view.layer (живёт пока жив controller) → безопасно.
    /// `done` гарантированно зовётся ровно один раз, иначе performClose потеряется.
    func playCloseAnimation(_ done: @escaping () -> Void) {
        guard !Motion.reduced, let lyr = view.layer else { done(); return }
        var fired = false
        let fire = { if !fired { fired = true; done() } }
        CATransaction.begin()
        CATransaction.setCompletionBlock(fire)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = 0; move.toValue = -3              // экранный y вниз → оседание (зеркало всплытию)
        let g = CAAnimationGroup()
        g.animations = [fade, move]
        g.duration = Design.Motion.durClose
        g.timingFunction = Design.Motion.easeOut
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        lyr.add(g, forKey: "close")
        CATransaction.commit()
    }
    /// E1-проброс: flowView приватный — даём AppDelegate честные точки входа.
    func pulseUSB(connect: Bool) { flowView.pulseObod(connect: connect) }
    func setUSBCount(_ n: Int, name: String?) { flowView.setUSBCount(n, name: name) }
    /// Волосяной шов-разделитель: тонкая (1px) hairline-линия в ширину контента (IW),
    /// перекрашивается под тему. Заменяет тяжёлый NSBox.separator — это бренд-шов «безеля», а не системная рамка.
    private func divider() -> NSView {
        let v = HairlineView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: IW).isActive = true
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }
    private func metricRow(_ key: String) -> NSStackView {
        let name = NSTextField(labelWithString: key)
        name.font = Design.Font.caption
        name.textColor = .secondaryLabelColor
        let value = NSTextField(labelWithString: "—")
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        value.alignment = .right
        metric[key] = value
        let row = NSStackView(views: [name, spacer(), value])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: IW).isActive = true
        return row
    }

    // MARK: обновление данных
    func update(battery b: BatteryInfo, history: [Double], components c: ComponentPower,
                energy e: EnergySnapshot, sensors: SensorsSnapshot) {
        latestAdvisorBattery = b
        latestAdvisorEnergy = e
        latestAdvisorSensors = sensors
        flowView.update(
            e,
            components: c,
            hasBattery: b.present,
            batteryCharge: b.present ? b.charge : nil,
            externalPower: b.present ? b.external : nil,
            batteryCharging: b.present ? b.charging : nil
        )
        var feed = FlowInfoBar.Feed()
        feed.hasBattery = b.present
        feed.cycleCount = b.cycleCount
        feed.health = b.displayHealth
        feed.capacityWh = b.capacityWh
        feed.onBattery = b.present && !e.plugged
        feed.topApp = appsLast.first?.name
        feed.screenBrightness = e.screenBrightness
        feed.brightnessDelta = e.brightnessDelta
        flowInfoBar.update(feed)
        // (V6: термосводка удалена — строка под схемой несёт только живой разбор под курсором)
        applyThermalLabel()
        // «ядро NN°» ретайрнут из шапки (V3) — дублировал ТЕМП в витальных; тинт-температуру несёт витальная ячейка ниже.
        // «Спокойный прибор»: пилюля рельса — константная бирюза (ставится в buildModules), состоянием не красится
        refreshToggles()               // переключатели — не-батарейное, обновляем всегда (и на десктопе)
        refreshDisk()                  // диск — тоже не-батарейное; no-op, если плитка не построена
        refreshBT()                    // Bluetooth — не-батарейное; no-op, если плитка не построена
        refreshAudio()                 // аудио-вывод — не-батарейное; no-op, если плитка не построена

        // Сенсоры раз в тик — ЕДИНЫЙ источник и для витальных ячеек, и для вкладки «Железо»
        // (раньше снимок брался ниже, а «Темп» кормилась из e.cpuTemp=TC0P — иного датчика, чем герой).
        // Витальные CPU/Темп/Кулер/RAM + спарклайн НЕ зависят от наличия АКБ — обновляем всегда
        // (десктоп без батареи иначе оставался бы с пустой полосой и мёртвым графом навсегда;
        //  и разовый провал чтения батареи не должен замораживать расход/термику).
        // Единственный общий ватт теперь живёт во вкладке «Питание». В шапке показываем
        // универсальную нагрузку CPU — она доступна без SMC/powermetrics и не спорит с энергобалансом.
        let cpuLoad = sensors.loads.first(where: { $0.id == "cpuload" })?.value
            ?? SystemUsage.shared.cpuHistory.last
        statSysVal.stringValue = cpuLoad.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
        statSysVal.textColor = .labelColor
        let cpuTempSensor = sensors.temps.first { $0.id == "cpu" }        // тот же PECI-датчик, что и герой «Железа»
        statTempVal.stringValue = cpuTempSensor.map { String(format: "%.0f°", $0.value) } ?? "—"
        let cpuTempLvl = cpuTempSensor.map { Design.sensorLevel(id: "cpu", $0.value) } ?? .ok
        // «Спокойный прибор»: норма НЕЙТРАЛЬНА (не вечно-бирюзовая) — цвет только на реальном тепле
        statTempVal.textColor = (cpuTempLvl == .ok) ? .labelColor : Design.Color.stateColor(cpuTempLvl, isDark)
        statFanVal.stringValue = (e.fans.first.map { $0 > 0 } ?? false) ? String(format: "%.0f", e.fans.first!) : "—"
        statFanVal.textColor = .labelColor
        graph.accentColor = chargeAccent        // спарклайн всегда бренд-бирюза (состояние несёт кольцо)
        graph.setHistory(history)

        let ramLoad = sensors.loads.first(where: { $0.id == "ramload" })?.value
            ?? SystemUsage.shared.ramHistory.last
        statBatVal.stringValue = ramLoad.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
        statBatVal.textColor = .labelColor

        if b.present {
            // «Спокойный прибор»: кольцо несёт ТОЛЬКО состояние ЗАРЯДА — тепло живёт в ячейке «Темп» и в
            // ауре (та краснеет при реальном crit). Тепловой crit из тинта кольца УБРАН: иначе 90% заряда +
            // горячий CPU красили кольцо красным, читаясь как «критический заряд». Заряжается → бирюза;
            // иначе семантика заряда (≤15 красный / ≤35 амбер / иначе зелёный).
            let activelyCharging = b.charging && b.charge < 100
            let ringColor: NSColor = activelyCharging ? Design.Color.accentBright(isDark)
                : (b.charge <= 15 ? Design.Color.levelCrit
                   : (b.charge <= 35 ? Design.Color.levelWarn : Design.Color.levelOK))
            let presentedFlow: BatteryFlow = (b.charge >= 100 && e.battFlow == .charging) ? .idle : e.battFlow
            ring.set(charge: b.charge, charging: activelyCharging,
                     flow: presentedFlow, plugged: e.plugged, accent: ringColor)
            syncAura(to: ringColor, animated: true)
            applyChargeLimit()                         // тик на кольце + дорожка заряда (Pro charge limit)
            // дорожка заряда (строка 2): реальное состояние потолка/режима/парусов + Pro-флаг
            chargeTrack.set(charge: b.charge, charging: activelyCharging, flow: presentedFlow,
                            limit: ChargeControl.limit, mode: ChargeControl.mode,
                            sailUpper: ChargeControl.sailUpper, sailLower: ChargeControl.sailLower,
                            topUpActive: ChargeControl.isTopUpActive,
                            controlReady: ChargeControl.systemControlReady,
                            pro: Licensing.shared.isPro)

            // Статус ЧЕЛОВЕЧЕСКИМ языком, коротко (прежнее «адаптер 47 Вт» обрезалось до «адаптер 47 В»):
            // «Зарядка · до полного 1:20» / «От сети · держим 80%» / «От батареи · осталось 4:10».
            if b.charging && b.charge < 100 {
                statusTitle.stringValue = L("Зарядка")
                statusTitle.textColor = chargeAccent
                // «ещё» (не «до полного»): правая колонка шапки узкая (ring 80 + широкий вердикт),
                // длинный префикс обрезал бы САМО значение по хвосту («до полного 30 мин»→«до полного 3»).
                // Точный ярлык «ДО ПОЛНОГО» — в стат-строке ниже; здесь коротко, значение всегда видно.
                statusSub.stringValue = validMin(b.timeToFull).map { String(format: L("ещё %@"), fmtHM($0)) }
                    ?? String(format: L("%.0f Вт"), e.adapterWatts)
            } else if b.external {
                statusTitle.stringValue = L("От сети")
                statusTitle.textColor = .secondaryLabelColor
                statusSub.stringValue = ChargeControl.requiresSystemControl
                    ? L("защита настроена · не активна")
                    : (ChargeControl.limit < 100 && b.charge >= ChargeControl.limit - 2)
                    ? String(format: L("держим %d%%"), ChargeControl.limit)
                    : (b.charge >= 99 ? L("заряд завершён") : L("заряд приостановлен"))
            } else {
                statusTitle.stringValue = L("От батареи")
                statusTitle.textColor = .systemGreen
                statusSub.stringValue = validMin(b.timeToEmpty).map { String(format: L("ещё %@"), fmtHM($0)) }
                    ?? String(format: L("АКБ %.0f°"), b.temperature)
            }
            // (CPU/Темп/Кулер/RAM + спарклайн уже обновлены ВЫШЕ — не зависят от батарейной ветки.)

            metric["Здоровье"]?.stringValue = String(format: "%.0f%%", b.displayHealth)
            // Основная шкала здоровья заканчивается на 100%; сырой коэффициент остаётся в подсказке
            // вместе с обеими ёмкостями — диагностическая точность сохранена, но UI не выглядит сломанным.
            metric["Здоровье"]?.toolTip = (b.designCapacity > 0 && b.maxCapacity > 0)
                ? String(format: L("Полная ёмкость сейчас %d мА·ч из заводских %d мА·ч (%.0f%%). Выше 100%% — норма для новых или откалиброванных АКБ; ниже — естественный износ."),
                         b.maxCapacity, b.designCapacity, b.health)
                : nil
            metric["Циклы"]?.stringValue = "\(b.cycleCount)"
            metric["battAge"]?.stringValue = batteryAgeLine(b)
            if let why = batteryWhyNotCharging(b) {
                metric["battWhy"]?.stringValue = why; metric["battWhy"]?.isHidden = false
            } else { metric["battWhy"]?.isHidden = true }
            metric["Температура"]?.stringValue = String(format: L("%.1f °C"), b.temperature)
            metric["Напряжение"]?.stringValue = String(format: L("%.2f В"), b.voltage)
            let mins = b.timeToEmpty
            metric["Осталось"]?.stringValue = (!b.charging && mins > 0 && mins < 1200) ? String(format: "%d:%02d", mins/60, mins%60) : "—"
            metric["Ёмкость"]?.stringValue = String(format: L("%.0f / %.0f Вт·ч"), b.capacityWh, b.maxWh)
            cellsLabel.stringValue = b.cells.isEmpty ? "—" : String(format: L("Ячейки: %@ В"), b.cells.map { String(format: "%.3f", $0) }.joined(separator: " · "))
        } else {
            ring.setLimit(nil)                          // нет АКБ — ни тика лимита (плитка-шапка скрыта целиком)
            syncAura(to: Design.Color.stateColor(lastVerdictLevel, isDark), animated: true)
        }

        // сенсоры уже сняты выше (единый снимок за тик) — просто отдаём во вкладку «Железо»
        sensorsView.update(sensors)
        let hardwareSignal = worstTempSignal(sensors.temps)
        switch hardwareSignal.level {
        case .ok:
            if let hottest = hardwareSignal.sensor {
                hardwareStatus.stringValue = String(format: L("Макс. %@"), hottest.text)
                hardwareStatus.toolTip = String(
                    format: L("Самый горячий датчик: %@ · %@"),
                    hottest.name,
                    hottest.text
                )
                hardwareStatus.textColor = .secondaryLabelColor
            } else {
                hardwareStatus.stringValue = L("Нет данных температур")
                hardwareStatus.toolTip = nil
                hardwareStatus.textColor = .tertiaryLabelColor
            }
        case .warn:
            hardwareStatus.stringValue = hardwareSignal.sensor.map {
                String(format: L("Высокая: %@"), $0.text)
            } ?? L("Высокая температура")
            hardwareStatus.toolTip = hardwareSignal.sensor.map {
                String(format: L("Высокая температура: %@ · %@"), $0.name, $0.text)
            }
            hardwareStatus.textColor = Design.Color.levelWarn
        case .crit:
            hardwareStatus.stringValue = hardwareSignal.sensor.map {
                String(format: L("Перегрев: %@"), $0.text)
            } ?? L("Перегрев")
            hardwareStatus.toolTip = hardwareSignal.sensor.map {
                String(format: L("Перегрев: %@ · %@"), $0.name, $0.text)
            }
            hardwareStatus.textColor = Design.Color.levelCrit
        }
        let hardwareTitle: String
        let hardwareSubtitle: String
        let hardwareTint: NSColor
        let hardwareSymbol: String
        switch hardwareSignal.level {
        case .ok:
            hardwareTitle = hardwareSignal.sensor == nil ? L("Собираем данные датчиков") : L("Температуры в норме")
            hardwareTint = hardwareSignal.sensor == nil ? Design.Color.accent(isDark) : Design.Color.levelOK
            hardwareSymbol = hardwareSignal.sensor == nil ? "cpu" : "thermometer.medium"
        case .warn:
            hardwareTitle = L("Высокая температура")
            hardwareTint = Design.Color.levelWarn
            hardwareSymbol = "thermometer.high"
        case .crit:
            hardwareTitle = L("Перегрев")
            hardwareTint = Design.Color.levelCrit
            hardwareSymbol = "thermometer.sun.fill"
        }
        hardwareSubtitle = hardwareSignal.sensor?.name
            ?? L("Температуры · частоты · охлаждение")
        hardwareHero.set(
            symbol: hardwareSymbol,
            eyebrow: L("Тепловая картина"),
            title: hardwareTitle,
            subtitle: hardwareSubtitle,
            metric: hardwareSignal.sensor?.text,
            tint: hardwareTint
        )
        // живая смена GPU (дискретная↔встроенная) — перекрашиваем строку, пока видна вкладка «Железо»
        if currentTab < tabOrder.count, tabOrder[currentTab] == "hardware" {
            paintGPU()
            paintGPUPolicy()   // read-only политика во вкладке «Железо»
        }
        refreshAppsUpdatedLabel()      // «обновлено N с назад» в футере Приложений тикает каждую секунду
        // каталог-лента: read() ТОЛЬКО видимых строк (перф) + диагностика движка из уже собранных полей
        let visible = sensorsView.visibleIDs()
        let catRows = SensorCatalog.snapshot(visibleIDs: visible, record: true)
        sensorsView.updateCatalog(rows: catRows, components: c, energy: e)
        refreshHealthVerdict(battery: b, sensors: sensors)
        refreshTabDots(battery: b, sensors: sensors)                    // тихие warn/crit-точки на вкладках
        // Детализация powermetrics имеет собственную state machine. Краткий stale после
        // wake/нагрузки больше не маскируется под «нужно переустановить».
        switch HelperInstall.telemetryState(c) {
        case .ready:
            compStatus.isHidden = true
            installBtn.isHidden = true
        case .notInstalled:
            compStatus.isHidden = false
            installBtn.isHidden = false
            compStatus.stringValue = L("Детализация CPU/GPU/DRAM доступна после однократного подключения.")
            installBtn.title = L("Подключить…")
        case .starting:
            compStatus.isHidden = false
            installBtn.isHidden = true
            compStatus.stringValue = L("Системный модуль подключён — ждём первый замер.")
        case .temporarilyUnavailable:
            compStatus.isHidden = false
            installBtn.isHidden = true
            compStatus.stringValue = L("Детализация мощности временно недоступна. Базовый мониторинг продолжает работать.")
        case .repairNeeded:
            compStatus.isHidden = false
            installBtn.isHidden = false
            compStatus.stringValue = L("Установка системного модуля неполная.")
            installBtn.title = L("Восстановить…")
        }
    }

    /// Вердикт здоровья в шапке: цветная точка + слово ХУДШЕГО активного сигнала.
    /// Зеркалит язык вердикт-карты фаервола, но компактно (одна слим-строка, не меняет высоту).
    /// Сигналы (как в задании): перегрев температур (Design.tempLevel), высокий расход системы (>28 Вт),
    /// критический заряд (≤15%), форс-кулер (SensorsModel forced). Берём worst-of, с крошечной спецификой.
    /// Худший ТЕПЛОВОЙ сигнал по ЧЕСТНЫМ per-sensor порогам (не единый 70/85 → иначе Intel CPU = вечный крит).
    /// Возврат: уровень + датчик-источник (для подписи). Среди датчиков одного уровня берём самый горячий.
    private func worstTempSignal(_ temps: [Sensor]) -> (level: Design.Level, sensor: Sensor?) {
        var best: (Design.Level, Sensor)?
        for s in temps {
            let l = Design.sensorLevel(id: s.id, s.value)
            if best == nil || Design.rank(l) > Design.rank(best!.0)
                || (Design.rank(l) == Design.rank(best!.0) && s.value > best!.1.value) {
                best = (l, s)
            }
        }
        return (best?.0 ?? .ok, best?.1)
    }

    private func refreshHealthVerdict(battery b: BatteryInfo, sensors: SensorsSnapshot) {
        // Худший тепловой сигнал по ЧЕСТНЫМ порогам датчика (CPU крит ≥100°, батарея ≥45° и т.д.).
        let (instTempLvl, _) = worstTempSignal(sensors.temps)
        // Устойчивость: крит-температуру показываем «Перегрев» только если держится ≥3 тика (~4–5с),
        // иначе мгновенный турбо-скачок кристалла флипал бы капсулу. До того — максимум «Греется».
        if instTempLvl == .crit { tempCritStreak += 1 } else { tempCritStreak = 0 }
        let tempLvl: Design.Level = (instTempLvl == .crit && tempCritStreak < 3) ? .warn : instTempLvl
        let critCharge = b.present && !b.charging && b.charge <= 15      // как кольцо/алерты: критический заряд
        // «Спокойный прибор» (совет по дизайну): ни высокий расход (40–70 Вт норма на ноуте), ни forced-кулеры
        // (у владельца с fan-кривой это ПОСТОЯННО) — НЕ фолт. Вердикт-warn остаётся ТОЛЬКО за реальной жарой
        // (Греется/Перегрев) → кольцо амбер редко и честно; температура/обороты видны в витальных.

        if tempLvl == .crit || critCharge {
            lastVerdictLevel = .crit
        } else if tempLvl == .warn {
            lastVerdictLevel = .warn
        } else {
            lastVerdictLevel = .ok
        }
    }

    /// Тихие warn/crit-точки на вкладках таб-бара: «Железо» — перегрев сенсора (Design.tempLevel),
    /// «Питание» — критический заряд (crit) или высокий расход системы (warn). Спокойная машина — точек нет.
    /// Берёт уже собранные снимки (не перечитывает SMC); оверлей не меняет высоту таб-бара.
    private func refreshTabDots(battery b: BatteryInfo, sensors: SensorsSnapshot) {
        guard let bar = tabBar else { return }
        let hwLevel: Design.Level? = { let l = worstTempSignal(sensors.temps).level; return l == .ok ? nil : l }()
        let critCharge = b.present && !b.charging && b.charge <= 15      // как кольцо/алерты/вердикт
        // V3 «спокойный прибор»: высокий расход больше НЕ warn-точка на вкладке (на ноуте 40–70Вт норма) — только реальный crit.
        let pwrLevel: Design.Level? = critCharge ? .crit : nil
        for (i, id) in tabOrder.enumerated() {
            switch id {
            case "hardware": bar.setDot(i, hwLevel)
            case "flow":     bar.setDot(i, pwrLevel)
            default:         bar.setDot(i, nil)          // «Приложения» и прочее — спокойны
            }
        }
    }

    private func fmtW(_ v: Double?) -> String { v.map { String(format: L("%.2f Вт"), $0) } ?? "—" }

    private func rowView(id: String) -> NSView? {
        func find(_ v: NSView) -> NSView? {
            if v.identifier?.rawValue == id { return v }
            for s in v.subviews { if let r = find(s) { return r } }
            return nil
        }
        return find(view)
    }

    func updateApps(_ apps: [AppEnergy]) {
        AppSession.pushImpacts(apps)         // сессионная история impact (спарклайн) — из уже-собранного снимка
        let grouped = groupedApps(apps)
        appsLast = grouped
        refreshAppFlags()                    // освежаем гео-флаги в фоне (lsof не на main)
        renderAppRows(grouped, animateReorder: true)
        // футер-сводка (все данные уже собраны этим же снимком/тиком — ноль новых системных чтений)
        AppSession.pushTopTotal(apps.reduce(0) { $0 + $1.impact })
        appsUpdatedAt = Date()
        appsFootProcs.stringValue = PowerInfo.lastProcCount.map(String.init) ?? "—"
        // до первого сэмпла — честное «—», не выдуманный «0%»
        appsFootCPU.stringValue = SystemUsage.shared.cpuHistory.last.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
        appsFootMem.stringValue = SystemUsage.shared.ramHistory.last.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
        appsTotalSpark.setHistory(AppSession.topTotalHistory(), tint: Design.Color.accent(isDark))
        refreshAppsUpdatedLabel()
        // Число сгруппированных строк меняется от снимка к снимку — высота вкладки следует
        // фактическому списку, а не старому фиксированному резерву.
        settlePreferredSize()
    }

    /// `top` возвращает отдельные helper/web-content процессы. Для быстрого рейтинга это шум:
    /// объединяем их по имени приложения, суммируя расход, CPU, память и потоки.
    private func groupedApps(_ apps: [AppEnergy]) -> [AppEnergy] {
        var result: [String: AppEnergy] = [:]
        for app in apps {
            let resolved = Connections.resolveByName(app.name).name
            let display: String = {
                let candidates = [resolved, app.name]
                for candidate in candidates {
                    let lower = candidate.lowercased()
                    if lower == "code" || lower.hasPrefix("code ")
                        || lower.hasPrefix("code…") || lower.hasPrefix("visual studio code") {
                        return "Visual Studio Code"
                    }
                    if lower.hasPrefix("firefox") { return "Firefox" }
                    if lower.hasPrefix("google chrome helper") { return "Google Chrome" }
                    if lower.hasPrefix("safari web content") { return "Safari" }
                }
                return resolved.isEmpty ? app.name : resolved
            }()
            if var current = result[display] {
                current.impact += app.impact
                current.cpu = (current.cpu ?? 0) + (app.cpu ?? 0)
                current.memMB = (current.memMB ?? 0) + (app.memMB ?? 0)
                current.threads = (current.threads ?? 0) + (app.threads ?? 0)
                result[display] = current
            } else {
                result[display] = AppEnergy(name: display, impact: app.impact, cpu: app.cpu,
                                            memMB: app.memMB, threads: app.threads)
            }
        }
        return Array(result.values)
    }
    /// «обновлено только что / N с назад» — живёт на 1Гц-тике (данные приложений едут раз в ~5с).
    func refreshAppsUpdatedLabel() {
        guard let t = appsUpdatedAt else { appsUpdatedLabel.stringValue = ""; return }
        let s = Int(Date().timeIntervalSince(t).rounded())
        appsUpdatedLabel.stringValue = s <= 1 ? L("обновлено только что")
                                              : String(format: L("обновлено %d сек. назад"), s)
    }

    /// Ховер строки: замораживает/размораживает вертикальную пересортировку лидерборда (O4).
    /// Зовётся строкой из mouseEntered/mouseExited. По выходу — применяем отложенный снимок (если был),
    /// уже без «прыжка» под курсором. Гейт Motion.reduced: при reduced FLIP и так выключен — гейт инертен.
    func setRowHover(_ name: String?, entered: Bool) {
        if entered {
            hoveredRowName = name
        } else if hoveredRowName == name {
            hoveredRowName = nil
            if let pending = pendingAppsSnapshot {
                pendingAppsSnapshot = nil
                renderAppRows(pending, animateReorder: true)   // отложенная пересортировка — теперь курсор ушёл
            }
        }
    }

    /// Сбросить реестр переиспользуемых карточек (при переходе в досье/пустой-стейт/calm-floor).
    private func teardownAppRows() {
        appsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        appRows.removeAll(); appHeroName = nil; appsHeader = nil; appsVerdict = nil
        lastFlagCodes.removeAll()                           // O12: карточек нет — diff-кэш флагов недействителен
        hoveredRowName = nil; pendingAppsSnapshot = nil     // реестр сброшен — заморозка ховера недействительна
    }

    /// Достойный пустой/сборный плейсхолдер: нейтральный SF-символ над подписью, центр по H и V в
    /// зарезервированной высоте (266 — тот же пол host). Голый caption у левого края читался бы как
    /// «сломалось» в платном продукте. Без анимации появления (нет пульса под Motion.reduced).
    private func appsPlaceholder(symbol: String, text: String) -> NSView {
        let container = NSView()
        container.identifier = NSUserInterfaceItemIdentifier("appsPlaceholder")   // чтобы data-ветка могла снять «висящий» плейсхолдер
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(equalToConstant: IW).isActive = true
        container.heightAnchor.constraint(equalToConstant: 260).isActive = true   // ≈ пол host, минус корешок секции

        let cfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        let iv = NSImageView()
        iv.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        iv.contentTintColor = .tertiaryLabelColor
        iv.translatesAutoresizingMaskIntoConstraints = false

        let l = NSTextField(labelWithString: text)
        l.font = Design.Font.caption; l.textColor = .tertiaryLabelColor
        l.alignment = .center

        let col = NSStackView(views: [iv, l])
        col.orientation = .vertical; col.alignment = .centerX; col.spacing = 8
        col.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(col)
        NSLayoutConstraint.activate([
            col.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            col.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    /// Отрисовка гибрида A+ГЕРОЙ из снимка энергии (без нового top/lsof). Зовут updateApps
    /// (новый снимок → animateReorder), гео-колбэк (флаги доехали → без reorder) и смена сортировки.
    /// animateReorder=true — включает FLIP-пересортировку по имени (переиспользуем вью, не сносим).
    private func renderAppRows(_ apps: [AppEnergy], animateReorder: Bool = false) {
        // ИНВАРИАНТ ДОСЬЕ: пока открыто — рисуем ЛИЦО досье (не лидерборд) на каждый снимок/колбэк.
        if let name = openDossierName {
            if apps.isEmpty { openDossierName = nil }     // idle Mac обнулил топ → безопасный возврат к лидерборду
            else { teardownAppRows(); renderDossierFace(name, apps: apps); return }
        }
        // Пустой/сборный стейт и calm-floor — плейсхолдер, реестр карточек сбрасываем.
        if apps.isEmpty {
            teardownAppRows()
            appsStack.addArrangedSubview(appsPlaceholder(symbol: "hourglass", text: L("сбор данных…")))
            return
        }
        // CALM FLOOR: на простаивающем Mac у топ-приложения крошечный impact — спокойный пустой-стейт.
        // impact — базовая метрика во всех режимах (для .net значение колонки всё равно impact), поэтому
        // держим calm-floor при ЛЮБОЙ сортировке: иначе «герой» промотирует шум с РАСХОД 0.0 в accent-кант.
        let topImpact = sortedApps(apps).first?.impact ?? 0
        if topImpact < 1.0 {
            teardownAppRows()
            appsStack.addArrangedSubview(appsPlaceholder(symbol: "moon.zzz", text: L("Ничего не нагружает")))
            return
        }

        // КРИТИЧНО: data-ветка НЕ зовёт teardownAppRows (переиспользует карточки через reorderStack), поэтому
        // «висящий» плейсхолдер (260pt hourglass, посеянный updateApps([]) на старте) оставался в стеке НАВСЕГДА
        // → вечный «сбор данных…» + скачущая вёрстка. Снимаем любой плейсхолдер перед сборкой лидерборда.
        appsStack.arrangedSubviews
            .filter { $0.identifier?.rawValue == "appsPlaceholder" }
            .forEach { $0.removeFromSuperview() }

        let ordered = Array(sortedApps(apps).prefix(6))
        // Знаменатель длины бара — максимум АКТИВНОЙ метрики (impact/CPU/сеть), чтобы бар кодировал
        // ту же величину, что число и порядок (в CPU/Сеть прежний impact-бар врал).
        let maxMetric = max(ordered.map { appSortMetric($0) }.max() ?? 1, 0.001)
        let targetNames = ordered.map { $0.name }
        let targetSet = Set(targetNames)

        // O4: строка под курсором раскрыта оверлеем, привязанным к её геометрии. FLIP двигает СЛОЙ —
        // оверлей отклеился бы, а под неподвижным курсором mouseExited не перевызвался. Пока ховер жив,
        // замораживаем вертикальную пересортировку/эвикт: обновляем ТОЛЬКО значения/бар/спарк/флаги НА
        // МЕСТЕ (порядок не трогаем), а последний снимок откладываем — применим по mouseExited.
        if animateReorder, hoveredRowName != nil, !appRows.isEmpty {
            pendingAppsSnapshot = apps
            for a in ordered {
                guard let card = appRows[a.name] else { continue }   // новые/переехавшие ждут разморозки
                configureCard(card, a: a, fraction: appSortMetric(a) / maxMetric, isHero: card.isHero, animateValue: true)
            }
            DispatchQueue.main.async { [weak self] in self?.applyAppRowTips() }
            return
        }

        // ВЫВОД-ВЕРДИКТ над лидербордом: #1 потребитель как ГОТОВЫЙ вывод, а не таблица для чтения
        // («Chrome больше всех расходует энергию») — это и есть преимущество над Мониторингом системы.
        if appsVerdict == nil {
            let v = NSTextField(labelWithString: "")
            v.font = Design.Font.sys(12, .semibold); v.textColor = .labelColor
            // 2 строки с переносом: длинное имя процесса («WindowServer») + фраза не влезали в одну
            // строку IW и обрезались по хвосту («…больше всех рас…»), теряя сам вывод. Перенос держит
            // вердикт целым (и заполняет верх вкладки — цель L4), высоту вкладка вмещает.
            v.lineBreakMode = .byWordWrapping; v.maximumNumberOfLines = 2
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: IW).isActive = true
            v.preferredMaxLayoutWidth = IW
            appsVerdict = v
            appsStack.addArrangedSubview(v)
        }
        if let top = ordered.first { appsVerdict?.stringValue = appsVerdictText(top) }

        // Заголовок колонки + сегмент сортировки — строится один раз, живёт наверху стека.
        if appsHeader == nil {
            let h = appsColumnHeader()
            appsHeader = h
            appsStack.addArrangedSubview(h)
        } else {
            updateColumnHeaderEyebrow()
        }

        // Снять First-кадры существующих карточек ДО перестановки (для FLIP).
        let doFlip = animateReorder && !Motion.reduced
        var firstFrames: [String: CGRect] = [:]
        if doFlip { for (n, v) in appRows { firstFrames[n] = v.frame } }

        // Эвикт карточек, выпавших из топа.
        for (n, v) in appRows where !targetSet.contains(n) {
            v.removeFromSuperview(); appRows[n] = nil
            lastFlagCodes[n] = nil      // O12: не течь diff-кэшем флагов
            if appHeroName == n { appHeroName = nil }
        }

        // Создать/обновить карточки НА МЕСТЕ и выставить целевой порядок в стеке.
        var newCardNames: [String] = []
        for (_, a) in ordered.enumerated() {
            let isHero = false
            let card: DossierRowView
            if let existing = appRows[a.name], (existing.isHero == isHero) {
                card = existing
            } else {
                appRows[a.name]?.removeFromSuperview()       // сменилась роль (герой↔строка) — пересоздать
                card = buildAppCard(a, isHero: isHero)
                appRows[a.name] = card
                newCardNames.append(a.name)
            }
            configureCard(card, a: a, fraction: appSortMetric(a) / maxMetric, isHero: isHero, animateValue: animateReorder)
        }
        appHeroName = nil

        // Целевой порядок arrangedSubviews: вердикт, header, затем карточки в порядке ordered.
        var order: [NSView] = []
        if let vd = appsVerdict { order.append(vd) }
        if let h = appsHeader { order.append(h) }
        for a in ordered { if let c = appRows[a.name] { order.append(c) } }
        reorderStack(appsStack, to: order)

        // O5: имя, что БЫЛО до пересортировки (есть First-кадр), но карточка пересоздана из-за смены
        // роли герой↔строка, — это ПЕРЕЕЗД, а не рождение. Даём ему FLIP от старого origin.y (а не
        // stagger-fade), иначе экс-герой и новый герой ХЛОПАЮТ, пока строки 2..6 плавно скользят.
        let trulyNewNames = newCardNames.filter { firstFrames[$0] == nil }

        // FLIP: Last-кадры после layout, анимируем Δ(First−Last) к нулю (соседи волной).
        if doFlip {
            appsStack.layoutSubtreeIfNeeded()
            for (n, v) in appRows {
                guard let first = firstFrames[n] else { continue }   // покрывает и переехавшего (пере)героя
                let dy = first.origin.y - v.frame.origin.y
                guard abs(dy) > 0.5 else { continue }
                let anim = CABasicAnimation(keyPath: "transform.translation.y")
                anim.fromValue = dy; anim.toValue = 0
                anim.duration = Design.Motion.durBase
                // O10: reorder на фирменной decelerate (без overshoot — 6 строк с перелётом-откатом читались «желе»).
                anim.timingFunction = Design.Motion.easeStandard
                v.layer?.add(anim, forKey: "flipReorder")
            }
        }
        // Каскад появления ТОЛЬКО по-настоящему новых карточек (stagger) — при первом заполнении/новых именах.
        if !Motion.reduced {
            for (i, n) in trulyNewNames.enumerated() {
                guard let v = appRows[n] else { continue }
                v.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Design.Motion.durSlow
                    ctx.timingFunction = Design.Motion.easeOut
                    v.animator().alphaValue = 1
                }
                let rise = CABasicAnimation(keyPath: "transform.translation.y")
                rise.fromValue = -6; rise.toValue = 0
                rise.beginTime = CACurrentMediaTime() + Double(i) * Design.Motion.stagger
                rise.duration = Design.Motion.durSlow
                rise.timingFunction = Design.Motion.easeOut
                rise.fillMode = .backwards
                v.layer?.add(rise, forKey: "stagger")
            }
        }
        // Тултипы на усекаемое — ПОСЛЕ layout (ширина известна только тогда).
        DispatchQueue.main.async { [weak self] in self?.applyAppRowTips() }
    }

    /// Переставить arrangedSubviews стека в целевой порядок без сноса вью (FLIP-совместимо).
    private func reorderStack(_ stack: NSStackView, to order: [NSView]) {
        for (i, v) in order.enumerated() {
            if v.superview == nil || !stack.arrangedSubviews.contains(v) {
                stack.insertArrangedSubview(v, at: min(i, stack.arrangedSubviews.count))
            } else if let cur = stack.arrangedSubviews.firstIndex(of: v), cur != i {
                stack.removeArrangedSubview(v)
                stack.insertArrangedSubview(v, at: min(i, stack.arrangedSubviews.count))
            }
        }
    }

    /// Капс-эйброу над колонкой значений + сегмент сортировки (Расход/CPU/Сеть) справа сверху.
    /// Вывод-вердикт «кто грузит» — фраза по активной сортировке + имя топ-приложения (честно: это #1
    /// по тому же критерию, что и лидерборд; ничего не выдумываем — только называем вывод словами).
    private func appsVerdictText(_ a: AppEnergy) -> String {
        switch appsSort {
        case .impact: return String(format: L("%@ расходует больше всего · %@"), a.name, fmtImpact(a.impact))
        case .cpu:    return String(format: L("%@ сильнее грузит CPU · %@"), a.name, a.cpu.map(fmtCPU) ?? "—")
        case .net:    return String(format: L("%@ активнее всех в сети · %d"), a.name, appNetCount(a))
        }
    }

    private func appsColumnHeader() -> NSView {
        let seg = makeAppsSortSegment()

        let row = NSStackView(views: [seg])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 0
        row.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 3, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: IW).isActive = true
        return row
    }
    private func updateColumnHeaderEyebrow() {
        // Полноширинный сегмент сам объясняет активную метрику; отдельный обрезаемый эйброу больше не нужен.
    }
    private func findField(in v: NSView, id: String) -> NSTextField? {
        if let f = v as? NSTextField, f.identifier?.rawValue == id { return f }
        for s in v.subviews { if let r = findField(in: s, id: id) { return r } }
        return nil
    }

    /// Сегмент сортировки Расход/CPU/Сеть в стиле PillTabBar. Смена → пересортировка той же FLIP.
    private func makeAppsSortSegment() -> NSView {
        let labels = [L("Расход"), L("CPU"), L("Сеть")]
        let sel: Int = appsSort == .impact ? 0 : (appsSort == .cpu ? 1 : 2)
        let bar = PillTabBar(labels: labels, selected: sel)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: IW).isActive = true
        bar.heightAnchor.constraint(equalToConstant: 26).isActive = true
        bar.setAccessibilityLabel(L("Сортировка расхода приложений"))
        bar.onSelect = { [weak self] i in
            guard let self = self else { return }
            let s: AppEnergySort = i == 0 ? .impact : (i == 1 ? .cpu : .net)
            guard s != self.appsSort else { return }
            self.appsSort = s
            self.renderAppRows(self.appsLast, animateReorder: true)   // та же FLIP-пересортировка
        }
        return bar
    }

    /// Флаг-вью страны-назначения (лидерборд). Тултип НАЗЫВАЕТ страну через GeoIP.name (правило).
    private func makeFlagView(for name: String, resolvedName: String, width: CGFloat) -> NSView {
        let key = resolvedName.lowercased()
        let alt = name.lowercased()
        let flag = appCountryFlags[key] ?? appCountryFlags[alt]
        let flagView: NSView
        if let flag = flag, flag != Self.lanGlobe {
            let f = NSTextField(labelWithString: flag)
            f.font = Design.Font.caption
            // тултип флага = ИМЯ показанной страны (не «усечение»): код из самого флага → GeoIP.name.
            f.toolTip = GeoIP.code(fromFlag: flag).map { GeoIP.name($0) } ?? L("Активное сетевое соединение в эту страну")
            flagView = f
        } else if flag == Self.lanGlobe {
            let g = NSImageView()
            g.image = NSImage(systemSymbolName: "globe", accessibilityDescription: L("Локальная сеть"))
            g.contentTintColor = .tertiaryLabelColor
            g.translatesAutoresizingMaskIntoConstraints = false
            g.widthAnchor.constraint(equalToConstant: 11).isActive = true
            g.heightAnchor.constraint(equalToConstant: 11).isActive = true
            g.toolTip = L("Соединение только в локальной сети")
            flagView = g
        } else {
            flagView = NSView()
        }
        flagView.translatesAutoresizingMaskIntoConstraints = false
        flagView.widthAnchor.constraint(equalToConstant: width).isActive = true
        return flagView
    }

    private func appIconView(_ a: AppEnergy, resolved: (icon: NSImage?, name: String), side: CGFloat) -> NSView {
        let iconView: NSView
        if let img = resolved.icon {
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            // Ж1: единый токен скругления app-иконки; герою (крупнее) — пропорционально больше.
            iv.layer?.cornerRadius = side >= 28 ? 6 : Design.Radius.appIcon
            iv.layer?.cornerCurve = .continuous
            iv.layer?.masksToBounds = true
            iv.image = img
            iconView = iv
        } else {
            iconView = systemProcessGlyph(a.name)
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: side).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: side).isActive = true
        return iconView
    }

    /// Строит новую карточку (герой или строку лидерборда) с ссылками на мутируемый контент.
    /// Контент наполняется отдельно в configureCard (чтобы FLIP-переиспользование обновляло НА МЕСТЕ).
    private func buildAppCard(_ a: AppEnergy, isHero: Bool) -> DossierRowView {
        let wrapper = DossierRowView()
        wrapper.owner = self
        wrapper.appName = a.name
        wrapper.isHero = isHero
        wrapper.barW = appsBarW
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.wantsLayer = true
        wrapper.layer?.cornerRadius = Design.Radius.chip
        wrapper.layer?.cornerCurve = .continuous
        wrapper.widthAnchor.constraint(equalToConstant: IW).isActive = true
        if isHero { buildHeroBody(wrapper, a: a) } else { buildRowBody(wrapper, a: a) }
        return wrapper
    }

    /// Тело строки лидерборда: [иконка][имя][спарклайн][бар][значение][флаг].
    private func buildRowBody(_ wrapper: DossierRowView, a: AppEnergy) {
        let resolved = Connections.resolveByName(a.name)
        let baseFill = Design.Color.controlFill(isDark).cgColor
        wrapper.baseFill = baseFill
        wrapper.layer?.backgroundColor = baseFill
        wrapper.layer?.borderWidth = 0

        let iconView = appIconView(a, resolved: resolved, side: 20)

        let name = NSTextField(labelWithString: resolved.name)
        name.font = Design.Font.caption
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.identifier = NSUserInterfaceItemIdentifier("rowName")
        name.setContentHuggingPriority(.init(1), for: .horizontal)
        name.setContentCompressionResistancePriority(.init(250), for: .horizontal)

        let spark = MiniSpark()
        spark.translatesAutoresizingMaskIntoConstraints = false
        spark.widthAnchor.constraint(equalToConstant: appsSparkW).isActive = true
        spark.heightAnchor.constraint(equalToConstant: 14).isActive = true
        wrapper.spark = spark

        let track = NSView()
        track.translatesAutoresizingMaskIntoConstraints = false
        track.wantsLayer = true
        track.layer?.backgroundColor = Design.Color.trackFill(isDark).cgColor
        track.layer?.cornerRadius = 3; track.layer?.cornerCurve = .continuous
        track.widthAnchor.constraint(equalToConstant: appsBarW).isActive = true
        track.heightAnchor.constraint(equalToConstant: 6).isActive = true
        let fill = NSView()
        fill.translatesAutoresizingMaskIntoConstraints = false
        fill.wantsLayer = true
        fill.layer?.backgroundColor = Design.Color.accent(isDark).cgColor
        fill.layer?.cornerRadius = 3; fill.layer?.cornerCurve = .continuous
        track.addSubview(fill)
        let fw = fill.widthAnchor.constraint(equalToConstant: 6)
        wrapper.fillWidth = fw
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fw,
        ])

        let val = NSTextField(labelWithString: "")
        val.font = Design.Font.numericBody
        val.textColor = .secondaryLabelColor
        val.alignment = .right
        val.wantsLayer = true                 // roll-up CATransition требует backing-слой
        val.translatesAutoresizingMaskIntoConstraints = false
        val.widthAnchor.constraint(equalToConstant: appsValW).isActive = true
        wrapper.valLabel = val

        let flag = makeFlagView(for: a.name, resolvedName: resolved.name, width: appsFlagW)
        let flagHost = NSView()
        flagHost.translatesAutoresizingMaskIntoConstraints = false
        flagHost.widthAnchor.constraint(equalToConstant: appsFlagW).isActive = true
        flagHost.addSubview(flag)
        NSLayoutConstraint.activate([
            flag.centerXAnchor.constraint(equalTo: flagHost.centerXAnchor),
            flag.centerYAnchor.constraint(equalTo: flagHost.centerYAnchor),
        ])
        wrapper.flagHost = flagHost

        let row = NSStackView(views: [iconView, name, spark, track, val, flagHost])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: wrapper.topAnchor),
            row.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        ])
    }

    /// Тело ГЕРОЯ: accent-кант, крупная иконка, имя + микро-строка CPU·MEM, полноширинный спарклайн,
    /// РАСХОД крупно справа, кластер флагов-назначений. Крупнее строк — «дорогая» плитка.
    private func buildHeroBody(_ wrapper: DossierRowView, a: AppEnergy) {
        let resolved = Connections.resolveByName(a.name)
        let accent = Design.Color.accent(isDark)
        let baseFill = Design.Color.glassTint(accent, isDark).cgColor
        wrapper.baseFill = baseFill
        wrapper.layer?.backgroundColor = baseFill
        wrapper.layer?.borderWidth = 1
        wrapper.layer?.borderColor = Design.Color.accentRim(isDark).cgColor   // Ж2: токен accentRim (app↔web-контракт)

        let iconView = appIconView(a, resolved: resolved, side: 28)

        let name = NSTextField(labelWithString: resolved.name)
        name.font = Design.Font.headline
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.identifier = NSUserInterfaceItemIdentifier("rowName")
        name.setContentHuggingPriority(.init(1), for: .horizontal)
        name.setContentCompressionResistancePriority(.init(250), for: .horizontal)

        let micro = NSTextField(labelWithString: "")
        micro.font = Design.Font.microStat
        micro.textColor = .tertiaryLabelColor
        micro.lineBreakMode = .byTruncatingTail
        micro.wantsLayer = true             // Ж6: CATransition crossfade требует backing-слой
        wrapper.microLine = micro
        let nameCol = NSStackView(views: [name, micro])
        nameCol.orientation = .vertical
        nameCol.alignment = .leading
        nameCol.spacing = 1

        // РАСХОД крупно + капс
        let valNum = NSTextField(labelWithString: "")
        valNum.font = Design.Font.numericLarge
        valNum.textColor = .labelColor
        valNum.alignment = .right
        valNum.wantsLayer = true              // roll-up CATransition требует backing-слой
        wrapper.valLabel = valNum
        let valCap = NSTextField(labelWithString: "")
        valCap.font = Design.Font.microStat
        valCap.textColor = .tertiaryLabelColor
        valCap.alignment = .right
        capsText(valCap, L("Расход"))
        let valueCluster = NSStackView(views: [valNum, valCap])
        valueCluster.orientation = .vertical
        valueCluster.alignment = .trailing
        valueCluster.spacing = 0

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        // O7: правый коридор героя = коридор строк. У строки справа флаг (appsFlagW) + spacing(8) ПОСЛЕ
        // числа; во heroTopRow флагов нет — компенсируем пустым pad той же ширины, чтобы правая кромка
        // ЧИСЛА героя (valNum) встала ровно над правой кромкой val строк (десятичная точка — в колонку).
        let valPad = NSView()
        valPad.translatesAutoresizingMaskIntoConstraints = false
        valPad.widthAnchor.constraint(equalToConstant: appsFlagW).isActive = true

        let topRow = NSStackView(views: [iconView, nameCol, spacer, valueCluster, valPad])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 8

        // полноширинный спарклайн истории (Ж4: тяжелее линия — вес совпадает с тонкой строкой на глаз)
        let spark = MiniSpark()
        spark.heavy = true
        spark.translatesAutoresizingMaskIntoConstraints = false
        spark.heightAnchor.constraint(equalToConstant: 16).isActive = true   // Ж4: 18→16, ближе к строке (14)
        wrapper.spark = spark

        // кластер флагов-назначений (до 3) + тултип имени страны через GeoIP.name
        let flagHost = NSView()
        flagHost.translatesAutoresizingMaskIntoConstraints = false
        flagHost.heightAnchor.constraint(equalToConstant: 14).isActive = true
        wrapper.flagHost = flagHost

        let sparkRow = NSStackView(views: [spark, flagHost])
        sparkRow.orientation = .horizontal
        sparkRow.alignment = .centerY
        sparkRow.spacing = 8
        spark.setContentHuggingPriority(.init(1), for: .horizontal)

        let col = NSStackView(views: [topRow, sparkRow])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 6
        // O7: инсеты героя = инсеты строк (8/8) — левые края иконок и правый внутренний коридор совпадут.
        col.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        col.translatesAutoresizingMaskIntoConstraints = false
        topRow.widthAnchor.constraint(equalTo: col.widthAnchor, constant: -16).isActive = true
        sparkRow.widthAnchor.constraint(equalTo: col.widthAnchor, constant: -16).isActive = true

        wrapper.addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: wrapper.topAnchor),
            col.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            col.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            col.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        ])
    }

    /// Наполнить карточку данными снимка — НА МЕСТЕ (roll-up значения, анимация бара, спарклайн, флаги).
    private func configureCard(_ card: DossierRowView, a: AppEnergy, fraction: Double, isHero: Bool, animateValue: Bool) {
        let resolved = Connections.resolveByName(a.name)
        // спарклайн истории impact. Ж4: у героя accent-линия на accent-фоне теряла контраст — берём
        // accentBright, чтобы форма тренда читалась на тинте героя.
        let sparkTint = isHero ? Design.Color.accentBright(isDark) : Design.Color.accent(isDark)
        card.spark?.setHistory(AppSession.history(a.name), tint: sparkTint)

        // значение (roll-up / кросс-фейд при изменении). O11: направление push зависит от роста/падения —
        // растущее число въезжает снизу, падающее — сверху (иначе падение «въезжало сверху» неверно).
        let newVal = appValueText(a)
        if let val = card.valLabel {
            if val.stringValue != newVal {
                if animateValue && !Motion.reduced && !val.stringValue.isEmpty {
                    let t = CATransition()
                    t.type = .push
                    t.subtype = (leadingNumber(newVal) > leadingNumber(val.stringValue)) ? .fromBottom : .fromTop
                    t.duration = Design.Motion.durBase   // O9: одна длительность с баром (обе кодируют impact)
                    t.timingFunction = Design.Motion.easeStandard
                    val.layer?.add(t, forKey: "rollup")
                }
                val.stringValue = newVal
            }
        }

        // бар: анимируем ширину (не скачком). O9: та же длительность/кривая, что и roll-up — финишируют вместе.
        if let fw = card.fillWidth {
            let target = max(card.barW * CGFloat(min(max(fraction, 0), 1)), 6)
            if abs(fw.constant - target) > 0.5 {
                if animateValue && !Motion.reduced {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = Design.Motion.durBase
                        ctx.timingFunction = Design.Motion.easeStandard   // O9: раньше дефолтная линейная
                        fw.animator().constant = target
                    }
                } else { fw.constant = target }
            }
        }

        // микро-строка героя: CPU · MEM. Ж6: гоним через тот же crossfade, что и число (не голый щелчок под едущим числом).
        if isHero, let micro = card.microLine {
            var parts: [String] = []
            if let c = a.cpu { parts.append("CPU " + fmtCPU(c)) }
            if let m = a.memMB { parts.append(fmtMem(m)) }
            let newMicro = parts.joined(separator: "  ·  ")
            if micro.stringValue != newMicro {
                if animateValue && !Motion.reduced && !micro.stringValue.isEmpty {
                    let t = CATransition()
                    t.type = .fade
                    t.duration = Design.Motion.durBase
                    micro.layer?.add(t, forKey: "microfade")
                }
                micro.stringValue = newMicro
            }
            micro.isHidden = parts.isEmpty
        }

        // флаги: пересобираем flagHost ТОЛЬКО когда набор кодов реально изменился (O12) — иначе флаги
        // мигали каждый тик под плавно едущим числом/баром. Diff по последнему набору на карте.
        if let host = card.flagHost {
            let codes = AppSession.countryCodes(nameLower: a.name.lowercased())
            if lastFlagCodes[a.name] != codes {
                lastFlagCodes[a.name] = codes
                host.subviews.forEach { $0.removeFromSuperview() }
                if isHero {
                    populateHeroFlags(host, name: a.name)
                } else {
                    let flag = makeFlagView(for: a.name, resolvedName: resolved.name, width: appsFlagW)
                    host.addSubview(flag)
                    NSLayoutConstraint.activate([
                        flag.centerXAnchor.constraint(equalTo: host.centerXAnchor),
                        flag.centerYAnchor.constraint(equalTo: host.centerYAnchor),
                    ])
                }
            }
        }

        // O14: у героя нет ховер-раскрытия и его setAccessibilityLabel мёртв (override возвращает a11yText),
        // поэтому «топ-приложение» несём префиксом самого a11yText, чтобы VoiceOver его объявил.
        // Ж12: потоки/страны иначе недостижимы без мыши (ховер-раскрытие) — сворачиваем в a11yText.
        var tail = ""
        if let t = a.threads { tail += ", " + String(format: L("%d потоков"), t) }
        let acodes = AppSession.countryCodes(nameLower: a.name.lowercased())
        if !acodes.isEmpty { tail += ", " + acodes.map { GeoIP.name($0) }.joined(separator: ", ") }
        let base = String(format: L("%@, расход %@, CPU %@, память %@, открыть досье"),
                          resolved.name, fmtImpact(a.impact),
                          a.cpu.map(fmtCPU) ?? "—", a.memMB.map(fmtMem) ?? "—") + tail
        card.a11yText = isHero ? (L("Топ-приложение по расходу") + ", " + base) : base
    }

    // O12: последний набор ISO-кодов страны на приложение — diff, чтобы не пересобирать флаги каждый тик.
    private var lastFlagCodes: [String: [String]] = [:]

    /// Ведущее число строки значения (для направления roll-up O11): "12.3" → 12.3, "45%" → 45, "—" → 0.
    private func leadingNumber(_ s: String) -> Double {
        var out = ""
        for ch in s {
            if ch.isNumber || ch == "." || (out.isEmpty && ch == "-") { out.append(ch) }
            else if !out.isEmpty { break }
        }
        return Double(out) ?? 0
    }

    /// Кластер флагов-назначений героя: до 3 флагов (тултип = имя страны через GeoIP.name) + «+N».
    private func populateHeroFlags(_ host: NSView, name: String) {
        let codes = AppSession.countryCodes(nameLower: name.lowercased())
        guard !codes.isEmpty else { return }
        let shown = Array(codes.prefix(3))
        var chips: [NSView] = []
        for code in shown {
            let f = NSTextField(labelWithString: GeoIP.flag(code))
            f.font = Design.Font.caption
            f.toolTip = GeoIP.name(code)          // флаг НАЗЫВАЕТ страну
            chips.append(f)
        }
        if codes.count > shown.count {
            let extra = NSTextField(labelWithString: "+\(codes.count - shown.count)")
            extra.font = Design.Font.microStat
            extra.textColor = .secondaryLabelColor
            // свёртка +N — тултип = имена свёрнутых стран через GeoIP.name
            extra.toolTip = codes.dropFirst(shown.count).map { GeoIP.name($0) }.joined(separator: ", ")
            chips.append(extra)
        }
        let stack = NSStackView(views: chips)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor),
        ])
    }

    /// ТУЛТИПЫ на усекаемое — ставятся ПОСЛЕ layout (ширина полей известна только тогда).
    private func applyAppRowTips() {
        for (_, card) in appRows {
            guard let nameField = findField(in: card, id: "rowName") else { continue }
            applyTruncTip(nameField, full: nameField.stringValue, avail: nameField.bounds.width)
            if let val = card.valLabel {
                applyTruncTip(val, full: val.stringValue, avail: val.bounds.width)
            }
            // O14: микро-строка героя (CPU · MEM) усекается byTruncatingTail, а герой не раскрывается —
            // это единственная дыра честности над ним. Тултип на усечение закрывает её.
            if let micro = card.microLine, !micro.isHidden {
                applyTruncTip(micro, full: micro.stringValue, avail: micro.bounds.width)
            }
        }
    }

    // MARK: - ДОСЬЕ ПРИЛОЖЕНИЯ (Batch D) — задняя грань плитки «Приложения»

    /// Открытие досье: фиксируем имя (инвариант перерендера), чистим кэш соединений, флипаем на
    /// заднюю грань, запускаем фоновой сбор conns. Грань рисуется в renderDossierFace через rebuild.
    func openDossier(for name: String) {
        guard openDossierName != name else { return }
        openDossierName = name
        dossierConns = []; dossierCountries = []; dossierHasLAN = false; dossierAppPath = nil
        dossierBusy = false        // новый open всегда стартует свою загрузку; прежний snapshot в полёте безвреден (отсечётся name-guard'ом в completion) — иначе busy мог застрять и грань вечно «сбор соединений…»
        flipApps(toDossier: true) { [weak self] in self?.renderAppRows(self?.appsLast ?? []) }
        loadDossierConns(name)
    }

    /// Назад-шеврон: сбрасываем состояние, флипаем обратно к лидерборду, VoiceOver-фокус на строку.
    @objc func closeDossier() {
        guard let was = openDossierName else { return }
        openDossierName = nil
        flipApps(toDossier: false) { [weak self] in
            guard let self = self else { return }
            self.renderAppRows(self.appsLast)
            // VoiceOver: вернуть фокус на исходную строку (по сырому имени), иначе на стек.
            let target: NSView? = self.appsStack.arrangedSubviews
                .compactMap { $0 as? DossierRowView }.first { $0.appName == was } ?? self.appsStack
            NSAccessibility.post(element: target as Any, notification: .focusedUIElementChanged)
        }
    }

    /// Рисует ЛИЦО досье в appsStack (зовётся из renderAppRows-диспетчера на каждый снимок/колбэк).
    /// impact берёт из свежего снимка; выпало из топа → последний известный из appsLast → «—».
    private func renderDossierFace(_ name: String, apps: [AppEnergy]) {
        appsStack.addArrangedSubview(dossierFace(name, apps: apps))
    }

    /// Лицо досье: вертикальный стек ≤ высоты лидерборда (~155pt). Прозрачный фон (плитка стеклянная).
    /// Блоки: A шапка (back/иконка/имя/значение-РАСХОД) · B страны · C хайрлайн · D соединения · E пилюли.
    private func dossierFace(_ name: String, apps: [AppEnergy]) -> NSView {
        let resolved = Connections.resolveByName(name)
        let impact = apps.first { $0.name == name }?.impact
            ?? appsLast.first { $0.name == name }?.impact      // выпал из топа → последний известный

        let face = NSStackView()
        face.orientation = .vertical
        face.alignment = .leading
        face.spacing = 6
        face.translatesAutoresizingMaskIntoConstraints = false
        face.widthAnchor.constraint(equalToConstant: IW).isActive = true
        face.setAccessibilityElement(true)
        face.setAccessibilityLabel(String(format: L("Досье приложения %@"), resolved.name))

        // --- A. Шапка ---
        let back = NSButton()
        back.isBordered = false
        back.bezelStyle = .regularSquare
        back.imagePosition = .imageOnly
        let backCfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        back.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: L("Назад к списку приложений"))?
            .withSymbolConfiguration(backCfg)
        back.contentTintColor = Design.Color.accent(isDark)
        back.target = self
        back.action = #selector(closeDossier)
        back.toolTip = L("Назад к списку приложений")
        back.setAccessibilityLabel(L("Назад к списку приложений"))
        back.translatesAutoresizingMaskIntoConstraints = false
        back.widthAnchor.constraint(equalToConstant: 22).isActive = true
        back.heightAnchor.constraint(equalToConstant: 22).isActive = true
        dossierBackButton = back

        let iconView: NSView
        if let img = resolved.icon {
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            iv.layer?.cornerRadius = Design.Radius.appIcon   // Ж1: единый токен скругления app-иконки
            iv.layer?.cornerCurve = .continuous
            iv.layer?.masksToBounds = true
            iv.image = img
            iconView = iv
        } else {
            iconView = systemProcessGlyph(name)
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 20).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let nameLabel = NSTextField(labelWithString: resolved.name)
        nameLabel.font = Design.Font.headline
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        // тултип имени досье — ТОЛЬКО если усечено (после layout, ширина известна лишь тогда)
        DispatchQueue.main.async { [weak self, weak nameLabel] in
            guard let self = self, let nameLabel = nameLabel else { return }
            self.applyTruncTip(nameLabel, full: resolved.name, avail: nameLabel.bounds.width)
        }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        // valueCluster: число РАСХОД + капс-эйброу. ЖЁСТКО «РАСХОД», НИКОГДА «Вт».
        // Ж9: приложение открыто, но в покое (impact ~0) → «—», а не «0.0» под капсом РАСХОД.
        let valNum = NSTextField(labelWithString: (impact.map { $0 < 0.05 ? "—" : String(format: "%.1f", $0) }) ?? "—")
        valNum.font = Design.Font.numericLarge
        valNum.textColor = .labelColor
        valNum.alignment = .right
        let valCap = NSTextField(labelWithString: "")
        valCap.font = Design.Font.microStat
        valCap.textColor = .tertiaryLabelColor
        valCap.alignment = .right
        capsText(valCap, L("Расход"))
        let valueCluster = NSStackView(views: [valNum, valCap])
        valueCluster.orientation = .vertical
        valueCluster.alignment = .trailing
        valueCluster.spacing = 0
        valueCluster.translatesAutoresizingMaskIntoConstraints = false

        let headerRow = NSStackView(views: [back, iconView, nameLabel, spacer, valueCluster])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 8)
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        headerRow.widthAnchor.constraint(equalToConstant: IW).isActive = true
        face.addArrangedSubview(headerRow)

        // --- B. Кластер стран (дословная калька connRow) ---
        let geoRow = NSStackView()
        geoRow.orientation = .horizontal
        geoRow.alignment = .centerY
        geoRow.spacing = 4
        if dossierBusy && dossierConns.isEmpty && dossierCountries.isEmpty && !dossierHasLAN {
            let l = NSTextField(labelWithString: L("сбор соединений…"))
            l.font = Design.Font.caption; l.textColor = .tertiaryLabelColor
            geoRow.addArrangedSubview(l)
        } else if dossierCountries.isEmpty && !dossierHasLAN {
            let l = NSTextField(labelWithString: L("Нет активных соединений"))
            l.font = Design.Font.caption; l.textColor = .tertiaryLabelColor
            geoRow.addArrangedSubview(l)
        } else {
            let shown = dossierCountries.prefix(3)
            for c in shown {
                let l = NSTextField(labelWithString: c)   // "🇺🇸 США" — флаг уже в метке
                l.font = Design.Font.callout; l.lineBreakMode = .byTruncatingTail
                geoRow.addArrangedSubview(l)
            }
            if dossierCountries.count > shown.count {
                let extra = NSTextField(labelWithString: "+\(dossierCountries.count - shown.count)")
                extra.font = Design.Font.callout; extra.textColor = .secondaryLabelColor
                // свёртка +N: тултип = имена свёрнутых стран (метки уже содержат имя после флага)
                extra.toolTip = dossierCountries.dropFirst(shown.count).joined(separator: ", ")
                geoRow.addArrangedSubview(extra)
            }
            if dossierHasLAN && dossierCountries.count < 3 {
                let globe = NSImageView()
                globe.image = NSImage(systemSymbolName: "globe", accessibilityDescription: L("Локальная сеть"))
                globe.contentTintColor = .secondaryLabelColor
                globe.translatesAutoresizingMaskIntoConstraints = false
                globe.widthAnchor.constraint(equalToConstant: 13).isActive = true
                globe.heightAnchor.constraint(equalToConstant: 13).isActive = true
                let lan = NSTextField(labelWithString: L("Локальная сеть"))
                lan.font = Design.Font.callout; lan.textColor = .secondaryLabelColor
                geoRow.addArrangedSubview(globe)
                geoRow.addArrangedSubview(lan)
            }
        }
        face.addArrangedSubview(geoRow)

        // --- C/D. Хайрлайн + список соединений (до 3) — только если conns есть ---
        if !dossierConns.isEmpty {
            let rule = NSView()
            rule.wantsLayer = true
            rule.layer?.backgroundColor = Design.Color.hairline(isDark, 0.08).cgColor
            rule.translatesAutoresizingMaskIntoConstraints = false
            rule.widthAnchor.constraint(equalToConstant: IW).isActive = true
            rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
            face.addArrangedSubview(rule)

            for c in dossierConns.prefix(3) { face.addArrangedSubview(connDetailRow(c)) }
            if dossierConns.count > 3 {
                let more = NSTextField(labelWithString: String(format: L("ещё %d"), dossierConns.count - 3))
                more.font = Design.Font.caption; more.textColor = .tertiaryLabelColor
                face.addArrangedSubview(more)
            }
        }

        // --- E. Пилюли действий (только честные) ---
        face.addArrangedSubview(dossierPills())
        return face
    }

    /// Строка одного соединения: proto-бейдж · ip:port · флаг страны-назначения (исходящее).
    private func connDetailRow(_ c: NetConn) -> NSView {
        let proto = NSTextField(labelWithString: c.proto)
        proto.font = Design.Font.microStat
        proto.textColor = .tertiaryLabelColor
        proto.alignment = .center
        proto.wantsLayer = true
        proto.drawsBackground = false
        let protoWrap = NSView()
        protoWrap.wantsLayer = true
        protoWrap.layer?.backgroundColor = Design.Color.controlFill(isDark).cgColor
        protoWrap.layer?.cornerRadius = Design.Radius.chip
        protoWrap.layer?.cornerCurve = .continuous
        protoWrap.translatesAutoresizingMaskIntoConstraints = false
        protoWrap.addSubview(proto)
        proto.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            protoWrap.widthAnchor.constraint(equalToConstant: 28),
            proto.centerXAnchor.constraint(equalTo: protoWrap.centerXAnchor),
            proto.centerYAnchor.constraint(equalTo: protoWrap.centerYAnchor),
        ])

        let dest = NSTextField(labelWithString: c.label)
        dest.font = Design.Font.numericBody
        dest.textColor = .secondaryLabelColor
        dest.lineBreakMode = .byTruncatingMiddle
        dest.setContentHuggingPriority(.init(1), for: .horizontal)
        dest.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        // тултип ip:port — ТОЛЬКО если усечено (после layout)
        DispatchQueue.main.async { [weak self, weak dest] in
            guard let self = self, let dest = dest else { return }
            self.applyTruncTip(dest, full: c.label, avail: dest.bounds.width)
        }

        let flagView: NSView
        if let geo = GeoIP.label(for: c.remoteIP) {
            let f = NSTextField(labelWithString: geo)   // "🇺🇸 США"
            f.font = Design.Font.caption
            flagView = f
        } else {
            let g = NSImageView()                       // LAN/неизвестно → глобус, не фейк-флаг
            g.image = NSImage(systemSymbolName: "globe", accessibilityDescription: L("Локальная сеть"))
            g.contentTintColor = .tertiaryLabelColor
            g.translatesAutoresizingMaskIntoConstraints = false
            g.widthAnchor.constraint(equalToConstant: 11).isActive = true
            g.heightAnchor.constraint(equalToConstant: 11).isActive = true
            flagView = g
        }
        flagView.translatesAutoresizingMaskIntoConstraints = false
        flagView.widthAnchor.constraint(equalToConstant: appsFlagW).isActive = true

        let row = NSStackView(views: [protoWrap, dest, flagView])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: IW).isActive = true
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel("\(c.proto) \(c.label) \(GeoIP.label(for: c.remoteIP) ?? "")")
        return row
    }

    /// Пилюли действий досье: «Показать в Finder» (Free) и «Заблокировать входящие» (Pro/.netBlock).
    /// Демон/бинарь/несматченный (appPath==nil) → обе disabled с честным tooltip. Без блока исходящих.
    private func dossierPills() -> NSView {
        let path = dossierAppPath

        let finder = GlassButton(title: L("Показать в Finder"), symbol: "folder", cornerRadius: Design.Radius.chip)
        finder.onClick = { [weak self] in self?.revealDossierInFinder() }
        if path == nil { finder.isEnabled = false; finder.toolTip = L("Путь к приложению недоступен.") }

        let block = GlassButton(title: L("Заблокировать входящие"), symbol: "hand.raised.fill", accentText: true, cornerRadius: Design.Radius.chip)
        block.onClick = { [weak self] in self?.blockDossierIncoming() }
        if path == nil {
            block.isEnabled = false
            block.toolTip = L("Для системных процессов и демонов точечный блок через фаервол недоступен.")
        }

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [finder, block, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: IW).isActive = true
        return row
    }

    /// Free-действие: показать .app в Finder. Всегда честно — только если путь известен.
    @objc private func revealDossierInFinder() {
        guard let path = dossierAppPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Pro-действие (.netBlock): блок ВХОДЯЩИХ через системный фаервол. Копирайт дословно из
    /// Settings.blockAppIncoming. НЕ блокирует исходящий (для этого нужен сетевой фильтр — честно).
    @objc private func blockDossierIncoming() {
        guard let path = dossierAppPath else { return }
        guard SettingsCoordinator.requirePro(.netBlock) else { return }   // канон из поповера (см. requirePro на makeCustomButton)
        let confirm = NSAlert()
        confirm.messageText = L("Заблокировать входящие?")
        confirm.informativeText = L("Системный фаервол запретит входящие соединения этому приложению (нужен пароль администратора). Это НЕ блокирует исходящий трафик — для этого нужен сетевой фильтр.")
        confirm.addButton(withTitle: L("Заблокировать")); confirm.addButton(withTitle: L("Отмена"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        let ok = Firewall.block(path)
        let done = NSAlert()
        done.messageText = ok ? L("Готово") : L("Не удалось")
        done.informativeText = ok ? L("Входящие для приложения заблокированы. Управление — в разделе «Фаервол».") : L("Не удалось применить правило фаервола.")
        done.runModal()
    }

    /// Фоновой сбор conns/стран для досье — СВОЙ snapshot, НЕ трогает refreshAppFlags. Корреляция
    /// по name.lowercased(). Guard openDossierName == name отбрасывает гонку «открыл A, доехал B».
    private func loadDossierConns(_ name: String) {
        guard !dossierBusy else { return }
        dossierBusy = true
        let needle = name.lowercased()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // ФОН: только lsof-сырьё (POSIX). Резолв имён (для матча по name) — на main (B1).
            let raw = Connections.rawSnapshot()
            DispatchQueue.main.async {
                guard let self = self, self.openDossierName == name else { self?.dossierBusy = false; return }
                // MAIN: AppKit-резолв, матч по name идентичен прежнему, гео (набор = 1 приложение — тривиально).
                let match = Connections.resolveOnMain(raw).first { $0.name.lowercased() == needle }
                let conns = match?.conns ?? []
                var seen = Set<String>(); var countries: [String] = []; var lan = false
                for c in conns {
                    if let g = GeoIP.label(for: c.remoteIP) { if seen.insert(g).inserted { countries.append(g) } }
                    else { lan = true }
                }
                self.dossierBusy = false
                self.dossierConns = conns
                self.dossierCountries = countries
                self.dossierHasLAN = lan
                self.dossierAppPath = match?.appPath
                self.renderAppRows(self.appsLast)        // данные доехали → перерисовать грань НА МЕСТЕ
            }
        }
    }

    /// Флип плитки «Приложения» на заднюю грань и обратно. Безопасный приём (без anchorPoint/
    /// doubleSided/полного оверта): контент-свап под кросс-фейдом + лёгкий Y-наклон 0.18рад.
    /// Motion.reduced → мгновенный rebuild + opacity 0→1 (кросс-фейд, без вращения). Высота инвариантна.
    private func flipApps(toDossier: Bool, rebuild: @escaping () -> Void) {
        guard !Motion.reduced, let layer = appsFlipHost?.layer else {
            rebuild()
            if let l = appsFlipHost?.layer {
                l.removeAllAnimations(); l.opacity = 1
                let op = CABasicAnimation(keyPath: "opacity")
                op.fromValue = 0; op.toValue = 1; op.duration = Design.Motion.durBase
                l.add(op, forKey: "dossierFade")
            }
            if toDossier { focusDossierBack() }
            return
        }
        let dir: CGFloat = toDossier ? 1 : -1
        let dur = Design.Motion.durFast            // 0.18 на фазу, Σ 0.36
        var persp = CATransform3DIdentity          // лёгкая перспектива — наклон читается объёмно
        persp.m34 = -1.0 / 600
        layer.sublayerTransform = persp
        layer.removeAllAnimations()

        // фаза 1: 0 → dir*0.18, opacity 1→0
        let rot1 = CABasicAnimation(keyPath: "transform.rotation.y")
        rot1.fromValue = 0; rot1.toValue = dir * 0.18
        rot1.timingFunction = Design.Motion.easeOut
        let op1 = CABasicAnimation(keyPath: "opacity")
        op1.fromValue = 1; op1.toValue = 0
        op1.timingFunction = Design.Motion.easeOut
        let g1 = CAAnimationGroup()
        g1.animations = [rot1, op1]; g1.duration = dur
        g1.fillMode = .forwards; g1.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self = self, let layer = self.appsFlipHost?.layer else { return }
            layer.removeAnimation(forKey: "dossierFlip1")   // ремень: прерванный флип не оставляет forwards-фил
            rebuild()
            // мгновенно перекинуть на зеркальный угол (грань уже подменена), фаза 2 вернёт к 0
            layer.transform = CATransform3DMakeRotation(-dir * 0.18, 0, 1, 0)
            layer.opacity = 0
            let rot2 = CABasicAnimation(keyPath: "transform.rotation.y")
            rot2.fromValue = -dir * 0.18; rot2.toValue = 0
            rot2.timingFunction = Design.Motion.easeIn
            let op2 = CABasicAnimation(keyPath: "opacity")
            op2.fromValue = 0; op2.toValue = 1
            op2.timingFunction = Design.Motion.easeIn
            let g2 = CAAnimationGroup()
            g2.animations = [rot2, op2]; g2.duration = dur
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                guard let layer = self?.appsFlipHost?.layer else { return }
                // КРИТИЧЕСКИЙ ФИКС «пустой экран после клика по приложению»: g1 висела с
                // fillMode=.forwards + isRemovedOnCompletion=false; когда g2 само-удалялась,
                // g1 снова клампила presentation-opacity слоя в 0 НАВСЕГДА (model=1, поэтому
                // код «не видел» проблему). Снимаем фил явно — как "close" в playOpenAnimation.
                layer.removeAnimation(forKey: "dossierFlip1")
                layer.transform = CATransform3DIdentity
                layer.sublayerTransform = CATransform3DIdentity   // Ж7: сбросить остаточную m34-перспективу (не копить грязь состояния)
                layer.opacity = 1
                if toDossier { self?.focusDossierBack() }
            }
            layer.add(g2, forKey: "dossierFlip2")
            layer.transform = CATransform3DIdentity
            layer.opacity = 1
            CATransaction.commit()
        }
        layer.add(g1, forKey: "dossierFlip1")
        CATransaction.commit()
    }

    /// VoiceOver: фокус на назад-кнопку при открытии досье.
    private func focusDossierBack() {
        NSAccessibility.post(element: dossierBackButton as Any, notification: .focusedUIElementChanged)
    }

    /// Нейтральный значок системного процесса/демона (нет .app-иконки): спокойный заполненный
    /// SF-глиф на стеклянной плитке (controlFill, tertiary tint) вместо пустого пунктирного контура.
    /// Читается как «системный процесс», а не «сломанная иконка». Глиф подбираем по имени процесса.
    private func systemProcessGlyph(_ proc: String) -> NSView {
        let tile = NSView()
        tile.wantsLayer = true
        tile.layer?.backgroundColor = Design.Color.controlFill(isDark).cgColor
        tile.layer?.cornerRadius = Design.Radius.appIcon   // Ж1: единый токен (был хардкод 5)
        tile.layer?.cornerCurve = .continuous
        tile.translatesAutoresizingMaskIntoConstraints = false

        let glyph = NSImageView()
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        glyph.image = NSImage(systemSymbolName: systemProcessSymbol(proc), accessibilityDescription: L("Системный процесс"))?
            .withSymbolConfiguration(cfg)
        glyph.contentTintColor = .tertiaryLabelColor
        glyph.imageScaling = .scaleProportionallyDown
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        tile.toolTip = L("Системный процесс")
        return tile
    }

    /// Подбор нейтрального SF-символа по имени процесса: рендеры/оконный сервер → дисплей,
    /// сеть/конфиг → cpu, хелперы → terminal; всё прочее → шестерёнка (общий «системный»).
    private func systemProcessSymbol(_ proc: String) -> String {
        let n = proc.lowercased()
        if n.contains("window") || n.contains("display") || n.contains("render") { return "display" }
        if n.contains("helper") || n.contains("agent") { return "terminal" }
        if n.contains("config") || n.contains("network") || n.contains("net") { return "cpu" }
        return "gearshape.fill"
    }

    /// Маркер «есть соединения, но все — локальная сеть» (рисуем глоб вместо флага страны).
    private static let lanGlobe = "\u{1F310}"

    /// Освежает гео-флаги лидерборда: lsof-снимок в фоне (НЕ на main), коррелируем приложение
    /// с его соединениями по имени, берём самую частую не-LAN страну-назначение. Готово →
    /// если карта изменилась, перерисовываем строки (флаги «доедут» через кадр-другой).
    private func refreshAppFlags() {
        guard !appFlagsBusy else { return }
        appFlagsBusy = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // ФОН: lsof-сырьё (POSIX) + гео по IP (GeoIP чистый). AppKit-резолв имён — на main (B1).
            let raw = Connections.rawSnapshot()
            var codeByIP: [String: String?] = [:]
            for rp in raw { for c in rp.conns where codeByIP[c.remoteIP] == nil {
                codeByIP[c.remoteIP] = GeoIP.countryCode(for: c.remoteIP)
            } }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.appFlagsBusy = false
                // MAIN: резолвим имена/иконки (безопасно), затем считаем гео из фон-карты codeByIP.
                var map: [String: String] = [:]
                var codesByApp: [String: Set<String>] = [:]   // nameLower → все ISO-коды за снимок (для AppSession)
                var netApps: [FirstConnAlert.NetApp] = []     // приложения с внешним соединением (для first-conn алерта)
                let resolved = Connections.resolveOnMain(raw)
                let now = Date()
                for app in resolved {
                    var tally: [String: Int] = [:]     // код страны → счётчик соединений
                    var hadConn = false
                    let key = app.name.lowercased()
                    let ident = app.appPath ?? app.name           // стабильная тождественность (как в радаре/леджере)
                    var rep: (label: String, code: String?)? = nil   // представительный внешний endpoint (ip:port)
                    for c in app.conns {
                        hadConn = true
                        let code = codeByIP[c.remoteIP] ?? nil
                        AppSession.noteConnection(appId: ident, app: app.name, endpoint: c.label, code: code, now: now)
                        if let code = code {
                            tally[code, default: 0] += 1
                            codesByApp[key, default: []].insert(code)
                        }
                        // Для first-conn: предпочитаем публичный endpoint (есть страна), иначе первый маршрутизируемый.
                        if FirstConnAlert.isRoutable(c.remoteIP), rep == nil || (rep?.code == nil && code != nil) {
                            rep = (c.label, code)
                        }
                    }
                    if let rep = rep {
                        netApps.append(FirstConnAlert.NetApp(id: ident, name: app.name, endpoint: rep.label, code: rep.code))
                    }
                    if let top = tally.max(by: { $0.value < $1.value })?.key {
                        map[key] = GeoIP.flag(top)              // самая частая страна-назначение
                    } else if hadConn {
                        map[key] = PopoverController.lanGlobe   // соединения есть, но только LAN/неизвестно
                    }
                }
                // Сессионное множество стран-назначений — коммитим на main (AppSession не thread-safe).
                for (key, codes) in codesByApp { AppSession.addCountries(key, codes: codes) }
                // Радар 2.0: заметить новое приложение в сети (наблюдение). Дешёвый выход, если фича выключена.
                FirstConnAlert.shared.consider(netApps, now: now)
                // История числа соединений за сессию (спарклайн радара) — толкаем ВСЕГДА, даже с закрытым
                // поповером: тренд копится непрерывно. total = уникальные ip:port по всем приложениям.
                AppSession.pushConnTotal(resolved.reduce(0) { $0 + $1.conns.count })
                // Радар «Приватности» — из ТОГО ЖЕ снимка (один lsof на оба). Рендерим только когда
                // поповер на экране (view.window != nil) — вне вкладки слои спят (см. viewDidMoveToWindow).
                if self.view.window != nil { self.privacyView.update(apps: resolved, codeByIP: codeByIP); self.mediaChipRefresh?() }
                guard map != self.appCountryFlags else { return }   // без изменений — не перерисовываем
                self.appCountryFlags = map
                self.renderAppRows(self.appsLast)   // флаги доехали → перерисовать строки из кэша
            }
        }
    }

    private func refreshApps() {
        // Берём расширенный сырой пул: после объединения helper/web-content процессов
        // всё равно остаётся полноценный топ из шести самостоятельных приложений.
        PowerInfo.topApps(limit: 18) { [weak self] in self?.updateApps($0) }
    }

    @objc private func openSettings() {
        view.window?.close()                      // закрыть поповер
        SettingsCoordinator.open()
    }

    /// Эффективный потолок заряда: «Парусный» → верхний порог; «Лимит» → chargeLimit (<100).
    /// nil — лимита нет. Кольцо получает тик-метку, чип показывает «Лимит N%» (иначе скрыт).
    private func applyChargeLimit() {
        guard ChargeControl.systemControlReady else {
            ring.setLimit(nil)
            return
        }
        let limit: Int? = SettingsStore.chargeMode == "sail"
            ? SettingsStore.sailUpper
            : (SettingsStore.chargeLimit < 100 ? SettingsStore.chargeLimit : nil)
        ring.setLimit(limit)                            // тик-метка лимита на кольце; потолок теперь несёт дорожка заряда
    }

    @objc private func showInstall() {
        let state = HelperInstall.installState(.telemetry)
        if state == .installed || state == .starting { return }
        let alert = NSAlert()
        switch state {
        case .notInstalled:
            alert.messageText = L("Подключить детализацию мощности")
            alert.informativeText = L("Kelvin установит небольшой системный модуль для CPU/GPU/DRAM. Пароль администратора понадобится один раз.")
            alert.addButton(withTitle: L("Подключить"))
        case .updateAvailable:
            alert.messageText = L("Обновить модуль детализации")
            alert.informativeText = L("Новая версия устанавливается только по вашему выбору.")
            alert.addButton(withTitle: L("Обновить"))
        case .repairNeeded:
            alert.messageText = L("Восстановить модуль детализации")
            alert.informativeText = L("Установка неполная. Kelvin восстановит только модуль метрик.")
            alert.addButton(withTitle: L("Восстановить"))
        case .starting, .installed:
            return
        }
        alert.addButton(withTitle: L("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let r = HelperInstall.runPrivileged("install-helper.sh", prompt: L("Kelvin устанавливает хелпер CPU/GPU/DRAM"))
        guard HelperInstall.presentFailureIfNeeded(r, title: L("Не удалось установить хелпер")) else { return }
        compStatus.isHidden = false
        compStatus.stringValue = L("Системный модуль подключён — ждём первый замер.")
        installBtn.isHidden = true
    }
}
// Отладочный дамп: проверяет, что данные реально доходят до строк (без GUI).
if ProcessInfo.processInfo.environment["BM_DUMP"] != nil {
    if let b = BatteryReader.read() {
        print(String(format: "Заголовок:  %@ %d%%  /  %@", b.charging ? "🔌" : "🔋", b.charge, b.charging ? "зарядка" : "разряд"))
        print(String(format: "Расход:     %.1f Вт", b.watts))
        print(String(format: "Здоровье=%.0f%%  Циклы=%d  Темп=%.1f°C  Напр=%.2fВ  Ёмкость=%.0f/%.0f Вт·ч",
                     b.health, b.cycleCount, b.temperature, b.voltage, b.capacityWh, b.maxWh))
    }
    let c = PowerInfo.components()
    print(String(format: "Компоненты: fresh=%@ CPU=%@ GPU=%@ DRAM=%@ Package=%@ (возраст %.1fс)",
                 c.fresh ? "да" : "нет",
                 c.cpu.map { String(format: "%.2fВт", $0) } ?? "—",
                 c.gpu.map { String(format: "%.2fВт", $0) } ?? "—",
                 c.dram.map { String(format: "%.2fВт", $0) } ?? "—",
                 c.package.map { String(format: "%.2fВт", $0) } ?? "—",
                 c.ageSeconds))
    print("Топ приложений по энергии:")
    for a in PowerInfo.topAppsSync() { print(String(format: "   %-22@  %.1f", a.name as NSString, a.impact)) }

    let e = EnergyModel.snapshot()
    print("\n=== SMC энергопоток (hasSMC=\(e.hasSMC)) ===")
    print(String(format: "Батарея: %.2f В × %.2f А = %.1f Вт  (%@)", e.battVolts, e.battAmps, e.battWatts, e.charging ? "заряд" : "разряд"))
    print(String(format: "Адаптер: %.2f В × %.2f А = %.1f Вт  (%@)", e.adapterVolts, e.adapterAmps, e.adapterWatts, e.plugged ? "подключён" : "отключён"))
    print(String(format: "Система потребляет: %.1f Вт", e.systemWatts))
    print("Потребители (ток):")
    for r in e.rails { print(String(format: "   %-8@ %.3f А%@", r.name as NSString, r.amps, r.watts.map { String(format: "  (%.2f Вт)", $0) } ?? "")) }
    print(String(format: "CPU %@°C  GPU %@°C  Вентиляторы: %@ об/мин",
                 e.cpuTemp.map { String(format: "%.0f", $0) } ?? "—",
                 e.gpuTemp.map { String(format: "%.0f", $0) } ?? "—",
                 e.fans.map { String(format: "%.0f", $0) }.joined(separator: "/")))
    exit(0)
}

// Зонд SMC: ищем прямые power-ключи (ватты) для системы/адаптера/батареи.
if ProcessInfo.processInfo.environment["BM_SMCPROBE"] != nil {
    let smc = SMC()
    let keys = ["PSTR","PDTR","PPBR","PCTR","PGTR","PHPC","PC0C","PCPC","PCPG",
                "PG0R","PD0R","PZ0R","PDIN","Pp0R","PM0R","PB0R","PBLC","PSVR","PO0R",
                "B0AP","PC0R","PCPT","PCPL","PCTL","PMTR","PpAR",
                "VD0R","ID0R","VD0r","ID0r","VP0R","IP0R","AC-W","ACFP","ACID","ACIC","D0IR","D0VR","D0VX"]
    print("ключ  тип  размер  значение")
    for k in keys {
        if let p = smc.probe(k) {
            print(String(format: "%-5@ %-5@ %d  %@", k as NSString, p.type as NSString, p.size,
                         p.value.map { String(format: "%.3f", $0) } ?? "—(тип не декодир.)"))
        }
    }
    exit(0)
}

// Зонд дисплея: перечислить доступные разрешения (read-only, ничего не меняет).
if ProcessInfo.processInfo.environment["BM_DISPLAYS"] != nil {
    if let c = ScreenResolution.current() { print("текущее: \(c.w) × \(c.h)") }
    print("доступные режимы:")
    for m in ScreenResolution.available() {
        print("  \(m.w) × \(m.h)\(m.hidpi ? "  (HiDPI)" : "")   [pixel \(m.cg.pixelWidth)×\(m.cg.pixelHeight)]")
    }
    exit(0)
}

// Зонд загрузки CPU/RAM (read-only).
if ProcessInfo.processInfo.environment["BM_USAGE"] != nil {
    let u = SystemUsage.shared
    _ = u.cpu()                                   // первый замер задаёт базу
    usleep(400_000)
    let c = u.cpu(), r = u.ram()
    print(String(format: "CPU: %.0f%%   RAM: %.0f%%", c * 100, r * 100))
    print(String(format: "RAM физически: %.1f ГБ", Double(ProcessInfo.processInfo.physicalMemory) / 1e9))
    exit(0)
}

// Крипто-самотест привязки лицензии (BM_LICTEST): проверяет HMAC-подпись и привязку к железу БЕЗ Keychain
// (значит без модалки SecurityAgent на ad-hoc сборке). Подделка сообщения/тега обязана проваливаться.
if ProcessInfo.processInfo.environment["BM_LICTEST"] != nil {
    let hw = MachineID.hardwareUUID
    let msg = "KEY-1234|inst-abcd|1720000000.0"
    let t = MachineID.tag(msg)
    let good = MachineID.verify(msg, tag: t)
    let badMsg = MachineID.verify(msg + "x", tag: t)                                   // подделан текст → должно быть false
    let badTag = MachineID.verify(msg, tag: String(t.dropLast()) + (t.hasSuffix("0") ? "1" : "0"))  // подделан тег → false
    let pass = good && !badMsg && !badTag && !hw.isEmpty
    print("LICTEST hwUUID=\(hw.isEmpty ? "EMPTY" : "present") tagLen=\(t.count) good=\(good) badMsg=\(badMsg) badTag=\(badTag) => \(pass ? "PASS" : "FAIL")")
    fflush(stdout)
    exit(pass ? 0 : 1)
}

// Диагностика авто-переключения раскладки (BM_LANGTEST): доступ + режим + прогон детектора.
if ProcessInfo.processInfo.environment["BM_LANGTEST"] != nil {
    print("AXIsProcessTrusted = \(AXIsProcessTrusted())")
    print("langMode(defaults) = \(SettingsStore.langMode)")
    print("snippetsEnabled=\(SettingsStore.snippetsEnabled) spellFix=\(SettingsStore.spellFixEnabled) isPro=\(Licensing.shared.isPro)")
    let samples = ["ghbdtn", "нуддщ", "rjnbr", "ghtdtn", "vfvf", "ntcn", "qwerty", "привет"]
    for w in samples {
        let conv = LangDetect.shouldConvert(w)
        let flip = LayoutMap.flip(word: w)
        print("  \(w.padding(toLength: 10, withPad: " ", startingAt: 0)) shouldConvert=\(conv)  flip=\(flip)")
    }
    fflush(stdout)
    exit(0)
}

// Галерея фирменных status item состояний — быстрый визуальный regression test.
if let statusPath = ProcessInfo.processInfo.environment["BM_STATUS_SNAP"] {
    let statusApp = NSApplication.shared
    statusApp.setActivationPolicy(.accessory)
    AppDelegate().renderStatusIconSnapshot(to: statusPath)
    print("STATUS_SNAP_DONE -> \(statusPath)")
    fflush(stdout)
    exit(0)
}

// Снапшот-рендер поповера (BM_SNAP=<dir>): офскрин PNG каждой вкладки, БЕЗ окна/Screen-Recording-TCC.
// Идёт ДО single-instance guard (иначе установленная копия владельца выкинула бы нас) и до app.run().
if let snapDir = ProcessInfo.processInfo.environment["BM_SNAP"] {
    let snapApp = NSApplication.shared
    snapApp.setActivationPolicy(.accessory)
    let light = ProcessInfo.processInfo.environment["BM_LIGHT"] != nil
    // Раскладка снапшота (in-memory, НЕ трогаем UserDefaults владельца):
    //  • BM_SNAP_MIN → минимум (battery+toggles+flow): тест «растягивается+пусто».
    //  • BM_SNAP_ALL → ВСЕ модули: тест, что каждый рендерится (вкл. опц. консоль/диск/BT).
    //  • по умолчанию → ДЕФОЛТ (defaultOn) = что реально видит владелец (макет-композиция, без большого блока).
    if ProcessInfo.processInfo.environment["BM_SNAP_MIN"] != nil {
        PopoverController.snapshotLayout = [PopoverItem(id: "battery", on: true),
                                            PopoverItem(id: "toggles", on: true),
                                            PopoverItem(id: "flow", on: true)]
    } else if ProcessInfo.processInfo.environment["BM_SNAP_ALL"] != nil {
        PopoverController.snapshotLayout = PopoverModules.all.map { PopoverItem(id: $0.id, on: true) }
    } else {
        PopoverController.snapshotLayout = PopoverModules.all.map { PopoverItem(id: $0.id, on: PopoverModules.defaultOn.contains($0.id)) }
    }
    let snapCtl = PopoverController()
    let shots = snapCtl.renderSnapshots(to: snapDir, light: light)
    // окно Настроек — все секции (офскрин, без показа). Поповер-PNG уже на диске, даже если тут упадёт.
    let sset = KelvinSettingsWindowController.shared.renderSectionsSnapshot(to: snapDir, light: light, prefix: "S")
    OnboardingWindowController.shared.renderSnapshot(to: snapDir, light: light)   // стартовое окно разрешений
    CorrectionChoiceHUD.shared.renderSnapshot(to: snapDir, light: light)
    // PDF-отчёт «здоровье Mac» — визуальная проверка самого документа (из живой истории).
    let rbatt = BatteryReader.read()
    let rhs = History.shared.series(.health, since: Int64(Date().timeIntervalSince1970) - Int64(30 * 86_400))
    let rins = BatteryHealth.analyze(battery: rbatt, healthSeries: rhs)
    let rpdf = Report.healthReportPDF(period: 30 * 86_400, battery: rbatt, insight: rins)
    try? rpdf.write(to: URL(fileURLWithPath: snapDir + "/report.pdf"))
    print("SNAP_DONE popover=\(shots) settings=\(sset) -> \(snapDir)")
    fflush(stdout)
    exit(0)
}

// CLI-режим дерегистрации привилегированного GPU-сервиса (SMAppService.unregister()).
// Используется скриптом очистки (clean-old-version.sh) до pkill и удаления bundle:
// из shell доступен только launchctl bootout, а полная дерегистрация записи
// SMAppService требует вызова из приложения. Идёт ДО single-instance guard —
// работающая копия владельца не должна выгонять одноразовый сервисный запуск.
//   exit 0 — unregister выполнен (или нечего было снимать);
//   exit 3 — сервис зарегистрирован, но unregister завершился ошибкой.
if CommandLine.arguments.contains("--unregister-privileged-service") {
    if #available(macOS 13.0, *) {
        let service = SMAppService.daemon(plistName: PrivilegedServiceConfig.plistName)
        let prior = service.status
        if prior == .notRegistered || prior == .notFound {
            print("unregister: сервис не был зарегистрирован (status=\(prior.rawValue))")
            exit(0)
        }
        do {
            try service.unregister()
            print("unregister: OK (был status=\(prior.rawValue), теперь status=\(service.status.rawValue))")
            exit(0)
        } catch {
            let ns = error as NSError
            // -128 = отмена авторизации пользователем — не считаем ошибкой скрипта.
            if ns.code == -128 { print("unregister: отменено пользователем"); exit(0) }
            print("unregister: ОШИБКА \(ns.domain)/\(ns.code) — \(ns.localizedDescription)")
            exit(3)
        }
    } else {
        // macOS 11–12: SMJobBless-сервис. Дерегистрация через launchctl выполняется скриптом.
        print("unregister: legacy (macOS <13) — обрабатывается скриптом через launchctl")
        exit(0)
    }
}

// Single-instance: если копия уже запущена (автозапуск + ручной запуск) — выходим.
let bundleID = Bundle.main.bundleIdentifier ?? AppConfig.bundleID
let selfPID = ProcessInfo.processInfo.processIdentifier
let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { $0.processIdentifier != selfPID }
if !others.isEmpty { exit(0) }

Log.installCrashHandlers()
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
Log.app.notice("Kelvin запущен (pid \(selfPID, privacy: .public), версия \(appVersion, privacy: .public))")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
