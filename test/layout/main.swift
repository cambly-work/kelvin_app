import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        print("  ✗ \(message)")
        failures += 1
    }
}

let plain = KeyboardLayoutEngine.splitTrailingPunctuation("ghbdtn")
expect(plain.coreLength == 6 && plain.suffix.isEmpty, "plain word must stay intact")

let punctuated = KeyboardLayoutEngine.splitTrailingPunctuation("ghbdtn,?!")
expect(punctuated.coreLength == 6, "word core must exclude trailing punctuation")
expect(punctuated.suffix == ",?!", "trailing punctuation must be preserved verbatim")

let internalPunctuation = KeyboardLayoutEngine.splitTrailingPunctuation("foo-bar")
expect(internalPunctuation.coreLength == 7 && internalPunctuation.suffix.isEmpty,
       "internal punctuation must not be detached")

expect(KeyboardLayoutEngine.isSafeTrailingPunctuation(","), "comma must be a supported suffix")
expect(!KeyboardLayoutEngine.isSafeTrailingPunctuation("-"), "hyphen must remain conservative")

expect(!KeyboardLanguageDetector.shouldConvert(
    typed: "ab", converted: "фи", sourceLanguage: "en", targetLanguage: "ru", capsLock: false
), "two-letter words must remain untouched")
expect(!KeyboardLanguageDetector.shouldConvert(
    typed: "abc123", converted: "фис123", sourceLanguage: "en", targetLanguage: "ru", capsLock: false
), "tokens with digits must remain untouched")
expect(!KeyboardLanguageDetector.shouldConvert(
    typed: "HTTP", converted: "РЕЕЗ", sourceLanguage: "en", targetLanguage: "ru", capsLock: false
), "all-caps acronyms must remain untouched")

if failures > 0 {
    exit(1)
}
print("  ✓ KeyboardLayoutEngine (\(8) проверок)")
