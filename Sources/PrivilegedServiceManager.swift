import Foundation
import AppKit
import ServiceManagement

/// Менеджер состояния и установки привилегированного сервиса.
/// Единая точка для установки, проверки статуса, обновления и удаления.
@MainActor
final class PrivilegedServiceManager: ObservableObject {
    
    /// Состояния сервиса
    enum State: Equatable {
        case notInstalled
        case approvalRequired
        case installing
        case healthy(ServiceInfo)
        case updateRequired(current: ServiceInfo, required: ServiceInfo)
        case incompatible(reason: String)
        case degraded(reason: ServiceFailure)
        case repairing
        case uninstalling
        
        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.notInstalled, .notInstalled),
                 (.approvalRequired, .approvalRequired),
                 (.installing, .installing),
                 (.repairing, .repairing),
                 (.uninstalling, .uninstalling):
                return true
            case (.healthy(let l), .healthy(let r)):
                return l.serviceVersion == r.serviceVersion && 
                       l.protocolVersion == r.protocolVersion &&
                       l.health == r.health
            case (.updateRequired(let lc, let lr), .updateRequired(let rc, let rr)):
                return lc.serviceVersion == rc.serviceVersion && 
                       lr.serviceVersion == rr.serviceVersion
            case (.incompatible(let l), .incompatible(let r)):
                return l == r
            case (.degraded(let l), .degraded(let r)):
                return l.reason == r.reason
            default:
                return false
            }
        }
    }
    
    /// Причины деградации сервиса
    struct ServiceFailure: Equatable {
        let reason: String
        let errorCode: Int?
        let recoverable: Bool
    }
    
    /// Синглтон
    static let shared = PrivilegedServiceManager()
    
    /// Текущее состояние
    @Published private(set) var state: State = .notInstalled
    
    /// Версия сервиса (если установлен)
    @Published private(set) var serviceVersion: String?
    
    /// Поддерживаемые возможности
    @Published private(set) var capabilities: Set<Capability> = []
    
    /// Bundle ID приложения
    private let appBundleID: String
    
    /// Team ID (извлекается из подписи)
    private let teamID: String?
    
    /// Label launch daemon
    private let serviceLabel = "com.trykelvin.kelvin.privileged"
    
    /// Путь к plist сервиса
    private let servicePlistPath = "/Library/LaunchDaemons/com.trykelvin.kelvin.privileged.plist"
    
    private init() {
        appBundleID = Bundle.main.bundleIdentifier ?? "com.trykelvin.kelvin"
        teamID = Self.extractTeamID()
        
        // Начальная проверка состояния
        Task { await checkStatus() }
    }
    
    /// Извлечение Team ID из кодовой подписи
    private static func extractTeamID() -> String? {
        // В production это должно извлекаться из code requirement
        // Для сейчас используем заглушку
        return nil
    }
    
    // MARK: - Проверка состояния
    
    /// Проверить текущее состояние сервиса
    func checkStatus() async {
        let fm = FileManager.default
        
        // Проверка наличия plist
        guard fm.fileExists(atPath: servicePlistPath) else {
            state = .notInstalled
            serviceVersion = nil
            capabilities = []
            return
        }
        
        // Проверка запущенности процесса
        let serviceRunning = isServiceRunning()
        
        if !serviceRunning {
            // Plist есть, но сервис не запущен — возможно требуется approval
            if requiresApproval() {
                state = .approvalRequired
            } else {
                state = .degraded(reason: ServiceFailure(
                    reason: "Сервис не запускается",
                    errorCode: nil,
                    recoverable: true
                ))
            }
            return
        }
        
        // Сервис запущен — получаем информацию через XPC (пока заглушка)
        // В будущем здесь будет XPC handshake
        let info = ServiceInfo(
            serviceVersion: "1.0.0", // TODO: получить от сервиса
            protocolVersion: CurrentProtocolVersion,
            supportedCapabilities: Set(Capability.allCases),
            health: .healthy
        )
        
        // Проверка совместимости протокола
        if info.protocolVersion != CurrentProtocolVersion {
            state = .updateRequired(
                current: info,
                required: ServiceInfo(
                    serviceVersion: "1.0.0",
                    protocolVersion: CurrentProtocolVersion,
                    supportedCapabilities: Set(Capability.allCases),
                    health: .healthy
                )
            )
        } else {
            state = .healthy(info)
            serviceVersion = info.serviceVersion
            capabilities = info.supportedCapabilities
        }
    }
    
    /// Проверка запущенности сервиса через launchctl
    private func isServiceRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["list", serviceLabel]
        task.standardOutput = nil
        task.standardError = nil
        
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
    
    /// Проверка требования approval в System Settings
    private func requiresApproval() -> Bool {
        // На macOS 13+ сервисы требуют approval в System Settings
        // Проверяем через SMAppService.status если доступно
        if #available(macOS 13.0, *) {
            // TODO: использовать SMAppService для проверки статуса
            return true
        }
        return false
    }
    
    // MARK: - Установка
    
    /// Запустить установку сервиса
    func install() async throws {
        guard case .notInstalled = state else {
            throw NSError(domain: "PrivilegedServiceManager", 
                         code: 1, 
                         userInfo: [NSLocalizedDescriptionKey: "Сервис уже установлен или устанавливается"])
        }
        
        state = .installing
        
        do {
            if #available(macOS 13.0, *) {
                try await installModern()
            } else {
                try await installLegacy()
            }
            
            // После установки проверяем статус
            try await Task.sleep(nanoseconds: 2_000_000_000) // 2 секунды
            await checkStatus()
            
        } catch {
            state = .notInstalled
            throw error
        }
    }
    
    /// Установка на macOS 13+ через ServiceManagement
    @available(macOS 13.0, *)
    private func installModern() async throws {
        let service = SMAppService.mainApp
        do {
            try service.register()
            Log.service.info("Запрошена регистрация privileged сервиса")
        } catch {
            Log.service.error("Ошибка регистрации сервиса: \(error)")
            throw error
        }
    }
    
    /// Установка на macOS 11-12 через legacy механизм
    private func installLegacy() async throws {
        // Fallback на старый метод с AppleScript
        // TODO: реализовать через HelperInstall с proper validation
        throw NSError(domain: "PrivilegedServiceManager",
                     code: 2,
                     userInfo: [NSLocalizedDescriptionKey: "macOS 11-12 требует отдельной реализации"])
    }
    
    // MARK: - Обновление
    
    /// Обновить сервис до новой версии
    func update() async throws {
        guard case .updateRequired = state else {
            throw NSError(domain: "PrivilegedServiceManager",
                         code: 3,
                         userInfo: [NSLocalizedDescriptionKey: "Обновление не требуется"])
        }
        
        state = .repairing
        
        // unregister → register
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            try? service.unregister()
            try service.register()
        }
        
        try await Task.sleep(nanoseconds: 2_000_000_000)
        await checkStatus()
    }
    
    // MARK: - Удаление
    
    /// Удалить сервис
    func uninstall() async throws {
        state = .uninstalling
        
        do {
            if #available(macOS 13.0, *) {
                let service = SMAppService.mainApp
                try service.unregister()
            } else {
                // Legacy удаление
                try await uninstallLegacy()
            }
            
            try await Task.sleep(nanoseconds: 1_000_000_000)
            await checkStatus()
            
        } catch {
            // Возвращаем предыдущее состояние при ошибке
            await checkStatus()
            throw error
        }
    }
    
    /// Legacy удаление для macOS 11-12
    private func uninstallLegacy() async throws {
        let fm = FileManager.default
        
        // Остановить сервис
        let stopTask = Process()
        stopTask.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        stopTask.arguments = ["bootout", "system/\(serviceLabel)"]
        try? stopTask.run()
        stopTask.waitUntilExit()
        
        // Удалить plist
        if fm.fileExists(atPath: servicePlistPath) {
            try fm.removeItem(atPath: servicePlistPath)
        }
        
        Log.service.info("Privileged сервис удалён")
    }
    
    // MARK: - Восстановление
    
    /// Попытка восстановления сервиса
    func repair() async throws {
        guard case .degraded = state || case .approvalRequired = state else {
            throw NSError(domain: "PrivilegedServiceManager",
                         code: 4,
                         userInfo: [NSLocalizedDescriptionKey: "Восстановление не требуется"])
        }
        
        state = .repairing
        
        // Перерегистрация
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            try? service.unregister()
            try service.register()
        }
        
        try await Task.sleep(nanoseconds: 2_000_000_000)
        await checkStatus()
    }
    
    // MARK: - Открытие системных настроек
    
    /// Открыть System Settings для approval
    func openSystemSettings() {
        if #available(macOS 13.0, *) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.extensions")!)
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
        }
    }
}

// MARK: - Логирование

private extension Log {
    static let service = OSLog(subsystem: "com.trykelvin.kelvin", category: "PrivilegedService")
}
