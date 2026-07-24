import AppKit
import Darwin   // sysctlbyname

/// PDF-отчёт «Здоровье Mac за период». Строит офскрин-вид (белый лист, светлая тема) и рендерит его в
/// PDF через `dataWithPDF`. Честность: включаем ТОЛЬКО реально снятые данные — графики рисуются лишь при
/// ≥2 точках, метрики без истории пропускаются, батарея-блок честно говорит «десктоп» при отсутствии АКБ.
/// Ноль сети/телеметрии — весь отчёт из локальной SQLite-истории.
enum Report {

    /// Белый лист-канва: рисуем фон в draw (не через слой — чтобы попал в PDF-контекст), flipped для
    /// естественной верстки сверху-вниз.
    private final class Canvas: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ r: NSRect) { NSColor.white.setFill(); r.fill() }
    }

    static func healthReportPDF(period: TimeInterval, battery: BatteryInfo?, insight: BatteryHealth.Insight) -> Data {
        let W: CGFloat = 612                              // ширина листа US Letter @72dpi
        let pad: CGFloat = 40
        let innerW = W - pad * 2
        let now = Int64(Date().timeIntervalSince1970)
        let since = now - Int64(period)
        let days = Int((period / 86_400).rounded())

        func lbl(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.font = .systemFont(ofSize: size, weight: weight)
            t.textColor = color
            t.lineBreakMode = .byWordWrapping
            t.maximumNumberOfLines = 0
            t.preferredMaxLayoutWidth = innerW
            t.translatesAutoresizingMaskIntoConstraints = false
            return t
        }
        func sep() -> NSView {
            let v = NSBox(); v.boxType = .separator
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: innerW).isActive = true
            return v
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.translatesAutoresizingMaskIntoConstraints = false

        // — Шапка —
        stack.addArrangedSubview(lbl(L("Kelvin — отчёт о здоровье Mac"), 22, .bold, .labelColor))
        stack.addArrangedSubview(lbl(String(format: L("Период: последние %d дн · сформирован %@"), days, dateStr()), 11, .regular, .secondaryLabelColor))
        stack.addArrangedSubview(lbl(String(format: L("Модель: %@ · macOS %@"), sysctlStr("hw.model"), osVersion()), 11, .regular, .secondaryLabelColor))
        stack.addArrangedSubview(sep())

        // — Батарея —
        stack.addArrangedSubview(lbl(L("Батарея"), 15, .semibold, .labelColor))
        if let b = battery, b.present {
            stack.addArrangedSubview(lbl(batteryLines(b, insight), 12, .regular, .labelColor))
        } else {
            stack.addArrangedSubview(lbl(L("Батарея не обнаружена (десктоп)."), 12, .regular, .secondaryLabelColor))
        }
        stack.addArrangedSubview(sep())

        // — Тренды —
        stack.addArrangedSubview(lbl(L("Тренды за период"), 15, .semibold, .labelColor))
        // cap/floor: заряд честно 0..100; здоровье НЕ кэпим (бывает 104% — не прячем), низ 0.
        let metrics: [(title: String, metric: History.Metric, unit: String, color: NSColor, cap: Double?, floor: Double?)] = [
            (L("Здоровье АКБ"), .health,  "%",          .systemGreen,  nil, 0),
            (L("Заряд"),        .charge,  "%",          .systemBlue,   100, 0),
            (L("Температура CPU"), .cpuTemp, "°",       .systemOrange, nil, nil),
            (L("Потребление"),  .systemW, L(" Вт"),     .systemPurple, nil, 0),
            (L("Кулеры"),       .fanRPM,  L(" об/мин"), .systemTeal,   nil, 0),
        ]
        var anyChart = false
        for m in metrics {
            let series = History.shared.series(m.metric, since: since)
            guard series.count >= 2 else { continue }
            anyChart = true
            stack.addArrangedSubview(lbl(m.title + "  " + statLine(series, m.unit), 11, .medium, .secondaryLabelColor))
            let chart = HistoryChart()
            chart.translatesAutoresizingMaskIntoConstraints = false
            chart.widthAnchor.constraint(equalToConstant: innerW).isActive = true
            chart.heightAnchor.constraint(equalToConstant: 84).isActive = true
            chart.set(points: series.map { (x: Double($0.ts), y: $0.v) }, color: m.color, unit: m.unit, yCap: m.cap, yFloor: m.floor, empty: "")
            stack.addArrangedSubview(chart)
        }
        if !anyChart {
            stack.addArrangedSubview(lbl(L("Недостаточно истории для графиков — Kelvin снимает метрики раз в минуту, пока запущен."), 11, .regular, .secondaryLabelColor))
        }

        stack.addArrangedSubview(sep())
        let n = History.shared.countSince(since)               // точки ЗА ПЕРИОД отчёта, а не вся 90д база
        let pts: String
        switch I18n.current {
        case .ru: pts = SettingsStore.plural(n, "точка", "точки", "точек")
        case .uk: pts = SettingsStore.plural(n, "точка", "точки", "точок")
        case .en: pts = n == 1 ? "point" : "points"
        case .pt: pts = n == 1 ? "ponto" : "pontos"
        }
        stack.addArrangedSubview(lbl(String(format: L("Данные сняты локально, раз в минуту · %d %@. Никакой сети и телеметрии."), n, pts), 9, .regular, .tertiaryLabelColor))

        // — Сборка канвы + рендер в PDF —
        let root = Canvas()
        root.appearance = NSAppearance(named: .aqua)     // светлая тема: семантические цвета → тёмное по белому
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -pad),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: pad),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -pad),
            root.widthAnchor.constraint(equalToConstant: W),
        ])
        root.layoutSubtreeIfNeeded()
        let h = max(root.fittingSize.height, 200)
        root.frame = NSRect(x: 0, y: 0, width: W, height: h)
        root.layoutSubtreeIfNeeded()
        return root.dataWithPDF(inside: root.bounds)
    }

    // MARK: - вспомогательное

    private static func batteryLines(_ b: BatteryInfo, _ ins: BatteryHealth.Insight) -> String {
        var lines: [String] = []
        var l1 = String(format: L("Здоровье %.0f%%"), b.health)
        if let rated = b.ratedCycles, rated > 0 { l1 += String(format: L(" · %d циклов из ~%d"), b.cycleCount, rated) }
        else { l1 += String(format: L(" · %d циклов"), b.cycleCount) }
        lines.append(l1)
        if b.maxCapacity > 0, b.designCapacity > 0 {
            lines.append(String(format: L("Ёмкость %d / %d мА·ч (проектная)"), b.maxCapacity, b.designCapacity))
        }
        if ins.enough, let spm = ins.slopePerMonth {
            if spm < -0.15 {
                var t = String(format: L("Тренд износа %.1f%%/мес"), spm)
                if let m = ins.monthsTo80 {
                    t += m.rounded() < 1 ? L(" · до 80% < 1 мес") : String(format: L(" · до 80%% ~%.0f мес"), m)
                }
                lines.append(t)
            } else {
                lines.append(L("Тренд стабилен — деградации за период не видно"))
            }
        } else {
            lines.append(String(format: L("Тренд износа: нужно ≥2 недель истории (собрано %.0f дн)"), ins.spanDays))
        }
        return lines.joined(separator: "\n")
    }

    private static func statLine(_ s: [(ts: Int64, v: Double)], _ unit: String) -> String {
        let vs = s.map { $0.v }
        let avg = vs.reduce(0, +) / Double(vs.count)
        return String(format: L("(мин %.0f · сред %.0f · макс %.0f%@)"), vs.min()!, avg, vs.max()!, unit)
    }

    private static func dateStr() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: I18n.current.rawValue)
        df.dateStyle = .medium; df.timeStyle = .short
        return df.string(from: Date())
    }

    private static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func sysctlStr(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "—" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
