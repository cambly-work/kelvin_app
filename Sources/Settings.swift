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
    ]
    // V2 макет-дефолт: шапка + тумблеры + звук + 6 доменов. БЕЗ большого блока Батарея-кратко/Диск/BT
    // (в макете его нет; доступны по желанию через настройки). audio добавлен — в макете звук на месте.
    static let defaultOn: Set<String> = ["battery", "toggles", "audio", "flow", "hardware", "apps", "privacy", "maintenance", "history"]
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
    /// Непрозрачность фона поповера: 1.0 = плотный тёмный прибор, ниже = больше стекла/вибранси.
    /// Пол 0.4 — читаемость (никогда полностью прозрачный). Правит AuraView.applyBase; применяется
    /// на пересборке (BMPopoverChanged → buildModules). Слайдер «Прозрачность фона» в S19.
    static var popoverOpacity: Double {
        get { d.object(forKey: "popover.opacity") as? Double ?? 0.80 }   // дефолт прозрачнее (V5: владелец «докрути»)
        set { d.set(Swift.min(1.0, Swift.max(0.18, newValue)), forKey: "popover.opacity") }   // предел прозрачности ещё глубже (V5)
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
            let defaultOn: Set<String> = ["limit80", "topup", "turbofan", "panic", "caffeine"]   // V5: фичи Kelvin, не дубль Пункта управления
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
    static var mainIconStyle: String {       // главная иконка строки меню (режим «Батарея»): thermometer | battery
        get { d.string(forKey: "menubar.mainIcon") ?? "thermometer" }
        set { d.set(newValue, forKey: "menubar.mainIcon") }
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
    static var alertsEnabled: Bool {        // мастер-тумблер пороговых уведомлений
        get { d.object(forKey: "alerts.enabled") as? Bool ?? true }
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




/// Бренд-карточка героя Pro: бирюзовая заливка-токен + акцентная кромка, перекрашивается под тему.
/// Используется только в разделе Kelvin Pro (CTA $19) — не общий бокс настроек.
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
    /// Иконка в Dock на время открытого окна — принятый компромисс для платного приложения.
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
        w.windowController is SettingsWindowController || w.windowController is OnboardingWindowController
    }
}

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let content = NSVisualEffectView()  // liquid glass — blur под всеми карточками
    private var sidebarRows: [NSButton] = []
    private var currentSection: Section?
    private var currentScroll: NSScrollView?

    /// Постоянные страницы разделов. Переход по сайдбару больше не строит экран заново.
    private var sectionScrolls: [Section: NSScrollView] = [:]
    private var sectionWidthConstraints: [Section: NSLayoutConstraint] = [:]
    private var sectionBuildVersion: [Section: Int] = [:]
    private var dirtySections = Set<Section>()

    /// Повторные запросы перестройки одного раздела объединяются в один кадр.
    private var reloadWorkItems: [Section: DispatchWorkItem] = [:]

    /// Тяжёлые фоновые загрузки имеют стабильный ключ, отмену ожидающей работы и защиту
    /// от устаревшего результата после перестройки страницы.
    private var asyncWorkItems: [String: DispatchWorkItem] = [:]
    private var asyncWorkSections: [String: Section] = [:]
    private var asyncGeneration: [String: Int] = [:]

    /// Состояние ленивых раскрытий сохраняется при локальной перестройке раздела.
    private var disclosureState: [String: Bool] = [:]

    /// Debounce для дорогих каскадов: пересборка поповера и запись профиля вентилятора.
    private var popoverNotifyWorkItem: DispatchWorkItem?
    private var fanApplyWorkItem: DispatchWorkItem?
    /// Кешированная тема — вместо 8 мест дублирования `(window?.effectiveAppearance...).bestMatch(...)`.
    private var isDark: Bool {
        (window?.effectiveAppearance ?? NSApp.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
    private let settingsActionQueue = DispatchQueue(label: "com.trykelvin.kelvin.settings.actions",
                                                    qos: .userInitiated)
    private let settingsWriteQueue = DispatchQueue(label: "com.trykelvin.kelvin.settings.writes",
                                                   qos: .utility)
    private weak var fanStatusLabel: NSTextField?
    private weak var fanStatusIcon: NSImageView?
    private weak var fanToggleBtn: NSButton?
    private let customLabelField = NSTextField(string: "")
    private let customIconField = NSTextField(string: "")
    private let customCmdField = NSTextField(string: "")
    private let customColorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let licenseKeyField = NSTextField(string: "")
    private weak var activateButton: GlassButton?       // блокируется на время сетевого запроса
    private weak var activateSpinner: NSProgressIndicator?
    private weak var activateError: NSTextField?        // инлайн-строка ошибки под полем ключа
    private weak var sailUpperLabel: NSTextField?            // живое обновление подписи парусной полосы
    private weak var sailLowerLabel: NSTextField?
    private weak var sailUpperSlider: KSlider?               // кросс-обновление ползунка при клампе полосы (≥5)
    private weak var sailLowerSlider: KSlider?
    private weak var heatTempLabel: NSTextField?            // живое обновление подписи порога перегрева
    private weak var nightStrengthLabel: NSTextField?       // живое обновление подписи теплоты Night Shift

    private enum Section: String, CaseIterable {
        case support = "Поддержать Kelvin"
        case basics = "Основные"
        case power = "Питание и охлаждение"
        case input = "Ввод и текст"
        case netsec = "Сеть и защита"
        case hub = "Поповер и уведомления"
        case about = "О программе"
        // Скрытые (спящий код — лицензия):
        case license = "Kelvin Pro"
        /// Разделы в сайдбаре (7): «Поддержать» сверху, «О программе» — снизу.
        static let visible: [Section] = [.support, .basics, .power, .input, .netsec, .hub, .about]
        var icon: String {
            switch self {
            case .support:  return "heart.fill"
            case .basics:   return "gearshape"
            case .power:    return "bolt.fill"
            case .input:    return "keyboard"
            case .netsec:   return "lock.shield"
            case .hub:      return "square.grid.2x2"
            case .about:    return "info.circle"
            case .license:  return "creditcard"
            }
        }
    }

    private convenience init() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 680),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        // Окно адаптивное: достаточно широкое для сложных контролов, но больше не заперто на 880 px.
        // Это убирает искусственное усечение локализаций и позволяет пользователю выбрать плотность.
        win.contentMinSize = NSSize(width: 820, height: 500)
        win.contentMaxSize = NSSize(width: 1180, height: 100000)
        win.title = L("Настройки Kelvin")
        win.titleVisibility = .visible              // заголовок виден + рабочая строка управления окном
        win.titlebarAppearsTransparent = true       // стекло сайдбара протекает во всю высоту под титул
        win.isReleasedWhenClosed = false
        // запоминаем положение окна между запусками; центрируем только при первом показе
        let autosave = "KelvinSettings"
        let hadSavedFrame = UserDefaults.standard.object(forKey: "NSWindow Frame \(autosave)") != nil
        win.setFrameAutosaveName(autosave)
        self.init(window: win)
        win.delegate = self                         // windowWillClose → возврат в .accessory
        buildLayout()
        select(Self.lastSection)
        if !hadSavedFrame { win.center() }
        else if win.frame.width < win.contentMinSize.width || win.frame.width > win.contentMaxSize.width {
            var f = win.frame
            f.size.width = min(max(f.size.width, win.contentMinSize.width), win.contentMaxSize.width)
            win.setFrame(f, display: false)
        }
    }
    private static var lastSection: Section {
        let s = Section(rawValue: UserDefaults.standard.string(forKey: "settings.lastSection") ?? "") ?? .basics
        return Section.visible.contains(s) ? s : .basics   // старый сохранённый раздел → на новый дефолт
    }

    func open() {
        // .accessory никогда не владеет строкой меню → показалось бы чужое меню (напр. Notes).
        // Становимся .regular, чтобы строка показывала app-меню Kelvin; назад в .accessory —
        // при закрытии последнего окна (windowWillClose). Положение восстанавливается из autosave.
        WindowChrome.becomeRegular()
        NSApp.activate(ignoringOtherApps: true)   // accessory-app: без активации окно всплывает ПОЗАДИ/на чужом спейсе → «окно не открывается»
        // Автосейв старой версии мог сохранить недопустимую ширину — только клампим её, не фиксируем.
        if let w = window, w.frame.width < w.contentMinSize.width || w.frame.width > w.contentMaxSize.width {
            var f = w.frame
            f.size.width = min(max(f.size.width, w.contentMinSize.width), w.contentMaxSize.width)
            w.setFrame(f, display: false)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()            // гарантированно поверх, даже если фокус у другого приложения/fullscreen
    }

    /// Пересобрать раздел «Питание и охлаждение», ЕСЛИ окно открыто и показывает именно его — чтобы после
    /// применения быстрого пресета из меню-бара пилюли/герой отразили новое состояние. Иначе no-op.
    func refreshPowerIfOpen() {
        guard isWindowLoaded, window?.isVisible == true, currentSection == .power else { return }
        select(.power)
    }

    /// Снапшот ВСЕХ секций Настроек в PNG (офскрин `cacheDisplay`, БЕЗ показа окна) — для визуального QA.
    /// Окно уже построено в init; просто перебираем секции, рендерим contentView (сайдбар + область).
    func renderSectionsSnapshot(to dir: String, light: Bool, prefix: String) -> Int {
        guard let win = window, let root = win.contentView else { return 0 }
        if light { win.appearance = NSAppearance(named: .aqua) }
        win.setContentSize(NSSize(width: 880, height: 640))
        // Область контента прозрачна (в живом окне за ней материал окна). Офскрин материала нет → был бы
        // белый фон и невидимый светлый (тёмнотемный) текст. Красим непрозрачным фоном окна под тему.
        root.wantsLayer = true; content.wantsLayer = true
        let appr = win.appearance ?? NSApp.effectiveAppearance
        appr.performAsCurrentDrawingAppearance {
            root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        var n = 0
        for s in Section.allCases {
            select(s)
            root.layoutSubtreeIfNeeded()
            let end = Date().addingTimeInterval(0.5)                    // даём секции долить async-данные
            while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
            root.layoutSubtreeIfNeeded()
            let r = root.bounds
            guard r.width > 1, r.height > 1, let rep = root.bitmapImageRepForCachingDisplay(in: r) else { continue }
            root.cacheDisplay(in: r, to: rep)
            let slug = s.rawValue.replacingOccurrences(of: " ", with: "_")
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: String(format: "%@/%@%02d_%@.png", dir, prefix, n, slug)))
                n += 1
            }
        }
        return n
    }

    func windowWillClose(_ notification: Notification) {
        WindowChrome.restoreAccessoryIfNoWindows(closing: window)
    }

    override func close() {
        super.close()
    }

    private func buildLayout() {
        guard let win = window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(inputRuntimeChanged),
                                               name: Notification.Name("BMLangRuntimeChanged"), object: nil)
        let root = NSView()

        // Контент — спокойный системный фон. Blur оставлен только сайдбару: меньше GPU-работы
        // и нет эффекта «стеклянного супа» под каждой карточкой.
        content.material = .contentBackground
        content.blendingMode = .withinWindow
        content.state = .followsWindowActiveState
        content.wantsLayer = true

        // сайдбар — групповые заголовки + кнопки с крупными иконками
        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 3
        sidebar.edgeInsets = NSEdgeInsets(top: 50, left: 10, bottom: 10, right: 10)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        // Группировка: подписи заголовков + цветные иконки-плитки + визуальное разделение пробелом.
        let sidebarGroups: [(label: String?, sections: [Section])] = [
            (nil,                          [.support]),
            (L("Основные"),                [.basics]),
            (L("Устройства"),             [.power, .input, .hub]),
            (L("Сеть"),                    [.netsec]),
            (L("О приложении"),           [.about]),
        ]
        for (gi, grp) in sidebarGroups.enumerated() {
            if gi > 0 {
                let gap = NSView(); gap.translatesAutoresizingMaskIntoConstraints = false
                gap.heightAnchor.constraint(equalToConstant: 18).isActive = true
                sidebar.addArrangedSubview(gap)
            }
            if let label = grp.label {
                let lbl = NSTextField(labelWithString: label.uppercased())
                lbl.font = Design.Font.micro; lbl.textColor = .tertiaryLabelColor
                let kern = NSMutableAttributedString(string: lbl.stringValue, attributes: [.font: lbl.font as Any, .kern: Design.Font.capsKern])
                lbl.attributedStringValue = kern
                lbl.translatesAutoresizingMaskIntoConstraints = false
                lbl.heightAnchor.constraint(equalToConstant: 16).isActive = true
                sidebar.addArrangedSubview(lbl)
                // tighter spacing after label, before buttons
                let postLabelGap = NSView(); postLabelGap.translatesAutoresizingMaskIntoConstraints = false
                postLabelGap.heightAnchor.constraint(equalToConstant: 4).isActive = true
                sidebar.addArrangedSubview(postLabelGap)
            }
            for s in grp.sections {
                let b = SidebarButton(title: "  " + L(s.rawValue), target: self, action: #selector(sidebarClick(_:)))
                b.image = settingsIcon(s.icon, sidebarTint(s))
                b.imagePosition = .imageLeading
                b.bezelStyle = .inline
                b.isBordered = false
                b.alignment = .left
                b.font = .systemFont(ofSize: 13, weight: .medium)
                b.identifier = NSUserInterfaceItemIdentifier(s.rawValue)
                b.translatesAutoresizingMaskIntoConstraints = false
                b.widthAnchor.constraint(equalToConstant: 206).isActive = true
                b.heightAnchor.constraint(equalToConstant: 38).isActive = true
                b.wantsLayer = true; b.layer?.cornerRadius = 8
                sidebarRows.append(b)
                sidebar.addArrangedSubview(b)
            }
        }
        let sideBg = NSVisualEffectView()
        sideBg.material = .sidebar; sideBg.blendingMode = .behindWindow; sideBg.state = .active
        sideBg.translatesAutoresizingMaskIntoConstraints = false
        sideBg.addSubview(sidebar)

        // — Тонкая разделительная линия между сайдбаром и контентом —
        let divider = NSView()
        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        // Тема-зависимый цвет задаётся в viewDidChangeEffectiveAppearance (см. ниже)
        divider.identifier = NSUserInterfaceItemIdentifier("sidebarDivider")

        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sideBg); root.addSubview(divider); root.addSubview(content)
        NSLayoutConstraint.activate([
            sideBg.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sideBg.topAnchor.constraint(equalTo: root.topAnchor),
            sideBg.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sideBg.widthAnchor.constraint(equalToConstant: 228),
            sidebar.topAnchor.constraint(equalTo: sideBg.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: sideBg.leadingAnchor),
            divider.leadingAnchor.constraint(equalTo: sideBg.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        // Разделитель — тонкая hairline
        let dark = win.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        divider.layer?.backgroundColor = Design.Color.hairline(dark, 0.12).cgColor
        win.contentView = root
    }

    /// Цветная иконка-плитка в стиле Системных настроек macOS: SF-символ белым на скруглённом цветном квадрате.
    private func settingsIcon(_ symbol: String, _ color: NSColor) -> NSImage {
        let side: CGFloat = 26
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side), xRadius: 6, yRadius: 6).addClip()
        color.setFill(); NSRect(x: 0, y: 0, width: side, height: side).fill()
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let gs = glyph.size
            glyph.draw(in: NSRect(x: (side - gs.width) / 2, y: (side - gs.height) / 2, width: gs.width, height: gs.height))
        }
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    /// Цвет плитки для раздела (семантика как в Системных настройках).
    private func sidebarTint(_ s: Section) -> NSColor {
        // Один брендовый акцент вместо радуги из системных цветов. Семантические цвета
        // остаются только внутри статусов: ошибка/предупреждение/успех.
        switch s {
        case .support: return .systemPink
        case .basics, .about: return .systemGray
        case .power, .input, .netsec, .hub, .license:
            return SettingsStore.brandAccent(dark: isDark)
        }
    }

    /// Глушит горизонтальное «распирание» контента: раздел не должен растягивать окно или вылезать за
    /// пейн. Однострочные подписи усекаем хвостом; ВСЕМ текст-полям снижаем сопротивление сжатию по
    /// горизонтали, чтобы они переносились/усекались под ширину окна, а не толкали его. Многострочные
    /// (wrapping) уже переносятся. Кнопки/слайдеры/сегменты не трогаем — у них своя нужная ширина.
    private func stabilizeH(_ view: NSView) {
        // Не обнуляем сопротивление всему дереву: priority=1 заставлял AppKit хаотично
        // схлопывать подписи. Ослабляем только однострочные тексты, которым допустимо усечение.
        func walk(_ v: NSView) {
            for sub in v.subviews {
                if let tf = sub as? NSTextField {
                    let wraps = (tf.maximumNumberOfLines == 0) || (tf.cell as? NSTextFieldCell)?.wraps == true
                    if !wraps {
                        tf.lineBreakMode = .byTruncatingTail
                        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                    }
                }
                walk(sub)
            }
        }
        walk(view)
    }

    func selectByName(_ s: String) {
        if let sec = Section(rawValue: s), Section.visible.contains(sec) {
            select(sec)
        } else {
            select(.basics)   // неизвестный → дефолт
        }
    }

    @objc private func langChanged(_ s: NSPopUpButton) {
        let i = s.indexOfSelectedItem
        I18n.override = i <= 0 ? nil : Lang.allCases[min(i - 1, Lang.allCases.count - 1)]  // i == -1 / OOB → «Система»/клампа
        window?.title = L("Настройки Kelvin")
        // пересобрать имена сайдбара, текущий раздел и поповер на новом языке
        for b in sidebarRows {
            if let id = b.identifier?.rawValue, let sec = Section(rawValue: id) { b.title = "  " + L(sec.rawValue) }
        }
        let section = currentSection ?? .basics
        invalidateAllSections()
        currentSection = section
        updateSidebarSelection(section)
        reloadSectionNow(section, preserveScroll: false)
        NotificationCenter.default.post(name: Notification.Name("BMPopoverChanged"), object: nil)
        NotificationCenter.default.post(name: Notification.Name("BMMenuBarChanged"), object: nil)   // релокализовать тултип строки меню сразу
    }
    @objc private func sidebarClick(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let section = Section(rawValue: id) else { return }
        guard currentSection != section else { return }
        select(section)
    }

    @objc private func inputRuntimeChanged() {
        guard window?.isVisible == true, currentSection == .input else { return }
        select(.input)
    }

    /// Potentially slow system tools and administrator prompts must not block
    /// AppKit's event loop. The section is refreshed after the operation has
    /// actually completed instead of immediately showing stale state.
    private func performSettingsAction(in section: Section, _ action: @escaping () -> Void) {
        settingsActionQueue.async { [weak self] in
            action()
            DispatchQueue.main.async { [weak self] in
                self?.requestSectionReload(section, delay: 0)
            }
        }
    }

    private func updateSidebarSelection(_ section: Section) {
        for button in sidebarRows {
            let selected = button.identifier?.rawValue == section.rawValue
            (button as? SidebarButton)?.isSelectedRow = selected
            button.contentTintColor = .labelColor
        }
    }

    private func buildSectionContent(_ section: Section) -> NSView {
        switch section {
        case .support: return buildSupport()
        case .basics:  return buildBasics()
        case .power:   return buildPower()
        case .input:   return buildInput()
        case .netsec:  return buildNetSec()
        case .hub:     return buildHub()
        case .about:   return buildAbout()
        case .license: return buildLicense()
        }
    }

    /// Создаёт страницу раздела один раз. Переходы по сайдбару затем только переключают hidden,
    /// поэтому scroll position, first responder и уже загруженные данные не теряются.
    private func makeSectionScroll(_ section: Section) -> NSScrollView {
        sectionBuildVersion[section, default: 0] += 1
        cancelAsyncWork(for: section)

        let view = buildSectionContent(section)
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(view)
        stabilizeH(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: doc.topAnchor, constant: 28),
            view.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 24),
            view.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -24),
            view.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -28),
        ])

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc

        sectionWidthConstraints[section]?.isActive = false
        let width = doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        width.isActive = true
        sectionWidthConstraints[section] = width
        return scroll
    }

    private func installSectionScrollIfNeeded(_ scroll: NSScrollView) {
        guard scroll.superview !== content else { return }
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }

    private func showSection(_ section: Section) {
        let scroll: NSScrollView
        if let cached = sectionScrolls[section], !dirtySections.contains(section) {
            scroll = cached
        } else {
            let old = sectionScrolls[section]
            scroll = makeSectionScroll(section)
            sectionScrolls[section] = scroll
            dirtySections.remove(section)
            old?.removeFromSuperview()
        }
        installSectionScrollIfNeeded(scroll)
        for (_, page) in sectionScrolls { page.isHidden = page !== scroll }
        scroll.isHidden = false
        currentScroll = scroll
    }

    /// Публичная семантика старого select сохранена:
    /// - другой раздел: мгновенно показываем уже созданную страницу;
    /// - тот же раздел: не уничтожаем UI в обработчике, а объединяем запросы в одну перестройку.
    private func select(_ section: Section) {
        let sameSection = currentSection == section
        currentSection = section
        UserDefaults.standard.set(section.rawValue, forKey: "settings.lastSection")
        updateSidebarSelection(section)

        if sameSection {
            requestSectionReload(section)
        } else {
            showSection(section)
        }
    }

    private func requestSectionReload(_ section: Section, delay: TimeInterval = 0.06) {
        dirtySections.insert(section)
        reloadWorkItems[section]?.cancel()
        guard currentSection == section else { return }

        let item = DispatchWorkItem { [weak self] in
            self?.reloadSectionNow(section, preserveScroll: true)
        }
        reloadWorkItems[section] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func reloadSectionNow(_ section: Section, preserveScroll: Bool) {
        reloadWorkItems[section]?.cancel()
        reloadWorkItems[section] = nil

        let old = sectionScrolls[section]
        let savedY = preserveScroll ? (old?.contentView.bounds.origin.y ?? 0) : 0
        let replacement = makeSectionScroll(section)
        sectionScrolls[section] = replacement
        dirtySections.remove(section)

        if currentSection == section {
            installSectionScrollIfNeeded(replacement)
            for (_, page) in sectionScrolls { page.isHidden = page !== replacement }
            replacement.isHidden = false
            currentScroll = replacement
            replacement.layoutSubtreeIfNeeded()
            if savedY > 0, let doc = replacement.documentView {
                let maxY = max(0, doc.fittingSize.height - replacement.contentView.bounds.height)
                replacement.contentView.scroll(to: NSPoint(x: 0, y: min(savedY, maxY)))
                replacement.reflectScrolledClipView(replacement.contentView)
            }
        }
        old?.removeFromSuperview()
    }

    private func invalidateAllSections() {
        for section in Section.allCases { dirtySections.insert(section) }
        for item in reloadWorkItems.values { item.cancel() }
        reloadWorkItems.removeAll()
        for item in asyncWorkItems.values { item.cancel() }
        asyncWorkItems.removeAll()
        asyncWorkSections.removeAll()
    }

    private func cancelAsyncWork(for section: Section) {
        let keys = asyncWorkSections.compactMap { $0.value == section ? $0.key : nil }
        for key in keys {
            asyncWorkItems[key]?.cancel()
            asyncWorkItems[key] = nil
            asyncWorkSections[key] = nil
            asyncGeneration[key, default: 0] += 1
        }
    }

    /// Тяжёлые system tools не блокируют AppKit. Одинаковый key отменяет ожидающую предыдущую
    /// загрузку; version не позволяет старому результату заменить уже перестроенную страницу.
    private func asyncSection<T>(_ section: Section,
                                 key: String,
                                 fetch: @escaping () -> T,
                                 build: @escaping (T) -> NSView) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: L("Загрузка…"))
        label.font = Design.Font.callout
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [spinner, label])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            container.trailingAnchor.constraint(greaterThanOrEqualTo: row.trailingAnchor),
            container.bottomAnchor.constraint(greaterThanOrEqualTo: row.bottomAnchor, constant: 4),
        ])

        asyncWorkItems[key]?.cancel()
        asyncGeneration[key, default: 0] += 1
        let generation = asyncGeneration[key] ?? 0
        let buildVersion = sectionBuildVersion[section] ?? 0
        asyncWorkSections[key] = section

        let work = DispatchWorkItem { [weak self, weak container] in
            let data = fetch()
            DispatchQueue.main.async {
                guard let self, let container else { return }
                guard self.asyncGeneration[key] == generation,
                      self.sectionBuildVersion[section] == buildVersion else { return }

                let real = build(data)
                self.stabilizeH(real)
                real.translatesAutoresizingMaskIntoConstraints = false
                container.subviews.forEach { $0.removeFromSuperview() }
                container.addSubview(real)
                NSLayoutConstraint.activate([
                    real.topAnchor.constraint(equalTo: container.topAnchor),
                    real.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    real.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    real.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                ])
                self.asyncWorkItems[key] = nil
                container.needsLayout = true
                container.superview?.needsLayout = true
            }
        }
        asyncWorkItems[key] = work
        DispatchQueue.global(qos: .utility).async(execute: work)

        let wrap = NSStackView(views: [container])
        wrap.orientation = .vertical
        wrap.alignment = .width
        wrap.spacing = 0
        wrap.translatesAutoresizingMaskIntoConstraints = false
        return wrap
    }

    private func lazyDisclosure(key: String, title: String, builder: @escaping () -> NSView) -> NSView {
        let expanded = disclosureState[key] ?? false
        return LazyDisclosureView(title: title, expanded: expanded, onStateChange: { [weak self] on in
            self?.disclosureState[key] = on
        }, builder: builder)
    }

    // MARK: секции

    private static let menuExtraDefs: [(id: String, label: String)] = [
        ("watts",   "Ватты (потребление)"),
        ("cputemp", "Температура CPU"),
        ("gputemp", "Температура GPU"),
        ("fan",     "Вентилятор (об/мин)"),
        ("cpu",     "Загрузка CPU"),
        ("ram",     "Память (RAM)"),
        ("net",     "Сеть (↓↑ скорость)"),
        ("clock",   "Часы (время)"),
        ("date",    "Дата (день)"),
        ("diskio",  "Диск (R/W скорость)"),
        ("diskfree", "Диск (свободно)"),
        ("btbatt",  "Bluetooth (заряд)"),
    ]

    /// Мгновенно применить настройки строки меню (без перезапуска): будит наблюдателя в AppDelegate,
    /// тот сбрасывает кэш рендера и перерисовывает строку меню сейчас же.
    private func applyMenuBarLive() {
        NotificationCenter.default.post(name: Notification.Name("BMMenuBarChanged"), object: nil)
    }

    /// Стандартная SF-иконка для каждого доп-показателя строки меню (нативный вид macOS).
    private func menuExtraIcon(_ id: String) -> String {
        switch id {
        case "watts":    return "bolt.fill"
        case "cputemp":  return "thermometer.medium"
        case "gputemp":  return "thermometer.high"
        case "fan":      return "fanblades"
        case "cpu":      return "cpu"
        case "ram":      return "memorychip"
        case "net":      return "arrow.up.arrow.down"
        case "clock":    return "clock"
        case "date":     return "calendar"
        case "diskio":   return "internaldrive"
        case "diskfree": return "externaldrive"
        case "btbatt":   return "dot.radiowaves.right"
        default:         return "circle"
        }
    }

    /// Группа «Горячая клавиша»: глобальный хоткей вызова поповера (Carbon, ⌥⌘B по умолчанию).
    /// Включить/выключить + мини-рекордер аккорда + сброс к дефолту. Перерегистрация — живая.

    private func reapplyPopoverHotkey() {
        GlobalHotkey.shared.apply(
            enabled: SettingsStore.popoverHotkeyEnabled,
            keyCode: SettingsStore.popoverHotkeyKeyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(SettingsStore.popoverHotkeyMods)))
    }

    // MARK: — Утилиты секций (шапки, заметки, иконки-лейблы)

    /// Шапка группы (выделенный заголовок секции внутри scaffold).
    private func groupHeader(_ s: String) -> SKGroupHeader { SKGroupHeader(s) }

    /// Подпись-примечание (caption, вторичный цвет). Тянется по ширине контейнера.
    private func note(_ s: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: s)
        l.font = Design.Font.caption; l.textColor = .secondaryLabelColor
        l.lineBreakMode = .byWordWrapping; l.maximumNumberOfLines = 4
        return l
    }

    /// Иконка + текст в ряд (компактный бейдж).
    private func iconLabel(_ symbol: String, _ text: String, tint: NSColor,
                           size: CGFloat = 13, weight: NSFont.Weight = .medium) -> NSView {
        let iv = NSImageView()
        iv.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iv.contentTintColor = tint
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: 15).isActive = true
        iv.heightAnchor.constraint(equalToConstant: 15).isActive = true
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight); l.textColor = tint
        let row = NSStackView(views: [iv, l]); row.spacing = 6; row.alignment = .centerY
        return row
    }

    /// Группа «Night Shift»: открытый, находимый регулятор теплоты + включить/держать.
    /// Раньше теплоту можно было менять лишь в спрятанном right-click подменю грубыми пресетами.
    /// Логика применения зеркалит setNightStrength из меню: пишем стор, затем
    /// enableNow(strength:) когда включён/держим, иначе setStrength — теплота применяется вживую.
    private func buildNightGroup() -> [NSView] {
        nightStrengthLabel = nil
        guard NightShift.available else { return [] }
        return [
            groupHeader(L("Night Shift")),
            SK.card([
                SK.sliderRow(icon: "thermometer.sun", title: L("Теплота"), min: 0, max: 100,
                             value: Double((SettingsStore.nightStrength * 100).rounded()), ticks: 0, unit: "%") { v, label in
                    let pct = Int(v.rounded())
                    let f = Float(pct) / 100
                    SettingsStore.nightStrength = f
                    label.stringValue = "\(pct)%"
                    if NightShift.isOn || SettingsStore.nightKeepOn { NightShift.enableNow(strength: f) } else { NightShift.setStrength(f) }
                },
                SK.infoRow(icon: "arrow.left.and.right", text: L("прохладнее ← теплее — применяется вживую")),
                SK.toggleRow(icon: "moon.circle", title: L("Включён сейчас"),
                             isOn: NightShift.isOn) { [weak self] on in
                    if on != NightShift.isOn { NightShift.toggle() }
                    self?.select(.input)                       // отразить фактическое состояние в обоих свитчах
                },
                SK.toggleRow(icon: "lock", title: L("Держать всегда включённым"),
                             isOn: SettingsStore.nightKeepOn) { [weak self] on in
                    SettingsStore.nightKeepOn = on
                    if on { NightShift.enableNow() }
                    self?.select(.input)                       // «Держать вкл.» включает Night Shift → свитч «Включён сейчас» должен подтянуться
                },
            ]),
            SK.infoRow(icon: "info.circle", text: L("Теплота применяется вживую. По умолчанию было «сильно» — теперь её можно плавно настроить под себя.")),
        ]
    }

    /// Группа «Здоровье батареи»: режим заряда (лимит/парус), защита от перегрева, top-up.
    /// Реактивно пересобирается через select(.general) при смене режима/чекбокса.
    /// Все действия пишут полный charge-limit.json (writeChargeConfigJSON) и Pro-гейтятся в хендлерах.

    /// Слайдер-строка для парусных порогов/температуры (гибкая ширина). Обновляет ОБЕ парусные метки
    /// (перекрёстно, как setSailThreshold) либо температурную. valLabel — уже созданный аутлет-лейбл.
    private func sailSliderRow(_ title: String, value: Int, min: Double, max: Double, ticks: Int,
                               top: Bool, valLabel: NSTextField, isHeat: Bool = false) -> NSView {
        let slider = KSlider.make(min: min, max: max, value: Double(value), ticks: ticks) { [weak self] v in
            guard let self else { return }
            if isHeat {
                SettingsStore.heatTemp = Int(v.rounded())
                self.heatTempLabel?.stringValue = String(format: "%d°", SettingsStore.heatTemp)
                self.writeChargeConfigJSON()
            } else {
                let r = ChargeControl.setSailThreshold(Int(v.rounded()), top: top)
                self.sailUpperLabel?.stringValue = String(format: "%d%%", r.upper)
                self.sailLowerLabel?.stringValue = String(format: "%d%%", r.lower)
                // при клампе полосы (≥5) двигаем и ПОЛЗУНОК соседнего порога, не только его подпись
                self.sailUpperSlider?.doubleValue = Double(r.upper)
                self.sailLowerSlider?.doubleValue = Double(r.lower)
            }
        }
        if !isHeat { if top { sailUpperSlider = slider } else { sailLowerSlider = slider } }
        slider.setContentHuggingPriority(.init(1), for: .horizontal)
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        valLabel.font = Design.Font.numericBody; valLabel.textColor = .secondaryLabelColor
        valLabel.alignment = .right; valLabel.translatesAutoresizingMaskIntoConstraints = false
        valLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let t = NSTextField(labelWithString: title); t.font = Design.Font.body
        t.setContentCompressionResistancePriority(.required, for: .horizontal)
        t.setContentHuggingPriority(.required, for: .horizontal)
        let hs = NSStackView(views: [t, slider, valLabel])
        hs.orientation = .horizontal; hs.alignment = .centerY; hs.spacing = 12
        hs.translatesAutoresizingMaskIntoConstraints = false
        let wrap = NSView(); wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(hs)
        NSLayoutConstraint.activate([
            hs.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: SK.inset),
            hs.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -SK.inset),
            hs.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
            wrap.heightAnchor.constraint(greaterThanOrEqualToConstant: SK.rowHeight),
        ])
        return wrap
    }

    /// Дата с временем из минуты локального дня (для NSDatePicker; дата-часть не важна, показываем только время).
    private static func dateFromMinute(_ m: Int) -> Date {
        var c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        c.hour = m / 60; c.minute = m % 60; c.second = 0
        return Calendar.current.date(from: c) ?? Date()
    }
    private static func minuteFromDate(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    /// Плановый дозаряд (чекбокс): включение — Pro-гейт; пересборка обновляет доступность time/lead.
    @objc private func alarmTimeChanged(_ s: NSDatePicker) {
        ChargeControl.setAlarm(on: SettingsStore.chargeAlarmOn, targetMin: Self.minuteFromDate(s.dateValue))
    }
    @objc private func alarmLeadChanged(_ s: NSPopUpButton) {
        let leads = [30, 45, 60, 90, 120]
        ChargeControl.setAlarm(on: SettingsStore.chargeAlarmOn, leadMin: leads[max(0, min(leads.count - 1, s.indexOfSelectedItem))])
    }

    // MARK: секция «Уведомления» — пороговые алерты (Free: видит и предупреждает)
    /// Секция «Уведомления» — переверстана на стеклянный кит (SettingsKit): карточки гибкой ширины, живые
    /// свитчи/слайдеры, порог+авто-ответ раскрываются ТОЛЬКО у включённого правила (тише, без простыни).
    /// Сохранено: tag=index на AlertKind.allCases, Pro-гейт requirePro(.fans), select(.netsec)-перестройка
    /// для show/hide, все вызовы AlertsEngine/FirstConnAlert.
    private func alertIcon(_ k: AlertKind) -> String {
        switch k {
        case .cpuTemp:     return "cpu"
        case .gpuTemp:     return "thermometer.high"
        case .batteryLow:  return "battery.25"
        case .batteryFull: return "battery.100.bolt"
        case .cpuLoad:     return "gauge.with.dots.needle.67percent"
        }
    }

    // MARK: секция «Поповер» — модули (показ/скрытие + порядок) и быстрые переключатели
    private func arrowBtn(_ symbol: String, _ action: Selector, _ tag: Int, enabled: Bool) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.bezelStyle = .rounded; b.controlSize = .small; b.tag = tag; b.isEnabled = enabled
        b.toolTip = ["arrow.up": L("Поднять выше"), "arrow.down": L("Опустить ниже"), "trash": L("Удалить")][symbol]
        return b
    }
    private func notifyPopoverChanged(immediate: Bool = false) {
        popoverNotifyWorkItem?.cancel()
        let item = DispatchWorkItem {
            NotificationCenter.default.post(name: Notification.Name("BMPopoverChanged"), object: nil)
        }
        popoverNotifyWorkItem = item
        if immediate { DispatchQueue.main.async(execute: item) }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item) }
    }

    // MARK: секция «Переключатели» — встроенные + свои кнопки-команды
    private func toggleTitle(_ id: String) -> String {
        if id.hasPrefix("custom:") {
            let cid = String(id.dropFirst("custom:".count))
            return "★ " + (SettingsStore.customToggles.first { $0.id == cid }?.label ?? L("Своя кнопка"))
        }
        return QuickToggleRegistry.def(id)?.label ?? id
    }

    /// Любой активный режим заряда требует демона (для применения BCLM). Единый источник — ChargeControl.
    private var chargeActive: Bool { ChargeControl.isActive }
    /// Ставит демон через системный диалог пароля, если он ещё не установлен и просят активный режим.
    private func installChargeHelperIfNeeded() {
        guard !fanDaemonInstalled else { return }
        let a = NSAlert()
        a.messageText = L("Включить лимит заряда")
        a.informativeText = L("Лимит сохранён. Для применения нужен системный root-демон (ставится один раз через системный диалог пароля).")
        a.addButton(withTitle: L("Установить и включить")); a.addButton(withTitle: L("Отмена"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let r = HelperInstall.runPrivileged("install-fan-helper.sh", prompt: L("Kelvin устанавливает демон лимита заряда"))
        refreshFanDaemonRow()
        if HelperInstall.presentFailureIfNeeded(r, title: L("Не удалось включить лимит")) {
            let done = NSAlert(); done.messageText = L("Готово")
            done.informativeText = L("Лимит заряда активен.")
            done.runModal()
        }
    }
    /// Публичная обёртка над installChargeHelperIfNeeded — чтобы общий ChargeControl
    /// (вызываемый и из поповера) мог поставить демон, не открывая приватный метод с его UI.
    func ensureChargeHelper() { installChargeHelperIfNeeded() }
    /// Пишет полный charge-limit.json. Единый путь записи теперь в ChargeControl.writeJSON()
    /// (тот же JSON, общий с поповером); метод оставлен тонкой обёрткой для остальных
    /// хендлеров заряда (защита от перегрева, порог °C), чьё поведение не меняется.
    private func writeChargeConfigJSON() { ChargeControl.writeJSON() }

    // MARK: — Автозапуск (login items X-ray) — влит в «Основные» блоком «Программы при входе».
    /// Возвращает карточки списка (без внешнего scaffold) — их встраивает buildBasics.
    private func startupItems(_ result: LoginItems.ScanResult) -> [NSView] {
        var items: [NSView] = []

        // — Крупная плашка-вердикт: режим просмотра, официальный тон —
        let total = result.items.count
        let verdict = NSTextField(wrappingLabelWithString: L("Только просмотр — Kelvin не изменяет объекты автозапуска"))
        verdict.font = Design.Font.calloutEmph
        verdict.textColor = .labelColor
        verdict.maximumNumberOfLines = 2
        let verdictIcon = NSImageView()
        verdictIcon.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        verdictIcon.contentTintColor = .systemBlue
        verdictIcon.symbolConfiguration = .init(pointSize: 22, weight: .semibold)
        verdictIcon.translatesAutoresizingMaskIntoConstraints = false
        verdictIcon.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let sub = NSTextField(labelWithString: total > 0
            ? String(format: L("Обнаружено объектов автозапуска: %d. Список доступен только для просмотра."), total)
            : L("Проверка программ, запускающихся при входе в систему."))
        sub.font = Design.Font.caption; sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byWordWrapping; sub.maximumNumberOfLines = 3
        let textCol = NSStackView(views: [verdict, sub])
        textCol.orientation = .vertical; textCol.alignment = .leading; textCol.spacing = 3
        let heroStack = NSStackView(views: [verdictIcon, textCol])
        heroStack.orientation = .horizontal; heroStack.alignment = .centerY; heroStack.spacing = 12
        items.append(SK.card([SK.customRow(heroStack, minHeight: 56)]))

        if result.items.isEmpty && result.skipped == 0 {
            items.append(SK.card([SK.infoRow(icon: "checkmark.seal",
                text: L("Объекты автозапуска не обнаружены."),
                tint: .systemGreen)]))
        } else {
            // — Мини-легенда: значения бейджей (только если есть что расшифровывать — иначе сирота при items.isEmpty && skipped>0) —
            if !result.items.isEmpty {
                items.append(SK.card([
                    SK.infoRow(icon: "bolt.fill",
                        text: L("«При загрузке» — программа запускается автоматически при входе в систему."),
                        tint: .systemOrange),
                    SK.infoRow(icon: "moon.zzz",
                        text: L("«Отключено» — объект помечен как неактивный и не запускается."),
                        tint: .tertiaryLabelColor),
                ]))
            }

            // — Списки по расположению, официальными заголовками —
            let groups: [(LoginItems.Scope, String, String)] = [
                (.userAgent,    L("Объекты пользователя"),        "person"),
                (.globalAgent,  L("Для всех пользователей"),       "person.2"),
                (.systemDaemon, L("Системные службы"),             "gearshape.2"),
            ]
            for (scope, header, icon) in groups {
                let g = result.items.filter { $0.scope == scope }
                guard !g.isEmpty else { continue }
                let hint: String
                switch scope {
                case .userAgent:    hint = L("Установлены вами или вашими программами; хранятся в домашней папке пользователя.")
                case .globalAgent:  hint = L("Запускаются для всех учётных записей этого Mac.")
                case .systemDaemon: hint = L("Работают в фоне до входа в систему; обычно относятся к установленным программам.")
                }
                items.append(groupHeader(String(format: L("%@ · %d"), header, g.count)))
                var rows: [NSView] = [SK.infoRow(icon: icon, text: hint)]
                rows.append(contentsOf: g.map { self.startupRow($0) })
                items.append(SK.card(rows))
            }

            // честно: не выдаём (count) за полный каталог, если часть файлов не прочли (root-only/битые)
            if result.skipped > 0 {
                items.append(SK.card([SK.infoRow(icon: "exclamationmark.lock",
                    text: String(format: L("Не удалось прочитать файлов: %d (требуются права root или файлы повреждены). В списке они не показаны."), result.skipped),
                    tint: .tertiaryLabelColor)]))
            }
        }

        // — Честная граница, свёрнута в «Что не отображается и почему» —
        items.append(groupHeader(L("Подробнее")))
        items.append(SK.card([
            SK.disclosure(title: L("Что не отображается и почему"), expanded: false, rows: [
                SK.infoRow(icon: "apple.logo",
                    text: L("Системные службы Apple (каталог /System) не отображаются.")),
                SK.infoRow(icon: "app.badge",
                    text: L("Объекты входа обычных приложений находятся в разделе «Основные».")),
                SK.infoRow(icon: "clock.arrow.circlepath",
                    text: L("Устаревшие механизмы автозапуска (cron, login-хуки) здесь не считываются.")),
                SK.infoRow(icon: "lock.shield",
                    text: L("«При загрузке» и «отключено» — значения из файла конфигурации. Точное состояние доступно только при полном доступе к диску, который Kelvin не запрашивает.")),
            ]),
        ]))

        return items
    }

    private func startupRow(_ it: LoginItems.Item) -> NSView {
        // Гибкая строка (без жёсткой 440-ширины — та в SK.card роняла офскрин-вёрстку):
        // имя+путь слева (SK.controlRow), бейдж состояния + стеклянная «Показать» справа.
        var trailing: [NSView] = []
        if it.disabled {
            trailing.append(iconLabel("moon.zzz", L("отключено"), tint: .tertiaryLabelColor, size: 11))
        } else if it.runAtLoad {
            trailing.append(iconLabel("bolt.fill", L("при загрузке"), tint: .systemOrange, size: 11))
        }
        let reveal = GlassButton(title: L("Показать файл"), symbol: "arrow.up.forward.app", cornerRadius: Design.Radius.chip)
        reveal.onClick = { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: it.path)]) }
        trailing.append(reveal)
        let tstack = NSStackView(views: trailing)
        tstack.orientation = .horizontal; tstack.alignment = .centerY; tstack.spacing = 8
        let r = SK.controlRow(icon: it.disabled ? "powersleep" : "app.badge.checkmark",
                              title: it.name, subtitle: it.program.isEmpty ? L("путь к программе не указан") : it.program, control: tstack)
        if it.disabled { r.alphaValue = 0.6 }
        return r
    }


    // MARK: — Журнал сети (session connection log) — куда Mac звонил за сессию

private func netLogRow(_ e: AppSession.LedgerEntry, _ df: DateFormatter) -> NSView {
        let flag = e.code == nil ? "\u{1F310}" : GeoIP.flag(e.code!)

        // — левая колонка: флаг+программа, под ней адрес —
        let name = NSTextField(labelWithString: flag + "  " + e.app)
        name.font = Design.Font.body; name.lineBreakMode = .byTruncatingTail
        let ep = NSTextField(labelWithString: e.endpoint)
        ep.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular); ep.textColor = .tertiaryLabelColor
        ep.lineBreakMode = .byTruncatingMiddle
        ep.translatesAutoresizingMaskIntoConstraints = false
        ep.widthAnchor.constraint(lessThanOrEqualToConstant: 250).isActive = true
        let info = NSStackView(views: [name, ep]); info.orientation = .vertical; info.alignment = .leading; info.spacing = 1

        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        // — правая колонка: по-человечески «×N раз» и «в HH:MM» + всплывашка с объяснением —
        let last = df.string(from: e.last)
        let stat = NSTextField(labelWithString: String(format: L("×%d раз · в %@"), e.count, last))
        stat.font = .systemFont(ofSize: 10); stat.textColor = .secondaryLabelColor
        stat.alignment = .right
        stat.toolTip = String(format: L("Видели %d раз(а) в снимках; последний раз в %@. «×N» ≈ как долго соединение было открыто, а не сколько данных прошло."), e.count, last)

        let row = NSStackView(views: [info, spacer, stat]); row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
        row.setContentHuggingPriority(.init(1), for: .horizontal)
        return SK.customRow(row, minHeight: 34)
    }

    // MARK: вентиляторы
    private var editorArea = NSStackView()
    private var draft = SettingsStore.customFanProfile
    private var fanPreview = NSTextField(labelWithString: "")
    private weak var fanProfilePopup: NSPopUpButton?     // переполняем при add/rename/delete
    private weak var chargeReadout: NSTextField?         // живой % заряда в карточке «Аккумулятор»
    private var thermalNowLabels: [AlertKind: NSTextField] = [:]   // живое «сейчас X°/X%» у тепловых правил
    private weak var curveView: FanCurveView?            // канвас кривой активного редактора (бегущий t°-маркер)
    private var perFanIndex = 0                          // какой вент правим в per-fan режиме (индекс)
    private var editingSensorKeys: [String] = []         // датчики настройки, открытой в канвасе (для t°-маркера)


    /// Список профилей для пикеров автоматики: встроенные + пользовательские; выбор по id (без «+ Новый»).
    private func fillProfileChoices(_ popup: NSPopUpButton, selected: String) {
        popup.removeAllItems()
        for id in SettingsStore.builtinFanIDs { addFanItem(popup, title: SettingsStore.builtinFanDisplay(id), id: id) }
        let users = SettingsStore.userFanPresets.map { $0.name }
        if !users.isEmpty { popup.menu?.addItem(.separator()); for name in users { addFanItem(popup, title: name, id: name) } }
        selectFanItem(popup, id: selected)
    }
    @objc private func fanACChanged(_ s: NSPopUpButton) {
        if let id = s.selectedItem?.representedObject as? String { SettingsStore.fanProfileAC = id; applyCurrentSourceIfAuto() }
    }
    @objc private func fanBatteryChanged(_ s: NSPopUpButton) {
        if let id = s.selectedItem?.representedObject as? String { SettingsStore.fanProfileBattery = id; applyCurrentSourceIfAuto() }
    }
    /// Немедленно применить профиль ТЕКУЩЕГО источника (при включении/смене выбора), если автоматика активна.
    /// isPro тут ОБЯЗАТЕЛЕН — симметрично tick-пути: иначе истёкший триал форсил бы кулеры через пикеры.
    private func applyCurrentSourceIfAuto() {
        guard SettingsStore.fanAutoBySource, Licensing.shared.isPro, FanController.daemonInstalled else { return }
        if AlertsEngine.shared.isBoostActive { return }                       // не перебивать аварийный форс кулеров
        let ext = BatteryReader.read()?.external ?? true
        FanController.applyProfileHeadless(named: ext ? SettingsStore.fanProfileAC : SettingsStore.fanProfileBattery)
    }

    private func fanDaemonRow() -> NSView {
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let status = NSTextField(labelWithString: ""); status.font = Design.Font.caption
        let line = NSStackView(views: [icon, status]); line.spacing = 5; line.alignment = .centerY
        let btn = NSButton(title: "", target: self, action: #selector(toggleFanDaemon))
        btn.bezelStyle = .rounded; btn.controlSize = .small
        fanStatusLabel = status; fanStatusIcon = icon; fanToggleBtn = btn
        let s = NSStackView(views: [line, btn]); s.orientation = .vertical; s.alignment = .leading; s.spacing = 6
        refreshFanDaemonRow()                       // заполнит иконку/текст/кнопку по факту установки
        return s
    }
    private func refreshFanDaemonRow() {
        let on = fanDaemonInstalled
        fanStatusIcon?.image = NSImage(systemSymbolName: on ? "checkmark.circle.fill" : "circle.dashed", accessibilityDescription: nil)
        fanStatusIcon?.contentTintColor = on ? .systemGreen : .secondaryLabelColor
        fanStatusLabel?.stringValue = on ? L("Управление установлено (демон активен)") : L("Только мониторинг (демон не установлен)")
        fanStatusLabel?.textColor = on ? .systemGreen : .secondaryLabelColor
        fanToggleBtn?.title = on ? L("Отключить управление…") : L("Установить управление…")
    }
    @objc private func toggleFanDaemon() {
        let installing = !fanDaemonInstalled
        if installing, !requirePro(.fans) { return }            // установка управления — Pro
        let confirm = NSAlert()
        confirm.messageText = installing ? L("Установить управление вентиляторами") : L("Отключить управление вентиляторами")
        confirm.informativeText = installing
            ? L("Поставит root-демон управления вентиляторами через системный диалог пароля (один раз). Защита: перегрев → максимум; «Авто», удаление демона или пропажа приложения → системный режим.")
            : L("Удалит демон и вернёт системный авто-режим (понадобится пароль).")
        confirm.addButton(withTitle: installing ? L("Установить") : L("Отключить"))
        confirm.addButton(withTitle: L("Отмена"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        let r = HelperInstall.runPrivileged(installing ? "install-fan-helper.sh" : "uninstall-fan-helper.sh",
                                            prompt: installing ? L("Kelvin устанавливает управление вентиляторами") : L("Kelvin отключает управление вентиляторами"))
        refreshFanDaemonRow()
        if HelperInstall.presentFailureIfNeeded(r, title: installing ? L("Не удалось установить") : L("Не удалось отключить")) {
            let done = NSAlert(); done.messageText = L("Готово")
            done.informativeText = installing ? L("Управление вентиляторами установлено и запущено.") : L("Управление отключено — системный авто-режим.")
            done.runModal()
        }
        select(.power)   // состояние демона изменилось — пересобрать пилюли/кнопку/инфо секции
    }

    private func sectionHead(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s.uppercased())
        l.font = .systemFont(ofSize: 9, weight: .semibold); l.textColor = .tertiaryLabelColor
        return l
    }

    /// Текущее значение датчика тепловго правила — «сейчас 54°» / «сейчас 62%» (nil-безопасно → «—»).
    private func thermalNowText(_ kind: AlertKind) -> String {
        switch kind {
        case .cpuTemp:
            if let t = FanController.temp("TC0E") ?? FanController.leadingTemp(["TCXC", "TC0P"]) { return String(format: L("сейчас %.0f°"), t) }
        case .gpuTemp:
            if let t = FanController.temp("TG0D") ?? FanController.temp("TCGC") { return String(format: L("сейчас %.0f°"), t) }
        case .batteryLow, .batteryFull:
            if let p = BatteryReader.systemChargePercent() { return String(format: L("сейчас %d%%"), p) }
        case .cpuLoad:
            break
        }
        return L("сейчас —")
    }

    /// Краткая строка заряда для героя: «Заряд 62% · лимит 80%» / «поддержание 50–80%» / «без ограничений».
    private func fanChargeSummary(_ pct: Int?) -> String {
        let head = pct.map { String(format: L("Заряд %d%%"), $0) } ?? L("Заряд —")
        let tail: String
        switch SettingsStore.chargeMode {
        case "sail": tail = String(format: L("поддержание %d–%d%%"), SettingsStore.sailLower, SettingsStore.sailUpper)
        default:     tail = SettingsStore.chargeLimit < 100 ? String(format: L("лимит %d%%"), SettingsStore.chargeLimit) : L("без ограничений")
        }
        return head + " · " + tail
    }

    /// Мгновенное применение активного профиля к железу БЕЗ модалки — если управление включено (демон
    /// стоит) и есть Pro. Иначе no-op: профиль лишь сохраняется как предпочтение, включение — через applyProfile().
    private func applyLiveIfControlled() {
        guard fanDaemonInstalled else { return }
        let profile = activeDraft()
        if profile.mode != .auto, !Licensing.shared.isPro { return }

        // Drag слайдера больше не пишет JSON десятки раз в секунду. Последнее значение
        // применяется после короткой паузы, визуальный preview при этом остаётся мгновенным.
        fanApplyWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.writeProfileJSON(profile) }
        fanApplyWorkItem = item
        settingsWriteQueue.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    /// Сентинел «+ Новый профиль…» — служебный пункт (id = nil в representedObject).
    private static let newFanSentinelID = "\u{0}new"

    /// Добавляет пункт с локализуемым заголовком и СТАБИЛЬНЫМ id в representedObject (B2).
    private func addFanItem(_ popup: NSPopUpButton, title: String, id: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = id
        popup.menu?.addItem(item)
    }
    /// Заполняет пикер: встроенные (id) + (если есть) пользовательские (имя=id) + сентинел «+ Новый профиль…».
    private func populateFanPopup(_ popup: NSPopUpButton) {
        popup.removeAllItems()
        for id in SettingsStore.builtinFanIDs { addFanItem(popup, title: SettingsStore.builtinFanDisplay(id), id: id) }
        let users = SettingsStore.userFanPresets.map { $0.name }
        if !users.isEmpty {
            popup.menu?.addItem(.separator())
            for name in users { addFanItem(popup, title: name, id: name) }   // userPreset: имя = id
        }
        popup.menu?.addItem(.separator())
        addFanItem(popup, title: L("+ Новый профиль…"), id: Self.newFanSentinelID)
        selectFanItem(popup, id: SettingsStore.activeFanProfileName)
    }
    /// Выбирает пункт по СТАБИЛЬНОМУ id (representedObject), не по заголовку (B2 — устойчиво к локали).
    private func selectFanItem(_ popup: NSPopUpButton, id: String) {
        if let item = popup.menu?.items.first(where: { ($0.representedObject as? String) == id }) {
            popup.select(item)
        } else {
            selectFanItem(popup, id: "auto")   // повреждённый/неизвестный id → безопасный дефолт
        }
    }
    private func refreshFanPopupAndEditor() {
        if let p = fanProfilePopup { populateFanPopup(p) }
        rebuildEditor(); updatePreview()
    }
    /// Является ли активный профиль пользовательским (редактируемым) пресетом.
    private func activeUserPresetIndex() -> Int? {
        SettingsStore.userFanPresets.firstIndex { $0.name == SettingsStore.activeFanProfileName }
    }

    private func activeDraft() -> FanProfile {
        // Матч по СТАБИЛЬНОМУ id (B2). Внутреннее FanProfile.name сохраняем русским — это метка для
        // JSON демона/легаси и она ему не важна (декодит по полям); id-развязка живёт на уровне пикера.
        switch SettingsStore.activeFanProfileName {
        case "quiet":   return FanProfile(name: "Тихий", mode: .constant, rpm: 2200)
        case "balance": return FanProfile(name: "Баланс", mode: .curve, sensorKey: "TC0P", tempLow: 42, tempHigh: 72, alertTemp: 98)
        case "turbo":   return FanProfile(name: "Турбо", mode: .constant, rpm: 9999)
        case "auto":    return .auto
        default:
            if let p = SettingsStore.userFanPresets.first(where: { $0.name == SettingsStore.activeFanProfileName }) { return p }
            return .auto
        }
    }


    private func rebuildEditor() {
        editorArea.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let id = SettingsStore.activeFanProfileName    // СТАБИЛЬНЫЙ id (B2)
        switch id {
        case "auto":
            editorArea.addArrangedSubview(note(L("Системный авто-режим. Приложение не вмешивается.")))
        case "quiet":
            editorArea.addArrangedSubview(note(L("Постоянные ~2200 об/мин. Тихо, но греется сильнее — следите за температурой.")))
        case "turbo":
            editorArea.addArrangedSubview(note(L("Максимальные обороты постоянно. Максимум охлаждения, шумно.")))
        case "balance":
            editorArea.addArrangedSubview(note(L("Плавная кривая по корпусу CPU: 42° → мин, 72° → макс. Алерт 98°.")))
        default:
            // пользовательский пресет — (если их несколько) выбор нужного + редактор кривой/оборотов + действия имени
            let userNames = SettingsStore.userFanPresets.map { $0.name }
            if userNames.count >= 2 {
                let cur = userNames.firstIndex(of: SettingsStore.activeFanProfileName) ?? 0
                let picker = KPopup.make(userNames, selected: cur) { [weak self] i in
                    guard let self, userNames.indices.contains(i) else { return }
                    SettingsStore.activeFanProfileName = userNames[i]
                    self.draft = self.activeDraft()
                    self.applyLiveIfControlled()
                    self.select(.power)
                }
                editorArea.addArrangedSubview(row(L("Профиль"), picker, ""))
            }
            buildCustomEditor()
            let rename = NSButton(title: L("Переименовать"), target: self, action: #selector(renamePreset))
            let dup    = NSButton(title: L("Дублировать"),   target: self, action: #selector(duplicatePreset))
            let del    = NSButton(title: L("Удалить"),       target: self, action: #selector(deletePreset))
            for b in [rename, dup, del] { b.bezelStyle = .rounded; b.controlSize = .small; b.font = Design.Font.caption }
            del.contentTintColor = .systemRed
            let actions = NSStackView(views: [rename, dup, del]); actions.spacing = 8
            editorArea.addArrangedSubview(actions)
        }
    }

    /// NSAlert с полем ввода имени; валидирует: непустое, не зарезервированное, уникальное.
    private func askName(_ title: String, suggestion: String) -> String? {
        let a = NSAlert(); a.messageText = title
        let field = NSTextField(string: suggestion)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: L("Сохранить")); a.addButton(withTitle: L("Отмена"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        // Занято, если имя = отображение/легаси-имя встроенного, ИЛИ = стабильный id встроенного
        // (иначе userPreset «quiet» затенился бы id-веткой switch — B2), ИЛИ = существующий userPreset.
        if SettingsStore.builtinFanNames.contains(name) || SettingsStore.isBuiltinFanID(name)
            || SettingsStore.userFanPresets.contains(where: { $0.name == name }) {
            let e = NSAlert(); e.messageText = L("Имя занято")
            e.informativeText = L("Выберите другое имя — это уже используется встроенным или вашим профилем.")
            e.runModal(); return nil
        }
        return name
    }

    @objc private func newPreset() {
        guard let name = askName(L("Сохранить как новый профиль"), suggestion: L("Мой профиль")) else {
            fanProfilePopup.map { selectFanItem($0, id: SettingsStore.activeFanProfileName) }; return
        }
        var p = draft; if p.mode == .auto { p.mode = .constant }; p.name = name   // новый профиль стартует с прямого слайдера оборотов
        if p.idleHandoffTemp == nil { p.idleHandoffTemp = 45 }                     // idle-отдача по умолчанию ВКЛ (решение владельца)
        // Движок читает idle per-fan → синхронизируем в perFan, иначе тумблер покажет ВКЛ, а факта нет (ревью L5).
        if p.perFan != nil { for i in p.perFan!.indices { p.perFan![i].idleHandoffTemp = p.idleHandoffTemp } }
        var ps = SettingsStore.userFanPresets; ps.append(p); SettingsStore.userFanPresets = ps
        SettingsStore.activeFanProfileName = name; draft = p
        refreshFanPopupAndEditor()
    }
    @objc private func duplicatePreset() {
        guard let i = activeUserPresetIndex() else { return }
        guard let name = askName(L("Дублировать профиль"), suggestion: SettingsStore.userFanPresets[i].name + " 2") else { return }
        var p = SettingsStore.userFanPresets[i]; p.name = name
        var ps = SettingsStore.userFanPresets; ps.append(p); SettingsStore.userFanPresets = ps
        SettingsStore.activeFanProfileName = name; draft = p
        select(.power)                                    // пересобрать пилюли/редактор — не только редактор
    }
    @objc private func renamePreset() {
        guard let i = activeUserPresetIndex() else { return }
        let old = SettingsStore.userFanPresets[i].name
        guard let name = askName(L("Переименовать профиль"), suggestion: old) else { return }
        var ps = SettingsStore.userFanPresets; ps[i].name = name; SettingsStore.userFanPresets = ps
        SettingsStore.activeFanProfileName = name; draft.name = name
        // не оставлять висячую ссылку автоматики по источнику на старое имя пресета
        if SettingsStore.fanProfileAC == old { SettingsStore.fanProfileAC = name }
        if SettingsStore.fanProfileBattery == old { SettingsStore.fanProfileBattery = name }
        select(.power)
    }
    @objc private func deletePreset() {
        guard let i = activeUserPresetIndex() else { return }
        let nm = SettingsStore.userFanPresets[i].name
        let c = NSAlert(); c.messageText = String(format: L("Удалить профиль «%@»?"), nm)
        c.informativeText = L("Это действие необратимо.")
        c.addButton(withTitle: L("Удалить")); c.addButton(withTitle: L("Отмена"))
        guard c.runModal() == .alertFirstButtonReturn else { return }
        let wasApplied = (SettingsStore.activeFanProfileName == nm)
        var ps = SettingsStore.userFanPresets; ps.remove(at: i); SettingsStore.userFanPresets = ps
        SettingsStore.activeFanProfileName = "auto"; draft = SettingsStore.customFanProfile   // id-дефолт (B2)
        // автоматика по источнику ссылалась на удалённый пресет — сбросить на «Авто», иначе висячая ссылка
        if SettingsStore.fanProfileAC == nm { SettingsStore.fanProfileAC = "auto" }
        if SettingsStore.fanProfileBattery == nm { SettingsStore.fanProfileBattery = "auto" }
        // если удаляемый профиль был применён живьём — вернуть авто, чтобы венты не зависли форсированными
        if wasApplied, fanDaemonInstalled { writeProfileJSON(.auto) }
        select(.power)                                    // пересобрать пилюли (активным стал «auto») + редактор
    }

    /// Редактор своего профиля (per-fan «по-полной»). Порядок: время разгона → idle-отдача (глоб.) →
    /// тумблер «настроить каждый вент отдельно» → настройка (глобальная или таб-бар вентиляторов) →
    /// алерт (глоб.). Настройку каждого вента строит buildSettingEditor через get/set — единый код и
    /// для глобального FanSetting, и для perFan[i]. Канвас FanCurveView заменяет прежние точки-слайдеры.
    private func buildCustomEditor() {
        let fanCount = FanController.fans().count
        editingSensorKeys = []; curveView = nil          // выставит buildSettingEditor, если покажет канвас

        // 1) Время разгона (глобально для профиля; slew живёт в демоне).
        let rampLabel = editorValueLabel(rampText(draft.rampTime))
        let ramp = KSlider.make(min: 0, max: 120, value: Double(draft.rampTime)) { [weak self, weak rampLabel] v in
            guard let self else { return }
            self.draft.rampTime = Int(v.rounded()); rampLabel?.stringValue = self.rampText(self.draft.rampTime)
            self.persistDraft(); self.applyLiveIfControlled()
        }
        ramp.widthAnchor.constraint(equalToConstant: 300).isActive = true
        editorArea.addArrangedSubview(editorRow(L("Время разгона"), ramp, rampLabel))
        editorArea.addArrangedSubview(note(L("Плавный набор и сброс оборотов за это время. Тише переключения; перегрев всё равно форсирует максимум мгновенно.")))

        // 2) Idle-отдача (глобальный порог; движок читает per-fan → синхронизируем в normalizeIdleIntoPerFan).
        let idleOn = (draft.idleHandoffTemp ?? 0) > 0
        editorArea.addArrangedSubview(editorToggleLine(L("Отдавать системе при простое"), on: idleOn) { [weak self] on in
            guard let self else { return }
            self.draft.idleHandoffTemp = on ? Swift.max(35, self.draft.idleHandoffTemp ?? 45) : nil
            self.normalizeIdleIntoPerFan(); self.persistDraft(); self.applyLiveIfControlled(); self.rebuildEditor()
        })
        if idleOn {
            let idleVal = editorValueLabel("\(draft.idleHandoffTemp ?? 45)°")
            let idle = KSlider.make(min: 30, max: 60, value: Double(draft.idleHandoffTemp ?? 45)) { [weak self, weak idleVal] v in
                guard let self else { return }
                self.draft.idleHandoffTemp = Int(v.rounded()); idleVal?.stringValue = "\(Int(v.rounded()))°"
                self.normalizeIdleIntoPerFan(); self.persistDraft(); self.applyLiveIfControlled()
            }
            idle.widthAnchor.constraint(equalToConstant: 300).isActive = true
            editorArea.addArrangedSubview(editorRow(L("Ниже температуры"), idle, idleVal))
            editorArea.addArrangedSubview(note(L("Пока ведущий датчик ниже порога — вентилятор отдаётся системе (на маках Apple может остановиться). Поднимется температура — управление вернётся.")))
        }

        // 3) Per-fan режим (только если вентиляторов больше одного).
        let perFanOn = (draft.perFan?.count ?? 0) == fanCount && fanCount > 1
        if fanCount > 1 {
            editorArea.addArrangedSubview(editorToggleLine(L("Настроить каждый вентилятор отдельно"), on: perFanOn) { [weak self] on in
                guard let self else { return }
                if on {
                    let base = self.draft.setting(forFan: 0)          // размножаем текущую настройку по всем вентам
                    self.draft.perFan = (0..<fanCount).map { _ in base }
                } else {
                    self.draft.perFan = nil
                }
                self.perFanIndex = 0
                self.persistDraft(); self.applyLiveIfControlled(); self.rebuildEditor()
            })
            editorArea.addArrangedSubview(note(L("По умолчанию все вентиляторы работают по одной настройке. На ноутбуках с общим радиатором раздельная настройка даёт малый эффект.")))
        }

        // 4) Настройка: глобальная либо таб-бар вентиляторов (perFan).
        if perFanOn, let pf = draft.perFan, pf.count == fanCount {
            let idx = Swift.min(perFanIndex, fanCount - 1)
            let tabs = PillTabBar(labels: (0..<fanCount).map { String(format: L("Вент %d"), $0 + 1) }, selected: idx)
            tabs.onSelect = { [weak self] i in self?.perFanIndex = i; self?.rebuildEditor() }
            tabs.translatesAutoresizingMaskIntoConstraints = false
            tabs.heightAnchor.constraint(equalToConstant: 28).isActive = true
            tabs.widthAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(fanCount) * 68).isActive = true
            editorArea.addArrangedSubview(tabs)
            buildSettingEditor(fanIndex: idx,
                               get: { [weak self] in self?.draft.perFan?[idx] ?? FanSetting() },
                               set: { [weak self] s in
                                   guard let self, var arr = self.draft.perFan, idx < arr.count else { return }
                                   arr[idx] = s; self.draft.perFan = arr
                               })
        } else {
            buildSettingEditor(fanIndex: 0,
                               get: { [weak self] in self?.globalSetting() ?? FanSetting() },
                               set: { [weak self] s in self?.applyGlobalSetting(s) })
        }

        // 5) Алерт (форс макс) — общий для профиля.
        let alertLabel = editorValueLabel("\(draft.alertTemp)°")
        let alert = KSlider.make(min: 80, max: 105, value: Double(draft.alertTemp)) { [weak self, weak alertLabel] v in
            guard let self else { return }
            self.draft.alertTemp = Int(v.rounded()); alertLabel?.stringValue = "\(self.draft.alertTemp)°"
            self.persistDraft(); self.applyLiveIfControlled(); self.updatePreview()
        }
        alert.widthAnchor.constraint(equalToConstant: 300).isActive = true
        editorArea.addArrangedSubview(editorRow(L("Алерт (форс макс)"), alert, alertLabel))
    }

    /// Редактор ОДНОЙ настройки (режим/датчики/кривая) через get/set — общий код для глобальной настройки
    /// и для конкретного вентилятора в per-fan режиме. Канвас FanCurveView правит кривую вживую (drag не
    /// рвётся: canvas.onChange не пересобирает редактор). Смена режима/датчиков — структурная → rebuildEditor.
    private func buildSettingEditor(fanIndex: Int, get: @escaping () -> FanSetting, set: @escaping (FanSetting) -> Void) {
        let s0 = get()
        let fans = FanController.fans()
        let fan = fans.first(where: { $0.index == fanIndex }) ?? fans.first
        let fmin = fan?.min ?? 1500, fmax = Swift.max((fan?.max ?? 6500), (fan?.min ?? 1500) + 1)

        // Режим настройки: по сенсору (кривая) или постоянные обороты.
        let modeBar = PillTabBar(labels: [L("По сенсору"), L("Постоянные")], selected: s0.mode == .constant ? 1 : 0)
        modeBar.onSelect = { [weak self] i in
            guard let self else { return }
            var s = get(); s.mode = (i == 1) ? .constant : .curve
            if s.mode == .curve, FanController.sanitizedPoints(s.curvePoints ?? []).count < 2 {
                s.curvePoints = self.seedCurve(min: fmin, max: fmax, low: s.tempLow, high: s.tempHigh)
            }
            set(s); self.persistDraft(); self.applyLiveIfControlled(); self.rebuildEditor()
        }
        modeBar.translatesAutoresizingMaskIntoConstraints = false
        modeBar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        modeBar.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        editorArea.addArrangedSubview(row(L("Режим"), modeBar, ""))

        if s0.mode == .constant {
            let valLabel = editorValueLabel("\(s0.rpm) " + L("об/мин"))
            let slider = KSlider.make(min: fmin, max: fmax, value: Double(s0.rpm)) { [weak self, weak valLabel] v in
                guard let self else { return }
                var s = get(); s.rpm = Int(v.rounded()); set(s)
                valLabel?.stringValue = "\(Int(v.rounded())) " + L("об/мин")
                self.persistDraft(); self.applyLiveIfControlled(); self.updatePreview()
            }
            slider.widthAnchor.constraint(equalToConstant: 300).isActive = true
            editorArea.addArrangedSubview(editorRow(L("Целевые обороты"), slider, valLabel))
            editorArea.addArrangedSubview(note(L("Постоянные обороты, зажатые пределами мин/макс этого вентилятора.")))
        } else {
            // Мульти-датчик (max-of): компактный дропдаун с галочками.
            let sensorBtn = sensorMenuButton(keys: s0.sensorKeys) { [weak self] newKeys in
                guard let self else { return }
                var s = get(); s.sensorKeys = newKeys.isEmpty ? ["TC0P"] : newKeys; set(s)
                self.persistDraft(); self.applyLiveIfControlled(); self.rebuildEditor()
            }
            editorArea.addArrangedSubview(row(L("Датчики"), sensorBtn, ""))
            editorArea.addArrangedSubview(note(L("Несколько датчиков → ведёт самый горячий (безопасно: не недоохладит). «CPU ядра» отзывчивее, «CPU корпус» спокойнее.")))

            // Канвас кривой: перетаскиваемые узлы + бегущий маркер текущей t°.
            var pts = FanController.sanitizedPoints(s0.curvePoints ?? [])
            if pts.count < 2 { pts = seedCurve(min: fmin, max: fmax, low: s0.tempLow, high: s0.tempHigh) }
            let canvas = FanCurveView()
            canvas.tempRange = 20...100
            canvas.rpmRange = fmin...fmax
            canvas.points = pts
            canvas.currentTemp = FanController.leadingTemp(s0.sensorKeys)
            canvas.onChange = { [weak self] newPts in
                guard let self else { return }
                var s = get(); s.curvePoints = newPts; set(s)
                self.persistDraft(); self.applyLiveIfControlled(); self.updatePreview()
            }
            canvas.translatesAutoresizingMaskIntoConstraints = false
            canvas.widthAnchor.constraint(equalToConstant: 420).isActive = true
            canvas.heightAnchor.constraint(equalToConstant: 160).isActive = true
            editingSensorKeys = s0.sensorKeys; curveView = canvas
            editorArea.addArrangedSubview(canvas)
            editorArea.addArrangedSubview(note(L("Тяните узлы: температура → обороты. Кривая только растёт (горячее не медленнее). Оранжевая линия — текущая температура ведущего датчика.")))
        }
    }

    // MARK: — вспомогательные для редактора профиля вентиляторов —

    private func rampText(_ s: Int) -> String { s <= 0 ? L("мгновенно") : String(format: L("%d с"), s) }

    /// Компактная строка-тумблер внутри editorArea (не карточная): подпись слева, KSwitch справа.
    private func editorToggleLine(_ title: String, on: Bool, onChange: @escaping (Bool) -> Void) -> NSView {
        let l = NSTextField(labelWithString: title); l.font = Design.Font.caption
        let sw = KSwitch(on: on); sw.onChange = onChange
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let hs = NSStackView(views: [l, spacer, sw]); hs.spacing = 8; hs.alignment = .centerY
        hs.translatesAutoresizingMaskIntoConstraints = false
        hs.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return hs
    }

    /// Компактный дропдаун мультивыбора датчиков (галочки; всегда ≥1). Перестройка редактора обновляет title.
    private func sensorMenuButton(keys: [String], onChange: @escaping ([String]) -> Void) -> GlassButton {
        let btn = GlassButton(title: sensorSummary(keys), symbol: "thermometer.medium", cornerRadius: Design.Radius.chip)
        btn.onClick = { [weak btn] in
            guard let btn else { return }
            let menu = NSMenu()
            for sensor in FanController.sensors() {
                let checked = keys.contains(sensor.key)
                menu.addItem(ClosureMenuItem(title: sensor.name, checked: checked) {
                    var sel = keys
                    if let i = sel.firstIndex(of: sensor.key) { if sel.count > 1 { sel.remove(at: i) } }   // не даём снять последний
                    else { sel.append(sensor.key) }
                    onChange(sel)
                })
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: btn.bounds.height), in: btn)
        }
        return btn
    }
    private func sensorSummary(_ keys: [String]) -> String {
        let sensors = FanController.sensors()
        if keys.isEmpty { return L("нет датчиков") }
        if keys.count == 1 { return sensors.first(where: { $0.key == keys[0] })?.name ?? keys[0] }
        return String(format: L("датчиков: %d (макс)"), keys.count)
    }

    /// 3 стартовые точки кривой из 2-точечной линейки (низ→мин, середина→середина, верх→макс).
    private func seedCurve(min mn: Double, max mx: Double, low: Int, high: Int) -> [CurvePoint] {
        let midT = (low + high) / 2
        return [CurvePoint(temp: low, rpm: Int(mn)),
                CurvePoint(temp: midT, rpm: Int((mn + mx) / 2)),
                CurvePoint(temp: high, rpm: Int(mx))]
    }

    /// Текущая глобальная настройка профиля (perFan=nil ветка) — как её видит движок.
    private func globalSetting() -> FanSetting { draft.setting(forFan: 0) }
    /// Записать глобальную настройку обратно в поля профиля (idle остаётся отдельным глобальным контролом).
    private func applyGlobalSetting(_ s: FanSetting) {
        draft.mode = s.mode
        draft.rpm = s.rpm
        draft.curveSensorKeys = s.sensorKeys
        draft.sensorKey = s.sensorKeys.first ?? "TC0P"
        draft.tempLow = s.tempLow
        draft.tempHigh = s.tempHigh
        draft.curvePoints = s.curvePoints
    }
    /// Глобальный idle-порог движок читает per-fan — синхронизируем во все perFan-настройки.
    private func normalizeIdleIntoPerFan() {
        guard var arr = draft.perFan else { return }
        for i in arr.indices { arr[i].idleHandoffTemp = draft.idleHandoffTemp }
        draft.perFan = arr
    }

    /// Моноширинная value-подпись для строк редактора кривой (обновляется live из замыкания слайдера).
    private func editorValueLabel(_ text: String) -> NSTextField {
        let v = NSTextField(labelWithString: text)
        v.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); v.textColor = .secondaryLabelColor
        return v
    }
    /// Строка редактора: подпись(130) · контрол · живая value-подпись.
    private func editorRow(_ title: String, _ control: NSView, _ valueLabel: NSTextField) -> NSView {
        let l = NSTextField(labelWithString: title); l.font = Design.Font.caption
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let hs = NSStackView(views: [l, control, valueLabel]); hs.spacing = 8; hs.alignment = .centerY
        return hs
    }

    private func row(_ label: String, _ control: NSView, _ value: String) -> NSStackView {
        let l = NSTextField(labelWithString: label); l.font = Design.Font.caption
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let v = NSTextField(labelWithString: value); v.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        v.textColor = .secondaryLabelColor
        let s = NSStackView(views: [l, control, v]); s.spacing = 8; s.alignment = .centerY
        return s
    }

    private func persistDraft() {
        // авто-сохранение правок в активный именованный пресет; иначе — легаси-слот (до миграции)
        if let i = activeUserPresetIndex() {
            var ps = SettingsStore.userFanPresets; ps[i] = draft; SettingsStore.userFanPresets = ps
        } else {
            SettingsStore.customFanProfile = draft
        }
    }

    /// Живой honest-readout: что профиль просит СЕЙЧАС — цель, датчик, текущая температура. Обновляется на
    /// тике таймера. Отвечает на «непонятно на какие датчики» и «почему скачет» (видно цель и t°, что её ведёт).
    /// Живой honest-readout под редактором: цель каждого вентилятора СЕЙЧАС (per-fan) + ведущий датчик.
    /// nil-цель → вент отдан системе (idle/auto/датчик недоступен) — показываем «система», не выдумываем.
    private func updatePreview() {
        let p = activeDraft()
        let fans = FanController.fans()
        guard !fans.isEmpty else { fanPreview.stringValue = ""; return }
        if p.mode == .auto {
            fanPreview.stringValue = L("Системный авто-режим — обороты задаёт macOS.")
            return
        }
        let parts: [String] = fans.map { f in
            let name = fans.count > 1 ? String(format: L("В%d "), f.index + 1) : ""
            if let t = FanController.targetRPM(for: p, fan: f) { return String(format: L("%@≈%.0f об"), name, t) }
            return String(format: L("%@система"), name)
        }
        let s0 = p.setting(forFan: 0)
        if s0.mode == .curve, let lead = FanController.leadingSensor(s0.sensorKeys) {
            let sname = FanController.sensors().first(where: { $0.key == lead.key })?.name ?? lead.key
            fanPreview.stringValue = String(format: L("Ведёт %@ · %.0f° → "), sname, lead.temp) + parts.joined(separator: " · ")
        } else {
            fanPreview.stringValue = L("Цель: ") + parts.joined(separator: " · ")
        }
    }

    private var fanDaemonInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.trykelvin.kelvin.fand.plist")
    }
    private func writeProfileJSON(_ p: FanProfile) { FanController.writeProfileFile(p) }   // единый путь записи (санитайз внутри)

    @objc private func applyProfile() {
        let p = activeDraft()
        if p.mode != .auto, !requirePro(.fans) { return }      // форс вентиляторов — Pro
        writeProfileJSON(p)                      // демон подхватит профиль за ~2 с
        let alert = NSAlert()
        if p.mode == .auto {
            alert.messageText = L("Авто-режим")
            alert.informativeText = fanDaemonInstalled
                ? L("Управление отключено — вентиляторы в системном режиме.")
                : L("Системный режим. Демон не установлен.")
            alert.addButton(withTitle: L("ОК")); alert.runModal(); return
        }
        if fanDaemonInstalled {
            alert.messageText = String(format: L("Профиль «%@» применён"), p.name)
            alert.informativeText = L("Демон управляет вентиляторами по профилю. Защита по перегреву активна.")
            alert.addButton(withTitle: L("ОК")); alert.runModal()
        } else {
            alert.messageText = L("Включить управление вентиляторами")
            alert.informativeText = L("Профиль сохранён. Принудительное управление требует root-демона (ставится один раз через системный диалог пароля).\n\n⚠️ Снижает охлаждение. Защита: перегрев → максимум; «Авто» или удаление демона → системный режим.")
            alert.addButton(withTitle: L("Установить и включить"))
            alert.addButton(withTitle: L("Отмена"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let r = HelperInstall.runPrivileged("install-fan-helper.sh", prompt: L("Kelvin устанавливает управление вентиляторами"))
            refreshFanDaemonRow()
            if HelperInstall.presentFailureIfNeeded(r, title: L("Не удалось включить управление")) {
                let done = NSAlert(); done.messageText = L("Управление включено")
                done.informativeText = String(format: L("Демон применяет профиль «%@». Защита по перегреву активна."), p.name)
                done.runModal()
            }
            select(.power)   // демон установлен — убрать кнопку «Включить управление…», обновить инфо
        }
    }

    // MARK: клавиатура (подсветка, яркость, раскладки)
    private var kbLayouts: [KbLayout] = []
    private let kbBacklightVal = NSTextField(labelWithString: "")

    private func sliderRow(_ label: String, _ slider: NSSlider, _ value: NSTextField) -> NSStackView {
        let l = NSTextField(labelWithString: label); l.font = Design.Font.caption
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 150).isActive = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        value.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); value.textColor = .secondaryLabelColor
        value.alignment = .right
        value.translatesAutoresizingMaskIntoConstraints = false
        value.widthAnchor.constraint(equalToConstant: 46).isActive = true
        let s = NSStackView(views: [l, slider, value]); s.spacing = 8; s.alignment = .centerY
        return s
    }


    @objc private func kbBacklightChanged(_ s: NSSlider) {
        KeyboardBacklight.set(Float(s.doubleValue)); kbBacklightVal.stringValue = "\(Int(s.doubleValue * 100))%"
    }
    // MARK: сниппеты
    private let snippetText = NSTextView()
    private var snippetTextLoaded = false     // грузим из хранилища один раз — иначе пересборка секции затирает несохранённые правки

    // MARK: фаервол
    private var fwApps: [Firewall.AppRule] = []
    private let domainText = NSTextView()
    private var domainTextLoaded = false          // грузим /etc/hosts один раз — пересборка netsec не должна затирать правки
    // MARK: сеть — инспектор подключений (Little-Snitch-стиль, read-only + лёгкий блок)
    // Соединение + его офлайн-гео (флаг+страна), посчитанное в фоне.
    private struct GeoConn { let conn: NetConn; let geo: String? }   // geo = "🇺🇸 США" или nil (LAN/неизвестно)
    // Приложение с предрасчитанной гео-разметкой соединений.
    private struct GeoApp { let app: AppNet; let conns: [GeoConn] }
    // Сырьё соединений + предрасчитанные гео-метки по каждому pid (всё фон-безопасно).
    // Резолв имён/иконок (AppNet) откладывается на main (B1) — гео к нему не привязана.
    private struct RawNet { let raw: [RawProc]; let geoByLabel: [String: String?] }


    /// Строка-приложение для карточки «Сеть»: иконка+имя, флаги стран (главный сигнал),
    /// приглушённый ip:port и кнопка «Заблокировать» (Free видит, действие — Pro-апселл).
    /// Строка-приложение для карточки «Сеть»: иконка+имя, флаги стран (главный сигнал),
    /// приглушённый ip:port и кнопка «Закрыть доступ» (Free видит, действие — Pro-гейт).
    private func netAppRow(_ ga: GeoApp) -> NSView {
        let a = ga.app
        let iconView = NSImageView()
        iconView.image = a.icon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 24).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let name = NSTextField(labelWithString: a.name); name.font = .systemFont(ofSize: 13, weight: .semibold)

        // Главный сигнал, который читает обычный человек: страны (флаг+имя), куда идёт трафик.
        // Уникальные гео-метки в порядке появления; соединения без гео (LAN/неизвестно) → нейтральный глобус.
        var seenGeo = Set<String>()
        var countries: [String] = []
        var hasLocal = false
        for gc in ga.conns {
            if let geo = gc.geo {
                if seenGeo.insert(geo).inserted { countries.append(geo) }
            } else {
                hasLocal = true
            }
        }
        let geoRow = NSStackView()
        geoRow.orientation = .horizontal; geoRow.alignment = .centerY; geoRow.spacing = 4
        let shownCountries = countries.prefix(3)
        for c in shownCountries {
            let l = NSTextField(labelWithString: c)   // "🇺🇸 США" — флаг уже внутри метки
            l.font = Design.Font.callout; l.lineBreakMode = .byTruncatingTail
            geoRow.addArrangedSubview(l)
        }
        if countries.count > shownCountries.count {
            let extra = NSTextField(labelWithString: "+\(countries.count - shownCountries.count)")
            extra.font = Design.Font.callout; extra.textColor = .secondaryLabelColor
            geoRow.addArrangedSubview(extra)
        }
        if hasLocal && countries.count < 3 {
            let globe = NSImageView()
            globe.image = NSImage(systemSymbolName: "house", accessibilityDescription: nil)
            globe.contentTintColor = .secondaryLabelColor
            globe.translatesAutoresizingMaskIntoConstraints = false
            globe.widthAnchor.constraint(equalToConstant: 13).isActive = true
            globe.heightAnchor.constraint(equalToConstant: 13).isActive = true
            let lan = NSTextField(labelWithString: L("Домашняя сеть"))
            lan.font = Design.Font.callout; lan.textColor = .secondaryLabelColor
            geoRow.addArrangedSubview(globe)
            geoRow.addArrangedSubview(lan)
        }

        // Вторичный, приглушённый: ip:port (для тех, кому нужны детали).
        let dests = ga.conns.prefix(3).map { $0.conn.label }.joined(separator: ", ")
        let more = a.conns.count > 3 ? " +\(a.conns.count - 3)" : ""
        let sub = NSTextField(labelWithString: String(format: L("%d соед. · %@%@"), a.conns.count, dests, more))
        sub.font = Design.Font.caption; sub.textColor = .tertiaryLabelColor; sub.lineBreakMode = .byTruncatingTail

        let texts = NSStackView(views: [name, geoRow, sub])
        texts.orientation = .vertical; texts.alignment = .leading; texts.spacing = 2
        let left = NSStackView(views: [iconView, texts]); left.orientation = .horizontal; left.alignment = .centerY; left.spacing = 9
        left.translatesAutoresizingMaskIntoConstraints = false

        // «Закрыть доступ» — Free видит, но действие ведёт в Pro-гейт; Pro реально блокирует входящие.
        let block = GlassButton(title: L("Закрыть доступ"), symbol: "hand.raised.fill", cornerRadius: Design.Radius.chip)
        block.translatesAutoresizingMaskIntoConstraints = false
        if let path = a.appPath {
            block.toolTip = L("Запретить этой программе входящие соединения через системный фаервол (нужен пароль администратора). Исходящий трафик это не обрывает.")
            block.onClick = { [weak self] in self?.blockAppIncoming(path: path) }
        } else {
            block.isEnabled = false   // нет .app (демон/бинарь) — точечный блок через фаервол невозможен
            block.toolTip = L("Это системный процесс или демон без обычного приложения — для него точечная блокировка через фаервол недоступна.")
        }

        let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false
        let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let hs = NSStackView(views: [left, spacer, block])
        hs.orientation = .horizontal; hs.alignment = .centerY; hs.spacing = 10
        hs.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(hs)
        NSLayoutConstraint.activate([
            hs.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            hs.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            hs.topAnchor.constraint(equalTo: row.topAnchor),
            hs.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    /// Блок входящих для приложения (Pro-гейт + подтверждение + Firewall.block). Вынесено из @objc
    /// blockAppIncoming(_:) под замыкание GlassButton — семантика идентична (путь вместо identifier).
    private func blockAppIncoming(path: String) {
        guard requirePro(.netBlock) else { return }
        let confirm = NSAlert()
        confirm.messageText = L("Заблокировать входящие?")
        confirm.informativeText = L("Системный фаервол запретит входящие соединения этому приложению (нужен пароль администратора). Это НЕ блокирует исходящий трафик — для этого нужен сетевой фильтр.")
        confirm.addButton(withTitle: L("Заблокировать")); confirm.addButton(withTitle: L("Отмена"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        settingsActionQueue.async {
            let ok = Firewall.block(path)
            DispatchQueue.main.async {
                let done = NSAlert()
                done.messageText = ok ? L("Готово") : L("Не удалось")
                done.informativeText = ok ? L("Входящие для приложения заблокированы. Управление — в разделе «Фаервол».") : L("Не удалось применить правило фаервола.")
                done.runModal()
            }
        }
    }



    private struct FWState {
        let enabled: Bool
        let stealth: Bool
        let blockAll: Bool
    }
    private struct NetSecCoreState {
        let firewall: FWState?
        let vpn: VPN.Status
    }

    /// Вердикт-карточка фаервола: SF-щит + одна фраза о реальном состоянии, цвет по уровню.
    /// enabled+stealth → levelOK «невидимость»; enabled → levelOK «включён»; выключен → levelWarn.


    // MARK: графика (gfxCardStatus-стиль)
    private struct GFXState { let gpus: [GPU]; let active: GPU?; let switchable: Bool; let mode: GPUMode?; let isAppleSilicon: Bool }



    // MARK: Поддержать Kelvin — донат автору (заменил раздел «Kelvin Pro»; коммерция снята, июль 2026)
    private func buildSupport() -> NSView {
        var items: [NSView] = []

        // — Герой: приложение бесплатно + кнопка благодарности —
        let donate = GlassButton(title: L("Поддержать автора"), symbol: "heart.fill", cornerRadius: Design.Radius.chip)
        donate.onClick = { Donate.open() }
        items.append(SK.card([
            SK.controlRow(icon: "heart.fill", title: L("Kelvin бесплатен — и остаётся таким"),
                          subtitle: L("Все функции открыты для всех, без подписки."),
                          control: donate),
        ]))

        // — Честно: зачем это (без обещаний платных функций) —
        items.append(groupHeader(L("Зачем это")))
        items.append(SK.card([
            SK.infoRow(icon: "sparkles", text: L("Поддержка помогает развивать Kelvin в свободное время: новые датчики, языки интерфейса, совместимость со свежими Mac и macOS.")),
            SK.infoRow(icon: "lock.open", text: L("Никакой подписки и никаких платных функций. Донат — полностью добровольный.")),
        ]))

        // — Другие способы помочь (бесплатные) —
        let feedback = GlassButton(title: L("Написать автору"), symbol: "envelope", cornerRadius: Design.Radius.chip)
        feedback.onClick = { [weak self] in self?.openFeedbackMail() }
        items.append(groupHeader(L("Другие способы помочь")))
        items.append(SK.card([
            SK.controlRow(icon: "envelope", title: L("Обратная связь"), subtitle: L("Идея, баг или пожелание — автор читает всё."), control: feedback),
            SK.infoRow(icon: "person.2", text: L("Расскажите друзьям, которым пригодится один прибор вместо десятка утилит в строке меню.")),
        ]))

        return SK.scaffold(L("Поддержать Kelvin"),
                           L("Приложение бесплатное. Эта страница — для тех, кто хочет поблагодарить автора."),
                           items)
    }

    private func openFeedbackMail() {
        if let u = AppConfig.mailto(subject: "Kelvin feedback") { NSWorkspace.shared.open(u) }
    }

    // MARK: Kelvin Pro — лицензия/триал/апселл (СПЯЩИЙ КОД — коммерция отключена; сохранён для реактивации)
    private func buildLicense() -> NSView {
        let lic = Licensing.shared
        let dark = (window?.effectiveAppearance ?? NSApp.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let teal = Design.Color.accent(dark)
        var items: [NSView] = []

        // — Статус (спокойно, без давления): активен / пробный / ничего не показываем в фри —
        if lic.activated {
            let deact = GlassButton(title: L("Деактивировать на этом Mac"), symbol: "minus.circle", cornerRadius: Design.Radius.chip)
            deact.onClick = { [weak self] in self?.deactivateLicense() }
            items.append(SK.card([
                SK.controlRow(icon: "checkmark.seal.fill", title: L("Kelvin Pro активен"), subtitle: lic.statusText, control: deact),
                SK.infoRow(icon: "info.circle", text: L("Деактивация освобождает место лицензии (2 Mac) — пригодится при продаже или замене компьютера.")),
            ]))
        } else if lic.inTrial {
            let warn = lic.trialDaysLeft <= 3
            items.append(SK.card([
                SK.infoRow(icon: warn ? "exclamationmark.circle.fill" : "clock.fill",
                           text: I18n.trialStatus(lic.trialDaysLeft) + " — " + L("в пробном периоде доступны все функции Pro."),
                           tint: warn ? Design.Color.levelWarn : teal),
            ]))
        }

        // — Что Kelvin показывает бесплатно (наблюдение), тематические иконки —
        items.append(groupHeader(L("Бесплатно навсегда")))
        items.append(SK.card([
            licenseFeatureRow("battery.100", L("Заряд и здоровье батареи")),
            licenseFeatureRow("thermometer.medium", L("Температуры и датчики")),
            licenseFeatureRow("fanblades", L("Обороты вентиляторов")),
            licenseFeatureRow("gauge.medium", L("Сеть, диск и нагрузка")),
            licenseFeatureRow("dot.radiowaves.left.and.right", L("Заряд Bluetooth-устройств")),
            licenseFeatureRow("point.3.connected.trianglepath.dotted", L("Список активных подключений")),
        ]))

        // — Что добавляет Pro: управление ровно тем, что бесплатно видно выше —
        let owned = lic.isPro
        let proIcon = owned ? "checkmark.circle.fill" : "slider.horizontal.3"
        let proTint = owned ? Design.Color.levelOK : teal
        items.append(groupHeader(L("Возможности Pro")))
        items.append(SK.card([
            licenseFeatureRow(proIcon, L("Ограничение заряда и бережная зарядка"), tint: proTint),
            licenseFeatureRow(proIcon, L("Кривая оборотов и пресеты вентиляторов"), tint: proTint),
            licenseFeatureRow(proIcon, L("Блокировка входящих подключений (сетевой экран)"), tint: proTint),
            licenseFeatureRow(proIcon, L("Уведомления по порогам с автоматическим действием"), tint: proTint),
            licenseFeatureRow(proIcon, L("Собственные команды в меню Kelvin"), tint: proTint),
            licenseFeatureRow(proIcon, L("Настройка раскладки меню"), tint: proTint),
        ]))
        items.append(SK.card([
            SK.infoRow(icon: "lightbulb", text: L("Мониторинг доступен бесплатно без ограничений по времени. Pro добавляет управление функциями, которые вы наблюдаете; бесплатные возможности при этом не отключаются.")),
        ]))

        // — Покупка/ключ (спокойно, в самом конце) — только пока не активирован —
        if !lic.activated {
            let buy = GlassButton(title: L("Купить — $19"), symbol: "cart", cornerRadius: Design.Radius.chip)
            buy.onClick = { [weak self] in self?.buyPro() }

            licenseKeyField.placeholderString = L("Ключ лицензии")
            licenseKeyField.font = Design.Font.body
            let activate = GlassButton(title: L("Активировать"), symbol: "key", cornerRadius: Design.Radius.chip)
            activate.onClick = { [weak self] in self?.activateLicense() }
            self.activateButton = activate
            let spin = NSProgressIndicator(); spin.style = .spinning; spin.controlSize = .small
            spin.isDisplayedWhenStopped = false; spin.translatesAutoresizingMaskIntoConstraints = false
            spin.widthAnchor.constraint(equalToConstant: 16).isActive = true
            self.activateSpinner = spin
            let activateCluster = NSStackView(views: [spin, activate])
            activateCluster.orientation = .horizontal; activateCluster.alignment = .centerY; activateCluster.spacing = 6

            let err = NSTextField(wrappingLabelWithString: "")
            err.font = Design.Font.caption; err.textColor = Design.Color.levelWarn; err.isHidden = true
            err.translatesAutoresizingMaskIntoConstraints = false
            err.widthAnchor.constraint(lessThanOrEqualToConstant: 360).isActive = true
            self.activateError = err

            items.append(groupHeader(L("Разблокировать Pro")))
            items.append(SK.card([
                SK.infoRow(icon: "checkmark.seal", text: L("Разовая покупка $19 · без подписки · 2 Mac на лицензию · пробный период открывает всё на 14 дней.")),
                SK.controlRow(icon: "cart", title: L("Купить Kelvin Pro"), subtitle: L("Откроется страница оплаты"), control: buy),
                SK.textFieldRow(icon: "key", field: licenseKeyField, placeholder: L("Ключ лицензии")),
                SK.controlRow(icon: "checkmark.circle", title: L("Активация ключа"), subtitle: L("Введите ключ в поле выше"), control: activateCluster),
                SK.infoRow(icon: "info.circle", text: L("Оплата и выдача ключей — через Lemon Squeezy (будет подключено к релизу). Крупные обновления могут быть платными.")),
            ]))
            items.append(SK.customRow(err, minHeight: 1))
            items.append(SK.customRow(restoreLink(), minHeight: 30))
        }

        return SK.scaffold(L("Kelvin Pro"),
                           L("Наблюдение бесплатно навсегда. Pro добавляет управление тем, что вы видите: заряд, вентиляторы, подключения. Разовая покупка, без подписки."),
                           items)
    }

    /// Строка-фича вкладки Pro: иконка + текст (body, переносится) во всю ширину карточки.
    private func licenseFeatureRow(_ icon: String, _ text: String, tint: NSColor = .secondaryLabelColor) -> NSView {
        return SK.controlRow(icon: icon, title: text, control: NSView())
    }

    /// Бренд-герой $19: бирюзовая карточка с ценой, CTA «купить» и строкой статуса
    /// (триал/активировано/бесплатно). CTA скрыта, когда лицензия уже активна.
    private func proHeroCard(_ lic: Licensing) -> NSView {
        let dark = (window?.effectiveAppearance ?? NSApp.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let teal = Design.Color.accent(dark)

        let eyebrow = NSTextField(labelWithString: "KELVIN PRO")
        eyebrow.font = Design.Font.micro
        eyebrow.textColor = teal

        let price = NSTextField(labelWithString: "$19")
        price.font = Design.Font.display
        price.textColor = .labelColor
        let once = NSTextField(labelWithString: L("разово · без подписки"))
        once.font = Design.Font.callout; once.textColor = .secondaryLabelColor
        let priceRow = NSStackView(views: [price, once])
        priceRow.orientation = .horizontal; priceRow.alignment = .firstBaseline; priceRow.spacing = 8

        // Строка статуса под ценой — единый индикатор (символ + подпись одним цветом).
        let statusView: NSView
        if lic.activated {
            statusView = iconLabel("checkmark.seal.fill", lic.statusText, tint: Design.Color.levelOK, weight: .semibold)
        } else if lic.inTrial {
            let warn = lic.trialDaysLeft <= 3
            statusView = iconLabel(warn ? "exclamationmark.circle.fill" : "clock.fill",
                                   I18n.trialStatus(lic.trialDaysLeft),
                                   tint: warn ? Design.Color.levelWarn : teal, weight: .semibold)
        } else {
            statusView = iconLabel("lock.fill", lic.statusText, tint: .secondaryLabelColor, weight: .semibold)
        }

        var col: [NSView] = [eyebrow, priceRow, statusView]
        if !lic.activated {
            let buy = NSButton(title: L("Купить Kelvin Pro — $19"), target: self, action: #selector(buyPro))
            buy.bezelStyle = .rounded; buy.controlSize = .large; buy.keyEquivalent = "\r"
            buy.bezelColor = teal                 // фирменная бирюза на главной CTA (а не системный синий дефолт-кнопки)
            buy.contentTintColor = .white
            col.append(buy)
        }

        let stack = NSStackView(views: col)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let card = HeroCardView()
        card.wantsLayer = true
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            card.widthAnchor.constraint(equalToConstant: 440),
        ])
        return card
    }

    /// Бесплатно (видеть) vs Pro (управлять): две колонки в одном боксе.
    /// Free-строки — нейтральная «галочка-глаз», всегда доступны. Pro-строки —
    /// зелёный «владею» ТОЛЬКО при isPro; иначе бирюзовый замок (заблокировано, не «куплено»).
    private func freeProMatrix(_ lic: Licensing) -> NSView {
        let dark = (window?.effectiveAppearance ?? NSApp.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let teal = Design.Color.accent(dark)

        // Заголовки колонок.
        let freeHead = NSTextField(labelWithString: L("Бесплатно"))
        freeHead.font = Design.Font.calloutEmph; freeHead.textColor = .secondaryLabelColor
        let proHead = NSTextField(labelWithString: "Pro")
        proHead.font = Design.Font.calloutEmph; proHead.textColor = teal

        // Free = мониторинг («видеть»). Доступно всем — нейтральный глаз.
        let freeItems = [
            L("Заряд и здоровье батареи"),
            L("Температуры и датчики"),
            L("Обороты вентиляторов"),
            L("Сеть, диск и нагрузка"),
            L("Заряд Bluetooth-устройств"),
            L("Список подключений"),
        ]
        // Pro = управление («управлять»). Глиф «владею» (зелёный) — только при isPro,
        // иначе бирюзовый замок: видно ценность, но это заблокировано, а не «уже ваше».
        let proItems = [
            L("Лимит заряда и парусный режим"),
            L("Пресеты и форсаж вентиляторов"),
            L("Свои кнопки-команды"),
            L("Пороги-уведомления с действием"),
            L("Блокировка подключений и фаервол"),
            L("Своя раскладка поповера"),
        ]

        func featRow(_ text: String, symbol: String, tint: NSColor, muted: Bool) -> NSView {
            let iv = NSImageView()
            iv.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            iv.contentTintColor = tint
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.widthAnchor.constraint(equalToConstant: 15).isActive = true
            iv.heightAnchor.constraint(equalToConstant: 15).isActive = true
            let l = NSTextField(wrappingLabelWithString: text)
            l.font = Design.Font.body
            l.textColor = muted ? .secondaryLabelColor : .labelColor
            let row = NSStackView(views: [iv, l]); row.spacing = 7; row.alignment = .firstBaseline
            return row
        }

        let freeCol = NSStackView(views: [freeHead] + freeItems.map {
            featRow($0, symbol: "eye.fill", tint: .secondaryLabelColor, muted: true)
        })
        freeCol.orientation = .vertical; freeCol.alignment = .leading; freeCol.spacing = 10
        freeCol.translatesAutoresizingMaskIntoConstraints = false
        freeCol.widthAnchor.constraint(equalToConstant: 196).isActive = true

        let owned = lic.isPro
        let proCol = NSStackView(views: [proHead] + proItems.map {
            owned ? featRow($0, symbol: "checkmark.circle.fill", tint: Design.Color.levelOK, muted: false)
                  : featRow($0, symbol: "lock.fill", tint: teal, muted: false)
        })
        proCol.orientation = .vertical; proCol.alignment = .leading; proCol.spacing = 10
        proCol.translatesAutoresizingMaskIntoConstraints = false
        proCol.widthAnchor.constraint(equalToConstant: 196).isActive = true

        let divider = NSBox(); divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let cols = NSStackView(views: [freeCol, divider, proCol])
        cols.orientation = .horizontal; cols.alignment = .top; cols.spacing = 14
        cols.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalTo: cols.heightAnchor).isActive = true
        return cols
    }
    /// Открыть раздел Pro и сразу поставить курсор в поле ключа (из апселла «Ввести ключ»).
    func openLicenseEntry() {
        select(.license)
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self?.licenseKeyField) }
    }
    @objc private func buyPro() { if let u = URL(string: Licensing.checkoutURL) { NSWorkspace.shared.open(u) } }
    @objc private func activateLicense() {
        activateError?.isHidden = true
        activateButton?.isEnabled = false
        activateSpinner?.startAnimation(nil)
        Licensing.shared.activate(licenseKeyField.stringValue) { [weak self] ok, msg in
            guard let self else { return }
            self.activateSpinner?.stopAnimation(nil)
            self.activateButton?.isEnabled = true
            if ok {
                self.select(.license)   // свёртка → ветка activated (checkmark + деактивировать)
                let a = NSAlert()
                a.messageText = L("Спасибо! Kelvin Pro активирован 🎉")
                a.informativeText = L("Управление и автоматизация разблокированы на этом Mac.") + " \(msg)"
                a.addButton(withTitle: L("Отлично"))
                a.runModal()
            } else {
                // 3 состояния (неверный ключ / лимит устройств / сеть / магазин не подключён)
                // спокойно, инлайн под полем — без модалки-крэша.
                self.activateError?.stringValue = msg
                self.activateError?.isHidden = false
            }
        }
    }

    /// Честное восстановление покупки — почта (без «магии»). Портал/ключи придут с релизным магазином.
    private func restoreLink() -> NSView {
        let b = NSButton(title: L("Восстановить покупку / Не помню ключ"), target: self, action: #selector(restorePurchase))
        b.isBordered = false
        b.contentTintColor = Design.Color.accent(true)
        b.font = Design.Font.caption
        b.setButtonType(.momentaryChange)
        return b
    }
    @objc private func restorePurchase() {
        let subj = "Kelvin — restore purchase".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let u = URL(string: "mailto:cambly.studio@gmail.com?subject=\(subj)") { NSWorkspace.shared.open(u) }
    }
    @objc private func deactivateLicense() { Licensing.shared.deactivate(); select(.license) }

    /// Гейт Pro-функции: true если доступна; иначе показывает апселл (купить / ввести ключ) и ведёт в Pro.
    @discardableResult
    func requirePro(_ f: ProFeature) -> Bool {
        if Licensing.shared.isPro { return true }
        let a = NSAlert()
        a.messageText = I18n.proFeatureTitle(f.title)
        a.informativeText = Licensing.shared.licenseKey != nil
            ? L("Лицензия есть, но не подтверждена — проверьте соединение и переактивируйте ключ в разделе Pro.")
            : L("Мониторинг бесплатен навсегда. Управление и автоматизация — в Kelvin Pro: разовая покупка $19, 2 Mac на лицензию, без подписки.")
        a.addButton(withTitle: L("Купить за $19"))
        a.addButton(withTitle: L("Ввести ключ"))
        a.addButton(withTitle: L("Позже"))
        switch a.runModal() {
        case .alertFirstButtonReturn:  buyPro()
        case .alertSecondButtonReturn: openLicenseEntry()
        default: break
        }
        return false
    }

    /// Секция «О программе» — на кит: хедер (иконка+имя+версия), карточка описания+автообновление,
    /// карточка действий (кнопки NSButton — «Отчёт» меняет свой title при генерации, поэтому НЕ GlassButton),
    /// карточка кредитов (кликабельная db-ip ссылка сохранена). Все хендлеры целы.
    private func buildAbout() -> NSView {
        let iconView = NSImageView()
        if let p = Bundle.main.path(forResource: "AppIcon", ofType: "icns") { iconView.image = NSImage(contentsOfFile: p) }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 60).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 60).isActive = true
        let name = NSTextField(labelWithString: "Kelvin"); name.font = Design.Font.display
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let ver = NSTextField(labelWithString: L("Версия") + " \(v) · " + L("мониторинг и управление системой"))
        ver.font = Design.Font.caption; ver.textColor = .secondaryLabelColor
        let nameCol = NSStackView(views: [name, ver]); nameCol.orientation = .vertical; nameCol.alignment = .leading; nameCol.spacing = 2
        let header = NSStackView(views: [iconView, nameCol]); header.orientation = .horizontal; header.alignment = .centerY; header.spacing = 14

        let welcome = GlassButton(title: L("Показать приветствие"), symbol: "sparkles", cornerRadius: Design.Radius.chip)
        let upd = GlassButton(title: L("Проверить обновления"), symbol: "arrow.down.circle", cornerRadius: Design.Radius.chip)
        let report = GlassButton(title: L("Создать отчёт"), symbol: "doc.text.magnifyingglass", cornerRadius: Design.Radius.chip)
        welcome.onClick = { [weak self] in self?.showWelcome() }
        upd.onClick = { [weak self] in self?.checkUpdates() }
        report.onClick = { [weak self] in self?.makeDiagnosticReport(NSButton()) }

        let copy = NSTextField(labelWithString: AppConfig.copyright)
        copy.font = Design.Font.caption; copy.textColor = .tertiaryLabelColor

        return SK.scaffold(L("О программе"), L("Сведения о программе, обновления и диагностика."), [
            SK.card([SK.customRow(header, minHeight: 76),
                     SK.infoRow(icon: "bolt.heart", text: L("Локальный мониторинг питания на данных IOKit и SMC, без сбора телеметрии. Энергопотоки, схема токов, температуры и управление системой."))]),
            groupHeader(L("Обновления")),
            SK.card([SK.toggleRow(icon: "arrow.triangle.2.circlepath", title: L("Проверять обновления автоматически"),
                                  isOn: Updater.autoCheck) { Updater.autoCheck = $0 },
                     SK.controlRow(icon: "arrow.down.circle", title: L("Проверить обновления"), control: upd),
                     SK.controlRow(icon: "sparkles", title: L("Показать приветствие"), control: welcome)]),
            groupHeader(L("Диагностика")),
            SK.card([SK.controlRow(icon: "doc.text.magnifyingglass", title: L("Диагностический отчёт"),
                                   subtitle: L("Снимок состояния системы для поддержки"), control: report),
                     SK.infoRow(icon: "lock.doc", text: L("«Диагностический отчёт» формирует снимок состояния системы в формате Markdown (безопасность, батарея, температуры, сеть за сессию). Данные остаются локально и никуда не отправляются."))]),
            SK.card([SK.customRow(creditsRow()), SK.customRow(copy)]),
        ])
    }

    /// Консолидированная секция «Основные»: автозапуск, строка меню (режим/иконка/мощность/объединённый вид/
    /// доп-показатели), язык интерфейса, подсказка о полноэкранном режиме и горячая клавиша. Night Shift и
    /// заряд батареи вынесены в отдельные секции. Все побочные эффекты (SettingsStore, applyMenuBarLive,
    /// LoginItem, reapplyPopoverHotkey, langChanged) сохранены дословно; пересборка идёт через select(.basics).
    /// Группа горячей клавиши встроена сюда (не через buildHotkeyGroup), чтобы её живая пересборка нацеливалась
    /// на .basics, а не на устаревший .general.
    private func buildBasics() -> NSView {
        var items: [NSView] = []

        // — Запуск —
        items.append(groupHeader(L("Запуск")))
        items.append(SK.card([
            SK.toggleRow(icon: "power", title: L("Запускать при входе в систему"),
                         subtitle: L("Kelvin отображается в строке меню после входа в систему"),
                         isOn: LoginItem.enabled, enabled: LoginItem.available) { [weak self] on in
                guard let self else { return }
                if !LoginItem.set(on) {
                    let a = NSAlert()
                    a.messageText = L("Не удалось изменить автозапуск")
                    a.informativeText = L("Откройте «Системные настройки» → «Основные» → «Объекты входа» и добавьте Kelvin вручную.")
                    a.runModal()
                    self.select(.basics)
                }
            },
        ]))

        // — Строка меню: показываем только уместные опции + нейтральные подсказки —
        let mode = SettingsStore.menuBarMode
        let modeIdx = ["battery", "cpu", "ram"].firstIndex(of: mode) ?? 0
        var mbRows: [NSView] = [
            SK.segmentRow(icon: "chart.line.uptrend.xyaxis", title: L("Показатель"),
                          options: [L("Батарея"), L("CPU"), L("Память")], selected: modeIdx) { [weak self] idx in
                SettingsStore.menuBarMode = ["battery", "cpu", "ram"][max(0, min(2, idx))]
                self?.applyMenuBarLive()
                self?.select(.basics)              // обновить подсказку и набор уместных опций
            },
        ]
        switch mode {
        case "cpu":  mbRows.append(SK.infoRow(icon: "waveform.path.ecg", text: L("Иконка отображает мини-график загрузки процессора.")))
        case "ram":  mbRows.append(SK.infoRow(icon: "waveform.path.ecg", text: L("Иконка отображает мини-график использования памяти.")))
        default:     mbRows.append(SK.infoRow(icon: "info.circle", text: L("Отображается заряд батареи. Ниже — выбор иконки и показ мощности вместо процента.")))
        }
        if mode == "battery" {
            mbRows.append(SK.segmentRow(icon: "thermometer.medium", title: L("Главная иконка"),
                                        options: [L("Термометр"), L("Батарея")],
                                        selected: SettingsStore.mainIconStyle == "battery" ? 1 : 0) { [weak self] idx in
                SettingsStore.mainIconStyle = idx == 1 ? "battery" : "thermometer"
                self?.applyMenuBarLive()
            })
            mbRows.append(SK.toggleRow(icon: "bolt.fill", title: L("Показывать мощность вместо процента"),
                                       isOn: SettingsStore.menuBarShowWatts) { [weak self] on in
                SettingsStore.menuBarShowWatts = on; self?.applyMenuBarLive()
            })
        }
        mbRows.append(SK.toggleRow(icon: "rectangle.on.rectangle", title: L("Объединённый вид"),
                                   subtitle: L("Показатели в одной монохромной плашке фиксированной ширины"),
                                   isOn: SettingsStore.menuBarCombined) { [weak self] on in
            SettingsStore.menuBarCombined = on; self?.applyMenuBarLive(); self?.select(.basics)
        })
        if SettingsStore.menuBarCombined {
            mbRows.append(SK.toggleRow(icon: "square.grid.2x2", title: L("Иконки перед показателями"),
                                       isOn: SettingsStore.menuBarExtraIcons) { [weak self] on in
                SettingsStore.menuBarExtraIcons = on; self?.applyMenuBarLive(); self?.select(.basics)
            })
            if SettingsStore.menuBarExtraIcons {
                mbRows.append(SK.segmentRow(icon: "paintpalette", title: L("Стиль иконок"),
                                            options: [L("Kelvin"), L("Системные")],
                                            selected: SettingsStore.menuBarIconStyle == "system" ? 1 : 0) { [weak self] idx in
                    SettingsStore.menuBarIconStyle = idx == 1 ? "system" : "kelvin"
                    self?.applyMenuBarLive()
                })
            }
            mbRows.append(SK.infoRow(icon: "info.circle", text: L("В объединённом виде показатели монохромны: система тинтует их под тему, поэтому цветовая индикация нагрузки недоступна.")))
        }
        items.append(groupHeader(L("Строка меню")))
        items.append(SK.card(mbRows))

        // — Дополнительные показатели строки меню (с лимитом), спрятаны в disclosure —
        let selected = SettingsStore.menuBarExtras
        let mx = SettingsStore.menuBarExtraMax
        let atMax = selected.count >= mx
        var extraRows: [NSView] = []
        for (i, def) in Self.menuExtraDefs.enumerated() {
            let isOn = selected.contains(def.id)
            extraRows.append(SK.toggleRow(icon: menuExtraIcon(def.id), title: L(def.label),
                                          isOn: isOn, enabled: isOn || !atMax) { [weak self] on in
                guard let self else { return }
                guard Self.menuExtraDefs.indices.contains(i) else { return }
                let id = Self.menuExtraDefs[i].id
                var cur = SettingsStore.menuBarExtras
                if on {
                    if !cur.contains(id), cur.count < SettingsStore.menuBarExtraMax { cur.append(id) }
                } else {
                    cur.removeAll { $0 == id }
                }
                SettingsStore.menuBarExtras = cur
                self.applyMenuBarLive()
                self.select(.basics)
            })
        }
        let cnt = selected.count
        extraRows.append(SK.infoRow(icon: atMax ? "exclamationmark.circle" : "info.circle",
            text: atMax ? String(format: L("Выбрано %d из %d — достигнут лимит. Снимите один показатель, чтобы добавить другой."), cnt, mx)
                        : String(format: L("Выбрано %d из %d. Количество ограничено, чтобы строка меню оставалась компактной."), cnt, mx)))
        items.append(groupHeader(L("Дополнительные показатели")))
        items.append(SK.card([
            SK.disclosure(title: String(format: L("Выбор показателей (%d из %d)"), cnt, mx), expanded: false, rows: extraRows),
        ]))

        // — Язык интерфейса (сложный хендлер — сырой NSPopUpButton; langChanged читает индекс из sender) —
        let langPop = NSPopUpButton(frame: .zero, pullsDown: false)
        langPop.addItem(withTitle: L("Система"))
        Lang.allCases.forEach { langPop.addItem(withTitle: $0.title) }
        if let o = I18n.override, let idx = Lang.allCases.firstIndex(of: o) { langPop.selectItem(at: idx + 1) } else { langPop.selectItem(at: 0) }
        langPop.target = self; langPop.action = #selector(langChanged(_:))
        items.append(groupHeader(L("Язык интерфейса")))
        items.append(SK.card([
            SK.controlRow(icon: "globe", title: L("Язык интерфейса"), control: langPop),
            SK.infoRow(icon: "info.circle", text: L("Меню и панель обновляются сразу; часть системных диалогов — после перезапуска.")),
        ]))

        // — Полноэкранный режим (системная настройка macOS) —
        let fsBtn = GlassButton(title: L("Открыть настройки строки меню…"), symbol: "arrow.up.forward.app", cornerRadius: Design.Radius.chip)
        fsBtn.onClick = { [weak self] in self?.openMenuBarSettings() }
        items.append(groupHeader(L("Строка меню в полноэкранном режиме")))
        items.append(SK.card([
            SK.controlRow(icon: "menubar.rectangle", title: L("Отображение строки меню"),
                          subtitle: L("Управляется настройками macOS, а не Kelvin"), control: fsBtn),
            SK.infoRow(icon: "info.circle", text: L("«Пункт управления» → «Строка меню» → «Автоматически скрывать и показывать строку меню» → «Никогда».")),
        ]))

        // — Горячая клавиша (встроена, чтобы живая пересборка целилась в .basics) —
        let hkEnabled = SettingsStore.popoverHotkeyEnabled
        let rec = HotkeyRecorder(keyCode: SettingsStore.popoverHotkeyKeyCode,
                                 mods: NSEvent.ModifierFlags(rawValue: UInt(SettingsStore.popoverHotkeyMods)))
        rec.isEnabled = hkEnabled
        rec.onCapture = { [weak self] code, mods in
            SettingsStore.popoverHotkeyKeyCode = code
            SettingsStore.popoverHotkeyMods = Int(mods.rawValue)
            self?.reapplyPopoverHotkey()                      // LIVE перерегистрация
        }
        let hkClear = GlassButton(title: L("Сбросить"), symbol: "arrow.uturn.backward", cornerRadius: Design.Radius.chip)
        hkClear.isEnabled = hkEnabled
        hkClear.onClick = { [weak self] in
            guard let self else { return }
            // «Сброс» = вернуть дефолт ⌥⌘B (а НЕ пусто — дефолт всегда осмыслен).
            SettingsStore.popoverHotkeyKeyCode = 11            // kVK_ANSI_B
            SettingsStore.popoverHotkeyMods = Int(NSEvent.ModifierFlags([.command, .option]).rawValue)
            self.reapplyPopoverHotkey()
            self.select(.basics)
        }
        var hkRows: [NSView] = [
            SK.toggleRow(icon: "command", title: L("Открывать поповер по горячей клавише"),
                         isOn: hkEnabled) { [weak self] on in
                SettingsStore.popoverHotkeyEnabled = on
                self?.reapplyPopoverHotkey()
                self?.select(.basics)                         // рекордер/сброс enable/disable вживую
            },
        ]
        if hkEnabled {
            hkRows.append(SK.controlRow(icon: "keyboard", title: L("Комбинация"), control: rec))
            hkRows.append(SK.controlRow(icon: "arrow.uturn.backward", title: L("Сбросить к ⌥⌘B"), control: hkClear))
        }
        hkRows.append(SK.infoRow(icon: "info.circle", text: L("Глобальная клавиша открывает панель Kelvin поверх любого приложения — в том числе в полноэкранном режиме. По умолчанию ⌥⌘B. Нужна минимум одна клавиша-модификатор. Esc отменяет запись.")))
        items.append(groupHeader(L("Горячая клавиша")))
        items.append(SK.card(hkRows))

        // — Автозапуск (login-items X-ray) влит сюда блоком «только просмотр» (отдельного раздела больше нет) —
        items.append(groupHeader(L("Программы при входе")))
        if let cached = cachedLoginScan {
            items.append(startupBlockView(cached))                   // из кэша — без спиннера/мерцания при тумблерах
        } else {
            items.append(asyncSection(.basics, key: "basics.login-items", fetch: { LoginItems.scan() }) { [weak self] result in
                guard let self else { return NSView() }
                self.cachedLoginScan = result
                return self.startupBlockView(result)
            })
        }

        return SK.scaffold(L("Основные"),
                           L("Автозапуск, строка меню, язык интерфейса и горячая клавиша. Kelvin работает в строке меню, без значка в Dock. Изменения применяются сразу."),
                           items)
    }
    /// Кэш скана login-items (для блока «Программы при входе» в «Основных») — чтобы каждый тумблер
    /// раздела не пере-сканировал файловую систему и не мигал спиннером. Живёт до закрытия окна.
    private var cachedLoginScan: LoginItems.ScanResult?
    /// Вертикальный стек карточек списка автозапуска (общий для кэш- и async-веток «Основных»).
    private func startupBlockView(_ result: LoginItems.ScanResult) -> NSView {
        let stack = NSStackView(views: startupItems(result))
        stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// Консолидированная секция «Ввод и текст»: раскладка/конвертация языка, дисплей (подсветка/яркость/
    /// авто-подсветка), Ночной режим, а также свёрнутые списки раскладок и текстовых расширений.
    /// Все побочные эффекты 1:1 со старыми buildLanguage/buildKeyboard/buildSnippets; пересборка/откат — через .input.
    private func buildInput() -> NSView {
        var items: [NSView] = []

        // — Баннер разрешения (только пока Универсальный доступ не выдан) —
        let trusted = LangSwitcher.shared.isTrusted
        if !trusted {
            let grant = GlassButton(title: L("Разрешить"), symbol: "lock.open", cornerRadius: Design.Radius.chip)
            grant.onClick = { [weak self] in LangSwitcher.shared.requestAccessibility(); self?.select(.input) }
            items.append(SK.card([SK.controlRow(icon: "exclamationmark.triangle.fill",
                                                title: L("Требуется Универсальный доступ"),
                                                subtitle: L("Необходим для конвертации раскладки, исправления опечаток и текстовых расширений"),
                                                control: grant)]))
        }

        // ============================ Раскладка ============================
        let modes = ["off", "hotkey", "auto"]
        let modeIdx = modes.firstIndex(of: SettingsStore.langMode) ?? 0
        var langRows: [NSView] = [
            SK.segmentRow(icon: "globe", title: L("Переключение раскладки"),
                          options: [L("Выключено"), L("По клавише"), L("Автоматически")], selected: modeIdx) { [weak self] idx in
                guard let self else { return }
                let m = modes[max(0, min(2, idx))]
                if m != "off", !self.requirePro(.language) { self.select(.input); return }   // Pro — иначе откат перестройкой
                SettingsStore.langMode = m
                LangSwitcher.shared.mode = (m == "auto") ? .auto : (m == "hotkey" ? .hotkey : .off)
                if m != "off" && !LangSwitcher.shared.isTrusted { LangSwitcher.shared.requestAccessibility() }
                self.select(.input)                       // показать/скрыть выбор клавиши + обновить пояснение
            }
        ]
        if SettingsStore.langMode == "hotkey" {
            let codes = [61, 54, 62]
            langRows.append(SK.selectRow(icon: "keyboard", title: L("Клавиша конвертации"),
                                         options: [L("Правый ⌥"), L("Правый ⌘"), L("Правый ⌃")],
                                         selected: codes.firstIndex(of: SettingsStore.langHotkey) ?? 0) { idx in
                let kc = codes[max(0, min(2, idx))]
                SettingsStore.langHotkey = kc
                LangSwitcher.shared.hotkeyKeycode = CGKeyCode(kc)
            })
        }
        if SettingsStore.langMode == "auto" {
            langRows.append(SK.selectRow(icon: "character.cursor.ibeam",
                                         title: L("Минимум букв для автоконвертации"),
                                         options: ["3", "4", "5"],
                                         selected: max(0, min(2, SettingsStore.langAutoMinLength - 3))) { idx in
                SettingsStore.langAutoMinLength = idx + 3
            })
        }
        let modeInfo: String
        switch SettingsStore.langMode {
        case "hotkey": modeInfo = L("Если слово введено не в той раскладке, нажмите выбранную клавишу-модификатор — последнее слово будет сконвертировано.")
        case "auto":   modeInfo = L("Конвертация выполняется автоматически по завершении слова (в экспериментальном режиме). Поддерживаются направления RU и EN.")
        default:       modeInfo = L("Автоматическое переключение раскладки отключено.")
        }
        langRows.append(SK.infoRow(icon: "info.circle", text: modeInfo))
        let runtime = LangSwitcher.shared.runtimeDiagnostics
        let runtimeText: String
        let inputWanted = SettingsStore.langMode != "off"
            || SettingsStore.spellFixEnabled
            || SettingsStore.snippetsEnabled
        if !inputWanted {
            runtimeText = L("Движок ввода остановлен.")
        } else if !runtime.trusted {
            runtimeText = L("Движок ввода не запущен: нет разрешения «Универсальный доступ».")
        } else if runtime.tapActive {
            runtimeText = runtime.recoveries == 0
                ? L("Движок ввода работает на выделенном потоке.")
                : "\(L("Движок ввода работает. Восстановлений после системной паузы:")) \(runtime.recoveries)"
        } else {
            runtimeText = "\(L("Движок ввода не запущен. Ошибок создания перехвата:")) \(runtime.creationFailures)"
        }
        langRows.append(SK.infoRow(icon: runtime.tapActive ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                   text: runtimeText))
        items.append(groupHeader(L("Раскладка")))
        items.append(SK.card(langRows))

        // — Исправление опечаток и обратная связь —
        items.append(groupHeader(L("Исправление опечаток")))
        var spellRows: [NSView] = [
            SK.toggleRow(icon: "textformat.abc.dottedunderline", title: L("Исправление опечаток"),
                         subtitle: L("Автоматически исправляет явные опечатки RU и EN."),
                         isOn: SettingsStore.spellFixEnabled) { [weak self] on in
                guard let self else { return }
                if on, !self.requirePro(.language) { self.select(.input); return }   // Pro — иначе откат перестройкой
                SettingsStore.spellFixEnabled = on
                LangSwitcher.shared.spellFixEnabled = on
                if on && !LangSwitcher.shared.isTrusted { LangSwitcher.shared.requestAccessibility() }
                self.select(.input)
            },
        ]
        if SettingsStore.spellFixEnabled {
            spellRows.append(SK.selectRow(icon: "scope", title: L("Точность исправлений"),
                         options: [L("Строго"), L("Сбалансированно")],
                         selected: SettingsStore.spellFixMode == "balanced" ? 1 : 0) { idx in
                SettingsStore.spellFixMode = idx == 1 ? "balanced" : "strict"
            })
        }
        spellRows.append(contentsOf: [
            SK.toggleRow(icon: "speaker.wave.2", title: L("Звук при замене"),
                         subtitle: L("Короткий звуковой сигнал при автоматической замене"),
                         isOn: SettingsStore.langFeedbackSound) { on in SettingsStore.langFeedbackSound = on },
            SK.toggleRow(icon: "bell.badge", title: L("Индикатор замены"),
                         subtitle: L("Кратковременный индикатор в верхней части экрана"),
                         isOn: SettingsStore.langFeedbackHUD) { [weak self] on in
                SettingsStore.langFeedbackHUD = on
                if on { FeedbackHUD.shared.show(symbol: "globe", text: L("Русский"), tint: .systemTeal) }   // предпросмотр
                self?.select(.input)
            },
        ])
        if SettingsStore.langFeedbackHUD {
            spellRows.append(SK.selectRow(icon: "sparkles", title: L("Стиль индикатора"),
                         options: [L("Анимированный"), L("Компактный")],
                         selected: SettingsStore.langFeedbackStyle == "compact" ? 1 : 0) { idx in
                SettingsStore.langFeedbackStyle = idx == 1 ? "compact" : "animated"
                FeedbackHUD.shared.show(symbol: "globe", text: L("Русский"), tint: .systemTeal)
            })
        }
        items.append(SK.card(spellRows))

        // ============================ Дисплей ============================
        var displayRows: [NSView] = []
        if ScreenBrightness.available {
            let cur = max(0, ScreenBrightness.get())
            displayRows.append(SK.sliderRow(icon: "sun.max", title: L("Яркость экрана"),
                                            min: 0, max: 100, value: Double(cur) * 100, unit: "%") { v, label in
                ScreenBrightness.set(Float(v / 100))
                label.stringValue = "\(Int(v))%"
            })
        }
        if KeyboardBacklight.available {
            let cur = max(0, KeyboardBacklight.get())
            displayRows.append(SK.sliderRow(icon: "keyboard", title: L("Подсветка клавиатуры"),
                                            min: 0, max: 100, value: Double(cur) * 100, unit: "%") { v, label in
                KeyboardBacklight.set(Float(v / 100))
                label.stringValue = "\(Int(v))%"
            })
        }
        if displayRows.isEmpty {
            displayRows.append(SK.infoRow(icon: "exclamationmark.triangle", text: L("Управление яркостью и подсветкой недоступно на этом Mac.")))
        }
        // — Авто-подсветка по простою (тумблер + задержка) —
        let idleOn = SettingsStore.idleBacklight
        displayRows.append(SK.toggleRow(icon: "moon.zzz", title: L("Гасить подсветку при простое"),
                                        isOn: idleOn) { [weak self] on in
            SettingsStore.idleBacklight = on
            self?.select(.input)
        })
        if idleOn {
            let secOptions = [L("15 с"), L("30 с"), L("1 мин"), L("2 мин")]
            let secValues = [15, 30, 60, 120]
            displayRows.append(SK.selectRow(icon: "timer", title: L("Задержка"), options: secOptions,
                                            selected: secValues.firstIndex(of: SettingsStore.idleSeconds) ?? 1) { idx in
                SettingsStore.idleSeconds = secValues[max(0, min(3, idx))]
            })
        }
        items.append(groupHeader(L("Дисплей")))
        items.append(SK.card(displayRows))
        if idleOn {
            items.append(SK.infoRow(icon: "info.circle", text: L("На этом Mac датчик освещённости недоступен, поэтому используется реакция на простой: подсветка гаснет при бездействии и включается при вводе.")))
        }

        // ============================ Ночной режим ============================
        items.append(contentsOf: buildNightGroup())

        // ============================ Раскладки клавиатуры (свёрнуто) ============================
        kbLayouts = InputSources.installed()
        var layoutRows: [NSView] = []
        for (i, l) in kbLayouts.enumerated() {
            layoutRows.append(SK.toggleRow(icon: "character", title: l.name, isOn: l.enabled) { [weak self] on in
                guard let self else { return }
                guard self.kbLayouts.indices.contains(i) else { return }
                let layout = self.kbLayouts[i]
                let ok = InputSources.setEnabled(layout, on)
                // И при откате, И при успехе пересобираем: список раскладок мог измениться/переупорядочиться,
                // иначе замыкания строк держат устаревшие индексы i и переключалась бы ЧУЖАЯ раскладка.
                _ = ok
                self.kbLayouts = InputSources.installed()
                self.select(.input)
            })
        }
        if layoutRows.isEmpty {
            layoutRows.append(SK.infoRow(icon: "questionmark.circle", text: L("Раскладки не найдены.")))
        }
        let openBtn = GlassButton(title: L("Открыть настройки клавиатуры"), symbol: "keyboard", cornerRadius: Design.Radius.chip)
        openBtn.onClick = { InputSources.openSystemKeyboardSettings() }
        layoutRows.append(SK.controlRow(icon: "gearshape", title: L("Настройки клавиатуры"),
                                        subtitle: L("Добавление и удаление языков ввода"), control: openBtn))
        items.append(groupHeader(L("Раскладки клавиатуры")))
        items.append(SK.card([
            SK.disclosure(title: L("Список раскладок"), expanded: false, rows: [SK.card(layoutRows)]),
        ]))

        // ============================ Текстовые расширения (свёрнуто) ============================
        let snippetsOn = SettingsStore.snippetsEnabled
        let toggleRow = SK.toggleRow(icon: "text.badge.plus", title: L("Текстовые расширения"),
                                     subtitle: L("После ввода триггера и пробела он заменяется на заданный текст."),
                                     isOn: snippetsOn) { [weak self] on in
            guard let self else { return }
            if on, !self.requirePro(.snippets) { self.select(.input); return }   // Pro — иначе откат перестройкой
            SettingsStore.snippetsEnabled = on
            LangSwitcher.shared.snippets = SettingsStore.parseSnippets(SettingsStore.snippetsRaw)
            LangSwitcher.shared.snippetsEnabled = on
            if on && !LangSwitcher.shared.isTrusted { LangSwitcher.shared.requestAccessibility() }
        }

        // Многострочный редактор замен (NSTextView в скролле) — outlet snippetText сохранён.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        if !snippetTextLoaded { snippetText.string = SettingsStore.snippetsRaw; snippetTextLoaded = true }
        snippetText.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        snippetText.isRichText = false
        snippetText.isAutomaticQuoteSubstitutionEnabled = false
        snippetText.isVerticallyResizable = true
        snippetText.isHorizontallyResizable = false
        snippetText.autoresizingMask = [.width]
        snippetText.textContainer?.widthTracksTextView = true
        scroll.documentView = snippetText

        let save = GlassButton(title: L("Сохранить"), symbol: "tray.and.arrow.down", cornerRadius: Design.Radius.chip)
        save.onClick = { [weak self] in
            guard let self else { return }
            SettingsStore.snippetsRaw = self.snippetText.string
            LangSwitcher.shared.snippets = SettingsStore.parseSnippets(self.snippetText.string)
        }

        items.append(groupHeader(L("Текстовые расширения")))
        items.append(SK.card([
            toggleRow,
            SK.infoRow(icon: "info.circle", text: L("Формат: одна замена на строку, «триггер = текст». Пример: ;mail = почта@example.com")),
            SK.disclosure(title: L("Список замен"), expanded: false, rows: [
                SK.stretchRow(scroll, height: 150),
                SK.customRow(save),
            ]),
        ]))

        return SK.scaffold(L("Ввод и текст"),
                           L("Переключение раскладки, исправление опечаток, дисплей, ночной режим и текстовые расширения. Обработка выполняется локально, без передачи данных."),
                           items)
    }

    /// Готовые наборы плотности поповера. Минимум = заряд+переключатели; Баланс = шапка+6 вкладок
    /// (дефолт, звук/консоль ВЫКЛ); Всё = все 12 блоков. Меняет только on-флаги, порядок сохраняется.
    private func applyPopoverPreset(_ idx: Int) {
        let on: Set<String>
        switch idx {
        case 0:  on = ["battery", "toggles"]                          // Минимум
        case 2:  on = Set(PopoverModules.all.map { $0.id })           // Всё
        default: on = PopoverModules.defaultOn                        // Баланс
        }
        var lay = SettingsStore.popoverLayout
        for i in lay.indices { lay[i].on = on.contains(lay[i].id) }
        SettingsStore.popoverLayout = lay
        notifyPopoverChanged()
    }
    /// Индекс текущего пресета для селектора (кастомная раскладка → «Баланс» как ближайший нейтральный).
    private func currentPopoverPreset() -> Int {
        let onSet = Set(SettingsStore.popoverLayout.filter { $0.on }.map { $0.id })
        if onSet == Set(["battery", "toggles"]) { return 0 }
        if onSet == Set(PopoverModules.all.map { $0.id }) { return 2 }
        return 1
    }

    // MARK: секция «Поповер и уведомления» — слияние: поповер (layout-editor) + быстрые действия
    // (плитка переключателей + конструктор своих команд) + уведомления (мастер + тест + первый выход в сеть).
    // ВАЖНО: пороговые правила (CPU/GPU/батарея) сюда НЕ входят — они в разделе «Питание и охлаждение».
    private func buildHub() -> NSView {
        var items: [NSView] = []

        // ─────────────────────────────────────────────────────────────────────
        // Поповер: редактор блоков (галочка — показывать, перетаскивание — порядок)
        // ─────────────────────────────────────────────────────────────────────
        items.append(groupHeader(L("Поповер")))
        items.append(SK.card([
            // Готовый набор плотности: сдержанный «Баланс» по умолчанию (шапка + 6 вкладок; звук и полная
            // консоль выключены) — новый пользователь не тонет в максимальной плотности (урок iStat 7).
            SK.selectRow(icon: "rectangle.3.group", title: L("Готовый набор"),
                         options: [L("Минимум"), L("Баланс"), L("Всё")], selected: currentPopoverPreset()) { [weak self] idx in
                self?.applyPopoverPreset(idx); self?.select(.hub)
            },
            // Прозрачность фона поповера: слайдер «плотность стекла» (0 = плотный прибор, 100 = максимум вибранси).
            // При системной «Уменьшить прозрачность» стекло и так плотное — слайдер остаётся, но эффект мал.
            SK.sliderRow(icon: "circle.lefthalf.filled", title: L("Прозрачность фона"),
                         min: 0, max: 100,
                         value: (1.0 - SettingsStore.popoverOpacity) / 0.82 * 100, unit: "%") { [weak self] v, lbl in
                SettingsStore.popoverOpacity = 1.0 - (v / 100.0) * 0.82
                lbl.stringValue = String(format: "%.0f%%", v)
                self?.notifyPopoverChanged()
            },
            SK.customRow(PopoverLayoutEditor(), minHeight: 214),
            SK.infoRow(icon: "square.grid.2x2",
                text: L("Готовый набор задаёт плотность; ниже можно точно отметить блоки (галочка — показывать) и задать порядок перетаскиванием. Блок «Переключатели» настраивается в «Быстрых действиях».")),
        ]))

        // ─────────────────────────────────────────────────────────────────────
        // Быстрые действия: плитка переключателей поповера + конструктор своих команд
        // ─────────────────────────────────────────────────────────────────────
        items.append(groupHeader(L("Быстрые действия")))

        // — список доступных переключателей: свитч + вверх/вниз + (корзина у своих) —
        // Список остаётся компактной карточкой (а не раскрывающимся блоком): стрелки/корзина
        // пересобирают секцию, и disclosure сбрасывал бы своё состояние при каждом действии.
        let layout = SettingsStore.toggleLayout
        var toggleRows: [NSView] = []
        for (i, item) in layout.enumerated() {
            let sw = KSwitch(on: item.on)
            sw.onChange = { [weak self] on in
                var lay = SettingsStore.toggleLayout
                guard lay.indices.contains(i) else { return }
                lay[i].on = on
                SettingsStore.toggleLayout = lay
                self?.notifyPopoverChanged()
            }
            let up = arrowBtn("arrow.up", #selector(moveToggleUpHub(_:)), i, enabled: i > 0)
            let down = arrowBtn("arrow.down", #selector(moveToggleDownHub(_:)), i, enabled: i < layout.count - 1)
            var trailing: [NSView] = [sw, up, down]
            if item.id.hasPrefix("custom:") {
                let del = arrowBtn("trash", #selector(deleteCustomToggleHub(_:)), i, enabled: true)
                del.contentTintColor = .systemRed
                trailing.append(del)
            }
            let controls = NSStackView(views: trailing)
            controls.orientation = .horizontal; controls.alignment = .centerY; controls.spacing = 6
            toggleRows.append(SK.controlRow(icon: item.id.hasPrefix("custom:") ? "star" : "switch.2",
                                            title: toggleTitle(item.id), control: controls))
        }
        if toggleRows.isEmpty {
            toggleRows.append(SK.infoRow(icon: "tray", text: L("Нет доступных переключателей.")))
        }
        toggleRows.append(SK.infoRow(icon: "info.circle",
            text: L("Включите нужные переключатели и задайте их порядок стрелками. Они отображаются в блоке «Переключатели» поповера.")))
        items.append(SK.card(toggleRows))

        // — конструктор своей кнопки-команды (Pro), демотирован в раскрывающийся блок —
        customLabelField.placeholderString = L("Подпись (например, «Очистить корзину»)")
        customIconField.placeholderString = L("Имя SF Symbol (например, trash)")
        customCmdField.placeholderString = L("Команда оболочки (например, osascript -e 'tell app \"Finder\" to empty trash')")
        for f in [customLabelField, customIconField, customCmdField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.font = Design.Font.body
        }
        customColorPopup.removeAllItems()
        customColorPopup.addItems(withTitles: SettingsStore.toggleColors)
        customColorPopup.translatesAutoresizingMaskIntoConstraints = false
        let add = GlassButton(title: L("Добавить кнопку"), symbol: "plus", cornerRadius: Design.Radius.chip)
        add.onClick = { [weak self] in self?.addCustomToggleHub() }
        let addWrap = NSStackView(views: [add])
        addWrap.orientation = .horizontal; addWrap.alignment = .centerY

        let builderCard = SK.card([
            SK.textFieldRow(icon: "textformat", field: customLabelField),
            SK.textFieldRow(icon: "star", field: customIconField),
            SK.controlRow(icon: "paintpalette", title: L("Цвет"), control: customColorPopup),
            SK.textFieldRow(icon: "terminal", field: customCmdField),
            SK.customRow(addWrap),
        ])
        let customToggleDisclosure = SK.disclosure(title: L("Пользовательская кнопка-команда"), expanded: false, rows: [
            builderCard,
            SK.infoRow(icon: "info.circle",
                text: L("Команда выполняется в оболочке от имени текущего пользователя (без root). В поле иконки укажите имя SF Symbol; список доступен в приложении «SF Symbols» от Apple.")),
        ])
        items.append(SK.card([customToggleDisclosure]))

        // Уведомления: мастер-переключатель + тестовый баннер + первый выход в сеть
        // ─────────────────────────────────────────────────────────────────────
        items.append(groupHeader(L("Уведомления")))

        let master = SettingsStore.alertsEnabled
        let masterRow = SK.toggleRow(icon: "bell.badge", title: L("Показывать уведомления"),
                                     subtitle: L("Баннеры через Центр уведомлений macOS"), isOn: master) { [weak self] on in
            SettingsStore.alertsEnabled = on
            if on { AlertsEngine.shared.primeAuthorization() } else { AlertsEngine.shared.onRulesChanged() }
            self?.select(.hub)
        }
        let testBtn = GlassButton(title: L("Отправить"), symbol: "paperplane", cornerRadius: Design.Radius.chip)
        testBtn.isEnabled = master                                   // вид и доступность совпадают с alphaValue
        testBtn.onClick = { AlertsEngine.shared.sendTest() }
        let testRow = SK.controlRow(icon: "paperplane.circle", title: L("Тестовый баннер"), control: testBtn)
        testRow.alphaValue = master ? 1 : 0.5

        // — первый выход приложения в сеть (наблюдение) —
        let fcRow = SK.toggleRow(icon: "network.badge.shield.half.filled",
                                 title: L("Уведомлять о первом выходе приложения в сеть"),
                                 subtitle: L("Только наблюдение за подключениями; трафик не перехватывается"),
                                 isOn: SettingsStore.firstConnAlerts) { on in
            SettingsStore.firstConnAlerts = on
            if on { AlertsEngine.shared.primeAuthorization() } else { FirstConnAlert.shared.reset() }
        }
        items.append(SK.card([
            masterRow,
            testRow,
            SK.infoRow(icon: "info.circle", text: L("При первом включении macOS запросит разрешение на уведомления.")),
            fcRow,
            SK.infoRow(icon: "eye", text: L("При включении текущий набор приложений запоминается без уведомлений; баннеры приходят только для новых.")),
        ]))
        items.append(SK.card([SK.infoRow(icon: "slider.horizontal.3",
            text: L("Пороговые правила для температуры, заряда и нагрузки настраиваются в разделе «Питание и охлаждение»."))]))

        return SK.scaffold(L("Поповер и уведомления"),
                           L("Состав панели, плитка быстрых действий и уведомления. Изменения применяются сразу."),
                           items)
    }

    @objc private func moveToggleUpHub(_ s: NSButton) { moveToggleHub(s.tag, -1) }

    @objc private func moveToggleDownHub(_ s: NSButton) { moveToggleHub(s.tag, +1) }

    /// Перестановка переключателя в разделе «Поповер и уведомления». Зеркалит moveToggle,
    /// но пересобирает секцию .hub (а не .toggles).
    private func moveToggleHub(_ idx: Int, _ delta: Int) {
        var layout = SettingsStore.toggleLayout
        let j = idx + delta
        guard layout.indices.contains(idx), layout.indices.contains(j) else { return }
        layout.swapAt(idx, j); SettingsStore.toggleLayout = layout
        notifyPopoverChanged(); select(.hub)
    }

    /// Удаление своей кнопки-команды в разделе «Поповер и уведомления». Зеркалит deleteCustomToggle,
    /// но пересобирает секцию .hub.
    @objc private func deleteCustomToggleHub(_ s: NSButton) {
        let layout = SettingsStore.toggleLayout
        guard layout.indices.contains(s.tag) else { return }
        let id = layout[s.tag].id
        guard id.hasPrefix("custom:") else { return }
        let cid = String(id.dropFirst("custom:".count))
        var customs = SettingsStore.customToggles; customs.removeAll { $0.id == cid }; SettingsStore.customToggles = customs
        var lay = SettingsStore.toggleLayout; lay.removeAll { $0.id == id }; SettingsStore.toggleLayout = lay
        notifyPopoverChanged(); select(.hub)
    }

    /// Добавление своей кнопки-команды в разделе «Поповер и уведомления». Зеркалит addCustomToggle,
    /// сохраняя Pro-гейт requirePro(.customToggles) и все побочные эффекты, но пересобирает секцию .hub.
    private func addCustomToggleHub() {
        guard requirePro(.customToggles) else { return }
        let label = customLabelField.stringValue.trimmingCharacters(in: .whitespaces)
        let cmd = customCmdField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, !cmd.isEmpty else {
            let a = NSAlert(); a.messageText = L("Заполните подпись и команду."); a.runModal(); return
        }
        let c = CustomToggle(id: UUID().uuidString, label: label,
                             icon: customIconField.stringValue.trimmingCharacters(in: .whitespaces),
                             command: cmd, color: customColorPopup.titleOfSelectedItem ?? "blue")
        var customs = SettingsStore.customToggles; customs.append(c); SettingsStore.customToggles = customs
        customLabelField.stringValue = ""; customIconField.stringValue = ""; customCmdField.stringValue = ""
        notifyPopoverChanged(); select(.hub)
    }

    /// Единая секция «Питание и охлаждение»: аккумулятор, вентиляторы, графический процессор и
    /// тепловые правила в одном столбце стеклянных карточек. Каждая перестройка/откат Pro внутри
    /// зовёт select(.power) — не старые кейсы (.general/.fans/.graphics/.alerts).
    private func buildPower() -> NSView {
        var items: [NSView] = []

        // 1) ВЕНТИЛЯТОРЫ — управление + per-fan редактор.
        items.append(contentsOf: buildFansItems())

        // 2) АККУМУЛЯТОР
        items.append(groupHeader(L("Аккумулятор")))
        items.append(contentsOf: buildChargeItems())

        // 3) ТЕПЛОВЫЕ ПРАВИЛА
        items.append(groupHeader(L("Тепловые правила")))
        items.append(contentsOf: buildThermalRuleItems())

        // 4) ГРАФИКА — в конец (реже трогают). Асинхронно: GPUInfo.* блокирует main.
        items.append(groupHeader(L("Графический процессор")))
        // asyncSection возвращает голый NSView-контейнер; SK.scaffold тянет во всю ширину ТОЛЬКО
        // SettingsCard/NSStackView (SettingsKit.scaffold), поэтому оборачиваем контейнер в стек
        // с выравниванием .width — иначе карточки GPU схлопнутся по intrinsic-ширине.
        let gfxAsync = asyncSection(.power, key: "power.gpu", fetch: {
            GFXState(gpus: GPUInfo.all(), active: GPUInfo.active(), switchable: GPUInfo.switchable,
                     mode: GPUInfo.mode(), isAppleSilicon: GPUInfo.isAppleSilicon)
        }) { [weak self] st in
            let v = NSStackView(views: self?.buildGraphicsViewItems(st) ?? [])
            v.orientation = .vertical; v.alignment = .width; v.spacing = Design.Space.s4
            v.translatesAutoresizingMaskIntoConstraints = false
            return v
        }
        let gfxWrap = NSStackView(views: [gfxAsync])
        gfxWrap.orientation = .vertical; gfxWrap.alignment = .width; gfxWrap.spacing = 0
        gfxWrap.translatesAutoresizingMaskIntoConstraints = false
        items.append(gfxWrap)

        return SK.scaffold(L("Питание и охлаждение"),
                           L("Управление зарядом, вентиляторами, графикой и тепловыми правилами. Изменения применяются сразу."),
                           items)
    }


    /// Пункты области «Аккумулятор» — инлайн содержимого buildChargeGroup() с ретаргетом каждого
    /// select(.power) → select(.power). Сохранены все вызовы ChargeControl.*, requirePro(.charge),
    /// installChargeHelperIfNeeded, writeChargeConfigJSON, аутлеты sailUpperLabel/sailLowerLabel/heatTempLabel.
    /// Метафора «Парусный режим» → нейтральное «Режим поддержания заряда». sailSliderRow переиспользован как есть.
    private func buildChargeItems() -> [NSView] {
        sailUpperLabel = nil; sailLowerLabel = nil; heatTempLabel = nil; chargeReadout = nil
        let mode = SettingsStore.chargeMode
        let modeIdx = (mode == "sail") ? 2 : (SettingsStore.chargeLimit == 100 ? 0 : 1)

        // Живой ридаут: крупный % заряда + краткий режим. Обновляется через select(.power).
        let pctNow = BatteryReader.systemChargePercent()
        let pctText = pctNow.map { String(format: L("%d%%"), $0) } ?? "—"
        let modeCaption = fanChargeSummary(pctNow).components(separatedBy: " · ").last ?? ""
        let readout = SK.readoutRow(icon: "battery.100", value: pctText, caption: modeCaption)

        var rows: [NSView] = [
            readout,
            SK.selectRow(icon: "battery.100.bolt", title: L("Режим заряда"),
                         options: [L("Без ограничений"), L("Лимит"), L("Режим поддержания заряда")],
                         selected: modeIdx) { [weak self] idx in
                _ = ChargeControl.setMode(["off", "limit", "sail"][max(0, min(2, idx))])
                self?.select(.power)
            },
        ]

        if modeIdx == 1 {
            // Плавный слайдер лимита 50–100% (виден только после входа в режим «Лимит» — Pro-гейт уже пройден,
            // поэтому applyLimit по ходу перетаскивания не спамит апселлом). Зелёная зона 50–80 — здоровый диапазон.
            rows.append(SK.sliderRow(icon: "bolt.badge.checkmark", title: L("Лимит заряда"),
                                     min: 50, max: 100, value: Double(SettingsStore.chargeLimit),
                                     ticks: 11, unit: "%") { [weak self] v, label in
                let pct = Int(v.rounded())
                label.stringValue = String(format: "%d%%", pct)
                if !ChargeControl.setLimit(pct) { self?.select(.power) }
            })
            rows.append(SK.infoRow(icon: "leaf", text: L("50–80% — здоровый повседневный диапазон (меньше износ). 100% удобно перед поездкой — временно снимите лимит кнопкой ниже.")))
        } else if modeIdx == 2 {
            let upperVal = NSTextField(labelWithString: String(format: "%d%%", SettingsStore.sailUpper))
            let lowerVal = NSTextField(labelWithString: String(format: "%d%%", SettingsStore.sailLower))
            sailUpperLabel = upperVal; sailLowerLabel = lowerVal
            rows.append(sailSliderRow(L("Заряжать до"), value: SettingsStore.sailUpper, min: 60, max: 90, ticks: 7, top: true, valLabel: upperVal))
            rows.append(sailSliderRow(L("Держать не ниже"), value: SettingsStore.sailLower, min: 50, max: 85, ticks: 8, top: false, valLabel: lowerVal))
            rows.append(SK.infoRow(icon: "arrow.left.and.right", text: L("Поддержание-диапазон: заряд идёт до верхней границы, затем удерживается и ждёт естественного снижения до нижней при работе от аккумулятора. Полоса между границами — минимум 5%.")))
        }

        // Защита от перегрева. Детали (порог температуры) — под раскрытием, чтобы не растягивать столбец.
        rows.append(SK.toggleRow(icon: "thermometer.high", title: L("Пауза заряда при перегреве аккумулятора"),
                                 isOn: SettingsStore.heatProtect) { [weak self] on in
            guard let self else { return }
            if on, !self.requirePro(.charge) { self.select(.power); return }
            SettingsStore.heatProtect = on
            self.writeChargeConfigJSON()
            if on { self.installChargeHelperIfNeeded() }
            self.select(.power)
        })
        if SettingsStore.heatProtect {
            let heatVal = NSTextField(labelWithString: String(format: "%d°", SettingsStore.heatTemp))
            heatTempLabel = heatVal
            rows.append(SK.disclosure(title: L("Порог перегрева"), expanded: false, rows: [
                sailSliderRow(L("Порог температуры"), value: SettingsStore.heatTemp, min: 30, max: 45, ticks: 16, top: false, valLabel: heatVal, isHeat: true),
                SK.infoRow(icon: "thermometer.snowflake", text: L("Заряд приостанавливается при температуре аккумулятора (датчик TB0T) выше порога и возобновляется после остывания.")),
            ]))
        }

        // Немедленная дозарядка.
        let topUpBtn = GlassButton(title: L("Зарядить"), symbol: "bolt.fill", cornerRadius: Design.Radius.chip)
        topUpBtn.isEnabled = (mode == "sail" || SettingsStore.chargeLimit < 100)
        topUpBtn.onClick = {
            guard ChargeControl.topUp() else { return }
            let done = NSAlert(); done.messageText = L("Готово")
            done.informativeText = L("Дозарядка до 100% временно снимает лимит примерно на час. После этого режим заряда возвращается автоматически.")
            done.runModal()
        }
        rows.append(SK.controlRow(icon: "bolt.badge.clock", title: L("Зарядить до 100% сейчас"), control: topUpBtn))

        // Плановая дозарядка — вторичный контрол, под раскрытием.
        var alarmRows: [NSView] = [
            SK.toggleRow(icon: "alarm", title: L("Полный заряд к времени"),
                         isOn: SettingsStore.chargeAlarmOn) { [weak self] on in
                _ = ChargeControl.setAlarm(on: on)
                self?.select(.power)
            },
        ]
        if SettingsStore.chargeAlarmOn {
            let timePicker = NSDatePicker()
            timePicker.datePickerStyle = .textFieldAndStepper
            timePicker.datePickerElements = .hourMinute
            timePicker.dateValue = Self.dateFromMinute(SettingsStore.chargeAlarmTargetMin)
            timePicker.target = self; timePicker.action = #selector(alarmTimeChanged(_:))
            alarmRows.append(SK.controlRow(icon: "clock", title: L("Готов к"), control: timePicker))
            let leads = [30, 45, 60, 90, 120]
            alarmRows.append(SK.selectRow(icon: "hourglass", title: L("Начинать заранее"),
                                          options: leads.map { String(format: L("за %d мин"), $0) },
                                          selected: leads.firstIndex(of: SettingsStore.chargeAlarmLeadMin) ?? 2) { idx in
                ChargeControl.setAlarm(on: SettingsStore.chargeAlarmOn, leadMin: leads[max(0, min(leads.count - 1, idx))])
            })
        }
        alarmRows.append(SK.infoRow(icon: "clock.badge.exclamationmark", text: L("Потолок поднимается до 100% в окне перед сроком (без гарантии). Работает, пока Mac не в режиме сна и заряжается. При активной защите от перегрева и горячем аккумуляторе плановая дозарядка не выполняется.")))
        rows.append(SK.disclosure(title: L("Плановая дозарядка"), expanded: false, rows: alarmRows))

        return [
            SK.card(rows),
            SK.card([
                SK.infoRow(icon: "info.circle", text: L("Ограничение заряда продлевает ресурс аккумулятора (через SMC BCLM). Требуется системный root-демон (общий с управлением вентиляторами). Эффективность зависит от модели Mac.")),
                SK.infoRow(icon: "battery.75", text: L("Режим поддержания заряда заряжает до верхнего порога, удерживает лимит на нижнем и ожидает естественного снижения заряда при работе от аккумулятора. Принудительная разрядка средствами BCLM недоступна.")),
            ]),
        ]
    }

    /// Пункты области «Вентиляторы». Выделено из buildFans() — исходная машинерия (живой список,
    /// редактор кривой, попап профиля, таймер 1.5с, авто-по-источнику) не изменена, только собрана здесь.
    /// Единственный select() в этих пунктах (в тумблере авто-по-источнику) ретаргетирован на .power.
    /// buildFans() теперь тонко делегирует сюда (см. ниже).
    private func buildFansItems() -> [NSView] {
        // Нет управляемых вентиляторов — герой-дашборд уже сообщил об этом и предложил заряд/тепловые
        // правила. Контролы управления не рисуем (управлять нечем).
        guard !FanController.fans().isEmpty else { return [] }

        SettingsStore.migrateLegacyCustomPresetIfNeeded()
        draft = activeDraft()

        editorArea = NSStackView()
        editorArea.orientation = .vertical; editorArea.alignment = .leading; editorArea.spacing = 10
        // Живой readout — читаемый (не серый caption): цель/датчик/t°.
        fanPreview.font = Design.Font.body; fanPreview.textColor = .labelColor
        fanPreview.lineBreakMode = .byWordWrapping; fanPreview.maximumNumberOfLines = 2
        rebuildEditor()

        let auto = SettingsStore.fanAutoBySource
        let pickable = auto && Licensing.shared.isPro
        let acPop = NSPopUpButton(frame: .zero, pullsDown: false)
        fillProfileChoices(acPop, selected: SettingsStore.fanProfileAC)
        acPop.target = self; acPop.action = #selector(fanACChanged(_:)); acPop.isEnabled = pickable
        let batPop = NSPopUpButton(frame: .zero, pullsDown: false)
        fillProfileChoices(batPop, selected: SettingsStore.fanProfileBattery)
        batPop.target = self; batPop.action = #selector(fanBatteryChanged(_:)); batPop.isEnabled = pickable

        let controlOn = fanDaemonInstalled
        var items: [NSView] = []

        // 1) Управление вентиляторами (демон вкл/выкл).
        items.append(groupHeader(L("Вентиляторы")))
        items.append(SK.card([
            SK.customRow(fanDaemonRow()),
            SK.infoRow(icon: controlOn ? "checkmark.shield.fill" : "info.circle",
                       text: controlOn
                           ? L("Управление разрешено. Профиль и кривая выбираются ниже.")
                           : L("Вентиляторами управляет система. Чтобы задать собственный режим, требуется разрешение управления (однократный запрос пароля администратора). При отключении управление возвращается системе."),
                       tint: controlOn ? Design.Color.levelOK : .secondaryLabelColor),
        ]))

        // 2) Режим вентиляторов: пилюли-профили (применяются сразу) + редактор + предпросмотр.
        let modeIDs = ["auto", "quiet", "balance", "turbo"]
        let selIdx = modeIDs.firstIndex(of: SettingsStore.activeFanProfileName) ?? 4   // пользовательский → «Свой»
        items.append(groupHeader(L("Режим вентиляторов")))
        var modeRows: [NSView] = [
            SK.segmentRow(icon: "fanblades", title: L("Профиль"),
                          options: [L("Авто"), L("Тихий"), L("Баланс"), L("Турбо"), L("Свой")],
                          selected: selIdx) { [weak self] idx in
                guard let self else { return }
                if idx < 4 {
                    SettingsStore.activeFanProfileName = modeIDs[idx]
                    self.draft = self.activeDraft()
                } else {
                    if let i = self.activeUserPresetIndex() {
                        self.draft = SettingsStore.userFanPresets[i]
                    } else if let first = SettingsStore.userFanPresets.first {
                        SettingsStore.activeFanProfileName = first.name; self.draft = first
                    } else {
                        guard self.requirePro(.fans) else { self.select(.power); return }
                        self.newPreset()                             // создаёт+выбирает свой профиль (или отмена)
                    }
                }
                self.applyLiveIfControlled()                          // применить к железу сразу (если управление включено)
                self.select(.power)
            },
            SK.customRow(editorArea, minHeight: 24),
            SK.customRow(fanPreview, minHeight: 24),
            SK.infoRow(icon: "info.circle", text: L("Готовые профили задают одну цель на все вентиляторы (каждый держит её в своих пределах мин/макс — обороты могут различаться). В своём профиле можно настроить каждый вентилятор отдельно.")),
        ]
        if !controlOn {
            let enableBtn = GlassButton(title: L("Включить управление…"), symbol: "bolt.circle", cornerRadius: Design.Radius.chip)
            enableBtn.onClick = { [weak self] in self?.applyProfile() }   // существующий flow установки демона + применения
            modeRows.append(SK.customRow(enableBtn))
        }
        items.append(SK.card(modeRows))

        // 4) Автоматика по источнику питания (Pro) — под раскрытием, чтобы не удлинять столбец.
        let autoSourceDisclosure = SK.disclosure(title: L("Автоматика по источнику питания"), expanded: false, rows: [
            SK.card([
                SK.toggleRow(icon: "powerplug", title: L("Профиль для сети и аккумулятора"),
                             subtitle: L("Режим переключается при подключении и отключении адаптера"),
                             isOn: auto) { [weak self] on in
                    guard let self else { return }
                    if on, !self.requirePro(.fans) { self.select(.power); return }
                    SettingsStore.fanAutoBySource = on
                    if on { self.applyCurrentSourceIfAuto() }
                    self.select(.power)
                },
                SK.controlRow(icon: "bolt", title: L("От сети"), control: acPop),
                SK.controlRow(icon: "battery.75", title: L("От аккумулятора"), control: batPop),
                SK.infoRow(icon: "info.circle", text: L("Действует, пока Kelvin запущен. После завершения работы системный режим возвращается примерно через 15 минут. Требуется разрешение управления (выше).")),
            ]),
        ])
        items.append(SK.card([autoSourceDisclosure]))
        items.append(SK.card([SK.infoRow(icon: "exclamationmark.triangle.fill",
            text: L("Ручное управление снижает охлаждение — учитывайте температуру. Защита действует постоянно: при перегреве вентиляторы форсируются на максимум; при завершении работы Kelvin возвращается системный режим."),
            tint: Design.Color.levelWarn)]))

        return items
    }

    /// Пункты области «Графический процессор». Выделено из buildGraphicsView(_:) с ретаргетом
    /// select(.power) → select(.power) и официальным тоном (без метафор «тихая/горячая карта»):
    /// «встроенный/дискретный графический процессор», «активен» вместо «работает». Пояснение трёх режимов —
    /// под раскрытием. Сохранены GPUInfo.setMode, requirePro(.gpuSwitch), диалоги подтверждения/результата.
    private func buildGraphicsViewItems(_ state: GFXState) -> [NSView] {
        let dark = (window?.effectiveAppearance ?? NSApp.effectiveAppearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let teal = Design.Color.accent(dark)
        let gpus = state.gpus
        let active = state.active

        var items: [NSView] = []

        // — Текущий активный процессор —
        if let active {
            let integrated = active.integrated
            let heroIcon = integrated ? "cpu" : "bolt.fill"
            let heroTint = integrated ? Design.Color.levelOK : teal
            let heroText = integrated
                ? String(format: L("Активен встроенный графический процессор «%@». Ниже потребление энергии и нагрев."), active.name)
                : String(format: L("Активен дискретный графический процессор «%@». Выше производительность, выше потребление энергии."), active.name)
            items.append(SK.card([SK.infoRow(icon: heroIcon, text: heroText, tint: heroTint)]))
        }

        // — Список процессоров —
        var gpuRows: [NSView] = []
        for g in gpus {
            let isActive = active?.registryID == g.registryID
            let character = g.integrated ? L("встроенный") : (g.external ? L("внешний") : L("дискретный"))
            let tag: NSView
            if isActive {
                let lbl = NSTextField(labelWithString: L("активен"))
                lbl.font = Design.Font.microStat; lbl.textColor = .systemGreen
                let pill = NSView(); pill.wantsLayer = true; pill.translatesAutoresizingMaskIntoConstraints = false
                pill.layer?.cornerRadius = Design.Radius.chip; pill.layer?.cornerCurve = .continuous
                pill.layer?.backgroundColor = Design.Color.controlFill(true).cgColor
                pill.layer?.borderWidth = 1; pill.layer?.borderColor = Design.Color.surfaceRim(true).cgColor
                pill.addSubview(lbl)
                NSLayoutConstraint.activate([
                    lbl.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6),
                    lbl.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6),
                    lbl.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
                    pill.heightAnchor.constraint(equalToConstant: 20),
                ])
                tag = pill
            } else {
                tag = NSView(); tag.translatesAutoresizingMaskIntoConstraints = false
                tag.widthAnchor.constraint(equalToConstant: 0).isActive = true
                tag.heightAnchor.constraint(equalToConstant: 0).isActive = true
            }
            let row = SK.controlRow(icon: isActive ? "circle.fill" : "circle",
                                    title: g.name,
                                    subtitle: "\(character) · \(g.vramText) \(L("видеопамяти"))",
                                    control: tag)
            row.alphaValue = isActive ? 1 : 0.6
            gpuRows.append(row)
        }
        if gpuRows.isEmpty {
            gpuRows.append(SK.infoRow(icon: "xmark.circle", text: L("Графические процессоры не обнаружены.")))
        }
        items.append(SK.card(gpuRows))

        // — Выбор режима —
        if state.switchable, let mode = state.mode {
            let selIdx = (mode == .automatic ? 0 : (mode == .integratedOnly ? 1 : 2))
            let hint: NSView
            switch mode {
            case .integratedOnly:
                hint = SK.infoRow(icon: "cpu", text: L("Постоянно активен встроенный графический процессор. Ниже нагрев и потребление энергии. Ресурсоёмким задачам может не хватить производительности."), tint: Design.Color.levelOK)
            case .discreteOnly:
                hint = SK.infoRow(icon: "bolt.fill", text: L("Постоянно активен дискретный графический процессор. Выше производительность, выше нагрев и потребление энергии."), tint: Design.Color.levelWarn)
            default:
                hint = SK.infoRow(icon: "wand.and.stars", text: L("Система выбирает графический процессор автоматически: встроенный для обычных задач, дискретный при повышенной нагрузке. Рекомендуемый режим."), tint: teal)
            }

            var modeRows: [NSView] = [
                SK.segmentRow(icon: "arrow.triangle.2.circlepath", title: L("Режим графики"),
                              options: [L("Авто"), L("Встроенный"), L("Дискретный")], selected: selIdx) { [weak self] idx in
                    guard let self else { return }
                    let modes: [GPUMode] = [.automatic, .integratedOnly, .discreteOnly]
                    let m = modes[max(0, min(2, idx))]
                    if m != .automatic, !self.requirePro(.gpuSwitch) { self.select(.power); return }
                    let a = NSAlert()
                    a.messageText = String(format: L("Переключить графику: «%@»?"), m.title)
                    a.informativeText = L("Потребуется пароль администратора. Экран может кратковременно погаснуть при смене активного процессора. Возврат — режим «Авто».")
                    a.addButton(withTitle: L("Переключить")); a.addButton(withTitle: L("Отмена"))
                    guard a.runModal() == .alertFirstButtonReturn else { self.select(.power); return }
                    let ok = GPUInfo.setMode(m)
                    let done = NSAlert()
                    done.messageText = ok ? L("Готово") : L("Не удалось")
                    done.informativeText = ok ? String(format: L("Режим: «%@». Отдельным приложениям может потребоваться перезапуск."), m.title) : L("Команда не выполнена: ввод пароля отменён или произошла ошибка.")
                    done.runModal()
                    self.select(.power)
                },
                hint,
            ]

            modeRows.append(SK.disclosure(title: L("О трёх режимах"), expanded: false, rows: [
                SK.infoRow(icon: "wand.and.stars", text: L("Авто — процессор выбирает система. Обычно оптимально по энергопотреблению."), tint: teal),
                SK.infoRow(icon: "cpu", text: L("Встроенный — всегда встроенный процессор. Ниже нагрев, выше время автономной работы."), tint: Design.Color.levelOK),
                SK.infoRow(icon: "bolt.fill", text: L("Дискретный — всегда дискретный процессор. Выше производительность, выше нагрев и потребление энергии."), tint: Design.Color.levelWarn),
                SK.infoRow(icon: "lock.shield", text: L("Смена процессора требует пароль администратора; экран может кратковременно погаснуть.")),
            ]))

            items.append(groupHeader(L("Режим графики")))
            items.append(SK.card(modeRows))
        } else if state.isAppleSilicon {
            items.append(SK.card([
                SK.infoRow(icon: "cpu", text: L("Mac на чипе Apple (серия M): графический процессор встроен в чип и всегда один. Переключение недоступно."), tint: teal),
            ]))
        } else {
            items.append(SK.card([
                SK.infoRow(icon: "info.circle", text: L("В этом Mac один графический процессор — переключение недоступно.")),
            ]))
        }

        return items
    }

    /// Пункты области «Тепловые правила» — из правил уведомлений берутся ТОЛЬКО пороги cpuTemp/gpuTemp/
    /// batteryLow/batteryFull (мастер-тумблер и «первое подключение» остаются в секции «Уведомления»).
    /// Каждое правило: тумблер + слайдер порога (виден при включении) + «Разгонять вентиляторы до максимума»
    /// (Pro, только для температурных правил). Сохранены tag=index (замыкания захватывают i), вызовы
    /// AlertsEngine, requirePro(.fans), откат через select(.power). Мастер-тумблер уведомлений соблюдён.
    private func buildThermalRuleItems() -> [NSView] {
        thermalNowLabels.removeAll()
        let master = SettingsStore.alertsEnabled
        let rules = SettingsStore.alertRules
        let thermalKinds: Set<AlertKind> = [.cpuTemp, .gpuTemp, .batteryLow, .batteryFull]

        var rows: [NSView] = []
        for (i, rule) in rules.enumerated() {
            guard thermalKinds.contains(rule.kind) else { continue }   // cpuLoad и прочее — не здесь
            // Единая грамматика «когда [датчик] (сейчас X) пересекает порог → действие»: шапка правила
            // с ЖИВЫМ текущим значением справа, затем тумблер, порог, и разгон вентиляторов.
            let nowLbl = NSTextField(labelWithString: thermalNowText(rule.kind))
            nowLbl.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium); nowLbl.textColor = .secondaryLabelColor
            thermalNowLabels[rule.kind] = nowLbl
            rows.append(SK.controlRow(icon: alertIcon(rule.kind), title: rule.kind.label, control: nowLbl))
            rows.append(SK.toggleRow(title: L("Уведомлять при срабатывании"),
                                     isOn: rule.on, enabled: master) { [weak self] on in
                var rs = SettingsStore.alertRules
                guard rs.indices.contains(i) else { return }
                rs[i].on = on; SettingsStore.alertRules = rs
                if on { AlertsEngine.shared.primeAuthorization() } else { AlertsEngine.shared.onRulesChanged() }
                self?.select(.power)
            })
            guard master && rule.on else { continue }
            let rng = rule.kind.range
            let ticks = Int((rng.hi - rng.lo) / rng.step) + 1
            rows.append(SK.sliderRow(title: L("Порог"), min: rng.lo, max: rng.hi, value: rule.threshold,
                                     ticks: ticks, unit: rule.kind.unit) { v, label in
                var rs = SettingsStore.alertRules
                guard rs.indices.contains(i) else { return }
                rs[i].threshold = v.rounded(); SettingsStore.alertRules = rs
                label.stringValue = String(format: "%.0f%@", v.rounded(), rule.kind.unit)
            })
            if rule.kind.canBoostFans {   // среди тепловых — только cpuTemp/gpuTemp
                rows.append(SK.toggleRow(icon: "fanblades", title: L("→ разгонять вентиляторы до максимума"),
                                         subtitle: L("Вентиляторы удерживаются на максимальных оборотах до снижения температуры"),
                                         isOn: rule.action == .fansMax) { [weak self] on in
                    guard let self else { return }
                    if on, !self.requirePro(.fans) { self.select(.power); return }
                    var rs = SettingsStore.alertRules
                    guard rs.indices.contains(i) else { return }
                    rs[i].action = on ? .fansMax : nil; SettingsStore.alertRules = rs
                    AlertsEngine.shared.onRulesChanged()
                })
            }
        }

        var result: [NSView] = []
        if !master {
            result.append(SK.infoRow(icon: "bell.slash", text: L("Уведомления выключены. Включите их в разделе «Уведомления», чтобы задействовать тепловые правила.")))
        }
        result.append(SK.card(rows.isEmpty ? [SK.infoRow(icon: "tray", text: L("Тепловые правила недоступны."))] : rows))
        result.append(SK.infoRow(icon: "timer", text: L("Правило: когда датчик устойчиво пересекает порог → уведомление (и, по желанию, разгон вентиляторов). Не чаще раза в 10 минут. «Низкий заряд» — только от аккумулятора, «Заряжен» — только от сети.")))
        return result
    }

    /// Консолидированная секция «Сеть и защита» (enum case .netsec).
    /// Объединяет прежние разделы Фаервол + Сеть + Журнал сети + VPN под groupHeader'ами.
    /// Функциональность сверху, три длинных списка — под SK.disclosure. Официальный тон.
    ///
    /// Загрузки, блокирующие main (socketfilterfw / lsof / scutil), вынесены в фон:
    ///  • состояние сетевого экрана + правила по программам — asyncSection(.netsec,…) внутри netsecFirewallItems;
    ///  • активные подключения — отдельный asyncSection(.netsec,…) внутри netsecConnectionsContainer;
    ///  • статус VPN — синхронный снимок VPN.status() (лёгкий), пересборка секции обновляет его.
    /// КАЖДАЯ пересборка/откат Pro зовёт self.select(.netsec) — НЕ старые кейсы .firewall/.network/.netlog.
    private func buildNetSec() -> NSView {
        var items: [NSView] = []

        // Состояние firewall + VPN читается одним фоновым снимком. Раньше один вход в раздел
        // запускал три socketfilterfw и отдельный scutil, а закрытые disclosure уже грузили списки.
        items.append(asyncSection(.netsec, key: "netsec.core", fetch: {
            let firewall: FWState?
            if Firewall.available {
                firewall = FWState(enabled: Firewall.enabled,
                                   stealth: Firewall.stealth,
                                   blockAll: Firewall.blockAll)
            } else {
                firewall = nil
            }
            return NetSecCoreState(firewall: firewall, vpn: VPN.status())
        }) { [weak self] state in
            guard let self else { return NSView() }
            var views: [NSView] = []
            if let firewall = state.firewall {
                views.append(self.netsecStatusCard(enabled: firewall.enabled,
                                                   stealth: firewall.stealth,
                                                   blockAll: firewall.blockAll))
            } else {
                views.append(SK.card([
                    SK.infoRow(icon: "exclamationmark.triangle",
                               text: L("Сетевой экран недоступен на этом Mac."),
                               tint: Design.Color.levelWarn),
                ]))
            }
            views.append(self.groupHeader(L("Защита")))
            if let firewall = state.firewall {
                views.append(self.netsecFirewallCard(firewall))
            }
            views.append(contentsOf: self.netsecVPNItems(state.vpn))

            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .width
            stack.spacing = Design.Space.s4
            stack.translatesAutoresizingMaskIntoConstraints = false
            return stack
        })

        items.append(groupHeader(L("Активные подключения")))
        items.append(netsecConnectionsContainer())

        // Тяжёлые списки действительно ленивые: до клика нет Firewall.apps(), журнала
        // и редактора /etc/hosts. Состояние раскрытия переживает локальные перестройки.
        items.append(groupHeader(L("Дополнительно")))
        if Firewall.available {
            items.append(SK.card([
                lazyDisclosure(key: "netsec.rules.disclosure", title: L("Правила по программам")) { [weak self] in
                    self?.netsecRulesContainer() ?? NSView()
                },
            ]))
        }
        items.append(SK.card([
            lazyDisclosure(key: "netsec.session.disclosure", title: L("Журнал сеанса")) { [weak self] in
                self?.netsecSessionLogContainer() ?? NSView()
            },
        ]))
        if Firewall.available {
            items.append(SK.card([
                lazyDisclosure(key: "netsec.domains.disclosure", title: L("Блокировка доменов")) { [weak self] in
                    self?.netsecDomainCard() ?? NSView()
                },
            ]))
        }

        return SK.scaffold(L("Сеть и защита"),
                           L("Сетевой экран, VPN и активные подключения этого Mac. Изменения применяются сразу."),
                           items)
    }

    /// Нейтральная карточка состояния для секции «Сеть и защита»: вердикт сетевого экрана +
    /// число программ, соединённых с сетью сейчас (считается синхронным лёгким снимком).
    /// Тон — официальный (без метафор). Async-контейнер уже гарантирует фон для socketfilterfw.
    private func netsecStatusCard(enabled: Bool, stealth: Bool, blockAll: Bool) -> NSView {
        let symbol: String
        let headline: String
        let tint: NSColor
        if !enabled {
            symbol = "exclamationmark.shield.fill"
            headline = L("Сетевой экран выключен")
            tint = Design.Color.levelWarn
        } else if stealth {
            symbol = "checkmark.shield.fill"
            headline = blockAll ? L("Сетевой экран включён · скрытый режим · только подписанные")
                                : L("Сетевой экран включён · скрытый режим")
            tint = Design.Color.levelOK
        } else {
            symbol = "checkmark.shield.fill"
            headline = blockAll ? L("Сетевой экран включён · только подписанные") : L("Сетевой экран включён")
            tint = Design.Color.levelOK
        }
        let detail = enabled
            ? L("Входящие подключения к этому Mac контролируются.")
            : L("Входящие подключения к этому Mac не контролируются.")

        let iv = NSImageView()
        iv.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iv.contentTintColor = tint
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.widthAnchor.constraint(equalToConstant: 26).isActive = true
        iv.heightAnchor.constraint(equalToConstant: 26).isActive = true
        iv.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        let head = NSTextField(labelWithString: headline)
        head.font = Design.Font.headline; head.textColor = tint
        head.lineBreakMode = .byWordWrapping; head.maximumNumberOfLines = 2
        let sub = NSTextField(wrappingLabelWithString: detail)
        sub.font = Design.Font.caption; sub.textColor = .secondaryLabelColor
        let texts = NSStackView(views: [head, sub]); texts.orientation = .vertical; texts.alignment = .leading; texts.spacing = 3
        let row = NSStackView(views: [iv, texts]); row.orientation = .horizontal; row.alignment = .top; row.spacing = 12

        return SK.card([SK.customRow(row, minHeight: 56)])
    }

    /// VPN-блок секции «Сеть и защита». Статус — бесплатно; подключение/отключение системного
    /// профиля — Pro (.vpn). ЧЕСТНО: Kelvin не VPN-провайдер, только запускает/останавливает
    /// системные профили (scutil). «Подключено» — лишь когда именованный профиль Connected.
    /// Каждая Pro-акция + пересборка зовёт self.select(.netsec).
    private func netsecVPNItems(_ status: VPN.Status) -> [NSView] {
        var rows: [NSView] = []

        // Строка статуса (free).
        if let active = status.active {
            rows.append(SK.controlRow(icon: "lock.shield", title: L("Состояние"),
                                      subtitle: String(format: L("Подключено: %@"), active.name),
                                      control: netsecStatusChip(L("Подключено"), tint: Design.Color.levelOK)))
        } else {
            rows.append(SK.controlRow(icon: "lock.open", title: L("Состояние"),
                                      subtitle: L("Не подключено"),
                                      control: netsecStatusChip(L("Не подключено"), tint: .secondaryLabelColor)))
        }

        // Управление по каждому именованному профилю (Pro).
        if status.hasProfiles {
            for p in status.profiles {
                let btn: GlassButton
                if p.connected {
                    btn = GlassButton(title: L("Отключить"), symbol: "stop.circle", cornerRadius: Design.Radius.chip)
                    btn.onClick = { [weak self] in
                        guard let self else { return }
                        guard self.requirePro(.vpn) else { return }
                        self.performSettingsAction(in: .netsec) {
                            VPN.disconnect(p.name)
                            Thread.sleep(forTimeInterval: 0.6)
                        }
                    }
                } else {
                    btn = GlassButton(title: L("Подключить"), symbol: "play.circle", cornerRadius: Design.Radius.chip)
                    btn.onClick = { [weak self] in
                        guard let self else { return }
                        guard self.requirePro(.vpn) else { return }
                        self.performSettingsAction(in: .netsec) {
                            VPN.connect(p.name)
                            Thread.sleep(forTimeInterval: 0.6)
                        }
                    }
                }
                rows.append(SK.controlRow(icon: "network.badge.shield.half.filled", title: p.name,
                                          subtitle: p.connected ? L("Подключено") : (p.enabled ? L("Профиль готов к подключению") : L("Профиль отключён в системе")),
                                          control: btn))
            }
        } else {
            rows.append(SK.infoRow(icon: "info.circle",
                text: L("Настроенных профилей VPN не найдено. Профили добавляются в Системных настройках macOS.")))
        }

        return [
            SK.card(rows),
            SK.card([SK.infoRow(icon: "info.circle",
                text: L("Kelvin управляет системными профилями VPN, но не является поставщиком VPN и не создаёт собственный туннель. Состояние «Подключено» отображается только для именованного системного профиля."))]),
        ]
    }

    /// Нейтральный статус-чип (текст+точка-цвет) для строк состояния секции «Сеть и защита».
    private func netsecStatusChip(_ text: String, tint: NSColor) -> NSView {
        let dot = NSImageView()
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        dot.symbolConfiguration = .init(pointSize: 8, weight: .regular)
        dot.contentTintColor = tint
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        let l = NSTextField(labelWithString: text)
        l.font = Design.Font.callout; l.textColor = tint
        let hs = NSStackView(views: [dot, l]); hs.orientation = .horizontal; hs.alignment = .centerY; hs.spacing = 5
        hs.translatesAutoresizingMaskIntoConstraints = false
        return hs
    }

    /// Карточка переключателей сетевого экрана для секции «Сеть и защита». Официальный тон —
    /// без метафор «охранник/дверь открыта». Каждый переключатель Pro-гейтед (.firewall);
    /// при отказе self.select(.netsec) откатывает свитч перестройкой. Побочки Firewall.set* сохранены.
    private func netsecFirewallCard(_ state: FWState) -> NSView {
        let on = state.enabled
        var rows: [NSView] = [
            SK.toggleRow(icon: "shield.lefthalf.filled", title: L("Включить сетевой экран"),
                         subtitle: L("Сетевой экран контролирует входящие подключения к этому Mac"),
                         isOn: on) { [weak self] o in
                guard let self else { return }
                if o, !self.requirePro(.firewall) { self.select(.netsec); return }
                self.performSettingsAction(in: .netsec) { _ = Firewall.setEnabled(o) }
            },
        ]
        if on {
            rows.append(SK.toggleRow(icon: "eye.slash", title: L("Скрытый режим"),
                         subtitle: L("Не отвечать на запросы к закрытым портам"),
                         isOn: state.stealth) { [weak self] o in
                guard let self else { return }
                if o, !self.requirePro(.firewall) { self.select(.netsec); return }
                self.performSettingsAction(in: .netsec) { _ = Firewall.setStealth(o) }
            })
            rows.append(SK.toggleRow(icon: "hand.raised", title: L("Блокировать всё, кроме подписанного"),
                         subtitle: L("Разрешать входящие только подписанным и системным программам"),
                         isOn: state.blockAll) { [weak self] o in
                guard let self else { return }
                if o, !self.requirePro(.firewall) { self.select(.netsec); return }
                self.performSettingsAction(in: .netsec) { _ = Firewall.setBlockAll(o) }
            })
        }
        rows.append(SK.infoRow(icon: "key",
            text: L("Используется встроенный сетевой экран macOS. Для изменения настроек система запросит пароль администратора.")))
        return SK.card(rows)
    }

    /// Асинхронный контейнер списка активных подключений для секции «Сеть и защита».
    /// Фон: lsof-снимок + офлайн-гео. Main: резолв имён/иконок → netsecConnectionsCard.
    /// Ретаргет прежнего asyncSection(.network,…) на .netsec.
    private func netsecConnectionsContainer() -> NSView {
        return asyncSection(.netsec, key: "netsec.connections", fetch: { () -> RawNet in
            let raw = Connections.rawSnapshot()
            var geo: [String: String?] = [:]
            for rp in raw { for c in rp.conns where geo[c.remoteIP] == nil {
                geo[c.remoteIP] = GeoIP.label(for: c.remoteIP)
            } }
            return RawNet(raw: raw, geoByLabel: geo)
        }) { [weak self] net -> NSView in
            let apps: [GeoApp] = Connections.resolveOnMain(net.raw).map { app in
                GeoApp(app: app, conns: app.conns.map { GeoConn(conn: $0, geo: net.geoByLabel[$0.remoteIP] ?? nil) })
            }
            return self?.netsecConnectionsCard(apps) ?? NSView()
        }
    }

    /// Карточка активных подключений (компактная, префикс 20) для секции «Сеть и защита».
    /// Переиспользует netAppRow(ga) для строк по программам (флаги стран + ip:port +
    /// «Закрыть входящий доступ» — Pro через blockAppIncoming(path:)). Честная граница —
    /// нейтральными словами: Kelvin блокирует только входящие, не прерывает исходящий трафик программ.
    /// «Обновить» ретаргетит на .netsec.
    private func netsecConnectionsCard(_ apps: [GeoApp]) -> NSView {
        let total = apps.reduce(0) { $0 + $1.app.conns.count }
        let refresh = GlassButton(title: L("Обновить"), symbol: "arrow.clockwise", cornerRadius: Design.Radius.chip)
        refresh.onClick = { [weak self] in self?.select(.netsec) }

        var rows: [NSView] = [
            SK.controlRow(icon: "network",
                          title: apps.isEmpty
                            ? L("Сейчас нет программ с активными подключениями")
                            : String(format: L("Программ с активными подключениями: %d · подключений: %d"), apps.count, total),
                          control: refresh),
        ]
        if apps.isEmpty {
            rows.append(SK.infoRow(icon: "checkmark.circle",
                text: L("Активных исходящих подключений не обнаружено. Список — снимок на текущий момент.")))
        } else {
            for ga in apps.prefix(20) { rows.append(SK.customRow(netAppRow(ga), minHeight: 60)) }
            if apps.count > 20 {
                rows.append(SK.infoRow(icon: "ellipsis.circle",
                    text: String(format: L("Показаны первые 20 программ из %d."), apps.count)))
            }
        }
        rows.append(SK.infoRow(icon: "hand.raised",
            text: L("«Закрыть доступ» запрещает программе входящие подключения через сетевой экран (требуется пароль администратора). Исходящий трафик программ Kelvin не прерывает — для этого необходим системный сетевой фильтр.")))
        return SK.card(rows)
    }

    /// Асинхронный контейнер «Правила по программам» для секции «Сеть и защита».
    /// Фон: чтение правил сетевого экрана. Main: netsecRulesCard. Ретаргет .firewall → .netsec.
    private func netsecRulesContainer() -> NSView {
        return asyncSection(.netsec, key: "netsec.rules", fetch: { Firewall.apps() }) { [weak self] apps in
            self?.netsecRulesCard(apps) ?? NSView()
        }
    }

    /// Карточка «Правила по программам» (входящие) для секции «Сеть и защита».
    /// Свитч blocked/allowed, tag=index через захват i в замыкании; побочки Firewall.block/unblock
    /// сохранены; i-capture через NSOpenPanel сохранён. Pro-гейт (.firewall), откат select(.netsec).
    private func netsecRulesCard(_ apps: [Firewall.AppRule]) -> NSView {
        fwApps = apps
        var ruleRows: [NSView] = [
            SK.infoRow(icon: "app.badge.checkmark",
                text: L("Правило запрещает выбранной программе принимать входящие подключения. Включённый переключатель означает блокировку.")),
        ]
        for (i, a) in fwApps.prefix(12).enumerated() {
            let icon = NSImageView()
            icon.image = NSWorkspace.shared.icon(forFile: a.path)
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
            let name = NSTextField(labelWithString: a.name); name.font = Design.Font.body
            name.lineBreakMode = .byTruncatingMiddle
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let statusText = NSTextField(labelWithString: a.blocked ? L("заблокирована") : L("разрешена"))
            statusText.font = Design.Font.caption
            statusText.textColor = a.blocked ? Design.Color.levelWarn : .secondaryLabelColor
            let nameCol = NSStackView(views: [name, statusText])
            nameCol.orientation = .vertical; nameCol.alignment = .leading; nameCol.spacing = 1
            let sw = KSwitch(on: a.blocked)
            sw.onChange = { [weak self] o in
                guard let self else { return }
                guard i < self.fwApps.count else { return }
                let rule = self.fwApps[i]
                if o, !self.requirePro(.firewall) { self.select(.netsec); return }
                self.performSettingsAction(in: .netsec) {
                    _ = o ? Firewall.block(rule.path) : Firewall.unblock(rule.path)
                }
            }
            let spacer = NSView(); spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            let hs = NSStackView(views: [icon, nameCol, spacer, sw])
            hs.orientation = .horizontal; hs.alignment = .centerY; hs.spacing = 9
            ruleRows.append(SK.customRow(hs))
        }
        if fwApps.prefix(12).isEmpty {
            ruleRows.append(SK.infoRow(icon: "tray", text: L("Правила ещё не заданы. Чтобы добавить программу, нажмите «Выбрать программу…».")))
        }
        let addBtn = GlassButton(title: L("Выбрать программу…"), symbol: "plus", cornerRadius: Design.Radius.chip)
        addBtn.onClick = { [weak self] in
            guard let self else { return }
            guard self.requirePro(.firewall) else { return }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                self.performSettingsAction(in: .netsec) { _ = Firewall.block(url.path) }
            }
        }
        ruleRows.append(SK.controlRow(icon: "plus.app", title: L("Заблокировать новую программу"),
                                      subtitle: L("Выбранная программа перестанет принимать входящие подключения"), control: addBtn))
        return SK.card(ruleRows)
    }

    /// Асинхронный контейнер «Журнал сеанса» для секции «Сеть и защита».
    /// Снимок леджера на main (не thread-safe) → рендер строк в build. Ретаргет .netlog → .netsec.
    private func netsecSessionLogContainer() -> NSView {
        // Леджер принадлежит main thread; снимок дешёвый. Тяжёлым раньше был рендер сотен stack-row,
        // теперь список виртуализирован через NSTableView.
        return netsecSessionLogCard(AppSession.connectionLog())
    }

    /// Карточка «Журнал сеанса»: исходящие соединения за сессию. Обновить/Очистить
    /// (AppSession.clearLog), кэп рендера 250, нейтральная заметка «только в памяти».
    /// Переиспользует netLogRow. Все действия ретаргетят select(.netsec).
    private func netsecSessionLogCard(_ log: [AppSession.LedgerEntry]) -> NSView {
        let refresh = GlassButton(title: L("Обновить"), symbol: "arrow.clockwise", cornerRadius: Design.Radius.chip)
        refresh.onClick = { [weak self] in self?.requestSectionReload(.netsec, delay: 0) }
        let clear = GlassButton(title: L("Очистить журнал"), symbol: "trash", cornerRadius: Design.Radius.chip)
        clear.onClick = { [weak self] in
            AppSession.clearLog()
            self?.requestSectionReload(.netsec, delay: 0)
        }
        let buttons = NSStackView(views: [refresh, clear])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        var rows: [NSView] = [
            SK.controlRow(icon: "list.bullet.rectangle",
                          title: log.isEmpty
                            ? L("Записей за эту сессию пока нет")
                            : String(format: L("Записей за сессию: %d"), log.count),
                          control: buttons),
            SK.infoRow(icon: "memorychip",
                text: L("Журнал хранится только в памяти и очищается при завершении Kelvin или перезагрузке. Данные никуда не сохраняются и не передаются.")),
        ]

        if log.isEmpty {
            rows.append(SK.infoRow(icon: "tray",
                text: L("Записей пока нет. Соединения фиксируются, пока открыт Kelvin.")))
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            formatter.locale = Locale(identifier: I18n.current.rawValue)
            let table = SettingsListTable(items: log, rowHeight: 44) { [weak self] entry in
                self?.netLogRow(entry, formatter) ?? NSView()
            }
            let visibleRows = min(max(log.count, 3), 7)
            rows.append(SK.stretchRow(table, height: CGFloat(visibleRows) * 44))
        }
        return SK.card(rows)
    }

    /// Карточка «Блокировка доменов» (/etc/hosts) для секции «Сеть и защита».
    /// Редактор domainText + HostBlock.apply, Pro-гейт (.firewall). Официальный тон.
    /// Не зависит от FWState.domains — читает текущий список синхронно (лёгкое чтение файла).
    private func netsecDomainCard() -> NSView {
        let dscroll = NSScrollView()
        dscroll.hasVerticalScroller = true; dscroll.borderType = .lineBorder
        dscroll.translatesAutoresizingMaskIntoConstraints = false
        if !domainTextLoaded { domainText.string = HostBlock.current().joined(separator: "\n"); domainTextLoaded = true }
        domainText.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        domainText.isRichText = false
        domainText.isAutomaticQuoteSubstitutionEnabled = false
        domainText.isVerticallyResizable = true
        domainText.isHorizontallyResizable = false
        domainText.autoresizingMask = [.width]
        domainText.textContainer?.widthTracksTextView = true
        dscroll.documentView = domainText
        let applyBtn = GlassButton(title: L("Применить"), symbol: "checkmark.circle", cornerRadius: Design.Radius.chip)
        applyBtn.onClick = { [weak self] in
            guard let self else { return }
            guard self.requirePro(.firewall) else { return }
            let domains = self.domainText.string.split(separator: "\n").map(String.init)
            self.performSettingsAction(in: .netsec) { _ = HostBlock.apply(domains) }
        }
        return SK.card([
            SK.infoRow(icon: "nosign",
                text: L("Перечисленные домены блокируются для всех программ этого Mac. По одному адресу на строку.")),
            SK.stretchRow(dscroll, height: 104),
            SK.controlRow(icon: "square.and.arrow.down", title: L("Сохранить и применить"), control: applyBtn),
            SK.infoRow(icon: "key",
                text: L("Изменяется системный файл /etc/hosts, поэтому требуется пароль администратора.")),
        ])
    }
    /// Собрать кросс-вкладочный отчёт (в фоне) и предложить сохранить .md + показать в Finder.
    @objc private func makeDiagnosticReport(_ sender: NSButton) {
        let prev = sender.title
        sender.isEnabled = false; sender.title = L("Готовлю…")
        let log = AppSession.connectionLog()          // снимок на main (леджер не thread-safe) → отдаём в фон
        DiagnosticReport.generate(log: log) { [weak sender] md in
            sender?.isEnabled = true; sender?.title = prev
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "Kelvin-diagnostics.md"
            panel.title = L("Диагностический отчёт")
            panel.begin { resp in
                guard resp == .OK, let url = panel.url else { return }
                try? md.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
    /// Кредиты сторонних данных. Гео-база DB-IP под CC BY 4.0 — атрибуция обязательна.
    private func creditsRow() -> NSView {
        let label = NSTextField(labelWithString: L("Геоданные стран — DB-IP, лицензия CC BY 4.0"))
        label.font = Design.Font.caption; label.textColor = .tertiaryLabelColor
        let link = NSButton(title: "db-ip.com", target: self, action: #selector(openDBIP))
        link.isBordered = false
        link.contentTintColor = Design.Color.accent(true)
        link.font = Design.Font.caption
        link.setButtonType(.momentaryChange)
        let row = NSStackView(views: [label, link]); row.spacing = 5; row.alignment = .firstBaseline
        return row
    }
    @objc private func openDBIP() { if let u = URL(string: "https://db-ip.com") { NSWorkspace.shared.open(u) } }

    /// Fullscreen-честность: депплинк в панель «Пункт управления / Строка меню» Системных настроек.
    /// Первичный anchor — панель Control Center (Ventura+); фолбэк — общий раздел Системных настроек.
    @objc private func openMenuBarSettings() {
        let primary = "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"
        if let u = URL(string: primary) { NSWorkspace.shared.open(u); return }
        if let u = URL(string: "x-apple.systempreferences:") { NSWorkspace.shared.open(u) }
    }
    @objc private func showWelcome() { OnboardingWindowController.shared.present() }
    @objc private func checkUpdates() { Updater.checkManually() }
}
