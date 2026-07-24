import AppKit
import Carbon.HIToolbox

/// Глобальный хоткей вызова поповера поверх fullscreen-приложений.
/// Carbon RegisterEventHotKey: для ОДНОЙ комбинации НЕ требует Универсального доступа
/// (в отличие от CGEventTap в LangSwitcher) — минимум TCC-промптов.
final class GlobalHotkey {
    static let shared = GlobalHotkey()
    private init() {}

    /// Колбэк на нажатие — ставит AppDelegate (дёргает togglePopover на main).
    var onPressed: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x4B4C5648    // 'KLVH' (Kelvin Hotkey)
    private let hotKeyID: UInt32 = 1

    /// Перевод NSEvent.ModifierFlags → Carbon-маска (cmdKey/optionKey/controlKey/shiftKey).
    /// .deviceIndependentFlagsMask чтобы отсечь caps/numpad/function-биты.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }

    /// (Пере)регистрация из настроек. Идемпотентна: сперва снимает прежнюю регистрацию.
    /// enabled=false → просто снять. Мягкая деградация: status != noErr → лог, без краша.
    func apply(enabled: Bool, keyCode: Int, modifierFlags: NSEvent.ModifierFlags) {
        unregisterHotKey()                       // снять прежний ref (хендлер оставляем)
        guard enabled else { return }
        let mods = Self.carbonModifiers(from: modifierFlags)
        guard mods != 0 else {                   // ≥1 модификатор обязателен (двойная защита)
            NSLog("GlobalHotkey: no modifiers — skip register"); return
        }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: hotKeyID)
        let status = RegisterEventHotKey(UInt32(keyCode), mods, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            hotKeyRef = ref
        } else {
            NSLog("GlobalHotkey: RegisterEventHotKey failed status=\(status)")   // комбо занята/иное — не блокируем запуск
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let cb: EventHandlerUPP = { _, eventRef, userData in
            guard let userData = userData, let eventRef = eventRef else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(eventRef, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let me = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
            if hkID.signature == me.signature && hkID.id == me.hotKeyID {
                DispatchQueue.main.async { me.onPressed?() }   // на MAIN (Carbon колбэк уже на main, но явно)
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), cb, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
    }

    /// Полный teardown (applicationWillTerminate). Снять ref и хендлер без утечки.
    func teardown() {
        unregisterHotKey()
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
    }
}

// MARK: - Форматтер символов комбинации

enum HotkeyFormat {
    /// «⌃⌥⇧⌘B». Порядок модификаторов как в macOS HIG: ⌃⌥⇧⌘.
    static func string(keyCode: Int, mods: NSEvent.ModifierFlags) -> String? {
        var s = ""
        if mods.contains(.control) { s += "⌃" }
        if mods.contains(.option)  { s += "⌥" }
        if mods.contains(.shift)   { s += "⇧" }
        if mods.contains(.command) { s += "⌘" }
        guard let key = keyName(keyCode) else { return nil }
        return s + key
    }

    /// Имя клавиши по virtual keyCode. Спец-клавиши — таблицей, остальное — через UCKeyTranslate
    /// текущей раскладки; fallback — «key N».
    static func keyName(_ code: Int) -> String? {
        switch code {
        case kVK_Space:        return "Space"
        case kVK_Return:       return "↩"
        case kVK_Tab:          return "⇥"
        case kVK_Delete:       return "⌫"
        case kVK_ForwardDelete:return "⌦"
        case kVK_Escape:       return "⎋"
        case kVK_LeftArrow:    return "←"
        case kVK_RightArrow:   return "→"
        case kVK_UpArrow:      return "↑"
        case kVK_DownArrow:    return "↓"
        case kVK_ANSI_B:       return "B"
        default:               return Self.viaUCKeyTranslate(code)?.uppercased() ?? "key \(code)"
        }
    }

    private static func viaUCKeyTranslate(_ code: Int) -> String? {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadState: UInt32 = 0
        var len = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let r = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay),
                                  0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadState, 4, &len, &chars)
        }
        guard r == noErr, len > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: len)
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }
}

// MARK: - Рекордер аккорда

/// Рекордер аккорда для глобального хоткея. Клик → ждёт keyDown с ≥1 модификатором.
/// Esc — отмена записи. Только модификаторы без клавиши — невалидно (ждём дальше).
final class HotkeyRecorder: NSButton {
    var onCapture: ((Int, NSEvent.ModifierFlags) -> Void)?   // (keyCode, mods)
    private var recording = false { didSet { refreshTitle() } }
    private var keyCode: Int
    private var mods: NSEvent.ModifierFlags

    init(keyCode: Int, mods: NSEvent.ModifierFlags) {
        self.keyCode = keyCode; self.mods = mods
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self; action = #selector(begin)
        setAccessibilityRole(.button)
        refreshTitle()
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(keyCode: Int, mods: NSEvent.ModifierFlags) {
        self.keyCode = keyCode; self.mods = mods; refreshTitle()
    }

    @objc private func begin() {
        recording = true
        window?.makeFirstResponder(self)
    }

    private func refreshTitle() {
        if recording {
            title = L("Нажмите комбинацию…")
        } else {
            title = HotkeyFormat.string(keyCode: keyCode, mods: mods) ?? L("Не задано")
        }
        // VoiceOver: озвучить текущее значение/режим
        setAccessibilityValue(title)
        setAccessibilityLabel(L("Горячая клавиша поповера"))
    }

    override var acceptsFirstResponder: Bool { recording }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        // Esc — отмена записи (вернуть прежнее значение)
        if event.keyCode == UInt16(kVK_Escape) { recording = false; return }
        let m = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ≥1 модификатор обязателен; иначе игнор (остаёмся в записи)
        guard !m.intersection([.command, .option, .control, .shift]).isEmpty else {
            NSSound.beep(); return
        }
        keyCode = Int(event.keyCode); mods = m
        recording = false
        onCapture?(keyCode, mods)
    }

    override func flagsChanged(with event: NSEvent) {
        // только модификаторы без клавиши — НЕ фиксируем (ждём настоящую клавишу)
        if recording { super.flagsChanged(with: event) }
    }

    // потеря фокуса во время записи → отмена
    override func resignFirstResponder() -> Bool {
        if recording { recording = false }
        return super.resignFirstResponder()
    }
}
