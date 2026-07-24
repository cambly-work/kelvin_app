import SQLite3
import Foundation

/// Локальная история метрик на SQLite — БЕЗ внешних зависимостей (чистый C API; соло/raw-swiftc).
///
/// ПОТОКОБЕЗОПАСНОСТЬ: один коннект + одна серийная очередь (`q`) — весь доступ сериализован, гонок нет.
/// Пишем ~раз в 60с из тика. RETENTION: держим 90 дней для ВСЕХ (диск ~единицы МБ), а ПОКАЗ ограничиваем
/// по тиру в UI (Free — 24ч, Pro — до 90д + экспорт) → данные не «заложники», апгрейд раскрывает накопленное.
///
/// ЧЕСТНОСТЬ (закон продукта): в базу идут ТОЛЬКО реально снятые точки; на первом запуске история пуста —
/// UI показывает «накопление данных», а не выдуманную кривую. Ноль сети, ноль телеметрии — файл на диске юзера.
final class History {
    static let shared = History()

    private var db: OpaquePointer?
    private var insertStmt: OpaquePointer?
    private let q = DispatchQueue(label: "com.trykelvin.kelvin.history")

    /// Снимок метрик в момент времени. Любое поле может быть nil (нет датчика/десктоп без АКБ) → пишем NULL.
    struct Sample {
        let ts: Int64                 // unix-секунды
        let charge: Double?           // заряд %
        let health: Double?           // здоровье АКБ %
        let battTemp: Double?         // температура АКБ °C
        let cpuTemp: Double?          // °C
        let gpuTemp: Double?          // °C
        let systemW: Double?          // потребление системы, Вт
        let fanRPM: Double?           // макс. обороты кулеров
        let charging: Bool
    }

    /// Метрики, которые умеет строить график. rawValue == имя колонки (подставляется в SQL — из фикс-enum,
    /// НЕ пользовательский ввод, инъекции нет).
    enum Metric: String, CaseIterable {
        case charge, health, battTemp, cpuTemp, gpuTemp, systemW, fanRPM
    }

    struct Dashboard {
        let charge: [(ts: Int64, v: Double)]
        let health: [(ts: Int64, v: Double)]
        let earliest: Int64?
        let count: Int
        let battery: BatteryInfo?
    }

    private init() { q.sync { openDB() } }

    private func openDB() {
        let fm = FileManager.default
        guard let appSup = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = appSup.appendingPathComponent("Kelvin", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("history.db").path
        guard sqlite3_open(path, &db) == SQLITE_OK else { db = nil; return }
        // WAL — не блокирует читателей писателем; synchronous=NORMAL — быстрая и безопасная для WAL;
        // busy_timeout — на всякий случай (мы и так сериализуем очередью).
        sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=2000;", nil, nil, nil)
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS samples(
              ts INTEGER PRIMARY KEY, charge REAL, health REAL, battTemp REAL,
              cpuTemp REAL, gpuTemp REAL, systemW REAL, fanRPM REAL, charging INTEGER);
            """, nil, nil, nil)
        sqlite3_prepare_v2(db, """
            INSERT OR REPLACE INTO samples(ts,charge,health,battTemp,cpuTemp,gpuTemp,systemW,fanRPM,charging)
            VALUES(?,?,?,?,?,?,?,?,?);
            """, -1, &insertStmt, nil)
    }

    private func bind(_ st: OpaquePointer?, _ i: Int32, _ v: Double?) {
        if let v = v, v.isFinite { sqlite3_bind_double(st, i, v) } else { sqlite3_bind_null(st, i) }
    }

    /// Записать точку (async — не блокирует тик). После вставки чистим старше `keepSeconds` (дешёвый DELETE по PK).
    func record(_ s: Sample, keepSeconds: Int64) {
        q.async { [weak self] in
            guard let self = self, let db = self.db, let st = self.insertStmt else { return }
            sqlite3_reset(st)
            sqlite3_bind_int64(st, 1, s.ts)
            self.bind(st, 2, s.charge);  self.bind(st, 3, s.health);  self.bind(st, 4, s.battTemp)
            self.bind(st, 5, s.cpuTemp); self.bind(st, 6, s.gpuTemp); self.bind(st, 7, s.systemW); self.bind(st, 8, s.fanRPM)
            sqlite3_bind_int(st, 9, s.charging ? 1 : 0)
            sqlite3_step(st)
            sqlite3_exec(db, "DELETE FROM samples WHERE ts < \(s.ts - keepSeconds);", nil, nil, nil)
        }
    }

    /// UI-friendly aggregate: all SQLite waits happen away from main, while the
    /// existing serial queue remains the single owner of the connection.
    func dashboard(chargeSince: Int64, healthSince: Int64,
                   completion: @escaping (Dashboard) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let span = self.span()
            let value = Dashboard(
                charge: self.series(.charge, since: chargeSince),
                health: self.series(.health, since: healthSince),
                earliest: span.earliest,
                count: span.count,
                battery: BatteryReader.read()
            )
            DispatchQueue.main.async { completion(value) }
        }
    }

    func exportCSV(since: Int64, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let csv = self.exportCSV(since: since)
            DispatchQueue.main.async { completion(csv) }
        }
    }

    /// Точки метрики с момента `since` до сейчас (sync). NULL-значения метрики пропускаются (честно — «нет данных»).
    func series(_ metric: Metric, since: Int64) -> [(ts: Int64, v: Double)] {
        q.sync {
            guard let db = db else { return [] }
            var st: OpaquePointer?
            let sql = "SELECT ts, \(metric.rawValue) FROM samples WHERE ts>=? AND \(metric.rawValue) IS NOT NULL ORDER BY ts;"
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(st) }
            sqlite3_bind_int64(st, 1, since)
            var out: [(ts: Int64, v: Double)] = []
            while sqlite3_step(st) == SQLITE_ROW {
                out.append((sqlite3_column_int64(st, 0), sqlite3_column_double(st, 1)))
            }
            return out
        }
    }

    /// (самая ранняя точка, всего строк) — для подписи «данные с …» и состояния «накопление».
    func span() -> (earliest: Int64?, count: Int) {
        q.sync {
            guard let db = db else { return (nil, 0) }
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT MIN(ts), COUNT(*) FROM samples;", -1, &st, nil) == SQLITE_OK else { return (nil, 0) }
            defer { sqlite3_finalize(st) }
            guard sqlite3_step(st) == SQLITE_ROW else { return (nil, 0) }
            let earliest = sqlite3_column_type(st, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(st, 0)
            return (earliest, Int(sqlite3_column_int64(st, 1)))
        }
    }

    /// Число точек за окно since..сейчас — чтобы подпись отчёта совпадала с его периодом (не всей 90д базой).
    func countSince(_ since: Int64) -> Int {
        q.sync {
            guard let db = db else { return 0 }
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM samples WHERE ts>=?;", -1, &st, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(st) }
            sqlite3_bind_int64(st, 1, since)
            guard sqlite3_step(st) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(st, 0))
        }
    }

    /// CSV всех точек за период (для Pro-экспорта). Заголовок + строки; пустые метрики — пусто.
    func exportCSV(since: Int64) -> String {
        q.sync {
            guard let db = db else { return "" }
            var st: OpaquePointer?
            let sql = "SELECT ts,charge,health,battTemp,cpuTemp,gpuTemp,systemW,fanRPM,charging FROM samples WHERE ts>=? ORDER BY ts;"
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return "" }
            defer { sqlite3_finalize(st) }
            sqlite3_bind_int64(st, 1, since)
            var lines = ["timestamp,charge_pct,health_pct,batt_temp_c,cpu_temp_c,gpu_temp_c,system_w,fan_rpm,charging"]
            let iso = ISO8601DateFormatter()
            while sqlite3_step(st) == SQLITE_ROW {
                func d(_ i: Int32) -> String { sqlite3_column_type(st, i) == SQLITE_NULL ? "" : String(format: "%.2f", sqlite3_column_double(st, i)) }
                let ts = sqlite3_column_int64(st, 0)
                let stamp = iso.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
                lines.append("\(stamp),\(d(1)),\(d(2)),\(d(3)),\(d(4)),\(d(5)),\(d(6)),\(d(7)),\(sqlite3_column_int(st, 8))")
            }
            return lines.joined(separator: "\n")
        }
    }
}
