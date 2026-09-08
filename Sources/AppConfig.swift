import Foundation
import AppKit

// Единое место для публичных данных Kelvin.
enum AppConfig {
    // Kelvin бесплатен: все функции доступны без ключа, триала и подписки.
    // Для донатов вставь сюда Boosty / Ko-fi / PayPal / Patreon URL.
    // Пока URL не задан, кнопка благодарности откроет письмо автору.
    static let supportURL: String? = nil

    // TEAM ID для hardened runtime / notarization и проверки privileged helper.
    static let expectedDeveloperTeamID: String? = nil

    static let contactEmail = "cambly.studio@gmail.com"
    static let website = "https://trykelvin.com"

    static let bundleID = "com.trykelvin.kelvin"
    static let appcastURL = "\(website)/appcast.xml"
    static let privacyURL = "\(website)/privacy.html"
    static let eulaURL = "\(website)/eula.html"

    static let appName = "Kelvin"
    static let copyright = "© 2026 Kelvin · Artem Balabanov"

    static var isTeamIDConfigured: Bool {
        guard let team = expectedDeveloperTeamID else { return false }
        return !team.isEmpty && team.count >= 10
    }

    static var supportConfigured: Bool {
        guard let value = supportURL else { return false }
        return value.hasPrefix("https://") && !value.contains("example.com")
    }

    static func openSupport() {
        if supportConfigured, let supportURL {
            open(supportURL)
        } else if let message = mailto(subject: "Спасибо за Kelvin") {
            NSWorkspace.shared.open(message)
        }
    }

    static func openWebsite() { open(website) }

    static func mailto(subject: String) -> URL? {
        let s = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "mailto:\(contactEmail)?subject=\(s)")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
