import Foundation
import AppKit
import Carbon.HIToolbox

/// Наблюдаемый статус работы автоязыка в runtime.
/// Потокобезопасен для чтения из UI (main) и записи из background tap thread.
enum LangRuntimeStatus: Equatable {
    /// Автоязык выключен пользователем
    case off
    /// Нужна лицензия Pro (trial истёк или не активирован)
    case unavailableByLicense
    /// Отсутствует разрешение Accessibility
    case accessibilityDenied
    /// Не удалось создать/запустить event tap для мониторинга ввода
    case inputMonitoringUnavailable
    /// Не найдена пара раскладок для конвертации (RU ↔ UK или другая целевая)
    case missingLayouts
    /// Event tap в процессе запуска
    case tapStarting
    /// Автоязык активен и работает
    case active
    /// Event tap создан, но не слушает (paused/blocked)
    case tapFailed
    
    var localizedDescription: String {
        switch self {
        case .off:
            return L("Выключено")
        case .unavailableByLicense:
            return L("Недоступно по лицензии")
        case .accessibilityDenied:
            return L("Нужен Универсальный доступ")
        case .inputMonitoringUnavailable:
            return L("Мониторинг ввода недоступен")
        case .missingLayouts:
            return L("Не найдена пара раскладок")
        case .tapStarting:
            return L("Запуск обработчика…")
        case .active:
            return L("Работает")
        case .tapFailed:
            return L("Не удалось запустить обработчик")
        }
    }
    
    var isWorking: Bool {
        if case .active = self { return true }
        return false
    }
}

/// Наблюдаемое состояние автоязыка — потокобезопасный snapshot для UI.
struct LangSwitcherStatus {
    /// Сохранённый режим (off/hotkey/auto)
    let savedMode: LangSwitcher.Mode
    /// Фактический runtime status
    let runtimeStatus: LangRuntimeStatus
    /// Доступность Pro/trial
    let hasProAccess: Bool
    /// Разрешение Accessibility
    let accessibilityTrusted: Bool
    /// Event tap активен
    let tapActive: Bool
    /// Количество восстановлений tap
    let recoveries: Int
    /// Количество неудач создания tap
    let creationFailures: Int
    /// Текущий input source ID
    let currentSourceID: String?
    /// Список доступных раскладок (локализованное имя + ID)
    let availableLayouts: [(name: String, id: String, language: String?)]
    /// Найденные пары source/target для конвертации
    let conversionPairs: [(from: String, to: String)]
    
    init(
        savedMode: LangSwitcher.Mode,
        runtimeStatus: LangRuntimeStatus,
        hasProAccess: Bool,
        accessibilityTrusted: Bool,
        tapActive: Bool,
        recoveries: Int,
        creationFailures: Int,
        currentSourceID: String?,
        availableLayouts: [(name: String, id: String, language: String?)],
        conversionPairs: [(from: String, to: String)]
    ) {
        self.savedMode = savedMode
        self.runtimeStatus = runtimeStatus
        self.hasProAccess = hasProAccess
        self.accessibilityTrusted = accessibilityTrusted
        self.tapActive = tapActive
        self.recoveries = recoveries
        self.creationFailures = creationFailures
        self.currentSourceID = currentSourceID
        self.availableLayouts = availableLayouts
        self.conversionPairs = conversionPairs
    }
    
    /// Сформировать текущий статус из LangSwitcher и Licensing.
    static func current() -> LangSwitcherStatus {
        let switcher = LangSwitcher.shared
        let savedMode = switcher.mode
        let wanted = savedMode != .off
            || SettingsStore.snippetsEnabled
            || SettingsStore.spellFixEnabled
        
        // Лицензия
        let hasProAccess = Licensing.shared.isPro
        
        // Accessibility
        let accessibilityTrusted = switcher.isTrusted
        
        // Tap state
        let diagnostics = switcher.runtimeDiagnostics
        let tapActive = diagnostics.tapActive
        let recoveries = diagnostics.recoveries
        let creationFailures = diagnostics.creationFailures
        
        // Runtime status determination
        let runtimeStatus: LangRuntimeStatus
        if !wanted {
            runtimeStatus = .off
        } else if !hasProAccess {
            runtimeStatus = .unavailableByLicense
        } else if !accessibilityTrusted {
            runtimeStatus = .accessibilityDenied
        } else if !tapActive && creationFailures > 0 {
            runtimeStatus = .tapFailed
        } else if !tapActive {
            runtimeStatus = .inputMonitoringUnavailable
        } else {
            // Tap активен, проверим наличие раскладок
            let layouts = InputSources.availableKeyboardLayouts()
            let hasRu = layouts.contains { $0.lowercased().contains("russian") || $0.lowercased().contains("русская") }
            let hasUk = layouts.contains { $0.lowercased().contains("ukrainian") || $0.lowercased().contains("українська") }
            
            if !hasRu && !hasUk {
                runtimeStatus = .missingLayouts
            } else if tapActive {
                runtimeStatus = .active
            } else {
                runtimeStatus = .tapStarting
            }
        }
        
        // Current source
        let currentSourceID = InputSources.currentInputSourceID()
        
        // Available layouts with IDs
        let availableLayouts = InputSources.allInputSources().compactMap { source -> (name: String, id: String, language: String?)? in
            guard let id = source[kTISPropertyInputSourceID as String] as? String,
                  let name = source[kTISPropertyLocalizedName as String] as? String else {
                return nil
            }
            let language = source["language"] as? String
            return (name: name, id: id, language: language)
        }
        
        // Conversion pairs (из LayoutMap)
        let conversionPairs = LayoutMap.knownPairs.map { (from: $0.key, to: $0.value) }
        
        return LangSwitcherStatus(
            savedMode: savedMode,
            runtimeStatus: runtimeStatus,
            hasProAccess: hasProAccess,
            accessibilityTrusted: accessibilityTrusted,
            tapActive: tapActive,
            recoveries: recoveries,
            creationFailures: creationFailures,
            currentSourceID: currentSourceID,
            availableLayouts: availableLayouts,
            conversionPairs: conversionPairs
        )
    }
}
