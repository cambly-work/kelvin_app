import Foundation
import IOKit

// kelvin-fand — root-демон управления вентиляторами.
// Читает профиль (JSON), форсирует обороты через SMC (FS! / F<i>Tg).
// Защита: при превышении температуры алерта — максимум; при выходе — авто-режим.
// Компилируется вместе с SMCReader.swift (использует класс SMC).

// Одна точка многоточечной кривой temp→rpm. Структурно = Sources/FanController.swift CurvePoint (общий JSON).
struct CurvePoint: Codable { var temp = 0; var rpm = 0 }

// Настройка ОДНОГО вентилятора (per-fan). Зеркалит Sources/FanController.swift FanSetting (общий JSON).
// idleHandoffTemp: 0 = выкл (в app — Int?/nil; nil→ключ отсутствует→0). sensorKeys — max-of.
struct FanSettingD: Codable {
    var mode = "curve"
    var rpm = 3000
    var sensorKeys: [String] = ["TC0P"]
    var tempLow = 42
    var tempHigh = 72
    var curvePoints: [CurvePoint] = []
    var idleHandoffTemp = 0
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(String.self, forKey: .mode) { mode = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .rpm) { rpm = v }
        if let v = try c.decodeIfPresent([String].self, forKey: .sensorKeys) { sensorKeys = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .tempLow) { tempLow = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .tempHigh) { tempHigh = v }
        if let v = try c.decodeIfPresent([CurvePoint].self, forKey: .curvePoints) { curvePoints = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .idleHandoffTemp) { idleHandoffTemp = v }
    }
}

struct ProfileD: Codable {
    var name = "Авто"
    var mode = "auto"                  // auto | constant | curve
    var rpm = 3000
    var sensorKey = "TC0P"             // кривая по сглаженному корпусу; защита — по кристаллу (ниже)
    var tempLow = 42
    var tempHigh = 72
    var alertSensorKeys: [String] = []
    var alertTemp = 98
    var curvePoints: [CurvePoint] = [] // многоточечная кривая (≥2) — приоритетнее 2-точечной tempLow/tempHigh
    // — Редизайн «по-полной» (пусто/0 → глобальное поведение как прежде): —
    var perFan: [FanSettingD] = []      // per-fan override, index = вент; пусто → глобальные поля на все венты
    var curveSensorKeys: [String] = []  // мульти-датчик глобальной кривой (max-of); пусто → [sensorKey]
    var idleHandoffTemp = 0             // глобальный порог idle-отдачи (0 = выкл)
    var rampTime = 0                    // сек плавного разгона (slew)

    init() {}
    // Устойчивый декодер: недостающие ключи берутся из значений по умолчанию.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(String.self, forKey: .name) { name = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .mode) { mode = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .rpm) { rpm = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .sensorKey) { sensorKey = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .tempLow) { tempLow = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .tempHigh) { tempHigh = v }
        if let v = try c.decodeIfPresent([String].self, forKey: .alertSensorKeys) { alertSensorKeys = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .alertTemp) { alertTemp = v }
        if let v = try c.decodeIfPresent([CurvePoint].self, forKey: .curvePoints) { curvePoints = v }
        if let v = try c.decodeIfPresent([FanSettingD].self, forKey: .perFan) { perFan = v }
        if let v = try c.decodeIfPresent([String].self, forKey: .curveSensorKeys) { curveSensorKeys = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .idleHandoffTemp) { idleHandoffTemp = v }
        if let v = try c.decodeIfPresent(Int.self, forKey: .rampTime) { rampTime = v }
    }

    /// Эффективная настройка вента f: per-fan override или глобальные поля. Зеркалит FanProfile.setting(forFan:).
    func effectiveSetting(_ f: Int) -> FanSettingD {
        if f >= 0, f < perFan.count { return perFan[f] }
        var s = FanSettingD()
        s.mode = mode; s.rpm = rpm
        s.sensorKeys = curveSensorKeys.isEmpty ? [sensorKey] : curveSensorKeys
        s.tempLow = tempLow; s.tempHigh = tempHigh
        s.curvePoints = curvePoints
        s.idleHandoffTemp = idleHandoffTemp
        return s
    }
}

let gSMC = SMC()

// Определить количество вентиляторов с учётом fanless-моделей.
// FNum может отсутствовать на некоторых моделях — это не ошибка.
let gFanCount: Int = {
    guard gSMC.available else { return 0 }
    // Попробовать прочитать FNum. Если ключ отсутствует или равен 0 — это может быть fanless Mac.
    if let fnum = gSMC.read("FNum"), fnum > 0 {
        return Int(fnum)
    }
    // Fallback: проверить наличие хотя бы одного F0Ac.
    if let ac = gSMC.read("F0Ac"), ac > 1 {
        return 1  // Минимум один вентилятор обнаружен
    }
    return 0  // Вентиляторы не обнаружены (fanless или данные недоступны)
}()
var gProfilePath = ""
var gFollowConsoleUser = false
var gDry = false
var gSignalSources: [DispatchSourceSignal] = []

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

func restoreFansAuto() { gSMC.write("FS! ", 0) }            // снять ручной режим вентиляторов
func restoreAll() { gSMC.write("FS! ", 0); gSMC.write("BCLM", 100) }   // + снять лимит заряда

/// LaunchDaemon один на систему, а конфигурация принадлежит активному пользователю.
/// Не фиксируем home того, кто установил helper: при Fast User Switching безопасно
/// переключаемся на профиль текущего console-user.
func refreshConsoleUserProfile() -> Bool {
    guard gFollowConsoleUser else { return !gProfilePath.isEmpty }
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: "/dev/console"),
          let user = attrs[.ownerAccountName] as? String,
          !user.isEmpty,
          !["root", "loginwindow", "_mbsetupuser"].contains(user),
          let home = NSHomeDirectoryForUser(user)
    else {
        gProfilePath = ""
        return false
    }
    let next = (home as NSString)
        .appendingPathComponent("Library/Application Support/Kelvin/fan-profile.json")
    if next != gProfilePath {
        gProfilePath = next
        log("активный пользователь: \(user); profile=\(next)")
    }
    return true
}

// ── charge config (обратно совместима с {"limit":N}) ─────────────────────────
// Расширенная конфигурация лимита заряда. Демон пишет ТОЛЬКО ключ BCLM [50,100].
// Режимы: "limit" (фикс. потолок) | "sail" (гистерезисная полоса). Поверх — оверлеи
// heat-protection (перегрев батареи TB0T → понижаем потолок) и top-up (временно BCLM=100).
struct ChargeCfg: Codable {
    var limit = 100            // legacy-потолок для mode=="limit"; его же чтит старый демон
    var mode = "limit"         // "limit" | "sail"
    var sailUpper = 80
    var sailLower = 70
    var heatProtect = false    // оверлей: пауза заряда при перегреве (TB0T)
    var heatTemp = 35          // °C — порог включения паузы
    var topUpUntil = 0.0       // epoch-секунды; 0 = выкл. (разовый «зарядить сейчас»)
    // Плановый дозаряд «полный к времени» (honest: только пока Mac бодрствует; демон спящего не будит).
    var topUpDaily = false     // включён ли суточный оконный дозаряд
    var topUpTargetMin = 420   // минуты локального дня цели (7:00 = 420)
    var topUpLeadMin = 60      // за сколько минут до цели начинать поднимать до 100%
    init() {}
    // Устойчивый декодер: недостающие ключи → значения по умолчанию (декодит старый {"limit":N}).
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        if let v = try c.decodeIfPresent(Int.self,    forKey: .limit)          { limit = v }
        if let v = try c.decodeIfPresent(String.self, forKey: .mode)           { mode = v }
        if let v = try c.decodeIfPresent(Int.self,    forKey: .sailUpper)      { sailUpper = v }
        if let v = try c.decodeIfPresent(Int.self,    forKey: .sailLower)      { sailLower = v }
        if let v = try c.decodeIfPresent(Bool.self,   forKey: .heatProtect)    { heatProtect = v }
        if let v = try c.decodeIfPresent(Int.self,    forKey: .heatTemp)       { heatTemp = v }
        if let v = try c.decodeIfPresent(Double.self, forKey: .topUpUntil)     { topUpUntil = v }
        if let v = try c.decodeIfPresent(Bool.self,   forKey: .topUpDaily)     { topUpDaily = v }
        if let v = try c.decodeIfPresent(Int.self,    forKey: .topUpTargetMin) { topUpTargetMin = v }
        if let v = try c.decodeIfPresent(Int.self,    forKey: .topUpLeadMin)   { topUpLeadMin = v }
    }
}

let gChargeFloor = 50          // никогда не пишем BCLM ниже (совпадает со старым клампом)
let gHeatCap     = 50          // BCLM при перегреве батареи (захардкожено, = пол)
let gHeatHystC   = 3           // °C мёртвая зона снятия паузы по перегреву (захардкожено)
var gLastBCLM    = 100         // память гистерезиса для парусной полосы (только sail!)
var gWasSail     = false       // был ли предыдущий тик в sail-режиме (изоляция гистерезиса)
var gWasHot      = false       // память гистерезиса для перегрева

func clampi(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }

// Файл user-writable → root валидирует жёстко (как sanitize() для профиля вентиляторов).
func sanitizeCharge(_ raw: ChargeCfg) -> ChargeCfg {
    var c = raw
    if !["limit", "sail"].contains(c.mode) { c.mode = "limit" }
    c.limit     = clampi(c.limit,     gChargeFloor, 100)
    c.sailLower = clampi(c.sailLower, gChargeFloor, 100)
    c.sailUpper = clampi(c.sailUpper, gChargeFloor, 100)
    if c.sailUpper < c.sailLower + 5 { c.sailUpper = min(100, c.sailLower + 5) }  // реальная полоса ≥5
    c.heatTemp  = clampi(c.heatTemp, 30, 45)
    let now = Date().timeIntervalSince1970
    if c.topUpUntil > now + 86_400 { c.topUpUntil = now + 86_400 }   // отсечь подделанное далёкое будущее
    if c.topUpUntil < 0 { c.topUpUntil = 0 }
    c.topUpTargetMin = clampi(c.topUpTargetMin, 0, 1439)            // минута локального дня [00:00,23:59]
    c.topUpLeadMin   = clampi(c.topUpLeadMin, 1, 720)              // фора 1 мин … 12 ч
    return c
}

// Минута локального дня [0,1439] сейчас. Root-демон: TimeZone.current читает системную зону.
func localMinuteOfDay() -> Int {
    let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
    return (c.hour ?? 0) * 60 + (c.minute ?? 0)
}

// В суточном окне [start,end] (обе — минуты дня)? Обрабатываем переход через полночь (start > end).
func inDailyWindow(_ m: Int, _ start: Int, _ end: Int) -> Bool {
    start <= end ? (m >= start && m <= end) : (m >= start || m <= end)
}

func loadChargeCfg() -> ChargeCfg {
    let p = (gProfilePath as NSString).deletingLastPathComponent + "/charge-limit.json"
    guard let data = FileManager.default.contents(atPath: p),
          let c = try? JSONDecoder().decode(ChargeCfg.self, from: data) else { return ChargeCfg() }
    return sanitizeCharge(c)
}

// Минимальное чтение % заряда — верный подмножество Sources/BatteryReader.swift (детект AS vs Intel).
// nil при отсутствии батареи / нечитаемости (десктоп, транзиент) → вызывающий fail-safe.
func readChargePct() -> Int? {
    let svc = IOServiceGetMatchingService(ioPort(), IOServiceMatching("AppleSmartBattery"))
    guard svc != 0 else { return nil }
    defer { IOObjectRelease(svc) }
    var um: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(svc, &um, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dict = um?.takeRetainedValue() as? [String: Any] else { return nil }
    func i(_ k: String) -> Int { (dict[k] as? NSNumber)?.intValue ?? 0 }
    let pctCur = i("CurrentCapacity")
    let pctMax = max(i("MaxCapacity"), 1)
    let rawMax = i("AppleRawMaxCapacity")
    let percentScale = pctMax <= 100 && rawMax > 0      // Apple Silicon: CurrentCapacity уже %
    let pct = percentScale ? pctCur : Int((Double(pctCur) / Double(pctMax) * 100).rounded())
    return max(0, min(100, pct))
}

// Решение на итерацию → BCLM к записи, всегда в [gChargeFloor,100]. ТОЛЬКО BCLM.
func computeBCLM(_ cfg: ChargeCfg) -> Int {
    let charge = readChargePct()                        // nil ⇒ нет батареи / нечитаемо
    let now = Date().timeIntervalSince1970

    // 1) базовая цель из режима
    var target: Int
    switch cfg.mode {
    case "sail":
        if let ch = charge {
            if ch >= cfg.sailUpper      { target = cfg.sailLower }   // достигли верха → кап, дрейф при работе
            else if ch <= cfg.sailLower { target = cfg.sailUpper }   // низ → разрешаем дозаряд
            else {
                // Внутри полосы → держим последнее решение. НО gLastBCLM накапливался
                // во всех режимах (limit/top-up могли оставить 100 или 50) → первый вход
                // в sail давал непредсказуемый target. Изолируем: если предыдущий тик был
                // НЕ sail (или первый запуск), стартуем с безопасного sailUpper — разрешаем
                // заряд до верха полосы, а не до чужого остатка.
                target = gWasSail ? gLastBCLM : cfg.sailUpper
            }
        } else {
            target = cfg.limit                                       // нет данных о заряде → простой потолок
        }
        gWasSail = true
    default: // "limit"
        target = cfg.limit
        gWasSail = false        // не sail → сбрасываем, чтобы при возврате в sail gLastBCLM не протекал
    }

    // 2) оверлей перегрева (гистерезис включения/снятия; nil-темп ⇒ FAIL SAFE = не горячо)
    if cfg.heatProtect {
        let temp = gSMC.read("TB0T")                    // общий SMC; nil если сенсора нет
        var hot = gWasHot
        if let t = temp {
            if t >= Double(cfg.heatTemp)                  { hot = true }
            else if t <= Double(cfg.heatTemp - gHeatHystC){ hot = false }
            // иначе мёртвая зона → держим прежнее gWasHot
        } else {
            hot = false                                 // нет темп → никогда не капаем по фантомному перегреву
        }
        gWasHot = hot
        if hot { target = min(target, gHeatCap) }       // только ПОНИЖАЕТ — безопасное направление
    }

    // 3) оверлей top-up (временно BCLM=100; истечение ИЛИ заряд достигнут; переживает рестарт демона)
    let topUpActive = cfg.topUpUntil > now && (charge ?? 0) < 100
    if topUpActive { target = 100 }                     // только ПОВЫШАЕТ до 100 — безопасное значение

    // 3b) плановый дозаряд «полный к времени»: суточное окно [цель−фора, цель]. Пока Mac бодрствует
    //     (демон исполняется) и заряд < 100 — поднимаем до 100. ТОЛЬКО ВВЕРХ. Спящий Mac не будим —
    //     это честная граница фичи (окно повторяется каждый день само, без epoch).
    //     УВАЖАЕТ защиту от перегрева: БЕЗ НАДЗОРА не форсируем 100 на горячей батарее (в отличие от
    //     разового top-up выше, где пользователь рядом и выбрал сам). gWasHot уже посчитан в шаге 2.
    if cfg.topUpDaily, (charge ?? 0) < 100, !(cfg.heatProtect && gWasHot) {
        let start = (cfg.topUpTargetMin - cfg.topUpLeadMin + 1440) % 1440
        if inDailyWindow(localMinuteOfDay(), start, cfg.topUpTargetMin) { target = 100 }
    }

    // 4) финальный кламп + запоминание для гистерезиса (только в sail-режиме)
    let bclm = clampi(target, gChargeFloor, 100)
    if cfg.mode == "sail" { gLastBCLM = bclm }
    return bclm
}

func loadProfile() -> ProfileD {
    guard !gProfilePath.isEmpty,
          let data = FileManager.default.contents(atPath: gProfilePath),
          let p = try? JSONDecoder().decode(ProfileD.self, from: data) else { return ProfileD() }
    return sanitize(p)
}

// Конфиг лежит в user-writable файле — root применять его вслепую нельзя. Жёстко валидируем:
// режим из белого списка, ключи сенсоров — только температурные 4CC (T-префикс, печатаемый ASCII),
// числа — в физичных диапазонах. Защищает от подмены JSON сторонним процессом
// (произвольные SMC-READ по sensorKey, абсурдные обороты/лимиты).
// Температурный 4CC-ключ: 4 символа, T-префикс, печатаемый ASCII. Whitelist против произвольных SMC-READ.
func validTempKey(_ k: String) -> Bool {
    k.count == 4 && k.hasPrefix("T") && k.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 32 && $0.value < 127 }
}

// Санитайз ОДНОЙ per-fan настройки (те же клампы/whitelist, что и глобальные поля).
func sanitizeSetting(_ raw: FanSettingD) -> FanSettingD {
    var s = raw
    if !["auto", "constant", "curve"].contains(s.mode) { s.mode = "auto" }
    s.sensorKeys = s.sensorKeys.filter(validTempKey)
    if s.sensorKeys.isEmpty { s.sensorKeys = ["TC0P"] }
    s.rpm      = min(7000, max(0, s.rpm))
    s.tempLow  = min(110, max(0, s.tempLow))
    s.tempHigh = min(120, max(s.tempLow + 1, s.tempHigh))
    s.idleHandoffTemp = min(90, max(0, s.idleHandoffTemp))
    s.curvePoints = sanitizeCurve(s.curvePoints)
    return s
}

func sanitize(_ raw: ProfileD) -> ProfileD {
    var p = raw
    if !["auto", "constant", "curve"].contains(p.mode) { p.mode = "auto" }
    if !validTempKey(p.sensorKey) { p.sensorKey = "TC0P" }
    p.alertSensorKeys = p.alertSensorKeys.filter(validTempKey)
    p.rpm      = min(7000, max(0, p.rpm))
    p.tempLow  = min(110, max(0, p.tempLow))
    p.tempHigh = min(120, max(p.tempLow + 1, p.tempHigh))
    p.alertTemp = min(115, max(40, p.alertTemp))
    p.curvePoints = sanitizeCurve(p.curvePoints)
    // — новые поля: тот же жёсткий whitelist/кламп (root не доверяет user JSON) —
    p.curveSensorKeys = p.curveSensorKeys.filter(validTempKey)
    p.idleHandoffTemp = min(90, max(0, p.idleHandoffTemp))
    p.rampTime = min(300, max(0, p.rampTime))
    p.perFan = p.perFan.map(sanitizeSetting)
    return p
}

// Валидация многоточечной кривой (JSON user-writable → root жёстко чистит): кламп temp[0,120]/rpm[0,7000],
// сорт по temp, дедуп одинаковых temp (макс rpm), МОНОТОННО-НЕУБЫВАЮЩИЙ rpm (горячее НИКОГДА не медленнее —
// безопасность охлаждения), не более 5 точек. Меньше 2 валидных → [] (демон падает на легаси 2-точки).
func sanitizeCurve(_ pts: [CurvePoint]) -> [CurvePoint] {
    var p = pts.map { CurvePoint(temp: clampi($0.temp, 0, 120), rpm: clampi($0.rpm, 0, 7000)) }
    p.sort { $0.temp < $1.temp }
    var dedup: [CurvePoint] = []
    for pt in p {
        if let last = dedup.last, last.temp == pt.temp { dedup[dedup.count - 1].rpm = max(last.rpm, pt.rpm) }
        else { dedup.append(pt) }
    }
    p = Array(dedup.prefix(5))
    if p.count >= 2 { for i in 1..<p.count { p[i].rpm = max(p[i].rpm, p[i - 1].rpm) } }
    return p.count >= 2 ? p : []
}

// Интерполяция кривой temp→rpm: линейно между соседними, ПЛАТО за краями, затем кламп в [lo,hi] вентилятора.
// `points` уже санитизированы (sorted+monotonic). Обязана совпадать с FanController.curveRPM (app-превью).
func curveRPMFand(_ points: [CurvePoint], _ temp: Double, _ lo: Double, _ hi: Double) -> Double {
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
    return clamp(rpm, lo, hi)
}

// Heartbeat-«аренда»: пока приложение живо, оно обновляет mtime конфигов (FanController.refreshLease).
// Если приложение исчезло (краш/удаление/SIGKILL), файлы «протухают» за это окно и демон сам
// возвращает авто-режим — вентиляторы не остаются форсированными по последнему профилю навсегда.
let gLeaseSeconds: TimeInterval = 900       // 15 мин; приложение касается раз в ~2 мин → запас 7×

func fileFresh(_ path: String) -> Bool {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let m = attrs[.modificationDate] as? Date else { return false }
    return Date().timeIntervalSince(m) <= gLeaseSeconds
}

// Slew-состояние: последняя ЗАПИСАННАЯ цель каждого вента — для плавного разгона (rampTime).
var gLastFanTarget: [Int: Double] = [:]

// Ведущая температура набора датчиков — max-of (безопасно: не недоохладит); nil если ВСЕ недоступны.
func leadingTempD(_ keys: [String]) -> Double? { keys.compactMap { gSMC.read($0) }.max() }

// Сработал ли алерт (по alertSensorKeys / кристаллу CPU/GPU) — форс макс. Едино для constant и curve.
func alertActiveD(_ p: ProfileD) -> Bool {
    let keys = p.alertSensorKeys.isEmpty ? ["TCXC", "TC0E", "TG0D"] : p.alertSensorKeys
    for k in keys { if let tv = gSMC.read(k), tv >= Double(p.alertTemp) { return true } }
    return false
}

// STEADY-STATE цели ТОЛЬКО управляемых вентов (per-fan). Венты в auto / idle-отдаче / со всеми nil-датчиками
// ОМИТЯТСЯ → не попадают в маску FS! → ими рулит система. alert=true → форс макс (минует idle/slew).
// Зеркалит FanController.targetRPM (steady-state); slew применяется ОТДЕЛЬНО в главном цикле поверх цели.
func computeTargets(_ p: ProfileD) -> [Int: (rpm: Double, alert: Bool)] {
    var out: [Int: (rpm: Double, alert: Bool)] = [:]
    let alert = alertActiveD(p)
    for f in 0..<gFanCount {
        let mn = gSMC.read("F\(f)Mn") ?? 1500
        let mx = gSMC.read("F\(f)Mx") ?? 6000
        let s = p.effectiveSetting(f)
        if s.mode == "auto" { continue }                                   // вент — системе
        if alert { out[f] = (mx, true); continue }                         // алерт → форс макс (минует idle/slew)
        if s.idleHandoffTemp > 0, let lead = leadingTempD(s.sensorKeys), lead < Double(s.idleHandoffTemp) { continue }  // idle → системе
        var t: Double
        switch s.mode {
        case "constant":
            t = Double(s.rpm)
        case "curve":
            guard let temp = leadingTempD(s.sensorKeys) else { continue }  // все датчики nil → системе
            if s.curvePoints.count >= 2 {                     // многоточечная (уже санитизирована в loadProfile)
                t = curveRPMFand(s.curvePoints, temp, mn, mx)
            } else {                                          // легаси 2-точечная линейка
                let lo = Double(s.tempLow), hi = Double(max(s.tempHigh, s.tempLow + 1))
                t = mn + (mx - mn) * clamp((temp - lo) / (hi - lo), 0, 1)
            }
        default:
            continue
        }
        out[f] = (clamp(t, mn, mx), false)
    }
    return out
}

@main
struct Fand {
    static func main() {
        var i = 1
        let a = CommandLine.arguments
        while i < a.count {
            switch a[i] {
            case "--profile": if i + 1 < a.count { gProfilePath = a[i + 1]; i += 1 }
            case "--follow-console-user": gFollowConsoleUser = true
            case "--dry-run": gDry = true
            default: break
            }
            i += 1
        }

        guard gSMC.available else { log("SMC недоступен"); exit(1) }
        // На fanless Mac этот service всё равно нужен для BCLM. Отсутствие
        // вентиляторов отключает только fan-policy, но не charge-policy.
        if gFanCount == 0 { log("Вентиляторов нет; работает только управление зарядом") }

        // восстановление системного режима при остановке (launchctl unload шлёт SIGTERM; SIGHUP — на всякий)
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler { if !gDry { restoreAll() }; exit(0) }
            src.resume()
            gSignalSources.append(src)
        }

        log("fand старт: fans=\(gFanCount) dry=\(gDry) profile=\(gProfilePath)")
        while true {
            guard refreshConsoleUserProfile() else {
                if !gDry { restoreAll() }
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            // лимит заряда: если конфиг «протух» (приложение исчезло) — снимаем лимит (100 = безопасно)
            let chargePath = (gProfilePath as NSString).deletingLastPathComponent + "/charge-limit.json"
            let limit = fileFresh(chargePath) ? computeBCLM(loadChargeCfg()) : 100   // протухшая аренда ⇒ 100
            if gDry { if limit < 100 { log("[dry] BCLM→\(limit)") } } else { gSMC.write("BCLM", Double(limit)) }

            // вентиляторы
            var p = loadProfile()
            // аренда: профиль «протух» → контроллер мёртв → авто (не форсируем по старому профилю вечно)
            if p.mode != "auto", !fileFresh(gProfilePath) {
                log("профиль не обновлялся > \(Int(gLeaseSeconds))с → авто-режим")
                p.mode = "auto"
            }
            // (Глобальная sensor-nil проверка убрана: computeTargets теперь per-fan — вент с недоступными
            //  датчиками ОМИТЯТСЯ индивидуально; если омитятся все → tg пуст → restoreFansAuto ниже.)
            if p.mode == "auto" {
                if !gDry { restoreFansAuto() }
                gLastFanTarget.removeAll()                     // возврат из auto → slew стартует с факта
            } else {
                let tg = computeTargets(p)
                if tg.isEmpty {
                    if !gDry { restoreFansAuto() }             // ни один вент не под контролем (все auto/idle/nil) → системе
                    gLastFanTarget.removeAll()
                } else {
                    var mask = 0
                    for f in tg.keys { mask |= (1 << f) }
                    let dt = 2.0                               // шаг цикла (сек) = Thread.sleep ниже
                    var applied: [Int: Double] = [:]
                    for (f, v) in tg {
                        let mn = gSMC.read("F\(f)Mn") ?? 1500
                        let mx = gSMC.read("F\(f)Mx") ?? 6000
                        var next: Double
                        if v.alert || p.rampTime <= 0 {
                            next = v.rpm                        // алерт / без разгона — сразу к цели
                        } else {
                            let last = gLastFanTarget[f] ?? (gSMC.read("F\(f)Ac") ?? v.rpm)   // 1-й тик: старт с факта
                            let step = (mx - mn) * (dt / Double(p.rampTime))                 // об за тик (полный диапазон за rampTime сек)
                            next = last + clamp(v.rpm - last, -step, step)
                        }
                        applied[f] = clamp(next, mn, mx)
                    }
                    gLastFanTarget = applied                   // помним только текущих управляемых; вышедшие — забыты
                    if gDry {
                        let line = applied.sorted { $0.key < $1.key }.map { "F\($0.key)→\(Int($0.value))" }.joined(separator: " ")
                        log("[dry] «\(p.name)» mode=\(p.mode) mask=\(mask) ramp=\(p.rampTime) \(line)")
                    } else {
                        gSMC.write("FS! ", Double(mask))
                        for (f, t) in applied { gSMC.write("F\(f)Tg", t) }
                    }
                }
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }
}
