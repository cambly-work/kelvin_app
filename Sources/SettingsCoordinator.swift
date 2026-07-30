import AppKit
import Foundation

/// Единая точка входа в настройки и платные возможности.
///
/// Не наследуется от `NSWindowController`, поэтому обычное открытие настроек,
/// Pro-проверка или запрос helper больше не создают тяжёлое legacy AppKit-окно.
enum SettingsCoordinator {
    static var window: NSWindow? {
        KelvinSettingsWindowController.shared.window
    }

    static func open(section: String? = nil) {
        KelvinSettingsWindowController.shared.open(section: section)
    }

    static func select(_ section: String) {
        KelvinSettingsWindowController.shared.select(section)
    }

    static func refresh() {
        KelvinSettingsWindowController.shared.refresh()
    }

    @discardableResult
    static func requirePro(_ feature: ProFeature) -> Bool {
        if Licensing.shared.isPro { return true }

        let alert = NSAlert()
        alert.messageText = I18n.proFeatureTitle(feature.title)
        alert.informativeText = Licensing.shared.licenseKey != nil
            ? L("Лицензия есть, но не подтверждена — проверьте соединение и переактивируйте ключ в разделе Pro.")
            : String(
                format: L("Мониторинг бесплатен навсегда. Управление и автоматизация — в Kelvin Pro: разовая покупка %@, %@ на лицензию, без подписки."),
                AppConfig.proPriceDisplay,
                L("2 Mac")
            )
        alert.addButton(withTitle: String(format: L("Купить за %@"), AppConfig.proPriceDisplay))
        alert.addButton(withTitle: L("Ввести ключ"))
        alert.addButton(withTitle: L("Позже"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openCheckout()
        case .alertSecondButtonReturn:
            open(section: "pro")
        default:
            break
        }
        return false
    }

    /// Единственная интерактивная точка установки/обновления control-service.
    /// Вызывается только из явной CTA — никогда из slider/toggle setter.
    @discardableResult
    static func installSystemControlHelper() -> Bool {
        let state = HelperInstall.installState(.control)
        if state == .installed { return true }
        if state == .starting { return false }
        let alert = NSAlert()
        switch state {
        case .notInstalled:
            alert.messageText = L("Подключить системное управление")
            alert.informativeText = L("Kelvin установит один системный компонент для лимита заряда и управления вентиляторами. Пароль администратора понадобится только сейчас.")
            alert.addButton(withTitle: L("Подключить"))
        case .updateAvailable:
            alert.messageText = L("Обновить системное управление")
            alert.informativeText = L("В приложении есть новая версия системного компонента. Текущие настройки сохранятся.")
            alert.addButton(withTitle: L("Обновить"))
        case .repairNeeded:
            alert.messageText = L("Восстановить системное управление")
            alert.informativeText = L("Установка неполная. Kelvin восстановит системный компонент и сохранит ваши настройки.")
            alert.addButton(withTitle: L("Восстановить"))
        case .starting, .installed:
            return true
        }
        alert.addButton(withTitle: L("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let result = HelperInstall.runPrivileged(
            "install-fan-helper.sh",
            prompt: L("Kelvin подключает системное управление")
        )
        let ok = HelperInstall.presentFailureIfNeeded(result, title: L("Не удалось подключить системное управление"))
        if ok {
            // Конфиги могли быть подготовлены до установки — daemon применит их сразу.
            ChargeControl.writeJSON()
            FanController.writeProfileFile(FanController.profile(named: SettingsStore.activeFanProfileName))
        }
        KelvinSettingsWindowController.shared.refresh()
        NotificationCenter.default.post(name: Notification.Name("BMHelperStateChanged"), object: nil)
        return ok
    }

    /// Совместимость со старыми call sites. Это всё равно явный UI action;
    /// автоматические вызовы из ChargeControl удалены.
    static func ensureChargeHelper() {
        _ = installSystemControlHelper()
    }

    /// Открыть системную панель Login Items (для одобрения привилегированного GPU-сервиса).
    /// Вызывается только при approvalRequired — не при штатном переключении.
    static func openLoginItemsSettings() {
        if #available(macOS 13.0, *) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        } else {
            MacSystemSettings.open(["x-apple.systempreferences:com.apple.preference.users"])
        }
    }

    private static func openCheckout() {
        guard let checkout = Licensing.checkoutURL,
              let url = URL(string: checkout)
        else {
            let alert = NSAlert()
            alert.messageText = L("Покупка временно недоступна")
            alert.informativeText = L("Магазин Lemon Squeezy ещё не подключён. Пожалуйста, активируйте лицензию ключом или попробуйте позже.")
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        NSWorkspace.shared.open(url)
    }
}
