import AppKit
import Sparkle

/// Адаптер для Sparkle updater — скрывает API фреймворка за протоколом UpdateProviding.
/// Весь UI работает только через этот протокол, что позволяет:
/// - тестировать настройки без сети
/// - заменить implementation
/// - централизовать логирование
protocol UpdateProviding {
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    func checkInBackground()
    func checkManually()
}

/// Реализация адаптера для Sparkle 2.x
final class SparkleUpdater: UpdateProviding {
    private let controller: SPUStandardUpdaterController
    
    init() {
        // Инициализируем Sparkle с стандартным UI (алерты, прогресс)
        // updaterDelegate: nil — используем поведение по умолчанию
        // userDriverDelegate: nil — стандартный driver для macOS
        self.controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        
        // Настраиваем поведение
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.updateCheckInterval = 24 * 3600 // раз в сутки
    }
    
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    
    var canCheckForUpdates: Bool {
        return controller.canCheckForUpdates
    }
    
    func checkInBackground() {
        // Sparkle автоматически проверяет обновления при запуске,
        // если automaticallyChecksForUpdates = true
        // Явный вызов не требуется, но можно форсировать:
        controller.updater.checkForUpdatesInBackground()
    }
    
    func checkManually() {
        // Показывает стандартный UI Sparkle (прогресс, алерт о новой версии)
        controller.checkForUpdates(nil)
    }
}

/// Legacy Updater — оставлен для совместимости, но делегирует Sparkle
enum Updater {
    private static var sparkle: UpdateProviding?
    
    private static func getSparkle() -> UpdateProviding {
        if sparkle == nil {
            sparkle = SparkleUpdater()
        }
        return sparkle!
    }
    
    /// Публикуется рядом с DMG (см. release.sh). Заменить на реальный хост при запуске.
    /// BM_FEED переопределяет адрес ТОЛЬКО в DEBUG — иначе env подменил бы канал обновлений в релизе.
    static var feedURL: String {
        #if DEBUG
        if let f = ProcessInfo.processInfo.environment["BM_FEED"] { return f }
        #endif
        return "https://trykelvin.com/appcast.xml"
    }
    
    struct Release: Decodable {
        let version: String          // "1.1.0"
        let url: String              // прямой URL .dmg
        let minOS: String?           // "11.0" — не предлагать на более старой macOS
        let notes: String?           // URL заметок о выпуске (необязательно)
    }
    
    private static let d = UserDefaults.standard
    
    static var autoCheck: Bool {
        get { 
            // Миграция: читаем старое значение, но используем Sparkle
            if let legacy = d.object(forKey: "updates.auto") as? Bool {
                return legacy
            }
            return getSparkle().automaticallyChecksForUpdates
        }
        set { 
            d.set(newValue, forKey: "updates.auto")
            getSparkle().automaticallyChecksForUpdates = newValue
        }
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
    /// Тихая проверка при запуске: делегирует Sparkle
    static func checkOnLaunch() {
        guard autoCheck else { return }
        // Sparkle автоматически проверяет при запуске, если настроено
        getSparkle().checkInBackground()
    }
    
    /// Ручная проверка (из настроек): показывает стандартный UI Sparkle
    static func checkManually() {
        getSparkle().checkManually()
    }
}
