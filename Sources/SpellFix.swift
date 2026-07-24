import AppKit

/// Консервативное авто-исправление ЯВНЫХ опечаток через системный NSSpellChecker.
/// Локально, без сети. Язык слова определяется по алфавиту (кириллица → ru, иначе en).
/// Правим только когда движок уверенно даёт близкую замену — чтобы не портить текст.
enum SpellFix {
    private static let checker = NSSpellChecker.shared

    /// Возвращает исправление для слова или nil, если трогать не нужно.
    static func correction(for word: String) -> String? {
        // --- фильтры «явной опечатки»: не трогаем сомнительное ---
        guard word.count >= 4, word.count <= 32 else { return nil }
        guard word.allSatisfy({ $0.isLetter }) else { return nil }   // только буквы (без цифр/пунктуации)
        let scalars = word.unicodeScalars
        // пропускаем АББРЕВИАТУРЫ и слова с заглавными внутри (имена/бренды/CamelCase)
        let letters = Array(word)
        if letters.dropFirst().contains(where: { $0.isUppercase }) { return nil }
        if word == word.uppercased() { return nil }

        let lang = scalars.contains(where: { $0.value >= 0x0400 && $0.value <= 0x04FF }) ? "ru" : "en"

        let ns = word as NSString
        let full = NSRange(location: 0, length: ns.length)
        // всё слово целиком должно считаться ошибкой
        let miss = checker.checkSpelling(of: word, startingAt: 0, language: lang,
                                         wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        guard miss.location == 0, miss.length == ns.length else { return nil }

        // System correction is not consistently available for every language.
        // Merge it with ordered guesses and choose the nearest clean candidate.
        var candidates: [String] = []
        if let direct = checker.correction(forWordRange: full, in: word, language: lang,
                                           inSpellDocumentWithTag: 0) {
            candidates.append(direct)
        }
        candidates += checker.guesses(forWordRange: full, in: word, language: lang,
                                      inSpellDocumentWithTag: 0) ?? []
        let clean = candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.allSatisfy({ $0.isLetter }) }
            .filter { $0.lowercased() != word.lowercased() }
        let ranked = clean.map { ($0, editDistance(word.lowercased(), $0.lowercased())) }
            .sorted { $0.1 < $1.1 }
        guard let (fix, distance) = ranked.first else { return nil }

        // Strict is safe for normal use; balanced also permits a two-edit typo,
        // but only for longer words where the collision surface is smaller.
        let balanced = SettingsStore.spellFixMode == "balanced"
        let maxDistance = balanced && word.count >= 6 ? 2 : 1
        guard distance <= maxDistance else { return nil }

        return matchCase(of: word, to: fix)
    }

    /// Переносит регистр первой буквы исходного слова на исправление.
    private static func matchCase(of original: String, to fixed: String) -> String {
        guard let f = original.first, f.isUppercase else { return fixed }
        return fixed.prefix(1).uppercased() + fixed.dropFirst()
    }

    /// Расстояние Левенштейна (для защиты от «диких» замен).
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        // Adjacent transposition is one human typo, not two unrelated edits.
        if s.count == t.count {
            let mismatch = s.indices.filter { s[$0] != t[$0] }
            if mismatch.count == 2, mismatch[1] == mismatch[0] + 1,
               s[mismatch[0]] == t[mismatch[1]], s[mismatch[1]] == t[mismatch[0]] {
                return 1
            }
        }
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var cur = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            cur[0] = i
            for j in 1...t.count {
                let cost = s[i-1] == t[j-1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[t.count]
    }
}
