import Foundation

// Минимальные реальные контракты каталога для изолированного теста SensorResolver.
// Полный SensorCatalog зависит от SMC/UI-моделей, которые rule engine не использует.
enum SensorClass: String, Codable {
    case temp, volt, curr, power, fan, batt, other

    static func of(_ key: String) -> SensorClass {
        if key.hasPrefix("T") { return .temp }
        if key.hasPrefix("F") { return .fan }
        return .other
    }
}

struct CatalogKey: Codable, Equatable {
    let fourCC: String
    let cls: SensorClass
    let smcType: String
    let curatedName: String?
    let decodable: Bool
}
