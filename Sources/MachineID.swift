import Foundation
import IOKit
import CryptoKit

/// Аппаратный идентификатор машины + криптопривязка локального состояния лицензии.
///
/// Цель — сделать так, чтобы состояние «Pro активирован» нельзя было НИ подделать `defaults write`,
/// НИ скопировать на другой Mac: валидность подписывается HMAC-SHA256 на ключе, производном из
/// встроенного секрета И аппаратного UUID (IOPlatformUUID). Подделка требует извлечь секрет из бинаря
/// и вычислить HMAC под конкретное железо — это отсекает copy-paste-пиратство (кейген/шаринг/`defaults write`).
///
/// ЧЕСТНАЯ ГРАНИЦА (закон продукта): секрет лежит в бинаре — определённый реверсер его извлечёт. Это НЕ
/// стойкая криптозащита, а «поднять стоимость взлома выше $19». По-настоящему стойкий путь — серверно
/// подписанный Ed25519-entitlement (публичный ключ в приложении, приватный на своём бэкенде) — когда
/// у владельца появится сервер подписи. Здесь — прагматичный клиентский рубеж без сервера/нотаризации.
enum MachineID {
    /// Аппаратный якорь: IOPlatformUUID ‖ IOPlatformSerialNumber. Оба стабильны на железе и недоступны на
    /// другой машине. Комбинируем ДВА: если один пуст (VM/необычное железо/сбой IOKit) — привязка держится
    /// на втором, а не деградирует в переносимый между машинами блоб. Кэшируем (одно чтение IOKit).
    static let hardwareUUID: String = {
        let svc = IOServiceGetMatchingService(ioPort(), IOServiceMatching("IOPlatformExpertDevice"))
        guard svc != 0 else { return "" }
        defer { IOObjectRelease(svc) }
        func prop(_ k: String) -> String {
            (IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String) ?? ""
        }
        let combined = prop("IOPlatformUUID") + "/" + prop("IOPlatformSerialNumber")
        return combined == "/" ? "" : combined
    }()

    /// Встроенный секрет, собранный из замаскированных фрагментов и размаскированный в рантайме — чтобы
    /// `strings` по бинарю не выдавал его открытым текстом (мелкий барьер против скрипт-кидди).
    private static func appSecret() -> [UInt8] {
        let masked: [UInt8] = [
            0x3a, 0x9f, 0x14, 0x7c, 0xd2, 0x08, 0xb5, 0x61, 0x4e, 0xaa, 0x27, 0xf3, 0x90, 0x1c, 0x6d, 0xc8,
            0x55, 0x82, 0x3e, 0xe1, 0x0b, 0x74, 0xbf, 0x29, 0x96, 0x4d, 0xda, 0x17, 0x60, 0xa3, 0xce, 0x38,
        ]
        let mask: UInt8 = 0x5a
        return masked.map { $0 ^ mask }
    }

    /// Ключ HMAC = встроенный секрет ‖ хэш аппаратного UUID → привязка к железу (копия на чужой Mac не пройдёт).
    private static func key() -> SymmetricKey {
        var material = Data(appSecret())
        material.append(contentsOf: SHA256.hash(data: Data(hardwareUUID.utf8)))
        return SymmetricKey(data: material)
    }

    /// HMAC-SHA256(message) в hex. message обязан включать все защищаемые поля.
    static func tag(_ message: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key())
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Проверка тега в постоянное время (защита от timing-side-channel — дёшево и корректно).
    static func verify(_ message: String, tag expected: String) -> Bool {
        let actual = tag(message)
        let a = Array(actual.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}
