import Foundation
import os

/// Единая точка логирования: unified log (видно в Console.app / `log stream` по подсистеме = bundle id).
/// LSUIElement-агент пишет `print` в никуда — для прода нужен структурный лог и причина краша.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.trykelvin.kelvin"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let helper = Logger(subsystem: subsystem, category: "helper")
    static let lang = Logger(subsystem: subsystem, category: "lang")

    /// Обработчик необработанных Obj-C исключений — имя/причина/стек в unified log (иначе при краше пусто).
    static func installCrashHandlers() {
        NSSetUncaughtExceptionHandler { ex in
            let stack = ex.callStackSymbols.joined(separator: "\n")
            Log.app.fault("Необработанное исключение \(ex.name.rawValue, privacy: .public): \(ex.reason ?? "—", privacy: .public)\n\(stack, privacy: .public)")
        }
    }
}
