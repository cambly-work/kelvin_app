import Foundation
import AppKit

/// Единый путь применения настроек заряда — общий для окна настроек и поповера.
///
/// Инкапсулирует: (1) чтение текущего состояния (лимит/режим/парусные пороги/top-up);
/// (2) применение изменений (лимит, режим, парусные границы, top-up). Каждое изменение
/// Pro-гейтится через канонический `SettingsCoordinator.requirePro(.charge)`
/// и пишет полный charge-limit.json (тот же JSON, что и старый writeChargeConfigJSON).
///
/// Демон BCLM НЕ трогаем напрямую — пишем только конфиг, демон применяет его сам (честность).
/// Доступен из поповера (PopoverController) и из настроек: оба маршрутят через один путь.
enum ChargeControl {
    static let helperSetupNeeded = Notification.Name("BMHelperSetupNeeded")
    private static var helperSetupNoticePosted = false

    // MARK: - Чтение состояния (read-only снимок текущих настроек заряда)

    /// Текущий лимит заряда в % (100 = без ограничений).
    static var limit: Int { SettingsStore.chargeLimit }
    /// Режим заряда: "limit" | "sail".
    static var mode: String { SettingsStore.chargeMode }
    /// Верхний порог парусной полосы (заряжаем до).
    static var sailUpper: Int { SettingsStore.sailUpper }
    /// Нижний порог парусной полосы (держим лимит).
    static var sailLower: Int { SettingsStore.sailLower }
    /// epoch-секунды конца временного top-up (0 = выкл).
    static var topUpUntil: Double { SettingsStore.topUpUntil }
    /// Активен ли top-up прямо сейчас.
    static var isTopUpActive: Bool { SettingsStore.topUpUntil > Date().timeIntervalSince1970 }
    /// Плановый дозаряд «полный к времени»: вкл, минута цели, фора (минуты).
    static var alarmOn: Bool { SettingsStore.chargeAlarmOn }
    static var alarmTargetMin: Int { SettingsStore.chargeAlarmTargetMin }
    static var alarmLeadMin: Int { SettingsStore.chargeAlarmLeadMin }
    /// Любой активный режим заряда требует демона (для применения BCLM).
    /// Зеркало приватного chargeActive в SettingsWindowController.
    static var isActive: Bool {
        SettingsStore.chargeMode == "sail"
            || SettingsStore.heatProtect
            || SettingsStore.chargeLimit < 100
            || isTopUpActive
            || SettingsStore.chargeAlarmOn
    }
    static var systemControlReady: Bool { HelperInstall.fandInstalled }
    static var requiresSystemControl: Bool { isActive && !HelperInstall.fandInstalled }

    // MARK: - Pro-гейт

    /// Канонический Pro-гейт ($19-апселл). true — доступно; false — показан апселл,
    /// вызывающий должен откатить UI. Тот же путь, что используют хендлеры настроек.
    @discardableResult
    static func requireProGate() -> Bool {
        SettingsCoordinator.requirePro(.charge)
    }

    // MARK: - Применение изменений
    //
    // Каждый метод возвращает Bool: true — изменение применено и записано;
    // false — Pro-гейт сорвался (показан апселл), состояние НЕ изменено, вызывающий
    // должен вернуть UI в прежнее положение. Поведение байт-в-байт совпадает со
    // старыми @objc-хендлерами Settings (которые теперь — тонкие обёртки над этим).

    /// Установить лимит заряда (%). pct<100 ⇒ Pro + установка демона.
    /// Зеркало chargeLimitChanged: при отказе Pro лимит остаётся/возвращается к 100.
    @discardableResult
    static func setLimit(_ pct: Int) -> Bool {
        if pct < 100, !requireProGate() {
            SettingsStore.chargeLimit = 100
            return false
        }
        SettingsStore.chargeLimit = pct
        writeJSON()
        if pct < 100 { ensureHelper() }
        return true
    }

    /// Сменить режим. mode: "off" | "limit" | "sail" (зеркало индексов popup 0/1/2).
    ///  - off  → limit@100 (без Pro).
    ///  - limit→ вход в активный лимит (было 100 → станет 80) требует Pro; при отказе НЕ меняется.
    ///  - sail → Pro-гейт; при отказе режим НЕ меняется.
    @discardableResult
    static func setMode(_ mode: String) -> Bool {
        switch mode {
        case "off":
            SettingsStore.chargeMode = "limit"
            SettingsStore.chargeLimit = 100
        case "sail":
            if !requireProGate() { return false }
            SettingsStore.chargeMode = "sail"
        default: // "limit"
            // Активный лимит (80%) — Pro-фича: гейтим ТОЛЬКО когда лимит реально становится активным
            // (был 100). Иначе не-Pro включал бы 80% и провоцировал установку root-демона бесплатно.
            if SettingsStore.chargeLimit == 100, !requireProGate() { return false }
            SettingsStore.chargeMode = "limit"
            if SettingsStore.chargeLimit == 100 { SettingsStore.chargeLimit = 80 }
        }
        writeJSON()
        if isActive { ensureHelper() }
        return true
    }

    /// Парусные границы. tag-агностично: задаём верх и низ, удерживая полосу ≥5.
    /// Зеркало sailThresholdChanged (в самом хендлере Pro-гейта нет — режим уже за гейтом).
    /// Возвращает финально применённые (upper, lower) после зажима.
    @discardableResult
    static func setSail(upper: Int, lower: Int) -> (upper: Int, lower: Int) {
        SettingsStore.sailUpper = upper
        SettingsStore.sailLower = lower
        // удерживаем полосу ≥5 (sailLower ≤ sailUpper−5), в обе стороны — как в хендлере
        if SettingsStore.sailLower > SettingsStore.sailUpper - 5 {
            SettingsStore.sailLower = max(50, SettingsStore.sailUpper - 5)
        }
        if SettingsStore.sailUpper < SettingsStore.sailLower + 5 {
            SettingsStore.sailUpper = min(90, SettingsStore.sailLower + 5)
        }
        writeJSON()
        if SettingsStore.chargeMode == "sail" { ensureHelper() }
        return (SettingsStore.sailUpper, SettingsStore.sailLower)
    }

    /// Сдвинуть один парусный порог (как одиночный слайдер). top=true → верх, иначе низ.
    /// Полностью повторяет ветвление sailThresholdChanged (tag 1 = верх, 0 = низ).
    @discardableResult
    static func setSailThreshold(_ value: Int, top: Bool) -> (upper: Int, lower: Int) {
        if top {
            SettingsStore.sailUpper = value
            if SettingsStore.sailLower > value - 5 { SettingsStore.sailLower = max(50, value - 5) }
        } else {
            SettingsStore.sailLower = value
            if SettingsStore.sailUpper < value + 5 { SettingsStore.sailUpper = min(90, value + 5) }
        }
        writeJSON()
        return (SettingsStore.sailUpper, SettingsStore.sailLower)
    }

    /// Top-Up: временно снять лимит (~1 час). Pro-гейт; демон сам вернёт режим по истечении.
    /// Зеркало topUpNow (без модального «Готово» — это деталь UI настроек, не логики).
    @discardableResult
    static func topUp() -> Bool {
        if !requireProGate() { return false }
        SettingsStore.topUpUntil = Date().timeIntervalSince1970 + 3600
        writeJSON()
        ensureHelper()
        return true
    }

    /// Плановый дозаряд «полный заряд к времени». Включение — Pro; выключение — свободно.
    /// ЧЕСТНОСТЬ: демон поднимает BCLM=100 в суточном окне [цель−фора, цель], ТОЛЬКО пока Mac
    /// бодрствует и заряжается; спящий Mac он НЕ будит (это оговорено в UI-сноске).
    @discardableResult
    static func setAlarm(on: Bool, targetMin: Int? = nil, leadMin: Int? = nil) -> Bool {
        if on, !SettingsStore.chargeAlarmOn, !requireProGate() { return false }   // Pro только на включении
        SettingsStore.chargeAlarmOn = on
        if let t = targetMin { SettingsStore.chargeAlarmTargetMin = min(1439, max(0, t)) }
        if let l = leadMin  { SettingsStore.chargeAlarmLeadMin = min(720, max(1, l)) }
        writeJSON()
        if on { ensureHelper() }
        return true
    }

    /// Защита аккумулятора от перегрева. Как и остальные параметры, сначала
    /// сохраняет конфигурацию, а setup системного компонента оставляет явной CTA.
    @discardableResult
    static func setHeatProtection(_ on: Bool) -> Bool {
        if on, !SettingsStore.heatProtect, !requireProGate() { return false }
        SettingsStore.heatProtect = on
        writeJSON()
        if on { ensureHelper() }
        return true
    }

    // MARK: - Единый путь записи (json + установка демона)

    /// Пишет полный charge-limit.json. Поле "limit" всегда присутствует — старый
    /// (limit-only) демон по-прежнему безопасно капает (для парусного режима ему
    /// отдаём верхний порог). Тело идентично старому writeChargeConfigJSON.
    static func writeJSON() {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Kelvin")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("charge-limit.json")
        let mode = SettingsStore.chargeMode                          // "limit" | "sail"
        let legacyLimit = (mode == "sail") ? SettingsStore.sailUpper : SettingsStore.chargeLimit
        let obj: [String: Any] = [
            "limit":          legacyLimit,                          // ← обязателен для обратной совместимости
            "mode":           mode,
            "sailUpper":      SettingsStore.sailUpper,
            "sailLower":      SettingsStore.sailLower,
            "heatProtect":    SettingsStore.heatProtect,
            "heatTemp":       SettingsStore.heatTemp,
            "topUpUntil":     SettingsStore.topUpUntil,
            "topUpDaily":     SettingsStore.chargeAlarmOn,          // плановый дозаряд «полный к времени»
            "topUpTargetMin": SettingsStore.chargeAlarmTargetMin,
            "topUpLeadMin":   SettingsStore.chargeAlarmLeadMin,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj) { try? data.write(to: URL(fileURLWithPath: path)) }
    }

    /// Сообщает UI, что конфигурация подготовлена, но системный компонент ещё не подключён.
    /// ВАЖНО: штатное изменение настройки никогда само не открывает admin/password dialog.
    /// Установка выполняется только по явной CTA пользователя в Settings.
    static func ensureHelper() {
        if HelperInstall.fandInstalled {
            helperSetupNoticePosted = false
            return
        }
        guard !helperSetupNoticePosted else { return }
        helperSetupNoticePosted = true
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: helperSetupNeeded, object: nil)
        }
    }
}
