import Foundation
import AppKit
import Carbon.HIToolbox

/// Установленная раскладка клавиатуры.
struct KbLayout {
    let id: String
    let name: String
    var enabled: Bool
    let src: TISInputSource
}

/// Список и управление раскладками клавиатуры (через TIS, без root).
enum InputSources {
    static func installed() -> [KbLayout] {
        guard let list = TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource] else { return [] }
        var out: [KbLayout] = []
        var seen = Set<String>()
        for s in list {
            guard cat(s) == (kTISCategoryKeyboardInputSource as String) else { continue }
            let type = str(s, kTISPropertyInputSourceType)
            guard type == (kTISTypeKeyboardLayout as String) || type == (kTISTypeKeyboardInputMode as String) else { continue }
            guard let id = str(s, kTISPropertyInputSourceID),
                  let name = str(s, kTISPropertyLocalizedName), !seen.contains(id) else { continue }
            seen.insert(id)
            let enabled = bool(s, kTISPropertyInputSourceIsEnabled) ?? false
            out.append(KbLayout(id: id, name: name, enabled: enabled, src: s))
        }
        return out.sorted { ($0.enabled ? 0 : 1, $0.name) < ($1.enabled ? 0 : 1, $1.name) }
    }

    @discardableResult
    static func setEnabled(_ l: KbLayout, _ on: Bool) -> Bool {
        if on {
            return TISEnableInputSource(l.src) == noErr
        } else {
            // не выключаем последнюю активную раскладку
            if installed().filter({ $0.enabled }).count <= 1 { return false }
            return TISDisableInputSource(l.src) == noErr
        }
    }

    static func openSystemKeyboardSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(u)
        }
    }

    // MARK: TIS-свойства
    private static func cat(_ s: TISInputSource) -> String? { str(s, kTISPropertyInputSourceCategory) }
    private static func str(_ s: TISInputSource, _ key: CFString) -> String? {
        guard let p = TISGetInputSourceProperty(s, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }
    private static func bool(_ s: TISInputSource, _ key: CFString) -> Bool? {
        guard let p = TISGetInputSourceProperty(s, key) else { return nil }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
    }
}
