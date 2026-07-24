import Foundation

/// Класс сенсора по ПЕРВОЙ букве FourCC. Единица берётся из класса, НЕ из значения.
///   T→temp(°C) · V→volt(В) · I→curr(А) · P→power(Вт) · F→fan(об/мин) · B→batt · иначе other
enum SensorClass {
    case temp, volt, curr, power, fan, batt, other

    /// Класс по первой букве FourCC.
    static func of(_ fourCC: String) -> SensorClass {
        switch fourCC.first {
        case "T": return .temp
        case "V": return .volt
        case "I": return .curr
        case "P": return .power
        case "F": return .fan
        case "B": return .batt
        default:  return .other
        }
    }

    /// Локализованное имя класса (для совпадения в поиске по категории).
    static func titleFor(_ c: SensorClass) -> String {
        switch c {
        case .temp:  return L("ТЕМПЕРАТУРЫ")
        case .volt:  return L("ВОЛЬТАЖИ")
        case .curr:  return L("ТОКИ")
        case .power: return L("ПИТАНИЕ")
        case .fan:   return L("ВЕНТИЛЯТОРЫ")
        case .batt:  return L("НАГРУЗКА")
        case .other: return L("РАСШИРЕННЫЕ")
        }
    }

    /// Единица класса для подписи значения (шёпотом справа). other без фиксированной единицы.
    /// batt — единица не из класса, а из физсмысла ключа (см. BattUnit.of) — здесь общий fallback.
    var unit: String {
        switch self {
        case .temp:  return "°C"
        case .volt:  return L("В")
        case .curr:  return L("А")
        case .power: return L("Вт")
        case .fan:   return L("об/мин")
        case .batt, .other: return ""
        }
    }
}

/// Физвеличина батарейного ключа (класс .batt) — выводится из ПОСЛЕДНЕЙ буквы FourCC, а не из класса.
///   …V → напряжение (В) · …C → ток (А) · …P → мощность (Вт). Иначе — неизвестно (без единицы).
/// Граница честности: подписанное значение всегда несёт корректную единицу, никаких «Вт» на не-ваттах.
enum BattUnit {
    case volt, curr, power, unknown

    static func of(_ fourCC: String) -> BattUnit {
        switch fourCC.last {
        case "V": return .volt     // B0AV / BC1V…BC3V — вольтаж
        case "C": return .curr     // B0AC — ток
        case "P": return .power    // B0AP — мощность
        default:  return .unknown
        }
    }

    var unit: String {
        switch self {
        case .volt:    return L("В")
        case .curr:    return L("А")
        case .power:   return L("Вт")
        case .unknown: return ""
        }
    }

    /// Подпись значения с корректной единицей и разумным числом знаков (не «%g»-хвост).
    func format(_ v: Double) -> String {
        switch self {
        case .volt:    return String(format: "%.2f %@", v, L("В"))
        case .curr:    return String(format: "%.2f %@", v, L("А"))
        case .power:   return String(format: "%.1f %@", v, L("Вт"))
        case .unknown: return String(format: "%.2f", v)   // нет единицы — но без «%g»-хвоста
        }
    }
}

/// Один ключ каталога — описание (статичное), без значения. id == FourCC (стабилен для пинов/истории).
struct CatalogKey {
    let fourCC: String
    let cls: SensorClass
    let smcType: String       // "flt"/"sp78"/"ui16"/… из keyInfo
    let curatedName: String?  // рус.имя из кураторского словаря; nil → сырой ключ
    let decodable: Bool       // тип входит в набор поддерживаемых декодеров

    var id: String { fourCC }
    /// Единица: для .batt — из физсмысла ключа (BattUnit), иначе — из класса.
    var unit: String { cls == .batt ? BattUnit.of(fourCC).unit : cls.unit }
    var displayName: String { curatedName ?? fourCC }
    var isRaw: Bool { curatedName == nil }
}

/// Одна строка ленты — описание + текущее значение + сессионная история (для скролл-вида).
struct CatalogRow {
    let key: CatalogKey
    let value: Double?
    let text: String          // готовая подпись «62°» / «значение не декодируется»
    let history: [Double]
}

/// Одна строка диагностики движка «подпись: значение» (без SMC-чтений).
struct EngineRow {
    let label: String
    let value: String
}

enum SensorCatalog {
    static var smc: SMC { EnergyModel.smc }

    /// Типы, которые decode() умеет превратить в число. Совпадает с веткой decode в SMCReader:
    /// flt / ui8 / ui16 / ui32 / si8 / si16 + любой spXY/fpXY (4-символьный fixed-point).
    private static func isDecodable(_ type: String) -> Bool {
        switch type {
        case "flt", "ui8", "ui16", "ui32", "si8", "si16": return true
        default:
            // spXY/fpXY: 4 символа, последняя — hex-цифра дробных бит (sp78/fpe2/…)
            return (type.hasPrefix("sp") || type.hasPrefix("fp"))
                && type.count == 4
                && Int(String(Array(type)[3]), radix: 16) != nil
        }
    }

    /// Кураторский словарь FourCC → рус.имя. ТОЛЬКО уже известные из кода ключи
    /// (SensorsModel.snapshot / EnergyModel.snapshot). Никаких выдуманных имён —
    /// всё прочее остаётся сырым FourCC.
    // ОДНО каноническое имя на концепт — без дублей (прежде каталог показывал 6× «CPU», 3× «Батарея»).
    // Прочие датчики того же концепта (TCXC/TC1C…, TG0P, TB1T/2T) остаются сырыми → уходят в свёрнутую
    // секцию «Сырые ключи». SensorsModel/EnergyModel читают SMC-ключи напрямую — на замеры это не влияет.
    static let curated: [String: String] = [
        // температуры
        "TCXC": "CPU", "TC0P": "CPU корпус",   // TCXC — агрегат PECI (его же берёт первым SensorsModel для героя)
        "TG0D": "GPU",
        "TM0P": "Память",
        "TPCD": "Платформа",
        "TW0P": "Wi-Fi",
        "TB0T": "Батарея",
        // вентиляторы
        "F0Ac": "Кулер 1", "F1Ac": "Кулер 2",
        "F0Mn": "Кулер 1 · мин", "F1Mn": "Кулер 2 · мин",
        "F0Mx": "Кулер 1 · макс", "F1Mx": "Кулер 2 · макс",
        // батарея / питание
        "B0AP": "АКБ мощность", "B0AV": "АКБ напряжение", "B0AC": "АКБ ток",
        "BC1V": "Ячейка 1", "BC2V": "Ячейка 2", "BC3V": "Ячейка 3",
        "PSTR": "Система (полное)", "PDTR": "Адаптер",
        "VD0R": "Адаптер · В", "ID0R": "Адаптер · А",
        // токовые рельсы потребителей
        "IM0c": "Память · ток", "IC0r": "CPU · ток", "IG0r": "GPU · ток",
        "VC0c": "CPU · В", "VG0c": "GPU · В",
    ]

    /// Каталог всех ключей машины — строится ОДИН раз из энумерации, дальше из кэша.
    private static var cache: [CatalogKey]?

    static func catalog() -> [CatalogKey] {
        if let c = cache { return c }
        guard smc.available else { return [] }
        var out: [CatalogKey] = []
        for fcc in smc.enumerateKeys() {
            // служебные мета-ключи (#KEY и пр.) — не сенсоры, в каталог не кладём
            if fcc.hasPrefix("#") { continue }
            let info = smc.typeInfo(fcc)
            let type = info?.type ?? ""
            let cls = SensorClass.of(fcc)
            out.append(CatalogKey(
                fourCC: fcc,
                cls: cls,
                smcType: type,
                curatedName: curated[fcc].map { L($0) },
                decodable: isDecodable(type)
            ))
        }
        // стабильный порядок: класс → имя/FourCC (раскладка по секциям делает вид, но детерминизм полезен)
        out.sort { a, b in
            if a.cls != b.cls { return classOrder(a.cls) < classOrder(b.cls) }
            return a.fourCC < b.fourCC
        }
        cache = out
        return out
    }

    private static func classOrder(_ c: SensorClass) -> Int {
        switch c {
        case .temp: return 0; case .volt: return 1; case .curr: return 2
        case .power: return 3; case .fan: return 4; case .batt: return 5; case .other: return 6
        }
    }

    /// Интеловый SMC отдаёт токи/вольтажи в мА/мВ для целочисленных/flt-ключей (эталон — EnergyModel.V()/A():
    /// там /1000 даёт вменяемые ватты); fixed-point (spXY/fpXY: VD0R, ID0R…) — уже в В/А. Каталог печатал
    /// сырьё как есть → «CPU · ток 500 А». Ватты/температуры/обороты — native, не трогаем.
    private static func normalize(_ key: CatalogKey, _ raw: Double) -> Double {
        let fixedPoint = key.smcType.hasPrefix("sp") || key.smcType.hasPrefix("fp")
        switch key.cls {
        case .curr, .volt:
            return fixedPoint ? raw : raw / 1000.0
        case .batt:
            switch BattUnit.of(key.fourCC) {
            case .volt, .curr: return fixedPoint ? raw : raw / 1000.0
            case .power, .unknown: return raw
            }
        default:
            return raw
        }
    }

    /// Форматирование значения по классу. Недекодируемое/nil → честная метка, НЕ «0».
    static func format(_ key: CatalogKey, _ value: Double?) -> String {
        guard key.decodable, let v = value, v.isFinite else {
            return L("значение не декодируется")
        }
        switch key.cls {
        case .temp:  return String(format: "%.0f°", v)
        case .volt:  return String(format: "%.2f %@", v, L("В"))
        case .curr:  return String(format: "%.2f %@", v, L("А"))
        case .power: return String(format: "%.1f %@", v, L("Вт"))
        case .fan:   return String(format: "%.0f", v)
        case .batt:
            // единица из физсмысла ключа (…V→В, …C→А, …P→Вт), формат с разумным числом знаков
            return BattUnit.of(key.fourCC).format(v)
        case .other:
            // нет фиксированной единицы — показываем сырое число (честно, без выдуманной единицы)
            return String(format: "%g", v)
        }
    }

    // MARK: — чтение значений ТОЛЬКО видимых строк (вид зовёт по запросу, не все 200/тик)

    /// Сессионная история значений каталога — keyed by FourCC. Раздельное пространство id с
    /// кураторскими гейджами (там id «cpu»/«gpu»): ключи не пересекаются, словари независимы.
    private static var history: [String: [Double]] = [:]
    private static let histCap = 32

    private static func pushHistory(_ id: String, _ v: Double, record: Bool) -> [Double] {
        guard record else { return history[id] ?? [] }
        var h = history[id] ?? []
        h.append(v)
        if h.count > histCap { h.removeFirst(h.count - histCap) }
        history[id] = h
        return h
    }

    /// Прочитать одну строку каталога по id (FourCC). Читает SMC ТОЛЬКО для этого ключа.
    /// Вид зовёт это для каждой ВИДИМОЙ строки в тике (visibleIDs), а не для всего каталога.
    static func row(_ id: String, record: Bool = true) -> CatalogRow? {
        guard let key = catalog().first(where: { $0.id == id }) else { return nil }
        return row(for: key, record: record)
    }

    static func row(for key: CatalogKey, record: Bool = true) -> CatalogRow {
        let v: Double? = key.decodable ? smc.read(key.fourCC).map { normalize(key, $0) } : nil
        let hist: [Double]
        if let v = v, v.isFinite { hist = pushHistory(key.id, v, record: record) }
        else { hist = history[key.id] ?? [] }
        return CatalogRow(key: key, value: v, text: format(key, v), history: hist)
    }

    /// Снимок для набора видимых id. read() зовётся ТОЛЬКО для них.
    static func snapshot(visibleIDs: Set<String>, record: Bool = true) -> [CatalogRow] {
        catalog()
            .filter { visibleIDs.contains($0.id) }
            .map { row(for: $0, record: record) }
    }

    // MARK: — диагностика «ДВИЖОК KELVIN» (из существующих полей, без новых SMC-чтений)

    /// Строки диагностики движка. Каталог-count и источник ватт собираются из уже доступных данных.
    static func engineDiagnostics(components: ComponentPower, energy: EnergySnapshot) -> [EngineRow] {
        var rows: [EngineRow] = []
        let age = components.ageSeconds
        let ageStr: String
        if age.isFinite {
            ageStr = String(format: L("%.1f с · "), age) + (components.fresh ? L("свежий") : L("устарел"))
        } else {
            ageStr = "— · " + L("устарел")
        }
        rows.append(EngineRow(label: L("Сэмпл хелпера"), value: ageStr))

        let pstrDirect = (energy.systemWattsRaw ?? 0) > 0.05
        rows.append(EngineRow(label: L("Источник ватт"),
                              value: pstrDirect ? L("PSTR (прямой)") : L("энергобаланс")))
        rows.append(EngineRow(label: L("Такт"), value: L("1 Гц")))
        rows.append(EngineRow(label: L("Сглаживание"), value: L("EMA 0.65/0.35 (CPU/GPU)")))
        rows.append(EngineRow(label: L("Кэш ключей"),
                              value: "\(catalog().count) " + L("ключей")))
        rows.append(EngineRow(label: L("История"), value: L("сессия · до 32 кадров")))
        return rows
    }
}
