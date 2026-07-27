import Foundation

// MARK: - Power Metrics Service

/// Сервис для чтения метрик питания через /usr/bin/powermetrics
struct PowerMetricsService {
    
    /// Путь к утилите powermetrics
    private static let powermetricsPath = "/usr/bin/powermetrics"
    
    /// Максимальная длительность сбора метрик (секунды)
    private static let maxDuration: TimeInterval = 60.0
    
    /// Таймаут выполнения команды (секунды)
    private static let commandTimeout: TimeInterval = 120.0
    
    /// Результат измерения
    struct MetricsResult {
        let cpuEnergy: Double // mJ
        let gpuEnergy: Double // mJ
        let systemIdleEnergy: Double // mJ
        let timestamp: Date
        let sampleDuration: TimeInterval
    }
    
    /// Получить snapshot метрик питания
    /// - Parameters:
    ///   - duration: Длительность сбора (0.1-60 секунд)
    ///   - sampleInterval: Интервал семплирования (0.01-1 секунда)
    /// - Returns: Структурированные метрики
    func readMetrics(duration: TimeInterval = 1.0, sampleInterval: TimeInterval = 0.1) async throws -> MetricsResult {
        // Валидация параметров
        let validatedDuration = min(max(duration, 0.1), Self.maxDuration)
        let validatedInterval = min(max(sampleInterval, 0.01), 1.0)
        
        os_log("Reading power metrics: duration=%{public}f, interval=%{public}f", 
               log: .kelvinService, type: .info, validatedDuration, validatedInterval)
        
        // Формирование аргументов (только allowlist)
        let arguments = [
            "--samplers", "cpu_power,gpu_power",
            "--show-unit",
            "--interval", String(Int(validatedInterval * 1000)), // ms
            "-n", "1" // один снимок
        ]
        
        return try await executePowermetrics(arguments: arguments, duration: validatedDuration)
    }
    
    /// Запуск powermetrics с контролируемыми параметрами
    private func executePowermetrics(arguments: [String], duration: TimeInterval) async throws -> MetricsResult {
        let process = Process()
        process.executableURL = URL(filePath: Self.powermetricsPath)
        process.arguments = arguments
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Ограничение по времени выполнения
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.commandTimeout * 1_000_000_000))
            if process.isRunning {
                process.interrupt()
            }
        }
        
        try process.run()
        
        // Чтение вывода
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        
        process.waitUntilExit()
        timeoutTask.cancel()
        
        guard process.terminationStatus == 0 else {
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            os_log("powermetrics failed: %{public}@", log: .kelvinService, type: .error, errorMessage)
            throw PowerMetricsError.executionFailed(errorMessage)
        }
        
        // Парсинг вывода
        return try parseOutput(String(data: outputData, encoding: .utf8) ?? "", duration: duration)
    }
    
    /// Парсинг вывода powermetrics
    private func parseOutput(_ output: String, duration: TimeInterval) throws -> MetricsResult {
        var cpuEnergy: Double = 0.0
        var gpuEnergy: Double = 0.0
        var systemIdleEnergy: Double = 0.0
        
        let lines = output.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            
            // Поиск строк с энергией CPU
            if trimmedLine.contains("CPU Energy") || trimmedLine.contains("cpu_energy") {
                if let value = extractValue(from: trimmedLine) {
                    cpuEnergy = value
                }
            }
            
            // Поиск строк с энергией GPU
            if trimmedLine.contains("GPU Energy") || trimmedLine.contains("gpu_energy") {
                if let value = extractValue(from: trimmedLine) {
                    gpuEnergy = value
                }
            }
            
            // Поиск строк с системной энергией
            if trimmedLine.contains("System Idle Energy") || trimmedLine.contains("idle_energy") {
                if let value = extractValue(from: trimmedLine) {
                    systemIdleEnergy = value
                }
            }
        }
        
        os_log("Parsed metrics: CPU=%{public}f mJ, GPU=%{public}f mJ, Idle=%{public}f mJ", 
               log: .kelvinService, type: .info, cpuEnergy, gpuEnergy, systemIdleEnergy)
        
        return MetricsResult(
            cpuEnergy: cpuEnergy,
            gpuEnergy: gpuEnergy,
            systemIdleEnergy: systemIdleEnergy,
            timestamp: Date(),
            sampleDuration: duration
        )
    }
    
    /// Извлечение числового значения из строки
    private func extractValue(from line: String) -> Double? {
        // Паттерн: "value: 123.45 mJ" или "value 123.45"
        let pattern = #":\s*([\d.]+)"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else {
            return nil
        }
        
        return Double(String(line[range]))
    }
}

// MARK: - Errors

enum PowerMetricsError: LocalizedError {
    case executionFailed(String)
    case parsingFailed
    case timeout
    case unsupportedSampler
    
    var errorDescription: String? {
        switch self {
        case .executionFailed(let message):
            return "Failed to execute powermetrics: \(message)"
        case .parsingFailed:
            return "Failed to parse powermetrics output"
        case .timeout:
            return "Powermetrics command timed out"
        case .unsupportedSampler:
            return "Requested sampler is not supported on this Mac"
        }
    }
}

// MARK: - Logging Extension

extension OSLog {
    fileprivate static let kelvinService = OSLog(subsystem: "com.trykelvin.kelvin", category: "PowerMetrics")
}
