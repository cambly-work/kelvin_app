import AppKit

/// Описание готового переключателя для плитки быстрых действий.
struct QuickToggleDef {
    let id: String
    let label: String
    let icon: String
    let accent: NSColor
    let available: () -> Bool
    let isOn: () -> Bool
    let toggle: () -> Void
}

/// Реестр встроенных переключателей. Используется и поповером (для рендера),
/// и настройками (для списка). Добавить новый — просто добавить запись.
enum QuickToggleRegistry {
    private static var savedKb: Float = 1
    private static var hiddenTweak: FinderTweaks.Tweak? { FinderTweaks.tweaks.first { $0.key == "AppleShowAllFiles" } }

    // Все встроенные тумблеры — единая фирменная бирюза (см. CCToggle.isBuiltin),
    // без «MIUI-радуги». Реальный рендер берёт Design.Color.accent(dark) по теме.
    private static let brand = Design.Color.accent(true)

    // V5 (решение владельца): плитка — витрина ФИЧЕЙ KELVIN, а не дубль Пункта управления macOS.
    // Системные тумблеры (Wi-Fi/BT/тёмная тема/Night Shift/подсветка) УБРАНЫ отовсюду —
    // toggleLayout сам отбрасывает исчезнувшие id, миграция автоматическая.
    static let all: [QuickToggleDef] = [
        QuickToggleDef(id: "limit80", label: L("Лимит 80%"), icon: "battery.75percent", accent: brand,
                       available: { BatteryReader.read() != nil },
                       isOn: {
                           HelperInstall.fandInstalled
                               && ChargeControl.mode != "sail" && ChargeControl.limit < 100
                       },
                       toggle: {
                           let configured = ChargeControl.mode != "sail" && ChargeControl.limit < 100
                           if configured {
                               ChargeControl.setMode("off")                 // выключить можно всегда
                           } else if !HelperInstall.fandInstalled {
                               SettingsCoordinator.open(section: "power")  // setup без внезапного password prompt
                           } else {
                               ChargeControl.setMode("limit")
                           }
                       }),
        QuickToggleDef(id: "topup", label: L("До 100%"), icon: "bolt.badge.clock", accent: brand,
                       available: { BatteryReader.read() != nil },
                       isOn: { HelperInstall.fandInstalled && ChargeControl.isTopUpActive },
                       toggle: {
                           if ChargeControl.isTopUpActive {                 // отмена дозаряда — свободно (честно: вернуть потолок)
                               SettingsStore.topUpUntil = 0
                               ChargeControl.writeJSON()
                           } else if !HelperInstall.fandInstalled {
                               SettingsCoordinator.open(section: "power")
                           } else {
                               ChargeControl.topUp()                        // Pro-гейт внутри
                           }
                       }),
        QuickToggleDef(id: "turbofan", label: L("Турбо-кулеры"), icon: "fanblades.fill", accent: brand,
                       available: { !FanController.fans().isEmpty },
                       isOn: { FanController.daemonInstalled && SettingsStore.activeFanProfileName == "turbo" },
                       toggle: {
                           guard Licensing.shared.isPro else { _ = SettingsCoordinator.requirePro(.fans); return }
                           if SettingsStore.activeFanProfileName == "turbo" {
                               FanController.applyProfileHeadless(named: "auto")
                           } else if !FanController.daemonInstalled {
                               SettingsCoordinator.open(section: "cooling")
                           } else {
                               FanController.applyProfileHeadless(named: "turbo")
                           }
                       }),
        // Root-firewall action намеренно не выдаём за «быстрый переключатель»:
        // текущий compatibility path требует системной авторизации на каждое действие.
        // Он останется в явном разделе Security до переноса в typed privileged service.
        QuickToggleDef(id: "caffeine", label: L("Не засыпать"), icon: "cup.and.saucer.fill", accent: brand,
                       available: { true }, isOn: { Caffeine.active }, toggle: { Caffeine.toggle() }),
        QuickToggleDef(id: "hidden", label: L("Скрытые файлы"), icon: "eye", accent: brand,
                       available: { true }, isOn: { hiddenTweak.map { FinderTweaks.isOn($0) } ?? false },
                       toggle: { if let t = hiddenTweak { FinderTweaks.toggle(t) } }),
    ]
    static func def(_ id: String) -> QuickToggleDef? { all.first { $0.id == id } }
    static var availableDefs: [QuickToggleDef] { all.filter { $0.available() } }
}

/// Запуск произвольной shell-команды для своей кнопки (от пользователя, без root, без Терминала).
enum CustomCommand {
    static func run(_ cmd: String) {
        let c = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-lc", c]
        try? p.run()
    }
}
