import Foundation
import CommonCrypto

private extension String {
    var crashStoreTrimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

/// Хранилище отчётов о сбоях Kelvin.
///
/// Отвечает за:
/// - обнаружение новых crash reports Kelvin в ~/Library/Logs/DiagnosticReports;
/// - вычисление стабильного fingerprint для deduplication;
/// - хранение состояний отчётов (discovered/reviewed/consented/queued/sent/declined/expired);
/// - предотвращение повторной отправки одного и того же crash;
/// - удаление локальных payload через ограниченный срок.
///
/// Хранение metadata: ~/Library/Application Support/Kelvin/CrashReports/
enum CrashReportStore {
    
    // MARK: - Public models
    
    /// Состояние отчёта о сбое.
    enum State: String, Codable {
        /// Обнаружен новый crash report.
        case discovered
        /// Пользователь просмотрел отчёт.
        case reviewed
        /// Получено согласие на отправку.
        case consented
        /// Отчёт добавлен в очередь отправки.
        case queued
        /// Успешно отправлен.
        case sent
        /// Пользователь отказался от отправки.
        case declined
        /// Истёк срок хранения.
        case expired
    }
    
    /// Метаданные одного crash report.
    struct ReportMetadata: Codable {
        /// Уникальный идентификатор отчёта (UUID).
        let reportID: String
        
        /// Fingerprint исходного .ips файла (SHA256 hash первых 8KB).
        let fingerprint: String
        
        /// Имя исходного файла .ips.
        let sourceFilename: String
        
        /// Дата обнаружения отчёта.
        let discoveredAt: Date
        
        /// Дата падения (из timestamp в .ips).
        let crashDate: Date?
        
        /// Текущее состояние.
        var state: State
        
        /// Дата последнего изменения состояния.
        var updatedAt: Date
        
        /// Количество попыток отправки.
        var sendAttempts: Int
        
        /// Дата последней попытки отправки.
        var lastSendAttempt: Date?
        
        /// Ошибка последней попытки (если была).
        var lastError: String?
        
        /// ID отчёта на сервере (после успешной отправки).
        var serverReportID: String?
        
        init(
            reportID: String = UUID().uuidString,
            fingerprint: String,
            sourceFilename: String,
            discoveredAt: Date = Date(),
            crashDate: Date?,
            state: State = .discovered,
            updatedAt: Date = Date(),
            sendAttempts: Int = 0,
            lastSendAttempt: Date? = nil,
            lastError: String? = nil,
            serverReportID: String? = nil
        ) {
            self.reportID = reportID
            self.fingerprint = fingerprint
            self.sourceFilename = sourceFilename
            self.discoveredAt = discoveredAt
            self.crashDate = crashDate
            self.state = state
            self.updatedAt = updatedAt
            self.sendAttempts = sendAttempts
            self.lastSendAttempt = lastSendAttempt
            self.lastError = lastError
            self.serverReportID = serverReportID
        }
        
        mutating func transition(to newState: State) {
            guard state != newState else { return }
            state = newState
            updatedAt = Date()
        }
        
        mutating func recordSendAttempt(error: String?) {
            sendAttempts += 1
            lastSendAttempt = Date()
            lastError = error
        }
        
        mutating func setServerReportID(_ id: String) {
            serverReportID = id
        }
    }
    
    /// Результат сканирования хранилища.
    struct ScanResult {
        /// Новые отчёты, требующие внимания пользователя.
        let newReports: [ReportMetadata]
        
        /// Отчёты в очереди на отправку.
        let queuedReports: [ReportMetadata]
        
        /// Все известные отчёты.
        let allReports: [ReportMetadata]
    }
    
    // MARK: - Constants
    
    private static let applicationSupportDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first!.appendingPathComponent("Kelvin", isDirectory: true)
    
    private static let crashReportsDirectory = applicationSupportDirectory
        .appendingPathComponent("CrashReports", isDirectory: true)
    
    private static let diagnosticReportsDirectory = URL(
        fileURLWithPath: NSHomeDirectory()
    ).appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    
    private static let metadataFilename = "crash_reports.json"
    
    /// Максимальный возраст отчёта для обработки (7 дней).
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    
    /// Размер данных для вычисления fingerprint (8 KB).
    private static let fingerprintReadSize = 8 * 1024
    
    // MARK: - Private storage
    
    private static let queue = DispatchQueue(
        label: "com.trykelvin.crashreportstore",
        qos: .userInitiated,
        attributes: .concurrent
    )
    
    private static var cachedMetadata: [ReportMetadata]?
    private static var metadataLastLoad: Date?
    private static let metadataCacheLifetime: TimeInterval = 5
    
    // MARK: - Public API
    
    /// Инициализировать хранилище (создать директорию при необходимости).
    static func initialize() throws {
        try queue.sync {
            let fm = FileManager.default
            if !fm.fileExists(atPath: crashReportsDirectory.path) {
                try fm.createDirectory(
                    at: crashReportsDirectory,
                    withIntermediateDirectories: true
                )
            }
        }
    }
    
    /// Просканировать системные DiagnosticReports и обновить локальное хранилище.
    /// Возвращает новые отчёты Kelvin за последние 7 дней.
    static func scan() -> ScanResult {
        queue.sync {
            performScan()
        }
    }
    
    /// Получить все отчёты с указанным состоянием.
    static func reports(state: State) -> [ReportMetadata] {
        queue.sync {
            loadMetadata().filter { $0.state == state }
        }
    }

    static func report(id: String) -> ReportMetadata? {
        queue.sync {
            loadMetadata().first { $0.reportID == id }
        }
    }

    static func sourceURL(for report: ReportMetadata) -> URL {
        diagnosticReportsDirectory.appendingPathComponent(report.sourceFilename)
    }
    
    /// Получить отчёт по fingerprint.
    static func report(byFingerprint fingerprint: String) -> ReportMetadata? {
        queue.sync {
            loadMetadata().first { $0.fingerprint == fingerprint }
        }
    }
    
    /// Обновить состояние отчёта.
    static func updateState(for fingerprint: String, to state: State) throws {
        try queue.sync(flags: .barrier) {
            var metadata = loadMetadata()
            guard let index = metadata.firstIndex(where: { $0.fingerprint == fingerprint }) else {
                throw StoreError.notFound
            }
            metadata[index].transition(to: state)
            saveMetadata(metadata)
        }
    }
    
    /// Записать ошибку отправки для отчёта.
    static func recordSendError(for fingerprint: String, error: String) throws {
        try queue.sync(flags: .barrier) {
            var metadata = loadMetadata()
            guard let index = metadata.firstIndex(where: { $0.fingerprint == fingerprint }) else {
                throw StoreError.notFound
            }
            metadata[index].recordSendAttempt(error: error)
            saveMetadata(metadata)
        }
    }
    
    /// Записать успешную отправку отчёта.
    static func recordSendSuccess(for fingerprint: String, serverReportID: String) throws {
        try queue.sync(flags: .barrier) {
            var metadata = loadMetadata()
            guard let index = metadata.firstIndex(where: { $0.fingerprint == fingerprint }) else {
                throw StoreError.notFound
            }
            metadata[index].transition(to: .sent)
            metadata[index].setServerReportID(serverReportID)
            saveMetadata(metadata)
        }
    }
    
    /// Удалить старые отчёты (отправленные > 24ч, отклонённые > 7 дней).
    static func cleanupExpired() {
        queue.sync(flags: .barrier) {
            let now = Date()
            var metadata = loadMetadata()
            
            let sentExpiration: TimeInterval = 24 * 60 * 60
            let declinedExpiration: TimeInterval = 7 * 24 * 60 * 60
            
            metadata = metadata.filter { report in
                switch report.state {
                case .sent:
                    return now.timeIntervalSince(report.updatedAt) < sentExpiration
                case .declined:
                    return now.timeIntervalSince(report.updatedAt) < declinedExpiration
                default:
                    return now.timeIntervalSince(report.discoveredAt) < maxAge
                }
            }
            
            saveMetadata(metadata)
        }
    }
    
    // MARK: - Private implementation
    
    private enum StoreError: LocalizedError {
        case notFound
        case readError
        case writeError
        
        var errorDescription: String? {
            switch self {
            case .notFound:
                return "Отчёт не найден"
            case .readError:
                return "Ошибка чтения метаданных"
            case .writeError:
                return "Ошибка записи метаданных"
            }
        }
    }
    
    private static func performScan() -> ScanResult {
        let fm = FileManager.default
        
        // Проверка существования директории
        guard fm.fileExists(atPath: diagnosticReportsDirectory.path) else {
            return ScanResult(newReports: [], queuedReports: [], allReports: loadMetadata())
        }
        
        // Получение списка файлов .ips
        let files: [String]
        do {
            files = try fm.contentsOfDirectory(atPath: diagnosticReportsDirectory.path)
        } catch {
            Log.app.error("CrashReportStore: не удалось прочитать DiagnosticReports: \(error.localizedDescription, privacy: .public)")
            return ScanResult(newReports: [], queuedReports: [], allReports: loadMetadata())
        }
        
        let cutoffDate = Date().addingTimeInterval(-maxAge)
        let existingMetadata = loadMetadata()
        let existingFingerprints = Set(existingMetadata.map { $0.fingerprint })
        
        var newReports: [ReportMetadata] = []
        
        for filename in files where filename.hasSuffix(".ips") {
            let url = diagnosticReportsDirectory.appendingPathComponent(filename)
            
            // Проверка: это crash Kelvin?
            guard isKelvinCrash(url: url) else {
                continue
            }
            
            // Вычисление fingerprint
            guard let fingerprint = computeFingerprint(url: url) else {
                continue
            }
            
            // Пропуск известных отчётов
            if existingFingerprints.contains(fingerprint) {
                continue
            }
            
            // Извлечение даты падения
            let crashDate = extractCrashDate(url: url)
            
            // Пропуск старых отчётов
            if let crashDate = crashDate, crashDate < cutoffDate {
                continue
            }
            
            // Создание метаданных
            let metadata = ReportMetadata(
                fingerprint: fingerprint,
                sourceFilename: filename,
                crashDate: crashDate
            )
            
            newReports.append(metadata)
        }
        
        // Сохранение новых отчётов
        if !newReports.isEmpty {
            var metadata = loadMetadata()
            metadata.append(contentsOf: newReports)
            saveMetadata(metadata)
        }
        
        let allMetadata = loadMetadata()
        let queuedReports = allMetadata.filter { $0.state == .queued || $0.state == .consented }
        
        return ScanResult(
            newReports: newReports,
            queuedReports: queuedReports,
            allReports: allMetadata
        )
    }
    
    private static func isKelvinCrash(url: URL) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            return false
        }
        
        let data = handle.readData(ofLength: 16 * 1024)
        try? handle.close()
        
        guard let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(separator: "\n", maxSplits: 1).first,
              let object = try? JSONSerialization.jsonObject(with: Data(firstLine.utf8), options: []),
              let dictionary = object as? [String: Any] else {
            return false
        }
        
        // bug_type 309 = macOS crash
        if let bugType = dictionary["bug_type"] as? Int, bugType != 309 {
            return false
        }
        
        // Проверка имени процесса
        let processName = (dictionary["app_name"] as? String)?
            .crashStoreTrimmedNonEmpty
            ?? (dictionary["proc_name"] as? String)?
            .crashStoreTrimmedNonEmpty
            ?? (dictionary["process"] as? String)?
            .crashStoreTrimmedNonEmpty
        
        guard let name = processName?.lowercased() else {
            return false
        }
        
        // Имена процессов Kelvin
        let kelvinNames = ["kelvin", "kelvin helper", "kelvin service"]
        return kelvinNames.contains(name)
    }
    
    private static func computeFingerprint(url: URL) -> String? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            return nil
        }
        
        let data = handle.readData(ofLength: fingerprintReadSize)
        try? handle.close()
        
        // SHA256 hash
        var hash = [UInt8](repeating: 0, count: 32)
        _ = CC_SHA256((data as NSData).bytes, CC_LONG(data.count), &hash)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    private static func extractCrashDate(url: URL) -> Date? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            return nil
        }
        
        let data = handle.readData(ofLength: 16 * 1024)
        try? handle.close()
        
        guard let text = String(data: data, encoding: .utf8),
              let firstLine = text.split(separator: "\n", maxSplits: 1).first,
              let object = try? JSONSerialization.jsonObject(with: Data(firstLine.utf8), options: []),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        
        // Попытка извлечь дату из timestamp
        if let timestamp = dictionary["timestamp"] as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: timestamp) {
                return date
            }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: timestamp) {
                return date
            }
        }
        
        // Попытка извлечь дату из имени файла
        let filename = url.deletingPathExtension().lastPathComponent
        let pattern = #"\d{4}-\d{2}-\d{2}-\d{6}"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: filename, range: NSRange(filename.startIndex..., in: filename)),
           let range = Range(match.range(at: 0), in: filename) {
            let dateStr = String(filename[range])
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            if let date = formatter.date(from: dateStr) {
                return date
            }
        }
        
        return nil
    }
    
    private static func loadMetadata() -> [ReportMetadata] {
        // Проверка кэша
        if let cached = cachedMetadata,
           let lastLoad = metadataLastLoad,
           Date().timeIntervalSince(lastLoad) < metadataCacheLifetime {
            return cached
        }
        
        let metadataURL = crashReportsDirectory.appendingPathComponent(metadataFilename)
        
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            cachedMetadata = []
            metadataLastLoad = Date()
            return []
        }
        
        do {
            let data = try Data(contentsOf: metadataURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let metadata = try decoder.decode([ReportMetadata].self, from: data)
            cachedMetadata = metadata
            metadataLastLoad = Date()
            return metadata
        } catch {
            Log.app.error("CrashReportStore: ошибка чтения метаданных: \(error.localizedDescription, privacy: .public)")
            cachedMetadata = []
            metadataLastLoad = Date()
            return []
        }
    }
    
    private static func saveMetadata(_ metadata: [ReportMetadata]) {
        let metadataURL = crashReportsDirectory.appendingPathComponent(metadataFilename)
        
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            try data.write(to: metadataURL, options: .atomic)
            cachedMetadata = metadata
            metadataLastLoad = Date()
        } catch {
            Log.app.error("CrashReportStore: ошибка записи метаданных: \(error.localizedDescription, privacy: .public)")
        }
    }
}
