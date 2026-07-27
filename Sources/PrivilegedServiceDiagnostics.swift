import Foundation
import os.log

/// Унифицированный интерфейс для диагностики и логирования состояния привилегированного сервиса.
final class PrivilegedServiceDiagnostics {
    
    private static let log = OSLog(subsystem: "com.trykelvin.kelvin", category: "Diagnostics")
    
    /// Структура с полным отчетом о состоянии
    struct DiagnosticReport: Codable {
        let timestamp: Date
        let serviceInstalled: Bool
        let serviceVersion: String?
        let protocolVersion: Int?
        let capabilities: [String]
        let healthStatus: String
        let legacyDaemonsPresent: [String]
        let migrationCompleted: Bool
        let lastErrorCode: Int?
        let lastErrorMessage: String?
    }
    
    /// Сбор полного диагностического отчета
    func collectReport() -> DiagnosticReport {
        let installer = PrivilegedServiceInstaller()
        let migrator = LegacyDaemonMigrator()
        
        // Проверка установленных legacy демонов
        var presentLegacy: [String] = []
        let legacyLabels = ["com.trykelvin.kelvin.powerd", "com.trykelvin.kelvin.fand"]
        for label in legacyLabels {
            let plistPath = "/Library/LaunchDaemons/\(label).plist"
            if FileManager.default.fileExists(atPath: plistPath) {
                presentLegacy.append(label)
            }
        }
        
        // Формируем отчет
        return DiagnosticReport(
            timestamp: Date(),
            serviceInstalled: installer.isInstalledAndReady,
            serviceVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            protocolVersion: CurrentProtocolVersion,
            capabilities: Capability.allCases.map { $0.rawValue },
            healthStatus: getServiceHealthString(installer.status),
            legacyDaemonsPresent: presentLegacy,
            migrationCompleted: !migrator.migrationRequired,
            lastErrorCode: nil, // Можно расширить, храня последнюю ошибку в UserDefaults
            lastErrorMessage: nil
        )
    }
    
    /// Вывод отчета в лог (для отладки или отправки в поддержку)
    func printReport() {
        let report = collectReport()
        
        os_log("=== Kelvin Privileged Service Diagnostic Report ===", log: Self.log, type: .info)
        os_log("Timestamp: %{public}@", log: Self.log, type: .info, ISO8601DateFormatter().string(from: report.timestamp))
        os_log("Service Installed: %{public}@", log: Self.log, type: .info, report.serviceInstalled ? "Yes" : "No")
        os_log("Service Version: %{public}@", log: Self.log, type: .info, report.serviceVersion ?? "Unknown")
        os_log("Protocol Version: %{public}d", log: Self.log, type: .info, report.protocolVersion ?? 0)
        os_log("Capabilities: %{public}@", log: Self.log, type: .info, report.capabilities.joined(separator: ", "))
        os_log("Health Status: %{public}@", log: Self.log, type: .info, report.healthStatus)
        os_log("Legacy Daemons Present: %{public}@", log: Self.log, type: .info, report.legacyDaemonsPresent.isEmpty ? "None" : report.legacyDaemonsPresent.joined(separator: ", "))
        os_log("Migration Completed: %{public}@", log: Self.log, type: .info, report.migrationCompleted ? "Yes" : "No")
        os_log("=== End of Report ===", log: Self.log, type: .info)
    }
    
    private func getServiceHealthString(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled:
            return "Healthy"
        case .notFound:
            return "Not Installed"
        case .requiresApproval:
            return "Requires Approval"
        case .invalid:
            return "Invalid Configuration"
        @unknown default:
            return "Unknown"
        }
    }
}

// Требуется для компиляции, если SMAppService еще не импортирован в этом файле
import ServiceManagement
