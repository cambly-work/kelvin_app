import Foundation
import AppKit

/// Фронт к встроенному фаерволу macOS (Application Layer Firewall, входящие соединения).
/// Чтение состояния — без root; изменения — через нативный диалог админ-пароля.
enum Firewall {
    private static let bin = "/usr/libexec/ApplicationFirewall/socketfilterfw"

    struct AppRule { let path: String; var blocked: Bool; var name: String {
        (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "") } }

    // MARK: чтение (без root)
    private static func read(_ args: [String]) -> String {
        ProcessRunner.output(bin, args, timeout: 8)
    }
    static var available: Bool { FileManager.default.isExecutableFile(atPath: bin) }
    static var enabled: Bool { read(["--getglobalstate"]).contains("State = 1") }
    static var stealth: Bool { read(["--getstealthmode"]).contains("is on") }
    static var blockAll: Bool { read(["--getblockall"]).contains("set to enabled") }

    static func apps() -> [AppRule] {
        let out = read(["--listapps"])
        var rules: [AppRule] = []
        var pendingPath: String?
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let r = line.range(of: " : ") {           // "1 :  /path/App.app"
                pendingPath = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if line.contains("incoming connections"), let path = pendingPath {
                rules.append(AppRule(path: path, blocked: line.contains("Block")))
                pendingPath = nil
            }
        }
        return rules
    }

    // MARK: изменения (root через osascript)
    @discardableResult
    static func privileged(_ commands: [String]) -> Bool {
        let q = SecurityTools.quote(bin)
        let shell = commands.map { "\(q) \($0)" }.joined(separator: " ; ")
        // Экранируем сначала backslash, затем кавычку — как в SecurityTools.runAdmin (иначе путь с \ или " ломает AppleScript-слой).
        let esc = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let src = "do shell script \"\(esc)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err { Log.helper.error("Firewall privileged не выполнилось: \(String(describing: err), privacy: .public)") }
        return err == nil
    }
    static func setEnabled(_ on: Bool) -> Bool { privileged(["--setglobalstate \(on ? "on" : "off")"]) }
    static func setStealth(_ on: Bool) -> Bool { privileged(["--setstealthmode \(on ? "on" : "off")"]) }
    static func setBlockAll(_ on: Bool) -> Bool { privileged(["--setblockall \(on ? "on" : "off")"]) }
    // Путь оборачиваем через SecurityTools.quote — закрывает инъекцию команд root через имя .app (…/Evil';rm…'.app).
    static func block(_ path: String) -> Bool { privileged(["--add \(SecurityTools.quote(path))", "--blockapp \(SecurityTools.quote(path))"]) }
    static func unblock(_ path: String) -> Bool { privileged(["--unblockapp \(SecurityTools.quote(path))"]) }
}
