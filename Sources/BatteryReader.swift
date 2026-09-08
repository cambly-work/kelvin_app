import Foundation
import IOKit
import IOKit.ps

/// Снимок состояния батареи, читается напрямую из IORegistry (без sudo).
struct BatteryInfo {
    var charge: Int          // % (CurrentCapacity / MaxCapacity)
    var voltage: Double      // В
    var amperage: Double     // А (отрицательное = разряд)
    var watts: Double        // мгновенная мощность, Вт (модуль V*I)
    var charging: Bool
    var external: Bool       // подключён внешний адаптер
    var currentCapacity: Int // мА·ч
    var maxCapacity: Int     // мА·ч (полный заряд сейчас)
    var designCapacity: Int  // мА·ч (заводская ёмкость)
    var cycleCount: Int
    var temperature: Double  // °C
    var timeToEmpty: Int     // мин (-1 если считается)
    var timeToFull: Int      // мин
    var health: Double       // % (maxCapacity / designCapacity)
    var cells: [Double]      // напряжение по ячейкам, В
    var present = true       // false на десктопах без АКБ (iMac/mini/Studio/Pro)
    var manufactureDate: String? = nil   // сырая ASCII-строка ManufacturerData (НЕ документированный API → literal)
    var ratedCycles: Int? = nil          // DesignCycleCount9C; nil если 0/65535 (не populated)
    var notChargingReason: Int? = nil    // ChargerData.NotChargingReason (недокументирован → показываем код literal)

    var capacityWh: Double { Double(currentCapacity) * voltage / 1000.0 }
    var maxWh: Double { Double(maxCapacity) * voltage / 1000.0 }
    /// Пользовательская шкала здоровья батареи — 0...100%. Сырой коэффициент ёмкости может быть
    /// немного выше 100 у новой/перекалиброванной АКБ; это диагностическая деталь, не состояние UI.
    var displayHealth: Double { max(0, min(100, health)) }

    /// «Нет батареи» — для десктопов: строка меню переходит в живой CPU-режим, не застывает.
    static let absent = BatteryInfo(charge: 0, voltage: 0, amperage: 0, watts: 0, charging: false,
                                    external: true, currentCapacity: 0, maxCapacity: 1, designCapacity: 1,
                                    cycleCount: 0, temperature: 0, timeToEmpty: 0, timeToFull: 0,
                                    health: 0, cells: [], present: false)
}

enum BatteryReader {

    /// % заряда из IOPowerSources — РОВНО тот источник, что показывает строка меню macOS
    /// (система слегка сглаживает), в отличие от сырого AppleSmartBattery.CurrentCapacity,
    /// который расходился с системным на 1–3%. nil → нет внутренней батареи / недоступно → фолбэк.
    static func systemChargePercent() -> Int? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            if let cur = desc[kIOPSCurrentCapacityKey] as? Int,
               let mx = desc[kIOPSMaxCapacityKey] as? Int, mx > 0 {
                return Int((Double(cur) / Double(mx) * 100.0).rounded())
            }
        }
        return nil
    }

    static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(ioPort(),
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }

        func int(_ key: String) -> Int { (dict[key] as? NSNumber)?.intValue ?? 0 }
        // Amperage хранится как 64-битное знаковое; .int64Value корректно вернёт минус.
        func signed(_ key: String) -> Int64 { (dict[key] as? NSNumber)?.int64Value ?? 0 }
        func bool(_ key: String) -> Bool { (dict[key] as? Bool) ?? false }

        let voltage = Double(int("Voltage")) / 1000.0
        let amperage = Double(signed("Amperage")) / 1000.0
        let design = max(int("DesignCapacity"), 1)

        // Apple Silicon: CurrentCapacity/MaxCapacity — ПРОЦЕНТЫ (0..100), а сырые мА·ч лежат в AppleRaw*.
        // Intel: те же ключи уже в мА·ч. Распознаём AS по тому, что MaxCapacity<=100 и есть AppleRawMaxCapacity.
        // Без этого ветвления Здоровье≈1% и Ёмкость≈1 Вт·ч на всех M-маках (читался процент как мА·ч).
        let pctCur = int("CurrentCapacity")
        let pctMax = max(int("MaxCapacity"), 1)
        let rawCur = int("AppleRawCurrentCapacity")
        let rawMax = int("AppleRawMaxCapacity")
        let percentScale = pctMax <= 100 && rawMax > 0
        let curMah = percentScale ? rawCur : pctCur
        let maxMah = percentScale ? max(rawMax, 1) : pctMax
        // Заряд для показа берём из IOPowerSources (как система), фолбэк — расчёт по AppleSmartBattery.
        let rawPct = percentScale ? pctCur : Int((Double(pctCur) / Double(pctMax) * 100).rounded())
        let chargePct = BatteryReader.systemChargePercent() ?? rawPct

        var cells: [Double] = []
        if let bd = dict["BatteryData"] as? [String: Any],
           let cv = bd["CellVoltage"] as? [Int] {
            cells = cv.map { Double($0) / 1000.0 }
        }

        var temp = Double(int("Temperature")) / 100.0
        if temp > 100 { temp /= 10 }                                  // часть моделей отдают деци-°C → масштабируем

        // Дата АКБ — сырьё из ManufacturerData (CFData с ASCII, напр. "2020-12-06"). Не документированный
        // «manufacture date», формат вендор-специфичен → показываем literal ТОЛЬКО если чисто печатаемый, иначе nil.
        var mfgDate: String? = nil
        if let data = dict["ManufacturerData"] as? Data, let raw = String(data: data, encoding: .ascii) {
            let s = String(raw.prefix(while: { $0 != "\0" }))                    // обрезаем по первому NUL (не склеивать хвост)
                       .filter { c in c.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value < 0x7F } }
                       .trimmingCharacters(in: .whitespaces)
            if !s.isEmpty, s.count <= 24 { mfgDate = s }
        }
        // Ресурс циклов — DesignCycleCount9C; 0/65535 = не populated (сосед DesignCycleCount70=65535) → nil.
        let rc = int("DesignCycleCount9C")
        let ratedCycles: Int? = (rc > 0 && rc != 65535) ? rc : nil
        // Почему не заряжается — код из ChargerData.NotChargingReason (недокументирован → literal).
        var ncr: Int? = nil
        if let cd = dict["ChargerData"] as? [String: Any], let r = cd["NotChargingReason"] as? NSNumber { ncr = r.intValue }

        return BatteryInfo(
            charge: max(0, min(100, chargePct)),                      // кламп: транзиентный глитч не даёт «103%»
            voltage: voltage,
            amperage: amperage,
            watts: abs(voltage * amperage),
            charging: bool("IsCharging"),
            external: bool("ExternalConnected"),
            currentCapacity: curMah,
            maxCapacity: maxMah,
            designCapacity: design,
            cycleCount: int("CycleCount"),
            temperature: temp,
            timeToEmpty: int("TimeRemaining"),
            timeToFull: int("AvgTimeToFull"),
            health: min(Double(maxMah) / Double(design) * 100.0, 120), // сырой мА·ч/design; верхний предел от мусора
            cells: cells,
            manufactureDate: mfgDate,
            ratedCycles: ratedCycles,
            notChargingReason: ncr
        )
    }
}
