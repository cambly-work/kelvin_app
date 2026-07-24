import Foundation

/// Поток по одной шине-потребителю.
struct RailFlow {
    let name: String
    let amps: Double          // А
    let volts: Double?        // В (если известно)
    var watts: Double? { volts.map { $0 * amps } }
}

/// Направление потока батареи для диаграммы — три состояния с гистерезисом (см. EnergyModel).
/// `.idle` — равновесие на адаптере (ток у нуля): провод спокойный, без анимации заряда/разряда.
enum BatteryFlow { case charging, discharging, idle }

/// Полный снимок энергопотока для диаграммы.
struct EnergySnapshot {
    var hasSMC: Bool = false

    // батарея
    var battVolts: Double = 0
    var battAmps: Double = 0        // знаковый: + заряд / − разряд (сырой — для числовых показов/тултипов)
    var charging: Bool = false      // grl: знак тока (для иконки/дампа); для ПОТОКА — battFlow с гистерезисом
    /// Стабильное направление потока с дедбэндом — чтобы провод не моргал заряд↔разряд у равновесия.
    var battFlow: BatteryFlow = .idle
    var battWatts: Double = 0       // |V·A|
    var cells: [Double] = []
    var battTemp: Double?

    // адаптер (DC-in)
    var adapterVolts: Double = 0
    var adapterAmps: Double = 0
    var adapterWatts: Double = 0          // ЖИВОЙ замер отдачи (SMC PDTR)
    var adapterRatedWatts: Int?           // НОМИНАЛ из IOKit (паспорт PD-профиля), nil если недоступно
    var adapterName: String?              // имя/модель адаптера, если ОС его отдаёт
    var plugged: Bool = false

    // потребители
    var rails: [RailFlow] = []

    // термика
    var cpuTemp: Double?
    var gpuTemp: Double?
    var fans: [Double] = []         // об/мин

    /// Прямой замер полного потребления системы (PSTR), если доступен.
    var systemWattsRaw: Double?

    // — ЖИВОЙ ОТКЛИК (облик B «живой прибор»). Вычисляемый слой ПОВЕРХ systemWatts: сам systemWatts /
    //   two-numbers / battFlow НЕ трогаем. Лечит «яркость тише — потребление как было»: отклик идёт от
    //   ДЕЛЬТЫ к скользящему фону, а не от абсолюта, поэтому Δ2-6 Вт от подсветки становятся видимы.
    /// Скользящий EMA расхода (τ≈18 с) — «спокойный фон» системы. 0 пока не инициализирован.
    var systemBaselineWatts: Double = 0
    /// (systemWatts − baseline) ПОСЛЕ дедбэнда. Знаковый: рост нагрузки → >0, спад → <0, у нуля → 0.
    /// Это «честная дельта» для усиления в визуальную амплитуду (аура/пульс/глубина).
    var loadDelta: Double = 0
    /// Яркость экрана 0..1 (DisplayServicesGetBrightness, root-free). −1 = канал недоступен.
    var screenBrightness: Float = -1
    /// Δ яркости с прошлого тика ПОСЛЕ дедбэнда — причинный канал для «толчка» на движение ползунка.
    var brightnessDelta: Float = 0

    /// Сколько суммарно потребляет система (Вт) — ЧЕСТНОЕ основное число хаба.
    ///
    /// ДВА ЧИСЛА — ОДНА ПРАВДА. PSTR (прямой замер полного потребления) и энергобаланс источников
    /// (`systemWattsBalance`) — независимые величины с разной калибровкой; у равновесия они расходятся
    /// на пару ватт, а в одном режиме — на ~2×. Скриншот владельца поймал именно это: хаб показывал
    /// баланс «адаптер + помощь АКБ» ≈ 62 Вт, а PSTR-замер ≈ 31 Вт. Баланс в режиме «на адаптере +
    /// разряд» СКЛАДЫВАЕТ adapterWatts и battWatts, но у равновесия знак тока B0AC дрожит в минус
    /// (артефакт измерения / КПД заряда), и тогда «помощь батареи» — фантом: система не ест 62 Вт.
    ///
    /// РЕШЕНИЕ (бренд = калиброванная честность): основным числом берём ПРЯМОЙ ЗАМЕР PSTR, когда он
    /// есть, — это калиброванный сенсор полного потребления, ему доверяем. Энергобаланс остаётся как
    /// `systemWattsBalance` для СВЕРКИ (тик примирения + строка разбора), а не как основное число —
    /// чтобы пользователь никогда не видел два противоречивых необъяснённых ватта. PSTR недоступен →
    /// честно падаем на баланс источников (иначе хаб был бы пустым).
    var systemWatts: Double {
        if let m = systemWattsRaw, m > 0.05 { return m }
        return systemWattsBalance
    }
    /// Энергобаланс источников (Вт) — ПРОИЗВОДНАЯ величина для сверки, НЕ основное число хаба.
    ///   • на батарее: система = разряд батареи (единственный источник);
    ///   • на адаптере + заряд: система = вход адаптера − мощность заряда;
    ///   • на адаптере + разряд (адаптер не тянет): система = адаптер + помощь батареи.
    var systemWattsBalance: Double {
        if plugged, adapterWatts > 0.5 {
            return charging ? max(adapterWatts - battWatts, 0) : adapterWatts + battWatts
        }
        if !plugged, battWatts > 0.05 { return battWatts }
        return systemWattsRaw ?? 0
    }
    /// Прямой замер PSTR (для подписи/сверки) — может слегка расходиться с балансом из-за потерь.
    var systemWattsMeasured: Double? { systemWattsRaw }
    /// Суммарный ток потребителей (А) — для масштабирования потоков.
    var railAmpsTotal: Double { rails.reduce(0) { $0 + $1.amps } }
}

enum EnergyModel {
    static let smc = SMC()

    // Гистерезис направления потока батареи (B1). SMC B0AC — знаковый ток в мА с шумом ±несколько мА;
    // на адаптере у равновесия он дрожит около нуля, и сырой порог `>0` дёргал бы провод заряд↔разряд
    // каждую секунду. Держим ПРЕДЫДУЩЕЕ состояние и переключаемся только за порогом дедбэнда:
    //   • → .charging    при battAmps > +0.05 А
    //   • → .discharging при battAmps < −0.05 А
    //   • → .idle        когда |battAmps| < 0.03 А держится несколько подряд (idleHold)
    //   • иначе          ДЕРЖИМ прошлое состояние (мёртвая зона между порогами).
    //
    // B2 — учёт состояния адаптера. На зарядке батарею держит/заряжает адаптер; кратковременный
    // скачок нагрузки на долю секунды загоняет B0AC в минус (батарея «подкидывает» ток), и симметричный
    // порог тут же читал бы это как .discharging → провод моргал заряд↔разряд. Когда plugged == true,
    // переходим в .discharging только после УСТОЙЧИВОЙ просадки (dischargeStreak ≥ dischargeNeed подряд
    // ниже явного минуса), иначе держим .charging/.idle. На батарее (plugged == false) разряд — норма,
    // оставляем прежнюю отзывчивую симметричную логику без стрика.
    private static var prevFlow: BatteryFlow = .idle
    private static var idleHold = 0
    private static let idleNeed = 2          // сколько подряд тихих сэмплов нужно, чтобы признать .idle
    private static var dischargeStreak = 0   // подряд сэмплов явной просадки на адаптере (B2)
    private static let dischargeNeed = 3     // сколько подряд нужно, чтобы признать .discharging на адаптере

    // Паспорт адаптера (номинал/имя) — статичен, пока тот же адаптер воткнут. Кэшируем и перечитываем
    // ТОЛЬКО на переходе «не воткнут → воткнут», чтобы IOPSCopy… не вызывался каждый тик впустую
    // (это делает обещание AdapterInfo «меняется только на вставке/выемке» правдой на месте вызова).
    private static var adapterPassport: AdapterInfo.Reading?
    private static var wasPlugged = false

    // — ЖИВОЙ ОТКЛИК: скользящий baseline PSTR + дедбэнд дельты + причинный канал яркости. —
    // baseline = EMA расхода τ≈18 с (живёт ровно сессию, БЕЗ диск-персиста — как SensorsModel.peakTemp).
    // Отклик вида берётся из (systemWatts − baseline), а не из абсолюта: иначе Δ2-6 Вт от подсветки
    // тонут в десятках ватт фона и «яркость тише — потребление как было». Дедбэнд на дельте (как
    // гистерезис batteryFlow) держит 0 у равновесия — без него PSTR/B0AC дрожали бы ±1 Вт и прибор
    // «дышал сам по себе» = мнимая отзывчивость = НЕЧЕСТНО.
    private static var pstrBaseline: Double = .nan   // .nan = ещё не инициализирован (первый сэмпл сядет на w)
    private static let baselineTau: Double = 18.0    // сек; tick=1с → α = 1 − exp(−1/18) ≈ 0.054
    private static let loadDeadband: Double = 1.2    // Вт: |Δ| ниже → отклик 0 (джиттер у нуля)
    private static var prevBrightness: Float = -1
    private static let brightDeadband: Float = 0.02  // ~2% хода ползунка — ниже считаем шумом

    /// Считает живой отклик ПОВЕРХ уже посчитанного systemWatts. Не меняет основное число —
    /// только заполняет baseline/loadDelta/screenBrightness/brightnessDelta для вида.
    private static func liveResponse(_ s: inout EnergySnapshot) {
        let w = s.systemWatts                                   // честное число (PSTR-приоритет или баланс)
        // EMA τ≈18 с. Первый сэмпл сидит на baseline = w (нет «прыжка из нуля» на старте).
        let alpha = 1 - exp(-1.0 / baselineTau)
        if pstrBaseline.isNaN { pstrBaseline = w }
        else { pstrBaseline += alpha * (w - pstrBaseline) }
        s.systemBaselineWatts = pstrBaseline
        // ДЕДБЭНД на дельте — как гистерезис batteryFlow: у нуля держим 0 (нет мнимого «дыхания»).
        let raw = w - pstrBaseline
        s.loadDelta = abs(raw) < loadDeadband ? 0 : raw
        // ЯРКОСТЬ — ОТДЕЛЬНЫЙ причинный канал (НЕ через темп потока). Δ с дедбэндом.
        let b = ScreenBrightness.available ? ScreenBrightness.get() : -1
        s.screenBrightness = b
        if b >= 0, prevBrightness >= 0 {
            let db = b - prevBrightness
            s.brightnessDelta = abs(db) < brightDeadband ? 0 : db
        } else { s.brightnessDelta = 0 }
        if b >= 0 { prevBrightness = b }
    }

    private static func batteryFlow(amps: Double, plugged: Bool) -> BatteryFlow {
        if plugged {
            // На адаптере: явный плюс → заряд; копим стрик просадки и переключаемся в разряд только
            // когда адаптер устойчиво не тянет (несколько сэмплов ниже чёткого минуса).
            if amps > 0.05 { idleHold = 0; dischargeStreak = 0; prevFlow = .charging; return .charging }
            if amps < -0.12 {
                dischargeStreak += 1
                if dischargeStreak >= dischargeNeed { idleHold = 0; prevFlow = .discharging; return .discharging }
                // кратковременный спайк нагрузки — ещё не разряд, держим прошлое (обычно .charging/.idle)
                return prevFlow
            }
            dischargeStreak = 0              // вышли из явного минуса — спайк закончился, сбрасываем стрик
            if abs(amps) < 0.03 {
                idleHold += 1
                if idleHold >= idleNeed { prevFlow = .idle; return .idle }
            } else {
                idleHold = 0                 // в дедбэнде (0.03…0.05 / −0.12…−0.03) — держим прошлое
            }
            return prevFlow
        }
        // На батарее: разряд — нормальное состояние, держим прежнюю отзывчивую симметричную логику.
        dischargeStreak = 0
        if amps > 0.05 { idleHold = 0; prevFlow = .charging; return .charging }
        if amps < -0.05 { idleHold = 0; prevFlow = .discharging; return .discharging }
        if abs(amps) < 0.03 {
            idleHold += 1
            if idleHold >= idleNeed { prevFlow = .idle; return .idle }
        } else {
            idleHold = 0                     // в дедбэнде (0.03…0.05) — не копим простой, держим прошлое
        }
        return prevFlow                      // мёртвая зона / ещё не выдержали простой → держим прошлое
    }

    static func snapshot() -> EnergySnapshot {
        var s = EnergySnapshot()
        s.hasSMC = smc.available
        guard smc.available else { return s }

        func V(_ k: String) -> Double { (smc.read(k) ?? 0) / 1000.0 }   // мВ → В
        func A(_ k: String) -> Double { (smc.read(k) ?? 0) / 1000.0 }   // мА → А

        // батарея (мощность — прямой ключ B0AP, знак направления — из тока B0AC)
        s.battVolts = V("B0AV")
        s.battAmps  = A("B0AC")                 // si16, знаковый: + заряд / − разряд
        s.charging  = s.battAmps > 0.001        // сырой знак — для иконки/дампа
        s.battWatts = smc.read("B0AP").map { abs($0) } ?? abs(s.battVolts * s.battAmps)
        s.cells     = ["BC1V", "BC2V", "BC3V"].compactMap { smc.read($0) }.map { $0 / 1000.0 }
        s.battTemp  = smc.read("TB0T")

        // адаптер — корректные ключи (заглавная R, фикс-точка В/А) + прямой ватт PDTR.
        // Старые VD0r/ID0r (строчная) на этой модели врут (3.3 В).
        s.adapterVolts = smc.read("VD0R") ?? V("VD0r")
        s.adapterAmps  = smc.read("ID0R") ?? A("ID0r")
        s.adapterWatts = smc.read("PDTR") ?? (s.adapterVolts * s.adapterAmps)
        s.plugged = s.adapterWatts > 0.5 || s.adapterVolts > 5

        // Паспорт адаптера (номинал/имя) из IOKit.ps — честный источник, отдельный от живого PDTR-замера.
        // Читаем на переходе «не воткнут → воткнут» (паспорт статичен, пока адаптер тот же) и пока кэш
        // пуст под воткнутым адаптером (самолечение от разовой nil-выдачи на самой вставке); дальше
        // отдаём кэш — IOPSCopy… не дёргается каждый тик. Выемка чистит кэш.
        if s.plugged {
            if !wasPlugged || adapterPassport == nil { adapterPassport = AdapterInfo.read() }
            if let a = adapterPassport {
                s.adapterRatedWatts = a.watts
                s.adapterName = a.name
            }
        } else {
            adapterPassport = nil
        }
        wasPlugged = s.plugged

        // стабильное направление потока с гистерезисом — для потока (учитывает plugged: см. B2)
        s.battFlow  = batteryFlow(amps: s.battAmps, plugged: s.plugged)

        // полное потребление системы — прямой ключ PSTR
        s.systemWattsRaw = smc.read("PSTR")

        // потребители (амперы; где есть — напряжение шины для ватт).
        // ILDc («Дисплей») НЕ показываем: это сырой некалиброванный токовый рельс SMC без напряжения,
        // на Apple Silicon он почти не меняется с яркостью и читался бы как «мощность дисплея», которой
        // он не является (B6). Честнее опустить, чем выдавать голый ампер за управляемую яркостью мощность.
        s.rails = [
            RailFlow(name: "Память",  amps: A("IM0c"), volts: nil),
            RailFlow(name: "CPU",     amps: A("IC0r"), volts: V("VC0c")),
            RailFlow(name: "GPU",     amps: A("IG0r"), volts: V("VG0c")),
            RailFlow(name: "Прочее",  amps: A("IO5r") + A("IO3r"), volts: nil),
        ].filter { $0.amps > 0.0005 }

        // термика
        s.cpuTemp = smc.read("TC0P")
        s.gpuTemp = smc.read("TG0P")
        s.fans = ["F0Ac", "F1Ac"].compactMap { smc.read($0) }.filter { $0 > 1 }

        // живой отклик — ПОСЛЕ того как systemWatts/баланс полностью определены (зависит от s.systemWatts)
        liveResponse(&s)

        return s
    }
}
