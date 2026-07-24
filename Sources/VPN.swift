import Foundation

/// Системный VPN: статус (free) + connect/disconnect настроенного профиля (Pro).
///
/// ЧЕСТНОСТЬ: управляем ТОЛЬКО системными профилями (scutil --nc) — Kelvin НЕ VPN-провайдер,
/// свой туннель не поднимаем. «Защищён» говорим лишь когда ИМЕНОВАННЫЙ профиль Connected;
/// голый utun ≠ VPN (Tailscale/др. поднимают utun даже при Disconnected — на этой машине 4 utun UP,
/// профиль «Tailscale» Disconnected, маршрут по умолчанию через en0). Поэтому первичные факты —
/// состояние профиля + интерфейс маршрута по умолчанию; число utun — приглушённая деталь.
enum VPN {
    struct Profile: Equatable { let name: String; let connected: Bool; let enabled: Bool }
    struct Status: Equatable {
        let profiles: [Profile]
        let defaultInterface: String       // en0 / utunN — интерфейс маршрута по умолчанию
        let utunCount: Int
        /// Подключённый именованный профиль (если есть).
        var active: Profile? { profiles.first { $0.connected } }
        var hasProfiles: Bool { !profiles.isEmpty }
    }

    /// Асинхронный снимок: shell-чтения в фоне, результат — на main (не блокируем UI при открытии/смене вкладки).
    static func status(completion: @escaping (Status) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let s = status()
            DispatchQueue.main.async { completion(s) }
        }
    }

    /// Снимок статуса. Все чтения без root. Синхронный — звать из фона (см. status(completion:)).
    static func status() -> Status {
        var profiles: [Profile] = []
        for raw in shell("/usr/sbin/scutil", ["--nc", "list"]).split(separator: "\n") {
            let line = String(raw)
            // формат строки сервиса: "* (Disconnected)   UUID VPN (bundle) \"Name\" [VPN:...]"
            guard let o = line.firstIndex(of: "("), let cl = line[o...].firstIndex(of: ")") else { continue }
            let state = String(line[line.index(after: o)..<cl])
            let quoted = line.split(separator: "\"")
            guard quoted.count >= 2 else { continue }           // без имени в кавычках — это заголовок, пропускаем
            let name = String(quoted[1])
            let enabled = line.trimmingCharacters(in: .whitespaces).hasPrefix("*")
            profiles.append(Profile(name: name, connected: state == "Connected", enabled: enabled))
        }
        let utun = shell("/sbin/ifconfig", ["-l"]).split(separator: " ").filter { $0.hasPrefix("utun") }.count
        return Status(profiles: profiles, defaultInterface: defaultIface(), utunCount: utun)
    }

    /// Подключить/отключить системный профиль по имени. Обычно без root (пользовательский VPN);
    /// если ОС потребует авторизацию — покажет свой диалог.
    static func connect(_ name: String) { _ = shell("/usr/sbin/scutil", ["--nc", "start", name]) }
    static func disconnect(_ name: String) { _ = shell("/usr/sbin/scutil", ["--nc", "stop", name]) }

    private static func defaultIface() -> String {
        for raw in shell("/sbin/route", ["-n", "get", "default"]).split(separator: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                return t.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return "—"
    }

    private static func shell(_ path: String, _ args: [String]) -> String {
        ProcessRunner.output(path, args, timeout: 8)
    }
}
