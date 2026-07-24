import Foundation
import ServiceManagement

/// Автозапуск при входе через современный SMAppService (login item),
/// вместо кустарного LaunchAgent-скрипта. Работает на macOS 13+.
enum LoginItem {
    static var available: Bool {
        if #available(macOS 13, *) { return true }
        return Bundle.main.executableURL != nil
    }

    static var enabled: Bool {
        if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
        return FileManager.default.fileExists(atPath: legacyPlistPath)
    }

    /// Включить/выключить автозапуск. Возвращает успех.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        if #available(macOS 13, *) {
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
        return setLegacy(on)
    }

    // Big Sur / Monterey fallback. Это пользовательский LaunchAgent без root:
    // plist лежит в ~/Library/LaunchAgents и запускает текущий bundle executable.
    private static let legacyLabel = "com.trykelvin.kelvin.login"
    private static var legacyPlistPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
    }

    private static func setLegacy(_ on: Bool) -> Bool {
        let fm = FileManager.default
        let domain = "gui/\(getuid())"
        if !on {
            _ = ProcessRunner.succeeds("/bin/launchctl", ["bootout", domain, legacyPlistPath], timeout: 4)
            do {
                if fm.fileExists(atPath: legacyPlistPath) { try fm.removeItem(atPath: legacyPlistPath) }
                return true
            } catch {
                return false
            }
        }

        guard let executable = Bundle.main.executableURL?.path else { return false }
        let directory = (legacyPlistPath as NSString).deletingLastPathComponent
        let plist: [String: Any] = [
            "Label": legacyLabel,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
        ]
        do {
            try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: legacyPlistPath), options: .atomic)
            _ = ProcessRunner.succeeds("/bin/launchctl", ["bootout", domain, legacyPlistPath], timeout: 4)
            return ProcessRunner.succeeds("/bin/launchctl", ["bootstrap", domain, legacyPlistPath], timeout: 4)
        } catch {
            return false
        }
    }
}
