import AppKit

/// Описание готового переключателя для плитки быстрых действий.
struct QuickToggleDef {
    let id: String
    let label: String
    let icon: String
    let accent: NSColor
    let isMomentaryAction: Bool
    let tooltip: String?
    let available: () -> Bool
    let isOn: () -> Bool
    let toggle: () -> Void

    init(id: String, label: String, icon: String, accent: NSColor,
         isMomentaryAction: Bool = false, tooltip: String? = nil,
         available: @escaping () -> Bool, isOn: @escaping () -> Bool,
         toggle: @escaping () -> Void) {
        self.id = id
        self.label = label
        self.icon = icon
        self.accent = accent
        self.isMomentaryAction = isMomentaryAction
        self.tooltip = tooltip
        self.available = available
        self.isOn = isOn
        self.toggle = toggle
    }
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
        QuickToggleDef(id: "limit80", label: L("Лимит заряда"), icon: "battery.75percent", accent: brand,
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
                               ChargeControl.topUp()
                           }
                       }),
        QuickToggleDef(id: "turbofan", label: L("Турбо-кулеры"), icon: "fanblades.fill", accent: brand,
                       available: { !FanController.fans().isEmpty },
                       isOn: { FanController.daemonInstalled && SettingsStore.activeFanProfileName == "turbo" },
                       toggle: {
                           if SettingsStore.activeFanProfileName == "turbo" {
                               // Повторное нажатие возвращает системный режим.
                               FanController.applyProfileHeadless(named: "auto")
                           } else if !Licensing.shared.isPro {
                               _ = SettingsCoordinator.requirePro(.fans)
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
        QuickToggleDef(
            id: "freeMemory",
            label: L("Освободить RAM"),
            icon: "memorychip",
            accent: brand,
            isMomentaryAction: true,
            tooltip: L("Освобождает файловый кэш в оперативной памяти. Память приложений и данные не удаляются; macOS может запросить пароль администратора."),
            available: { FileManager.default.isExecutableFile(atPath: "/usr/sbin/purge") },
            isOn: { false },
            toggle: {
                MemoryInfo.releaseFileCache { result in
                    let alert = NSAlert()
                    alert.alertStyle = result == .success ? .informational : .warning
                    switch result {
                    case .success:
                        alert.messageText = L("Кэш памяти освобождён")
                        alert.informativeText = L("macOS освободила доступный файловый кэш. Объём занятой RAM может быстро вырасти снова — это нормально.")
                    case .alreadyRunning:
                        alert.messageText = L("Очистка памяти уже выполняется")
                        alert.informativeText = L("Дождитесь завершения текущей операции.")
                    case .failed:
                        alert.messageText = L("Не удалось освободить кэш памяти")
                        alert.informativeText = L("Действие отменено или macOS не разрешила очистку.")
                    }
                    alert.runModal()
                }
            }
        ),
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
