import Foundation
import AppKit
import UserNotifications
import Darwin   // sysctlbyname

/// Тип порогового уведомления. Free-фича: приложение ВИДИТ и предупреждает
/// (управление — Pro). Громчайший гэп против iStat/Stats/TG Pro/AlDente — у них
/// alerting есть у всех, у нас не было ни одного.
enum AlertKind: String, Codable, CaseIterable {
    case cpuTemp, gpuTemp, batteryLow, batteryFull, cpuLoad

    /// Срабатывает при ПРЕВЫШЕНИИ порога (true) или при падении НИЖЕ (false).
    var above: Bool { self != .batteryLow }
    /// Единица для подписи значения.
    var unit: String { (self == .batteryLow || self == .batteryFull || self == .cpuLoad) ? "%" : "°" }
    /// Диапазон слайдера порога: (min, max, step).
    var range: (lo: Double, hi: Double, step: Double) {
        switch self {
        case .cpuTemp, .gpuTemp: return (70, 105, 1)
        case .batteryLow:        return (5, 50, 5)
        case .batteryFull:       return (50, 100, 5)
        case .cpuLoad:           return (50, 100, 5)
        }
    }
    var defaultThreshold: Double {
        switch self {
        case .cpuTemp: return 95
        case .gpuTemp: return 90
        case .batteryLow: return 20
        case .batteryFull: return 80
        case .cpuLoad: return 90
        }
    }
    /// Что включено «из коробки»: только редко-срабатывающие и полезные сразу
    /// (низкий заряд + реальный перегрев CPU). Остальное — по желанию.
    var defaultOn: Bool { self == .batteryLow || self == .cpuTemp }

    /// Поддерживает ли тип авто-ответ «кулеры на максимум» (только тепло/нагрузка; батарее не применимо).
    var canBoostFans: Bool { self == .cpuTemp || self == .gpuTemp || self == .cpuLoad }

    var label: String {
        switch self {
        case .cpuTemp: return L("Перегрев CPU")
        case .gpuTemp: return L("Перегрев GPU")
        case .batteryLow: return L("Низкий заряд")
        case .batteryFull: return L("Батарея заряжена")
        case .cpuLoad: return L("Высокая нагрузка CPU")
        }
    }
    /// Текст-разбор: что произошло (для тела баннера).
    func body(_ v: Double) -> String {
        switch self {
        case .cpuTemp:     return String(format: L("CPU нагрелся до %.0f°. Проверьте нагрузку и вентиляцию."), v)
        case .gpuTemp:     return String(format: L("GPU нагрелся до %.0f°. Проверьте нагрузку и вентиляцию."), v)
        case .cpuLoad:     return String(format: L("Загрузка CPU держится на %.0f%%."), v)
        case .batteryLow:  return String(format: L("Осталось %.0f%% заряда. Подключите зарядку."), v)
        case .batteryFull: return String(format: L("Заряд достиг %.0f%%. Можно отключить адаптер — это бережёт батарею."), v)
        }
    }
}

/// Авто-ответ (Pro) на устойчивое срабатывание правила. Пока один: форс кулеров на максимум.
enum AlertAction: String, Codable { case fansMax }

/// Правило: тип + вкл/выкл + порог (+ опц. Pro-действие). Хранится JSON-массивом в UserDefaults
/// (см. SettingsStore.alertRules — там же мердж дефолтов для новых типов).
/// `action` — Optional НАМЕРЕННО: синтез-Codable терпит отсутствие ключа → старые сохранённые правила целы.
struct AlertRule: Codable, Equatable {
    var kind: AlertKind
    var on: Bool
    var threshold: Double
    var action: AlertAction? = nil
}

/// Сторож порогов. Лёгкий: читает SMC/нагрузку ТОЛЬКО под включённые правила
/// и только когда его дёргают (раз в ~15 с из tick). Гистерезис + дебаунс +
/// кулдаун — чтобы не спамить на дребезге у границы.
final class AlertsEngine: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AlertsEngine()
    private static let authorizationCacheKey = "notifications.authorizationGranted"
    private override init() {
        super.init()
        if let cached = UserDefaults.standard.object(forKey: Self.authorizationCacheKey) as? Bool {
            authorizationState = cached ? .authorized : .denied
            authorized = cached
            if !cached {
                SettingsStore.alertsEnabled = false
                SettingsStore.firstConnAlerts = false
            }
        } else {
            // Старые сборки включали master-toggle по умолчанию, даже не зная TCC.
            // До первого явного согласия считаем уведомления выключенными.
            SettingsStore.alertsEnabled = false
            SettingsStore.firstConnAlerts = false
        }
    }

    enum AuthorizationState: Equatable {
        case notDetermined
        case authorized
        case denied
        case unavailable

        var canPost: Bool {
            if case .authorized = self { return true }
            return false
        }
    }

    private struct Rt { var armed = true; var streak = 0; var lastFired: Date? = nil }
    private var rt: [AlertKind: Rt] = [:]
    private var authorized = false
    private(set) var authorizationState: AuthorizationState = .notDetermined
    private var authorizationRequestInFlight = false
    private var authorizationCompletions: [(Bool) -> Void] = []

    // Авто-ответ «кулеры на максимум» — сериализован НА УРОВНЕ ДВИЖКА (не per-rule): один захват профиля до
    // форса, восстановление только когда отпустило ПОСЛЕДНЕЕ форсящее правило. Иначе multi-rule/fan-auto/ручная
    // смена профиля затирали бы захват (см. ревью). `boostKinds` — типы с активным форсом.
    //
    // Threading: эти поля мутируются из evaluate()/cross() (вызывается из tick() на main) и из
    // onRulesChanged() (UI-хендлеры на main). Потеря capture boostSaved оставила бы кулеры на Fnmax.
    // Методы-мутаторы предназначены для вызова на main; lock страхует от реентрантности через
    // notification-callback и будущих off-main вызовов.
    private let boostLock = NSLock()
    private var boostKinds: Set<AlertKind> = []
    private var boostSaved: String? = nil
    private static let boostID = "turbo"                 // транзиент-профиль форса (демон клампит к Fnmax)
    /// Активен ли аварийный форс кулеров — чтобы авто-по-источнику его не перебивала.
    var isBoostActive: Bool { boostLock.lock(); defer { boostLock.unlock() }; return !boostKinds.isEmpty }

    /// Ставится делегатом, чтобы баннеры показывались даже когда приложение «активно»
    /// (агент в строке меню фронтом почти не бывает, но подстрахуемся).
    func start() {
        UNUserNotificationCenter.current().delegate = self
        registerFirstConnCategories()
    }

    // MARK: - First-connection (Радар 2.0): категория + постинг + обработка действия
    private static let fcShowCat = "kelvin.firstconn.show"     // одно действие «Показать» → радар

    private func registerFirstConnCategories() {
        let show = UNNotificationAction(identifier: "SHOW", title: L("Показать"), options: [.foreground])
        let showCat = UNNotificationCategory(identifier: Self.fcShowCat, actions: [show], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([showCat])
    }

    /// Баннер «приложение впервые в сети» (наблюдение). Тело — реальные данные lsof: страна + endpoint (ip:port).
    /// Честно: НЕ предлагаем блок из баннера — надёжного блока нет (lsof даёт IP, а не домен; PTR≠forward-домен;
    /// macOS ALF режет лишь входящие). Действие — «Показать» радар, где видно, какое приложение и куда ходит.
    func postFirstConn(app: String, endpoint: String, code: String?) {
        var body = endpoint
        if let code = code { body = "\(GeoIP.flag(code)) \(GeoIP.name(code)) · " + endpoint }
        withAuthorization {
            let c = UNMutableNotificationContent()
            c.title = String(format: L("%@ впервые в сети"), app)
            c.body = body
            c.sound = .default
            c.categoryIdentifier = Self.fcShowCat
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.fcID(app), content: c, trigger: nil))
        }
    }

    /// Сводный баннер антифлуда: несколько новых приложений в одном снимке (VPN/старт среды/восст. сети).
    func postFirstConnSummary(count: Int) {
        guard count > 0 else { return }
        withAuthorization {
            let c = UNMutableNotificationContent()
            c.title = L("Ещё приложения впервые в сети")
            c.body = String(format: L("Всего новых: %d. Откройте радар со списком."), count)
            c.sound = .default
            c.categoryIdentifier = Self.fcShowCat
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "kelvin.firstconn.summary", content: c, trigger: nil))
        }
    }

    /// Стабильный непереполняемый id из имени приложения (abs(hashValue) трапит на Int.min и посолен per-run).
    private static func fcID(_ app: String) -> String {
        let slug = app.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
            .reduce(into: "") { $0.append($1) }
        return "kelvin.firstconn." + (slug.isEmpty ? "app" : slug)
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    /// Тап по баннеру/действию «Показать» → открыть радар (там видно, какое приложение и куда ходит).
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if response.notification.request.content.categoryIdentifier == Self.fcShowCat {
            DispatchQueue.main.async { FirstConnAlert.shared.showRadar?() }
        }
        done()
    }

    /// Главный проход. battery уже прочитан в tick — передаём бесплатно.
    /// popoverOpen: если поповер открыт, его снимок уже сэмплит CPU каждую секунду —
    /// переиспользуем свежее значение, а не зовём cpu() повторно (иначе back-to-back
    /// вызов дал бы «нулевую» дельту → провал в графике загрузки).
    func evaluate(battery b: BatteryInfo, popoverOpen: Bool, sampledCPULoad: Double? = nil) {
        guard SettingsStore.alertsEnabled, authorized else { return }
        let rules = SettingsStore.alertRules.filter { $0.on }
        guard !rules.isEmpty else { return }

        let needTemp = rules.contains { $0.kind == .cpuTemp || $0.kind == .gpuTemp }
        let needLoad = rules.contains { $0.kind == .cpuLoad }
        var cpuTemp: Double?, gpuTemp: Double?, cpuLoad: Double?
        
        if needTemp {
            let smc = EnergyModel.smc
            if smc.available {
                // Использовать resolved sensor set для получения подтверждённых ключей.
                let model = Self.sysctlStr("hw.model")
                let arch = Self.architecture()
                let catalog = SensorCatalog.build()
                let resolved = SensorResolver.resolve(
                    model: model,
                    architecture: arch,
                    catalog: catalog,
                    readValue: { smc.read($0) }
                )
                
                func maxOf(_ ks: [String]) -> Double? {
                    ks.compactMap { smc.read($0) }.filter { $0 > -40 && $0 < 130 }.max()
                }
                
                // Брать ключи из resolved set, fallback на legacy-списки.
                cpuTemp = maxOf(resolved.cpuTemperature?.keys ?? ["TCXC","TC0E","TC1C","TC2C","TC3C","TC4C"])
                gpuTemp = maxOf(resolved.gpuTemperature?.keys ?? ["TG0D","TG0P"])
            }
        }
        if needLoad {
            cpuLoad = sampledCPULoad.map { $0 * 100 } ?? (SystemUsage.shared.cpu() * 100)
        }

        for rule in rules {
            switch rule.kind {
            case .cpuTemp: if let v = cpuTemp { cross(rule, v, margin: 6, minStreak: 2) }
            case .gpuTemp: if let v = gpuTemp { cross(rule, v, margin: 6, minStreak: 2) }
            case .cpuLoad: if let v = cpuLoad { cross(rule, v, margin: 12, minStreak: 2) }
            case .batteryLow:
                guard b.present else { continue }
                if b.external || b.charging { rearm(.batteryLow); continue }   // на зарядке — перевзвести
                cross(rule, Double(b.charge), margin: 6, minStreak: 1)
            case .batteryFull:
                guard b.present else { continue }
                if !b.external { rearm(.batteryFull); continue }               // отключили адаптер — перевзвести
                cross(rule, Double(b.charge), margin: 4, minStreak: 1)
            }
        }
    }

    /// Гистерезис: сработка по серии (дебаунс), «взвод» обратно только когда значение
    /// ушло за порог на margin. Плюс кулдаун 10 мин как страховка от дребезга.
    private func cross(_ rule: AlertRule, _ value: Double, margin: Double, minStreak: Int) {
        var st = rt[rule.kind] ?? Rt()
        let triggered = rule.kind.above ? value >= rule.threshold : value <= rule.threshold
        let released  = rule.kind.above ? value <= rule.threshold - margin : value >= rule.threshold + margin
        st.streak = triggered ? st.streak + 1 : 0
        if released { st.armed = true }

        // АВТО-ОТВЕТ «кулеры на максимум» (Pro): один захват профиля на ВСЕ форсящие правила; форс держим,
        // пока breach'ит хоть одно; восстановление — когда отпустило ПОСЛЕДНЕЕ. Откат и при потере Pro
        // (revert вне isPro-гейта). Safety целиком в демоне (клампит к Fnmax, санитайз, аренда).
        if rule.action == .fansMax, FanController.daemonInstalled {
            // Снимаем/добавляем вид под локом; I/O профиля — вне локa, чтобы не держать его через apply.
            boostLock.lock()
            let boosting = boostKinds.contains(rule.kind)
            let isPro = Licensing.shared.isPro
            var actionToApply: String? = nil          // Self.boostID — начать форс
            var shouldEndBoost = false                // восстановить профиль
            if !boosting, st.streak >= minStreak, isPro {
                if boostKinds.isEmpty {                                     // первый форс — захват ДО действия
                    boostSaved = SettingsStore.activeFanProfileName
                    actionToApply = Self.boostID
                }
                boostKinds.insert(rule.kind)
            } else if boosting, released || !isPro {       // отпустило ИЛИ потеряли Pro
                boostKinds.remove(rule.kind)
                shouldEndBoost = boostKinds.isEmpty
            }
            boostLock.unlock()

            if let profile = actionToApply {
                FanController.applyProfileHeadless(named: profile)
            }
            if shouldEndBoost { endBoost() }                       // последний — восстановление
        }

        if st.streak >= minStreak && st.armed {
            let cooled = st.lastFired.map { Date().timeIntervalSince($0) > 600 } ?? true
            if cooled {
                st.armed = false
                st.lastFired = Date()
                notify(rule.kind, value: value)
            }
        }
        rt[rule.kind] = st
    }

    private func rearm(_ k: AlertKind) {
        var st = rt[k] ?? Rt(); st.armed = true; st.streak = 0; rt[k] = st
    }

    /// Настройки алертов изменились — снять форс у типов, чей fansMax-ответ больше НЕ активен
    /// (отключили правило/действие/мастер), иначе форс завис бы до истечения аренды. Зовётся из UI-хендлеров.
    func onRulesChanged() {
        let active = Set(SettingsStore.alertRules.filter { $0.on && $0.action == .fansMax }.map { $0.kind })
        let master = SettingsStore.alertsEnabled
        boostLock.lock()
        let drop = boostKinds.filter { !master || !active.contains($0) }
        guard !drop.isEmpty else { boostLock.unlock(); return }
        boostKinds.subtract(drop)
        let shouldEndBoost = boostKinds.isEmpty
        boostLock.unlock()
        if shouldEndBoost { endBoost() }
    }

    /// Снять форс: восстановить профиль. Только если он ВСЁ ЕЩЁ «наш turbo» — чужую смену (ручную/авто)
    /// во время форса НЕ затираем. При активной авто-по-источнику возвращаем профиль ТЕКУЩЕГО источника
    /// (а не устаревший захват), иначе — захваченный до форса.
    ///
    /// check-then-apply выполняется ПОД boostLock целиком: иначе между `guard active ==
    /// turbo` и `applyProfileHeadless` (который пишет active) могла вписаться ручная смена
    /// профиля, и endBoost перезаписал бы выбор пользователя.
    private func endBoost() {
        boostLock.lock()
        defer { boostLock.unlock() }
        let saved = boostSaved
        boostSaved = nil
        guard SettingsStore.activeFanProfileName == Self.boostID else { return }   // кто-то сменил профиль сам
        if SettingsStore.fanAutoBySource, Licensing.shared.isPro {
            let ext = BatteryReader.read()?.external ?? true
            FanController.applyProfileHeadless(named: ext ? SettingsStore.fanProfileAC : SettingsStore.fanProfileBattery)
        } else {
            FanController.applyProfileHeadless(named: saved ?? "auto")
        }
    }

    private func notify(_ kind: AlertKind, value: Double) {
        let title = kind.label, body = kind.body(value)
        withAuthorization {
            let c = UNMutableNotificationContent()
            c.title = title; c.body = body; c.sound = .default
            let req = UNNotificationRequest(identifier: "kelvin.alert.\(kind.rawValue)", content: c, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
    }

    /// Тестовый баннер из настроек — заодно вызывает системный запрос разрешения в контексте.
    func sendTest(completion: ((Bool) -> Void)? = nil) {
        requestOrOpenSettings { granted in
            guard granted else {
                completion?(false)
                return
            }
            let c = UNMutableNotificationContent()
            c.title = L("Уведомления Kelvin"); c.body = L("Так выглядит предупреждение. Можно настроить пороги ниже."); c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "kelvin.alert.test", content: c, trigger: nil))
            completion?(true)
        }
    }

    /// Спросить разрешение только из явного пользовательского действия.
    /// После отказа macOS больше не показывает prompt — UI должен вести в Settings.
    func primeAuthorization(completion: ((Bool) -> Void)? = nil) {
        requestOrOpenSettings(completion: completion)
    }

    /// Возвращает последнее состояние, подтверждённое явным пользовательским
    /// действием. Намеренно не вызывает getNotificationSettings: на поддерживаемых
    /// старых macOS этот API уже приводил к SIGSEGV при старте/onboarding.
    func refreshAuthorizationStatus(completion: ((AuthorizationState) -> Void)? = nil) {
        DispatchQueue.main.async { completion?(self.authorizationState) }
    }

    /// Контекстная CTA. requestAuthorization безопасно повторять: macOS показывает
    /// prompt только при первом выборе, затем возвращает фактический результат.
    /// Запросы сериализованы, чтобы быстрые клики не создавали конкурирующие callbacks.
    func requestOrOpenSettings(completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.main.async {
            if let completion { self.authorizationCompletions.append(completion) }
            guard !self.authorizationRequestInFlight else { return }
            self.authorizationRequestInFlight = true
            let shouldOpenSettingsOnFailure = self.authorizationState == .denied
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, error in
                DispatchQueue.main.async {
                    let state: AuthorizationState = error == nil
                        ? (ok ? .authorized : .denied)
                        : .unavailable
                    self.applyAuthorization(state)
                    self.authorizationRequestInFlight = false
                    let completions = self.authorizationCompletions
                    self.authorizationCompletions.removeAll()
                    if !ok, shouldOpenSettingsOnFailure { self.openNotificationSettings() }
                    completions.forEach { $0(ok) }
                }
            }
        }
    }

    private func withAuthorization(_ post: @escaping () -> Void) {
        // Фоновое событие никогда не вызывает ни системный prompt, ни TCC-query.
        // Состояние меняется только после явной CTA пользователя.
        guard authorized else { return }
        post()
    }

    private func mapAuthorization(_ status: UNAuthorizationStatus) -> AuthorizationState {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        @unknown default: return .unavailable
        }
    }

    private func applyAuthorization(_ state: AuthorizationState) {
        authorizationState = state
        authorized = state.canPost
        switch state {
        case .authorized:
            UserDefaults.standard.set(true, forKey: Self.authorizationCacheKey)
        case .denied:
            UserDefaults.standard.set(false, forKey: Self.authorizationCacheKey)
            SettingsStore.alertsEnabled = false
            SettingsStore.firstConnAlerts = false
            onRulesChanged()
        case .notDetermined, .unavailable:
            break
        }
    }

    private func openNotificationSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.trykelvin.kelvin",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
    
    // MARK: - Helpers для sysctl
    
    /// Хелпер для sysctl-строк.
    private static func sysctlStr(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "—" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "—" }
        return String(cString: buf)
    }
    
    /// Определить архитектуру (arm64/x86_64).
    private static func architecture() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buf, &size, nil, 0) == 0 else { return "unknown" }
        let machine = String(cString: buf)
        return machine.hasPrefix("arm") ? "arm64" : "x86_64"
    }
}
