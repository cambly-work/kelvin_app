import Foundation
import Security

// MARK: - Protocol Version

/// Версия протокола XPC между Kelvin и KelvinPrivilegedService.
/// При каждом несовместимом изменении номер увеличивается.
enum PrivilegedProtocolVersion {
    static let current = 1
}

// MARK: - Capabilities

/// Изолированные capabilities сервиса. Каждая — отдельный permission scope.
enum PrivilegedCapability: String, CaseIterable, Codable {
    case gpuSwitching = "gpu"
    // Future capabilities will be added here (fan, charge, etc.)
}

// MARK: - Service Health

enum ServiceHealth: String, Codable {
    case healthy
    case degraded
    case unknown
}

// MARK: - Service Info (handshake response)

/// Информация о подключённом privileged service (handshake).
struct PrivilegedServiceInfo: Equatable {
    let serviceVersion: String       // Build/version of the helper binary
    let protocolVersion: Int         // Must == PrivilegedProtocolVersion.current
    let capabilities: Set<PrivilegedCapability>
    let health: ServiceHealth
}

// MARK: - Service State (app-side view)

/// Состояние privileged service с точки зрения приложения.
enum PrivilegedServiceState: Equatable {
    case notInstalled
    case approvalRequired            // macOS 13+: SMAppService requiresApproval
    case installing
    case starting                    // SMAppService .enabled, но XPC-handshake ещё не подтверждён
    case healthy(PrivilegedServiceInfo)
    case updateRequired              // Service version != app expected version
    case incompatible                // Protocol version mismatch
    case repairNeeded                // Service binary missing/corrupted but plist exists
    case unavailable                 // Cannot connect (crash, not loaded)
}

// MARK: - GPU Errors

/// Машинно-читаемые ошибки GPU switching.
enum GPUModeError: Error, Equatable {
    case unsupportedHardware
    case invalidMode
    case unauthorizedClient
    case protocolMismatch
    case serviceUnavailable
    case commandTimedOut
    case pmsetFailed(code: Int)
    case verificationFailed(expected: Int, actual: Int?)

    var localizedDescription: String {
        switch self {
        case .unsupportedHardware: return L("Переключение графических режимов недоступно на этом Mac")
        case .invalidMode: return L("Некорректный режим переключения графики")
        case .unauthorizedClient: return L("Клиент не авторизован для выполнения этой операции")
        case .protocolMismatch: return L("Версия протокола несовместима с системным компонентом")
        case .serviceUnavailable: return L("Системный компонент недоступен")
        case .commandTimedOut: return L("Превышено время ожидания системной команды")
        case .pmsetFailed(let code): return String(format: L("Системная утилита pmset завершилась с кодом %d"), code)
        case .verificationFailed(let expected, let actual):
            if let a = actual {
                return String(format: L("Режим не подтверждён: ожидался %d, получен %d"), expected, a)
            }
            return String(format: L("Режим не подтверждён: ожидался %d, ответ не получен"), expected)
        }
    }
}

// MARK: - XPC Protocol Definition

/// Протокол XPC для KelvinPrivilegedService.
/// Все методы принимают reply-колбэки (async XPC pattern).
///
/// Note: @objc protocol reply closures cannot use Swift optional value types
/// (Int?), so we use -1 as a sentinel for "unavailable" in mode replies.
@objc protocol PrivilegedXPCProtocol {
    /// Получить информацию о сервисе (handshake).
    func getServiceInfo(reply: @escaping (String?, Error?) -> Void)
    // reply: JSON-encoded PrivilegedServiceInfo? or error

    /// Прочитать текущий режим GPU через pmset.
    func getGPUMode(reply: @escaping (Int, Error?) -> Void)
    // reply: raw mode 0/1/2, or -1 if not available

    /// Установить режим GPU.
    /// rawMode: только 0, 1, или 2.
    /// requestID: уникальный ID запроса для сериализации и dedup.
    func setGPUMode(_ rawMode: Int, requestID: String, reply: @escaping (Int, Error?) -> Void)
    // reply: подтверждённый mode после read-back, или -1 при ошибке
}

// MARK: - Service Configuration

/// Конфигурация privileged service.
enum PrivilegedServiceConfig {
    static let serviceName = "com.trykelvin.kelvin.privileged"
    static let bundleID = "com.trykelvin.kelvin"

    /// Mach service name (для XPC connection).
    static let machServiceName = serviceName

    /// Имя plist для SMAppService (macOS 13+).
    static let plistName = "\(serviceName).plist"

    /// Label для SMJobBless (macOS 11-12).
    static let blessHelperLabel = serviceName

    /// Timeout для XPC соединения (секунды).
    static let connectionTimeout: TimeInterval = 5.0

    /// Timeout для выполнения pmset команды (секунды).
    static let commandTimeout: TimeInterval = 10.0
}

// MARK: - PrivilegedServiceInfo Codable helpers

extension PrivilegedServiceInfo: Codable {
    private enum CodingKeys: String, CodingKey {
        case serviceVersion, protocolVersion, capabilities, health
    }

    /// Кодировать в JSON для передачи через XPC.
    func xpcJSON() -> String? {
        let encoder = JSONEncoder()
        return try? String(data: encoder.encode(self), encoding: .utf8)
    }

    /// Декодировать из JSON (ответ XPC).
    static func from(xpcJSON string: String?) -> PrivilegedServiceInfo? {
        guard let string else { return nil }
        return try? JSONDecoder().decode(PrivilegedServiceInfo.self, from: Data(string.utf8))
    }
}
