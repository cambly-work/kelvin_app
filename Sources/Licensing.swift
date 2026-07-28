import Foundation
import AppKit
import Security

/// Донат «Поддержать Kelvin» — заменил коммерцию (июль 2026). Приложение бесплатно; кто хочет —
/// благодарит автора. Все реквизиты правятся в ОДНОМ месте — `AppConfig` (Sources/AppConfig.swift).
enum Donate {
    static var url: String { AppConfig.donateURL }
    static var configured: Bool { AppConfig.donateConfigured }
    static func open() { AppConfig.openDonate() }
}

/// Pro-функции Kelvin: всё, что «пишет/автоматизирует». Мониторинг — бесплатно навсегда.
enum ProFeature: String, CaseIterable {
    case fans, charge, firewall, language, snippets, customToggles, gpuSwitch, netBlock, vpn, audioSwitch, history
    var title: String {
        switch self {
        case .fans:          return L("Управление вентиляторами")
        case .charge:        return L("Лимит заряда батареи")
        case .firewall:      return L("Фаервол")
        case .language:      return L("Переключение языка и опечатки")
        case .snippets:      return L("Сниппеты")
        case .customToggles: return L("Свои кнопки-команды")
        case .gpuSwitch:     return L("Переключение видеокарты")
        case .netBlock:      return L("Блокировка подключений")
        case .vpn:           return L("Переключатель системного VPN")
        case .audioSwitch:   return L("Переключение аудиовыхода")
        case .history:       return L("История трендов свыше 24 часов")
        }
    }
}

/// Хранилище якоря пробного периода в связке ключей (generic password). Переживает
/// `defaults delete` и переустановку — закаляет триал от тривиального сброса. Хранит дату
/// первого запуска как epoch-секунды строкой. Любая ошибка Keychain → nil (мягкая деградация).
enum TrialVault {
    private static let service = "com.trykelvin.kelvin.trial"
    private static let account = "firstRun"

    static func loadDate() -> Date? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8),
              let ts = TimeInterval(s) else { return nil }
        return Date(timeIntervalSince1970: ts)
    }

    static func saveDate(_ date: Date) {
        let data = Data(String(date.timeIntervalSince1970).utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)                              // идемпотентно: убрать старое
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// ПОДПИСАННОЕ, привязанное к железу состояние лицензии в связке ключей. В отличие от прежнего открытого
/// UserDefaults-кэша (lic.valid/lic.key/lic.validatedAt) — `defaults write` его НЕ подделает и на другой Mac
/// НЕ скопирует: блоб подписан HMAC на ключе из встроенного секрета ‖ IOPlatformUUID (см. MachineID).
struct LicenseState {
    var key: String
    var instance: String
    var validatedAt: Date
}
enum LicenseVault {
    private static let service = "com.trykelvin.kelvin.license"
    private static let account = "state"

    /// Загрузить и ПРОВЕРИТЬ подпись. Несовпадение (подделка / копия на чужой Mac) → nil.
    static func load() -> LicenseState? {
        guard let data = read(), let s = String(data: data, encoding: .utf8) else { return nil }
        let p = s.components(separatedBy: "\n")
        guard p.count == 4, let ts = TimeInterval(p[2]) else { return nil }
        guard MachineID.verify("\(p[0])|\(p[1])|\(p[2])", tag: p[3]) else { return nil }
        return LicenseState(key: p[0], instance: p[1], validatedAt: Date(timeIntervalSince1970: ts))
    }
    static func save(_ st: LicenseState) {
        let ts = String(st.validatedAt.timeIntervalSince1970)
        let tag = MachineID.tag("\(st.key)|\(st.instance)|\(ts)")
        write(Data("\(st.key)\n\(st.instance)\n\(ts)\n\(tag)".utf8))
    }
    static func clear() { SecItemDelete(base() as CFDictionary) }

    private static func base() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    private static func read() -> Data? {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
    private static func write(_ data: Data) {
        SecItemDelete(base() as CFDictionary)                            // идемпотентно
        var add = base()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Лицензия + триал. Источник истины — Lemon Squeezy License API (activate/validate
/// по ключу + привязка устройства), с ПОДПИСАННЫМ локальным кэшем (LicenseVault) и офлайн-grace.
final class Licensing {
    static let shared = Licensing()
    private let d = UserDefaults.standard

    // Коммерческая конфигурация из AppConfig (единый источник истины)
    var trialDays: Int { AppConfig.trialDays }
    var graceDays: Int { AppConfig.licenseGraceDays }
    
    static var checkoutURL: String? { AppConfig.lemonSqueezyCheckoutURL }
    static var storeID: Int? { AppConfig.lemonSqueezyStoreID }
    static var productID: Int? { AppConfig.lemonSqueezyProductID }
    static var isStoreConfigured: Bool { AppConfig.isStoreConfigured }
    
    private static let api = "https://api.lemonsqueezy.com/v1/licenses"

    // ВАЖНО: демо-оверрайды монетизации доступны ТОЛЬКО в DEBUG-сборке. В релизе (build.sh/release.sh
    // не передают -DDEBUG) ветка #else вырубает их — иначе `BM_PRO=1 open Kelvin` отдавал бы весь Pro даром.
    #if DEBUG
    private let env = ProcessInfo.processInfo.environment
    private var forceFree: Bool { env["BM_FREE"] != nil }       // для проверки апселла
    var forcePro: Bool { env["BM_PRO"] != nil }                 // демо: «активированная» лицензия
    private var trialOverride: Int? { env["BM_TRIAL_DAYS"].flatMap { Int($0) } }   // демо: подменить остаток триала
    private var envTrialEnded: Bool { env["BM_TRIALENDED"] != nil }                // демо: прощальный экран
    #else
    private var forceFree: Bool { false }
    var forcePro: Bool { false }
    private var trialOverride: Int? { nil }
    private var envTrialEnded: Bool { false }
    #endif

    // MARK: триал
    // Якорь триала закалён связкой ключей (Keychain): `defaults delete` и переустановка приложения
    // больше не сбрасывают 14-дневный отсчёт. Источник истины — САМАЯ РАННЯЯ из известных дат
    // (Keychain ∪ UserDefaults), и она зеркалится в оба хранилища — так сброс требует чистки обоих.
    // Скриншот/showcase-рендер (BM_AUTOSHOW/BM_SHOWCASE/BM_SETTINGS) не должен синхронно дёргать
    // связку ключей при старте: на ad-hoc-сборке без стабильной подписи это модалка SecurityAgent,
    // которая блокирует главный поток и срывает офскрин-рендер. В этом режиме — только UserDefaults.
    private static let renderMode: Bool = {
        let e = ProcessInfo.processInfo.environment
        return e["BM_AUTOSHOW"] != nil || e["BM_SHOWCASE"] != nil || e["BM_SETTINGS"] != nil || e["BM_SNAP"] != nil
    }()

    var firstRun: Date {
        if Self.renderMode {                                               // скриншот-режим: без Keychain
            if let ud = d.object(forKey: "lic.firstRun") as? Date { return ud }
            let now = Date(); d.set(now, forKey: "lic.firstRun"); return now
        }
        let kc = TrialVault.loadDate()
        let ud = d.object(forKey: "lic.firstRun") as? Date
        if let earliest = [kc, ud].compactMap({ $0 }).min() {
            if kc == nil { TrialVault.saveDate(earliest) }                 // миграция UD → Keychain
            if ud == nil { d.set(earliest, forKey: "lic.firstRun") }       // зеркало для быстрых чтений
            return earliest
        }
        let now = Date()                                                   // самый первый запуск — пишем в оба
        d.set(now, forKey: "lic.firstRun"); TrialVault.saveDate(now)
        return now
    }
    var trialDaysLeft: Int {
        if let o = trialOverride { return max(0, o) }
        let used = max(0, Calendar.current.dateComponents([.day], from: firstRun, to: Date()).day ?? 0)  // клок-назад не продлевает триал
        return max(0, trialDays - used)
    }
    var inTrial: Bool { licenseKey == nil && trialDaysLeft > 0 }

    // MARK: лицензия — ПОДПИСАННЫЙ, привязанный к железу кэш в связке ключей (не открытый UserDefaults).
    // Кэшируем прочитанное состояние в памяти: гейт (isPro) дёргается часто, а чтение Keychain недёшево.
    private var _stateLoaded = false
    private var _state: LicenseState?
    private func state() -> LicenseState? {
        if Self.renderMode { return nil }                 // скриншот-режим: без Keychain (иначе модалка SecurityAgent)
        if !_stateLoaded { _state = LicenseVault.load(); _stateLoaded = true }
        return _state
    }
    private func setState(_ s: LicenseState?) {
        if let s { LicenseVault.save(s) } else { LicenseVault.clear() }
        _state = s; _stateLoaded = true
    }

    var licenseKey: String? { state()?.key }
    var instanceID: String? { state()?.instance }  // public for UI
    
    /// Вспомогательная функция для склонения (используется в UI)
    func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n10 = n % 10, n100 = n % 100
        if n10 == 1 && n100 != 11 { return one }
        if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
        return many
    }

    /// Лицензия валидна, если есть ПОДПИСАННОЕ состояние (подпись сверена при загрузке — форж/копию отсекли)
    /// и последняя успешная проверка не старше grace-окна. Плюс детект отката системных часов назад.
    var licenseValid: Bool {
        guard let st = state(), !st.key.isEmpty else { return false }
        let now = Date()
        if now < st.validatedAt.addingTimeInterval(-86_400) { return false }   // часы откатили → нужна ревалидация
        let days = Calendar.current.dateComponents([.day], from: st.validatedAt, to: now).day ?? 999
        return days <= graceDays
    }

    /// Куплена ли лицензия (для UI: показывать «деактивировать» вместо «купить»).
    var activated: Bool {
        #if DEBUG
        if forcePro { return true }
        #endif
        return licenseValid
    }

    /// КОММЕРЧЕСКАЯ МОДЕЛЬ (возвращена после отмены в июле 2026):
    /// - Monitoring (чтение сенсоров, графики, история ≤24h) — бесплатно навсегда.
    /// - Control/Automation (запись параметров, вентиляторы, charge limit, firewall, language automation,
    ///   custom commands, GPU switch, VPN toggle, audio switch, history export >24h) — требуют Pro.
    ///
    /// Pro доступен при:
    /// - DEBUG overrides (BM_PRO) — только в DEBUG сборках;
    /// - Валидная лицензия (подписанное состояние + grace period не истёк);
    /// - Активный trial (≤14 дней с первого запуска, ключ не введён).
    ///
    /// Production без лицензии/после trial → isPro = false, контроль блокируется на уровне execution gate.
    var isPro: Bool {
        #if DEBUG
        if forcePro { return true }
        if forceFree { return false }
        #else
        // В production всегда проверяем реальное состояние
        #endif
        
        // Подписанная валидная лицензия даёт Pro
        if licenseValid { return true }
        
        // Trial даёт Pro (только если нет лицензии)
        if inTrial { return true }
        
        // Free (без лицензии и после trial) → только мониторинг
        return false
    }

    /// Триал закончился, лицензии нет, и мы ещё не показывали прощальный экран — момент для оффера.
    var shouldShowTrialEnded: Bool {
        if envTrialEnded { return true }                                // демо (только DEBUG)
        guard !isPro, licenseKey == nil, trialDaysLeft == 0 else { return false }
        guard d.object(forKey: "lic.firstRun") != nil else { return false }   // триал реально шёл
        return !d.bool(forKey: "lic.endedShown")
    }
    func markTrialEndedShown() { d.set(true, forKey: "lic.endedShown") }

    var statusText: String {
        #if DEBUG
        if forceFree { return L("Бесплатная версия — мониторинг") }
        if forcePro { return L("Kelvin Pro — активирован (DEBUG override)") }
        #endif
        
        if activated { return L("Kelvin Pro — активирован") }
        if licenseKey != nil && !licenseValid {
            return L("Лицензия — требуется проверка соединения")   // grace истёк или офлайн
        }
        if inTrial {
            let daysLeft = trialDaysLeft
            if daysLeft == 0 {
                return L("Пробный период закончился")
            } else {
                return I18n.trialStatus(daysLeft)
            }
        }
        return L("Бесплатная версия — пробный период закончился")
    }
    
    /// Checkout URL для кнопки покупки. Возвращает nil, если магазин не настроен.
    static func checkoutURL() -> String? {
        guard let url = AppConfig.lemonSqueezyCheckoutURL else { return nil }
        // Валидация: HTTPS и не example.com
        guard url.hasPrefix("https://"), !url.contains("example.com") else { return nil }
        return url
    }

    // MARK: Lemon Squeezy License API
    
    /// Активация лицензии через Lemon Squeezy API.
    /// - rawKey: ключ от пользователя (trimming применяется внутри)
    /// - completion: (success, message) на main queue
    func activate(_ rawKey: String, completion: @escaping (Bool, String) -> Void) {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return completion(false, L("Введите ключ лицензии.")) }
        
        // Проверка конфигурации магазина
        guard Self.isStoreConfigured else {
            #if DEBUG
            let diag = AppConfig.storeDiagnosticMessage
            return completion(false, "Магазин не подключён: \(diag)")
            #else
            return completion(false, L("Магазин Lemon Squeezy ещё не подключён — активация ключей появится в релизной сборке."))
            #endif
        }
        
        post("activate", ["license_key": key, "instance_name": Host.current().localizedName ?? "Mac"]) { [weak self] r in
            guard let self else { return }
            guard case .success(let j) = r else {
                if case .failure(let e) = r { 
                    completion(false, String(format: L("Не удалось связаться с сервером: %@"), e))
                }
                return
            }
            
            // Безопасное декодирование ответа
            let meta = j["meta"] as? [String: Any]
            let storeOK = (meta?["store_id"] as? Int) == Self.storeID && (meta?["product_id"] as? Int) == Self.productID
            let instID = (j["instance"] as? [String: Any])?["id"] as? String
            
            if (j["activated"] as? Bool) == true, storeOK, let instID {
                self.setState(LicenseState(key: key, instance: instID, validatedAt: Date()))
                completion(true, L("Kelvin Pro активирован на этом Mac."))
            } else if !storeOK {
                completion(false, L("Этот ключ от другого продукта."))
            } else {
                let errorMsg = (j["error"] as? String) ?? L("ключ недействителен или достигнут лимит устройств")
                completion(false, String(format: L("Активация не прошла: %@."), errorMsg))
            }
        }
    }

    /// Тихая перепроверка при запуске — обновляет grace-окно (переподписывает кэш). Сетевая ошибка ничего не ломает.
    func revalidate() {
        guard Self.isStoreConfigured, let key = licenseKey, let inst = instanceID else { return }
        post("validate", ["license_key": key, "instance_id": inst]) { [weak self] r in
            guard let self, case .success(let j) = r else { return }        // сеть упала — кэш не трогаем (офлайн-grace)
            if (j["valid"] as? Bool) == true {
                self.setState(LicenseState(key: key, instance: inst, validatedAt: Date()))   // обновили grace-окно
            } else {
                // Сервер сообщил о невалидности → очищаем состояние
                self.setState(nil)
            }
        }
    }

    /// Деактивация лицензии на этом Mac.
    /// Сначала пытается сообщить серверу (eventual consistency), затем локально очищает состояние.
    func deactivate() {
        if Self.isStoreConfigured, let key = licenseKey, let inst = instanceID {
            // Асинхронный запрос на деактивацию (не блокируем UI, ошибки игнорируем — eventual consistency)
            post("deactivate", ["license_key": key, "instance_id": inst]) { _ in }
        }
        // Локальная очистка состояния (немедленно)
        setState(nil)
    }

    private enum NetResult { case success([String: Any]); case failure(String) }
    
    /// HTTP POST к Lemon Squeezy API с базовой безопасностью:
    /// - timeout 12s
    /// - Content-Type: application/x-www-form-urlencoded
    /// - Accept: application/json
    /// - response size limit не реализован (NSURLSession без явного лимита)
    /// - нет кеширования/cookies (ephemeral session можно добавить при необходимости)
    private func post(_ path: String, _ form: [String: String], _ done: @escaping (NetResult) -> Void) {
        guard let url = URL(string: "\(Self.api)/\(path)") else { return done(.failure("bad url")) }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 12
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        
        // Используем ephemeral session без cookies и cache для приватности
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.urlCache = nil
        sessionConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: sessionConfig)
        
        session.dataTask(with: req) { data, _, err in
            DispatchQueue.main.async {
                if let err = err { return done(.failure(err.localizedDescription)) }
                guard let data, let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    return done(.failure(L("неожиданный ответ сервера")))
                }
                done(.success(j))
            }
        }.resume()
    }
}
