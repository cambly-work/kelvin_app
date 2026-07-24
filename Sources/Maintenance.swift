import Foundation

/// Вкладка «Обслуживание» — read-only постура безопасности/системы. Всё БЕЗ root.
/// ЧЕСТНОСТЬ: только факты из системных утилит; ничего не выдумываем, недоступное = nil → «—».
enum Maintenance {
    enum SIP {
        case enabled, disabled, custom, unknown
        var label: String {
            switch self {
            case .enabled:  return L("включена")
            case .disabled: return L("отключена")   // акцент несёт цвет (.crit), а не CAPS в смешанной строке
            case .custom:   return L("ослаблена (Custom Configuration)")
            case .unknown:  return L("неизвестно")
            }
        }
        /// warn/crit только для реально ослабленной защиты; enabled/unknown — спокойно.
        var level: Design.Level? {
            switch self {
            case .disabled: return .crit
            case .custom:   return .warn
            default:        return nil
            }
        }
    }

    enum Thermal {
        case nominal, fair, serious, critical, unknown
        var label: String {
            switch self {
            case .nominal:  return L("в норме")
            case .fair:     return L("умеренная")
            case .serious:  return L("высокая")
            case .critical: return L("критическая")
            case .unknown:  return L("неизвестно")
            }
        }
        var level: Design.Level? {
            switch self {
            case .serious:  return .warn
            case .critical: return .crit
            default:        return nil          // nominal/fair/unknown — без семантики уровня (см. neutral в UI)
            }
        }
    }

    struct Posture {
        let xprotect: String?       // версия сигнатур XProtect (актуально обновляемая копия)
        let sip: SIP
        let fileVault: Bool?        // шифрование системного тома
        let thermal: Thermal        // системная термонагрузка (ProcessInfo)
        let sleepBlockers: [String] // процессы, реально держащие запрет сна (не UserIsActive)
        let crashes7d: Int          // число отчётов о сбоях за 7 дней
        let latestCrash: String?    // «Process · дата» последнего отчёта
        let bootArgs: String?          // кастомные boot-args (nil = стандартно/не заданы — НЕ хвалим, нейтрально)
        let pendingUpdates: [PendingUpdate] // ожидающие обновления (из кэша macOS, ноль сети)
        let updateChecked: Date?       // когда macOS последний раз успешно проверяла обновления
        let memory: MemoryInfo.State   // давление памяти + своп (честная метрика, не «% занято»)
    }

    /// Одно ожидающее обновление. `major` = апгрейд ОС (валидный ВЫБОР — красим нейтрально, не «тревога»);
    /// иначе патч в текущей ОС (актуально применимый — красим warn).
    struct PendingUpdate { let name: String; let major: Bool }

    static func posture() -> Posture {
        let (blockers) = sleepBlockers()
        let (n, latest) = recentCrashes()
        let upd = macUpdates()
        return Posture(xprotect: xprotectVersion(), sip: sipStatus(), fileVault: fileVaultOn(),
                       thermal: thermalState(), sleepBlockers: blockers, crashes7d: n, latestCrash: latest,
                       bootArgs: bootArgsRaw(), pendingUpdates: upd.updates, updateChecked: upd.checked,
                       memory: MemoryInfo.read())
    }

    /// Кастомные boot-args из NVRAM. Переменная НЕ ЗАДАНА (nvram exit 1 → пустой stdout) = СТАНДАРТНО (не «unknown»,
    /// не тревога) → nil. Заданы → возвращаем значение verbatim (вердикт по флагам не выносим — просто показываем).
    private static func bootArgsRaw() -> String? {
        let out = shell("/usr/sbin/nvram", ["boot-args"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty, let tab = out.firstIndex(of: "\t") else { return nil }
        let v = String(out[out.index(after: tab)...]).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    /// Ожидающие обновления macOS из СОБСТВЕННОГО кэша системы (ноль сетевых запросов Kelvin). Атрибуция —
    /// macOS, не наш вердикт: имена ожидающих + дата последней успешной проверки самой системы.
    private static func macUpdates() -> (updates: [PendingUpdate], checked: Date?) {
        let path = "/Library/Preferences/com.apple.SoftwareUpdate.plist"
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = obj as? [String: Any] else { return ([], nil) }
        var updates: [PendingUpdate] = []
        if let recs = dict["RecommendedUpdates"] as? [[String: Any]] {
            updates = recs.compactMap { rec in
                guard let name = (rec["Display Name"] as? String) ?? (rec["Identifier"] as? String) else { return nil }
                let major = (rec["MobileSoftwareUpdate"] as? Bool == true) || ((rec["Identifier"] as? String)?.hasSuffix("_major") == true)
                return PendingUpdate(name: name, major: major)
            }
        }
        return (updates, dict["LastFullSuccessfulDate"] as? Date)
    }

    private static func thermalState() -> Thermal {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return .nominal
        case .fair:     return .fair
        case .serious:  return .serious
        case .critical: return .critical
        @unknown default: return .unknown
        }
    }

    /// Процессы, реально мешающие сну (Prevent*Sleep). UserIsActive («вы за компьютером») НЕ считаем блоком.
    private static func sleepBlockers() -> [String] {
        let out = shell("/usr/bin/pmset", ["-g", "assertions"])
        guard let r = out.range(of: "Listed by owning process:") else { return [] }
        let preventers: Set<String> = ["PreventUserIdleSystemSleep", "PreventSystemSleep", "PreventUserIdleDisplaySleep"]
        var names: [String] = []
        for raw in out[r.upperBound...].split(separator: "\n") {
            let line = String(raw)
            // формат: "   pid 164(WindowServer): [id] 00:01:27 Type named: \"...\""
            // Тип берём ПОЗИЦИОННО — токен прямо перед " named:", а не substring по всей строке
            // (free-text описание в named может содержать имя типа → ложные срабатывания).
            guard let head = line.range(of: " named:")?.lowerBound else { continue }
            let type = line[..<head].split(separator: " ").last.map(String.init) ?? ""
            guard preventers.contains(type) else { continue }
            // имя процесса из "pid N(Name): " — до "): " (имя может содержать ')')
            guard let o = line.firstIndex(of: "("), let end = line.range(of: "): ") else { continue }
            let name = String(line[line.index(after: o)..<end.lowerBound])
            if !name.isEmpty && !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// Отчёты о СБОЯХ (.ips, bug_type 309) за 7 дней: число + последний «процесс · дата».
    /// Дата — из хвоста имени файла (mtime ОС двигает); тип/имя — из первой JSON-строки заголовка (только ~4 КБ,
    /// без TCC). Свои падения (Kelvin/BatteryMeter) НЕ считаем; hang/jetsam/resource-отчёты — отсекаем по bug_type.
    private static func recentCrashes() -> (count: Int, latest: String?) {
        let dir = NSHomeDirectory() + "/Library/Logs/DiagnosticReports"
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return (0, nil) }
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        let selfNames: Set<String> = ["Kelvin", "BatteryMeter"]
        let fnFmt = DateFormatter(); fnFmt.dateFormat = "yyyy-MM-dd-HHmmss"; fnFmt.locale = Locale(identifier: "en_US_POSIX")
        var recent: [(proc: String, date: Date)] = []
        for f in items where f.hasSuffix(".ips") {
            let comps = f.dropLast(4).split(separator: "-", omittingEmptySubsequences: false)   // "<Proc>-YYYY-MM-DD-HHMMSS"
            guard comps.count >= 5, let date = fnFmt.date(from: comps.suffix(4).joined(separator: "-")),
                  date >= cutoff else { continue }
            guard let fh = FileHandle(forReadingAtPath: dir + "/" + f) else { continue }
            let headData = fh.readData(ofLength: 4096); try? fh.close()
            guard let line = String(data: headData, encoding: .utf8)?.split(separator: "\n").first,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  (obj["bug_type"] as? String) == "309" else { continue }       // 309 = крэш (не hang/jetsam/resource)
            let proc = (obj["app_name"] as? String) ?? String(comps.dropLast(4).joined(separator: "-"))
            guard !selfNames.contains(proc) else { continue }                   // не выставляем свои падения напоказ
            recent.append((proc, date))
        }
        guard let last = recent.max(by: { $0.date < $1.date }) else { return (recent.count, nil) }
        let df = DateFormatter(); df.dateFormat = "d MMM"; df.locale = Locale(identifier: I18n.current.rawValue)
        let proc = last.proc.count > 15 ? String(last.proc.prefix(14)) + "…" : last.proc   // длинные имена не выдавливают дату
        return (recent.count, proc + " · " + df.string(from: last.date))
    }

    /// Асинхронно: csrutil/fdesetup/defaults в фоне, результат — на main (не блокируем открытие поповера).
    static func posture(completion: @escaping (Posture) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = posture()
            DispatchQueue.main.async { completion(p) }
        }
    }

    private static func xprotectVersion() -> String? {
        // приоритет — актуально обновляемая защищённая копия; fallback — бандл в /Library
        for base in ["/private/var/protected/xprotect/XProtect.bundle/Contents/Info",
                     "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info"] {
            let v = shell("/usr/bin/defaults", ["read", base, "CFBundleShortVersionString"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { return v }
        }
        return nil
    }

    private static func sipStatus() -> SIP {
        let out = shell("/usr/bin/csrutil", ["status"]).lowercased()
        if out.contains("custom") { return .custom }        // «unknown (Custom Configuration)» = ослаблена
        if out.contains("enabled") { return .enabled }
        if out.contains("disabled") { return .disabled }
        return .unknown
    }

    private static func fileVaultOn() -> Bool? {
        let out = shell("/usr/bin/fdesetup", ["status"]).lowercased()
        if out.contains("filevault is on") { return true }
        if out.contains("filevault is off") { return false }
        return nil
    }

    private static func shell(_ path: String, _ args: [String]) -> String {
        ProcessRunner.output(path, args, timeout: 8)
    }
}
