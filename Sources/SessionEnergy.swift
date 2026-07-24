import Foundation

/// Сессионные аккумуляторы вкладки «Поток»: энергия (Вт·ч), пик расхода, время на батарее.
/// Всё «за сессию» — живёт ровно процесс, БЕЗ диск-персиста в v1 (так и подписано в UI, сброс =
/// перезапуск приложения). Образец дисциплины — SensorsModel.peakTemp/history (статик, живёт сессию).
///
/// ЧЕСТНОСТЬ: интегрируем по РЕАЛЬНОМУ Δt между тиками (не предполагаем ровно 1 с — тик дрожит и
/// пропускается, особенно когда поповер закрыт и движок дросселирует). Большой разрыв (сон системы)
/// НЕ интегрируем «дырой» — иначе Вт·ч прыгнул бы на величину сна.
enum SessionEnergy {
    /// Σ systemWatts · Δt / 3600 — энергия за сессию, Вт·ч.
    private(set) static var wattHours: Double = 0
    /// Суммарное время на батарее за сессию, сек.
    private(set) static var onBatterySeconds: Double = 0
    /// Пик расхода (systemWatts) за сессию, Вт.
    private(set) static var peakSystemWatts: Double = 0
    /// Пик температуры (max из cpuTemp/gpuTemp снапшота) за сессию, °C. nil пока не было ни одного замера.
    private(set) static var peakTemp: Double?
    /// Когда началась сессия учёта (первый принятый сэмпл) — для подписи «за N».
    private(set) static var startedAt: Date?
    private static var lastTick: Date?

    /// Толкнуть сэмпл. Зовётся раз в тик там же, где есть свежий снапшот энергии.
    static func accumulate(_ s: EnergySnapshot) {
        // пик температуры — обновляем НЕЗАВИСИМО от Δt-гейта (это max, «дыра» сна ему не вредит)
        let t = [s.cpuTemp, s.gpuTemp].compactMap { $0 }.max()
        if let t { peakTemp = max(peakTemp ?? t, t) }
        let now = Date()
        defer { lastTick = now }
        guard let prev = lastTick else { startedAt = now; return }   // первый сэмпл задаёт начало отсчёта
        let dt = now.timeIntervalSince(prev)
        guard dt > 0, dt < 10 else { return }            // пропуск/сон (>10 с) — не интегрируем «дыру»
        wattHours += s.systemWatts * dt / 3600.0
        if !s.plugged { onBatterySeconds += dt }
        peakSystemWatts = max(peakSystemWatts, s.systemWatts)
    }
}
