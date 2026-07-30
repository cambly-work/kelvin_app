import Foundation

private var failures = 0
private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("kelvin-sanitizer-\(UUID().uuidString)")

private func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("  ✓ \(name)")
    } else {
        failures += 1
        print("  ✗ \(name)")
    }
}

private func write(_ content: String) throws -> URL {
    let url = directory.appendingPathComponent("\(UUID().uuidString).ips")
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func sanitize(
    _ content: String
) throws -> CrashReportSanitizer.SanitizationResult {
    try CrashReportSanitizer.sanitize(
        url: write(content),
        reportID: "report-test",
        sourceFingerprint: "fingerprint-test"
    ).get()
}

do {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let privateBody = """
    {"app_name":"Kelvin","timestamp":"2026-07-30T12:34:56Z","exception_type":"EXC_BAD_ACCESS"}
    /Users/alice/Documents/private.txt
    alice@example.com
    KELVIN-ABCD-EFGH-IJKL-MNOP
    """
    let privateResult = try sanitize(privateBody)
    let payload = String(data: privateResult.jsonPayload, encoding: .utf8) ?? ""
    expect(!payload.contains("/Users/alice"), "home path is excluded")
    expect(!payload.contains("alice@example.com"), "email is excluded")
    expect(!payload.contains("KELVIN-ABCD"), "license key is excluded")
    expect(!privateResult.containsPII, "payload PII scan is clean")

    expect(
        privateResult.report.schemaVersion == CrashReportSanitizer.schemaVersion,
        "schema version is included"
    )
    expect(privateResult.report.reportID == "report-test", "report ID is preserved")
    expect(
        privateResult.report.sourceFingerprint == "fingerprint-test",
        "fingerprint is preserved"
    )
    expect(privateResult.report.application.name == "Kelvin", "application name is parsed")

    if let timestamp = privateResult.report.crashTimestamp {
        expect(
            Calendar(identifier: .gregorian).component(.second, from: timestamp) == 0,
            "timestamp is coarsened to a minute"
        )
    } else {
        expect(false, "timestamp is parsed")
    }

    let malformed = CrashReportSanitizer.sanitize(
        url: try write("not-json\n/Users/alice/Documents/private.txt"),
        reportID: "report-test",
        sourceFingerprint: "fingerprint-test"
    )
    if case .failure = malformed {
        expect(true, "malformed report fails closed")
    } else {
        expect(false, "malformed report fails closed")
    }

    let breadcrumbs = Array(
        repeating: SanitizerBreadcrumb.appStarted,
        count: CrashReportSanitizer.maxBreadcrumbs + 20
    )
    expect(
        CrashReportSanitizer.sanitizeBreadcrumbs(breadcrumbs).count
            == CrashReportSanitizer.maxBreadcrumbs,
        "breadcrumb limit is enforced"
    )
} catch {
    failures += 1
    print("  ✗ unexpected sanitizer error: \(error)")
}

if failures > 0 {
    print("✗ CrashReportSanitizer: \(failures) failures")
    exit(1)
}
print("✓ CrashReportSanitizer (11 checks)")
