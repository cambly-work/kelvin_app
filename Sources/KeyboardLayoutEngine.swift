import AppKit
import Carbon.HIToolbox

// Portions of this layout engine are adapted from RuSwitcher.
// Copyright (c) 2025 Rashns, used under the MIT License.
// See THIRD_PARTY_NOTICES/RuSwitcher-MIT.txt.

/// A physical key captured while the user is typing.
struct LayoutTypedKey {
    let code: UInt16
    let shift: Bool
    let caps: Bool
    let character: Character
}

/// Resolves the active EN/RU layout pair and translates physical keys with
/// UCKeyTranslate. Unlike the old hard-coded QWERTY table this also respects
/// Russian-PC, British, ABC and other installed layout variants.
enum KeyboardLayoutEngine {
    struct Conversion {
        let original: String
        let converted: String
        let sourceID: String
        let targetID: String
        let sourceLanguage: String
        let targetLanguage: String
    }

    private static let cacheLock = NSLock()
    private static var dataCache: [String: Data] = [:]
    private static var layoutsCache: [TISInputSource]?
    private struct InputSnapshot {
        let sourceID: String
        let targetID: String
        let sourceLanguage: String
        let targetLanguage: String
        let sourceData: Data
        let targetData: Data
    }

    static func conversion(for keys: [LayoutTypedKey]) -> Conversion? {
        guard !keys.isEmpty else { return nil }

        // HIToolbox's Text Input Source API is main-thread-affine on recent
        // macOS releases. Calling it directly from Kelvin's CGEventTap thread
        // ends in _dispatch_assert_queue_fail (SIGILL). Copy the small immutable
        // snapshot on main, then keep the actual translation off the UI thread.
        let snapshot: InputSnapshot? = onMain {
            guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                  let sourceLanguage = language(of: source),
                  let target = oppositeLayout(to: sourceLanguage),
                  let targetLanguage = language(of: target),
                  let sourceData = layoutData(of: source),
                  let targetData = layoutData(of: target) else { return nil }
            return InputSnapshot(
                sourceID: id(of: source),
                targetID: id(of: target),
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                sourceData: sourceData,
                targetData: targetData
            )
        }
        guard let snapshot else { return nil }

        var original = ""
        var converted = ""
        for key in keys {
            guard let from = translate(key, using: snapshot.sourceData),
                  let to = translate(key, using: snapshot.targetData) else { return nil }
            original.append(from)
            converted.append(to)
        }
        guard original != converted else { return nil }
        return Conversion(
            original: original,
            converted: converted,
            sourceID: snapshot.sourceID,
            targetID: snapshot.targetID,
            sourceLanguage: snapshot.sourceLanguage,
            targetLanguage: snapshot.targetLanguage
        )
    }

    static func switchTo(id wantedID: String) {
        onMain {
            guard let target = installedLayouts().first(where: { id(of: $0) == wantedID }) else { return }
            TISSelectInputSource(target)
        }
    }

    private static func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }

    static func splitTrailingPunctuation(_ text: String) -> (coreLength: Int, suffix: String) {
        let allowed: Set<Character> = [",", ".", "!", "?", ";", ":", ")"]
        var core = text[...]
        while let last = core.last, allowed.contains(last) { core = core.dropLast() }
        return (core.count, String(text.dropFirst(core.count)))
    }

    static func isSafeTrailingPunctuation(_ character: Character) -> Bool {
        [",", ".", "!", "?", ";", ":", ")"].contains(character)
    }

    private static func oppositeLayout(to sourceLanguage: String) -> TISInputSource? {
        let source = shortLanguage(sourceLanguage)
        let wanted = source == "ru" ? "en" : "ru"
        return installedLayouts().first { shortLanguage(language(of: $0) ?? "") == wanted }
    }

    private static func installedLayouts() -> [TISInputSource] {
        cacheLock.lock()
        if let cached = layoutsCache {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let conditions: CFDictionary = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsSelectCapable as String: true as Any,
        ] as CFDictionary
        let layouts = TISCreateInputSourceList(conditions, false)?.takeRetainedValue() as? [TISInputSource] ?? []
        cacheLock.lock()
        layoutsCache = layouts
        cacheLock.unlock()
        return layouts
    }

    private static func id(of source: TISInputSource) -> String {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }

    private static func language(of source: TISInputSource) -> String? {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages),
              let languages = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String] else {
            return nil
        }
        return languages.first
    }

    private static func shortLanguage(_ language: String) -> String {
        String(language.lowercased().prefix(2))
    }

    private static func layoutData(of source: TISInputSource) -> Data? {
        let sourceID = id(of: source)
        cacheLock.lock()
        if let cached = dataCache[sourceID] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        cacheLock.lock()
        dataCache[sourceID] = data
        cacheLock.unlock()
        return data
    }

    private static func translate(_ key: LayoutTypedKey, using data: Data) -> Character? {
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        var modifiers: UInt32 = key.shift ? UInt32(shiftKey >> 8) & 0xff : 0
        if key.caps { modifiers |= UInt32(alphaLock >> 8) & 0xff }

        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(
                layout,
                key.code,
                UInt16(kUCKeyActionDown),
                modifiers,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: length)
        return text.count == 1 ? text.first : nil
    }
}

/// Precision-first automatic layout detection backed by macOS dictionaries.
/// A word is converted only when its converted form is valid in the target
/// language and its typed form is not valid in the current language.
enum KeyboardLanguageDetector {
    private static let checker = NSSpellChecker.shared

    static func shouldConvert(
        typed: String,
        converted: String,
        sourceLanguage: String,
        targetLanguage: String,
        capsLock: Bool,
        minimumLength: Int = 3
    ) -> Bool {
        guard typed.count >= minimumLength,
              typed.allSatisfy({ $0.isLetter }),
              converted.allSatisfy({ $0.isLetter }) else { return false }

        if !capsLock {
            if typed == typed.uppercased(), typed != typed.lowercased() { return false }
            if typed.enumerated().contains(where: { $0.offset > 0 && $0.element.isUppercase }) { return false }
            if containsMixedLatinAndCyrillic(typed) { return false }
        }

        let source = shortLanguage(sourceLanguage)
        let target = shortLanguage(targetLanguage)
        guard dictionaryAvailable(for: target),
              isValid(converted.lowercased(), language: target) else { return false }
        if dictionaryAvailable(for: source), isValid(typed.lowercased(), language: source) {
            return false
        }
        return true
    }

    static func isAutoConversionDenied(in bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        let exact: Set<String> = [
            "com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
            "io.alacritty", "com.github.wez.wezterm", "dev.warp.Warp-Stable",
            "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
            "com.sublimetext.4", "com.google.android.studio",
            "com.1password.1password", "com.agilebits.onepassword7",
            "com.bitwarden.desktop", "org.keepassxc.keepassxc",
        ]
        return exact.contains(id) || id.hasPrefix("com.jetbrains.")
    }

    private static func dictionaryAvailable(for language: String) -> Bool {
        checker.availableLanguages.contains { shortLanguage($0) == language }
    }

    private static func isValid(_ word: String, language: String) -> Bool {
        let range = checker.checkSpelling(
            of: word,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        return range.location == NSNotFound
    }

    private static func shortLanguage(_ language: String) -> String {
        String(language.lowercased().prefix(2))
    }

    private static func containsMixedLatinAndCyrillic(_ text: String) -> Bool {
        var latin = false
        var cyrillic = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5a, 0x61...0x7a: latin = true
            case 0x0400...0x04ff: cyrillic = true
            default: break
            }
        }
        return latin && cyrillic
    }
}
