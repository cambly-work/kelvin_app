import Foundation

// MARK: - Unit tests for SensorResolver
// These tests verify the resolver logic using fixture data.
// Run on macOS with: swiftc SensorResolver.swift test/units/resolver_tests.swift -o resolver_tests

enum TestResult {
    case passed
    case failed(String)
}

func runTest(_ name: String, _ test: () throws -> Void) -> TestResult {
    do {
        try test()
        print("  ✓ \(name)")
        return .passed
    } catch let error {
        print("  ✗ \(name): \(error)")
        return .failed("\(error)")
    }
}

func assertEquals<T: Equatable>(_ actual: T, _ expected: T, message: String = "") throws {
    if actual != expected {
        throw TestError.assertionFailed("Expected \(expected), got \(actual). \(message)")
    }
}

enum TestError: Error {
    case assertionFailed(String)
    case unexpectedNil(String)
}

// MARK: - Mock SMC Inventory for testing

struct MockCatalogKey: Equatable {
    let fourCC: String
    let cls: SensorClassMock
    let smcType: String
    let curatedName: String?
    let decodable: Bool
}

enum SensorClassMock: String {
    case temp, volt, curr, power, fan, batt, other
}

extension CatalogKey {
    /// Create a mock CatalogKey for testing.
    static func mock(_ fourCC: String, type: String = "sp78", decodable: Bool = true) -> CatalogKey {
        return CatalogKey(
            fourCC: fourCC,
            cls: .of(fourCC),
            smcType: type,
            curatedName: nil,
            decodable: decodable
        )
    }
}

// MARK: - Tests

func runAllTests() {
    print("→ SensorResolver Unit Tests\n")
    
    var failures = 0
    
    // Test 1: Known Intel model selects correct CPU/GPU keys
    if case .failed = runTest("Intel model resolves CPU/GPU keys") {
        failures += 1
    }
    
    // Test 2: MacBook Air M1 fixture returns passive cooling
    if case .failed = runTest("MBA M1 returns passive cooling") {
        failures += 1
    }
    
    // Test 3: Unknown model does not assign fake CPU/GPU roles
    if case .failed = runTest("Unknown model has no confirmed CPU/GPU") {
        failures += 1
    }
    
    // Test 4: Invalid temperature values are filtered out
    if case .failed = runTest("Invalid temps (NaN/out-of-range) are filtered") {
        failures += 1
    }
    
    // Test 5: Unavailable SMC returns empty resolved set
    if case .failed = runTest("Unavailable SMC returns empty set") {
        failures += 1
    }
    
    // Test 6: FNum missing → unknown cooling
    if case .failed = runTest("Missing FNum → unknown cooling") {
        failures += 1
    }
    
    // Test 7: FNum == 0 on known fanless → passive
    if case .failed = runTest("FNum==0 on fanless model → passive") {
        failures += 1
    }
    
    // Test 8: Wildcard pattern matches family
    if case .failed = runTest("Wildcard pattern matches family") {
        failures += 1
    }
    
    print("")
    if failures > 0 {
        print("✗ \(failures) test(s) failed")
        exit(1)
    } else {
        print("✓ All tests passed")
    }
}

// MARK: - Individual Tests

func testIntelModelResolvesCPUKeys() {
    let catalog: [CatalogKey] = [
        .mock("TCXC"), .mock("TC0E"), .mock("TC0P"),
        .mock("TG0D"), .mock("TB0T"), .mock("FNum"), .mock("F0Ac")
    ]
    
    let result = SensorResolver.resolve(
        model: "MacBookPro15,1",
        architecture: "x86_64",
        catalog: catalog,
        readValue: { key in
            switch key {
            case "TCXC": return 65.0
            case "TC0E": return 63.0
            case "TC0P": return 55.0
            case "TG0D": return 58.0
            case "TB0T": return 35.0
            case "FNum": return 2.0
            default: return nil
            }
        }
    )
    
    try assertEquals(result.cpuTemperature?.keys.contains("TCXC"), true)
    try assertEquals(result.gpuTemperature?.keys.contains("TG0D"), true)
    try assertEquals(result.hasActiveCooling, true)
}

func testMBAM1PassiveCooling() {
    let catalog: [CatalogKey] = [
        .mock("TC0P"), .mock("TB0T")
        // No FNum, no fans on MBA M1
    ]
    
    let result = SensorResolver.resolve(
        model: "MacBookAir10,1",
        architecture: "arm64",
        catalog: catalog,
        readValue: { key in
            switch key {
            case "TC0P": return 45.0
            case "TB0T": return 32.0
            default: return nil
            }
        }
    )
    
    try assertEquals(result.isPassive, true, message: "MBA M1 should be passive")
    try assertEquals(result.fanIndices.count, 0, message: "No fans on MBA M1")
    // CPU/GPU may share TC0P on M1
    try assertEquals(result.cpuTemperature?.keys.contains("TC0P"), true)
}

func testUnknownModelNoFakeRoles() {
    let catalog: [CatalogKey] = [
        .mock("TXYZ"), .mock("TZ01")  // Unknown temp keys
    ]
    
    let result = SensorResolver.resolve(
        model: "MacBookPro99,1",  // Unknown model
        architecture: "arm64",
        catalog: catalog,
        readValue: { key in
            switch key {
            case "TXYZ": return 50.0
            case "TZ01": return 45.0
            default: return nil
            }
        }
    )
    
    // Unknown model should NOT assign CPU/GPU roles to random T*** keys
    // Legacy fallback only uses known keys (TCXC, TC0E, TG0D, etc.)
    try assertEquals(result.cpuTemperature, nil, message: "Should not assign CPU role to unknown keys")
    try assertEquals(result.gpuTemperature, nil, message: "Should not assign GPU role to unknown keys")
}

func testInvalidTempsFiltered() {
    let catalog: [CatalogKey] = [
        .mock("TCXC"), .mock("TC0E"), .mock("TC0P")
    ]
    
    let result = SensorResolver.resolve(
        model: "MacBookPro15,1",
        architecture: "x86_64",
        catalog: catalog,
        readValue: { key in
            switch key {
            case "TCXC": return Double.nan  // Invalid
            case "TC0E": return 150.0       // Out of range
            case "TC0P": return 55.0        // Valid
            default: return nil
            }
        }
    )
    
    // TCXC and TC0E should be filtered out, TC0P remains
    let cpuKeys = result.cpuTemperature?.keys ?? []
    try assertEquals(cpuKeys.contains("TCXC"), false, message: "NaN should be filtered")
    try assertEquals(cpuKeys.contains("TC0E"), false, message: "Out-of-range should be filtered")
    try assertEquals(cpuKeys.contains("TC0P"), true, message: "Valid temp should remain")
}

func testUnavailableSMC() {
    let catalog: [CatalogKey] = []  // Empty catalog
    
    let result = SensorResolver.resolve(
        model: "MacBookPro15,1",
        architecture: "x86_64",
        catalog: catalog,
        readValue: { _ in nil }
    )
    
    try assertEquals(result.sensors.isEmpty, true, message: "Empty catalog → no sensors")
    try assertEquals(result.cooling, .unknown, message: "No FNum → unknown cooling")
}

func testMissingFNumUnknownCooling() {
    let catalog: [CatalogKey] = [
        .mock("TC0P"), .mock("TB0T")
        // No FNum
    ]
    
    let result = SensorResolver.resolve(
        model: "MacBookPro99,1",  // Unknown model
        architecture: "x86_64",
        catalog: catalog,
        readValue: { key in
            switch key {
            case "TC0P": return 50.0
            case "TB0T": return 30.0
            default: return nil
            }
        }
    )
    
    // Unknown model without FNum → unknown cooling (not passive!)
    try assertEquals(result.cooling, .unknown, message: "Missing FNum on unknown model → unknown")
}

func testFNumZeroOnFanlessPassive() {
    let catalog: [CatalogKey] = [
        .mock("FNum"), .mock("TC0P")
    ]
    
    let result = SensorResolver.resolve(
        model: "MacBookAir10,1",  // Known fanless
        architecture: "arm64",
        catalog: catalog,
        readValue: { key in
            switch key {
            case "FNum": return 0.0
            case "TC0P": return 40.0
            default: return nil
            }
        }
    )
    
    try assertEquals(result.isPassive, true, message: "FNum==0 on known fanless → passive")
}

func testWildcardPatternMatch() {
    let catalog: [CatalogKey] = [
        .mock("TCXC"), .mock("TC0P"), .mock("TG0D")
    ]
    
    let result = SensorResolver.resolve(
        model: "MacBookPro16,1",  // Matches "MacBookPro15,*" or "MacBookPro16,*"
        architecture: "x86_64",
        catalog: catalog,
        readValue: { key in
            switch key {
            case "TCXC": return 60.0
            case "TC0P": return 50.0
            case "TG0D": return 55.0
            default: return nil
            }
        }
    )
    
    // Should match wildcard pattern and get legacy mapping
    try assertEquals(result.cpuTemperature?.confidence == .familyVerified, true,
                     message: "Wildcard match → familyVerified")
}

// MARK: - Entry Point

runAllTests()
