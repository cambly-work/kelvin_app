import Foundation
import Darwin   // sysctlbyname

/// Кросс-вкладочный снимок здоровья системы в Markdown — для саппорта/перепродажи.
///
/// ЧЕСТНОСТЬ (закон продукта):
///  • ТОЛЬКО факты, которые Kelvin уже читает локально (IOKit/SMC/системные утилиты). Ничего не выдумываем;
///    недоступное — «—» или секцию пропускаем.
///  • Ноль сетевых запросов, ноль телеметрии. Отчёт — это снимок для человека, не аплоад.
///  • Собственные падения Kelvin из счётчика сбоев уже исключены на уровне Maintenance (self-incrimination).
enum DiagnosticReport {

    /// Собрать Markdown в фоне (часть источников делает shell/SMC-чтения) → результат на main.
    /// `log` ПЕРЕДАЁТСЯ снимком (снят на main вызывающим): AppSession.ledger не thread-safe, читать его
    /// из фона нельзя (гонка с noteConnection на main). Массив — value-type, безопасен для фон-чтения.
    static func generate(now: Date = Date(), log: [AppSession.LedgerEntry], completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let md = build(now: now, log: log)
            DispatchQueue.main.async { completion(md) }
        }
    }

    private static func build(now: Date, log: [AppSession.LedgerEntry]) -> String {
        var s = ""
        func h(_ t: String) { s += "\n## \(t)\n\n" }
        func kv(_ k: String, _ v: String) { s += "- **\(k):** \(v)\n" }

        let ver = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"; df.locale = Locale(identifier: I18n.current.rawValue)
        s += "# " + L("Kelvin — диагностический отчёт") + "\n\n"
        s += "_" + String(format: L("Локальный снимок, без сети · Kelvin %@ · %@"), ver, df.string(from: now)) + "_\n"

        // — Система —
        h(L("Система"))
        kv(L("Модель"), sysctlStr("hw.model"))
        kv("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
        if let up = SystemUptime.seconds() { kv(L("Аптайм"), fmtDuration(up)) }

        // — Безопасность / Здоровье (Maintenance posture; sync) —
        let p = Maintenance.posture()
        h(L("Безопасность"))
        kv("SIP", p.sip.label)
        kv("FileVault", p.fileVault.map { $0 ? L("включено") : L("выключено") } ?? "—")
        kv("XProtect", p.xprotect ?? "—")

        h(L("Здоровье и стабильность"))
        kv(L("Термонагрузка"), p.thermal.label)
        kv(L("Что мешает сну"), p.sleepBlockers.isEmpty ? L("ничто не мешает") : p.sleepBlockers.map(mdText).joined(separator: ", "))
        var crashLine = "\(p.crashes7d)"
        if let latest = p.latestCrash { crashLine += " · " + mdText(latest) }
        crashLine += " " + L("(собственные сбои Kelvin не учтены)")
        kv(L("Отчёты о сбоях (7 дн)"), crashLine)

        // — Батарея —
        if let b = BatteryReader.read(), b.present {
            h(L("Батарея"))
            kv(L("Здоровье"), String(format: "%.0f%%", min(100, max(0, b.health))))   // >100% клампим (закон)
            kv(L("Циклы"), "\(b.cycleCount)")
            if b.temperature > 0 { kv(L("Температура"), String(format: "%.1f °C", b.temperature)) }
        }

        // — Диск —
        if let d = DiskInfo.capacity(), d.total > 0 {
            h(L("Диск"))
            kv(L("Свободно"), byteStr(d.free) + " / " + byteStr(d.total))
        }

        // — Сеть за сессию (из переданного снимка журнала) —
        h(L("Сеть за сессию"))
        // Оговорка охвата — в ОБЕИХ ветках (не только пустой): журнал не полный захват сессии.
        s += "_" + L("Журнал наполняется только пока открыт поповер Kelvin — это не полный захват сессии.") + "_\n"
        if log.isEmpty {
            s += "_" + L("Журнал пуст.") + "_\n"
        } else {
            let countries = Set(log.compactMap { $0.code })
            kv(L("Записей в журнале"), "\(log.count)")
            kv(L("Стран-назначений"), "\(countries.count)")
            // легенда «×N» едет ВНУТРИ .md (тултипа у читателя отчёта нет)
            s += "\n_" + L("«×N» — сколько раз соединение попало в 5-сек снимок (не число запросов и не объём данных).") + "_\n"
            for e in log.prefix(30) {   // топ-30 свежих, чтобы отчёт не разбухал
                let flag = e.code ?? "LAN"
                s += "- `\(e.endpoint)` · \(flag) · \(mdText(e.app)) · ×\(e.count)\n"   // имя приложения экранируем
            }
            if log.count > 30 { s += "- _…" + String(format: L("и ещё %d"), log.count - 30) + "_\n" }
        }

        s += "\n---\n_" + L("Данные локальны (IOKit/SMC/системные утилиты). Kelvin не отправляет ничего в сеть.") + "_\n"
        return s
    }

    // MARK: - Хелперы

    private static func sysctlStr(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "—" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "—" }
        return String(cString: buf)
    }

    private static func fmtDuration(_ sec: Double) -> String {
        let t = Int(sec), d = t / 86400, h = (t % 86400) / 3600, m = (t % 3600) / 60
        if d > 0 { return String(format: L("%dд %dч %dм"), d, h, m) }
        if h > 0 { return String(format: L("%dч %dм"), h, m) }
        return String(format: L("%dм"), m)
    }

    private static func byteStr(_ b: Int64) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: b)
    }

    /// Экранирование Markdown-активных символов в НЕДОВЕРЕННЫХ строках (имена приложений/процессов из
    /// localizedName / pmset / .ips — контролируются сторонним софтом). Иначе `*`/`_`/backtick/`|` рвут строку.
    private static func mdText(_ x: String) -> String {
        x.replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "`", with: "'")
         .replacingOccurrences(of: "|", with: "\\|")
         .replacingOccurrences(of: "*", with: "\\*")
         .replacingOccurrences(of: "_", with: "\\_")
         .replacingOccurrences(of: "[", with: "\\[")
         .replacingOccurrences(of: "]", with: "\\]")
    }
}
