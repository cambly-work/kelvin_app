import Foundation

/// Эвристика: набрано ли слово не в той раскладке (для авто-режима).
/// Без словаря — по доле гласных в текущем алфавите vs в «перевёрнутом».
/// Консервативна: лучше не сконвертировать, чем сконвертировать лишнее.
enum LangDetect {
    private static let enVowels = Set("aeiouy")
    private static let ruVowels = Set("аеёиоуыэюя")

    private static func vowelRatio(_ s: String, cyrillic: Bool) -> Double {
        let letters = s.lowercased().filter { $0.isLetter }
        guard !letters.isEmpty else { return 0 }
        let set = cyrillic ? ruVowels : enVowels
        let v = letters.filter { set.contains($0) }.count
        return Double(v) / Double(letters.count)
    }

    static func shouldConvert(_ word: String) -> Bool {
        let letters = word.filter { $0.isLetter }
        guard letters.count >= 3 else { return false }

        let cyr = letters.filter { LayoutMap.isCyrillic($0) }.count
        let lat = letters.filter { LayoutMap.isLatinLetter($0) }.count
        guard cyr == 0 || lat == 0 else { return false }      // смешанное — не трогаем
        let isCyr = cyr > lat

        let cur = String(letters)
        let flipped = LayoutMap.flip(word: cur)
        let curRatio = vowelRatio(cur, cyrillic: isCyr)
        let flipRatio = vowelRatio(flipped, cyrillic: !isCyr)

        // сильный сигнал: в текущем языке гласных нет, в другом — есть
        if curRatio < 0.08 && flipRatio >= 0.15 { return true }
        // мягкий: другой язык заметно правдоподобнее
        if curRatio < 0.25 && (flipRatio - curRatio) > 0.18 { return true }
        return false
    }
}
