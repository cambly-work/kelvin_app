import Foundation

// MARK: - GPU Mode Service

/// Сервис для переключения режима GPU на Intel Mac с dual-GPU
struct GPUModeService {
    
    /// Путь к утилите pmset
    private static let pmsetPath = "/usr/bin/pmset"
    
    /// Режимы GPU
    enum Mode: Int, Codable {
        case integrated = 0   // Только интегрированная
        case discrete = 1     // Только дискретная
        case automatic = 2    // Автоматическое переключение
    }
    
    /// Информация о поддержке GPU switching
    struct GPUCompatibility {
        let supported: Bool
        let isIntel: Bool
        let gpuCount: Int
        let currentMode: Mode?
        let availableModes: [Mode]
    }
    
    /// Проверка поддержки переключения GPU
    func checkCompatibility() async -> GPUCompatibility {
        os_log("Checking GPU compatibility", log: .kelvinService, type: .info)
        
        // Проверка архитектуры
        let isIntel = isIntelMac()
        
        guard isIntel else {
            os_log("GPU switching not supported: Apple Silicon Mac", log: .kelvinService, type: .info)
            return GPUCompatibility(
                supported: false,
                isIntel: false,
                gpuCount: 0,
                currentMode: nil,
                availableModes: []
            )
        }
        
        // Подсчёт GPU
        let gpuCount = countGPUs()
        
        guard gpuCount >= 2 else {
            os_log("GPU switching not supported: single GPU (%d)", log: .kelvinService, type: .info, gpuCount)
            return GPUCompatibility(
                supported: false,
                isIntel: true,
                gpuCount: gpuCount,
                currentMode: nil,
                availableModes: []
            )
        }
        
        // Чтение текущего режима
        let currentMode = await readCurrentMode()
        
        // Доступные режимы
        let availableModes: [Mode] = [.integrated, .discrete, .automatic]
        
        os_log("GPU switching supported: Intel, %d GPUs, current mode: %{public}@", 
               log: .kelvinService, type: .info, gpuCount, String(describing: currentMode))
        
        return GPUCompatibility(
            supported: true,
            isIntel: true,
            gpuCount: gpuCount,
            currentMode: currentMode,
            availableModes: availableModes
        )
    }
    
    /// Установить режим GPU
    /// - Parameter mode: Желаемый режим
    /// - Throws: GPUModeError при ошибке
    func setMode(_ mode: Mode) async throws {
        os_log("Setting GPU mode: %{public}@", log: .kelvinService, type: .info, String(describing: mode))
        
        // Проверка поддержки перед выполнением
        let compatibility = await checkCompatibility()
        
        guard compatibility.supported else {
            throw GPUModeError.unsupported("GPU switching not supported on this Mac")
        }
        
        // Формирование аргументов (только фиксированные значения)
        let arguments = ["gpuswitch", String(mode.rawValue)]
        
        // Выполнение команды
        try await executePmset(arguments: arguments)
        
        // Верификация результата
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 секунды
        let actualMode = await readCurrentMode()
        
        if actualMode != mode {
            os_log("Warning: GPU mode mismatch. Requested: %{public}@, Actual: %{public}@", 
                   log: .kelvinService, type: .warning, String(describing: mode), String(describing: actualMode))
            // Не выбрасываем ошибку, так как переключение может требовать перезагрузки
        }
    }
    
    /// Прочитать текущий режим GPU
    func readCurrentMode() async -> Mode? {
        do {
            let process = Process()
            process.executableURL = URL(filePath: Self.pmsetPath)
            process.arguments = ["-g", "gpuswitch"]
            
            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = Pipe()
            
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else {
                return nil
            }
            
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            // Парсинг вывода: "gpuswitch: 0" или "gpuswitch 0"
            if let range = output.range(of: #"\d+"#, options: .regularExpression),
               let value = Int(output[range]) {
                return Mode(rawValue: value)
            }
            
            return nil
            
        } catch {
            os_log("Failed to read GPU mode: %{public}@", log: .kelvinService, type: .error, error.localizedDescription)
            return nil
        }
    }
    
    // MARK: - Private Helpers
    
    /// Проверка на Intel Mac
    private func isIntelMac() -> Bool {
        #if arch(x86_64)
        return true
        #else
        return false
        #endif
    }
    
    /// Подсчёт количества GPU в системе
    private func countGPUs() -> Int {
        // Используем IOKit для подсчёта GPU
        var iterator: io_iterator_t = 0
        var count = 0
        
        let result = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOPCIDevice"),
            &iterator
        )
        
        guard result == kIOReturnSuccess else {
            return 0
        }
        
        defer { IOObjectRelease(iterator) }
        
        var device: io_object_t
        while {
            device = IOIteratorNext(iterator)
            return device != 0
        }() {
            // Проверка класса устройства
            var className = [CChar](repeating: 0, count: 256)
            if IORegistryEntryGetName(device, &className) == kIOReturnSuccess {
                let name = String(cString: className)
                if name.contains("VGA") || name.contains("Display") || name.contains("3D") {
                    count += 1
                }
            }
            IOObjectRelease(device)
        }
        
        // Альтернативно: проверка через system_profiler
        if count == 0 {
            count = countGPUsViaSystemProfiler()
        }
        
        return count
    }
    
    /// Подсчёт GPU через system_profiler (fallback)
    private func countGPUsViaSystemProfiler() -> Int {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/system_profiler")
        process.arguments = ["SPDisplaysDataType"]
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            
            guard process.terminationStatus == 0 else {
                return 0
            }
            
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            
            // Подсчёт строк с "Graphics Device" или аналогичными маркерами
            let lines = output.components(separatedBy: .newlines)
            let deviceLines = lines.filter { $0.contains("Device ID") || $0.contains("Vendor") }
            
            return deviceLines.count
            
        } catch {
            return 0
        }
    }
    
    /// Выполнение pmset с контролируемыми аргументами
    private func executePmset(arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(filePath: Self.pmsetPath)
        process.arguments = arguments
        
        let errorPipe = Pipe()
        process.standardError = errorPipe
        
        try process.run()
        
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            os_log("pmset failed: %{public}@", log: .kelvinService, type: .error, errorMessage)
            throw GPUModeError.executionFailed(errorMessage)
        }
    }
}

// MARK: - Errors

enum GPUModeError: LocalizedError {
    case unsupported(String)
    case executionFailed(String)
    case verificationFailed
    case permissionDenied
    
    var errorDescription: String? {
        switch self {
        case .unsupported(let message):
            return message
        case .executionFailed(let message):
            return "Failed to set GPU mode: \(message)"
        case .verificationFailed:
            return "GPU mode verification failed"
        case .permissionDenied:
            return "Permission denied: administrator privileges required"
        }
    }
}

// MARK: - Logging Extension

extension OSLog {
    fileprivate static let kelvinService = OSLog(subsystem: "com.trykelvin.kelvin", category: "GPUMode")
}

// MARK: - IOKit Import

#if canImport(IOKit)
import IOKit
#endif
