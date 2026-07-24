import Foundation

/// Один сенсор для интерактивной панели «Железо».
struct Sensor {
    enum Kind { case temp, fan, load, power }
    let id: String
    let name: String
    let icon: String          // SF-symbol
    let value: Double
    let text: String          // готовая подпись «62°»
    let level: Double         // 0..1 — для бара и цвета
    let kind: Kind
    let detail: String        // строка разбора при наведении
    var forced: Bool = false  // вентилятор на ручном/форсе (FS!-бит) — показываем бейдж
    var history: [Double] = []// сессионный буфер сэмплов (термокамера): SHAPE нагрева, не одно число
}

/// Сгруппированный снимок сенсоров.
struct SensorsSnapshot {
    var temps: [Sensor] = []
    var fans: [Sensor] = []
    var loads: [Sensor] = []
    var power: [Sensor] = []
    var hasPower: Bool { !power.isEmpty }
}

/// Сбор сенсоров: температуры/вентиляторы — напрямую из SMC (без хелпера),
/// нагрузка — Mach, ватты компонентов — из хелпера (если установлен).
enum SensorsModel {
    static var smc: SMC { EnergyModel.smc }
    private static let lock = NSRecursiveLock()
    private static var ema: [String: Double] = [:]   // сглаживание температур (CPU/GPU), keyed by id
    /// Скользящий максимум/минимум температуры за сессию (keyed by id). Пустые на старте → сбрасываются
    /// при запуске приложения само собой (статик живёт ровно процесс). «Как горячо/холодно было» — оба за СЕССИЮ,
    /// чтобы «мин N° · пик M°» был связным диапазоном (без асимметрии «пик-сессия / мин-окно»).
    private static var peakTemp: [String: Double] = [:]
    private static var lowTemp: [String: Double] = [:]
    /// Кольцевой буфер сэмплов за сессию (keyed by id) — кадры термокамеры/мини-графа. Прямой клон
    /// паттерна peakTemp: пушим раз в тик (1 Гц), держим ~32. На старте короткий → трасса вырождается
    /// в 1–2px культю (читается как прежний бар). Честно: только реально собранные сэмплы, без новых SMC-чтений.
    private static var history: [String: [Double]] = [:]
    private static let histCap = 32
    /// Толкнуть сэмпл в кольцо и вернуть текущую историю id (для отрисовки трассы в чипе).
    /// record:false → НЕ пушим (тёплый прогон перед замером высоты): кольцо двигает только 1Гц-тик,
    /// иначе ребилд по BMPopoverChanged впрыснул бы внеплановый кадр и сдвинул трассу.
    private static func pushHistory(_ id: String, _ v: Double, record: Bool) -> [Double] {
        guard record else { return history[id] ?? [] }
        var h = history[id] ?? []
        h.append(v)
        if h.count > histCap { h.removeFirst(h.count - histCap) }
        history[id] = h
        return h
    }

    /// record:false — прогрев без записи в историю (см. pushHistory): тёплому прогону нужны текущие
    /// значения для замера высоты, а кольцо трассы должно двигаться строго раз в тик (1 Гц).
    static func snapshot(cpuLoad: Double, ramLoad: Double, components: ComponentPower, record: Bool = true) -> SensorsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var s = SensorsSnapshot()
        guard smc.available else { return s }
        func r(_ k: String) -> Double? { smc.read(k) }

        // — температуры (выбираем осмысленные, не свалку) —
        // smooth=true → мягкое EMA: гасит одно-кадровый спайк ядра (PECI скачет на турбо-бусте),
        // но устойчивый нагрев показывает честно. Иначе CPU «пугал» 90° от единичного кадра.
        func temp(_ id: String, _ name: String, _ icon: String, _ keys: [String], smooth: Bool = false) {
            let vals = keys.compactMap { r($0) }.filter { $0 > -40 && $0 < 130 }
            guard var v = vals.max() else { return }
            if smooth {
                v = SensorsModel.ema[id].map { $0 * 0.65 + v * 0.35 } ?? v
                SensorsModel.ema[id] = v
            }
            let lvl = max(0, min(1, (v - 35) / 60))                       // 35°→0, 95°→1
            // сессионный буфер кадров термокамеры: трасса в чипе показывает SHAPE нагрева,
            // а пик помечается зарубкой ПРЯМО на трассе (угловой «↑92°» убран как дубль/шум).
            let hist = SensorsModel.pushHistory(id, v, record: record)
            let peak = max(SensorsModel.peakTemp[id] ?? v, v)
            let lo = min(SensorsModel.lowTemp[id] ?? v, v)
            if record {                                      // оба экстремума двигает только 1Гц-тик, не прогрев
                SensorsModel.peakTemp[id] = peak
                SensorsModel.lowTemp[id] = lo
            }
            // мин/пик ЗА СЕССИЮ (оба из одного окна-сессии) → в разбор-сток: «GPU · 58° · норма · мин 41° · пик 73°».
            // (зарубка на трассе помечает пик ВИДИМОГО буфера ~32с — это маркер трассы, отдельная сущность от текста.)
            let showRange = peak - lo >= 3                                // диапазон полезен, только если он есть
            let detail = "\(name) · \(String(format: "%.0f °C", v)) · \(tempWord(id: id, v))"
                + (showRange ? " · " + String(format: L("мин %.0f°"), lo)
                                + " · " + String(format: L("пик %.0f°"), peak) : "")
            s.temps.append(Sensor(id: id, name: name, icon: icon, value: v,
                                  text: String(format: "%.0f°", v), level: lvl, kind: .temp,
                                  detail: detail, history: hist))
        }
        // «CPU» — РЕАЛЬНАЯ температура кристалла (PECI/ядра), а не сглаженный датчик-близость TC0P:
        // именно по ней процессор греется и троттлит. TC0P (корпус пакета) показываем как «CPU корпус».
        temp("cpu",   "CPU",            "cpu.fill",            ["TCXC","TC0E","TC1C","TC2C","TC3C","TC4C"], smooth: true)
        temp("cpupkg",L("CPU корпус"),  "cpu",                ["TC0P"])
        temp("gpu",   "GPU",            "display",             ["TG0D","TG0P"], smooth: true)
        temp("mem",   L("Память"),      "memorychip.fill",     ["TM0P"])
        temp("pch",   L("Платформа"),   "square.stack.3d.up.fill", ["TPCD"])
        temp("wifi",  "Wi-Fi",          "wifi",                ["TW0P"])
        temp("batt",  L("Батарея"),     "battery.100",         ["TB0T","TB1T","TB2T"])

        // — вентиляторы (текущие + положение между мин/макс) —
        // FS! — битовая маска «какие вентиляторы на ручном/форсе» (бит i = вентилятор i).
        // Если форс есть, обороты НЕ реагируют на нагрев — показываем это бейджем, чтобы не путать.
        let forceMask = Int(r("FS! ") ?? 0)
        for (i, k) in [("F0Ac","F0Mn","F0Mx"), ("F1Ac","F1Mn","F1Mx")].enumerated() {
            guard let cur = r(k.0), cur > 1 else { continue }
            let mn = r(k.1) ?? 0, mx = max(r(k.2) ?? (cur + 1), cur)
            let lvl = mx > mn ? max(0, min(1, (cur - mn) / (mx - mn))) : 0
            let forced = (forceMask & (1 << i)) != 0
            let base = String(format: L("Кулер %d · %.0f об/мин · %.0f%% (от %.0f до %.0f)"), i+1, cur, lvl*100, mn, mx)
            s.fans.append(Sensor(id: "fan\(i)", name: String(format: L("Кулер %d"), i+1), icon: "fanblades.fill", value: cur,
                                 text: String(format: "%.0f", cur), level: lvl, kind: .fan,
                                 detail: forced ? base + " · " + L("ручной режим") : base, forced: forced,
                                 history: SensorsModel.pushHistory("fan\(i)", lvl, record: record)))
        }

        // — нагрузка —
        s.loads.append(Sensor(id: "cpuload", name: "CPU", icon: "gauge.with.dots.needle.67percent", value: cpuLoad,
                              text: String(format: "%.0f%%", cpuLoad*100), level: cpuLoad, kind: .load,
                              detail: String(format: L("Загрузка CPU · %d%%"), Int((cpuLoad*100).rounded())),
                              history: SensorsModel.pushHistory("cpuload", cpuLoad, record: record)))
        s.loads.append(Sensor(id: "ramload", name: L("Память"), icon: "memorychip", value: ramLoad,
                              text: String(format: "%.0f%%", ramLoad*100), level: ramLoad, kind: .load,
                              detail: String(format: L("Память · %d%% занято"), Int((ramLoad*100).rounded())),
                              history: SensorsModel.pushHistory("ramload", ramLoad, record: record)))

        // — ватты компонентов (только если хелпер отдаёт данные) —
        let comps: [(String, String, Double?)] = [("CPU", "cpu.fill", components.cpu),
                                                   ("GPU", "cpu", components.gpu),
                                                   ("DRAM", "memorychip.fill", components.dram)]
        for (n, ic, w) in comps {
            guard let w = w else { continue }
            let plvl = min(1, w/25)
            s.power.append(Sensor(id: "p\(n)", name: n, icon: ic, value: w,
                                  text: String(format: "%.1f %@", w, L("Вт")), level: plvl, kind: .power,
                                  detail: "\(n) · \(String(format: "%.2f %@", w, L("Вт")))",
                                  history: SensorsModel.pushHistory("p\(n)", plvl, record: record)))
        }
        return s
    }

    /// Слово-разбор температуры по ЧЕСТНОМУ per-sensor порогу (Design.sensorLevel по id): на Intel
    /// CPU 88° — «норма» (крит только ≥100°), а батарея 42° — уже «тепло». Слово совпадает с цветом
    /// гейджа (тот теперь тоже красит по sensorLevel), а не с общим 70/85, который вечно кричал «горячо».
    static func tempWord(id: String, _ t: Double) -> String {
        switch Design.sensorLevel(id: id, t) {
        case .ok:   return t < 50 ? L("прохладно") : L("норма")
        case .warn: return L("тепло")
        case .crit: return L("горячо")
        }
    }
}
