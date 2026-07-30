import Foundation

// MARK: - SensorResolver: единый слой разрешения физических датчиков
//
// Отделяет два понятия:
// 1. Ключ доступен в SMC и декодируется.
// 2. Физическое назначение ключа (CPU/GPU/Battery) подтверждено маппингом.
//
// Неизвестные, но читаемые ключи остаются в сыром каталоге и не получают
// автоматически имя CPU/GPU/Battery.

/// Физическая роль сенсора в системе.
enum PhysicalSensorRole: String, Codable, CaseIterable {
    case cpuTemperature
    case cpuPackageTemperature
    case gpuTemperature
    case memoryTemperature
    case platformTemperature
    case wifiTemperature
    case batteryTemperature
}

/// Уровень доверия к назначению роли.
enum SensorConfidence: String, Codable {
    /// Подтверждено точным hw.model.
    case modelVerified
    /// Подтверждено семейством моделей/SoC.
    case familyVerified
    /// Legacy-набор для известных Intel Mac.
    case legacyVerified
    /// Назначение не подтверждено — сырой ключ.
    case unknown
}

/// Разрешённый сенсор с подтверждённой физической ролью.
struct ResolvedSMCSensor: Equatable {
    let role: PhysicalSensorRole
    /// Список FourCC-ключей, предоставляющих эту роль (max-of используется для агрегации).
    let keys: [String]
    let confidence: SensorConfidence
    
    var id: String { role.rawValue }
}

/// Топология охлаждения системы.
enum CoolingTopology: Equatable {
    /// Пассивное охлаждение (fanless).
    case passive
    /// Активное охлаждение с указанием индексов вентиляторов.
    case active(fanIndices: [Int])
    /// Топология неизвестна (FNum отсутствует или не читается).
    case unknown
}

/// Полный набор разрешённых сенсоров для данной модели.
struct ResolvedSensorSet: Equatable {
    let modelIdentifier: String
    /// Роли → сенсоры. Роль отсутствует, если нет подтверждённого маппинга.
    let sensors: [PhysicalSensorRole: ResolvedSMCSensor]
    /// Топология охлаждения.
    let cooling: CoolingTopology
    
    /// Удобный доступ к CPU temperature.
    var cpuTemperature: ResolvedSMCSensor? { sensors[.cpuTemperature] }
    /// Удобный доступ к GPU temperature.
    var gpuTemperature: ResolvedSMCSensor? { sensors[.gpuTemperature] }
    /// Удобный доступ к Battery temperature.
    var batteryTemperature: ResolvedSMCSensor? { sensors[.batteryTemperature] }
    
    /// Список индексов вентиляторов для UI/control.
    var fanIndices: [Int] {
        switch cooling {
        case .passive: return []
        case .active(let indices): return indices
        case .unknown: return []
        }
    }
    
    /// Есть ли активное охлаждение.
    var hasActiveCooling: Bool {
        if case .active = cooling { return true }
        return false
    }
    
    /// Есть ли пассивное охлаждение.
    var isPassive: Bool {
        if case .passive = cooling { return true }
        return false
    }
}

/// SensorResolver: многоуровневый маппинг моделей → физические роли.
///
/// Порядок разрешения:
/// 1. Точный проверенный hw.model.
/// 2. Проверенное семейство моделей/SoC.
/// 3. Текущий проверенный legacy-набор Intel.
/// 4. Нет подтверждённого соответствия → роль отсутствует.
enum SensorResolver {
    
    /// Маппинг модели к набору сенсоров.
    struct SensorMapping {
        /// Паттерны hw.model (например, ["MacBookAir10,1", "MacBookAir9,1"]).
        let modelPatterns: [String]
        /// Архитектура (arm64/x86_64), nil = обе.
        let architecture: String?
        /// Роли → список ключей.
        let roles: [PhysicalSensorRole: [String]]
        /// Топология охлаждения, если известна заранее.
        let cooling: CoolingTopology?
        
        init(modelPatterns: [String], architecture: String? = nil,
             roles: [PhysicalSensorRole: [String]], cooling: CoolingTopology? = nil) {
            self.modelPatterns = modelPatterns
            self.architecture = architecture
            self.roles = roles
            self.cooling = cooling
        }
    }
    
    /// Каноническая таблица маппинга моделей.
    /// Заполняется постепенно по мере сбора фактических дампов.
    private static let modelMappings: [SensorMapping] = [
        // MacBook Air M1 (MacBookAir10,1) — пассивное охлаждение.
        // Только подтверждённые ключи из реального дампа.
        SensorMapping(
            modelPatterns: ["MacBookAir10,1"],
            architecture: "arm64",
            roles: [
                // CPU temperature: TCXC/TC0E — ядра, TC0P — корпус.
                // На M1 Air TCXC может отсутствовать — fallback на TC0P.
                .cpuTemperature: ["TC0P"],
                .cpuPackageTemperature: ["TC0P"],
                // GPU: на M1 SoC GPU интегрирован, отдельного TG0D может не быть.
                // Используем тот же TC0P как proxy.
                .gpuTemperature: ["TC0P"],
                // Battery: TB0T — основной датчик.
                .batteryTemperature: ["TB0T"],
            ],
            cooling: .passive
        ),
        
        // Intel MacBook Pro/Air — legacy mapping.
        // Основан на существующих hardcoded-списках SensorsModel/AlertsEngine.
        SensorMapping(
            modelPatterns: ["MacBookPro15,*", "MacBookPro16,*", "MacBookAir9,1"],
            architecture: "x86_64",
            roles: [
                .cpuTemperature: ["TCXC", "TC0E", "TC1C", "TC2C", "TC3C", "TC4C"],
                .cpuPackageTemperature: ["TC0P"],
                .gpuTemperature: ["TG0D", "TG0P"],
                .memoryTemperature: ["TM0P"],
                .platformTemperature: ["TPCD"],
                .wifiTemperature: ["TW0P"],
                .batteryTemperature: ["TB0T", "TB1T", "TB2T"],
            ],
            cooling: nil  // определяется динамически по FNum
        ),
    ]
    
    /// Fanless-модели для проверки cooling topology.
    private static let fanlessModels: Set<String> = [
        "MacBookAir10,1",  // M1 Air
    ]
    
    /// Разрешить сенсоры для данной модели.
    ///
    /// - Parameters:
    ///   - model: hw.model (например, "MacBookAir10,1").
    ///   - architecture: "arm64" или "x86_64".
    ///   - catalog: список доступных ключей SMC.
    ///   - values: функция чтения значений (возвращает nil если недоступно).
    /// - Returns: ResolvedSensorSet с подтверждёнными ролями.
    static func resolve(
        model: String,
        architecture: String,
        catalog: [CatalogKey],
        readValue: @escaping (String) -> Double?
    ) -> ResolvedSensorSet {
        let catalogKeys = Set(catalog.map { $0.fourCC })
        let catalogMap = Dictionary(uniqueKeysWithValues: catalog.map { ($0.fourCC, $0) })
        
        // Поиск подходящего маппинга.
        let mapping = findMapping(for: model, architecture: architecture)
        
        var resolvedSensors: [PhysicalSensorRole: ResolvedSMCSensor] = [:]
        
        if let m = mapping {
            // Применить маппинг модели.
            for (role, keys) in m.roles {
                // Фильтровать ключи: только те, что есть в каталоге и декодируются.
                let validKeys = keys.filter { key in
                    guard let ck = catalogMap[key] else { return false }
                    return ck.decodable && catalogKeys.contains(key)
                }
                
                if !validKeys.isEmpty {
                    // Проверка диапазона температур для temp-ролей.
                    let validatedKeys = validateTemperatureKeys(validKeys, readValue: readValue)
                    if !validatedKeys.isEmpty || !isTemperatureRole(role) {
                        resolvedSensors[role] = ResolvedSMCSensor(
                            role: role,
                            keys: validatedKeys.isEmpty ? validKeys : validatedKeys,
                            confidence: isWildcardPattern(m.modelPatterns) ? .familyVerified : .modelVerified
                        )
                    }
                }
            }
        } else {
            // Нет точного маппинга — использовать legacy Intel fallback.
            let legacyRoles: [PhysicalSensorRole: [String]] = [
                .cpuTemperature: ["TCXC", "TC0E", "TC1C", "TC2C", "TC3C", "TC4C"],
                .cpuPackageTemperature: ["TC0P"],
                .gpuTemperature: ["TG0D", "TG0P"],
                .batteryTemperature: ["TB0T"],
            ]
            
            for (role, keys) in legacyRoles {
                let validKeys = keys.filter { key in
                    guard let ck = catalogMap[key] else { return false }
                    return ck.decodable && catalogKeys.contains(key)
                }
                
                if !validKeys.isEmpty {
                    let validatedKeys = validateTemperatureKeys(validKeys, readValue: readValue)
                    if !validatedKeys.isEmpty || !isTemperatureRole(role) {
                        resolvedSensors[role] = ResolvedSMCSensor(
                            role: role,
                            keys: validatedKeys.isEmpty ? validKeys : validatedKeys,
                            confidence: .legacyVerified
                        )
                    }
                }
            }
        }
        
        // Определение топологии охлаждения.
        let cooling = determineCoolingTopology(
            model: model,
            catalog: catalogKeys,
            readValue: readValue
        )
        
        return ResolvedSensorSet(
            modelIdentifier: model,
            sensors: resolvedSensors,
            cooling: cooling
        )
    }
    
    /// Найти маппинг для модели.
    private static func findMapping(for model: String, architecture: String) -> SensorMapping? {
        for m in modelMappings {
            // Проверка архитектуры.
            if let arch = m.architecture, arch != architecture {
                continue
            }
            
            // Проверка паттернов модели.
            for pattern in m.modelPatterns {
                if matchPattern(pattern, model: model) {
                    return m
                }
            }
        }
        return nil
    }
    
    /// Соответствие паттерна модели. Поддерживает wildcard '*'.
    private static func matchPattern(_ pattern: String, model: String) -> Bool {
        if pattern.contains("*") {
            let prefix = pattern.replacingOccurrences(of: "*", with: "")
            return model.hasPrefix(prefix)
        }
        return pattern == model
    }
    
    /// Является ли паттерн wildcard (семейство моделей).
    private static func isWildcardPattern(_ patterns: [String]) -> Bool {
        return patterns.contains { $0.contains("*") }
    }
    
    /// Проверка температурных ключей на физический диапазон.
    /// Отбрасывает NaN, infinity, значения вне [-40, 130].
    private static func validateTemperatureKeys(_ keys: [String], readValue: (String) -> Double?) -> [String] {
        return keys.filter { key in
            guard let v = readValue(key) else { return false }
            return v.isFinite && v > -40 && v < 130
        }
    }
    
    /// Является ли роль температурной.
    private static func isTemperatureRole(_ role: PhysicalSensorRole) -> Bool {
        switch role {
        case .cpuTemperature, .cpuPackageTemperature, .gpuTemperature,
             .memoryTemperature, .platformTemperature, .wifiTemperature, .batteryTemperature:
            return true
        }
    }
    
    /// Определение топологии охлаждения.
    private static func determineCoolingTopology(
        model: String,
        catalog: Set<String>,
        readValue: (String) -> Double?
    ) -> CoolingTopology {
        // Проверка на известные fanless-модели.
        if fanlessModels.contains(model) {
            return .passive
        }
        
        // Чтение FNum (число вентиляторов).
        if let fnum = readValue("FNum"), fnum > 0 {
            // Активное охлаждение: собрать индексы доступных вентиляторов.
            var indices: [Int] = []
            for i in 0..<Int(fnum) {
                let acKey = "F\(i)Ac"
                if catalog.contains(acKey) {
                    indices.append(i)
                }
            }
            return indices.isEmpty ? .unknown : .active(fanIndices: indices)
        }
        
        // FNum == 0 на известной fanless-модели.
        if fanlessModels.contains(model) {
            return .passive
        }
        
        // FNum отсутствует — неизвестно.
        if !catalog.contains("FNum") {
            return .unknown
        }
        
        // FNum == 0, но модель не известна как fanless.
        if let fnum = readValue("FNum"), fnum == 0 {
            return .passive
        }
        
        return .unknown
    }
}

// MARK: - Fixture Data Structures для тестирования

/// Данные для fixture-теста resolver.
struct SMCFixture: Codable {
    let model: String
    let architecture: String
    let macOS: String
    let smcAvailable: Bool
    let keys: [FixtureKey]
}

/// Один ключ в fixture.
struct FixtureKey: Codable {
    let fourCC: String
    let type: String
    let size: Int
    let readable: Bool
    let value: Double?
}
