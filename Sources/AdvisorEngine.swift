//
//  AdvisorEngine.swift
//  Kelvin
//
//  «Центр здоровья Mac» — детерминированный rule engine для рекомендаций.
//  Честность как закон продукта:
//   • Анализ ТОЛЬКО локальных данных, без сети и AI.
//   • Никаких ложных предупреждений при отсутствии датчиков.
//   • Действия выполняются ТОЛЬКО после явного нажатия пользователя.
//

import Foundation
import AppKit

/// Уровень серьёзности рекомендации. Сравнимы по возрастанию.
enum AdvisorSeverity: Int, Codable, Comparable {
    case info      // нейтральная информация
    case notice    // стоит обратить внимание
    case warning   // рекомендуется действие
    case critical  // требуется внимание

    static func < (lhs: AdvisorSeverity, rhs: AdvisorSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Категория рекомендации для иконки и группировки.
enum AdvisorCategory: String, Codable {
    case battery
    case thermal
    case performance
    case memory
    case storage
    case security
    case network
    case maintenance

    var icon: String {
        switch self {
        case .battery: return "battery.75"
        case .thermal: return "thermometer.medium"
        case .performance: return "gauge.medium"
        case .memory: return "memorychip"
        case .storage: return "internaldrive"
        case .security: return "lock.shield"
        case .network: return "network"
        case .maintenance: return "wrench.and.screwdriver"
        }
    }

    var label: String {
        switch self {
        case .battery: return L("Батарея")
        case .thermal: return L("Температура")
        case .performance: return L("Производительность")
        case .memory: return L("Память")
        case .storage: return L("Диск")
        case .security: return L("Безопасность")
        case .network: return L("Сеть")
        case .maintenance: return L("Обслуживание")
        }
    }
}

/// Доступные действия для рекомендации. Enum безопаснее строк.
enum AdvisorAction: Equatable {
    case enableChargeLimit(percent: Int)
    case enableHeatProtection
    case activateFanProfile(String)
    case openSettings(section: String)
    case openPopoverSection(String)
    case revealApplication(String)

    static func == (lhs: AdvisorAction, rhs: AdvisorAction) -> Bool {
        switch (lhs, rhs) {
        case (.enableChargeLimit(let a), .enableChargeLimit(let b)): return a == b
        case (.enableHeatProtection, .enableHeatProtection): return true
        case (.activateFanProfile(let a), .activateFanProfile(let b)): return a == b
        case (.openSettings(let a), .openSettings(let b)): return a == b
        case (.openPopoverSection(let a), .openPopoverSection(let b)): return a == b
        case (.revealApplication(let a), .revealApplication(let b)): return a == b
        default: return false
        }
    }
}

/// Находка (recommendation) — единица рекомендации.
struct AdvisorFinding: Identifiable, Equatable {
    let id: String
    let category: AdvisorCategory
    let severity: AdvisorSeverity
    let title: String
    let explanation: String
    let metric: String?          // значение показателя если полезно
    let action: AdvisorAction?
    let detailsDestination: String?  // куда открыть подробности (имя секции настроек)

    /// ID для dismissal/cooldown. Стабильный по смыслу находки.
    var dismissKey: String { id }
}

/// Агрегированный снимок данных для Advisor. Изолирует rule engine от UI и источников.
struct AdvisorSnapshot {
    // Батарея
    let batteryPresent: Bool
    let batteryChargePercent: Int?
    let batteryHealthPercent: Double?
    let batteryCycles: Int?
    let batteryRatedCycles: Int?
    let batteryTemperature: Double?
    let batteryCharging: Bool
    let batteryExternalConnected: Bool

    // Заряд (из ChargeControl/SettingsStore)
    let chargeLimitEnabled: Bool       // лимит < 100% активен
    let chargeLimitValue: Int          // текущий лимит %
    let sailModeActive: Bool           // парусный режим
    let heatProtectionActive: Bool     // тепловая защита

    // Температуры
    let cpuTemperature: Double?
    let gpuTemperature: Double?
    let cpuTemperatureKeys: [String]?  // какие ключи использованы (для доверия)

    // Производительность
    let cpuLoad: Double                // 0..1
    let thermalPressure: Int?          // если доступен аналог

    // Память
    let memoryPressure: MemoryInfo.Pressure
    let memoryTotalRAM: UInt64
    let memorySwapUsed: UInt64

    // Диск
    let diskFreeBytes: Int64?
    let diskTotalBytes: Int64?

    // Обслуживание
    let uptime: TimeInterval
    let recentCrashesCount: Int        // за последние 7 дней
    let crashSummary: Maintenance.CrashSummary?

    // Helpers
    let fanHelperInstalled: Bool
    let chargeHelperInstalled: Bool

    /// Пустой снимок с безопасными дефолтами (для тестов и отсутствия данных).
    static let empty: AdvisorSnapshot = AdvisorSnapshot(
        batteryPresent: false,
        batteryChargePercent: nil,
        batteryHealthPercent: nil,
        batteryCycles: nil,
        batteryRatedCycles: nil,
        batteryTemperature: nil,
        batteryCharging: false,
        batteryExternalConnected: false,
        chargeLimitEnabled: false,
        chargeLimitValue: 100,
        sailModeActive: false,
        heatProtectionActive: false,
        cpuTemperature: nil,
        gpuTemperature: nil,
        cpuTemperatureKeys: nil,
        cpuLoad: 0,
        thermalPressure: nil,
        memoryPressure: .unknown,
        memoryTotalRAM: 0,
        memorySwapUsed: 0,
        diskFreeBytes: nil,
        diskTotalBytes: nil,
        uptime: 0,
        recentCrashesCount: 0,
        crashSummary: nil,
        fanHelperInstalled: false,
        chargeHelperInstalled: false
    )
}

/// Результат анализа: список находок + метаданные.
struct AdvisorResult {
    let findings: [AdvisorFinding]
    let analyzedAt: Date
    let snapshotVersion: Int           // для инвалидации кэша

    /// Наиболее серьёзный уровень среди находок.
    var maxSeverity: AdvisorSeverity {
        findings.map { $0.severity }.max() ?? .info
    }

    /// Статус для UI.
    var statusText: String {
        switch maxSeverity {
        case .critical: return L("Требуется внимание")
        case .warning: return L("Есть рекомендации")
        case .notice: return L("Есть рекомендации")
        case .info: return L("Всё хорошо")
        }
    }

    /// Количество находок по уровням.
    var countsBySeverity: [AdvisorSeverity: Int] {
        Dictionary(grouping: findings, by: { $0.severity })
            .mapValues { $0.count }
    }
}

/// Хранилище скрытых рекомендаций (dismissed) с cooldown.
struct AdvisorDismissalStore {
    private struct Record: Codable {
        let findingID: String
        let dismissedAt: Date
        let versionSignature: String?   // сигнатура данных при dismissal
    }

    private let userDefaultsKey = "advisor.dismissed"
    private var records: [String: Record] = [:]  // keyed by findingID

    init() {
        load()
    }

    private mutating func load() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([Record].self, from: data) else {
            records = [:]
            return
        }
        records = Dictionary(uniqueKeysWithValues: decoded.map { ($0.findingID, $0) })
    }

    private func save() {
        let array = Array(records.values)
        if let encoded = try? JSONEncoder().encode(array) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }

    /// Скрыть рекомендацию.
    mutating func dismiss(_ findingID: String, version: String? = nil) {
        records[findingID] = Record(findingID: findingID, dismissedAt: Date(), versionSignature: version)
        save()
    }

    /// Проверить, скрыта ли рекомендация.
    /// - Parameters:
    ///   - findingID: ID находки
    ///   - cooldownSeconds: период охлаждения (по умолчанию 7 дней)
    ///   - criticalOverride: если true, critical находки возвращаются раньше
    /// - Returns: true если скрыта (не показывать), false если можно показать
    func isDismissed(_ findingID: String, cooldownSeconds: TimeInterval = 7 * 24 * 3600, criticalOverride: Bool = false) -> Bool {
        guard let record = records[findingID] else { return false }

        let elapsed = Date().timeIntervalSince(record.dismissedAt)
        if elapsed >= cooldownSeconds { return false }  // cooldown истёк

        // Critical можно вернуть раньше при значительном ухудшении
        // (caller должен передать обновлённую версию если данные изменились)
        if criticalOverride {
            // Пока просто разрешаем — caller сам решит по контексту
            return false
        }

        return true
    }

    /// Вернуть скрытую рекомендацию (undo).
    mutating func restore(_ findingID: String) {
        records.removeValue(forKey: findingID)
        save()
    }

    /// Очистить все скрытые.
    mutating func clearAll() {
        records.removeAll()
        save()
    }
}

/// Главный движок рекомендаций.
///
/// Принципы:
///  • Чистая функция: snapshot → findings, без побочных эффектов.
///  • Детерминировано: одинаковый вход → одинаковый выход.
///  • Безопасно: отсутствие датчиков ≠ предупреждение.
///  • Без блокировок main thread: вызывающий решает где выполнять.
final class AdvisorEngine {
    static let shared = AdvisorEngine()

    private init() {}

    /// Версия формата snapshot (для инвалидации при изменениях).
    private let snapshotVersion = 1

    /// Проанализировать снимок и вернуть рекомендации.
    /// - Parameter snapshot: агрегированные данные
    /// - Returns: результат анализа
    func analyze(_ snapshot: AdvisorSnapshot) -> AdvisorResult {
        var findings: [AdvisorFinding] = []

        // 1. Батарея нагревается
        if let f = checkBatteryOverheat(snapshot) { findings.append(f) }

        // 2. Сниженное здоровье батареи
        if let f = checkBatteryHealthDegradation(snapshot) { findings.append(f) }

        // 3. Постоянная зарядка до 100%
        if let f = checkAlwaysPluggedIn(snapshot) { findings.append(f) }

        // 4. Высокая температура CPU/GPU
        if let f = checkHighCPUTemperature(snapshot) { findings.append(f) }
        if let f = checkHighGPUTemperature(snapshot) { findings.append(f) }

        // 5. Нехватка свободного места
        if let f = checkLowDiskSpace(snapshot) { findings.append(f) }

        // 6. Memory pressure
        if let f = checkMemoryPressure(snapshot) { findings.append(f) }

        // 7. Недавние повторяющиеся сбои
        if let f = checkRecentCrashes(snapshot) { findings.append(f) }

        // Дедупликация: убираем одинаковые по ID
        let unique = findings.uniqued(by: { $0.id })

        // Сортировка по серьёзности (critical first)
        let sorted = unique.sorted { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            return a.title < b.title  // алфавит как tie-breaker
        }

        // Ограничение количества (не более 10 в MVP)
        let limited = Array(sorted.prefix(10))

        return AdvisorResult(
            findings: limited,
            analyzedAt: Date(),
            snapshotVersion: snapshotVersion
        )
    }

    // MARK: - Правила

    /// Правило 1: Батарея нагревается.
    /// Порог: стабильно выше 45°C (ускоряет износ Li-ion).
    /// Не срабатывает на одиночный скачок — caller должен передавать сглаженное значение.
    private func checkBatteryOverheat(_ s: AdvisorSnapshot) -> AdvisorFinding? {
        guard s.batteryPresent else { return nil }
        guard let temp = s.batteryTemperature else { return nil }

        // Порог 45°C — консервативно, выше комнатной но ниже критической
        guard temp >= 45.0 else { return nil }

        let severity: AdvisorSeverity = temp >= 50 ? .warning : .notice

        var action: AdvisorAction? = nil
        if !s.heatProtectionActive && s.chargeHelperInstalled {
            action = .enableHeatProtection
        } else if s.batteryChargePercent ?? 100 >= 80, !s.chargeLimitEnabled, s.chargeHelperInstalled {
            action = .enableChargeLimit(percent: 80)
        }

        return AdvisorFinding(
            id: "battery.overheat.\(Int(temp))",
            category: .battery,
            severity: severity,
            title: L("Батарея нагревается"),
            explanation: String(format: L("Температура батареи %.0f°C может ускорять износ."), temp),
            metric: String(format: "%.0f°C", temp),
            action: action,
            detailsDestination: "power"
        )
    }

    /// Правило 2: Сниженное здоровье батареи.
    /// 80–89%: заметный износ (notice)
    /// <80%: значительный износ (warning)
    /// Не показывать critical только из-за возраста.
    private func checkBatteryHealthDegradation(_ s: AdvisorSnapshot) -> AdvisorFinding? {
        guard s.batteryPresent else { return nil }
        guard let health = s.batteryHealthPercent else { return nil }

        // Не показывать если health > 89% (нормальный износ)
        guard health < 89.0 else { return nil }

        let severity: AdvisorSeverity = health < 80.0 ? .warning : .notice

        // Дополнительная информация о циклах если доступна
        var metric: String? = String(format: "%.0f%%", health)
        if let cycles = s.batteryCycles, let rated = s.batteryRatedCycles {
            metric = String(format: "%.0f%% · %d/%d %@", health, cycles, rated, L("циклов"))
        }

        return AdvisorFinding(
            id: "battery.health.\(Int(health))",
            category: .battery,
            severity: severity,
            title: health < 80.0 ? L("Значительный износ батареи") : L("Заметный износ батареи"),
            explanation: health < 80.0
                ? L("Ёмкость батареи снижена. Это нормально после длительной эксплуатации.")
                : L("Батарея потеряла часть ёмкости. Это естественный процесс."),
            metric: metric,
            action: nil,  // Нет безопасного действия, только информация
            detailsDestination: "power"
        )
    }

    /// Правило 3: Постоянная зарядка до 100%.
    /// Если Mac долго на питании и около 100% — предложить лимит 80%.
    /// Не показывать если лимит уже включён.
    private func checkAlwaysPluggedIn(_ s: AdvisorSnapshot) -> AdvisorFinding? {
        guard s.batteryPresent else { return nil }
        guard s.batteryExternalConnected else { return nil }
        guard let charge = s.batteryChargePercent else { return nil }

        // Уже защищён?
        if s.chargeLimitEnabled || s.sailModeActive || s.heatProtectionActive {
            return nil
        }

        // Близко к 100% и на питании
        guard charge >= 95 else { return nil }

        return AdvisorFinding(
            id: "battery.always_plugged",
            category: .battery,
            severity: .notice,
            title: L("Постоянная зарядка"),
            explanation: L("Mac долго подключён к сети на 100%. Лимит 80% продлит жизнь батареи."),
            metric: "\(charge)%",
            action: s.chargeHelperInstalled ? .enableChargeLimit(percent: 80) : nil,
            detailsDestination: "power"
        )
    }

    /// Правило 4: Высокая температура CPU.
    /// Только при достоверном sensor mapping.
    /// Порог зависит от модели — используем Design.sensorLevel.
    private func checkHighCPUTemperature(_ s: AdvisorSnapshot) -> AdvisorFinding? {
        guard let temp = s.cpuTemperature else { return nil }
        guard let keys = s.cpuTemperatureKeys, !keys.isEmpty else { return nil }

        // Проверка порога через Design.sensorLevel (per-sensor threshold)
        let level = Design.sensorLevel(id: "cpu", temp)
        guard level == .crit || level == .warn else { return nil }

        let severity: AdvisorSeverity = level == .crit ? .warning : .notice

        var action: AdvisorAction? = nil
        if s.fanHelperInstalled {
            action = .activateFanProfile("cool")
        }

        return AdvisorFinding(
            id: "thermal.cpu.high.\(Int(temp))",
            category: .thermal,
            severity: severity,
            title: L("Высокая температура CPU"),
            explanation: String(format: L("CPU нагрелся до %.0f°C. Проверьте нагрузку и вентиляцию."), temp),
            metric: String(format: "%.0f°C", temp),
            action: action,
            detailsDestination: nil  // Откроет раздел температур в popover
        )
    }

    /// Правило 4b: Высокая температура GPU.
    private func checkHighGPUTemperature(_ s: AdvisorSnapshot) -> AdvisorFinding? {
        guard let temp = s.gpuTemperature else { return nil }

        // Для GPU пока консервативный порог 85°C
        guard temp >= 85.0 else { return nil }

        let severity: AdvisorSeverity = temp >= 95.0 ? .warning : .notice

        var action: AdvisorAction? = nil
        if s.fanHelperInstalled {
            action = .activateFanProfile("cool")
        }

        return AdvisorFinding(
            id: "thermal.gpu.high.\(Int(temp))",
            category: .thermal,
            severity: severity,
            title: L("Высокая температура GPU"),
            explanation: String(format: L("GPU нагрелся до %.0f°C. Проверьте нагрузку и вентиляцию."), temp),
            metric: String(format: "%.0f°C", temp),
            action: action,
            detailsDestination: nil
        )
    }

    /// Правило 5: Нехватка свободного места.
    /// Notice при <15%, warning при <5% или <10GB.
    private func checkLowDiskSpace(_ s: AdvisorSnapshot) -> AdvisorFinding? {
        guard let free = s.diskFreeBytes, let total = s.diskTotalBytes, total > 0 else { return nil }

        let freePercent = Double(free) / Double(total) * 100.0
        let freeGB = Double(free) / 1_000_000_000.0

        let severity: AdvisorSeverity
        if freePercent < 5.0 || freeGB < 10.0 {
            severity = .warning
        } else if freePercent < 15.0 {
            severity = .notice
        } else {
            return nil
        }

        return AdvisorFinding(
            id: "storage.low.\(Int(freeGB))",
            category: .storage,
            severity: severity,
            title: L("Мало места на диске"),
            explanation: String(format: L("Свободно %.1f ГБ (%.0f%%). Освободите место для стабильной работы."), freeGB, freePercent),
            metric: String(format: "%.1f ГБ", freeGB),
            action: .openSettings(section: "maintenance"),
            detailsDestination: "maintenance"
        )
    }

    /// Правило 6: Memory pressure.
    /// Не предупреждать только из-за большого объёма занятой RAM.
    /// Использовать memory pressure или swap.
    private func checkMemoryPressure(_ s: AdvisorSnapshot) -> AdvisorFinding? {
        guard s.memoryPressure != .normal && s.memoryPressure != .unknown else { return nil }

        let severity: AdvisorSeverity
        switch s.memoryPressure {
        case .critical: severity = .warning
        case .warning: severity = .notice
        default: return nil
        }

        let swapMB = Double(s.memorySwapUsed) / 1_000_000.0
        var metric: String? = s.memoryPressure == .critical ? L("критическое") : L("повышенное")
        if swapMB > 100 {
            metric = String(format: "%@ · swap %.0f МБ", metric!, swapMB)
        }

        return AdvisorFinding(
            id: "memory.pressure.\(s.memoryPressure.rawValue)",
            category: .memory,
            severity: severity,
            title: L("Давление памяти"),
            explanation: L("Система испытывает нехватку памяти. Закройте лишние приложения."),
            metric: metric,
            action: nil,
            detailsDestination: nil
        )
    }

    /// Правило 7: Недавние повторяющиеся сбои.
    /// Несколько крашей Kelvin за 7 дней → предложить диагностику.
    private func checkRecentCrashes(_ s: AdvisorSnapshot) -> AdvisorFinding? {
        guard s.recentCrashesCount >= 2 else { return nil }

        let severity: AdvisorSeverity = s.recentCrashesCount >= 5 ? .warning : .notice

        return AdvisorFinding(
            id: "maintenance.crashes.\(s.recentCrashesCount)",
            category: .maintenance,
            severity: severity,
            title: L("Повторяющиеся сбои"),
            explanation: String(format: L("Зафиксировано %d сбоев за неделю. Рекомендуется отправить отчёт."), s.recentCrashesCount),
            metric: "\(s.recentCrashesCount) " + (s.recentCrashesCount == 1 ? L("сбой") : (s.recentCrashesCount < 5 ? L("сбоя") : L("сбоев"))),
            action: .openSettings(section: "about"),  // раздел About → диагностика
            detailsDestination: "about"
        )
    }
}

// MARK: - Helper extensions

extension Array where Element: Hashable {
    /// Уникализация по ключу.
    func uniqued(by key: (Element) -> String) -> [Element] {
        var seen: Set<String> = []
        return filter { element in
            let k = key(element)
            if seen.contains(k) { return false }
            seen.insert(k)
            return true
        }
    }
}
