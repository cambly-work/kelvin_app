import Foundation

// MARK: - Версия протокола и возможности

/// Текущая версия протокола для handshake между app и сервисом
let CurrentProtocolVersion = 1

/// Возможности, поддерживаемые привилегированным сервисом
public enum Capability: String, CaseIterable, Codable {
    case fanControl
    case chargeLimit
    case powerMetrics
    case firewall
    case hostBlock
    case gpuMode
}

/// Состояние здоровья сервиса
public enum ServiceHealth: String, Codable {
    case healthy
    case degraded
    case unavailable
    case unknown
}

/// Информация о сервисе для handshake
public struct ServiceInfo: Codable {
    public let serviceVersion: String
    public let protocolVersion: Int
    public let supportedCapabilities: Set<Capability>
    public let health: ServiceHealth
    
    public init(serviceVersion: String, protocolVersion: Int, 
                supportedCapabilities: Set<Capability>, health: ServiceHealth) {
        self.serviceVersion = serviceVersion
        self.protocolVersion = protocolVersion
        self.supportedCapabilities = supportedCapabilities
        self.health = health
    }
}

// MARK: - Ошибки сервиса

/// Коды ошибок для машинного чтения
public enum PrivilegedServiceError: Int, Error, Codable {
    case invalidRequest = 1
    case unauthorizedClient = 2
    case unsupportedOperation = 3
    case validationFailed = 4
    case executionFailed = 5
    case serviceUnavailable = 6
    case leaseExpired = 7
    case unsafeCondition = 8
    case migrationRequired = 9
    case incompatibleVersion = 10
    
    public var localizedDescription: String {
        switch self {
        case .invalidRequest:
            return "Неверный формат запроса"
        case .unauthorizedClient:
            return "Клиентское приложение не авторизовано"
        case .unsupportedOperation:
            return "Операция не поддерживается этой версией сервиса"
        case .validationFailed:
            return "Проверка данных запроса не пройдена"
        case .executionFailed:
            return "Не удалось выполнить операцию"
        case .serviceUnavailable:
            return "Сервис временно недоступен"
        case .leaseExpired:
            return "Срок аренды истёк, возвращаем безопасное состояние"
        case .unsafeCondition:
            return "Операция создаст небезопасное условие системы"
        case .migrationRequired:
            return "Требуется миграция старых демонов"
        case .incompatibleVersion:
            return "Несовместимая версия протокола"
        }
    }
}

// MARK: - Валидированные типы данных

/// Профиль вентилятора с валидацией диапазонов
public struct ValidatedFanProfile: Codable {
    public let name: String
    public let minRPM: Int
    public let maxRPM: Int
    public let criticalTemp: Double // Celsius
    
    /// Инициализатор с валидацией. Возвращает nil если данные небезопасны.
    public init?(name: String, minRPM: Int, maxRPM: Int, criticalTemp: Double) {
        guard minRPM >= 0 && minRPM <= maxRPM else { return nil }
        guard maxRPM > 0 && maxRPM <= 10000 else { return nil } // Разумный максимум
        guard criticalTemp > 50 && criticalTemp < 120 else { return nil } // Безопасный диапазон температур
        
        self.name = name
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.criticalTemp = criticalTemp
    }
}

/// Правило брандмауэра с валидацией пути
public struct ValidatedFirewallRule: Codable {
    public let appPath: String
    public let allowed: Bool
    
    /// Инициализатор с валидацией пути
    public init?(appPath: String, allowed: Bool) {
        // Валидация: абсолютный путь, .app bundle, нет опасных символов
        guard appPath.hasPrefix("/"), appPath.hasSuffix(".app") else { return nil }
        
        // Защита от shell injection
        let dangerousChars = CharacterSet(charactersIn: ";|&`$()\"'\\")
        guard appPath.rangeOfCharacter(from: dangerousChars) == nil else { return nil }
        
        self.appPath = appPath
        self.allowed = allowed
    }
}

/// Домен с DNS-валидацией
public struct ValidatedDomain: Codable, Hashable {
    public let domain: String
    
    /// Инициализатор с валидацией DNS имени
    public init?(domain: String) {
        let trimmed = domain.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return nil }
        
        // Простая валидация DNS имени (RFC 1035)
        let pattern = "^[a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?)*$"
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else { return nil }
        
        self.domain = trimmed
    }
}

/// Режим переключения GPU
public enum GPUMode: Int, Codable {
    case integrated = 0
    case discrete = 1
    case automatic = 2
    
    public var title: String {
        switch self {
        case .integrated: return "Только встроенная"
        case .discrete: return "Только дискретная"
        case .automatic: return "Автоматически"
        }
    }
}

/// Опции для получения метрик питания
public struct PowerMetricsOptions: Codable {
    public let duration: TimeInterval
    public let sampleInterval: TimeInterval
    
    public init(duration: TimeInterval = 1.0, sampleInterval: TimeInterval = 0.1) {
        // Ограничиваем разумным диапазоном
        self.duration = min(max(duration, 0.1), 60.0)
        self.sampleInterval = min(max(sampleInterval, 0.01), 1.0)
    }
}

// MARK: - Запросы к сервису

/// Типизированный запрос к привилегированному сервису
public enum PrivilegedRequest: Codable {
    // Fan Control
    case setFanProfile(ValidatedFanProfile)
    case restoreFansAutomatic
    
    // Charge Limit
    case setChargeLimit(Int)
    
    // Power Metrics
    case readPowerMetrics(PowerMetricsOptions)
    
    // Firewall
    case setFirewallEnabled(Bool)
    case setFirewallRule(ValidatedFirewallRule)
    
    // Host Block
    case applyHostBlocklist([ValidatedDomain])
    
    // GPU Mode
    case setGPUMode(GPUMode)
    
    // Системные операции
    case getStatus
    case ping
    case startMigration
    case uninstall
    
    private enum CodingKeys: String, CodingKey {
        case type, value
    }
    
    private enum RequestType: String, Codable {
        case setFanProfile, restoreFansAutomatic, setChargeLimit,
             readPowerMetrics, setFirewallEnabled, setFirewallRule,
             applyHostBlocklist, setGPUMode, getStatus, ping,
             startMigration, uninstall
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setFanProfile(let profile):
            try container.encode(RequestType.setFanProfile, forKey: .type)
            try container.encode(profile, forKey: .value)
        case .restoreFansAutomatic:
            try container.encode(RequestType.restoreFansAutomatic, forKey: .type)
        case .setChargeLimit(let percent):
            try container.encode(RequestType.setChargeLimit, forKey: .type)
            try container.encode(percent, forKey: .value)
        case .readPowerMetrics(let options):
            try container.encode(RequestType.readPowerMetrics, forKey: .type)
            try container.encode(options, forKey: .value)
        case .setFirewallEnabled(let enabled):
            try container.encode(RequestType.setFirewallEnabled, forKey: .type)
            try container.encode(enabled, forKey: .value)
        case .setFirewallRule(let rule):
            try container.encode(RequestType.setFirewallRule, forKey: .type)
            try container.encode(rule, forKey: .value)
        case .applyHostBlocklist(let domains):
            try container.encode(RequestType.applyHostBlocklist, forKey: .type)
            try container.encode(domains, forKey: .value)
        case .setGPUMode(let mode):
            try container.encode(RequestType.setGPUMode, forKey: .type)
            try container.encode(mode, forKey: .value)
        case .getStatus:
            try container.encode(RequestType.getStatus, forKey: .type)
        case .ping:
            try container.encode(RequestType.ping, forKey: .type)
        case .startMigration:
            try container.encode(RequestType.startMigration, forKey: .type)
        case .uninstall:
            try container.encode(RequestType.uninstall, forKey: .type)
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(RequestType.self, forKey: .type)
        
        switch type {
        case .setFanProfile:
            let value = try container.decode(ValidatedFanProfile.self, forKey: .value)
            self = .setFanProfile(value)
        case .restoreFansAutomatic:
            self = .restoreFansAutomatic
        case .setChargeLimit:
            let value = try container.decode(Int.self, forKey: .value)
            self = .setChargeLimit(value)
        case .readPowerMetrics:
            let value = try container.decode(PowerMetricsOptions.self, forKey: .value)
            self = .readPowerMetrics(value)
        case .setFirewallEnabled:
            let value = try container.decode(Bool.self, forKey: .value)
            self = .setFirewallEnabled(value)
        case .setFirewallRule:
            let value = try container.decode(ValidatedFirewallRule.self, forKey: .value)
            self = .setFirewallRule(value)
        case .applyHostBlocklist:
            let value = try container.decode([ValidatedDomain].self, forKey: .value)
            self = .applyHostBlocklist(value)
        case .setGPUMode:
            let value = try container.decode(GPUMode.self, forKey: .value)
            self = .setGPUMode(value)
        case .getStatus:
            self = .getStatus
        case .ping:
            self = .ping
        case .startMigration:
            self = .startMigration
        case .uninstall:
            self = .uninstall
        }
    }
}

// MARK: - Ответы сервиса

/// Ответ от привилегированного сервиса
public enum PrivilegedResponse: Codable {
    case success(Data?)
    case error(PrivilegedServiceError, description: String?)
    
    private enum CodingKeys: String, CodingKey {
        case success, error, description, data
    }
    
    private enum ResponseType: String, Codable {
        case success, error
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success(let data):
            try container.encode(ResponseType.success, forKey: .success)
            if let data = data {
                try container.encode(data, forKey: .data)
            }
        case .error(let error, let desc):
            try container.encode(ResponseType.error, forKey: .success)
            try container.encode(error, forKey: .error)
            if let desc = desc {
                try container.encode(desc, forKey: .description)
            }
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let responseType = try container.decode(ResponseType.self, forKey: .success)
        
        switch responseType {
        case .success:
            let data = try container.decodeIfPresent(Data.self, forKey: .data)
            self = .success(data)
        case .error:
            let error = try container.decode(PrivilegedServiceError.self, forKey: .error)
            let description = try container.decodeIfPresent(String.self, forKey: .description)
            self = .error(error, description: description)
        }
    }
}

// MARK: - Lease и Watchdog

/// Идентификатор аренды для отслеживания владения состоянием
public struct LeaseID: Codable, Hashable {
    public let id: UUID
    public let timestamp: Date
    public let appName: String
    public let appBundleID: String
    
    public init(appName: String, appBundleID: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.appName = appName
        self.appBundleID = appBundleID
    }
}

/// Конфигурация для безопасного возврата в нормальное состояние
public struct SafeRecoveryConfig: Codable {
    public let defaultFanMode: String // "automatic"
    public let defaultChargeLimit: Int // e.g., 80%
    public let resetOnLeaseExpiry: Bool
    
    public init(defaultFanMode: String = "automatic", 
                defaultChargeLimit: Int = 80,
                resetOnLeaseExpiry: Bool = true) {
        self.defaultFanMode = defaultFanMode
        self.defaultChargeLimit = defaultChargeLimit
        self.resetOnLeaseExpiry = resetOnLeaseExpiry
    }
}
