import Foundation

/// Мощность по компонентам железа (CPU/GPU/DRAM) — данные пишет root-демон в файл.
struct ComponentPower {
    var cpu: Double?      // Вт
    var gpu: Double?      // Вт
    var dram: Double?     // Вт
    var package: Double?  // Вт
    var freqFraction: Double?   // System Average частота как доля номинала (0.6993 = 69.93%); может быть >1 (турбо)
    var freqMHz: Double?        // абсолютная средняя частота, МГц
    var available: Bool { cpu != nil || gpu != nil || dram != nil || package != nil }
    var ageSeconds: Double = .infinity   // насколько свежий сэмпл
    var fresh: Bool { available && ageSeconds < 8 }
}

struct AppEnergy: Equatable {
    var name: String
    var impact: Double
    // Новые поля — все опциональны, чтобы существующие потребители (impact/name) не ломались.
    var cpu: Double?      // %CPU из top, «сейчас» (может быть >100 — многопоток; НЕ клампим)
    var memMB: Double?    // резидентная память в МБ (честный парс из top-формата K/M/G/B)
    var threads: Int?     // #TH

    init(name: String, impact: Double, cpu: Double? = nil, memMB: Double? = nil, threads: Int? = nil) {
        self.name = name
        self.impact = impact
        self.cpu = cpu
        self.memMB = memMB
        self.threads = threads
    }
}

enum PowerInfo {
    /// Сюда root-демон (powermetrics) пишет последний сэмпл.
    /// Путь можно переопределить через BM_POWERFILE (для отладки/тестов).
    static var helperFile: String {
        ProcessInfo.processInfo.environment["BM_POWERFILE"]
            ?? "/Library/Application Support/Kelvin/power.txt"
    }

    // MARK: компоненты железа

    static func components() -> ComponentPower {
        var c = ComponentPower()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: helperFile),
              let mtime = attrs[.modificationDate] as? Date,
              let txt = try? String(contentsOfFile: helperFile, encoding: .utf8) else {
            return c
        }
        c.ageSeconds = -mtime.timeIntervalSinceNow
        c.cpu = watts(label: "CPU Power", in: txt)
        c.gpu = watts(label: "GPU Power", in: txt)
        c.dram = watts(label: "DRAM Power", in: txt)
        // package: либо "Package Power", либо строка Intel energy model
        c.package = watts(label: "Package Power", in: txt)
            ?? watts(label: "derived package power", in: txt)
        let f = systemFreq(in: txt)
        c.freqFraction = f.frac
        c.freqMHz = f.mhz
        return c
    }

    /// Парс строки powermetrics "System Average frequency as fraction of nominal: 69.93% (1818.30 Mhz)".
    /// Берём ИМЕННО System Average (агрегат), а не пер-ядерные "CPU Average frequency..." ниже.
    private static func systemFreq(in text: String) -> (frac: Double?, mhz: Double?) {
        guard let r = text.range(of: "System Average frequency as fraction of nominal:") else { return (nil, nil) }
        let tail = String(text[r.upperBound...].prefix(60))
        let sc = Scanner(string: tail)
        let digits = CharacterSet(charactersIn: "0123456789")
        _ = sc.scanUpToCharacters(from: digits); let pct = sc.scanDouble()   // 69.93
        _ = sc.scanUpToCharacters(from: digits); let mhz = sc.scanDouble()   // 1818.30
        return (pct.map { $0 / 100 }, mhz)
    }

    /// Ищет "<label> ... <число> mW|W" и нормализует в ватты.
    private static func watts(label: String, in text: String) -> Double? {
        guard let r = text.range(of: label) else { return nil }
        let tail = String(text[r.upperBound...].prefix(40))
        let scanner = Scanner(string: tail)
        // пропускаем всё до первой цифры
        let digits = CharacterSet(charactersIn: "0123456789")
        _ = scanner.scanUpToCharacters(from: digits)
        guard let value = scanner.scanDouble() else { return nil }
        // определяем единицу
        let rest = tail[tail.index(tail.startIndex, offsetBy: min(scanner.currentIndex.utf16Offset(in: tail), tail.count))...]
        let isMilli = rest.lowercased().contains("mw")
        return isMilli ? value / 1000.0 : value
    }

    // MARK: топ приложений по энергии (без sudo, через `top`)

    /// Синхронный вариант (для отладки/тестов).
    static func topAppsSync(limit: Int = 6) -> [AppEnergy] { runTopApps(limit: limit) }

    // in-flight гард: `top -l 2 -s 1` живёт ~2с; без гарда при лаге тика процессы накладываются.
    // Зеркалит BTPeripherals.refreshIfStale (флаг ставится/снимается на main). topApps зовётся
    // только с main (UI-тик), поэтому флаг без синхронизации безопасен. topAppsSync его не трогает.
    private static var topBusy = false
    private static var topBusyStart = Date.distantPast     // когда стартовал текущий in-flight (сторож застревания)
    /// «Всего процессов» из сводки последнего top-снимка (nil до первого/при непарсе — футер покажет «—»).
    private(set) static var lastProcCount: Int?

    static func topApps(limit: Int = 6, completion: @escaping ([AppEnergy]) -> Void) {
        // СТОРОЖ ЗАСТРЕВАНИЯ: если прошлый запуск не завершился за 15с (top живёт ~2с), флаг НЕ держим
        // вечно — иначе один зависший процесс запирал бы обновление навсегда → вечный «сбор данных…».
        if topBusy, Date().timeIntervalSince(topBusyStart) < 15 { return }
        topBusy = true
        topBusyStart = Date()
        DispatchQueue.global(qos: .utility).async {
            let result = runTopApps(limit: limit)
            DispatchQueue.main.async { topBusy = false; completion(result) }
        }
    }

    private static func runTopApps(limit: Int) -> [AppEnergy] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        // два сэмпла с интервалом 1с — второй содержит реальный energy impact
        p.arguments = ["-l", "2", "-s", "1", "-n", "30",
                       "-stats", "command,cpu,mem,threads,power", "-o", "power"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice   // НЕ Pipe(): недренированный stderr-пайп при переполнении (64КБ) вешал top → readDataToEndOfFile навсегда
        do { try p.run() } catch { return [] }
        // СТОРОЖ: top -l2 живёт ~2с; если завис (система под нагрузкой / странный вывод), убиваем через 10с —
        // иначе readDataToEndOfFile блокируется навсегда и флаг topBusy застревает → вечный «сбор данных…».
        // POSIX kill (НЕ Process.terminate(): тот БРОСАЕТ NSInvalidArgumentException при гонке «уже завершился»
        // → неперехватываемое ObjC-исключение → SIGABRT). kill на мёртвый pid просто вернёт ESRCH — безвредно.
        let watchdog = DispatchWorkItem { if p.isRunning { _ = kill(p.processIdentifier, SIGKILL) } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()   // EOF придёт и при terminate() сторожа
        p.waitUntilExit()
        watchdog.cancel()
        guard let out = String(data: data, encoding: .utf8) else { return [] }

        // top -l 2 печатает два сэмпла; берём ПОСЛЕДНИЙ (в нём реальный energy impact).
        // Каждый сэмпл начинается со строки "Processes:" — режем по ней.
        let samples = out.components(separatedBy: "Processes:")
        let body = samples.last ?? out
        var apps: [AppEnergy] = []
        var started = false   // флаг: прошли строку-заголовок "COMMAND ... POWER"
        for raw in body.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !started {
                // сводка ДО заголовка: первая строка body (хвост "Processes:") вида " 512 total, 2 running…"
                // — честное «всего процессов» для футера вкладки Приложения (пишется на utility-очереди
                // ДО main-hop completion'а → чтение на main после него упорядочено, гонки нет)
                if line.hasSuffix("…") == false, line.contains(" total"),
                   let n = Int(line.split(separator: " ").first ?? "") { lastProcCount = n }
                if line.hasPrefix("COMMAND") { started = true }
                continue            // всё до заголовка — это сводка (Load Avg, CPU usage, …)
            }
            // Хвост строки — 5 фиксированных полей: %CPU MEM #TH POWER (плюс имя в начале).
            // КРИТИЧНО: COMMAND содержит пробелы («Code Helper (Plu») и top обрезает имя, поэтому
            // имя = всё ДО последних четырёх полей, а не split по первому пробелу.
            let parts = line.split(separator: " ").filter { !$0.isEmpty }
            guard parts.count >= 5,
                  let power = Double(parts[parts.count - 1]), power > 0 else { continue }
            let cpu     = Double(parts[parts.count - 4])
            let memMB   = parseMem(String(parts[parts.count - 3]))
            // #TH иногда "1/1" (running/total) — берём первое поле, иначе Int("1/1") = nil.
            let thField = String(parts[parts.count - 2])
            let threads = Int(thField.split(separator: "/").first.map(String.init) ?? thField)
            let name    = parts[0..<(parts.count - 4)].joined(separator: " ")
            if name == "top" { continue }   // отбрасываем собственный замерочный процесс
            apps.append(AppEnergy(name: name, impact: power, cpu: cpu, memMB: memMB, threads: threads))
        }
        return Array(apps.sorted { $0.impact > $1.impact }.prefix(limit))
    }

    /// Парс поля MEM из top-формата в МБ (честно): "45M" → 45, "1.2G" → 1228.8, "512K" → 0.5,
    /// "340B" → крошечная доля МБ. Без суффикса трактуем как МБ.
    private static func parseMem(_ s: String) -> Double? {
        // top -l 2 во втором сэмпле лепит хвостовой знак роста ("218M+", "8008K-") — снимаем,
        // иначе last = "+"/"-" (не буква) → mult=1, num="218M+" → Double = nil → MEM = «—».
        var s = s
        if s.hasSuffix("+") || s.hasSuffix("-") { s = String(s.dropLast()) }
        guard let last = s.last else { return nil }
        let mult: Double
        switch last {
        case "K": mult = 1.0 / 1024
        case "M": mult = 1
        case "G": mult = 1024
        case "B": mult = 1.0 / (1024 * 1024)
        default:  mult = 1
        }
        let num = last.isLetter ? String(s.dropLast()) : s
        guard let v = Double(num) else { return nil }
        return v * mult
    }
}
