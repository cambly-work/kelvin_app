import Foundation
import AppKit
import UserNotifications

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
    private override init() { super.init() }

    private struct Rt { var armed = true; var streak = 0; var lastFired: Date? = nil }
    private var rt: [AlertKind: Rt] = [:]
    private var authorized = false

    // Авто-ответ «кулеры на максимум» — сериализован НА УРОВНЕ ДВИЖКА (не per-rule): один захват профиля до
    // форса, восстановление только когда отпустило ПОСЛЕДНЕЕ форсящее правило. Иначе multi-rule/fan-auto/ручная
    // смена профиля затирали бы захват (см. ревью). `boostKinds` — типы с активным форсом.
    private var boostKinds: Set<AlertKind> = []
    private var boostSaved: String? = nil
    private static let boostID = "turbo"                 // транзиент-профиль форса (демон клампит к Fnmax)
    /// Активен ли аварийный форс кулеров — чтобы авто-по-источнику его не перебивала.
    var isBoostActive: Bool { !boostKinds.isEmpty }

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
        guard SettingsStore.alertsEnabled else { return }
        let rules = SettingsStore.alertRules.filter { $0.on }
        guard !rules.isEmpty else { return }

        let needTemp = rules.contains { $0.kind == .cpuTemp || $0.kind == .gpuTemp }
        let needLoad = rules.contains { $0.kind == .cpuLoad }
        var cpuTemp: Double?, gpuTemp: Double?, cpuLoad: Double?
        if needTemp {
            let smc = EnergyModel.smc
            if smc.available {
                func maxOf(_ ks: [String]) -> Double? { ks.compactMap { smc.read($0) }.filter { $0 > -40 && $0 < 130 }.max() }
                cpuTemp = maxOf(["TCXC","TC0E","TC1C","TC2C","TC3C","TC4C"])
                gpuTemp = maxOf(["TG0D","TG0P"])
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
            let boosting = boostKinds.contains(rule.kind)
            if !boosting, st.streak >= minStreak, Licensing.shared.isPro {
                if boostKinds.isEmpty {                                     // первый форс — захват ДО действия
                    boostSaved = SettingsStore.activeFanProfileName
                    FanController.applyProfileHeadless(named: Self.boostID)
                }
                boostKinds.insert(rule.kind)
            } else if boosting, released || !Licensing.shared.isPro {       // отпустило ИЛИ потеряли Pro
                boostKinds.remove(rule.kind)
                if boostKinds.isEmpty { endBoost() }                       // последний — восстановление
            }
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
        let drop = boostKinds.filter { !master || !active.contains($0) }
        guard !drop.isEmpty else { return }
        boostKinds.subtract(drop)
        if boostKinds.isEmpty { endBoost() }
    }

    /// Снять форс: восстановить профиль. Только если он ВСЁ ЕЩЁ «наш turbo» — чужую смену (ручную/авто)
    /// во время форса НЕ затираем. При активной авто-по-источнику возвращаем профиль ТЕКУЩЕГО источника
    /// (а не устаревший захват), иначе — захваченный до форса.
    private func endBoost() {
        defer { boostSaved = nil }
        guard SettingsStore.activeFanProfileName == Self.boostID else { return }   // кто-то сменил профиль сам
        if SettingsStore.fanAutoBySource, Licensing.shared.isPro {
            let ext = BatteryReader.read()?.external ?? true
            FanController.applyProfileHeadless(named: ext ? SettingsStore.fanProfileAC : SettingsStore.fanProfileBattery)
        } else {
            FanController.applyProfileHeadless(named: boostSaved ?? "auto")
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
    func sendTest() {
        withAuthorization {
            let c = UNMutableNotificationContent()
            c.title = L("Уведомления Kelvin"); c.body = L("Так выглядит предупреждение. Можно настроить пороги ниже."); c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "kelvin.alert.test", content: c, trigger: nil))
        }
    }

    /// Спросить разрешение заранее (из настроек) — чтобы prompt появился осознанно,
    /// а не «из ниоткуда» при первом перегреве.
    func primeAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { s in
            // UN-колбэки приходят на произвольной очереди — запись authorized маршалим на main
            // (читается withAuthorization на main), чтобы снять data-race.
            if s.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
                    DispatchQueue.main.async { self.authorized = ok }
                }
            } else {
                let ok = (s.authorizationStatus == .authorized || s.authorizationStatus == .provisional)
                DispatchQueue.main.async { self.authorized = ok }
            }
        }
    }

    private func withAuthorization(_ post: @escaping () -> Void) {
        if authorized { post(); return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { s in
            switch s.authorizationStatus {
            case .authorized, .provisional:
                DispatchQueue.main.async { self.authorized = true; post() }
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
                    DispatchQueue.main.async { self.authorized = ok; if ok { post() } }
                }
            default: break   // запрещено пользователем — молча не шлём
            }
        }
    }
}
