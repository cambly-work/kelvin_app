import Foundation

/// Конвертация символов между раскладками ЙЦУКЕН (RU) и QWERTY (EN).
/// Используется и для детекта (как выглядел бы текст в другой раскладке),
/// и для перенабора через карту (запасной путь, если перепостить клавиши нельзя).
enum LayoutMap {
    // EN → RU по физическим клавишам (нижний регистр)
    private static let en2ruLower: [Character: Character] = [
        "`": "ё",
        "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н",
        "u": "г", "i": "ш", "o": "щ", "p": "з", "[": "х", "]": "ъ",
        "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п", "h": "р",
        "j": "о", "k": "л", "l": "д", ";": "ж", "'": "э",
        "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и", "n": "т",
        "m": "ь", ",": "б", ".": "ю", "/": ".",
    ]

    private static let en2ru: [Character: Character] = build()
    private static let ru2en: [Character: Character] = {
        var m: [Character: Character] = [:]
        for (e, r) in en2ru { m[r] = e }
        return m
    }()

    private static func build() -> [Character: Character] {
        var m = en2ruLower
        // верхний регистр для букв
        for (e, r) in en2ruLower {
            let eu = Character(e.uppercased()), ru = Character(r.uppercased())
            if eu != e || ru != r { m[eu] = ru }
        }
        return m
    }

    static func isCyrillic(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first else { return false }
        return (0x0410...0x044F).contains(Int(s.value)) || s.value == 0x0401 || s.value == 0x0451
    }
    static func isLatinLetter(_ c: Character) -> Bool { c.isLetter && c.isASCII }

    /// Конвертирует символ в «другую» раскладку (EN↔RU). Прочее — без изменений.
    static func flip(_ c: Character) -> Character {
        if let r = en2ru[c] { return r }
        if let e = ru2en[c] { return e }
        return c
    }

    /// Конвертирует слово, переключая раскладку для каждого символа.
    static func flip(word: String) -> String { String(word.map(flip)) }

    /// Целевая раскладка для конвертации слова: .ru если слово сейчас латиницей, иначе .en
    enum Target { case ru, en }
    static func target(for word: String) -> Target {
        let cyr = word.filter { isCyrillic($0) }.count
        let lat = word.filter { isLatinLetter($0) }.count
        return cyr >= lat ? .en : .ru
    }
    
    /// Известные пары раскладок для автопереключения (source ID → target ID паттерны)
    static var knownPairs: [String: String] {
        // Паттерны ID → целевой паттерн (упрощённо: RU ↔ UK)
        return [
            "com.apple.keylayout.Russian": "com.apple.keylayout.Ukrainian",
            "com.apple.keylayout.Ukrainian": "com.apple.keylayout.Russian",
            "com.apple.inputmethod.Russian.Cyrillic": "com.apple.inputmethod.Ukrainian",
            "com.apple.inputmethod.Ukrainian": "com.apple.inputmethod.Russian.Cyrillic",
        ]
    }
}

