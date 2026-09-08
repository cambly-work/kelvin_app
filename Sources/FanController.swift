import Foundation
import Darwin   // sysctlbyname

/// Один вентилятор: текущие/мин/макс обороты и режим.
struct FanInfo {
    let index: Int
    var rpm: Double
    var min: Double
    var max: Double
    var forced: Bool        // F<i>Md == 1 → ручной режим
}

/// Доступные температурные сенсоры (ключ SMC → человекочитаемое имя).
struct TempSensor: Identifiable, Hashable {
    let key: String
    let name: String
    var id: String { key }
}

/// Профиль управления вентиляторами.
enum FanMode: String, Codable { case auto, constant, curve }

/// Одна точка многоточечной кривой: температура (°C) → целевые обороты (об/мин).
/// Структурно идентична `CurvePoint` в helper/fand.swift — тот же JSON читают обе стороны.
struct CurvePoint: Codable, Equatable { var temp: Int; var rpm: Int }

extension CurvePoint {
    /// Резильентный декодер (в экстеншене — чтобы сохранить memberwise-init): частичный элемент → (0,0),
    /// который sanitizedPoints потом клампит/чинит. Иначе ОДИН битый элемент curvePoints ронял декод ВСЕГО
    /// массива пресетов (try? …decode([FanProfile]) → [] → тихая потеря всей библиотеки кривых).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        temp = try c.decodeIfPresent(Int.self, forKey: .temp) ?? 0
        rpm  = try c.decodeIfPresent(Int.self, forKey: .rpm) ?? 0
    }
}

/// Настройка ОДНОГО вентилятора (per-fan override). Все поля опциональны при декоде → старые профили целы.
/// Зеркалит helper/fand.swift FanSettingD (общий JSON). Мульти-датчик sensorKeys — max-of (безопасно: не недоохладит).
struct FanSetting: Codable, Equatable {
    var mode: FanMode = .curve
    var rpm: Int = 3000
    var sensorKeys: [String] = ["TC0P"]
    var tempLow: Int = 42
    var tempHigh: Int = 72
    var curvePoints: [CurvePoint]? = nil
    var idleHandoffTemp: Int? = nil       // ниже порога → отдать этот вент системе (nil = выкл)
    init() {}
    init(mode: FanMode, rpm: Int = 3000, sensorKeys: [String] = ["TC0P"], tempLow: Int = 42, tempHigh: Int = 72,
         curvePoints: [CurvePoint]? = nil, idleHandoffTemp: Int? = nil) {
        self.mode = mode; self.rpm = rpm; self.sensorKeys = sensorKeys; self.tempLow = tempLow
        self.tempHigh = tempHigh; self.curvePoints = curvePoints; self.idleHandoffTemp = idleHandoffTemp
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(FanMode.self, forKey: .mode) ?? .curve
        rpm = try c.decodeIfPresent(Int.self, forKey: .rpm) ?? 3000
        sensorKeys = try c.decodeIfPresent([String].self, forKey: .sensorKeys) ?? ["TC0P"]
        tempLow = try c.decodeIfPresent(Int.self, forKey: .tempLow) ?? 42
        tempHigh = try c.decodeIfPresent(Int.self, forKey: .tempHigh) ?? 72
        curvePoints = try c.decodeIfPresent([CurvePoint].self, forKey: .curvePoints)
        idleHandoffTemp = try c.decodeIfPresent(Int.self, forKey: .idleHandoffTemp)
    }
}

struct FanProfile: Codable, Equatable {
    var name: String
    var mode: FanMode
    var rpm: Int = 3000                 // для constant
    var sensorKey: String = "TC0P"      // кривая по СГЛАЖЕННОМУ датчику (корпус) — без «воя» от скачков кристалла
    var tempLow: Int = 42               // °C → min RPM (для корпуса; раньше 45/85 → недокручивало)
    var tempHigh: Int = 72              // °C → max RPM (корпус 72° ≈ кристалл у предела)
    var alertSensorKeys: [String] = []  // пусто → защита по КРИСТАЛЛУ (force-max до троттла)
    var alertTemp: Int = 98             // у TjMax ~100 — форсируем максимум заранее
    /// Многоточечная кривая (≥2 точки) — приоритетнее 2-точечной tempLow/tempHigh, когда задана.
    /// OPTIONAL намеренно: синтез-Codable терпит отсутствие ключа → старые сохранённые профили не ломаются.
    var curvePoints: [CurvePoint]? = nil
    // — Редизайн «по-полной» (все опц. → старые профили декодятся как прежде): —
    var perFan: [FanSetting]? = nil       // per-fan override, index = вент; nil → глобальные поля на все венты
    var curveSensorKeys: [String]? = nil  // мульти-датчик ГЛОБАЛЬНОЙ кривой (max-of); nil → [sensorKey]
    var idleHandoffTemp: Int? = nil       // глобальный порог idle-отдачи (nil = выкл)
    var rampTime: Int = 0                 // сек плавного разгона (slew, только в демоне); 0 = мгновенно

    static let auto = FanProfile(name: "Авто", mode: .auto)

    /// Эффективная настройка вентилятора f: per-fan override, иначе глобальные поля профиля.
    /// ЕДИНЫЙ источник — зеркалится в fand.swift effectiveSetting.
    func setting(forFan f: Int) -> FanSetting {
        if let pf = perFan, f >= 0, f < pf.count { return pf[f] }
        return FanSetting(mode: mode, rpm: rpm,
                          sensorKeys: (curveSensorKeys?.isEmpty == false) ? curveSensorKeys! : [sensorKey],
                          tempLow: tempLow, tempHigh: tempHigh, curvePoints: curvePoints,
                          idleHandoffTemp: idleHandoffTemp)
    }
}

extension FanProfile {
    /// Устойчивый декодер (в экстеншене — чтобы сохранить memberwise-init): недостающие ключи → дефолты.
    /// Обязателен: rampTime — не-Optional новый ключ, старые сохранённые пресеты (userFanPresets) без него
    /// иначе роняли бы декод ВСЕЙ библиотеки. Тот же приём, что у CurvePoint/ProfileD.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Авто"
        mode = try c.decodeIfPresent(FanMode.self, forKey: .mode) ?? .auto
        rpm = try c.decodeIfPresent(Int.self, forKey: .rpm) ?? 3000
        sensorKey = try c.decodeIfPresent(String.self, forKey: .sensorKey) ?? "TC0P"
        tempLow = try c.decodeIfPresent(Int.self, forKey: .tempLow) ?? 42
        tempHigh = try c.decodeIfPresent(Int.self, forKey: .tempHigh) ?? 72
        alertSensorKeys = try c.decodeIfPresent([String].self, forKey: .alertSensorKeys) ?? []
        alertTemp = try c.decodeIfPresent(Int.self, forKey: .alertTemp) ?? 98
        curvePoints = try c.decodeIfPresent([CurvePoint].self, forKey: .curvePoints)
        perFan = try c.decodeIfPresent([FanSetting].self, forKey: .perFan)
        curveSensorKeys = try c.decodeIfPresent([String].self, forKey: .curveSensorKeys)
        idleHandoffTemp = try c.decodeIfPresent(Int.self, forKey: .idleHandoffTemp)
        rampTime = try c.decodeIfPresent(Int.self, forKey: .rampTime) ?? 0
    }
}

enum FanController {
    private static var smc: SMC { EnergyModel.smc }
    /// Сенсоры-защиты по умолчанию (реальная температура кристалла CPU/GPU).
    static let defaultAlertKeys = ["TCXC", "TC0E", "TG0D"]
    
    /// Получить hw.model.
    static func sysctlStr(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buf)
    }
    
    /// Определить архитектуру (arm64/x86_64).
    static func architecture() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buf, &size, nil, 0) == 0 else { return "unknown" }
        let machine = String(cString: buf)
        return machine.hasPrefix("arm") ? "arm64" : "x86_64"
    }

    /// Список вентиляторов с текущими оборотами (чтение без sudo).
    static func fans() -> [FanInfo] {
        // Использовать resolved sensor set для определения доступных вентиляторов.
        let smc = EnergyModel.smc
        
        // Сначала попробовать FNum через resolver
        if let fnum = smc.read("FNum"), fnum > 0 {
            let mask = Int(smc.read("FS! ") ?? 0)
            return (0..<min(Int(fnum), 10)).compactMap { i in
                let acKey = "F\(i)Ac"
                let minRPM = smc.read("F\(i)Mn")
                let maxRPM = smc.read("F\(i)Mx")
                guard let cur = smc.read(acKey),
                      cur.isFinite, cur >= 0,
                      minRPM != nil || maxRPM != nil else { return nil }
                return FanInfo(index: i,
                               rpm: cur,
                               min: minRPM ?? 0,
                               max: maxRPM ?? max(cur, 1),
                               forced: (mask >> i) & 1 == 1)
            }
        }
        
        // Fallback: legacy-метод для совместимости
        let n = Int(smc.read("FNum") ?? 0)
        guard n > 0, n < 10 else { return [] }
        let mask = Int(smc.read("FS! ") ?? 0)
        return (0..<n).map { i in
            FanInfo(index: i,
                    rpm: smc.read("F\(i)Ac") ?? 0,
                    min: smc.read("F\(i)Mn") ?? 0,
                    max: smc.read("F\(i)Mx") ?? 0,
                    forced: (mask >> i) & 1 == 1)
        }
    }
    
    /// Получить cooling topology для текущей модели.
    static func coolingTopology() -> CoolingTopology {
        let model = sysctlStr("hw.model")
        let arch = architecture()
        let catalog = SensorCatalog.build()
        let smc = EnergyModel.smc
        
        guard smc.available else { return .unknown }
        
        let resolved = SensorResolver.resolve(
            model: model,
            architecture: arch,
            catalog: catalog,
            readValue: { smc.read($0) }
        )
        
        return resolved.cooling
    }
    
    /// Проверка наличия активного охлаждения.
    static var hasActiveCooling: Bool {
        let topology = coolingTopology()
        if case .active = topology { return true }
        return false
    }
    
    /// Проверка пассивного охлаждения (fanless).
    static var isPassiveCooling: Bool {
        let topology = coolingTopology()
        if case .passive = topology { return true }
        return false
    }

    /// Кандидаты-сенсоры температуры (только реально читаемые сейчас).
    static func sensors() -> [TempSensor] {
        // Использовать resolved sensor set для получения подтверждённых температурных сенсоров.
        let model = sysctlStr("hw.model")
        let arch = architecture()
        let catalog = SensorCatalog.build()
        
        guard smc.available else { return [] }
        
        let resolved = SensorResolver.resolve(
            model: model,
            architecture: arch,
            catalog: catalog,
            readValue: { smc.read($0) }
        )
        
        // Собрать все подтверждённые ключи из resolved сенсоров.
        var confirmedKeys: Set<String> = []
        for sensor in resolved.sensors.values {
            confirmedKeys.formUnion(sensor.keys)
        }
        
        // «ядра» (кристалл, PECI) — реальная температура, по ней и стоит рулить;
        // «корпус» (TC0P) — сглаженный датчик-близость, прохладнее на ~30°.
        let candidates: [(String, String)] = [
            ("TC0E", "CPU ядра"), ("TCXC", "CPU ядра+"), ("TC0P", "CPU корпус"), ("TG0D", "GPU"),
            ("TM0P", "Память"), ("TPCD", "Чипсет"), ("Ts0P", "Корпус"), ("TB0T", "Батарея"),
            ("TA0P", "Воздух"), ("TH0P", "Накопитель"),
        ]
        
        return candidates.compactMap { key, name in
            // Приоритет: confirmed keys из resolver, иначе fallback на legacy-кандидатов.
            let isConfirmed = confirmedKeys.contains(key)
            guard let v = smc.read(key), v > 5, v < 130 else { return nil }
            // Показывать только подтверждённые или явно читаемые ключи.
            if !isConfirmed && !confirmedKeys.isEmpty { return nil }
            // Отображаемое имя локализуем (B2-косметика); персистится .key, а не имя — матч не затронут.
            return TempSensor(key: key, name: "\(L(name)) (\(key))")
        }
    }

    static func temp(_ key: String) -> Double? { smc.read(key) }

    /// Резолв профиля по СТАБИЛЬНОМУ id: встроенные (auto/quiet/balance/turbo) + пользовательские пресеты.
    /// Источник истины встроенных ДУБЛИРУЕТ Settings.activeDraft — держать синхронно (значения стабильны).
    static func profile(named id: String) -> FanProfile {
        switch id {
        case "auto":    return .auto
        case "quiet":   return FanProfile(name: "Тихий", mode: .constant, rpm: 2200)
        case "balance": return FanProfile(name: "Баланс", mode: .curve, sensorKey: "TC0P", tempLow: 42, tempHigh: 72, alertTemp: 98)
        case "turbo":   return FanProfile(name: "Турбо", mode: .constant, rpm: 9999)
        default:        return SettingsStore.userFanPresets.first { $0.name == id } ?? .auto
        }
    }

    /// Каноническая запись профиля в fan-profile.json (санитизирует кривую перед демоном). Единый путь
    /// и для «Применить» из настроек, и для headless-автоматики.
    static func writeProfileFile(_ p: FanProfile) {
        var q = p
        let clean = sanitizedPoints(p.curvePoints ?? [])
        q.curvePoints = clean.isEmpty ? nil : clean
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Kelvin")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("fan-profile.json")
        if let data = try? JSONEncoder().encode(q) {
            do {
                // .atomic: root-демон fand опрашивает fan-profile.json каждые ~2с. Без атомарной
                // записи torn read даёт повреждённый JSON → декодер тихо применяет дефолты
                // (3000 rpm / 72°C), хотя пользователь ожидает активный профиль.
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                Log.app.error("FanController: не удалось записать профиль \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Headless-применение профиля по id (без NSAlert) — для автоматики по источнику питания.
    /// Конфигурация сохраняется даже без установленного демона: UI честно показывает её как
    /// подготовленную, а после явного подключения системного компонента она применится без
    /// повторного выбора. Демон подхватит файл за ~2с со всеми backstop'ами.
    static func applyProfileHeadless(named id: String) {
        writeProfileFile(profile(named: id))
        SettingsStore.activeFanProfileName = id
    }

    private static var supportDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Kelvin")
    }
    static var daemonInstalled: Bool {
        HelperInstall.fandInstalled
    }
    /// Heartbeat «аренды»: пока приложение живо, обновляем mtime конфигов — демон видит, что
    /// контроллер на связи. Если приложение исчезнет (краш/удаление), файлы «протухнут» за лизинг-окно
    /// (15 мин) и демон сам вернёт авто-режим — вентиляторы не останутся форсированными навсегда.
    static func refreshLease() {
        guard daemonInstalled else { return }
        let fm = FileManager.default
        for f in ["fan-profile.json", "charge-limit.json"] {
            let p = (supportDir as NSString).appendingPathComponent(f)
            if fm.fileExists(atPath: p) { try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: p) }
        }
    }

    /// Целевые обороты по профилю и текущим температурам (расчёт; запись — отдельный root-хелпер).
    /// ВАЖНО: логика кривой обязана БАЙТ-В-БАЙТ совпадать с fand.swift computeTargets — это превью того,
    /// что применит демон. Любая правка здесь дублируется там (и наоборот).
    /// STEADY-STATE целевые обороты вентилятора (per-fan, мульти-датчик max-of, idle-отдача). БЕЗ slew —
    /// разгон живёт только в демоне поверх этой цели (превью показывает установившуюся цель). Возврат nil =
    /// вент отдан системе (авто/idle/все датчики недоступны). Обязана совпадать с fand.swift computeTargets.
    static func targetRPM(for p: FanProfile, fan: FanInfo) -> Double? {
        let s = p.setting(forFan: fan.index)
        if s.mode == .auto { return nil }
        let alert = alertActive(p)
        // idle-отдача: ниже порога — системе (если алерт не сработал). idle>0 — как в демоне (0/nil = выкл).
        if !alert, let idle = s.idleHandoffTemp, idle > 0, let lead = leadingTemp(s.sensorKeys), lead < Double(idle) {
            return nil
        }
        if alert { return fan.max }                                  // алерт → форс макс (минует idle/кривую/constant)
        switch s.mode {
        case .auto: return nil
        case .constant: return Double(s.rpm).clamped(fan.min, fan.max)
        case .curve:
            guard let t = leadingTemp(s.sensorKeys) else { return nil }   // все датчики nil → системе
            let pts = sanitizedPoints(s.curvePoints ?? [])
            if pts.count >= 2 { return curveRPM(pts, temp: t, min: fan.min, max: fan.max).rounded() }
            let lo = Double(s.tempLow), hi = Double(max(s.tempHigh, s.tempLow + 1))
            let frac = ((t - lo) / (hi - lo)).clamped(0, 1)
            return (fan.min + (fan.max - fan.min) * frac).rounded()
        }
    }

    /// Ведущая температура набора датчиков — max-of (не может недоохладить); nil если ВСЕ недоступны.
    static func leadingTemp(_ keys: [String]) -> Double? { keys.compactMap { temp($0) }.max() }
    /// Какой из выбранных датчиков ведёт прямо сейчас (для живого индикатора «Ведёт: TG0D 71°»).
    static func leadingSensor(_ keys: [String]) -> (key: String, temp: Double)? {
        keys.compactMap { k in temp(k).map { (k, $0) } }.max { $0.1 < $1.1 }
    }
    /// Сработал ли алерт (по alertSensorKeys / кристаллу) — форс макс. Едино для constant и curve.
    static func alertActive(_ p: FanProfile) -> Bool {
        // Использовать resolved sensor set для получения подтверждённых CPU/GPU сенсоров.
        let model = sysctlStr("hw.model")
        let arch = architecture()
        let catalog = SensorCatalog.build()
        
        guard smc.available else {
            // Fallback на legacy-ключи если SMC недоступен.
            for k in (p.alertSensorKeys.isEmpty ? defaultAlertKeys : p.alertSensorKeys) {
                if let t = temp(k), t >= Double(p.alertTemp) { return true }
            }
            return false
        }
        
        let resolved = SensorResolver.resolve(
            model: model,
            architecture: arch,
            catalog: catalog,
            readValue: { smc.read($0) }
        )
        
        // Построить список ключей для проверки:
        // 1. Если заданы alertSensorKeys — использовать их.
        // 2. Иначе использовать подтверждённые CPU/GPU сенсоры из resolver.
        // 3. Fallback на legacy defaultAlertKeys.
        var alertKeys: [String] = []
        
        if !p.alertSensorKeys.isEmpty {
            alertKeys = p.alertSensorKeys
        } else {
            // Собрать CPU и GPU ключи из resolved set.
            var confirmedKeys: [String] = []
            if let cpu = resolved.cpuTemperature {
                confirmedKeys.append(contentsOf: cpu.keys)
            }
            if let gpu = resolved.gpuTemperature {
                confirmedKeys.append(contentsOf: gpu.keys)
            }
            alertKeys = confirmedKeys.isEmpty ? defaultAlertKeys : confirmedKeys
        }
        
        for k in alertKeys {
            if let t = temp(k), t >= Double(p.alertTemp) { return true }
        }
        return false
    }

    /// Интерполяция многоточечной кривой temp→rpm: линейно между соседними точками, ПЛАТО за краями,
    /// затем кламп в [min,max] вентилятора. `points` должны быть уже санитизированы (sorted+monotonic).
    static func curveRPM(_ points: [CurvePoint], temp: Double, min lo: Double, max hi: Double) -> Double {
        guard let first = points.first, let last = points.last else { return lo }
        var rpm: Double
        if temp <= Double(first.temp) { rpm = Double(first.rpm) }
        else if temp >= Double(last.temp) { rpm = Double(last.rpm) }
        else {
            rpm = Double(last.rpm)
            for i in 1..<points.count {
                let a = points[i - 1], b = points[i]
                if temp < Double(b.temp) {
                    let span = Double(b.temp - a.temp)
                    let f = span > 0 ? (temp - Double(a.temp)) / span : 0
                    rpm = Double(a.rpm) + (Double(b.rpm) - Double(a.rpm)) * f
                    break
                }
            }
        }
        return rpm.clamped(lo, hi)
    }

    /// Валидация кривой (та же, что root-демон применяет к user-writable JSON): кламп temp[0,120]/rpm[0,7000],
    /// сорт по temp, дедуп одинаковых temp (макс rpm), МОНОТОННО-НЕУБЫВАЮЩИЙ rpm (горячее НИКОГДА не медленнее —
    /// безопасность охлаждения), не более 5 точек. Меньше 2 валидных → [] (падение на легаси 2-точки).
    static func sanitizedPoints(_ pts: [CurvePoint]) -> [CurvePoint] {
        var p = pts.map { CurvePoint(temp: Swift.min(120, Swift.max(0, $0.temp)), rpm: Swift.min(7000, Swift.max(0, $0.rpm))) }
        p.sort { $0.temp < $1.temp }
        var dedup: [CurvePoint] = []
        for pt in p {
            if let last = dedup.last, last.temp == pt.temp { dedup[dedup.count - 1].rpm = Swift.max(last.rpm, pt.rpm) }
            else { dedup.append(pt) }
        }
        p = Array(dedup.prefix(5))
        if p.count >= 2 { for i in 1..<p.count { p[i].rpm = Swift.max(p[i].rpm, p[i - 1].rpm) } }
        return p.count >= 2 ? p : []
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}
