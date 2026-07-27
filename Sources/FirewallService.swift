import Foundation
import os

/// Сервис управления системным фаерволом (socketfilterfw).
/// Выполняет только типизированные операции с валидацией путей.
struct FirewallService {
    private let logger = Logger(subsystem: "com.trykelvin.kelvin.privileged", category: "Firewall")
    
    private let socketFilterPath = "/usr/libexec/ApplicationFirewall/socketfilterfw"
    
    /// Результат операции
    struct OperationResult: Codable {
        let success: Bool
        let message: String
        let details: String?
    }
    
    // MARK: - Public API
    
    /// Включение/выключение фаервола
    func setFirewallEnabled(_ enabled: Bool) -> OperationResult {
        logger.info("Request to set firewall enabled: \(enabled)")
        
        let args = enabled ? ["--setglobalstate", "on"] : ["--setglobalstate", "off"]
        
        return executeSocketFilter(args: args, description: enabled ? "enable" : "disable")
    }
    
    /// Добавление приложения в список разрешенных/запрещенных
    func setFirewallRule(_ rule: ValidatedFirewallRule) -> OperationResult {
        logger.info("Request to set firewall rule for: \(rule.appPath)")
        
        // Дополнительная валидация существования файла (так как мы root, можем проверить реально)
        guard FileManager.default.fileExists(atPath: rule.appPath) else {
            logger.error("App path does not exist: \(rule.appPath)")
            return OperationResult(success: false, message: "Application path does not exist", details: nil)
        }
        
        // Проверка, что это действительно .app бандл
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rule.appPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            logger.error("Path is not a directory (app bundle): \(rule.appPath)")
            return OperationResult(success: false, message: "Path is not a valid .app bundle", details: nil)
        }
        
        let canonicalPath = NSString(string: rule.appPath).standardizingPath
        
        let args = rule.allowed 
            ? ["--add", canonicalPath, "--allow"]
            : ["--add", canonicalPath, "--block"]
        
        return executeSocketFilter(args: args, description: rule.allowed ? "allow" : "block")
    }
    
    /// Удаление правила для приложения
    func removeFirewallRule(appPath: String) -> OperationResult {
        logger.info("Request to remove firewall rule for: \(appPath)")
        
        let canonicalPath = NSString(string: appPath).standardizingPath
        let args = ["--remove", canonicalPath]
        
        return executeSocketFilter(args: args, description: "remove rule")
    }
    
    /// Получение текущего состояния фаервола
    func getFirewallState() -> OperationResult {
        logger.info("Request to get firewall state")
        
        let args = ["--getglobalstate"]
        let result = executeSocketFilter(args: args, description: "get state", captureOutput: true)
        
        // Парсинг вывода (ожидается "Firewall is on" или "Firewall is off")
        if let output = result.details {
            if output.contains("on") {
                return OperationResult(success: true, message: "Firewall is enabled", details: "on")
            } else if output.contains("off") {
                return OperationResult(success: true, message: "Firewall is disabled", details: "off")
            }
        }
        
        return result
    }
    
    // MARK: - Private Helpers
    
    private func executeSocketFilter(args: [String], description: String, captureOutput: Bool = false) -> OperationResult {
        // Защита: проверяем, что путь к бинарнику неизменен
        guard socketFilterPath == "/usr/libexec/ApplicationFirewall/socketfilterfw" else {
            logger.critical("SECURITY: socketfilterfw path tampered!")
            return OperationResult(success: false, message: "Internal security check failed", details: nil)
        }
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: socketFilterPath)
        task.arguments = args
        
        // Блокируем опасные переменные окружения
        task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        
        var outputData = Data()
        if captureOutput {
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            
            do {
                try task.run()
                if let data = pipe.fileHandleForReading.readDataToEndOfFile().count > 0 {
                    outputData = pipe.fileHandleForReading.readDataToEndOfFile()
                }
                task.waitUntilExit()
            } catch {
                logger.error("Failed to run socketfilterfw: \(error.localizedDescription)")
                return OperationResult(success: false, message: "Execution failed", details: error.localizedDescription)
            }
        } else {
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                logger.error("Failed to run socketfilterfw: \(error.localizedDescription)")
                return OperationResult(success: false, message: "Execution failed", details: error.localizedDescription)
            }
        }
        
        guard task.terminationStatus == 0 else {
            logger.error("socketfilterfw exited with code: \(task.terminationStatus)")
            return OperationResult(success: false, message: "Command failed with status \(task.terminationStatus)", details: nil)
        }
        
        let output = captureOutput ? String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        
        logger.info("Firewall operation '\(description)' completed successfully")
        return OperationResult(success: true, message: "Firewall \(description) completed", details: output)
    }
}
