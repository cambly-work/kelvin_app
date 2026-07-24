import Foundation

/// Офлайн IP→страна. Ноль сетевых запросов — данные из бандла (DB-IP country-lite,
/// скомпактировано в Resources/geoip4.bin / geoip6.bin билдером build.sh).
///
/// Формат (отсортировано по start, покрытие непрерывное → «floor по start»):
///   v4: записи по 6 байт  — [u32 start BE][2 байта ISO-кода]
///   v6: записи по 10 байт — [u64 старшие-64-бита start BE][2 байта ISO-кода]
/// Поиск: бинарный, наибольший start ≤ ip → его код страны. Код "ZZ"/приватный → nil.
enum GeoIP {
    private static let v4 = load("geoip4")
    private static let v6 = load("geoip6")

    private static func load(_ name: String) -> [UInt8] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return [] }
        return [UInt8](data)
    }

    /// 2-буквенный ISO-код страны для IP (v4 или v6), или nil (неизвестно/приватный/локальный).
    static func countryCode(for ip: String) -> String? {
        ip.contains(":") ? lookup6(ip) : lookup4(ip)
    }

    /// Готовая метка «🇺🇸 США» для подключения, или nil.
    static func label(for ip: String) -> String? {
        guard let c = countryCode(for: ip) else { return nil }
        return "\(flag(c)) \(name(c))"
    }

    private static func lookup4(_ ip: String) -> String? {
        guard !v4.isEmpty, let key = ipv4ToUInt32(ip) else { return nil }
        let stride = 6, count = v4.count / stride
        var lo = 0, hi = count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2, off = mid * stride
            let start = (UInt32(v4[off]) << 24) | (UInt32(v4[off+1]) << 16)
                      | (UInt32(v4[off+2]) << 8) | UInt32(v4[off+3])
            if start <= key { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0 else { return nil }
        let off = found * stride + 4
        return cc(v4[off], v4[off+1])
    }

    private static func lookup6(_ ip: String) -> String? {
        guard !v6.isEmpty, let key = ipv6HiToUInt64(ip) else { return nil }
        let stride = 10, count = v6.count / stride
        var lo = 0, hi = count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2, off = mid * stride
            var start: UInt64 = 0
            for i in 0..<8 { start = (start << 8) | UInt64(v6[off+i]) }
            if start <= key { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard found >= 0 else { return nil }
        let off = found * stride + 8
        return cc(v6[off], v6[off+1])
    }

    private static func cc(_ a: UInt8, _ b: UInt8) -> String? {
        guard let s = String(bytes: [a, b], encoding: .ascii)?.trimmingCharacters(in: .whitespaces),
              s.count == 2, s != "ZZ" else { return nil }
        return s
    }

    private static func ipv4ToUInt32(_ s: String) -> UInt32? {
        let p = s.split(separator: ".")
        guard p.count == 4 else { return nil }
        var r: UInt32 = 0
        for part in p { guard let n = UInt32(part), n <= 255 else { return nil }; r = (r << 8) | n }
        return r
    }

    private static func ipv6HiToUInt64(_ s: String) -> UInt64? {
        var addr = in6_addr()
        guard s.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else { return nil }
        let bytes = withUnsafeBytes(of: &addr) { Array($0.prefix(8)) }   // старшие 8 байт (network order = BE)
        var r: UInt64 = 0
        for b in bytes { r = (r << 8) | UInt64(b) }
        return r
    }

    /// Флаг-эмодзи из кода (US → 🇺🇸) через regional-indicator symbols.
    static func flag(_ code: String) -> String {
        var s = ""
        for u in code.uppercased().unicodeScalars where u.value >= 65 && u.value <= 90 {
            if let sc = Unicode.Scalar(0x1F1E6 + (u.value - 65)) { s.unicodeScalars.append(sc) }
        }
        return s
    }

    /// Локализованное имя страны по ВЫБРАННОМУ языку приложения (I18n), напр. «США».
    /// Раньше брали Locale.current (язык ОС) — при ручном языке приложения имена стран
    /// расходились с остальным UI. Теперь — язык I18n.current (ru/uk/en/pt).
    static func name(_ code: String) -> String {
        Locale(identifier: I18n.current.rawValue).localizedString(forRegionCode: code) ?? code
    }

    /// Обратно из флаг-эмодзи → ISO-код (🇺🇸 → US). Нужен, чтобы тултип НАЗЫВАЛ именно показанный флаг.
    static func code(fromFlag flag: String) -> String? {
        var code = ""
        for u in flag.unicodeScalars where u.value >= 0x1F1E6 && u.value <= 0x1F1FF {
            code.unicodeScalars.append(Unicode.Scalar(65 + (u.value - 0x1F1E6))!)
        }
        return code.count == 2 ? code : nil
    }
}
