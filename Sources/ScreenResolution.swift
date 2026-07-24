import CoreGraphics
import Foundation

/// Смена разрешения главного дисплея (CoreGraphics, без root).
/// Список «как System Settings»: уникальные точки-разрешения, предпочитая HiDPI (Retina).
enum ScreenResolution {
    struct Mode {
        let cg: CGDisplayMode
        let w: Int            // логические (точки)
        let h: Int
        let hidpi: Bool
        var label: String { "\(w) × \(h)" + (hidpi ? "  ⟐" : "") }
    }

    static var displayID: CGDirectDisplayID { CGMainDisplayID() }

    static func current() -> (w: Int, h: Int)? {
        guard let m = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return (m.width, m.height)
    }

    static func available() -> [Mode] {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true as CFBoolean] as CFDictionary
        guard let arr = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode] else { return [] }
        var best: [String: Mode] = [:]
        for m in arr where m.isUsableForDesktopGUI() {
            let hidpi = m.pixelWidth > m.width
            let key = "\(m.width)x\(m.height)"
            let mode = Mode(cg: m, w: m.width, h: m.height, hidpi: hidpi)
            if let ex = best[key] {
                if hidpi && !ex.hidpi { best[key] = mode }      // предпочитаем Retina-вариант
            } else {
                best[key] = mode
            }
        }
        // только разумные размеры; от большего к меньшему
        return best.values
            .filter { $0.w >= 1024 && $0.h >= 640 }
            .sorted { $0.w == $1.w ? $0.h > $1.h : $0.w > $1.w }
    }

    @discardableResult
    static func apply(_ mode: Mode) -> Bool {
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return false }
        CGConfigureDisplayWithDisplayMode(cfg, displayID, mode.cg, nil)
        return CGCompleteDisplayConfiguration(cfg, .permanently) == .success
    }
}
