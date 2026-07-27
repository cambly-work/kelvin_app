import Foundation
import XPC

// MARK: - XPC Interface Protocol

/// Протокол XPC интерфейса для общения между App и Privileged Service
@objc protocol KelvinPrivilegedServiceProtocol {
    /// Handshake: получение информации о сервисе
    func getServiceInfo(completion: @escaping (Data?) -> Void)
    
    /// Выполнение привилегированного запроса
    func executeRequest(_ requestData: Data, completion: @escaping (Data?) -> Void)
    
    /// Ping для проверки доступности
    func ping(completion: @escaping () -> Void)
}

// MARK: - XPC Listener Delegate

class KelvinPrivilegedServiceDelegate: NSObject, NSXPCListenerDelegate {
    private let serviceImplementation: PrivilegedServiceImplementation
    
    init(serviceImplementation: PrivilegedServiceImplementation) {
        self.serviceImplementation = serviceImplementation
        super.init()
    }
    
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Настройка интерфейса для входящего соединения
        newConnection.exportedInterface = NSXPCInterface(with: KelvinPrivilegedServiceProtocol.self)
        newConnection.exportedObject = serviceImplementation
        
        // Важно: принимаем соединение только после проверки клиента
        newConnection.resume()
        
        return true
    }
}

// MARK: - Client Validation Extension

extension NSXPCConnection {
    /// Проверка подписи клиента
    func validateClientCodeSignature(expectedBundleID: String, expectedTeamID: String) -> Bool {
        guard let auditToken = self.auditToken else { return false }
        
        do {
            let requirementString = "anchor apple generic and identifier \"\(expectedBundleID)\" and (certificate leaf[field.1.2.840.113635.100.6.1.9] /* exists */ or certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = \(expectedTeamID))"
            
            let requirement = try SecRequirementCreateWithString(
                requirementString as CFString,
                [],
                nil
            )
            
            var code: SecCode?
            let status = SecCodeCopyGuestWithAttributes(
                nil,
                [kSecGuestAttributeAuditToken: auditToken] as CFDictionary,
                [],
                &code
            )
            
            guard status == errSecSuccess, let validCode = code else {
                os_log("Failed to get code object from client: %{public}d", log: .kelvinService, type: .error, status)
                return false
            }
            
            let checkStatus = SecCodeCheckValidity(validCode, [], requirement)
            if checkStatus != errSecSuccess {
                os_log("Client code signature validation failed: %{public}d", log: .kelvinService, type: .error, checkStatus)
                return false
            }
            
            os_log("Client code signature validated successfully", log: .kelvinService, type: .info)
            return true
            
        } catch {
            os_log("Exception during code signature validation: %{public}@", log: .kelvinService, type: .error, error.localizedDescription)
            return false
        }
    }
}

// Helper for logging
extension OSLog {
    private static let subsystem = "com.trykelvin.kelvin"
    static let kelvinService = OSLog(subsystem: subsystem, category: "PrivilegedService")
}
