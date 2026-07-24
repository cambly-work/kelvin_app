import Foundation
import ServiceManagement

/// Автозапуск при входе через современный SMAppService (login item),
/// вместо кустарного LaunchAgent-скрипта. Работает на macOS 13+.
enum LoginItem {
    static var available: Bool {
        if #available(macOS 13, *) { return true }
        return false
    }

    static var enabled: Bool {
        if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    /// Включить/выключить автозапуск. Возвращает успех.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        guard #available(macOS 13, *) else { return false }
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            return true
        } catch {
            return false
        }
    }
}
