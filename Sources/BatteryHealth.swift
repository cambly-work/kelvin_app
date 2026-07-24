import Foundation

/// Анализ деградации АКБ по накопленной истории здоровья. Честность как закон продукта:
///  • Тренд считаем ТОЛЬКО при достаточном охвате (≥14 дней и ≥8 точек) — иначе «нужно больше истории»,
///    а не выдуманная кривая падения по двум точкам.
///  • Прогноз «до 80%» выдаём лишь при ощутимом отрицательном наклоне и в разумном горизонте (≤10 лет);
///    иначе — молчим (не пугаем и не обещаем ложной вечности). health от SMC квантованный/шумный — линейная
///    регрессия сглаживает, но мы не делаем вид, что это точный прогноз (префикс «~»).
enum BatteryHealth {
    struct Insight {
        let present: Bool
        let health: Double?          // % (nil если нет АКБ/нечитаемо)
        let cycles: Int?
        let ratedCycles: Int?
        let slopePerMonth: Double?   // %/30дн (отрицательный = деградирует); nil если данных мало
        let monthsTo80: Double?      // мес до 80% при текущем темпе; nil если не деградирует/слишком далеко
        let spanDays: Double         // охват истории здоровья, дней
        let enough: Bool             // хватило ли данных на тренд
    }

    static func analyze(battery: BatteryInfo?, healthSeries s: [(ts: Int64, v: Double)]) -> Insight {
        let present = battery?.present ?? false
        let health: Double? = (present && (battery?.health ?? 0) > 1) ? battery?.health : nil
        let cycles: Int? = present ? battery?.cycleCount : nil
        let rated = battery?.ratedCycles

        var slopePerMonth: Double? = nil
        var monthsTo80: Double? = nil
        var enough = false
        var spanDays = 0.0

        if s.count >= 8, let t0 = s.first?.ts, let t1 = s.last?.ts, t1 > t0 {
            spanDays = Double(t1 - t0) / 86_400
            if spanDays >= 14 {
                // линейная регрессия: x — дни от начала, y — % здоровья
                let n = Double(s.count)
                let xs = s.map { Double($0.ts - t0) / 86_400 }
                let ys = s.map { $0.v }
                let sx = xs.reduce(0, +), sy = ys.reduce(0, +)
                let sxx = zip(xs, xs).reduce(0.0) { $0 + $1.0 * $1.1 }
                let sxy = zip(xs, ys).reduce(0.0) { $0 + $1.0 * $1.1 }
                let denom = n * sxx - sx * sx
                if abs(denom) > 1e-9 {
                    let slopePerDay = (n * sxy - sx * sy) / denom
                    let spm = slopePerDay * 30.0
                    enough = true
                    slopePerMonth = spm
                    // порог -0.15%/мес: выше шумового пола SMC-переоценки (единицы мА·ч дрейфа на коротком
                    // окне дают ~-0.05..-0.1), но заметно ниже темпа реально деградирующей АКБ.
                    if spm < -0.15, let h = health, h > 80 {
                        let mt = (h - 80) / (-spm)
                        if mt <= 120 { monthsTo80 = mt }        // >10 лет — слишком далеко, чтобы честно называть
                    }
                }
            }
        }

        return Insight(present: present, health: health, cycles: cycles, ratedCycles: rated,
                       slopePerMonth: slopePerMonth, monthsTo80: monthsTo80, spanDays: spanDays, enough: enough)
    }
}
