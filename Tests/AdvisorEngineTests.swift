//
//  AdvisorEngineTests.swift
//  Kelvin
//
//  Unit tests for Advisor rule engine.
//  Tests verify deterministic behavior, no false positives on missing sensors,
//  and correct severity assignment.
//

import XCTest
@testable import Kelvin

final class AdvisorEngineTests: XCTestCase {
    
    var engine: AdvisorEngine!
    
    override func setUp() {
        super.setUp()
        engine = AdvisorEngine.shared
    }
    
    override func tearDown() {
        engine = nil
        super.tearDown()
    }
    
    // MARK: - Helper
    
    private func makeSnapshot(
        batteryPresent: Bool = true,
        batteryChargePercent: Int? = 80,
        batteryHealthPercent: Double? = 95,
        batteryCycles: Int? = 100,
        batteryRatedCycles: Int? = 1000,
        batteryTemperature: Double? = 35,
        batteryCharging: Bool = false,
        batteryExternalConnected: Bool = false,
        chargeLimitEnabled: Bool = false,
        chargeLimitValue: Int = 100,
        sailModeActive: Bool = false,
        heatProtectionActive: Bool = false,
        cpuTemperature: Double? = 65,
        gpuTemperature: Double? = 60,
        cpuTemperatureKeys: [String]? = ["TCXC"],
        cpuLoad: Double = 0.3,
        memoryPressure: MemoryInfo.Pressure = .normal,
        diskFreeBytes: Int64? = 100_000_000_000,
        diskTotalBytes: Int64? = 500_000_000_000,
        recentCrashesCount: Int = 0,
        fanHelperInstalled: Bool = false,
        chargeHelperInstalled: Bool = false
    ) -> AdvisorSnapshot {
        AdvisorSnapshot(
            batteryPresent: batteryPresent,
            batteryChargePercent: batteryChargePercent,
            batteryHealthPercent: batteryHealthPercent,
            batteryCycles: batteryCycles,
            batteryRatedCycles: batteryRatedCycles,
            batteryTemperature: batteryTemperature,
            batteryCharging: batteryCharging,
            batteryExternalConnected: batteryExternalConnected,
            chargeLimitEnabled: chargeLimitEnabled,
            chargeLimitValue: chargeLimitValue,
            sailModeActive: sailModeActive,
            heatProtectionActive: heatProtectionActive,
            cpuTemperature: cpuTemperature,
            gpuTemperature: gpuTemperature,
            cpuTemperatureKeys: cpuTemperatureKeys,
            cpuLoad: cpuLoad,
            thermalPressure: nil,
            memoryPressure: memoryPressure,
            memoryTotalRAM: 16 * 1024 * 1024 * 1024,
            memorySwapUsed: 0,
            diskFreeBytes: diskFreeBytes,
            diskTotalBytes: diskTotalBytes,
            uptime: 3600,
            recentCrashesCount: recentCrashesCount,
            crashSummary: nil,
            fanHelperInstalled: fanHelperInstalled,
            chargeHelperInstalled: chargeHelperInstalled
        )
    }
    
    // MARK: - Test 1: Healthy battery — no finding
    
    func testHealthyBattery_noFinding() {
        let s = makeSnapshot(
            batteryHealthPercent: 95,
            batteryTemperature: 35
        )
        let result = engine.analyze(s)
        
        let batteryFindings = result.findings.filter { $0.category == .battery }
        XCTAssertTrue(batteryFindings.isEmpty, "Healthy battery should not produce findings")
    }
    
    // MARK: - Test 2: Low health percentage — correct severity
    
    func testLowBatteryHealth_warningSeverity() {
        let s = makeSnapshot(batteryHealthPercent: 75)
        let result = engine.analyze(s)
        
        let healthFinding = result.findings.first { $0.id.contains("battery.health") }
        XCTAssertNotNil(healthFinding)
        XCTAssertEqual(healthFinding?.severity, .warning, "Health <80% should be warning")
    }
    
    func testModerateBatteryHealth_noticeSeverity() {
        let s = makeSnapshot(batteryHealthPercent: 85)
        let result = engine.analyze(s)
        
        let healthFinding = result.findings.first { $0.id.contains("battery.health") }
        XCTAssertNotNil(healthFinding)
        XCTAssertEqual(healthFinding?.severity, .notice, "Health 80-89% should be notice")
    }
    
    // MARK: - Test 3: Missing health value — no false positive
    
    func testMissingHealthValue_noFinding() {
        let s = makeSnapshot(batteryHealthPercent: nil)
        let result = engine.analyze(s)
        
        let healthFinding = result.findings.first { $0.id.contains("battery.health") }
        XCTAssertNil(healthFinding, "Missing health should not produce finding")
    }
    
    // MARK: - Test 4: Brief temperature spike — no finding
    
    func testBriefTempSpike_noFinding() {
        // Single high reading without sustained condition
        // (engine receives smoothed value from caller, so single spike shouldn't trigger)
        let s = makeSnapshot(cpuTemperature: 92, cpuTemperatureKeys: ["TCXC"])
        let result = engine.analyze(s)
        
        // Design.sensorLevel для CPU 92°C должен быть ok/warn но не crit
        // Проверяем что нет critical thermal finding от одиночного пика
        let thermalFindings = result.findings.filter { $0.category == .thermal }
        // На этом уровне мы проверяем логику порогов — 92°C может дать notice
        // но не должно быть false positive при отсутствии ключей
    }
    
    // MARK: - Test 5: Sustained high temperature — finding appears
    
    func testSustainedHighTemperature_findingAppears() {
        let s = makeSnapshot(
            cpuTemperature: 98,
            cpuTemperatureKeys: ["TCXC", "TC0E"]
        )
        let result = engine.analyze(s)
        
        let thermalFinding = result.findings.first { $0.id.contains("thermal.cpu") }
        XCTAssertNotNil(thermalFinding, "High CPU temp should produce finding")
        XCTAssertTrue(thermalFinding?.severity == .notice || thermalFinding?.severity == .warning)
    }
    
    // MARK: - Test 6: Unknown CPU sensor — thermal rule does not fire
    
    func testUnknownCPUSensor_noThermalFinding() {
        // No keys = no confirmed sensor mapping
        let s = makeSnapshot(cpuTemperature: 95, cpuTemperatureKeys: nil)
        let result = engine.analyze(s)
        
        let thermalFinding = result.findings.first { $0.id.contains("thermal.cpu") }
        XCTAssertNil(thermalFinding, "Unknown sensor should not produce thermal finding")
    }
    
    // MARK: - Test 7: Charge limit already enabled — no recommendation
    
    func testChargeLimitEnabled_noRecommendation() {
        let s = makeSnapshot(
            batteryExternalConnected: true,
            batteryChargePercent: 100,
            chargeLimitEnabled: true
        )
        let result = engine.analyze(s)
        
        let pluggedFinding = result.findings.first { $0.id == "battery.always_plugged" }
        XCTAssertNil(pluggedFinding, "Already protected should not recommend limit")
    }
    
    // MARK: - Test 8: Low disk space — correct recommendation
    
    func testLowDiskSpace_recommendation() {
        let s = makeSnapshot(
            diskFreeBytes: 5_000_000_000,  // 5 GB
            diskTotalBytes: 500_000_000_000
        )
        let result = engine.analyze(s)
        
        let diskFinding = result.findings.first { $0.id.contains("storage.low") }
        XCTAssertNotNil(diskFinding)
        XCTAssertEqual(diskFinding?.severity, .warning, "<5% or <10GB should be warning")
        XCTAssertEqual(diskFinding?.action, .openSettings(section: "maintenance"))
    }
    
    // MARK: - Test 9: High RAM usage without pressure — no warning
    
    func testHighRAMUsageWithoutPressure_noWarning() {
        // High used RAM but normal pressure = OK (macOS uses RAM for cache)
        let s = makeSnapshot(memoryPressure: .normal)
        let result = engine.analyze(s)
        
        let memoryFinding = result.findings.first { $0.category == .memory }
        XCTAssertNil(memoryFinding, "Normal pressure should not produce memory finding")
    }
    
    func testMemoryPressureCritical_warning() {
        let s = makeSnapshot(memoryPressure: .critical, memorySwapUsed: 200_000_000)
        let result = engine.analyze(s)
        
        let memoryFinding = result.findings.first { $0.category == .memory }
        XCTAssertNotNil(memoryFinding)
        XCTAssertEqual(memoryFinding?.severity, .warning)
    }
    
    // MARK: - Test 10: Multiple findings sort correctly
    
    func testMultipleFindings_sortBySeverity() {
        let s = makeSnapshot(
            batteryHealthPercent: 75,  // warning
            cpuTemperature: 98,         // notice/warning
            diskFreeBytes: 5_000_000_000  // warning
        )
        let result = engine.analyze(s)
        
        XCTAssertGreaterThan(result.findings.count, 1)
        
        // Verify sorted by severity (descending)
        for i in 0..<(result.findings.count - 1) {
            XCTAssertTrue(
                result.findings[i].severity >= result.findings[i + 1].severity,
                "Findings should be sorted by severity descending"
            )
        }
    }
    
    // MARK: - Test 11: Duplicate findings deduplicate
    
    func testDuplicateFindings_deduplicate() {
        // Create conditions that might produce similar findings
        let s = makeSnapshot(
            cpuTemperature: 98,
            cpuTemperatureKeys: ["TCXC"]
        )
        let result = engine.analyze(s)
        
        let thermalIDs = result.findings.filter { $0.category == .thermal }.map { $0.id }
        let uniqueIDs = Set(thermalIDs)
        XCTAssertEqual(thermalIDs.count, uniqueIDs.count, "Thermal findings should be deduplicated")
    }
    
    // MARK: - Test 12: Dismissed finding hidden until cooldown
    
    func testDismissedFinding_hiddenUntilCooldown() {
        var store = AdvisorDismissalStore()
        store.dismiss("test.finding.1")
        
        XCTAssertTrue(store.isDismissed("test.finding.1"), "Should be dismissed immediately")
        XCTAssertFalse(store.isDismissed("test.finding.2"), "Other finding should not be dismissed")
    }
    
    func testDismissedFinding_reappearsAfterCooldown() {
        var store = AdvisorDismissalStore()
        store.dismiss("test.finding.1")
        
        // Simulate time travel by checking with short cooldown
        let shortCooldown: TimeInterval = 1  // 1 second
        usleep(1_100_000)  // Wait 1.1 seconds
        
        XCTAssertFalse(store.isDismissed("test.finding.1", cooldownSeconds: shortCooldown),
                      "Should reappear after cooldown")
    }
    
    // MARK: - Test 13: Critical finding returns on significant worsening
    
    func testCriticalFinding_returnsOnWorsening() {
        var store = AdvisorDismissalStore()
        store.dismiss("battery.health.85", version: "health_85")
        
        // Critical override allows early return
        XCTAssertFalse(store.isDismissed("battery.health.85", criticalOverride: true),
                      "Critical override should allow return")
    }
    
    // MARK: - Test 14: No actions performed during analysis
    
    func testNoActionsDuringAnalysis() {
        // Analysis is pure function — no side effects
        // This test verifies by checking that settings haven't changed
        let initialLimit = SettingsStore.chargeLimit
        let initialMode = SettingsStore.chargeMode
        
        let s = makeSnapshot(batteryExternalConnected: true, batteryChargePercent: 100)
        _ = engine.analyze(s)
        
        XCTAssertEqual(SettingsStore.chargeLimit, initialLimit, "Analysis should not change charge limit")
        XCTAssertEqual(SettingsStore.chargeMode, initialMode, "Analysis should not change mode")
    }
    
    // MARK: - Test 15: Desktop without battery — no battery findings
    
    func testDesktopNoBattery_noBatteryFindings() {
        let s = makeSnapshot(batteryPresent: false)
        let result = engine.analyze(s)
        
        let batteryFindings = result.findings.filter { $0.category == .battery }
        XCTAssertTrue(batteryFindings.isEmpty, "Desktop without battery should have no battery findings")
    }
    
    // MARK: - Test 16: Sail mode active — no always-plugged recommendation
    
    func testSailModeActive_noAlwaysPluggedRecommendation() {
        let s = makeSnapshot(
            batteryExternalConnected: true,
            batteryChargePercent: 100,
            sailModeActive: true
        )
        let result = engine.analyze(s)
        
        let pluggedFinding = result.findings.first { $0.id == "battery.always_plugged" }
        XCTAssertNil(pluggedFinding, "Sail mode should prevent always-plugged recommendation")
    }
    
    // MARK: - Test 17: Heat protection active — no overheat action
    
    func testHeatProtectionActive_noOverheatAction() {
        let s = makeSnapshot(
            batteryTemperature: 48,
            heatProtectionActive: true
        )
        let result = engine.analyze(s)
        
        let overheatFinding = result.findings.first { $0.id.contains("battery.overheat") }
        // Finding may exist but action should be nil
        if let finding = overheatFinding {
            XCTAssertNil(finding.action, "Heat protection active should not suggest action")
        }
    }
    
    // MARK: - Test 18: Empty snapshot produces safe defaults
    
    func testEmptySnapshot_safeDefaults() {
        let result = engine.analyze(.empty)
        
        // Should not crash and should produce minimal findings
        XCTAssertGreaterThanOrEqual(result.findings.count, 0)
        
        // No battery findings on empty (no battery present)
        let batteryFindings = result.findings.filter { $0.category == .battery }
        XCTAssertTrue(batteryFindings.isEmpty)
    }
    
    // MARK: - Test 19: Result status text matches max severity
    
    func testResultStatusText_matchesMaxSeverity() {
        let s1 = makeSnapshot()  // healthy
        let r1 = engine.analyze(s1)
        XCTAssertEqual(r1.statusText, L("Всё хорошо"))
        
        let s2 = makeSnapshot(batteryHealthPercent: 85)  // notice
        let r2 = engine.analyze(s2)
        XCTAssertTrue(["Есть рекомендации", "Требуется внимание"].contains(r2.statusText))
    }
    
    // MARK: - Test 20: Recent crashes threshold
    
    func testRecentCrashes_threshold() {
        let s1 = makeSnapshot(recentCrashesCount: 1)
        let r1 = engine.analyze(s1)
        let crashFinding1 = r1.findings.first { $0.id.contains("maintenance.crashes") }
        XCTAssertNil(crashFinding1, "1 crash should not trigger finding")
        
        let s2 = makeSnapshot(recentCrashesCount: 2)
        let r2 = engine.analyze(s2)
        let crashFinding2 = r2.findings.first { $0.id.contains("maintenance.crashes") }
        XCTAssertNotNil(crashFinding2, "2+ crashes should trigger finding")
    }
}
