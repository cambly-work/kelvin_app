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
        let model = sysctlStr("hw.model")
        kv(L("Модель"), model)
        let arch = architecture()
        kv("Архитектура", arch)
        kv("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
        if let up = SystemUptime.seconds() { kv(L("Аптайм"), fmtDuration(up)) }

        // — Оборудование и SMC —
        h(L("Оборудование и SMC"))
        let smc = EnergyModel.smc
        let smcAvailable = smc.available
        kv("SMC available", smcAvailable ? L("да") : L("нет"))
        
        if smcAvailable {
            // Получаем каталог ключей (ограниченно, не полный перебор)
            let catalogKeys = Array(SensorCatalog.catalog().prefix(200))
            kv(L("Ключей в каталоге"), "\(catalogKeys.count)")
            
            // Resolved sensor set
            let resolved = SensorResolver.resolve(
                model: model,
                architecture: arch,
                catalog: catalogKeys,
                readValue: { smc.read($0) }
            )
            
            // Cooling topology
            switch resolved.cooling {
            case .passive:
                kv(L("Охлаждение"), L("Пассивное"))
            case .active(let fanIndices):
                kv(L("Охлаждение"), L("Активное") + " (\(fanIndices.count) " + L("вентиляторов") + ")")
            case .unknown:
                kv(L("Охлаждение"), L("Данные недоступны"))
            }
            
            // FNum если доступен
            if let fnum = smc.read("FNum") {
                kv("FNum", "\(Int(fnum))")
            }
            
            // Разрешённые сенсоры
            s += "\n### " + L("Разрешённые сенсоры") + "\n\n"
            if resolved.sensors.isEmpty {
                s += "_" + L("Нет подтверждённых физических ролей для этой модели.") + "_\n"
            } else {
                for (role, sensor) in resolved.sensors.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    let roleName = roleDisplayName(role)
                    let confidenceName = confidenceDisplayName(sensor.confidence)
                    s += "- **\(roleName)**: `\(sensor.keys.joined(separator: ", "))` · \(confidenceName)\n"
                    if let value = sensor.keys.compactMap({ smc.read($0) }).first {
                        s += "  - " + String(format: "%.1f °C", value) + "\n"
                    }
                }
            }
            
            // Сырой каталог (температурные и fan ключи)
            s += "\n### " + L("Доступные датчики (сырой каталог)") + "\n\n"
            let tempAndFanKeys = catalogKeys.filter { key in
                key.smcType.hasPrefix("sp") || key.smcType.hasPrefix("flt")
                    || key.fourCC.hasPrefix("T") || key.fourCC.hasPrefix("F")
            }
            if tempAndFanKeys.isEmpty {
                s += "_" + L("Температурные и fan ключи не найдены.") + "_\n"
            } else {
                s += "| FourCC | Тип | Размер | Значение |\n"
                s += "|--------|-----|--------|----------|\n"
                for key in tempAndFanKeys.prefix(50) { // ограничим 50 для читаемости
                    let fourCC = key.fourCC
                    let type = key.smcType
                    let size = smc.typeInfo(fourCC)?.size ?? 0
                    let valueStr: String
                    if let value = smc.read(fourCC) {
                        if type.hasPrefix("sp78") {
                            valueStr = String(format: "%.1f", value)
                        } else if fourCC.hasPrefix("F") && fourCC.contains("Ac") {
                            valueStr = "\(Int(value)) RPM"
                        } else {
                            valueStr = String(format: "%.2f", value)
                        }
                    } else {
                        valueStr = "—"
                    }
                    s += "| `\(fourCC)` | `\(type)` | \(size) | \(valueStr) |\n"
                }
                if tempAndFanKeys.count > 50 {
                    s += "| … | … | … | " + String(format: L("и ещё %d"), tempAndFanKeys.count - 50) + " |\n"
                }
            }
        } else {
            kv(L("Статус"), L("SMC недоступен на этой системе"))
        }

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

        // — Автоязык —
        h(L("Автоязык"))
        let langStatus = LangSwitcherStatus.current()
        kv(L("Режим (сохранён)"), modeDisplayName(langStatus.savedMode))
        kv(L("Статус runtime"), langStatus.runtimeStatus.localizedDescription)
        kv(L("Accessibility"), langStatus.accessibilityTrusted ? L("разрешено") : L("запрещено"))
        kv(L("Event tap активен"), langStatus.tapActive ? L("да") : L("нет"))
        if langStatus.recoveries > 0 || langStatus.creationFailures > 0 {
            kv(L("Восстановления / ошибки"), "\(langStatus.recoveries) / \(langStatus.creationFailures)")
        }
        if let sourceID = langStatus.currentSourceID {
            kv(L("Текущий input source"), sourceID)
        }
        
        s += "\n### " + L("Доступные раскладки") + "\n\n"
        if langStatus.availableLayouts.isEmpty {
            s += "_" + L("Раскладки не найдены.") + "_\n"
        } else {
            s += "| ID | Название | Язык |\n"
            s += "|----|----------|------|\n"
            for layout in langStatus.availableLayouts.prefix(20) {
                let lang = layout.language ?? "—"
                s += "| `\(layout.id)` | \(mdText(layout.name)) | \(lang) |\n"
            }
            if langStatus.availableLayouts.count > 20 {
                s += "| … | … | " + String(format: L("и ещё %d"), langStatus.availableLayouts.count - 20) + " |\n"
            }
        }
        
        s += "\n### " + L("Пары конвертации") + "\n\n"
        if langStatus.conversionPairs.isEmpty {
            s += "_" + L("Пары конвертации не настроены.") + "_\n"
        } else {
            for pair in langStatus.conversionPairs {
                s += "- `\(pair.from)` → `\(pair.to)`\n"
            }
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
    
    // MARK: - Хелперы для SMC отчёта
    
    private static func architecture() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "—" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buf, &size, nil, 0) == 0 else { return "—" }
        let machine = String(cString: buf)
        if machine.hasPrefix("arm64") || machine.hasPrefix("armv") { return "arm64" }
        if machine.hasPrefix("x86_64") { return "x86_64" }
        return machine
    }
    
    private static func roleDisplayName(_ role: PhysicalSensorRole) -> String {
        switch role {
        case .cpuTemperature: return L("Температура CPU")
        case .cpuPackageTemperature: return L("Температура пакета CPU")
        case .gpuTemperature: return L("Температура GPU")
        case .memoryTemperature: return L("Температура памяти")
        case .platformTemperature: return L("Температура платформы")
        case .wifiTemperature: return L("Температура Wi-Fi")
        case .batteryTemperature: return L("Температура батареи")
        }
    }
    
    private static func confidenceDisplayName(_ confidence: SensorConfidence) -> String {
        switch confidence {
        case .modelVerified: return L("подтверждено моделью")
        case .familyVerified: return L("подтверждено семейством")
        case .legacyVerified: return L("legacy fallback")
        case .unknown: return L("неизвестно")
        }
    }
    
    private static func modeDisplayName(_ mode: LangSwitcher.Mode) -> String {
        switch mode {
        case .off: return L("Выключено")
        case .hotkey: return L("По горячей клавише")
        case .auto: return L("Автоматически")
        }
    }
}
