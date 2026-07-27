import Foundation
import ServiceManagement

// MARK: - Privileged Service Implementation

class PrivilegedServiceImplementation: NSObject, KelvinPrivilegedServiceProtocol {
    
    // MARK: - Constants
    
    private let expectedBundleID = "com.trykelvin.kelvin"
    private let expectedTeamID = "YOUR_TEAM_ID" // Заменить на реальный Team ID
    private let serviceVersion = "1.0.0"
    
    // MARK: - State
    
    private var currentLease: LeaseID?
    private let leaseQueue = DispatchQueue(label: "com.trykelvin.kelvin.lease")
    private let configQueue = DispatchQueue(label: "com.trykelvin.kelvin.config", attributes: .concurrent)
    
    // MARK: - XPC Protocol Methods
    
    func getServiceInfo(completion: @escaping (Data?) -> Void) {
        let info = ServiceInfo(
            serviceVersion: serviceVersion,
            protocolVersion: CurrentProtocolVersion,
            supportedCapabilities: Set(Capability.allCases),
            health: .healthy
        )
        
        do {
            let data = try JSONEncoder().encode(info)
            completion(data)
        } catch {
            os_log("Failed to encode service info: %{public}@", log: .kelvinService, type: .error, error.localizedDescription)
            completion(nil)
        }
    }
    
    func executeRequest(_ requestData: Data, completion: @escaping (Data?) -> Void) {
        // 1. Проверка клиента
        guard let connection = NSXPCConnection.current(),
              connection.validateClientCodeSignature(expectedBundleID: expectedBundleID, expectedTeamID: expectedTeamID) else {
            sendError(.unauthorizedClient, description: "Client validation failed", completion: completion)
            return
        }
        
        // 2. Парсинг запроса
        guard let request = parseRequest(requestData) else {
            sendError(.invalidRequest, description: "Failed to parse request", completion: completion)
            return
        }
        
        // 3. Выполнение запроса
        handleRequest(request, from: connection, completion: completion)
    }
    
    func ping(completion: @escaping () -> Void) {
        completion()
    }
    
    // MARK: - Request Handling
    
    private func parseRequest(_ data: Data) -> PrivilegedRequest? {
        do {
            return try JSONDecoder().decode(PrivilegedRequest.self, from: data)
        } catch {
            os_log("Failed to decode request: %{public}@", log: .kelvinService, type: .error, error.localizedDescription)
            return nil
        }
    }
    
    private func handleRequest(_ request: PrivilegedRequest, from connection: NSXPCConnection, completion: @escaping (Data?) -> Void) {
        switch request {
        case .getStatus:
            handleGetStatus(completion: completion)
            
        case .ping:
            completion(encodeResponse(.success(data: nil)))
            
        case .setFanProfile(let profile):
            handleSetFanProfile(profile, completion: completion)
            
        case .restoreFansAutomatic:
            handleRestoreFansAutomatic(completion: completion)
            
        case .setChargeLimit(let percent):
            handleSetChargeLimit(percent, completion: completion)
            
        case .readPowerMetrics(let options):
            handleReadPowerMetrics(options, completion: completion)
            
        case .setFirewallEnabled(let enabled):
            handleSetFirewallEnabled(enabled, completion: completion)
            
        case .setFirewallRule(let rule):
            handleSetFirewallRule(rule, completion: completion)
            
        case .applyHostBlocklist(let domains):
            handleApplyHostBlocklist(domains, completion: completion)
            
        case .setGPUMode(let mode):
            handleSetGPUMode(mode, completion: completion)
        }
    }
    
    // MARK: - Operation Handlers (Stubs - to be implemented)
    
    private func handleGetStatus(completion: @escaping (Data?) -> Void) {
        // Вернуть текущий статус сервиса
        let status: [String: Any] = [
            "running": true,
            "leaseActive": currentLease != nil,
            "capabilities": Capability.allCases.map { $0.rawValue }
        ]
        
        do {
            let data = try JSONSerialization.data(withJSONObject: status)
            completion(encodeResponse(.success(data: data)))
        } catch {
            sendError(.executionFailed, description: "Failed to get status", completion: completion)
        }
    }
    
    private func handleSetFanProfile(_ profile: ValidatedFanProfile, completion: @escaping (Data?) -> Void) {
        // TODO: Реализация установки профиля вентиляторов
        // - Валидация диапазонов
        // - Применение через SMC или fand
        // - Обновление lease
        
        os_log("Set fan profile: %{public}@", log: .kelvinService, type: .info, profile.name)
        completion(encodeResponse(.success(data: nil)))
    }
    
    private func handleRestoreFansAutomatic(completion: @escaping (Data?) -> Void) {
        // TODO: Восстановление автоматического управления вентиляторами
        os_log("Restore fans automatic", log: .kelvinService, type: .info)
        completion(encodeResponse(.success(data: nil)))
    }
    
    private func handleSetChargeLimit(_ percent: Int, completion: @escaping (Data?) -> Void) {
        // TODO: Установка лимита заряда батареи
        // Валидация: 50-100%
        guard percent >= 50 && percent <= 100 else {
            sendError(.validationFailed, description: "Charge limit must be between 50 and 100", completion: completion)
            return
        }
        
        os_log("Set charge limit: %d%%", log: .kelvinService, type: .info, percent)
        completion(encodeResponse(.success(data: nil)))
    }
    
    private func handleReadPowerMetrics(_ options: PowerMetricsOptions, completion: @escaping (Data?) -> Void) {
        // TODO: Чтение метрик питания через /usr/bin/powermetrics
        // - Запуск с фиксированными аргументами
        // - Парсинг вывода
        // - Timeout и bounded output
        
        os_log("Read power metrics: duration=%f, interval=%f", log: .kelvinService, type: .info, 
               options.duration, options.sampleInterval)
        
        // Stub response
        let metrics: [String: Any] = [
            "cpuEnergy": 0.0,
            "gpuEnergy": 0.0,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        do {
            let data = try JSONSerialization.data(withJSONObject: metrics)
            completion(encodeResponse(.success(data: data)))
        } catch {
            sendError(.executionFailed, description: "Failed to read power metrics", completion: completion)
        }
    }
    
    private func handleSetFirewallEnabled(_ enabled: Bool, completion: @escaping (Data?) -> Void) {
        // TODO: Включение/выключение firewall через /usr/libexec/ApplicationFirewall/socketfilterfw
        os_log("Set firewall enabled: %{public}@", log: .kelvinService, type: .info, enabled ? "true" : "false")
        completion(encodeResponse(.success(data: nil)))
    }
    
    private func handleSetFirewallRule(_ rule: ValidatedFirewallRule, completion: @escaping (Data?) -> Void) {
        // TODO: Добавление правила firewall
        // - Проверка существования app path
        // - Canonicalization пути
        // - Вызов socketfilterfw без shell
        
        os_log("Set firewall rule: path=%{public}@, allowed=%{public}@", log: .kelvinService, type: .info,
               rule.appPath, rule.allowed ? "true" : "false")
        completion(encodeResponse(.success(data: nil)))
    }
    
    private func handleApplyHostBlocklist(_ domains: [ValidatedDomain], completion: @escaping (Data?) -> Void) {
        // TODO: Применение блокировки хостов
        // - Валидация доменов
        // - Атомарное изменение /etc/hosts
        // - Backup и rollback
        
        os_log("Apply host blocklist: %d domains", log: .kelvinService, type: .info, domains.count)
        completion(encodeResponse(.success(data: nil)))
    }
    
    private func handleSetGPUMode(_ mode: GPUMode, completion: @escaping (Data?) -> Void) {
        // TODO: Переключение режима GPU через pmset gpuswitch
        // - Проверка поддержки (Intel dual-GPU)
        // - Вызов pmset с фиксированными аргументами
        // - Чтение фактического состояния после
        
        os_log("Set GPU mode: %d", log: .kelvinService, type: .info, mode.rawValue)
        completion(encodeResponse(.success(data: nil)))
    }
    
    // MARK: - Helper Methods
    
    private func encodeResponse(_ response: PrivilegedResponse) -> Data? {
        do {
            return try JSONEncoder().encode(response)
        } catch {
            os_log("Failed to encode response: %{public}@", log: .kelvinService, type: .error, error.localizedDescription)
            return nil
        }
    }
    
    private func sendError(_ error: PrivilegedServiceError, description: String?, completion: @escaping (Data?) -> Void) {
        os_log("Sending error: %{public}@ - %{public}@", log: .kelvinService, type: .error, 
               String(describing: error), description ?? "no description")
        completion(encodeResponse(.error(error, description: description)))
    }
    
    // MARK: - Lease Management
    
    func createLease(appName: String, appBundleID: String) -> LeaseID {
        let lease = LeaseID(appName: appName, appBundleID: appBundleID)
        leaseQueue.async { [weak self] in
            self?.currentLease = lease
        }
        return lease
    }
    
    func validateLease(_ leaseID: LeaseID) -> Bool {
        var isValid = false
        leaseQueue.sync { [weak self] in
            isValid = self?.currentLease == leaseID
        }
        return isValid
    }
    
    func releaseLease(_ leaseID: LeaseID) {
        leaseQueue.async { [weak self] in
            if self?.currentLease == leaseID {
                self?.currentLease = nil
                // TODO: Восстановить безопасное состояние (fans auto, charge limit reset)
            }
        }
    }
}

// MARK: - Extension for current XPC connection

extension NSXPCConnection {
    static func current() -> NSXPCConnection? {
        // Получаем текущее соединение из thread-local storage
        // Это упрощённая реализация, в production нужно использовать proper context
        return nil
    }
}
