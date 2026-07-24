import AppKit

/// Лёгкий собственный механизм обновлений (без Sparkle): тянет appcast-JSON, сравнивает версию,
/// предлагает скачать DMG. Полнофункциональный in-app install — задача Sparkle на будущее;
/// здесь — надёжная проверка + переход на загрузку, чего достаточно для прямой дистрибуции.
enum Updater {
    /// Публикуется рядом с DMG (см. release.sh). Заменить на реальный хост при запуске.
    /// BM_FEED переопределяет адрес ТОЛЬКО в DEBUG — иначе env подменил бы канал обновлений в релизе.
    static var feedURL: String {
        #if DEBUG
        if let f = ProcessInfo.processInfo.environment["BM_FEED"] { return f }
        #endif
        return "https://trykelvin.com/appcast.json"
    }

    struct Release: Decodable {
        let version: String          // "1.1.0"
        let url: String              // прямой URL .dmg
        let minOS: String?           // "11.0" — не предлагать на более старой macOS
        let notes: String?           // URL заметок о выпуске (необязательно)
    }

    private static let d = UserDefaults.standard
    static var autoCheck: Bool {
        get { d.object(forKey: "updates.auto") as? Bool ?? true }   // по умолчанию включено
        set { d.set(newValue, forKey: "updates.auto") }
    }
    private static var skipped: String? {
        get { d.string(forKey: "updates.skip") }
        set { d.set(newValue, forKey: "updates.skip") }
    }
    private static var lastCheck: Date? {
        get { d.object(forKey: "updates.lastCheck") as? Date }
        set { d.set(newValue, forKey: "updates.lastCheck") }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.9.0"
    }

    /// remote > current по компонентам (1.2.0 > 1.1.9).
    static func isNewer(_ remote: String, than current: String) -> Bool {
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }
        let c = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(r.count, c.count) {
            let x = i < r.count ? r[i] : 0, y = i < c.count ? c[i] : 0
            if x != y { return x > y }
        }
        return false
    }
    private static func osSatisfies(_ minOS: String?) -> Bool {
        guard let minOS, !minOS.isEmpty else { return true }
        let parts = minOS.split(separator: ".").map { Int($0) ?? 0 }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let cur = [v.majorVersion, v.minorVersion, v.patchVersion]
        for i in 0..<max(parts.count, cur.count) {
            let need = i < parts.count ? parts[i] : 0, have = i < cur.count ? cur[i] : 0
            if have != need { return have > need }
        }
        return true
    }

    // MARK: проверки
    /// Тихая проверка при запуске: не чаще раза в сутки, только если включено; алерт лишь при новой версии.
    static func checkOnLaunch() {
        guard autoCheck else { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
        fetch { rel in
            lastCheck = Date()
            guard let rel, isNewer(rel.version, than: currentVersion), osSatisfies(rel.minOS),
                  rel.version != skipped else { return }
            present(rel, allowSkip: true)
        }
    }

    /// Ручная проверка (из настроек): всегда показывает результат — есть новее / актуально / ошибка.
    static func checkManually() {
        fetch { rel in
            lastCheck = Date()
            guard let rel else {
                return alert(L("Не удалось проверить обновления"), L("Проверьте соединение и попробуйте позже."), L("Понятно"))
            }
            if isNewer(rel.version, than: currentVersion), osSatisfies(rel.minOS) {
                present(rel, allowSkip: false)
            } else {
                alert(L("Установлена последняя версия"), String(format: L("Kelvin %@ — обновлений нет."), currentVersion), L("Отлично"))
            }
        }
    }

    // MARK: сеть
    private static func fetch(_ done: @escaping (Release?) -> Void) {
        guard let url = URL(string: feedURL) else { return done(nil) }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let rel = data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
            DispatchQueue.main.async { done(rel) }
        }.resume()
    }

    // MARK: UI
    private static func present(_ rel: Release, allowSkip: Bool) {
        let a = NSAlert()
        a.messageText = String(format: L("Доступна Kelvin %@"), rel.version)
        a.informativeText = String(format: L("Установлена %@. Скачать новую версию?"), currentVersion)
        a.addButton(withTitle: L("Скачать"))
        if rel.notes != nil { a.addButton(withTitle: L("Что нового")) }
        a.addButton(withTitle: allowSkip ? L("Пропустить эту версию") : L("Позже"))
        NSApp.activate(ignoringOtherApps: true)
        let r = a.runModal()
        switch r {
        case .alertFirstButtonReturn:
            safeOpen(rel.url)
        case .alertSecondButtonReturn where rel.notes != nil:
            if let n = rel.notes { safeOpen(n) }
        default:
            if allowSkip { skipped = rel.version }   // последняя кнопка
        }
    }

    /// Defense-in-depth: URL из remote appcast открываем только по http(s).
    /// Подменённый фид (MITM) не сможет протолкнуть file:// / x-... схему.
    private static func safeOpen(_ s: String) {
        guard let u = URL(string: s), let sc = u.scheme?.lowercased(),
              sc == "http" || sc == "https" else {
            NSLog("Kelvin updater: отклонён не-http(s) URL из appcast")
            return
        }
        NSWorkspace.shared.open(u)
    }
    private static func alert(_ title: String, _ msg: String, _ ok: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = msg; a.addButton(withTitle: ok)
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }
}
