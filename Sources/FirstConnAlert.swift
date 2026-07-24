import Foundation
import AppKit

/// «Новое приложение впервые вышло в сеть» — наблюдательный алерт (Радар 2.0). Честность как закон продукта:
///  • Уведомляем ТОЛЬКО о реально новом (не виданном ранее) приложении с РЕАЛЬНЫМ исходящим соединением.
///  • Не перехватываем трафик и не претендуем на это — просто замечаем новизну (Little-Snitch-lite «увидеть»).
///  • Первый снимок при включении тихо заносит текущий парк приложений в «виданные» — без флуда баннеров.
///  • Блок из уведомления = hosts-блок ДОМЕНА (Pro), и только если удалось честно получить имя хоста (PTR).
///    Заголовок действия — «домен», а не «приложение»: macOS-ALF режет лишь входящие, исходящий per-app
///    блок без Network Extension невозможен (роадмап это и отклонил) — не обещаем того, чего нет.
///
/// Гейт Free/Pro: сам факт «видеть» — бесплатно; «управлять» (блок домена) — Pro. Множество «виданных»
/// персистится в UserDefaults, чтобы после перезапуска не заваливать пользователя старыми приложениями.
final class FirstConnAlert {
    static let shared = FirstConnAlert()
    private init() { seen = Set(UserDefaults.standard.stringArray(forKey: seenKey) ?? []) }

    struct NetApp { let id: String; let name: String; let endpoint: String; let code: String? }

    private let seenKey = "firstconn.seen"
    private let primedKey = "firstconn.primed"
    private var seen: Set<String>

    /// Хук открытия радара — ставит AppDelegate при старте (иначе логика не знает про UI).
    var showRadar: (() -> Void)?

    // Мастер-тумблер «Показывать уведомления» глушит и баннеры первого выхода в сеть (иначе они шли бы
    // при выключенных уведомлениях). Обе настройки должны быть включены.
    var enabled: Bool { SettingsStore.firstConnAlerts && SettingsStore.alertsEnabled }

    /// Внешне-маршрутизируемый адрес? Отсекаем loopback / link-local / unspecified. Приватный LAN
    /// считаем «сетью» (приложение реально куда-то пошло) — дедуп per-app держит шум ограниченным.
    static func isRoutable(_ ip: String) -> Bool {
        if ip.isEmpty || ip == "*" { return false }
        if ip.hasPrefix("127.") || ip == "::1" || ip == "0.0.0.0" || ip == "::" { return false }
        if ip.hasPrefix("169.254.") || ip.lowercased().hasPrefix("fe80") { return false }   // link-local
        return true
    }

    /// Рассмотреть снимок сетевых приложений (main, ≈раз/5с из refreshAppFlags). При выключенной фиче —
    /// мгновенный выход (ноль накладных). При первом включении — тихий прайм парка, дальше уведомляем о новых.
    func consider(_ apps: [NetApp], now: Date) {
        guard enabled else { return }
        let d = UserDefaults.standard
        if !d.bool(forKey: primedKey) {                        // прайм: заносим текущий парк, не уведомляя
            for a in apps { seen.insert(a.id) }
            persist(); d.set(true, forKey: primedKey)
            return
        }
        var fresh: [NetApp] = []
        for a in apps where !seen.contains(a.id) {
            seen.insert(a.id); fresh.append(a)
        }
        guard !fresh.isEmpty else { return }
        persist()
        // Антифлуд: до 3 индивидуальных баннеров, остаток — один сводный (VPN/старт dev-среды/восст. сети
        // могут вывести пачку новых бинарей в одном снимке — фича обещает не заваливать баннерами).
        let maxBanners = 3
        for a in fresh.prefix(maxBanners) {
            AlertsEngine.shared.postFirstConn(app: a.name, endpoint: a.endpoint, code: a.code)
        }
        let overflow = fresh.count - maxBanners
        if overflow > 0 { AlertsEngine.shared.postFirstConnSummary(count: overflow) }
    }

    private func persist() { UserDefaults.standard.set(Array(seen), forKey: seenKey) }

    /// Сбросить базу «виданных» (из настроек / при выключении) — следующий снимок перезаснимет парк молча.
    func reset() {
        seen.removeAll()
        UserDefaults.standard.removeObject(forKey: seenKey)
        UserDefaults.standard.set(false, forKey: primedKey)
    }
}
