import Foundation
import os

/// Сервис управления вентиляторами и лимитом заряда.
/// Использует прямой доступ к SMC или взаимодействует с низкоуровневым демоном (если есть).
/// В этой реализации эмулируется логика безопасности и lease, так как реальный доступ к SMC
/// требует специфических драйверов/библиотек, которые будут подключены отдельно.
struct FanChargeService {
    private let logger = Logger(subsystem: "com.trykelvin.kelvin.privileged", category: "FanCharge")
    
    // Состояние аренды (lease)
    private var currentLease: LeaseID?
    private var leaseTimer: Timer?
    private let leaseDuration: TimeInterval = 30.0 // 30 секунд по умолчанию
    
    // Константы безопасности
    private let minSafeRPM = 0
    private let maxSafeRPM = 6000 // Зависит от модели, здесь безопасный максимум
    private let minSafeTemp = 0.0
    private let maxSafeTemp = 100.0
    private let minChargeLimit = 50
    private let maxChargeLimit = 100
    
    /// Результат операции
    struct OperationResult: Codable {
        let success: Bool
        let message: String
        let previousState: String?
    }
    
    // MARK: - Public API
    
    /// Запрос на установку профиля вентиляторов
    mutating func setFanProfile(_ profile: ValidatedFanProfile, client: LeaseID) -> OperationResult {
        logger.info("Request to set fan profile: \(profile.name)")
        
        // 1. Проверка Lease
        guard validateOrExtendLease(for: client) else {
            return OperationResult(success: false, message: "Invalid or expired lease", previousState: nil)
        }
        
        // 2. Дополнительная валидация диапазонов (защита от "глупых" значений)
        guard profile.minRPM >= minSafeRPM && profile.maxRPM <= maxSafeRPM else {
            logger.error("Unsafe RPM range requested: \(profile.minRPM)-\(profile.maxRPM)")
            return OperationResult(success: false, message: "Requested RPM range exceeds safety limits", previousState: nil)
        }
        
        guard profile.criticalTemp <= maxSafeTemp else {
            logger.error("Unsafe critical temperature: \(profile.criticalTemp)")
            return OperationResult(success: false, message: "Critical temperature limit unsafe", previousState: nil)
        }
        
        // 3. Эмуляция применения (Здесь будет вызов SMCWrite или отправка команды fand)
        // В реальной реализации: SMCallDriver或直接 запись в SMC регистры
        logger.info("Applying fan profile: min=\(profile.minRPM), max=\(profile.maxRPM), crit=\(profile.criticalTemp)")
        
        // Сохраняем состояние (в памяти или в root-owned config)
        // applyToHardware(profile)
        
        return OperationResult(success: true, message: "Fan profile '\(profile.name)' applied", previousState: "automatic")
    }
    
    /// Сброс вентиляторов в автоматический режим
    mutating func restoreFansAutomatic(client: LeaseID) -> OperationResult {
        logger.info("Request to restore automatic fan control")
        
        guard validateOrExtendLease(for: client) else {
            return OperationResult(success: false, message: "Invalid lease", previousState: nil)
        }
        
        // Сброс аренды при явном запросе авто-режима (опционально)
        clearLease()
        
        logger.info("Restoring automatic fan control")
        // restoreToAutomatic()
        
        return OperationResult(success: true, message: "Fans restored to automatic", previousState: "manual")
    }
    
    /// Установка лимита заряда
    mutating func setChargeLimit(_ percent: Int, client: LeaseID) -> OperationResult {
        logger.info("Request to set charge limit: \(percent)%")
        
        guard validateOrExtendLease(for: client) else {
            return OperationResult(success: false, message: "Invalid lease", previousState: nil)
        }
        
        // Валидация диапазона
        guard percent >= minChargeLimit && percent <= maxChargeLimit else {
            logger.error("Unsafe charge limit requested: \(percent)")
            return OperationResult(success: false, message: "Charge limit must be between \(minChargeLimit) and \(maxChargeLimit)", previousState: nil)
        }
        
        logger.info("Setting charge limit to \(percent)%")
        // applyChargeLimit(percent)
        
        return OperationResult(success: true, message: "Charge limit set to \(percent)%", previousState: "100%")
    }
    
    /// Проверка аварийного перегрева (приоритет над профилем)
    func checkEmergencyThermalState(currentTemp: Double) -> Bool {
        if currentTemp > 95.0 { // Жесткий порог
            logger.critical("EMERGENCY THERMAL THRESHOLD EXCEEDED: \(currentTemp)")
            // Принудительный сброс вентиляторов на максимум независимо от профиля
            // forceMaxFans()
            return true
        }
        return false
    }
    
    // MARK: - Lease Management
    
    private mutating func validateOrExtendLease(for client: LeaseID) -> Bool {
        if let existing = currentLease {
            if existing.id == client.id {
                // Продлеваем аренду
                leaseTimer?.invalidate()
                startLeaseTimer(for: client)
                return true
            } else {
                // Чужая аренда
                logger.warning("Lease conflict: existing=\(existing.appName), new=\(client.appName)")
                return false
            }
        } else {
            // Новая аренда
            currentLease = client
            startLeaseTimer(for: client)
            return true
        }
    }
    
    private mutating func startLeaseTimer(for client: LeaseID) {
        leaseTimer = Timer.scheduledTimer(withTimeInterval: leaseDuration, repeats: false) { [weak self] _ in
            self?.handleLeaseExpiry(for: client)
        }
    }
    
    private mutating func handleLeaseExpiry(for client: LeaseID) {
        guard let existing = currentLease, existing.id == client.id else { return }
        
        logger.warning("Lease expired for \(client.appName). Reverting to safe state.")
        clearLease()
        
        // Safe rollback logic would be triggered here in a real implementation
        // restoreFansAutomatic()
        // setChargeLimit(80)
    }
    
    private mutating func clearLease() {
        currentLease = nil
        leaseTimer?.invalidate()
        leaseTimer = nil
    }
}
