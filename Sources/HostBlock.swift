import Foundation
import AppKit

/// Блокировка доменов через /etc/hosts (домен → 0.0.0.0). Режет резолвинг для всех
/// приложений. Чтение — без root; запись — через root-скрипт (osascript admin) + сброс DNS.
enum HostBlock {
    static let marker1 = "# >>> Kelvin blocklist >>>"
    static let marker2 = "# <<< Kelvin blocklist <<<"

    /// Текущий список заблокированных доменов (парсит секцию в /etc/hosts).
    static func current() -> [String] {
        guard let hosts = try? String(contentsOfFile: "/etc/hosts", encoding: .utf8) else { return [] }
        var inBlock = false
        var domains: [String] = []
        for raw in hosts.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.contains(marker1) { inBlock = true; continue }
            if line.contains(marker2) { inBlock = false; continue }
            if inBlock {
                let parts = line.split(separator: " ").filter { !$0.isEmpty }
                if parts.count >= 2 { domains.append(String(parts[1])) }
            }
        }
        return domains
    }

    /// Применяет список доменов: пишет файл и запускает root-скрипт через диалог пароля.
    @discardableResult
    static func apply(_ domains: [String]) -> Bool {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Kelvin")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let listPath = (dir as NSString).appendingPathComponent("blocklist.txt")
        let clean = domains.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        try? clean.joined(separator: "\n").write(toFile: listPath, atomically: true, encoding: .utf8)

        guard let script = Bundle.main.path(forResource: "apply-blocklist", ofType: "sh") else { return false }
        let cmd = "\(SecurityTools.quote(script)) \(SecurityTools.quote(listPath))"   // квотируем пути — закрываем инъекцию через апостроф в $HOME
        let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let src = "do shell script \"\(esc)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        return err == nil
    }
}
