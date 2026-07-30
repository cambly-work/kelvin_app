import AppKit

/// Единый источник дизайн-токенов Kelvin — Swift-зеркало `:root` в docs/style.css.
/// Контракт app↔web: акцент #33C7D1 (dark) / #008C99 (light). Рассинхрон значений = баг.
///
/// Правила (Head of Design, 28.06.2026):
/// • один акцент правит интерактивом/навигацией/CTA; семантика OK/Warn/Crit — ТОЛЬКО данные заряда/температур;
/// • токенизируем ПОВЕРХНОСТИ/заливки/кромки, а текст оставляем системным (.labelColor… — vibrancy-aware);
/// • радиус следует за elevation концентрично, все cornerCurve = .continuous;
/// • инфракрасный 4-stop градиент — редкий бренд-жест (иконка/hero), НЕ в UI-фонах.
enum Design {

    // MARK: - Color (поверхности и акцент; текст — системные label-цвета)
    enum Color {
        // Бренд-бирюза «термокамеры», полная шкала состояний (тема-зависимая)
        static func accent(_ dark: Bool) -> NSColor { dark ? srgb(0.20, 0.78, 0.82) : srgb(0.0, 0.55, 0.60) }     // #33C7D1 / #008C99 — канон
        /// Динамическая версия акцента для AppKit-контролов. В отличие от `.controlAccentColor`
        /// не зависит от выбранного пользователем системного accent macOS.
        static let accentAdaptive = NSColor(name: NSColor.Name("KelvinAccent")) { appearance in
            accent(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        }
        static func accentBright(_ dark: Bool) -> NSColor { dark ? hex(0x4DEAEA) : hex(0x1AA8B3) }                  // hover/active, кольцо при charging
        static func accentDeep(_ dark: Bool) -> NSColor { dark ? hex(0x198C9E) : hex(0x006B78) }                   // pressed
        static func accentInk(_ dark: Bool) -> NSColor { dark ? hex(0x0A3342) : srgb(0.0, 0.42, 0.47) }            // тень акцентных слоёв (НЕ грязный accent-ореол)
        static func accentMuted(_ dark: Bool) -> NSColor { accent(dark).withAlphaComponent(dark ? 0.16 : 0.20) }   // фон активной таб-пилюли

        // Поверхности стеклянной плитки (frosted-fill + световая кромка поверх popover-блюра)
        static func surfaceFill(_ dark: Bool) -> NSColor { dark ? white(0.12) : white(0.62) }
        static func surfaceRim(_ dark: Bool) -> NSColor { dark ? white(0.16) : white(0.72) }
        // Заливки контролов и треков
        static func controlFill(_ dark: Bool) -> NSColor { dark ? white(0.07) : black(0.05) }
        static func trackFill(_ dark: Bool) -> NSColor { dark ? white(0.11) : black(0.08) }     // дуга кольца / бар
        static func tabTrack(_ dark: Bool) -> NSColor { dark ? white(0.06) : black(0.04) }       // трек таб-бара

        // Семантика уровней — ТОЛЬКО заряд/температура, никогда не декор
        // V3: тёплые фирменные warn/crit вместо сырых systemOrange/systemRed (те выглядят «системным дефолтом»,
        // а не designed). Значения из утверждённого макета. Амбер редкий → выглядит намеренным сигналом.
        static let levelOK = NSColor.systemGreen, levelWarn = hex(0xF2A03D), levelCrit = hex(0xFF5C61)

        /// Цвет ТЕПЛОВОГО РЕЖИМА для дышащей ауры/акцентов «живого термо-прибора»:
        /// спокоен→бренд-бирюза, нагрузка→янтарь, жара→красный. Уровень уже сглажён вердиктом
        /// (устойчивость tempCritStreak) → аура меняется медленно, без «гирлянды».
        static func stateColor(_ level: Design.Level, _ dark: Bool) -> NSColor {
            switch level { case .ok: return accent(dark); case .warn: return levelWarn; case .crit: return levelCrit }
        }

        // Палитра ЗАРЯДА (B3-дедуп ChargeTrack↔BatteryGauge). Санкционированное семантическое
        // исключение бренд-закона: красный/жёлтый/зелёный/бирюза — это ДАННЫЕ заряда, не декор.
        // ВНИМАНИЕ: цвет-пространство calibratedRGB — НЕ srgb/system (levelOK и др. иные) — не смешивать.
        // Значения побайтно = прежним литералам обоих гейджей → визуал 1-в-1.
        static let chargeTeal = NSColor(calibratedRed: 0.20, green: 0.85, blue: 0.75, alpha: 1)  // зарядка
        static let chargeCrit = NSColor(calibratedRed: 1.0,  green: 0.27, blue: 0.30, alpha: 1)  // <15% красный
        static let chargeWarn = NSColor(calibratedRed: 1.0,  green: 0.74, blue: 0.10, alpha: 1)  // <35% жёлтый
        static let chargeOK   = NSColor(calibratedRed: 0.30, green: 0.85, blue: 0.42, alpha: 1)  // ≥35% зелёный

        /// Нейтральный узел Flow-схемы (потребитель CPU/GPU/Память/Прочее, Система, покоящийся источник):
        /// стеклянная нейтраль БЕЗ декоративного цвета — бренд-закон запрещает «радугу» в схеме.
        /// В светлой теме плотнее, чтобы заголовок/обводка не бледнели на светлом фоне.
        static func neutralNode(_ dark: Bool) -> NSColor { dark ? .secondaryLabelColor : NSColor(white: 0.40, alpha: 1) }

        // Тончайшие нейтральные линии/блики поверх стекла — токенизированы, чтобы свет/тьма шли в ногу.
        /// Волосяная линия (сетка графа, тики) — белая в тёмной теме, чёрная в светлой; alpha задаём.
        static func hairline(_ dark: Bool, _ alpha: CGFloat) -> NSColor { dark ? white(alpha) : black(alpha) }
        /// Светлый блик-кромка (bevel поверх линий/узлов) — всегда белый, alpha тема-зависимая.
        static func rimHighlight(_ dark: Bool, _ alpha: CGFloat) -> NSColor { white(dark ? alpha : alpha * 0.83) }
        /// Мягкий accent-тинт стеклянного чипа/узла (Flow-узел, сенсор-плитка): в светлой теме плотнее.
        static func glassTint(_ accent: NSColor, _ dark: Bool) -> NSColor { accent.withAlphaComponent(dark ? 0.13 : 0.16) }
        /// Accent-кант героя лидерборда (топ-1): единый токен, чтобы app↔web-контракт не разъехался.
        static func accentRim(_ dark: Bool) -> NSColor { accent(dark).withAlphaComponent(0.35) }

        /// `NSColor.labelColor` и другие semantic colors динамические. AppKit-контролы
        /// разрешают их сами, но после преобразования в `CGColor` для CALayer тема теряется.
        /// Этот мост фиксирует цвет в явно заданной appearance перед передачей Core Animation.
        static func resolved(_ color: NSColor, dark: Bool) -> NSColor {
            guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { return color }
            var resolved = color
            appearance.performAsCurrentDrawingAppearance {
                resolved = color.usingColorSpace(.deviceRGB) ?? color
            }
            return resolved
        }
    }

    /// Канонический порог температуры (°C → уровень): ~70° warn / ~85° crit.
    /// ЕДИНЫЙ источник — и цвет чипа, и слово-разбор берут отсюда, чтобы не расходились.
    enum Level { case ok, warn, crit }
    static func tempLevel(_ c: Double) -> Level { c < 70 ? .ok : (c < 85 ? .warn : .crit) }
    static func rank(_ l: Level) -> Int { l == .crit ? 2 : (l == .warn ? 1 : 0) }

    /// Класс датчика (по логическому id из SensorsModel) — чтобы пороги были ЧЕСТНЫМИ: на Intel
    /// CPU рутинно 85–95° под нагрузкой (троттл ~100°) — это НЕ «перегрев», а батарея 45° — уже да.
    /// Единый глобальный порог 70/85 давал вечный «Перегрев». Разводим по физике каждого датчика.
    enum SensorClass { case cpu, gpu, battery, generic }
    static func sensorClass(id: String) -> SensorClass {
        switch id {
        case "cpu", "cpupkg": return .cpu
        case "gpu":           return .gpu
        case "batt":          return .battery
        default:              return .generic     // память/платформа/wifi и прочее
        }
    }
    /// Честный уровень датчика по его классу. CPU крит только у самого троттла (≥100°), батарея — ≥45°.
    static func sensorLevel(id: String, _ c: Double) -> Level {
        switch sensorClass(id: id) {
        case .cpu:     return c < 90 ? .ok : (c < 100 ? .warn : .crit)
        case .gpu:     return c < 87 ? .ok : (c < 97 ? .warn : .crit)
        case .battery: return c < 40 ? .ok : (c < 45 ? .warn : .crit)
        case .generic: return c < 80 ? .ok : (c < 95 ? .warn : .crit)
        }
    }

    // MARK: - Typography (роль → NSFont; числа — моноширинные)
    enum Font {
        static let display   = sys(28, .bold)       // крупные числа / заголовок настроек
        static let title     = sys(22, .semibold)
        static let headline  = sys(15, .semibold)   // statusTitle
        static let body      = sys(13, .regular)    // строки боксов
        static let callout   = sys(12, .medium)     // таб-пилюля / CCToggle label
        static let calloutEmph = sys(13, .semibold) // groupHeader
        static let caption   = sys(11, .regular)    // statusSub / note
        static let micro     = sys(10, .semibold)   // CAPS eyebrow / section-label (kern +0.5, .uppercased())
        static let microStat = sys(9, .semibold)     // CAPS в плотных рядах: мини-стат / чип / IN-OUT-NET (тот же kern)

        static let numericRing  = mono(22, .bold)      // процент в кольце
        static let numericLarge = mono(16, .semibold)  // мини-показатели
        static let numericBody  = mono(12, .medium)    // строки/сенсоры/чипы
        static let numericMicro = mono(10, .semibold)  // пик графа / тултипы / узлы flow
        // V3 «нативный прибор»: герой-значения поповера (кольцо-заряд, витальные) — SF Pro Rounded вместо
        // «промышленных» моноширинных цифр. Rounded = семья цифр Fitness/Батарей Apple → читается как система.
        // V3 «Прибор — SF Pro Display» (выбор владельца): крупные числа герой+витальные — ОДИН голос,
        // моноширинный SF Pro Display/Text (не Rounded). Точный инструментальный вид, tabular = не дрожат при апдейте.
        static let numericHero  = mono(22, .bold)       // процент в кольце-герое (22pt = Display-оптика)
        static let numericVital = mono(18, .semibold)   // витальные-приборы (Ватт/Темп/Кулер/В АКБ)

        static let capsKern: CGFloat = 0.5             // трекинг капс-подписей
        static func sys(_ s: CGFloat, _ w: NSFont.Weight) -> NSFont { .systemFont(ofSize: s, weight: w) }
        static func mono(_ s: CGFloat, _ w: NSFont.Weight) -> NSFont { .monospacedDigitSystemFont(ofSize: s, weight: w) }
        /// SF Pro Rounded нужного кегля/веса (с деградацией к обычному SF, если дескриптор недоступен).
        static func rounded(_ s: CGFloat, _ w: NSFont.Weight) -> NSFont {
            let base = NSFont.systemFont(ofSize: s, weight: w)
            guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
            return NSFont(descriptor: d, size: s) ?? base
        }
    }

    // MARK: - Spacing (4pt-сетка)
    enum Space {
        static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
        static let s5: CGFloat = 20, s6: CGFloat = 24, s7: CGFloat = 32
        static let tileInset: CGFloat = 14       // внутренний отступ плитки (edge)
    }

    // MARK: - Radius (концентричная шкала, всё .continuous)
    enum Radius {
        static let tile: CGFloat = 16    // плитка поповера
        static let group: CGFloat = 12   // бокс настроек
        static let control: CGFloat = 10 // CCToggle
        static let chip: CGFloat = 8     // сенсор-чип
        static let appIcon: CGFloat = 5  // скругление app-иконки/system-glyph (в тон системным маскам)
        static let pill: CGFloat = 7     // таб-пилюля
        static let track: CGFloat = 9    // трек таб-бара
        static let graphBg: CGFloat = 10
        static let hwTile: CGFloat = 6   // B3-дедуп: чип/плитка Hardware (было 6 в 3 местах HardwareView) — значение 6 сохранено
        static let infoBar: CGFloat = 7  // B3-дедуп: капсула FlowInfoBar (было 7 в 3 местах) — значение 7 сохранено
    }

    // MARK: - Elevation (тень-глубина плитки поверх блюра)
    enum Elevation {
        /// e1 — стеклянная плитка: мягкая тень вниз + не режется краями.
        static func tile(_ layer: CALayer, dark: Bool) {
            layer.masksToBounds = false
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = dark ? 0.18 : 0.12
            layer.shadowRadius = 10
            layer.shadowOffset = CGSize(width: 0, height: -3)
        }
    }

    // MARK: - Motion (длительности и кривые)
    enum Motion {
        static let durFast: CFTimeInterval = 0.18    // press/hover
        static let durBase: CFTimeInterval = 0.22    // таб-кросс-фейд / пилюля
        static let durSlow: CFTimeInterval = 0.42    // всплытие плиток
        static let durSweep: CFTimeInterval = 0.75   // прорисовка кольца
        static let durValue: CFTimeInterval = 0.45   // кросс-фейд числовых значений
        static let stagger: CFTimeInterval = 0.045
        static let durClose: CFTimeInterval = 0.20   // каскад закрытия (быстрее открытия durSlow 0.42)
        static var easeStandard: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1) }
        static var easeIn: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1) }
        static var easeOut: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.32, 0, 0.67, 1) }
        /// Микро-перелёт (overshoot) для pill/USB-тика — кратко проскакивает цель и оседает.
        static var overshoot: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.34, 1.18, 0.64, 1) }
    }

    // MARK: - Size (высоты компонентов)
    enum Size {
        static let toggleHeight: CGFloat = 44, groupRowHeight: CGFloat = 40, chipHeight: CGFloat = 28
        static let tabBarHeight: CGFloat = 32
    }
}

// MARK: - локальные хелперы цвета
private func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}
private func hex(_ v: Int) -> NSColor {
    srgb(CGFloat((v >> 16) & 0xFF) / 255, CGFloat((v >> 8) & 0xFF) / 255, CGFloat(v & 0xFF) / 255)
}
private func white(_ a: CGFloat) -> NSColor { NSColor(white: 1, alpha: a) }
private func black(_ a: CGFloat) -> NSColor { NSColor(white: 0, alpha: a) }
