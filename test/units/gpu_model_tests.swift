import Foundation

// MARK: - Unit tests for GPU model (GPUInfo, GPUMode, GPUSupportState)
// These tests verify pmset parsing, capability detection, and mode enum logic.
// All tests use injectable shell to avoid calling real pmset or Metal APIs.
//
// Run:
//   swiftc -O Sources/GPUInfo.swift Sources/ProcessRunner.swift \
//     Sources/PrivilegedProtocol.swift test/units/gpu_model_tests.swift \
//     -o /tmp/gpu_model_tests && /tmp/gpu_model_tests

// MARK: - Localization stub (avoids pulling in full Localization.swift + AppKit)

/// Minimal L() stub for standalone tests — returns the key as-is (Russian).
func L(_ key: String) -> String { key }

// ─── Test infrastructure ────────────────────────────────────────────────────

enum GPUTestResult {
    case passed
    case failed(String)
}

func gpuRunTest(_ name: String, _ test: () -> Void) -> GPUTestResult {
    test()
    print("  ✓ \(name)")
    return .passed
}

func gpuAssert<T: Equatable>(_ actual: T, _ expected: T, file: String = #file, line: Int = #line) {
    if actual != expected {
        fatalError("Expected \(expected), got \(actual) (line \(line))")
    }
}

func gpuAssertTrue(_ actual: Bool, file: String = #file, line: Int = #line) {
    if !actual {
        fatalError("Expected true, got false (line \(line))")
    }
}

func gpuAssertFalse(_ actual: Bool, file: String = #file, line: Int = #line) {
    if actual {
        fatalError("Expected false, got true (line \(line))")
    }
}

enum GPUTestError: Error {
    case assertionFailed(String)
}

// MARK: - GPUMode parsing

func testGPUModeRawValues() {
    gpuAssert(GPUMode.integratedOnly.rawValue, 0)
    gpuAssert(GPUMode.discreteOnly.rawValue, 1)
    gpuAssert(GPUMode.automatic.rawValue, 2)
}

func testGPUModeFromRaw() {
    gpuAssert(GPUMode(rawValue: 0), .integratedOnly)
    gpuAssert(GPUMode(rawValue: 1), .discreteOnly)
    gpuAssert(GPUMode(rawValue: 2), .automatic)
    gpuAssert(GPUMode(rawValue: 3), nil)   // Invalid
    gpuAssert(GPUMode(rawValue: -1), nil)   // Invalid
}

func testGPUModeCaseIterable() {
    gpuAssert(GPUMode.allCases.count, 3)
    gpuAssert(GPUMode.allCases, [.integratedOnly, .discreteOnly, .automatic])
}

// MARK: - pmset output parsing

/// Тест парсинга реального вывода pmset -g с gpuswitch.
func testPmsetParsingNormal() {
    // Симуляция типичного вывода pmset -g
    let pmsetOutput = """
    Currently in use:
     AC Power (connected): sleep 0 displaysleep 10 halfbright 1
     Battery Power: sleep 0 displaysleep 10 halfbright 1
     gpuswitch 2

    """
    GPUInfo.shell = { _, _ in pmsetOutput }
    let result = GPUInfo.currentModeRaw()
    gpuAssert(result, 2)
}

func testPmsetParsingMode0() {
    let pmsetOutput = "Active AC: sleep 0\n gpuswitch 0\n"
    GPUInfo.shell = { _, _ in pmsetOutput }
    gpuAssert(GPUInfo.currentModeRaw(), 0)
}

func testPmsetParsingMode1() {
    let pmsetOutput = "Battery: sleep 0\n  gpuswitch 1\n"
    GPUInfo.shell = { _, _ in pmsetOutput }
    gpuAssert(GPUInfo.currentModeRaw(), 1)
}

func testPmsetParsingNoGpuswitch() {
    let pmsetOutput = "Active AC: sleep 0 displaysleep 10\nBattery: sleep 0\n"
    GPUInfo.shell = { _, _ in pmsetOutput }
    gpuAssert(GPUInfo.currentModeRaw(), nil)
}

func testPmsetParsingEmpty() {
    GPUInfo.shell = { _, _ in "" }
    gpuAssert(GPUInfo.currentModeRaw(), nil)
}

func testPmsetParsingCorrupted() {
    let pmsetOutput = "gpuswitch abc\n"
    GPUInfo.shell = { _, _ in pmsetOutput }
    gpuAssert(GPUInfo.currentModeRaw(), nil)
}

func testPmsetParsingMultipleNumbers() {
    // "gpuswitch 2 3" — берём последний
    let pmsetOutput = "gpuswitch 2 3\n"
    GPUInfo.shell = { _, _ in pmsetOutput }
    gpuAssert(GPUInfo.currentModeRaw(), 3)
}

// MARK: - PrivilegedServiceInfo JSON

func testServiceInfoEncoding() {
    let info = PrivilegedServiceInfo(
        serviceVersion: "1.0.0",
        protocolVersion: 1,
        capabilities: [.gpuSwitching],
        health: .healthy
    )
    let json = info.xpcJSON()
    gpuAssert(json != nil, true)
}

func testServiceInfoRoundTrip() {
    let info = PrivilegedServiceInfo(
        serviceVersion: "1.0.0",
        protocolVersion: 1,
        capabilities: [.gpuSwitching],
        health: .healthy
    )
    guard let json = info.xpcJSON() else {
        fatalError("JSON encoding failed")
    }
    let decoded = PrivilegedServiceInfo.from(xpcJSON: json)
    gpuAssert(decoded, info)
}

func testServiceInfoDecodingCorrupted() {
    let decoded = PrivilegedServiceInfo.from(xpcJSON: "not json")
    gpuAssert(decoded, nil)
}

func testServiceInfoDecodingNil() {
    let decoded = PrivilegedServiceInfo.from(xpcJSON: nil)
    gpuAssert(decoded, nil)
}

// MARK: - GPUModeError

func testGPUModeErrorDescriptions() {
    // Just verify they don't crash — actual text depends on L() / locale
    for error: GPUModeError in [
        .unsupportedHardware,
        .invalidMode,
        .unauthorizedClient,
        .protocolMismatch,
        .serviceUnavailable,
        .commandTimedOut,
        .pmsetFailed(code: 1),
        .verificationFailed(expected: 2, actual: 1),
        .verificationFailed(expected: 2, actual: nil),
    ] {
        let _ = error.localizedDescription
    }
}

func testGPUModeErrorEquatable() {
    gpuAssert(GPUModeError.unsupportedHardware, GPUModeError.unsupportedHardware)
    gpuAssert(GPUModeError.pmsetFailed(code: 1), GPUModeError.pmsetFailed(code: 1))
    // Different codes should not be equal
    let e1 = GPUModeError.pmsetFailed(code: 1)
    let e2 = GPUModeError.pmsetFailed(code: 2)
    gpuAssert(e1 != e2, true)
}

// MARK: - PrivilegedServiceState

func testPrivilegedServiceStateEquatable() {
    let info = PrivilegedServiceInfo(
        serviceVersion: "1.0", protocolVersion: 1,
        capabilities: [.gpuSwitching], health: .healthy
    )
    gpuAssert(PrivilegedServiceState.notInstalled, PrivilegedServiceState.notInstalled)
    gpuAssert(PrivilegedServiceState.healthy(info), PrivilegedServiceState.healthy(info))
    gpuAssert(PrivilegedServiceState.notInstalled != PrivilegedServiceState.healthy(info), true)
}

/// Regression: SMAppService .enabled не должен считаться healthy без XPC-handshake.
/// .starting — отдельное состояние (зарегистрирован, но живость не подтверждена).
/// Selector доступен (canSwitch) только при .healthy, поэтому .starting ≠ .healthy.
func testStartingStateIsNotHealthy() {
    gpuAssert(PrivilegedServiceState.starting, PrivilegedServiceState.starting)
    let info = PrivilegedServiceInfo(
        serviceVersion: "1.0", protocolVersion: 1,
        capabilities: [.gpuSwitching], health: .healthy
    )
    gpuAssert(PrivilegedServiceState.starting != PrivilegedServiceState.healthy(info), true)
    gpuAssert(PrivilegedServiceState.starting != PrivilegedServiceState.notInstalled, true)
}

// MARK: - PrivilegedServiceConfig

func testServiceConfig() {
    gpuAssert(PrivilegedServiceConfig.serviceName, "com.trykelvin.kelvin.privileged")
    gpuAssert(PrivilegedServiceConfig.bundleID, "com.trykelvin.kelvin")
    gpuAssert(PrivilegedServiceConfig.machServiceName, PrivilegedServiceConfig.serviceName)
    gpuAssertTrue(PrivilegedServiceConfig.plistName.hasSuffix(".plist"))
    gpuAssertTrue(PrivilegedServiceConfig.connectionTimeout > 0)
    gpuAssertTrue(PrivilegedServiceConfig.commandTimeout > 0)
}

// MARK: - Run all tests

func runAllGPUTests() -> Int {
    var failures = 0
    let tests: [(String, () -> Void)] = [
        ("testGPUModeRawValues", testGPUModeRawValues),
        ("testGPUModeFromRaw", testGPUModeFromRaw),
        ("testGPUModeCaseIterable", testGPUModeCaseIterable),
        ("testPmsetParsingNormal", testPmsetParsingNormal),
        ("testPmsetParsingMode0", testPmsetParsingMode0),
        ("testPmsetParsingMode1", testPmsetParsingMode1),
        ("testPmsetParsingNoGpuswitch", testPmsetParsingNoGpuswitch),
        ("testPmsetParsingEmpty", testPmsetParsingEmpty),
        ("testPmsetParsingCorrupted", testPmsetParsingCorrupted),
        ("testPmsetParsingMultipleNumbers", testPmsetParsingMultipleNumbers),
        ("testServiceInfoEncoding", testServiceInfoEncoding),
        ("testServiceInfoRoundTrip", testServiceInfoRoundTrip),
        ("testServiceInfoDecodingCorrupted", testServiceInfoDecodingCorrupted),
        ("testServiceInfoDecodingNil", testServiceInfoDecodingNil),
        ("testGPUModeErrorDescriptions", testGPUModeErrorDescriptions),
        ("testGPUModeErrorEquatable", testGPUModeErrorEquatable),
        ("testPrivilegedServiceStateEquatable", testPrivilegedServiceStateEquatable),
        ("testStartingStateIsNotHealthy", testStartingStateIsNotHealthy),
        ("testServiceConfig", testServiceConfig),
    ]

    print("═══ GPU Model Tests ═══")
    for (name, test) in tests {
        switch gpuRunTest(name, test) {
        case .passed: break
        case .failed: failures += 1
        }
    }

    // Restore original shell after tests
    GPUInfo.shell = { path, args in ProcessRunner.output(path, args, timeout: 8) }

    let total = tests.count
    if failures == 0 {
        print("═══ \(total)/\(total) passed ═══")
    } else {
        print("═══ \(total - failures)/\(total) passed, \(failures) FAILED ═══")
    }
    return failures
}

// MARK: - Entry Point

exit(Int32(runAllGPUTests()))
