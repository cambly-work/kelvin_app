import Foundation
import os

/// Сервис управления блокировкой хостов через /etc/hosts.
/// Атомарно изменяет только Kelvin-managed секцию файла с backup и rollback.
struct HostBlockService {
    private let logger = Logger(subsystem: "com.trykelvin.kelvin.privileged", category: "HostBlock")
    
    private let hostsFilePath = "/etc/hosts"
    private let backupPath = "/etc/hosts.kelvin.backup"
    private let markerStart = "# KELVIN_BLOCK_START"
    private let markerEnd = "# KELVIN_BLOCK_END"
    
    /// Результат операции
    struct OperationResult: Codable {
        let success: Bool
        let message: String
        let blockedCount: Int
    }
    
    // MARK: - Public API
    
    /// Применение списка блокировки доменов
    func applyHostBlocklist(_ domains: [ValidatedDomain]) -> OperationResult {
        logger.info("Request to apply host blocklist with \(domains.count) domains")
        
        // Лимиты безопасности
        guard domains.count <= 1000 else {
            logger.error("Too many domains requested: \(domains.count)")
            return OperationResult(success: false, message: "Domain list exceeds maximum allowed (1000)", blockedCount: 0)
        }
        
        // Создаем контент для Kelvin-секции
        var newSection = "\(markerStart)\n"
        for domain in domains {
            // Блокируем на 0.0.0.0 и 127.0.0.1
            newSection += "0.0.0.0 \(domain.domain)\n"
            newSection += "127.0.0.1 \(domain.domain)\n"
        }
        newSection += "\(markerEnd)\n"
        
        do {
            // Читаем текущий hosts
            let currentContent = try String(contentsOfFile: hostsFilePath, encoding: .utf8)
            
            // Создаем backup
            try FileManager.default.copyItem(atPath: hostsFilePath, toPath: backupPath)
            logger.info("Created backup at \(backupPath)")
            
            // Удаляем старую Kelvin-секцию если есть
            let contentWithoutKelvin = removeKelvinSection(from: currentContent)
            
            // Добавляем новую секцию в конец
            let finalContent = contentWithoutKelvin + "\n" + newSection
            
            // Атомарная запись через временный файл
            let tempPath = hostsFilePath + ".kelvin.tmp"
            try finalContent.write(toFile: tempPath, atomically: true, encoding: .utf8)
            
            // Меняем владельца и права (root:wheel, 644)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tempPath)
            
            // Переименовываем временный файл в целевой
            try FileManager.default.moveItem(atPath: tempPath, toPath: hostsFilePath)
            
            logger.info("Successfully applied host blocklist with \(domains.count) domains")
            return OperationResult(success: true, message: "Blocked \(domains.count) domains", blockedCount: domains.count)
            
        } catch {
            logger.error("Failed to apply host blocklist: \(error.localizedDescription)")
            
            // Попытка восстановления из backup
            restoreFromBackup()
            
            return OperationResult(success: false, message: "Failed to modify hosts file", blockedCount: 0)
        }
    }
    
    /// Очистка Kelvin-блокировок (rollback)
    func clearHostBlocklist() -> OperationResult {
        logger.info("Request to clear Kelvin host blocklist")
        
        do {
            let currentContent = try String(contentsOfFile: hostsFilePath, encoding: .utf8)
            let contentWithoutKelvin = removeKelvinSection(from: currentContent)
            
            // Backup перед изменением
            try FileManager.default.copyItem(atPath: hostsFilePath, toPath: backupPath)
            
            // Атомарная запись
            let tempPath = hostsFilePath + ".kelvin.tmp"
            try contentWithoutKelvin.write(toFile: tempPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tempPath)
            try FileManager.default.moveItem(atPath: tempPath, toPath: hostsFilePath)
            
            logger.info("Cleared Kelvin host blocklist")
            return OperationResult(success: true, message: "Host blocklist cleared", blockedCount: 0)
            
        } catch {
            logger.error("Failed to clear host blocklist: \(error.localizedDescription)")
            restoreFromBackup()
            return OperationResult(success: false, message: "Failed to clear blocklist", blockedCount: 0)
        }
    }
    
    // MARK: - Private Helpers
    
    private func removeKelvinSection(from content: String) -> String {
        guard let startRange = content.range(of: markerStart),
              let endRange = content.range(of: markerEnd, range: startRange.upperBound..<content.endIndex) else {
            // Секция не найдена, возвращаем как есть
            return content
        }
        
        // Удаляем от начала markerStart до конца markerEnd (включая newline после него)
        let fullRange = startRange.lowerBound..<endRange.upperBound
        var result = content
        result.removeSubrange(fullRange)
        
        // Очищаем лишние пустые строки
        return result.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
    
    private func restoreFromBackup() {
        guard FileManager.default.fileExists(atPath: backupPath) else {
            logger.warning("No backup found for restoration")
            return
        }
        
        do {
            try FileManager.default.copyItem(atPath: backupPath, toPath: hostsFilePath)
            logger.info("Restored hosts file from backup")
        } catch {
            logger.critical("Failed to restore from backup: \(error.localizedDescription)")
        }
    }
}
