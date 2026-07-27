import Foundation

/// Менеджер миграции со старых версий привилегированных демонов (powerd, fand).
/// Обеспечивает идемпотентный перенос настроек и безопасное удаление старых компонентов.
final class LegacyDaemonMigrator {
    
    private static let legacyLabels = [
        "com.trykelvin.kelvin.powerd",
        "com.trykelvin.kelvin.fand",
        "com.local.batterymeter.helper" // Пример возможного старого имени
    ]
    
    private static let migrationMarkerPath = "/Library/Application Support/Kelvin/migration_completed_v1"
    
    /// Проверка, требуется ли миграция
    var migrationRequired: Bool {
        // Если маркер существует, миграция уже проведена
        guard !FileManager.default.fileExists(atPath: Self.migrationMarkerPath) else {
            return false
        }
        
        // Проверяем наличие старых plist или процессов
        for label in Self.legacyLabels {
            let plistPath = "/Library/LaunchDaemons/\(label).plist"
            if FileManager.default.fileExists(atPath: plistPath) {
                return true
            }
        }
        
        return false
    }
    
    /// Выполнение миграции
    /// - Throws: Ошибки при остановке демонов, чтении конфига или записи маркера
    func migrate() throws {
        guard migrationRequired else {
            print("Migration not required or already completed.")
            return
        }
        
        print("Starting legacy daemon migration...")
        
        // 1. Остановить старые демоны
        for label in Self.legacyLabels {
            try stopDaemon(label: label)
        }
        
        // 2. (Опционально) Считать старые настройки, если они нужны
        // let oldConfig = try? readLegacyConfig()
        
        // 3. Удалить старые plist и бинарники
        for label in Self.legacyLabels {
            try removeLegacyFiles(label: label)
        }
        
        // 4. Записать маркер успешной миграции
        try writeMigrationMarker()
        
        print("Legacy daemon migration completed successfully.")
    }
    
    // MARK: - Private Helpers
    
    private func stopDaemon(label: String) throws {
        let plistPath = "/Library/LaunchDaemons/\(label).plist"
        guard FileManager.default.fileExists(atPath: plistPath) else {
            return // Уже удален или не существовал
        }
        
        // Выгружаем демон через launchctl
        let task = Process()
        task.launchPath = "/bin/launchctl"
        task.arguments = ["bootout", "system/\(label)"]
        
        // Игнорируем ошибку, если демон уже не запущен
        try? task.run()
        task.waitUntilExit()
        
        // Небольшая задержка для гарантии остановки
        Thread.sleep(forTimeInterval: 0.5)
    }
    
    private func removeLegacyFiles(label: String) throws {
        let fm = FileManager.default
        let plistPath = "/Library/LaunchDaemons/\(label).plist"
        
        if fm.fileExists(atPath: plistPath) {
            try fm.removeItem(atPath: plistPath)
            print("Removed legacy plist: \(plistPath)")
        }
        
        // Бинарник обычно лежит в /Library/PrivilegedHelperTools/
        let binaryPath = "/Library/PrivilegedHelperTools/\(label)"
        if fm.fileExists(atPath: binaryPath) {
            try fm.removeItem(atPath: binaryPath)
            print("Removed legacy binary: \(binaryPath)")
        }
    }
    
    private func writeMigrationMarker() throws {
        let fm = FileManager.default
        let dirPath = (migrationMarkerPath as NSString).deletingLastPathComponent
        
        if !fm.fileExists(atPath: dirPath) {
            try fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true, attributes: nil)
        }
        
        // Создаем пустой файл-маркер
        fm.createFile(atPath: Self.migrationMarkerPath, contents: Data("Migration completed at \(Date())".utf8), attributes: nil)
    }
}
