import Foundation
import CommonCrypto
import Darwin

/// Санитизатор отчётов о сбоях Kelvin.
///
/// Преобразует системные .ips файлы в санитизированный JSON payload,
/// удаляя персональные данные и чувствительную информацию.
///
/// Использует allowlist подход: включаются только явно разрешённые поля.
enum CrashReportSanitizer {
    
    // MARK: - Public models
    
    /// Версия схемы отчёта.
    static let schemaVersion = "1.0"
    
    /// Максимальный размер payload (512 KiB).
    static let maxPayloadSize = 512 * 1024
    
    /// Максимум потоков в отчёте.
    static let maxThreads = 10
    
    /// Максимум фреймов на поток.
    static let maxFramesPerThread = 50
    
    /// Максимум binary images.
    static let maxBinaryImages = 20
    
    /// Максимум breadcrumbs.
    static let maxBreadcrumbs = 50
    
    /// Санированный отчёт о сбое.
    struct SanitizedReport: Codable {
        /// Версия схемы.
        let schemaVersion: String
        
        /// Идентификатор отчёта.
        let reportID: String
        
        /// Время генерации отчёта.
        let generatedAt: Date
        
        /// Время падения (с точностью до минуты).
        let crashTimestamp: Date?
        
        /// Информация о приложении.
        let application: ApplicationInfo
        
        /// Информация о системе.
        let system: SystemInfo
        
        /// Информация о падении.
        let crash: CrashInfo?
        
        /// Breadcrumbs (события перед падением).
        let breadcrumbs: [Breadcrumb]?
        
        /// Исходный fingerprint для deduplication.
        let sourceFingerprint: String
    }
    
    /// Информация о приложении.
    struct ApplicationInfo: Codable {
        /// Название приложения.
        let name: String
        
        /// Версия (CFBundleShortVersionString).
        let version: String
        
        /// Номер сборки (CFBundleVersion).
        let buildNumber: String
        
        /// Bundle identifier.
        let bundleID: String?
    }
    
    /// Информация о системе.
    struct SystemInfo: Codable {
        /// Версия macOS.
        let macosVersion: String
        
        /// Сборка macOS.
        let macosBuild: String
        
        /// Модель Mac.
        let hardwareModel: String
        
        /// Архитектура процессора.
        let architecture: String
    }
    
    /// Информация о падении.
    struct CrashInfo: Codable {
        /// Тип исключения.
        let exceptionType: String?
        
        /// Код исключения.
        let exceptionCode: String?
        
        /// Сигнал POSIX.
        let signal: String?
        
        /// Причина завершения.
        let terminationReason: String?
        
        /// Имя упавшего потока.
        let crashedThreadName: String?
        
        /// Индекс упавшего потока.
        let crashedThreadIndex: Int?
        
        /// Стек вызовов упавшего потока.
        let stackTrace: [StackFrame]
        
        /// Binary images.
        let binaryImages: [BinaryImage]
    }
    
    /// Элемент стека вызовов.
    struct StackFrame: Codable {
        /// Номер фрейма.
        let index: Int
        
        /// Адрес возврата.
        let address: String
        
        /// Название бинарного файла.
        let binaryName: String
        
        /// Смещение в бинарном файле.
        let offset: Int
        
        /// Символизированное имя функции (если доступно).
        let symbolName: String?
    }
    
    /// Binary image.
    struct BinaryImage: Codable {
        /// Название бинарного файла.
        let name: String
        
        /// UUID бинарного файла.
        let uuid: String
        
        /// Базовый адрес.
        let baseAddress: String?
        
        /// Размер.
        let size: Int?
        
        /// Это системный Apple framework.
        let isSystemFramework: Bool
        
        /// Это основной бинарный файл приложения.
        let isMainExecutable: Bool
    }
    
    /// Событие breadcrumb.
    struct Breadcrumb: Codable {
        /// Тип события.
        let type: String
        
        /// Время события (относительно падения).
        let relativeTimestamp: TimeInterval
        
        /// Дополнительные данные (safe values only).
        let metadata: [String: String]?
    }
    
    /// Результат санитизации.
    struct SanitizationResult {
        /// Санированный отчёт.
        let report: SanitizedReport
        
        /// JSON представление для preview.
        let jsonPreview: String
        
        /// JSON представление для отправки.
        let jsonPayload: Data
        
        /// Содержит ли PII (должно быть всегда false).
        let containsPII: Bool
        
        /// Предупреждения о проблемах санитизации.
        let warnings: [String]
    }
    
    // MARK: - Constants
    
    /// Allowlist имён процессов Kelvin.
    private static let kelvinProcessNames = ["kelvin", "kelvin helper", "kelvin service"]
    
    /// Allowlist префиксов для binary images (системные Apple frameworks).
    private static let allowedSystemFrameworks = [
        "/System/Library/Frameworks/",
        "/System/Library/PrivateFrameworks/",
        "/usr/lib/swift/",
        "/usr/lib/system/"
    ]
    
    /// Паттерны PII для обнаружения.
    private static let piiPatterns: [(pattern: String, description: String)] = [
        (#"/Users/[^/\s]+"#, "User path"),
        (#"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#, "Email"),
        (#"\b[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\b"#i, "UUID"),
        (#"\b[A-Z0-9]{8}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{12}\b"#, "Hardware UUID"),
    ]
    
    // MARK: - Public API
    
    /// Санировать crash report из URL.
    ///
    /// - Parameters:
    ///   - url: URL к .ips файлу
    ///   - reportID: Уникальный идентификатор отчёта
    ///   - sourceFingerprint: Fingerprint исходного файла
    ///   - breadcrumbs: Опциональные breadcrumbs
    /// - Returns: Результат санитизации или ошибка
    static func sanitize(
        url: URL,
        reportID: String,
        sourceFingerprint: String,
        breadcrumbs: [CrashBreadcrumb] = []
    ) -> Result<SanitizationResult, Error> {
        // Чтение файла
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            return .failure(SanitizationError.readError("Не удалось открыть файл"))
        }
        
        let data = handle.readDataToEndOfFile()
        try? handle.close()
        
        guard let content = String(data: data, encoding: .utf8) else {
            return .failure(SanitizationError.parseError("Не удалось прочитать содержимое"))
        }
        
        // Парсинг header (первая строка JSON)
        guard let firstLine = content.split(separator: "\n", maxSplits: 1).first,
              let headerData = Data(firstLine.utf8),
              let header = try? JSONSerialization.jsonObject(with: headerData, options: []) as? [String: Any] else {
            return .failure(SanitizationError.parseError("Не удалось распарсить header"))
        }
        
        // Извлечение информации
        var warnings: [String] = []
        
        // Application info
        guard let appInfo = extractApplicationInfo(header: header, warnings: &warnings) else {
            return .failure(SanitizationError.parseError("Не удалось извлечь информацию о приложении"))
        }
        
        // System info
        let systemInfo = extractSystemInfo(warnings: &warnings)
        
        // Crash info
        let crashInfo = extractCrashInfo(content: content, header: header, warnings: &warnings)
        
        // Breadcrumbs
        let sanitizedBreadcrumbs = sanitizeBreadcrumbs(breadcrumbs)
        
        // Timestamp
        let crashTimestamp = extractTimestamp(header: header)
        
        // Построение отчёта
        let report = SanitizedReport(
            schemaVersion: schemaVersion,
            reportID: reportID,
            generatedAt: Date(),
            crashTimestamp: crashTimestamp.map { truncateTimestamp($0) },
            application: appInfo,
            system: systemInfo,
            crash: crashInfo,
            breadcrumbs: sanitizedBreadcrumbs.isEmpty ? nil : sanitizedBreadcrumbs,
            sourceFingerprint: sourceFingerprint
        )
        
        // Кодирование в JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        guard let jsonData = try? encoder.encode(report) else {
            return .failure(SanitizationError.encodingError("Не удалось закодировать JSON"))
        }
        
        // Проверка размера
        if jsonData.count > maxPayloadSize {
            warnings.append("Payload превышает максимальный размер, требуется truncation")
            // В реальной реализации здесь была бы логика truncation
        }
        
        // Проверка на PII
        let jsonString = String(data: jsonData, encoding: .utf8) ?? ""
        let containsPII = checkForPII(jsonString)
        
        if containsPII {
            warnings.append("Обнаружены потенциальные PII в payload")
        }
        
        let previewJSON = jsonString.prefix(2000) + (jsonString.count > 2000 ? "\n... (truncated)" : "")
        
        return .success(SanitizationResult(
            report: report,
            jsonPreview: String(previewJSON),
            jsonPayload: jsonData,
            containsPII: containsPII,
            warnings: warnings
        ))
    }
    
    /// Санировать breadcrumbs.
    static func sanitizeBreadcrumbs(_ breadcrumbs: [CrashBreadcrumb]) -> [Breadcrumb] {
        breadcrumbs.prefix(maxBreadcrumbs).map { breadcrumb in
            Breadcrumb(
                type: breadcrumb.typeName,
                relativeTimestamp: breadcrumb.relativeTimestamp,
                metadata: breadcrumb.safeMetadata
            )
        }
    }
    
    // MARK: - Private implementation
    
    private enum SanitizationError: LocalizedError {
        case readError(String)
        case parseError(String)
        case encodingError(String)
        
        var errorDescription: String? {
            switch self {
            case .readError(let msg):
                return "Ошибка чтения: \(msg)"
            case .parseError(let msg):
                return "Ошибка парсинга: \(msg)"
            case .encodingError(let msg):
                return "Ошибка кодирования: \(msg)"
            }
        }
    }
    
    private static func extractApplicationInfo(
        header: [String: Any],
        warnings: inout [String]
    ) -> ApplicationInfo? {
        let name = (header["app_name"] as? String)?.trimmedNonEmpty
            ?? (header["proc_name"] as? String)?.trimmedNonEmpty
            ?? "Unknown"
        
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "Unknown"
        
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "Unknown"
        
        let bundleID = Bundle.main.bundleIdentifier
        
        return ApplicationInfo(
            name: name,
            version: version,
            buildNumber: buildNumber,
            bundleID: bundleID
        )
    }
    
    private static func extractSystemInfo(warnings: inout [String]) -> SystemInfo {
        let processInfo = ProcessInfo.processInfo
        
        let macosVersion = "\(processInfo.operatingSystemVersion.majorVersion).\(processInfo.operatingSystemVersion.minorVersion).\(processInfo.operatingSystemVersion.patchVersion)"
        
        let macosBuild = getMacOSBuildNumber() ?? "Unknown"
        
        let hardwareModel = getHardwareModel() ?? "Unknown"
        
        let architecture = getArchitecture()
        
        return SystemInfo(
            macosVersion: macosVersion,
            macosBuild: macosBuild,
            hardwareModel: hardwareModel,
            architecture: architecture
        )
    }
    
    private static func extractCrashInfo(
        content: String,
        header: [String: Any],
        warnings: inout [String]
    ) -> CrashInfo? {
        let exceptionType = header["exception_type"] as? String
        let exceptionCode = header["exception_code"] as? String
        let signal = header["signal"] as? String
        let terminationReason = header["termination_reason"] as? String
        
        // Парсинг threads из content
        let threads = parseThreads(content: content)
        
        // Определение crashed thread
        let crashedThreadIndex = header["crashed_thread"] as? Int ?? 0
        let crashedThread = threads[safe: crashedThreadIndex]
        let crashedThreadName = crashedThread?.name
        
        // Извлечение stack trace
        let stackTrace = extractStackTrace(
            thread: crashedThread,
            maxFrames: maxFramesPerThread
        )
        
        // Извлечение binary images
        let binaryImages = extractBinaryImages(content: content, maxImages: maxBinaryImages)
        
        return CrashInfo(
            exceptionType: exceptionType,
            exceptionCode: exceptionCode,
            signal: signal,
            terminationReason: terminationReason,
            crashedThreadName: crashedThreadName,
            crashedThreadIndex: crashedThreadIndex,
            stackTrace: stackTrace,
            binaryImages: binaryImages
        )
    }
    
    private static func extractTimestamp(header: [String: Any]) -> Date? {
        guard let timestamp = header["timestamp"] as? String else {
            return nil
        }
        
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: timestamp) {
            return date
        }
        
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: timestamp)
    }
    
    private static func truncateTimestamp(_ date: Date) -> Date {
        // Округление до минуты для privacy
        let interval = floor(date.timeIntervalSince1970 / 60) * 60
        return Date(timeIntervalSince1970: interval)
    }
    
    private static func parseThreads(content: String) -> [ParsedThread] {
        // Упрощённый парсинг threads
        // В реальной реализации нужен более надёжный парсер
        return []
    }
    
    private static func extractStackTrace(thread: ParsedThread?, maxFrames: Int) -> [StackFrame] {
        guard let thread = thread else {
            return []
        }
        
        return thread.frames.prefix(maxFrames).enumerated().map { (index, frame) in
            StackFrame(
                index: index,
                address: frame.address,
                binaryName: frame.binaryName,
                offset: frame.offset,
                symbolName: frame.symbolName
            )
        }
    }
    
    private static func extractBinaryImages(content: String, maxImages: Int) -> [BinaryImage] {
        // Упрощённое извлечение binary images
        // В реальной реализации нужен парсер секции "Binary Images"
        return []
    }
    
    private static func checkForPII(_ text: String) -> Bool {
        for patternTuple in piiPatterns {
            let pattern = patternTuple.pattern
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)) != nil {
                return true
            }
        }
        return false
    }
    
    private static func getHardwareModel() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else {
            return nil
        }
        
        return String(cString: buf)
    }
    
    private static func getArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
    
    private static func getMacOSBuildNumber() -> String? {
        // Получение build number из SystemVersion.plist
        let plistPath = "/System/Library/CoreServices/SystemVersion.plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let build = plist["ProductBuildVersion"] as? String else {
            return nil
        }
        
        return build
    }
}

// MARK: - Supporting types

/// Внутреннее представление потока.
private struct ParsedThread {
    let name: String?
    let frames: [ParsedFrame]
}

/// Внутреннее представление фрейма.
private struct ParsedFrame {
    let address: String
    let binaryName: String
    let offset: Int
    let symbolName: String?
}

/// Расширение для safe array access.
private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Crash Breadcrumb integration

/// Публичный интерфейс для breadcrumbs.
enum CrashBreadcrumb {
    case appStarted
    case popoverOpened
    case popoverClosed
    case settingsOpened(section: String)
    case settingsClosed
    case helperConnectionChanged(state: String)
    case updateStateChanged(state: String)
    case sensorAvailabilityChanged(state: String)
    case licenseCheckPerformed(result: String)
    case backgroundTaskStarted(name: String)
    case backgroundTaskCompleted(name: String)
    
    var typeName: String {
        switch self {
        case .appStarted: return "app_started"
        case .popoverOpened: return "popover_opened"
        case .popoverClosed: return "popover_closed"
        case .settingsOpened: return "settings_opened"
        case .settingsClosed: return "settings_closed"
        case .helperConnectionChanged: return "helper_connection_changed"
        case .updateStateChanged: return "update_state_changed"
        case .sensorAvailabilityChanged: return "sensor_availability_changed"
        case .licenseCheckPerformed: return "license_check_performed"
        case .backgroundTaskStarted: return "background_task_started"
        case .backgroundTaskCompleted: return "background_task_completed"
        }
    }
    
    var relativeTimestamp: TimeInterval {
        // В реальной реализации хранится время создания
        return 0
    }
    
    var safeMetadata: [String: String]? {
        switch self {
        case .settingsOpened(let section):
            return ["section": section]
        case .helperConnectionChanged(let state):
            return ["state": state]
        case .updateStateChanged(let state):
            return ["state": state]
        case .sensorAvailabilityChanged(let state):
            return ["state": state]
        case .licenseCheckPerformed(let result):
            return ["result": result]
        case .backgroundTaskStarted(let name):
            return ["name": name]
        case .backgroundTaskCompleted(let name):
            return ["name": name]
        default:
            return nil
        }
    }
}
