import AppKit
import SwiftUI

/// SwiftUI-зеркало канонических токенов `Design`.
///
/// Kelvin смешивает AppKit (поповер, HUD, графики) и SwiftUI (новое окно настроек).
/// Значения здесь не дублируются: каждый цвет и размер берётся из `Design.swift`,
/// чтобы обе технологии оставались одним визуальным продуктом.
enum KelvinSwiftUITheme {
    static func isDark(_ scheme: ColorScheme) -> Bool {
        scheme == .dark
    }

    static func accent(_ scheme: ColorScheme) -> SwiftUI.Color {
        SwiftUI.Color(Design.Color.accent(isDark(scheme)))
    }

    static func accentMuted(_ scheme: ColorScheme) -> SwiftUI.Color {
        SwiftUI.Color(Design.Color.accentMuted(isDark(scheme)))
    }

    static func accentRim(_ scheme: ColorScheme) -> SwiftUI.Color {
        SwiftUI.Color(Design.Color.accentRim(isDark(scheme)))
    }

    static func surface(_ scheme: ColorScheme) -> SwiftUI.Color {
        SwiftUI.Color(Design.Color.surfaceFill(isDark(scheme)))
    }

    static func surfaceRim(_ scheme: ColorScheme) -> SwiftUI.Color {
        SwiftUI.Color(Design.Color.surfaceRim(isDark(scheme)))
    }

    static func control(_ scheme: ColorScheme) -> SwiftUI.Color {
        SwiftUI.Color(Design.Color.controlFill(isDark(scheme)))
    }

    static func hairline(_ scheme: ColorScheme, alpha: CGFloat = 0.08) -> SwiftUI.Color {
        SwiftUI.Color(Design.Color.hairline(isDark(scheme), alpha))
    }

    enum Spacing {
        static let compact = Design.Space.s1
        static let control = Design.Space.s2
        static let row = Design.Space.s3
        static let section = Design.Space.s5
        static let page = Design.Space.s7
        static let cardInset = Design.Space.s4
    }

    enum Radius {
        static let card = Design.Radius.group
        static let control = Design.Radius.control
        static let chip = Design.Radius.chip
    }

    enum Typography {
        static let pageTitle = SwiftUI.Font.system(size: 28, weight: .bold)
        static let brand = SwiftUI.Font.system(size: 20, weight: .bold)
        static let section = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let body = SwiftUI.Font.system(size: 13)
        static let detail = SwiftUI.Font.system(size: 11)
        static let navigation = SwiftUI.Font.system(size: 13, weight: .medium)
        static let eyebrow = SwiftUI.Font.system(size: 10, weight: .semibold)
    }
}
