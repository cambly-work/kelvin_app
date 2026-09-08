import AppKit

/// Уважение системной настройки «Уменьшить движение» (Универсальный доступ → Дисплей).
/// При включении гасим бесконечные/декоративные анимации, оставляя конечные состояния.
enum Motion {
    static var reduced: Bool {
        // Регрессионный снимок обязан фиксировать конечное состояние, а не случайный кадр
        // count/fade-анимации. В обычном приложении по-прежнему решает настройка macOS.
        ProcessInfo.processInfo.environment["BM_SNAP"] != nil
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
