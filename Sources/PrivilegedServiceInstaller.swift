import Foundation
import ServiceManagement
import os.log

/// Менеджер установки привилегированного сервиса.
/// Отвечает за регистрацию, проверку статуса и миграцию со старых версий.
@available(macOS 13.0, *)
final class PrivilegedServiceInstaller {
    
    private static let log = OSLog(subsystem: "com.trykelvin.kelvin", category: "Installer")
    
    /// Единственный экземпляр сервиса (соответствует label в Info.plist)
    private let service: SMAppService
    
    init() {
        // Label должен совпадать с тем, что указан в Launch Agent plist и entitlements
        self.service = SMAppService.mainApp.service(forIdentifier: "com.trykelvin.kelvin.privilegedHelper")
    }
    
    // MARK: - Public API
    
    /// Текущий статус сервиса
    var status: SMAppService.Status {
        service.status
    }
    
    /// Проверка, установлен ли сервис и готов к работе
    var isInstalledAndReady: Bool {
        status == .enabled
    }
    
    /// Попытка зарегистрировать сервис.
    /// Требует взаимодействия с пользователем (системный диалог), если статус не .enabled.
    /// - Returns: `true` если успешно зарегистрирован или уже был включен.
    func register() throws -> Bool {
        os_log("Attempting to register privileged service...", log: Self.log, type: .info)
        
        switch status {
        case .enabled:
            os_log("Service already enabled.", log: Self.log, type: .info)
            return true
            
        case .notFound, .requiresApproval, .invalid:
            do {
                try service.register()
                os_log("Service registration initiated. Awaiting user approval or immediate enablement.", log: Self.log, type: .info)
                // Примечание: В macOS 13+ register() может выбросить ошибку, если требуется одобрение в System Settings,
                // но часто возвращает управление сразу, а статус меняется асинхронно.
                // Мы полагаемся на внешний polling статуса или notification.
                return true
            } catch SMAppService.Error.registrationRequiresUserApproval {
                os_log("User approval required in System Settings.", log: Self.log, type: .warning)
                throw InstallationError.approvalRequired
            } catch {
                os_log("Registration failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
                throw InstallationError.registrationFailed(error)
            }
            
        @unknown default:
            os_log("Unknown service status.", log: Self.log, type: .error)
            throw InstallationError.unknownStatus
        }
    }
    
    /// Отмена регистрации (для случая, если пользователь передумал в процессе)
    func unregister() throws {
        os_log("Unregistering service...", log: Self.log, type: .info)
        do {
            try service.unregister()
            os_log("Service unregistered successfully.", log: Self.log, type: .info)
        } catch {
            os_log("Unregistration failed: %{public}@", log: Self.log, type: .error, error.localizedDescription)
            throw InstallationError.unregistrationFailed(error)
        }
    }
    
    /// Открытие системных настроек для одобрения Login Items
    func openSystemSettingsForApproval() {
        os_log("Opening System Settings for Login Items approval.", log: Self.log, type: .info)
        SMAppService.openSystemSettingsLoginItems()
    }
}

// MARK: - Errors

@available(macOS 13.0, *)
extension PrivilegedServiceInstaller {
    enum InstallationError: LocalizedError {
        case approvalRequired
        case registrationFailed(Error)
        case unregistrationFailed(Error)
        case unknownStatus
        
        var errorDescription: String? {
            switch self {
            case .approvalRequired:
                return "Требуется ваше подтверждение в Системных настройках."
            case .registrationFailed(let error):
                return "Не удалось установить системный компонент: \(error.localizedDescription)"
            case .unregistrationFailed(let error):
                return "Не удалось удалить компонент: \(error.localizedDescription)"
            case .unknownStatus:
                return "Неизвестное состояние системного компонента."
            }
        }
        
        var recoverySuggestion: String? {
            switch self {
            case .approvalRequired:
                return "Нажмите «Открыть настройки» и разрешите Kelvin в разделе «Общие» -> «Объекты входа»."
            default:
                return "Попробуйте повторить попытку или перезапустите приложение."
            }
        }
    }
}
