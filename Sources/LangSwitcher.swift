import AppKit
import Carbon.HIToolbox

/// Keyboard layout correction integrated with Kelvin's settings and feedback.
/// The conversion/detection core is adapted from RuSwitcher (MIT).
final class LangSwitcher {
    static let shared = LangSwitcher()

    enum Mode { case off, hotkey, auto }
    private struct Configuration {
        var mode: Mode = .off
        var hotkeyKeycode = CGKeyCode(kVK_RightOption)
        var snippetsEnabled = false
        var spellFixEnabled = false
        var snippets: [(trigger: String, text: String)] = []
    }
    private let configurationLock = NSLock()
    private var configuration = Configuration()

    var mode: Mode {
        get { withConfiguration { $0.mode } }
        set { updateConfiguration { $0.mode = newValue }; refreshTap() }
    }
    var hotkeyKeycode: CGKeyCode {
        get { withConfiguration { $0.hotkeyKeycode } }
        set { updateConfiguration { $0.hotkeyKeycode = newValue } }
    }
    var snippetsEnabled: Bool {
        get { withConfiguration { $0.snippetsEnabled } }
        set { updateConfiguration { $0.snippetsEnabled = newValue }; refreshTap() }
    }
    var spellFixEnabled: Bool {
        get { withConfiguration { $0.spellFixEnabled } }
        set { updateConfiguration { $0.spellFixEnabled = newValue }; refreshTap() }
    }
    var snippets: [(trigger: String, text: String)] {
        get { withConfiguration { $0.snippets } }
        set { updateConfiguration { $0.snippets = newValue } }
    }

    enum Feedback { case layout(toRU: Bool); case spell }
    var onFeedback: ((Feedback) -> Void)?

    struct RuntimeDiagnostics {
        let trusted: Bool
        let tapActive: Bool
        let recoveries: Int
        let creationFailures: Int
    }

    var runtimeDiagnostics: RuntimeDiagnostics {
        tapStateLock.lock()
        let active = tap != nil && tapThread != nil
        let recoveries = tapRecoveryCount
        let failures = tapCreationFailureCount
        tapStateLock.unlock()
        return RuntimeDiagnostics(
            trusted: isTrusted,
            tapActive: active,
            recoveries: recoveries,
            creationFailures: failures
        )
    }

    private struct RememberedWord {
        let keys: [LayoutTypedKey]
        var trailingSpaces: Int
        let bundleID: String?
    }

    private struct LastConversion {
        var original: String
        var converted: String
        var sourceID: String
        var targetID: String
    }

    private var currentKeys: [LayoutTypedKey] = []
    private var currentBundleID: String?
    private var previousWord: RememberedWord?
    private var tokenBuffer = ""
    private var lastConversion: LastConversion?
    private var userTypedSinceConversion = true

    // CGEventTap must not share Kelvin's busy main run loop (battery/SMC/UI work).
    // All captured-key state below is owned by this dedicated thread.
    private let tapStateLock = NSLock()
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapShouldStop = false
    private var tapRecoveryCount = 0
    private var tapCreationFailureCount = 0

    // All synthetic Delete/Unicode events and the matching TIS layout switch form
    // one ordered transaction. This prevents replacements from interleaving.
    private let injectionQueue = DispatchQueue(label: "com.trykelvin.kelvin.lang-injection",
                                               qos: .userInteractive)
    private var accessPollTimer: Timer?
    private var accessPollCount = 0
    private var accessPromptRequested = false
    private let spellRequestLock = NSLock()
    private var spellRequestGeneration: UInt64 = 0
    private let postSource = CGEventSource(stateID: .privateState)
    private let magic: Int64 = 0x42_4d_4c_53

    private var triggerDown = false
    private var otherKeySinceTrigger = false

    var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    func requestAccessibility() -> Bool {
        let option = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        return AXIsProcessTrustedWithOptions([option: true] as CFDictionary)
    }

    private func withConfiguration<T>(_ body: (Configuration) -> T) -> T {
        configurationLock.lock()
        let snapshot = configuration
        configurationLock.unlock()
        return body(snapshot)
    }

    private func updateConfiguration(_ body: (inout Configuration) -> Void) {
        configurationLock.lock()
        body(&configuration)
        configurationLock.unlock()
    }

    private func refreshTap() {
        let wanted = withConfiguration {
            $0.mode != .off || $0.snippetsEnabled || $0.spellFixEnabled
        }
        wanted ? startTap() : stopTap()
    }

    private func startTap() {
        guard isTrusted else {
            // A saved "hotkey"/"auto" mode is restored during app launch. Previously
            // that path only polled AXIsProcessTrusted and never displayed the macOS
            // permission prompt, leaving the feature silently inert until the user
            // happened to change the segment again in Settings.
            if !accessPromptRequested {
                accessPromptRequested = true
                _ = requestAccessibility()
            }
            awaitAccessibility()
            return
        }
        accessPromptRequested = false

        tapStateLock.lock()
        guard tapThread == nil else {
            tapStateLock.unlock()
            return
        }
        tapShouldStop = false
        let thread = Thread { [weak self] in
            self?.runTapLoop()
        }
        thread.name = "Kelvin Keyboard Monitor"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        tapStateLock.unlock()
        thread.start()
        stopAwaitingAccess()
    }

    /// Owns the event tap and its CFRunLoop for the whole lifetime of the monitor.
    /// No battery polling, view animation or NSSpellChecker feedback UI runs here.
    private func runTapLoop() {
        autoreleasepool {
            let mask = (1 << CGEventType.keyDown.rawValue)
                | (1 << CGEventType.flagsChanged.rawValue)
                | (1 << CGEventType.leftMouseDown.rawValue)
                | (1 << CGEventType.rightMouseDown.rawValue)
            let callback: CGEventTapCallBack = { _, type, event, pointer in
                let switcher = Unmanaged<LangSwitcher>.fromOpaque(pointer!).takeUnretainedValue()
                return switcher.handle(type: type, event: event)
            }
            guard let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else {
                tapStateLock.lock()
                tapCreationFailureCount += 1
                tapThread = nil
                tapStateLock.unlock()
                Log.lang.error("CGEventTap creation failed; Accessibility/Input Monitoring unavailable")
                return
            }

            let loop = CFRunLoopGetCurrent()
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            tapStateLock.lock()
            tap = eventTap
            runLoopSource = source
            tapRunLoop = loop
            let stopImmediately = tapShouldStop
            tapStateLock.unlock()

            if !stopImmediately {
                CFRunLoopAddSource(loop, source, .commonModes)
                CGEvent.tapEnable(tap: eventTap, enable: true)
                Log.lang.info("Keyboard event tap started on dedicated run loop")
                CFRunLoopRun()
                CFRunLoopRemoveSource(loop, source, .commonModes)
            }
            CGEvent.tapEnable(tap: eventTap, enable: false)
            resetAll()

            tapStateLock.lock()
            tap = nil
            runLoopSource = nil
            tapRunLoop = nil
            tapThread = nil
            tapShouldStop = false
            tapStateLock.unlock()
            Log.lang.info("Keyboard event tap stopped")
        }
    }

    private func stopTap() {
        stopAwaitingAccess()
        tapStateLock.lock()
        tapShouldStop = true
        let loop = tapRunLoop
        let eventTap = tap
        tapStateLock.unlock()
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false) }
        if let loop { CFRunLoopStop(loop) }
    }

    private func awaitAccessibility() {
        guard accessPollTimer == nil else { return }
        accessPollCount = 0
        accessPollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            accessPollCount += 1
            let wanted = withConfiguration {
                $0.mode != .off || $0.snippetsEnabled || $0.spellFixEnabled
            }
            if !wanted || accessPollCount > 90 { stopAwaitingAccess(); return }
            if isTrusted {
                accessPromptRequested = false
                startTap()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Notification.Name("BMLangRuntimeChanged"), object: nil)
                }
            }
        }
    }

    private func stopAwaitingAccess() {
        accessPollTimer?.invalidate()
        accessPollTimer = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if event.getIntegerValueField(.eventSourceUserData) == magic {
            return Unmanaged.passUnretained(event)
        }
        if IsSecureEventInputEnabled(), type == .keyDown || type == .flagsChanged {
            resetAll()
            return Unmanaged.passUnretained(event)
        }
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            tapStateLock.lock()
            tapRecoveryCount += 1
            let recoveries = tapRecoveryCount
            let eventTap = tap
            tapStateLock.unlock()
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            Log.lang.warning("Keyboard event tap recovered after disable; count=\(recoveries)")
        case .leftMouseDown, .rightMouseDown:
            resetAll()
        case .flagsChanged:
            handleFlags(event)
        case .keyDown:
            return handleKeyDown(event)
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func flag(for keycode: CGKeyCode) -> CGEventFlags {
        switch Int(keycode) {
        case kVK_RightCommand, kVK_Command: return .maskCommand
        case kVK_RightControl, kVK_Control: return .maskControl
        case kVK_RightShift, kVK_Shift: return .maskShift
        default: return .maskAlternate
        }
    }

    private func handleFlags(_ event: CGEvent) {
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let configuredHotkey = withConfiguration { $0.hotkeyKeycode }
        guard code == configuredHotkey else { return }
        let isDown = event.flags.contains(flag(for: code))
        if isDown {
            triggerDown = true
            otherKeySinceTrigger = false
        } else {
            if triggerDown && !otherKeySinceTrigger { convertOrUndo() }
            triggerDown = false
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        invalidatePendingSpellRequest()
        if triggerDown { otherKeySinceTrigger = true }
        let pass = Unmanaged.passUnretained(event)
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        if code == CGKeyCode(kVK_Delete) {
            userTypedSinceConversion = true
            lastConversion = nil
            if !currentKeys.isEmpty {
                currentKeys.removeLast()
                if !tokenBuffer.isEmpty { tokenBuffer.removeLast() }
            } else {
                previousWord = nil
                tokenBuffer.removeAll()
            }
            return pass
        }

        if code == CGKeyCode(kVK_Space) {
            return handleSpace(event: event, pass: pass)
        }

        if code == CGKeyCode(kVK_Return) || code == CGKeyCode(kVK_Tab) {
            if let replacement = snippetReplacement() {
                replace(count: tokenBuffer.count, with: replacement)
                if code != CGKeyCode(kVK_Return) { repost(code: code, shift: flags.contains(.maskShift)) }
                resetTypingState()
                return nil
            }
            resetTypingState()
            lastConversion = nil
            userTypedSinceConversion = true
            return pass
        }

        if isNavigationOrEditingKey(code) || !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            resetAll()
            return pass
        }

        guard let character = unicode(event), !character.isWhitespace else {
            resetAll()
            return pass
        }

        userTypedSinceConversion = true
        lastConversion = nil
        previousWord = nil
        if currentKeys.isEmpty { currentBundleID = frontmostBundleID }

        if tokenBuffer.count < 64 { tokenBuffer.append(character) }
        let key = LayoutTypedKey(
            code: UInt16(code),
            shift: flags.contains(.maskShift),
            caps: flags.contains(.maskAlphaShift),
            character: character
        )
        if character.isLetter || (!currentKeys.isEmpty && KeyboardLayoutEngine.isSafeTrailingPunctuation(character)) {
            if currentKeys.count < 64 { currentKeys.append(key) }
        } else {
            currentKeys.removeAll()
            currentBundleID = nil
        }
        return pass
    }

    private func handleSpace(
        event: CGEvent,
        pass: Unmanaged<CGEvent>
    ) -> Unmanaged<CGEvent>? {
        if let replacement = snippetReplacement() {
            replace(count: tokenBuffer.count, with: replacement + " ")
            resetTypingState()
            return nil
        }

        let config = withConfiguration { $0 }
        if config.mode == .auto,
           currentBundleID == frontmostBundleID,
           !KeyboardLanguageDetector.isAutoConversionDenied(in: frontmostBundleID),
           let prepared = preparedConversion(for: currentKeys, automatic: true) {
            perform(prepared, trailing: " ", feedback: true)
            resetTypingState(keepingLastConversion: true)
            return nil
        }

        // Layout correction has priority. Only if the word was already typed in
        // the right layout do we ask the existing Kelvin spell-fixer for a typo.
        if config.spellFixEnabled, !tokenBuffer.isEmpty {
            scheduleSpellCorrection(for: tokenBuffer, bundleID: currentBundleID)
        }

        if !currentKeys.isEmpty {
            previousWord = RememberedWord(keys: currentKeys, trailingSpaces: 1, bundleID: currentBundleID)
        } else if var previousWord {
            previousWord.trailingSpaces += 1
            self.previousWord = previousWord
        }
        currentKeys.removeAll()
        currentBundleID = nil
        tokenBuffer.removeAll()
        userTypedSinceConversion = true
        lastConversion = nil
        return pass
    }

    /// NSSpellChecker must never run inside the CGEventTap callback: a slow
    /// dictionary lookup makes macOS disable the tap. The original delimiter is
    /// allowed through, and the result is applied only if no newer physical key
    /// or focus-changing event has invalidated this request.
    private func scheduleSpellCorrection(for word: String, bundleID: String?) {
        spellRequestLock.lock()
        let generation = spellRequestGeneration
        spellRequestLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self, let correction = SpellFix.correction(for: word) else { return }
            self.spellRequestLock.lock()
            let isCurrent = self.spellRequestGeneration == generation
            self.spellRequestLock.unlock()
            guard isCurrent, self.frontmostBundleID == bundleID else { return }
            self.replace(count: word.count + 1, with: correction + " ")
            self.onFeedback?(.spell)
        }
    }

    private func invalidatePendingSpellRequest() {
        spellRequestLock.lock()
        spellRequestGeneration &+= 1
        spellRequestLock.unlock()
    }

    private func snippetReplacement() -> String? {
        let config = withConfiguration { $0 }
        guard config.snippetsEnabled, !tokenBuffer.isEmpty else { return nil }
        return config.snippets.first(where: { $0.trigger == tokenBuffer })?.text
    }

    private struct PreparedConversion {
        let conversion: KeyboardLayoutEngine.Conversion
        let deleteCount: Int
        let suffix: String
    }

    private func preparedConversion(for keys: [LayoutTypedKey], automatic: Bool) -> PreparedConversion? {
        guard !keys.isEmpty,
              let full = KeyboardLayoutEngine.conversion(for: keys) else { return nil }
        let split = KeyboardLayoutEngine.splitTrailingPunctuation(full.original)
        let coreKeys = split.suffix.isEmpty ? keys : Array(keys.prefix(split.coreLength))
        guard !coreKeys.isEmpty,
              let core = split.suffix.isEmpty ? full : KeyboardLayoutEngine.conversion(for: coreKeys) else {
            return nil
        }
        if automatic {
            let caps = coreKeys.contains(where: { $0.caps })
            guard KeyboardLanguageDetector.shouldConvert(
                typed: core.original,
                converted: core.converted,
                sourceLanguage: core.sourceLanguage,
                targetLanguage: core.targetLanguage,
                capsLock: caps,
                minimumLength: SettingsStore.langAutoMinLength
            ) else { return nil }
        }
        return PreparedConversion(conversion: core, deleteCount: keys.count, suffix: split.suffix)
    }

    private func convertOrUndo() {
        if !userTypedSinceConversion, let last = lastConversion {
            replace(count: last.converted.count, with: last.original, switchTo: last.sourceID)
            lastConversion = LastConversion(
                original: last.converted,
                converted: last.original,
                sourceID: last.targetID,
                targetID: last.sourceID
            )
            DispatchQueue.main.async { self.onFeedback?(.layout(toRU: false)) }
            return
        }

        if let prepared = preparedConversion(for: currentKeys, automatic: false) {
            perform(prepared, trailing: "", feedback: true)
            currentKeys.removeAll()
            tokenBuffer.removeAll()
            return
        }

        if let previousWord,
           previousWord.bundleID == frontmostBundleID,
           let prepared = preparedConversion(for: previousWord.keys, automatic: false) {
            let spaces = String(repeating: " ", count: previousWord.trailingSpaces)
            let adjusted = PreparedConversion(
                conversion: prepared.conversion,
                deleteCount: prepared.deleteCount + previousWord.trailingSpaces,
                suffix: prepared.suffix
            )
            perform(adjusted, trailing: spaces, feedback: true)
            self.previousWord = nil
        }
    }

    private func perform(_ prepared: PreparedConversion, trailing: String, feedback: Bool) {
        let original = prepared.conversion.original + prepared.suffix + trailing
        let converted = prepared.conversion.converted + prepared.suffix + trailing
        replace(count: prepared.deleteCount, with: converted, switchTo: prepared.conversion.targetID)
        lastConversion = LastConversion(
            original: original,
            converted: converted,
            sourceID: prepared.conversion.sourceID,
            targetID: prepared.conversion.targetID
        )
        userTypedSinceConversion = false
        if feedback {
            let toRU = String(prepared.conversion.targetLanguage.lowercased().prefix(2)) == "ru"
            DispatchQueue.main.async { self.onFeedback?(.layout(toRU: toRU)) }
        }
    }

    private func replace(count: Int, with text: String, switchTo layoutID: String? = nil) {
        injectionQueue.sync {
            for _ in 0..<count { repost(code: CGKeyCode(kVK_Delete), shift: false) }
            typeText(text)
            if let layoutID { KeyboardLayoutEngine.switchTo(id: layoutID) }
        }
    }

    private func typeText(_ text: String) {
        var utf16 = Array(text.utf16)
        guard !utf16.isEmpty else { return }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: postSource, virtualKey: 0, keyDown: down) else { continue }
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            event.setIntegerValueField(.eventSourceUserData, value: magic)
            event.post(tap: .cgSessionEventTap)
        }
    }

    private func repost(code: CGKeyCode, shift: Bool) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: postSource, virtualKey: code, keyDown: down) else { continue }
            event.flags = shift ? .maskShift : []
            event.setIntegerValueField(.eventSourceUserData, value: magic)
            event.post(tap: .cgSessionEventTap)
        }
    }

    private func unicode(_ event: CGEvent) -> Character? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: length).first
    }

    private func isNavigationOrEditingKey(_ code: CGKeyCode) -> Bool {
        let keys = [
            kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
            kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
            kVK_ForwardDelete, kVK_Escape,
        ]
        return keys.contains(Int(code))
    }

    private var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func resetTypingState(keepingLastConversion: Bool = false) {
        currentKeys.removeAll()
        currentBundleID = nil
        previousWord = nil
        tokenBuffer.removeAll()
        if !keepingLastConversion {
            lastConversion = nil
            userTypedSinceConversion = true
        }
    }

    private func resetAll() {
        invalidatePendingSpellRequest()
        resetTypingState()
        triggerDown = false
        otherKeySinceTrigger = false
    }
}
