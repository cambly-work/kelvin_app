import AppKit
import UniformTypeIdentifiers

/// Каталог модулей поповера (id + заголовок для настроек) и дефолтное состояние.
enum PopoverModules {
    static let all: [(id: String, title: String)] = [
        ("battery",      "Батарея (кольцо)"),
        ("toggles",      "Быстрые переключатели"),
        ("flow",         "Питание (схема)"),
        ("batteryStats", "Батарея кратко"),
        ("hardware",     "Железо"),
        ("apps",         "Приложения"),
        ("privacy",      "Приватность"),
        ("maintenance",  "Обслуживание"),
        ("history",      "История"),
        ("disk",         "Диск"),
        ("btbattery",    "Bluetooth-устройства"),
        ("audio",        "Звук (вывод)"),
        ("health",       "Здоровье"),
    ]
    // Продуктовый дефолт отвечает на четыре основные задачи: расход, приложения,
    // приватность и итоговая оценка здоровья. Диагностические экраны остаются
    // доступными в настройках поповера, но не конкурируют за первый экран.
    static let defaultOn: Set<String> = ["battery", "toggles", "audio", "flow", "apps", "privacy", "health"]
    static func title(_ id: String) -> String { L(all.first { $0.id == id }?.title ?? id) }
}
/// Одна запись раскладки поповера (модуль + видимость), сохраняется в UserDefaults.
struct PopoverItem: Codable { var id: String; var on: Bool }

/// Своя кнопка-команда в плитке переключателей.
struct CustomToggle: Codable, Equatable {
    var id: String
    var label: String
    var icon: String        // имя SF Symbol
    var command: String     // shell-команда
    var color: String       // имя цвета из SettingsStore.toggleColors
    var accent: NSColor { SettingsStore.color(named: color) }
}

/// Хранилище настроек (UserDefaults).
enum SettingsStore {
    private static let d = UserDefaults.standard

    static var autoSendCrashReports: Bool {
        get { d.bool(forKey: "CrashReports.AutoSendEnabled") }
        set { d.set(newValue, forKey: "CrashReports.AutoSendEnabled") }
    }

    /// Фирменный акцент Kelvin — единый «термокамерный» бирюзовый, тема-зависимый.
    /// Это цветовое лицо продукта: интерактив и навигация (нейтральная линия графа,
    /// бирюза зарядки, активная вкладка, дефолтные тумблеры, фокус). Семантику уровней
    /// (green/orange/red для заряда и температур) он НЕ заменяет.
    static func brandAccent(dark: Bool) -> NSColor { Design.Color.accent(dark) }   // алиас на токен (единый источник)

    /// Русское склонение по числу: (1 день, 2 дня, 5 дней).
    static func plural(_ n: Int, _ a: String, _ b: String, _ c: String) -> String {
        let n10 = n % 10, n100 = n % 100
        if n10 == 1 && n100 != 11 { return a }
        if (2...4).contains(n10) && !(12...14).contains(n100) { return b }
        return c
    }

    /// Раскладка поповера: порядок модулей + видимость. Сверяется с каталогом
    /// (новые модули добавляются в конец, исчезнувшие отбрасываются).
    static var popoverLayout: [PopoverItem] {
        get {
            let stored: [PopoverItem]
            if let data = d.data(forKey: "popover.layout"),
               let arr = try? JSONDecoder().decode([PopoverItem].self, from: data) {
                stored = arr
            } else {
                stored = PopoverModules.all.map { PopoverItem(id: $0.id, on: PopoverModules.defaultOn.contains($0.id)) }
            }
            let known = Set(PopoverModules.all.map { $0.id })
            var result = stored.filter { known.contains($0.id) }
            let present = Set(result.map { $0.id })
            for m in PopoverModules.all where !present.contains(m.id) {
                result.append(PopoverItem(id: m.id, on: PopoverModules.defaultOn.contains(m.id)))
            }
            return result
        }
        set { if let data = try? JSONEncoder().encode(newValue) { d.set(data, forKey: "popover.layout") } }
    }
    /// Непрозрачность фона поповера: 1.0 = плотный прибор, ниже = больше стекла.
    /// Ниже 0.72 системные secondary/tertiary labels теряют читаемость на рабочем столе.
    /// на пересборке (BMPopoverChanged → buildModules). Слайдер «Прозрачность фона» в S19.
    static var popoverOpacity: Double {
        get { Swift.min(1.0, Swift.max(0.72, d.object(forKey: "popover.opacity") as? Double ?? 0.88)) }
        set { d.set(Swift.min(1.0, Swift.max(0.72, newValue)), forKey: "popover.opacity") }
    }
    /// Раскрыта ли компактная панель «Управление». По умолчанию закрыта, чтобы
    /// активная вкладка начиналась сразу под шапкой; выбор пользователя запоминается.
    static var popoverControlsExpanded: Bool {
        get { d.bool(forKey: "popover.controlsExpanded") }
        set { d.set(newValue, forKey: "popover.controlsExpanded") }
    }
    /// Свои кнопки-команды (id, подпись, иконка, shell-команда, цвет).
    static var customToggles: [CustomToggle] {
        get { d.data(forKey: "toggles.custom").flatMap { try? JSONDecoder().decode([CustomToggle].self, from: $0) } ?? [] }
        set { if let data = try? JSONEncoder().encode(newValue) { d.set(data, forKey: "toggles.custom") } }
    }
    /// Раскладка плитки переключателей: порядок + видимость. id = встроенный или "custom:<uuid>".
    /// Сверяется с доступными встроенными + определёнными своими кнопками.
    static var toggleLayout: [PopoverItem] {
        get {
            let builtins = QuickToggleRegistry.availableDefs.map { $0.id }
            let customs = customToggles.map { "custom:\($0.id)" }
            let known = builtins + customs
            let defaultOn: Set<String> = ["limit80", "topup", "turbofan", "caffeine", "freeMemory"]   // root-firewall не маскируем под быстрый toggle
            let stored: [PopoverItem]
            if let data = d.data(forKey: "toggles.layout"),
               let arr = try? JSONDecoder().decode([PopoverItem].self, from: data) {
                stored = arr
            } else {
                stored = builtins.map { PopoverItem(id: $0, on: defaultOn.contains($0)) }
            }
            var result = stored.filter { known.contains($0.id) }
            let present = Set(result.map { $0.id })
            for id in known where !present.contains(id) {
                result.append(PopoverItem(id: id, on: id.hasPrefix("custom:") ? true : defaultOn.contains(id)))
            }
            return result
        }
        set { if let data = try? JSONEncoder().encode(newValue) { d.set(data, forKey: "toggles.layout") } }
    }
    // Палитра кастом-тумблеров сведена к бренд-семейству + семантика (без чужеродных pink/purple/yellow).
    // color(named:) ниже всё ещё резолвит старые значения — ранее сохранённые тумблеры не сломаются.
    static let toggleColors = ["teal", "blue", "green", "orange", "red", "indigo", "gray"]
    static func color(named s: String) -> NSColor {
        switch s {
        case "teal": return .systemTeal; case "green": return .systemGreen; case "orange": return .systemOrange
        case "red": return .systemRed; case "purple": return .systemPurple; case "indigo": return .systemIndigo
        case "pink": return .systemPink; case "yellow": return .systemYellow; case "gray": return .systemGray
        default: return .systemBlue
        }
    }

    static var langMode: String {           // off | hotkey | auto
        get { d.string(forKey: "lang.mode") ?? "off" }
        set { d.set(newValue, forKey: "lang.mode") }
    }
    static var langHotkey: Int {            // keycode модификатора-триггера (по умолч. правый ⌥ = 61)
        get { d.object(forKey: "lang.hotkey") as? Int ?? 61 }
        set { d.set(newValue, forKey: "lang.hotkey") }
    }
    // — Глобальный хоткей вызова поповера (Carbon). Дефолт ⌥⌘B, ВКЛ из коробки. —
    static var popoverHotkeyEnabled: Bool {       // по умолчанию ВКЛ (и для старых юзеров — нет ключа → true)
        get { d.object(forKey: "hotkey.popover.enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "hotkey.popover.enabled") }
    }
    static var popoverHotkeyKeyCode: Int {        // virtual keyCode (11 = kVK_ANSI_B)
        get { d.object(forKey: "hotkey.popover.keyCode") as? Int ?? 11 }
        set { d.set(newValue, forKey: "hotkey.popover.keyCode") }
    }
    static var popoverHotkeyMods: Int {           // NSEvent.ModifierFlags.rawValue; деф = ⌥⌘
        get { d.object(forKey: "hotkey.popover.mods") as? Int
                ?? Int(NSEvent.ModifierFlags([.command, .option]).rawValue) }
        set { d.set(newValue, forKey: "hotkey.popover.mods") }
    }
    static var menuBarShowWatts: Bool {
        get { d.bool(forKey: "menubar.watts") }
        set { d.set(newValue, forKey: "menubar.watts") }
    }
    static var menuBarMode: String {        // что показывает иконка в строке меню: battery | cpu | ram
        get { d.string(forKey: "menubar.mode") ?? "battery" }
        set { d.set(newValue, forKey: "menubar.mode") }
    }
    static var menuBarCombined: Bool {       // объединённый вид: основной показатель + доп-показатели одним моноблоком-картинкой
        get { d.bool(forKey: "menubar.combined") }
        set { d.set(newValue, forKey: "menubar.combined") }
    }
    static let menuBarExtraMax = 3           // жёсткий лимит доп-показателей — чтобы строка не превращалась в помойку
    static var menuBarExtras: [String] {     // доп-показатели поверх основного (watts/cputemp/gputemp/fan/cpu/ram)
        get { (d.array(forKey: "menubar.extras") as? [String]) ?? [] }
        set { d.set(Array(newValue.prefix(menuBarExtraMax)), forKey: "menubar.extras") }
    }
    static var menuBarExtraIcons: Bool {     // ведущий глиф перед каждым показателем в объединённом виде (по умолч. ВКЛ)
        get { d.object(forKey: "menubar.extraIcons") as? Bool ?? true }
        set { d.set(newValue, forKey: "menubar.extraIcons") }
    }
    static var menuBarIconStyle: String {    // стиль глифов показателей: kelvin (фирменные) | system (SF Symbols)
        get { d.string(forKey: "menubar.iconStyle") ?? "kelvin" }
        set { d.set(newValue, forKey: "menubar.iconStyle") }
    }
    static var mainIconStyle: String {       // kelvin | thermometer | battery | ring
        get { d.string(forKey: "menubar.mainIcon") ?? "kelvin" }
        set { d.set(newValue, forKey: "menubar.mainIcon") }
    }
    static var menuBarMotion: Bool {         // осмысленные event-анимации; Reduce Motion имеет приоритет
        get { d.object(forKey: "menubar.motion") as? Bool ?? true }
        set { d.set(newValue, forKey: "menubar.motion") }
    }

    /// Одноразово включает новое визуальное лицо Kelvin и для существующих
    /// пользователей. Иначе сохранённый legacy-дефолт (system + battery/thermometer)
    /// навсегда скрывал бы фирменную иконку и анимации после обновления. После
    /// миграции пользователь по-прежнему может выбрать любой стиль вручную.
    static func migrateMenuBarIdentityIfNeeded() {
        guard !d.bool(forKey: "menubar.identityV2") else { return }
        menuBarIconStyle = "kelvin"
        mainIconStyle = "kelvin"
        if d.object(forKey: "menubar.motion") == nil { menuBarMotion = true }
        d.set(true, forKey: "menubar.identityV2")
    }

    /// V3 возвращает привычную грамматику строки меню macOS: широкая живая батарея
    /// с точным уровнем и системные глифы. Миграция одноразовая — последующий выбор
    /// пользователя больше не перезаписывается обновлениями.
    static func migrateNativeMenuBarIfNeeded() {
        guard !d.bool(forKey: "menubar.nativeV3") else { return }
        menuBarIconStyle = "kelvin"
        mainIconStyle = "kelvin"
        if d.object(forKey: "menubar.motion") == nil { menuBarMotion = true }
        d.set(true, forKey: "menubar.nativeV3")
    }

    /// Возвращает фирменную иконку Kelvin пользователям, которым предыдущая
    /// миграция автоматически подставила системную батарею.
    static func migrateOriginalMenuBarIconIfNeeded() {
        guard !d.bool(forKey: "menubar.originalIconV4") else { return }
        menuBarIconStyle = "kelvin"
        mainIconStyle = "kelvin"
        d.set(true, forKey: "menubar.originalIconV4")
    }

    /// V4 могла отметить миграцию выполненной до того, как фирменный стиль реально
    /// сохранился (у таких установок осталась пара system + battery). Повторяем
    /// исправление новым ключом только для этой проблемной пары, не перезаписывая
    /// остальные осознанно выбранные пользователем варианты.
    static func repairOriginalMenuBarIconIfNeeded() {
        guard !d.bool(forKey: "menubar.originalIconV5") else { return }
        if menuBarIconStyle == "system", mainIconStyle == "battery" {
            menuBarIconStyle = "kelvin"
            mainIconStyle = "kelvin"
        }
        d.set(true, forKey: "menubar.originalIconV5")
    }

    /// Один раз переводит только нетронутый старый дефолт поповера на компактную
    /// продуктовую раскладку. Любой пользовательский порядок или набор сохраняется.
    static func migratePopoverProductLayoutIfNeeded() {
        let migrationKey = "popover.productLayoutV1"
        guard !d.bool(forKey: migrationKey) else { return }
        defer { d.set(true, forKey: migrationKey) }

        guard let data = d.data(forKey: "popover.layout"),
              let stored = try? JSONDecoder().decode([PopoverItem].self, from: data)
        else { return }

        let legacyOn: Set<String> = [
            "battery", "toggles", "audio", "flow", "hardware",
            "apps", "privacy", "maintenance", "history", "health"
        ]
        let catalogOrder = PopoverModules.all.map(\.id)
        guard stored.map(\.id) == catalogOrder,
              Set(stored.filter(\.on).map(\.id)) == legacyOn
        else { return }

        popoverLayout = stored.map {
            PopoverItem(id: $0.id, on: PopoverModules.defaultOn.contains($0.id))
        }
    }

    static var idleBacklight: Bool {
        get { d.bool(forKey: "kb.idleBacklight") }
        set { d.set(newValue, forKey: "kb.idleBacklight") }
    }
    static var idleSeconds: Int {
        get { d.object(forKey: "kb.idleSeconds") as? Int ?? 30 }
        set { d.set(newValue, forKey: "kb.idleSeconds") }
    }
    static var chargeLimit: Int {           // % лимита заряда (100 = без лимита)
        get { d.object(forKey: "batt.chargeLimit") as? Int ?? 100 }
        set { d.set(newValue, forKey: "batt.chargeLimit") }
    }
    static var chargeMode: String {          // limit | sail  (NB: off == limit@100, без отдельного "off" в демоне)
        get { d.string(forKey: "batt.chargeMode") ?? "limit" }
        set { d.set(newValue, forKey: "batt.chargeMode") }
    }
    static var sailUpper: Int {              // верхний порог парусной полосы (заряжаем до)
        get { d.object(forKey: "batt.sailUpper") as? Int ?? 80 }
        set { d.set(newValue, forKey: "batt.sailUpper") }
    }
    static var sailLower: Int {              // нижний порог парусной полосы (держим лимит)
        get { d.object(forKey: "batt.sailLower") as? Int ?? 70 }
        set { d.set(newValue, forKey: "batt.sailLower") }
    }
    static var heatProtect: Bool {           // оверлей: пауза заряда при перегреве (по умолч. выкл)
        get { d.bool(forKey: "batt.heatProtect") }
        set { d.set(newValue, forKey: "batt.heatProtect") }
    }
    static var heatTemp: Int {               // °C — порог перегрева батареи
        get { d.object(forKey: "batt.heatTemp") as? Int ?? 35 }
        set { d.set(newValue, forKey: "batt.heatTemp") }
    }
    static var topUpUntil: Double {          // epoch-секунды; до этого момента временно BCLM=100 (0 = выкл)
        get { d.double(forKey: "batt.topUpUntil") }
        set { d.set(newValue, forKey: "batt.topUpUntil") }
    }
    // Плановый дозаряд «полный заряд к времени» (честное окно; демон спящий Mac не будит).
    static var chargeAlarmOn: Bool {         // включён ли суточный оконный дозаряд
        get { d.bool(forKey: "batt.chargeAlarmOn") }
        set { d.set(newValue, forKey: "batt.chargeAlarmOn") }
    }
    static var chargeAlarmTargetMin: Int {   // минуты локального дня цели (по умолч. 7:00)
        get { d.object(forKey: "batt.chargeAlarmTargetMin") as? Int ?? 420 }
        set { d.set(newValue, forKey: "batt.chargeAlarmTargetMin") }
    }
    static var chargeAlarmLeadMin: Int {     // фора: за сколько минут до цели начинать (по умолч. 60)
        get { d.object(forKey: "batt.chargeAlarmLeadMin") as? Int ?? 60 }
        set { d.set(newValue, forKey: "batt.chargeAlarmLeadMin") }
    }
    // ─── GPU Automation (AC/battery) ───────────────────────────────────────
    /// Автоматическое переключение GPU по источнику питания.
    static var gpuAutomationEnabled: Bool {
        get { d.bool(forKey: "gpu.automation") }
        set { d.set(newValue, forKey: "gpu.automation") }
    }
    /// Режим GPU при питании от сети (по умолчанию Авто).
    static var gpuModeAC: Int {
        get { d.object(forKey: "gpu.modeAC") as? Int ?? GPUMode.automatic.rawValue }
        set { d.set(newValue, forKey: "gpu.modeAC") }
    }
    /// Режим GPU при питании от батареи (по умолчанию Встроенная).
    static var gpuModeBattery: Int {
        get { d.object(forKey: "gpu.modeBattery") as? Int ?? GPUMode.integratedOnly.rawValue }
        set { d.set(newValue, forKey: "gpu.modeBattery") }
    }

    static var alertsEnabled: Bool {        // мастер-тумблер пороговых уведомлений
        get { d.object(forKey: "alerts.enabled") as? Bool ?? false }
        set { d.set(newValue, forKey: "alerts.enabled") }
    }
    static var firstConnAlerts: Bool {      // «новое приложение впервые в сети» (Радар 2.0); по умолч. выкл — без сюрпризов
        get { d.bool(forKey: "firstconn.enabled") }
        set { d.set(newValue, forKey: "firstconn.enabled") }
    }
    /// Правила алертов: хранёное + мердж дефолтов для типов, которых ещё нет
    /// в сохранёнке (новые AlertKind подхватятся, порядок — как в allCases).
    static var alertRules: [AlertRule] {
        get {
            var byKind: [AlertKind: AlertRule] = [:]
            if let data = d.data(forKey: "alerts.rules"),
               let arr = try? JSONDecoder().decode([AlertRule].self, from: data) {
                for r in arr { byKind[r.kind] = r }
            }
            return AlertKind.allCases.map { k in
                byKind[k] ?? AlertRule(kind: k, on: k.defaultOn, threshold: k.defaultThreshold)
            }
        }
        set { if let data = try? JSONEncoder().encode(newValue) { d.set(data, forKey: "alerts.rules") } }
    }
    static var nightKeepOn: Bool {          // держать Night Shift всегда включённым
        get { d.bool(forKey: "night.keepOn") }
        set { d.set(newValue, forKey: "night.keepOn") }
    }
    static var nightStrength: Float {       // теплота Night Shift 0…1
        get { d.object(forKey: "night.strength") as? Float ?? 0.6 }
        set { d.set(newValue, forKey: "night.strength") }
    }
    static var snippetsEnabled: Bool {
        get { d.bool(forKey: "snip.enabled") }
        set { d.set(newValue, forKey: "snip.enabled") }
    }
    static var spellFixEnabled: Bool {       // авто-исправление явных опечаток (NSSpellChecker)
        get { d.bool(forKey: "spell.enabled") }
        set { d.set(newValue, forKey: "spell.enabled") }
    }
    static var spellFixMode: String {
        get { d.string(forKey: "spell.mode") ?? "strict" }
        set { d.set(newValue, forKey: "spell.mode") }
    }
    static var langAutoMinLength: Int {
        get { max(3, min(5, d.object(forKey: "lang.autoMinLength") as? Int ?? 3)) }
        set { d.set(max(3, min(5, newValue)), forKey: "lang.autoMinLength") }
    }
    static var langFeedbackSound: Bool {     // звук при смене раскладки/исправлении (по умолч. вкл)
        get { d.object(forKey: "lang.fbSound") as? Bool ?? true }
        set { d.set(newValue, forKey: "lang.fbSound") }
    }
    static var langFeedbackHUD: Bool {       // всплывающий индикатор при автозамене (по умолч. вкл)
        get { d.object(forKey: "lang.fbHUD") as? Bool ?? true }
        set { d.set(newValue, forKey: "lang.fbHUD") }
    }
    static var langFeedbackStyle: String {
        get { d.string(forKey: "lang.fbStyle") ?? "animated" }
        set { d.set(newValue, forKey: "lang.fbStyle") }
    }
    static var snippetsRaw: String {
        get { d.string(forKey: "snip.raw") ?? ";mail = cambly.studio@gmail.com\n;shrug = ¯\\_(ツ)_/¯\n;tm = ™" }
        set { d.set(newValue, forKey: "snip.raw") }
    }
    /// Парсит строки «триггер = текст» в пары.
    static func parseSnippets(_ raw: String) -> [(trigger: String, text: String)] {
        raw.split(separator: "\n").compactMap { line in
            guard let eq = line.range(of: "=") else { return nil }
            let t = line[line.startIndex..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
            let x = line[eq.upperBound...].trimmingCharacters(in: .whitespaces)
            return t.isEmpty || x.isEmpty ? nil : (t, x)
        }
    }
    static var customFanProfile: FanProfile {
        get {
            guard let data = d.data(forKey: "fan.custom"),
                  let p = try? JSONDecoder().decode(FanProfile.self, from: data) else {
                return FanProfile(name: "Свой", mode: .curve)
            }
            return p
        }
        set { if let data = try? JSONEncoder().encode(newValue) { d.set(data, forKey: "fan.custom") } }
    }
    /// Активный профиль хранится как СТАБИЛЬНЫЙ id (B2): встроенные — "auto/quiet/balance/turbo",
    /// пользовательские — по их имени (имя userPreset и есть его id; локализации к ним нет).
    /// Раньше здесь лежала русская строка-название — миграция V3 (см. ниже) перекладывает её в id.
    static var activeFanProfileName: String {
        get { d.string(forKey: "fan.active") ?? "auto" }
        set { d.set(newValue, forKey: "fan.active") }
    }
    // Автоматика вентиляторов по источнику питания (Pro): свой профиль на сети / на батарее.
    static var fanAutoBySource: Bool {
        get { d.bool(forKey: "fan.autoBySource") }
        set { d.set(newValue, forKey: "fan.autoBySource") }
    }
    static var fanProfileAC: String {           // id профиля при питании от сети (по умолч. «Баланс»)
        get { d.string(forKey: "fan.profileAC") ?? "balance" }
        set { d.set(newValue, forKey: "fan.profileAC") }
    }
    static var fanProfileBattery: String {      // id профиля при питании от батареи (по умолч. системный авто)
        get { d.string(forKey: "fan.profileBattery") ?? "auto" }
        set { d.set(newValue, forKey: "fan.profileBattery") }
    }
    /// Стабильные id встроенных профилей (НЕ локализуемы) — ключи идентичности/персистенса/матча.
    static let builtinFanIDs = ["auto", "quiet", "balance", "turbo"]
    /// Легаси русские имена встроенных (для миграции persisted-значений V2/V3 и защиты имён userPreset).
    static let builtinFanNames = ["Авто", "Тихий", "Баланс", "Турбо"]
    /// id встроенного профиля → локализуемое отображаемое имя (L-ключ = русская строка по контракту).
    static func builtinFanDisplay(_ id: String) -> String {
        switch id {
        case "auto":    return L("Авто")
        case "quiet":   return L("Тихий")
        case "balance": return L("Баланс")
        case "turbo":   return L("Турбо")
        default:        return id      // userPreset: имя = его отображение (не локализуется)
        }
    }
    /// Является ли id встроенным профилем.
    static func isBuiltinFanID(_ id: String) -> Bool { builtinFanIDs.contains(id) }
    /// Пользовательские именованные пресеты (Pro): сохранённые кривые/постоянные обороты.
    /// fand.swift декодит fan-profile.json по полям — имя ему не нужно, так что это чисто app-слой.
    static var userFanPresets: [FanProfile] {
        get {
            guard let data = d.data(forKey: "fan.userPresets"),
                  let a = try? JSONDecoder().decode([FanProfile].self, from: data) else { return [] }
            return a
        }
        set { if let data = try? JSONEncoder().encode(newValue) { d.set(data, forKey: "fan.userPresets") } }
    }
    /// Разовый перенос легаси-слота «Свой» (fan.custom) в массив именованных пресетов —
    /// чтобы у текущих пользователей их кастомная кривая не пропала после обновления.
    static func migrateLegacyCustomPresetIfNeeded() {
        // V2 (как было): перенос легаси-слота «Свой» в массив именованных пресетов.
        if !d.bool(forKey: "fan.migratedV2") {
            if d.data(forKey: "fan.custom") != nil {
                var ps = userFanPresets
                var legacy = customFanProfile
                if legacy.name.isEmpty || builtinFanNames.contains(legacy.name) { legacy.name = "Свой" }
                if !ps.contains(where: { $0.name == legacy.name }) { ps.append(legacy); userFanPresets = ps }
                if activeFanProfileName == "Свой" { activeFanProfileName = legacy.name }
            }
            d.set(true, forKey: "fan.migratedV2")
        }
        // V3 (B2): persisted активный профиль был русской строкой-названием встроенного — переложить в id.
        // userPreset-имена НЕ трогаем (их имя = их id; локализации нет) → выбор пользователя не теряется.
        if !d.bool(forKey: "fan.migratedV3") {
            let map = ["Авто": "auto", "Тихий": "quiet", "Баланс": "balance", "Турбо": "turbo"]
            if let raw = d.string(forKey: "fan.active"), let id = map[raw] {
                activeFanProfileName = id
            }
            d.set(true, forKey: "fan.migratedV3")
        }
    }
}

// MARK: - Окно настроек

/// Контейнер с координатами сверху-вниз — для документа в NSScrollView.
private final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// Ленивое раскрытие: тяжёлое содержимое создаётся только при первом открытии, а не во время
/// построения всей секции. Это особенно важно для lsof, firewall rules и больших журналов.
private final class LazyDisclosureView: NSView {
    private let header: NSButton
    private let body = NSStackView()
    private let builder: () -> NSView
    private let onStateChange: (Bool) -> Void
    private var builtContent: NSView?
    private(set) var isExpanded: Bool

    init(title: String, expanded: Bool, onStateChange: @escaping (Bool) -> Void = { _ in },
         builder: @escaping () -> NSView) {
        self.isExpanded = expanded
        self.builder = builder
        self.onStateChange = onStateChange
        self.header = NSButton(title: title, target: nil, action: nil)
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        header.target = self
        header.action = #selector(toggle)
        header.isBordered = false
        header.alignment = .left
        header.font = Design.Font.body
        header.imagePosition = .imageLeading
        header.contentTintColor = .labelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        header.heightAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true

        body.orientation = .vertical
        body.alignment = .width
        body.spacing = Design.Space.s2
        body.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [header, body])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyState(buildIfNeeded: expanded)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func toggle() {
        isExpanded.toggle()
        applyState(buildIfNeeded: isExpanded)
        onStateChange(isExpanded)
    }

    private func applyState(buildIfNeeded: Bool) {
        header.image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right",
                               accessibilityDescription: nil)
        if buildIfNeeded, builtContent == nil {
            let content = builder()
            content.translatesAutoresizingMaskIntoConstraints = false
            body.addArrangedSubview(content)
            builtContent = content
        }
        body.isHidden = !isExpanded
    }
}

/// Виртуализированный список для длинных настроечных списков. В отличие от сотен NSStackView,
/// NSTableView создаёт только видимые строки и переиспользует ячейки.
private final class SettingsListTable<Item>: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let items: [Item]
    private let rowHeightValue: CGFloat
    private let makeRow: (Item) -> NSView
    private let tableView = NSTableView()

    init(items: [Item], rowHeight: CGFloat, makeRow: @escaping (Item) -> NSView) {
        self.items = items
        self.rowHeightValue = rowHeight
        self.makeRow = makeRow
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("settings.list.column"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = .zero
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .clear

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = tableView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeightValue }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("settings.list.cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? NSTableCellView(frame: .zero)
        cell.identifier = id
        cell.subviews.forEach { $0.removeFromSuperview() }
        let content = makeRow(items[row])
        content.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: cell.topAnchor),
            content.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
        ])
        return cell
    }
}

/// Кнопка раздела сайдбара с лёгкой подсветкой при наведении (как в Системных настройках macOS):
/// выбранная строка держит accent-заливку, невыбранная мягко подсвечивается под курсором.
final class SidebarButton: NSButton {
    var isSelectedRow = false { didSet { paint(hovering: false) } }
    private var hoverTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t); hoverTracking = t
    }
    override func mouseEntered(with event: NSEvent) { paint(hovering: true) }
    override func mouseExited(with event: NSEvent) { paint(hovering: false) }
    private func paint(hovering: Bool) {
        let dark = window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if isSelectedRow {
            layer?.backgroundColor = Design.Color.accentMuted(dark).cgColor
        } else if hovering {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        } else {
            layer?.backgroundColor = .clear
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}




/// Бренд-карточка: бирюзовая заливка-токен + акцентная кромка, перекрашивается под тему.
private final class HeroCardView: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.cornerRadius = Design.Radius.group
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.backgroundColor = Design.Color.accentMuted(dark).cgColor
        layer?.borderColor = Design.Color.accent(dark).withAlphaComponent(dark ? 0.55 : 0.45).cgColor
    }
}

/// Вердикт-карточка фаервола: стеклянная плитка с тонированной кромкой по уровню (teal/warn).
/// Цвет задаётся снаружи (tint) — заливка приглушённая, кромка ярче, перекрашивается под тему.
private final class FWVerdictCardView: NSView {
    var tint: NSColor = Design.Color.accent(false) { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.cornerRadius = Design.Radius.group
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.backgroundColor = tint.withAlphaComponent(dark ? 0.14 : 0.10).cgColor
        layer?.borderColor = tint.withAlphaComponent(dark ? 0.50 : 0.40).cgColor
    }
}

/// Управление политикой активации для оконного UI агента (LSUIElement).
/// .accessory никогда не владеет системной строкой меню — пока открыто любое окно Kelvin,
/// держим .regular (своё меню + фокус), и возвращаемся к .accessory, только когда закрылось
/// ПОСЛЕДНЕЕ окно (Настройки/Онбординг/О программе), чтобы не было мигания при закрытии одного из нескольких.
enum WindowChrome {
    /// Переходим в обычное приложение: появляется свой app-меню (вместо чужого) и фокус.
    /// Иконка в Dock на время открытого окна нужна для фокуса и системного app-меню.
    static func becomeRegular() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    /// Возврат к agent-режиму, ТОЛЬКО если не осталось видимых окон Kelvin.
    /// Зовётся из windowWillClose — окно ещё в списке, поэтому считаем те, что НЕ закрываются.
    static func restoreAccessoryIfNoWindows(closing: NSWindow?) {
        let stillOpen = NSApp.windows.contains { w in
            w !== closing && w.isVisible && Self.isKelvinChrome(w)
        }
        if !stillOpen { NSApp.setActivationPolicy(.accessory) }
    }
    /// Окно — наше «хром»-окно (Настройки/Онбординг/О программе), а не поповер/служебное?
    private static func isKelvinChrome(_ w: NSWindow) -> Bool {
        w.windowController is KelvinSettingsWindowController
            || w.windowController is OnboardingWindowController
    }
}
