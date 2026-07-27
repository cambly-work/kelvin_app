import Foundation
import os
import ServiceManagement

/// Главный привилегированный сервис (root daemon).
/// Обрабатывает XPC запросы от приложения Kelvin.
class PrivilegedServiceDelegate: NSObject, NSXPCListenerDelegate {
    private let logger = Logger(subsystem: "com.trykelvin.kelvin.privileged", category: "MainService")
    
    // Сервисы-воркеры
    private var powerMetricsService = PowerMetricsService()
    private var gpuModeService = GPUModeService()
    private var fanChargeService = FanChargeService()
    private var firewallService = FirewallService()
    private var hostBlockService = HostBlockService()
    
    // Информация о сервисе
    private let serviceVersion = "1.0.0"
    private let supportedCapabilities: Set<Capability> = [
        .fanControl, .chargeLimit, .powerMetrics, 
        .firewall, .hostBlock, .gpuMode
    ]
    
    /// Обработка нового XPC подключения
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        logger.info("New XPC connection request")
        
        // 1. Валидация клиента (code signature, bundle ID, team ID)
        guard validateClient(connection: newConnection) else {
            logger.error("Client validation failed, rejecting connection")
            newConnection.invalidate()
            return false
        }
        
        // 2. Настройка интерфейса
        newConnection.exportedInterface = NSXPCInterface(with: PrivilegedServiceProtocol.self)
        newConnection.delegate = self
        
        // 3. Resume connection
        newConnection.resume()
        
        logger.info("XPC connection accepted")
        return true
    }
    
    /// Валидация клиента по code signature
    private func validateClient(connection: NSXPCConnection) -> Bool {
        guard let auditToken = connection.auditToken else {
            logger.error("No audit token available")
            return false
        }
        
        // Получаем информацию о процессе через audit token
        var stat = stat()
        // В реальной реализации здесь будет проверка code requirements через SecCodeCopyGuestWithAttributes
        
        // Эмуляция проверки (в production использовать SecCode API)
        logger.debug("Validating client audit token")
        
        // Проверка Bundle ID (эмуляция)
        // В реальности: extract from code signature
        let expectedBundleID = "com.trykelvin.kelvin"
        let expectedTeamID = "YOUR_TEAM_ID" // Заменить на реальный Team ID
        
        // NOTE: Здесь должна быть полноценная проверка:
        // 1. SecCodeCopyGuestWithAttributes с auditToken
        // 2. SecCodeCopySigningInformation
        // 3. Проверка kSecCodeInfoBundleIdentifier и kSecCodeInfoTeamIdentifier
        
        logger.info("Client validation passed (mock)")
        return true
    }
}

// MARK: - XPC Protocol Definition

@objc protocol PrivilegedServiceProtocol {
    func sendRequest(_ request: Data, reply: @escaping (Data) -> Void)
    func getStatus(reply: @escaping (Data) -> Void)
}

// MARK: - Implementation of Protocol

extension PrivilegedServiceDelegate: PrivilegedServiceProtocol {
    
    func sendRequest(_ request: Data, reply: @escaping (Data) -> Void) {
        logger.info("Received privileged request")
        
        do {
            // Декодируем запрос
            let decoder = JSONDecoder()
            let privilegedRequest = try decoder.decode(PrivilegedRequest.self, from: request)
            
            // Обрабатываем запрос
            let response: PrivilegedResponse = handleRequest(privilegedRequest)
            
            // Кодируем ответ
            let encoder = JSONEncoder()
            let responseData = try encoder.encode(response)
            
            reply(responseData)
            
        } catch {
            logger.error("Failed to decode request: \(error.localizedDescription)")
            let errorResponse = PrivilegedResponse.error(.invalidRequest, description: error.localizedDescription)
            let encoder = JSONEncoder()
            let responseData = try? encoder.encode(errorResponse)
            reply(responseData ?? Data())
        }
    }
    
    func getStatus(reply: @escaping (Data) -> Void) {
        logger.info("Received status request")
        
        let info = ServiceInfo(
            serviceVersion: serviceVersion,
            protocolVersion: CurrentProtocolVersion,
            supportedCapabilities: supportedCapabilities,
            health: .healthy
        )
        
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(info)
            let response = PrivilegedResponse.success(data: data)
            let responseData = try encoder.encode(response)
            reply(responseData)
        } catch {
            let errorResponse = PrivilegedResponse.error(.serviceUnavailable, description: error.localizedDescription)
            let encoder = JSONEncoder()
            let responseData = try? encoder.encode(errorResponse)
            reply(responseData ?? Data())
        }
    }
    
    /// Обработчик запросов
    private func handleRequest(_ request: PrivilegedRequest) -> PrivilegedResponse {
        switch request {
        case .ping:
            return .success(data: Data())
            
        case .getStatus:
            // Уже обработано в getStatus, но можно вернуть детальную инфу
            return .success(data: nil)
            
        case .setFanProfile(let profile):
            let lease = LeaseID(appName: "Kelvin", appBundleID: "com.trykelvin.kelvin")
            let result = fanChargeService.setFanProfile(profile, client: lease)
            return encodeResult(result)
            
        case .restoreFansAutomatic:
            let lease = LeaseID(appName: "Kelvin", appBundleID: "com.trykelvin.kelvin")
            let result = fanChargeService.restoreFansAutomatic(client: lease)
            return encodeResult(result)
            
        case .setChargeLimit(let percent):
            let lease = LeaseID(appName: "Kelvin", appBundleID: "com.trykelvin.kelvin")
            let result = fanChargeService.setChargeLimit(percent, client: lease)
            return encodeResult(result)
            
        case .readPowerMetrics(let options):
            let result = powerMetricsService.readPowerMetrics(options: options)
            return encodeResult(result)
            
        case .setGPUMode(let mode):
            let result = gpuModeService.setGPUMode(mode)
            return encodeResult(result)
            
        case .setFirewallEnabled(let enabled):
            let result = firewallService.setFirewallEnabled(enabled)
            return encodeResult(result)
            
        case .setFirewallRule(let rule):
            let result = firewallService.setFirewallRule(rule)
            return encodeResult(result)
            
        case .applyHostBlocklist(let domains):
            let result = hostBlockService.applyHostBlocklist(domains)
            return encodeResult(result)
        }
    }
    
    private func encodeResult<T: Codable>(_ result: T) -> PrivilegedResponse {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(result)
            return .success(data: data)
        } catch {
            return .error(.executionFailed, description: error.localizedDescription)
        }
    }
}
