import AppKit

/// Уважение системной настройки «Уменьшить движение» (Универсальный доступ → Дисплей).
/// При включении гасим бесконечные/декоративные анимации, оставляя конечные состояния.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
