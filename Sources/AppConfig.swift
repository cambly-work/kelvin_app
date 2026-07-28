import Foundation
import AppKit

// ════════════════════════════════════════════════════════════════════════════
//  KELVIN — ЕДИНЫЙ ФАЙЛ НАСТРОЕК ПРИЛОЖЕНИЯ ДЛЯ ВЛАДЕЛЬЦА
//
//  Здесь собрана вся «инфа о приложении», которую можно менять руками.
//  Поправь значения ниже (строки в кавычках) и пересобери:
//        ./build.sh && ./install-app.sh
//  Больше эти данные нигде искать не нужно — весь UI берёт их отсюда.
// ════════════════════════════════════════════════════════════════════════════
enum AppConfig {

    // ─── КОММЕРЧЕСКАЯ КОНФИГУРАЦИЯ (Lemon Squeezy) ───────────────────────────
    // Вписать store_id и product_id из настроек продукта Lemon Squeezy.
    // nil → магазин не подключён, кнопка покупки disabled, активация ключей недоступна.
    static let lemonSqueezyStoreID: Int? = nil              // ← store_id из Lemon Squeezy
    static let lemonSqueezyProductID: Int? = nil            // ← product_id из Lemon Squeezy
    static let lemonSqueezyCheckoutURL: String? = nil       // ← checkout URL (https://*.lemonsqueezy.com/checkout/...)
    
    /// Цена Kelvin Pro для отображения в UI.
    static let proPriceDisplay: String = "$19"
    
    /// Лимит активаций на одну лицензию (для отображения).
    static let activationLimitDisplay: Int = 2
    
    /// Длительность trial периода в днях.
    static let trialDays: Int = 14
    
    /// Grace period для офлайн-валидации лицензии (дней после последней успешной проверки).
    static let licenseGraceDays: Int = 7
    
    // ─── TEAM ID для self-validation (hardened runtime / notarization) ────────
    // Вписать Team ID из сертификата Developer ID Application (скобки из строки подписи).
    // Пример: "ABCDE12345" из "Developer ID Application: Artem Balabanov (ABCDE12345)"
    // nil → self-validation выключена (ad-hoc сборка).
    static let expectedDeveloperTeamID: String? = nil       // ← Team ID из Apple Developer
    
    // ─── ССЫЛКА ДОНАТА («Поддержать автора») ──────────────────────────────────
    // Сюда вставь свою ссылку: Boosty / Patreon / PayPal / Ko-fi / крипто-кошелёк…
    // Пока стоит заглушка — кнопки доната откроют её. Замени на реальную.
    static let donateURL = "https://example.com/support-kelvin"          // ← ВПИШИ СВОЮ ССЫЛКУ

    // ─── ПОЧТА ДЛЯ СВЯЗИ ──────────────────────────────────────────────────────
    // Кнопки «Написать автору» / «Обратная связь» открывают письмо на этот адрес.
    static let contactEmail = "cambly.studio@gmail.com"                  // ← твоя почта

    // ─── САЙТ / СТРАНИЦА ПРИЛОЖЕНИЯ ───────────────────────────────────────────
    static let website = "https://trykelvin.com"                         // ← твой сайт (или страница загрузки)

    // ─── ИМЯ И КОПИРАЙТ ───────────────────────────────────────────────────────
    static let appName   = "Kelvin"                                      // имя в письмах/заголовках
    static let copyright = "© 2026 Kelvin · Artem Balabanov"             // строка в «О программе»

    // ─── ВАЛИДАЦИЯ КОНФИГУРАЦИИ (fail-closed для release) ────────────────────
    /// Магазин Lemon Squeezy реально настроен?
    static var isStoreConfigured: Bool {
        guard let store = lemonSqueezyStoreID, let product = lemonSqueezyProductID else { return false }
        return store > 0 && product > 0
    }
    
    /// Team ID настроен для production validation?
    static var isTeamIDConfigured: Bool {
        guard let team = expectedDeveloperTeamID else { return false }
        return !team.isEmpty && team.count >= 10
    }
    
    /// Checkout URL валиден (HTTPS, не заглушка)?
    static var isCheckoutURLValid: Bool {
        guard let url = lemonSqueezyCheckoutURL else { return false }
        return url.hasPrefix("https://") && !url.contains("example.com")
    }

    /// Paywall включается только когда одновременно готовы покупка и активация.
    /// Это не даёт случайно заблокировать Pro-функции релизом с незаполненными nil.
    static var isCommerceEnabled: Bool { isStoreConfigured && isCheckoutURLValid }
    
    /// Diagnostic message для DEBUG (почему магазин не готов).
    static var storeDiagnosticMessage: String {
        var issues: [String] = []
        if lemonSqueezyStoreID == nil || lemonSqueezyStoreID! <= 0 {
            issues.append("storeID не задан или ≤ 0")
        }
        if lemonSqueezyProductID == nil || lemonSqueezyProductID! <= 0 {
            issues.append("productID не задан или ≤ 0")
        }
        if lemonSqueezyCheckoutURL == nil {
            issues.append("checkoutURL не задан")
        } else if !lemonSqueezyCheckoutURL!.hasPrefix("https://") {
            issues.append("checkoutURL должен начинаться с https://")
        } else if lemonSqueezyCheckoutURL!.contains("example.com") {
            issues.append("checkoutURL содержит example.com (заглушка)")
        }
        if issues.isEmpty { return "OK" }
        return issues.joined(separator: "; ")
    }

    // ─── (служебное, менять не нужно) ─────────────────────────────────────────
    /// Донат реально настроен (ссылка не заглушка)?
    static var donateConfigured: Bool { !donateURL.contains("example.com") }
    static func openDonate()  { open(donateURL) }
    static func openWebsite() { open(website) }
    /// Готовый mailto к автору с темой письма.
    static func mailto(subject: String) -> URL? {
        let s = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "mailto:\(contactEmail)?subject=\(s)")
    }
    private static func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }
}
