import Foundation
import IOKit.ps

/// Честные данные о ПОДКЛЮЧЁННОМ адаптере питания из IOKit.ps.
/// `IOPSCopyExternalPowerAdapterDetails()` возвращает словарь о ВЕДЁННОМ PD-профиле:
/// Watts (номинал, на который рассчитан/договорился адаптер), FamilyCode, SerialNumber, Current, Name.
/// Это НЕ живой замер отдачи (тот лежит в SMC PDTR → EnergySnapshot.adapterWatts) — а ПАСПОРТ адаптера.
/// Показываем номинал и живой замер рядом как ДВЕ РАЗНЫЕ величины: видно запас/недобор по питанию.
enum AdapterInfo {
    /// Номинальная мощность (Вт) и имя адаптера, если ОС их отдаёт. nil → адаптер не подключён/нет данных.
    /// Поля внутри тоже опциональны: что недоступно — не выдумываем (показываем только реальное).
    struct Reading {
        var watts: Int?   // номинал из словаря (kIOPSPowerAdapterWattsKey)
        var name: String? // имя/модель адаптера, если ОС его отдаёт (kIOPSNameKey) — иначе nil
    }

    /// Лёгкое чтение. Паспорт статичен, пока адаптер воткнут, поэтому вызывающий (EnergyModel)
    /// кэширует результат и зовёт read() лишь на переходе «вставлен» — не каждый тик.
    /// Возвращает nil, когда внешний адаптер не подключён ИЛИ словарь недоступен.
    static func read() -> Reading? {
        guard let dict = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] else { return nil }
        let watts = (dict[kIOPSPowerAdapterWattsKey] as? NSNumber)?.intValue
        let name = (dict[kIOPSNameKey] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // Если ни номинала, ни имени нет — словарь бесполезен, считаем что данных нет.
        guard watts != nil || name != nil else { return nil }
        return Reading(watts: watts, name: name)
    }
}
