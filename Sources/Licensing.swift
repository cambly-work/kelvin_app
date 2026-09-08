import Foundation

/// Исторические имена функций сохранены для стабильности call sites.
/// С бесплатной моделью они больше не используются для ограничения доступа.
enum ProFeature: String, CaseIterable {
    case fans, charge, firewall, language, snippets, customToggles, gpuSwitch, netBlock, vpn, audioSwitch, history

    var title: String {
        switch self {
        case .fans:          return L("Управление вентиляторами")
        case .charge:        return L("Лимит заряда батареи")
        case .firewall:      return L("Фаервол")
        case .language:      return L("Переключение языка и опечатки")
        case .snippets:      return L("Сниппеты")
        case .customToggles: return L("Свои кнопки-команды")
        case .gpuSwitch:     return L("Переключение видеокарты")
        case .netBlock:      return L("Блокировка подключений")
        case .vpn:           return L("Переключатель системного VPN")
        case .audioSwitch:   return L("Переключение аудиовыхода")
        case .history:       return L("История трендов свыше 24 часов")
        }
    }
}

/// Фасад оставлен, чтобы переход на бесплатную модель не ломал рабочий код.
/// `isPro` теперь означает «функция доступна» и всегда равен true.
final class Licensing {
    static let shared = Licensing()
    private init() {}

    var isPro: Bool { true }
}
