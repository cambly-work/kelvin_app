//
//  CrashBreadcrumb.swift
//  Kelvin
//
//  Локальный кольцевой журнал событий для контекста перед падением.
//  Строгий allowlist событий без пользовательских данных.
//

import Foundation

/// Безопасные типы событий для breadcrumbs.
/// Не содержат пользовательского ввода, путей, названий файлов.
enum CrashBreadcrumb: Codable, Equatable {
    case appStarted
    case appWillTerminate
    case popoverOpened(kind: PopoverKind)
    case popoverClosed(kind: PopoverKind)
    case settingsOpened(section: SettingsSection)
    case helperConnectionChanged(state: HelperConnectionState)
    case updateStateChanged(state: UpdateState)
    case sensorAvailabilityChanged(state: SensorState)
    case licenseCheckCompleted(success: Bool)
    case crashReportDetected(count: Int)
    case crashReportSent(id: String)
    case crashReportDeclined(id: String)
    
    enum PopoverKind: String, Codable {
        case main
        case settings
        case about
        case diagnostic
    }
    
    enum SettingsSection: String, Codable {
        case general
        case sensors
        case privacy
        case advanced
        case licensing
    }
    
    enum HelperConnectionState: String, Codable {
        case connected
        case disconnected
        case error
    }
    
    enum UpdateState: String, Codable {
        case checking
        case available
        case downloading
        case ready
        case upToDate
        case failed
    }
    
    enum SensorState: String, Codable {
        case available
        case unavailable
        case error
    }
    
    /// Человеко-читаемое описание события
    var description: String {
        switch self {
        case .appStarted:
            return "Приложение запущено"
        case .appWillTerminate:
            return "Приложение завершает работу"
        case .popoverOpened(let kind):
            return "Открыто окно: \(kind.description)"
        case .popoverClosed(let kind):
            return "Закрыто окно: \(kind.description)"
        case .settingsOpened(let section):
            return "Открыты настройки: \(section.description)"
        case .helperConnectionChanged(let state):
            return "Состояние helper: \(state.description)"
        case .updateStateChanged(let state):
            return "Обновление: \(state.description)"
        case .sensorAvailabilityChanged(let state):
            return "Сенсоры: \(state.description)"
        case .licenseCheckCompleted(let success):
            return "Проверка лицензии: \(success ? "успешно" : "неудачно")"
        case .crashReportDetected(let count):
            return "Обнаружено отчётов о сбоях: \(count)"
        case .crashReportSent(let id):
            return "Отчёт отправлен: \(String(id.prefix(8)))"
        case .crashReportDeclined(let id):
            return "Отчёт отклонён: \(String(id.prefix(8)))"
        }
    }
}

extension CrashBreadcrumb.PopoverKind {
    var description: String {
        switch self {
        case .main: return "Главное"
        case .settings: return "Настройки"
        case .about: return "О приложении"
        case .diagnostic: return "Диагностика"
        }
    }
}

extension CrashBreadcrumb.SettingsSection {
    var description: String {
        switch self {
        case .general: return "Основные"
        case .sensors: return "Сенсоры"
        case .privacy: return "Приватность"
        case .advanced: return "Расширенные"
        case .licensing: return "Лицензия"
        }
    }
}

extension CrashBreadcrumb.HelperConnectionState {
    var description: String {
        switch self {
        case .connected: return "Подключено"
        case .disconnected: return "Отключено"
        case .error: return "Ошибка"
        }
    }
}

extension CrashBreadcrumb.UpdateState {
    var description: String {
        switch self {
        case .checking: return "Проверка"
        case .available: return "Доступно обновление"
        case .downloading: return "Загрузка"
        case .ready: return "Готово к установке"
        case .upToDate: return "Актуальная версия"
        case .failed: return "Ошибка обновления"
        }
    }
}

extension CrashBreadcrumb.SensorState {
    var description: String {
        switch self {
        case .available: return "Доступны"
        case .unavailable: return "Недоступны"
        case .error: return "Ошибка"
        }
    }
}

/// Отдельная запись breadcrumb с меткой времени
struct CrumbEntry: Codable, Equatable {
    let timestamp: Date
    let breadcrumb: CrashBreadcrumb
    
    /// Грубое время (без секунд) для приватности
    init(timestamp: Date, breadcrumb: CrashBreadcrumb) {
        // Округляем до минут для ограничения точности
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: timestamp)
        self.timestamp = calendar.date(from: components) ?? timestamp
        self.breadcrumb = breadcrumb
    }
    
    var isoTimestamp: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: timestamp)
    }
}

/// Кольцевой журнал breadcrumbs
final class CrashBreadcrumbStore {
    static let shared = CrashBreadcrumbStore()
    
    private let maxEntries = 50
    private let queue = DispatchQueue(label: "kelvin.crash.breadcrumbs", attributes: .concurrent)
    private var entries: [CrumbEntry] = []
    
    private let fileManager: FileManager
    private let storageURL: URL
    
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let kelvinDir = applicationSupport.appendingPathComponent("Kelvin", isDirectory: true)
        let breadcrumbsDir = kelvinDir.appendingPathComponent("Breadcrumbs", isDirectory: true)
        
        try? fileManager.createDirectory(at: breadcrumbsDir, withIntermediateDirectories: true)
        self.storageURL = breadcrumbsDir.appendingPathComponent("breadcrumbs.json")
        
        load()
    }
    
    /// Добавить событие в журнал
    func add(_ breadcrumb: CrashBreadcrumb) {
        let entry = CrumbEntry(timestamp: Date(), breadcrumb: breadcrumb)
        
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            
            self.entries.append(entry)
            
            // Удаляем старые записи, если превышен лимит
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
            
            self.save()
        }
    }
    
    /// Получить последние N записей
    func recent(_ count: Int) -> [CrumbEntry] {
        queue.sync {
            let limited = min(count, entries.count)
            return Array(entries.suffix(limited))
        }
    }
    
    /// Получить все записи для отчёта о сбое
    func allForReport() -> [CrumbEntry] {
        queue.sync {
            return entries
        }
    }
    
    /// Очистить журнал
    func clear() {
        queue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.entries.removeAll()
            self.save()
        }
    }
    
    // MARK: - Private
    
    private func load() {
        guard fileManager.fileExists(atPath: storageURL.path) else {
            return
        }
        
        do {
            let data = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([CrumbEntry].self, from: data)
            
            // Проверяем размер и обрезаем если нужно
            if entries.count > maxEntries {
                entries.removeFirst(entries.count - maxEntries)
            }
        } catch {
            Log.app.error("Failed to load breadcrumbs: \(error.localizedDescription, privacy: .public)")
            entries = []
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            let data = try encoder.encode(entries)
            try data.write(to: storageURL)
        } catch {
            Log.app.error("Failed to save breadcrumbs: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Convenience methods for common events

extension CrashBreadcrumbStore {
    func appStarted() {
        add(.appStarted)
    }
    
    func appWillTerminate() {
        add(.appWillTerminate)
    }
    
    func popoverOpened(_ kind: CrashBreadcrumb.PopoverKind) {
        add(.popoverOpened(kind: kind))
    }
    
    func popoverClosed(_ kind: CrashBreadcrumb.PopoverKind) {
        add(.popoverClosed(kind: kind))
    }
    
    func settingsOpened(_ section: CrashBreadcrumb.SettingsSection) {
        add(.settingsOpened(section: section))
    }
    
    func helperConnectionChanged(state: CrashBreadcrumb.HelperConnectionState) {
        add(.helperConnectionChanged(state: state))
    }
    
    func updateStateChanged(state: CrashBreadcrumb.UpdateState) {
        add(.updateStateChanged(state: state))
    }
    
    func sensorAvailabilityChanged(state: CrashBreadcrumb.SensorState) {
        add(.sensorAvailabilityChanged(state: state))
    }
    
    func licenseCheckCompleted(success: Bool) {
        add(.licenseCheckCompleted(success: success))
    }
    
    func crashReportDetected(count: Int) {
        add(.crashReportDetected(count: count))
    }
    
    func crashReportSent(id: String) {
        add(.crashReportSent(id: id))
    }
    
    func crashReportDeclined(id: String) {
        add(.crashReportDeclined(id: id))
    }
}
