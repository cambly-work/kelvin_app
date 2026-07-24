import Foundation
import AppKit

/// Цивильная установка root-хелперов: запускает бандловый скрипт как root
/// через нативный диалог пароля (osascript admin) — без Терминала и copy-paste.
enum HelperInstall {
    static func scriptPath(_ file: String) -> String? {
        let base = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        return Bundle.main.path(forResource: base, ofType: ext.isEmpty ? nil : ext)
    }

    /// Бандл безопасен для запуска root-скрипта? Отказываем, если .app или его Resources доступны на запись
    /// группе/другим — иначе атакующий подменил бы скрипт/бинарь в Resources и, когда пользователь введёт
    /// пароль, выполнил бы свой код как root (эскалация через записываемый бандл).
    private static func bundleSafeForPrivileged() -> Bool {
        let fm = FileManager.default
        let paths = [Bundle.main.bundlePath,
                     (Bundle.main.bundlePath as NSString).appendingPathComponent("Contents/Resources")]
        for p in paths {
            guard let attrs = try? fm.attributesOfItem(atPath: p),
                  let perm = (attrs[.posixPermissions] as? NSNumber)?.uint16Value else { return false }
            if perm & 0o022 != 0 { return false }          // group- или other-writable → небезопасно
        }
        return true
    }

    /// Выполнить бандловый скрипт как root. Различает отмену пароля и реальный сбой.
    @discardableResult
    static func runPrivileged(_ file: String, prompt: String? = nil) -> (ok: Bool, canceled: Bool, output: String) {
        guard let path = scriptPath(file) else { return (false, false, "скрипт \(file) не найден в бандле") }
        guard bundleSafeForPrivileged() else {
            return (false, false, "бандл доступен на запись — переместите Kelvin в /Applications и повторите")
        }
        let promptClause = prompt.map { " with prompt \"\($0.replacingOccurrences(of: "\"", with: ""))\"" } ?? ""
        // Закрываем root-инъекцию через путь .app (…/o'brien/…, …/Tim's Apps/…): тот же приём, что в Firewall/HostBlock —
        // shell-квотируем путь (' → '\''), затем экранируем строку для литерала AppleScript (\ → \\, " → \").
        let cmd = SecurityTools.quote(path)
        let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let src = "do shell script \"\(esc)\"\(promptClause) with administrator privileges"
        var err: NSDictionary?
        let out = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err {
            let canceled = (err[NSAppleScript.errorNumber] as? Int) == -128   // пользователь сам отменил пароль
            return (false, canceled, (err[NSAppleScript.errorMessage] as? String) ?? "ошибка")
        }
        return (true, false, out?.stringValue ?? "")
    }

    /// Человеческое сообщение при сбое (не отмене) привилегированной операции.
    static let friendlyFailure = "Не удалось получить права администратора. Попробуйте ещё раз и введите пароль администратора вашего Mac."

    /// Дружелюбно показывает сбой; на отмену пользователем — молчит. Возвращает true при успехе.
    @discardableResult
    static func presentFailureIfNeeded(_ r: (ok: Bool, canceled: Bool, output: String), title: String = L("Не удалось")) -> Bool {
        if r.ok { return true }
        if r.canceled { return false }                 // отмена — без пугающего алерта
        let a = NSAlert(); a.alertStyle = .warning
        a.messageText = title; a.informativeText = L(friendlyFailure)
        a.runModal()
        return false
    }

    private static func installed(_ label: String) -> Bool {
        FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/\(label).plist")
    }
    static var powerdInstalled: Bool { installed("com.trykelvin.kelvin.powerd") }
    static var fandInstalled: Bool { installed("com.trykelvin.kelvin.fand") }
}
