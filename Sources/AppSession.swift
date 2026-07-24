import Foundation

/// Сессионные ряды вкладки «Приложения»: история impact (спарклайн) и множество стран-назначений
/// по приложению. НОЛЬ новых системных чтений — push из уже-собранных снимков (top + гео-флаги).
/// Живёт ровно процесс, без диск-персиста (дисциплина как у SessionEnergy / SensorsModel.history).
///
/// ПОТОК: все мутаторы/геттеры зовутся с main (pushImpacts — из updateApps; addCountry — из
/// completion-блока refreshAppFlags на main). Гео-цикл, что реально читает GeoIP, крутится в фоне;
/// он должен собрать коды локально и передать их сюда уже на main (см. main.swift refreshAppFlags).
enum AppSession {
    private static let cap = 32                                   // кольцо истории impact на приложение
    private static var impactHist: [String: [Double]] = [:]
    private static var countries: [String: Set<String>] = [:]    // nameLower → ISO-коды (US, DE…)
    private static var lastKeys = Set<String>()                  // эвикт исчезнувших имён (не течь)

    /// Толкнуть снимок top. Зовётся из updateApps ПЕРЕД renderAppRows (один раз на снимок, ~раз/5с).
    /// cap 32 ≈ 2.5 мин истории.
    static func pushImpacts(_ apps: [AppEnergy]) {
        let keys = Set(apps.map { $0.name })
        for a in apps {
            var h = impactHist[a.name] ?? []
            h.append(a.impact)
            if h.count > cap { h.removeFirst(h.count - cap) }
            impactHist[a.name] = h
        }
        // эвикт имён, выпавших из топа — держим карту компактной (топ-6..30)
        for gone in lastKeys.subtracting(keys) {
            impactHist[gone] = nil                // impactHist ключуется сырым именем — эвикт корректен
            countries[gone.lowercased()] = nil    // countries ключуется nameLower — иначе не течёт эвикт
        }
        lastKeys = keys
    }

    /// Накопить один код страны-назначения. key — name.lowercased() (как appCountryFlags),
    /// code — ISO из GeoIP.countryCode. Зовётся с main.
    static func addCountry(_ nameLower: String, code: String) {
        countries[nameLower, default: []].insert(code)
    }

    /// Накопить набор кодов страны-назначения для одного приложения за раз (удобно из completion).
    static func addCountries(_ nameLower: String, codes: Set<String>) {
        guard !codes.isEmpty else { return }
        countries[nameLower, default: []].formUnion(codes)
    }

    // MARK: API для вида

    /// История impact приложения (по СЫРОМУ имени, как ключ top). Для спарклайна героя/строк.
    static func history(_ name: String) -> [Double] { impactHist[name] ?? [] }

    /// Отсортированные ISO-коды стран-назначений (по nameLower). Для кластера флагов / ховер-раскрытия.
    static func countryCodes(nameLower: String) -> [String] {
        (countries[nameLower] ?? []).sorted()
    }

    // MARK: - История общего числа соединений (спарклайн вкладки «Приватность»)

    private static let connCap = 120                             // 120 × ~5с ≈ 10 мин тренда
    private static var connTotals: [Int] = []

    /// Толкнуть суммарное число активных соединений (уникальных ip:port по всем приложениям).
    /// Зовётся из refreshAppFlags КАЖДЫЙ снимок (≈раз/5с), даже когда поповер закрыт — реальный
    /// сессионный тренд, а не только «пока смотрю». Ноль новых системных чтений (уже собранный снимок).
    static func pushConnTotal(_ n: Int) {
        connTotals.append(n)
        if connTotals.count > connCap { connTotals.removeFirst(connTotals.count - connCap) }
    }

    /// История числа соединений за сессию (для спарклайна радара).
    static func connHistory() -> [Int] { connTotals }

    // MARK: - История СУММАРНОГО impact топа (спарклайн-футер вкладки «Приложения»)

    private static let topTotalCap = 120                         // 120 × ~5с ≈ 10 мин тренда
    private static var topTotals: [Double] = []

    /// Толкнуть суммарный energy-impact текущего топа (из уже собранного top-снимка, ноль новых чтений).
    static func pushTopTotal(_ v: Double) {
        topTotals.append(v)
        if topTotals.count > topTotalCap { topTotals.removeFirst(topTotals.count - topTotalCap) }
    }
    static func topTotalHistory() -> [Double] { topTotals }

    // MARK: - Журнал соединений за сессию (дедуп-леджер app+endpoint)
    //
    // Наблюдательный журнал: каждое активное соединение из 5с-снимка отмечается здесь; повтор → count++
    // и last=now. Живёт только в памяти процесса (как остальные ряды) — при перезапуске обнуляется.
    // Ноль новых системных чтений: питается из УЖЕ собранного снимка refreshAppFlags. `count` — сколько раз
    // соединение попало в снимок (не число сетевых запросов) — честно называем «наблюдений».

    struct LedgerEntry {
        let appId: String
        let app: String
        let endpoint: String
        var code: String?       // ISO страны (nil = локальная/приватная/неизвестная — как в радаре)
        var first: Date
        var last: Date
        var count: Int
    }
    private static let ledgerCap = 600                          // потолок записей; сверх — эвикт самых старых по last
    private static var ledger: [String: LedgerEntry] = [:]      // key = appId|endpoint

    /// Отметить активное соединение в журнале. Зовётся из refreshAppFlags на main (один снимок ≈раз/5с).
    static func noteConnection(appId: String, app: String, endpoint: String, code: String?, now: Date) {
        let key = appId + "|" + endpoint
        if var e = ledger[key] {
            e.last = now; e.count += 1
            if e.code == nil, code != nil { e.code = code }     // гео могло доехать позже — не теряем
            ledger[key] = e
        } else {
            ledger[key] = LedgerEntry(appId: appId, app: app, endpoint: endpoint, code: code, first: now, last: now, count: 1)
            // самый давно не виденный — вон; тай-брейк по first (при >600 уникальных за один снимок все
            // last==now → выбрасываем самый давно ИЗВЕСТНЫЙ, а не только что вставленный активный).
            if ledger.count > ledgerCap,
               let k = ledger.min(by: { ($0.value.last, $0.value.first) < ($1.value.last, $1.value.first) })?.key {
                ledger[k] = nil
            }
        }
    }

    /// Журнал за сессию, свежие сверху (по last-seen). Внешние направления (есть страна) выше локальных.
    static func connectionLog() -> [LedgerEntry] {
        ledger.values.sorted {
            if ($0.code != nil) != ($1.code != nil) { return $0.code != nil }
            return $0.last > $1.last
        }
    }
    static func clearLog() { ledger.removeAll() }
}
