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
