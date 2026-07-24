import Foundation
import AppKit

/// Gatekeeper и карантин загрузок. ⚠️ Снижают защиту — только по явному выбору пользователя.
/// Чтение состояния — без root; переключение Gatekeeper — root через системный диалог пароля.
enum SecurityTools {

    // MARK: низкоуровневые запуски
    @discardableResult
    private static func run(_ args: [String]) -> String {
        ProcessRunner.output(args[0], Array(args.dropFirst()), timeout: 8, mergeError: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func status(_ args: [String]) -> Int32 {
        ProcessRunner.succeeds(args[0], Array(args.dropFirst()), timeout: 8) ? 0 : 1
    }
    private static func runAdmin(_ shell: String, prompt: String) -> Bool {
        let esc = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let p = prompt.replacingOccurrences(of: "\"", with: "")
        let src = "do shell script \"\(esc)\" with prompt \"\(p)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        return err == nil
    }
    /// Безопасное оборачивание аргумента в одинарные кавычки для shell (закрывает инъекцию через пути/имена).
    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Gatekeeper (spctl)
    /// true — Gatekeeper включён (проверки подписи активны).
    static var gatekeeperEnabled: Bool {
        run(["/usr/sbin/spctl", "--status"]).lowercased().contains("enabled")
    }
    @discardableResult
    static func setGatekeeper(_ enabled: Bool) -> Bool {
        let cmd = enabled ? "/usr/sbin/spctl --master-enable" : "/usr/sbin/spctl --master-disable"
        return runAdmin(cmd, prompt: enabled ? L("Kelvin включает Gatekeeper") : L("Kelvin выключает Gatekeeper"))
    }

    // MARK: Карантин новых загрузок (LSQuarantine, домен пользователя)
    /// true — карантин включён (по умолчанию macOS помечает загрузки).
    static var quarantineOn: Bool {
        let v = run(["/usr/bin/defaults", "read", "com.apple.LaunchServices", "LSQuarantine"]).lowercased()
        if v.isEmpty || v.contains("does not exist") { return true }   // не задан → включён
        return !(v == "0" || v == "false" || v == "no")
    }
    static func setQuarantine(_ on: Bool) {
        run(["/usr/bin/defaults", "write", "com.apple.LaunchServices", "LSQuarantine", "-bool", on ? "true" : "false"])
    }

    // MARK: Снять карантин с файла/приложения
    /// Пытается без пароля (файл обычно принадлежит пользователю); при отказе — через admin.
    static func clearQuarantine(_ path: String) -> (ok: Bool, usedAdmin: Bool) {
        if status(["/usr/bin/xattr", "-dr", "com.apple.quarantine", path]) == 0 { return (true, false) }
        let ok = runAdmin("/usr/bin/xattr -dr com.apple.quarantine \(quote(path))",
                          prompt: L("Kelvin снимает карантин с приложения"))
        return (ok, true)
    }
}
