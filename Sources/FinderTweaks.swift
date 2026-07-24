import Foundation

/// Тумблеры Finder/рабочего стола через `defaults` (домен пользователя, без root).
/// Иконки дисков на столе, расширения, скрытые файлы, строка пути/состояния.
enum FinderTweaks {
    struct Tweak {
        let title: String
        let domain: String
        let key: String
        let killFinder: Bool      // изменению нужен перезапуск Finder, чтобы вступило в силу
    }

    static let tweaks: [Tweak] = [
        .init(title: L("Жёсткие диски на столе"),          domain: "com.apple.finder", key: "ShowHardDrivesOnDesktop",         killFinder: true),
        .init(title: L("Внешние диски на столе"),          domain: "com.apple.finder", key: "ShowExternalHardDrivesOnDesktop", killFinder: true),
        .init(title: L("Съёмные носители на столе"),        domain: "com.apple.finder", key: "ShowRemovableMediaOnDesktop",     killFinder: true),
        .init(title: L("Серверы на столе"),                 domain: "com.apple.finder", key: "ShowMountedServersOnDesktop",     killFinder: true),
        .init(title: L("Показывать расширения файлов"),     domain: "NSGlobalDomain",   key: "AppleShowAllExtensions",          killFinder: true),
        .init(title: L("Показывать скрытые файлы"),         domain: "com.apple.finder", key: "AppleShowAllFiles",               killFinder: true),
        .init(title: L("Строка пути"),                      domain: "com.apple.finder", key: "ShowPathbar",                     killFinder: true),
        .init(title: L("Строка состояния (место, размер)"), domain: "com.apple.finder", key: "ShowStatusBar",                   killFinder: true),
    ]

    @discardableResult
    private static func run(_ args: [String]) -> String {
        ProcessRunner.output("/usr/bin/env", args, timeout: 8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Текущее состояние тумблера (ключ может отсутствовать → false).
    /// Читаем НАПРЯМУЮ через CFPreferences, а не форком `defaults read`: refreshToggles() зовётся
    /// каждый 1Гц-тик при открытом поповере — форк подпроцесса на main-потоке ежесекундно был заметным хэнгом.
    static func isOn(_ t: Tweak) -> Bool {
        let appID: CFString = (t.domain == "NSGlobalDomain") ? kCFPreferencesAnyApplication : t.domain as CFString
        CFPreferencesAppSynchronize(appID)                       // подхватить свежее значение с диска (дёшево, без подпроцесса)
        guard let v = CFPreferencesCopyAppValue(t.key as CFString, appID) else { return false }
        if let n = v as? NSNumber { return n.boolValue }
        let s = (v as? String)?.lowercased() ?? ""
        return s == "1" || s == "true" || s == "yes"
    }

    /// Установить значение и при необходимости перезапустить Finder.
    static func set(_ t: Tweak, _ on: Bool) {
        run(["defaults", "write", t.domain, t.key, "-bool", on ? "true" : "false"])
        if t.killFinder { run(["killall", "Finder"]) }
    }

    static func toggle(_ t: Tweak) { set(t, !isOn(t)) }
}
