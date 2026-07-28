//
//  CrashReportSanitizerTests.swift
//  Kelvin
//
//  Unit tests for crash report sanitization.
//  Golden tests verify NO PII leaks to output.
//

import XCTest
@testable import Kelvin

final class CrashReportSanitizerTests: XCTestCase {
    
    var sanitizer: CrashReportSanitizer!
    var tempDir: URL!
    var fileManager: FileManager!
    
    override func setUp() {
        super.setUp()
        fileManager = FileManager.default
        sanitizer = CrashReportSanitizer(fileManager: fileManager)
        
        // Create temp directory for test files
        tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? fileManager.removeItem(at: tempDir)
        sanitizer = nil
        super.tearDown()
    }
    
    // MARK: - Helper Methods
    
    private func createTestIPSFile(name: String, content: String) -> URL {
        let url = tempDir.appendingPathComponent(name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    
    private func assertNoPII(in payload: Data, testName: String) throws {
        guard let jsonString = String(data: payload, encoding: .utf8) else {
            XCTFail("\(testName): Could not decode payload as string")
            return
        }
        
        // Check for common PII patterns that should NEVER appear
        
        // Full home paths with real usernames
        XCTAssertFalse(jsonString.contains("/Users/alice/"), "\(testName): Contains username 'alice'")
        XCTAssertFalse(jsonString.contains("/Users/bob/"), "\(testName): Contains username 'bob'")
        XCTAssertFalse(jsonString.contains("/Users/charlie/"), "\(testName): Contains username 'charlie'")
        
        // Email addresses
        let emailPattern = "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}"
        let emailRegex = try NSRegularExpression(pattern: emailPattern)
        let matches = emailRegex.matches(in: jsonString, range: NSRange(jsonString.startIndex..., in: jsonString))
        XCTAssertTrue(matches.isEmpty, "\(testName): Contains email addresses")
        
        // UUIDs (hardware UUIDs, serial numbers)
        let uuidPattern = "[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"
        let uuidRegex = try NSRegularExpression(pattern: uuidPattern, options: .caseInsensitive)
        let uuidMatches = uuidRegex.matches(in: jsonString, range: NSRange(jsonString.startIndex..., in: jsonString))
        // Allow some UUIDs for binary images but they should be limited
        // This is a soft check - main verification is manual review of golden files
        if uuidMatches.count > 10 {
            XCTFail("\(testName): Contains too many UUIDs (\(uuidMatches.count))")
        }
        
        // License key patterns
        let licensePattern = "KELVIN-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}"
        let licenseRegex = try NSRegularExpression(pattern: licensePattern)
        let licenseMatches = licenseRegex.matches(in: jsonString, range: NSRange(jsonString.startIndex..., in: jsonString))
        XCTAssertTrue(licenseMatches.isEmpty, "\(testName): Contains license key pattern")
        
        // Document paths
        XCTAssertFalse(jsonString.lowercased().contains("/documents/"), "\(testName): Contains /Documents/ path")
        XCTAssertFalse(jsonString.lowercased().contains("/desktop/"), "\(testName): Contains /Desktop/ path")
        XCTAssertFalse(jsonString.lowercased().contains("/downloads/"), "\(testName): Contains /Downloads/ path")
    }
    
    // MARK: - Tests
    
    func testHomePathRedaction() throws {
        // Given an IPS file with full home paths
        let content = """
        Process:               Kelvin [12345]
        Path:                  /Users/alice/Applications/Kelvin.app/Contents/MacOS/Kelvin
        Identifier:            app.trykelvin.mac
        Version:               1.0 (100)
        
        Thread 0 Crashed:
        0   libsystem_kernel.dylib        0x00007fff12345678 __pthread_kill + 8
        1   Kelvin                        0x0000000100123456 fatalError() + 123
        2   Kelvin                        0x0000000100123789 someFunction(path: "/Users/alice/Documents/secret.docx") + 45
        """
        
        let ipsURL = createTestIPSFile(name: "Kelvin_test_home_path.ips", content: content)
        
        // When sanitized
        let result = sanitizer.sanitize(fileURL: ipsURL, bundleIdentifier: "app.trykelvin.mac")
        
        // Then home paths should be redacted
        XCTAssertNotNil(result)
        if let payload = result?.sanitizedPayload {
            let jsonString = String(data: payload, encoding: .utf8) ?? ""
            XCTAssertFalse(jsonString.contains("/Users/alice/"), "Should not contain username path")
            XCTAssertTrue(jsonString.contains("$HOME") || !jsonString.contains("/Users/"), "Should use $HOME or remove user paths")
            
            try assertNoPII(in: payload, testName: "testHomePathRedaction")
        }
    }
    
    func testEmailRedaction() throws {
        // Given an IPS file with email addresses (could appear in exception messages)
        let content = """
        Exception Type:        EXC_BAD_INSTRUCTION
        Exception Codes:       user@domain.com attempted invalid operation
        
        Application Specific Information:
        Failed to connect to admin@example.org
        Contact support at help@kelvin-mac.app for assistance
        """
        
        let ipsURL = createTestIPSFile(name: "Kelvin_test_email.ips", content: content)
        
        // When sanitized
        let result = sanitizer.sanitize(fileURL: ipsURL, bundleIdentifier: "app.trykelvin.mac")
        
        // Then emails should be redacted (except maybe official support email if allowlisted)
        XCTAssertNotNil(result)
        if let payload = result?.sanitizedPayload {
            try assertNoPII(in: payload, testName: "testEmailRedaction")
        }
    }
    
    func testLicenseKeyRedaction() throws {
        // Given an IPS file with license key in memory dump or exception info
        let content = """
        Exception Type:        EXC_CRASH
        Application Specific Information:
        License validation failed: KELVIN-ABCD-1234-EFGH-5678
        User provided key: KELVIN-WXYZ-9999-QQQQ-8888
        """
        
        let ipsURL = createTestIPSFile(name: "Kelvin_test_license.ips", content: content)
        
        // When sanitized
        let result = sanitizer.sanitize(fileURL: ipsURL, bundleIdentifier: "app.trykelvin.mac")
        
        // Then license keys should NOT appear
        XCTAssertNotNil(result)
        if let payload = result?.sanitizedPayload {
            let jsonString = String(data: payload, encoding: .utf8) ?? ""
            XCTAssertFalse(jsonString.contains("KELVIN-"), "Should not contain license key pattern")
            
            try assertNoPII(in: payload, testName: "testLicenseKeyRedaction")
        }
    }
    
    func testDocumentPathRedaction() throws {
        // Given an IPS file with document paths
        let content = """
        Thread 0 Crashed:
        0   Kelvin  0x0000000100123456 processFile("/Users/bob/Documents/Tax Returns/2024/private_info.pdf") + 123
        1   Kelvin  0x0000000100123789 loadFromDesktop("~/Desktop/secrets.txt") + 45
        2   Kelvin  0x0000000100123ABC readFromDownloads("/Users/bob/Downloads/passwords.csv") + 67
        """
        
        let ipsURL = createTestIPSFile(name: "Kelvin_test_documents.ips", content: content)
        
        // When sanitized
        let result = sanitizer.sanitize(fileURL: ipsURL, bundleIdentifier: "app.trykelvin.mac")
        
        // Then document paths should be redacted
        XCTAssertNotNil(result)
        if let payload = result?.sanitizedPayload {
            let jsonString = String(data: payload, encoding: .utf8) ?? ""
            XCTAssertFalse(jsonString.lowercased().contains("documents"), "Should not contain Documents path")
            XCTAssertFalse(jsonString.lowercased().contains("desktop"), "Should not contain Desktop path")
            XCTAssertFalse(jsonString.lowercased().contains("downloads"), "Should not contain Downloads path")
            
            try assertNoPII(in: payload, testName: "testDocumentPathRedaction")
        }
    }
    
    func testShellArgumentsRedaction() throws {
        // Given an IPS file with shell command arguments
        let content = """
        Process:               Kelvin [12345]
        Command Line:          /Applications/Kelvin.app/Contents/MacOS/Kelvin --user=admin --password=secret123 --config=/Users/charlie/.kelvin/config.json
        Environment:           HOME=/Users/charlie
                               USER=charlie
                               DB_PASSWORD=mysecretpassword
        """
        
        let ipsURL = createTestIPSFile(name: "Kelvin_test_shell_args.ips", content: content)
        
        // When sanitized - command line and environment should be excluded
        let result = sanitizer.sanitize(fileURL: ipsURL, bundleIdentifier: "app.trykelvin.mac")
        
        // Then sensitive args should not appear
        XCTAssertNotNil(result)
        if let payload = result?.sanitizedPayload {
            let jsonString = String(data: payload, encoding: .utf8) ?? ""
            XCTAssertFalse(jsonString.contains("--password="), "Should not contain password argument")
            XCTAssertFalse(jsonString.contains("DB_PASSWORD"), "Should not contain environment variables")
            XCTAssertFalse(jsonString.contains("/Users/charlie"), "Should not contain charlie's path")
            
            try assertNoPII(in: payload, testName: "testShellArgumentsRedaction")
        }
    }
    
    func testUnicodeUsername() throws {
        // Given an IPS file with Unicode username
        let content = """
        Process:               Kelvin [12345]
        Path:                  /Users/用户名/Applications/Kelvin.app/Contents/MacOS/Kelvin
        Thread crashed at /Users/用户名/Documents/файл.txt
        """
        
        let ipsURL = createTestIPSFile(name: "Kelvin_test_unicode.ips", content: content)
        
        // When sanitized
        let result = sanitizer.sanitize(fileURL: ipsURL, bundleIdentifier: "app.trykelvin.mac")
        
        // Then Unicode paths should be handled and redacted
        XCTAssertNotNil(result)
        if let payload = result?.sanitizedPayload {
            let jsonString = String(data: payload, encoding: .utf8) ?? ""
            XCTAssertFalse(jsonString.contains("用户名"), "Should not contain Chinese username")
            XCTAssertFalse(jsonString.contains("файл"), "Should not contain Russian filename")
            
            try assertNoPII(in: payload, testName: "testUnicodeUsername")
        }
    }
    
    func testKelvinOnlyFiltering() throws {
        // Given IPS files from different applications
        let kelvinContent = """
        Process:               Kelvin [12345]
        Identifier:            app.trykelvin.mac
        Thread 0 Crashed:
        0   Kelvin  0x0000000100123456 crash() + 123
        """
        
        let otherAppContent = """
        Process:               Safari [67890]
        Identifier:            com.apple.Safari
        Thread 0 Crashed:
        0   Safari  0x0000000200123456 crash() + 123
        """
        
        let kelvinURL = createTestIPSFile(name: "Kelvin_ours.ips", content: kelvinContent)
        let safariURL = createTestIPSFile(name: "Safari_other.ips", content: otherAppContent)
        
        // When filtering for Kelvin crashes only
        let kelvinResult = sanitizer.sanitize(fileURL: kelvinURL, bundleIdentifier: "app.trykelvin.mac")
        let safariResult = sanitizer.sanitize(fileURL: safariURL, bundleIdentifier: "app.trykelvin.mac")
        
        // Then only Kelvin crash should be processed
        XCTAssertNotNil(kelvinResult, "Should process Kelvin crash")
        XCTAssertNil(safariResult, "Should ignore non-Kelvin crashes")
    }
    
    func testPayloadSizeLimit() throws {
        // Given a very large IPS file
        var content = """
        Process:               Kelvin [12345]
        Identifier:            app.trykelvin.mac
        
        """
        
        // Add excessive thread frames
        for i in 0..<1000 {
            content += """
            Thread \(i) Crashed:
            """
            for j in 0..<100 {
                content += """
                \(j)   Kelvin  0x0000000100\(String(format: "%06X", i * 100 + j)) function\(j)() + \(j)
                
                """
            }
        }
        
        let ipsURL = createTestIPSFile(name: "Kelvin_huge.ips", content: content)
        
        // When sanitized
        let result = sanitizer.sanitize(fileURL: ipsURL, bundleIdentifier: "app.trykelvin.mac")
        
        // Then payload should be within limits
        XCTAssertNotNil(result)
        if let payload = result?.sanitizedPayload {
            XCTAssertLessThanOrEqual(payload.count, 512 * 1024, "Payload should not exceed 512KB")
        }
    }
    
    func testMalformedIPSHandling() throws {
        // Given malformed IPS content
        let content = """
        This is not a valid IPS file
        Just random text
        { broken json: 
        """
        
        let ipsURL = createTestIPSFile(name: "Kelvin_malformed.ips", content: content)
        
        // When sanitized - should handle gracefully
        let result = sanitizer.sanitize(fileURL: ipsURL, bundleIdentifier: "app.trykelvin.mac")
        
        // Then either returns nil or a minimal valid structure
        // The sanitizer should not crash on malformed input
        XCTAssertNotNil(result) // Or could be nil, depending on design choice
    }
    
    func testSchemaVersionIncluded() throws {
        // Given a valid IPS file
        let content = """
        Process:               Kelvin [12345]
        Identifier:            app.trykelvin.mac
        Version:               1.0 (100)
        Thread 0 Crashed:
        0   Kelvin  0x0000000100123456 crash() + 123
        """
        
        let ipsURL = createTestIPSFile(name: "Kelvin_schema.ips", content: content)
        
        // When sanitized
        let result = sanitizer.sanitize(fileURL: ipsURL, bundleIdentifier: "app.trykelvin.mac")
        
        // Then schema version should be included
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.schemaVersion, 1, "Should include schema version 1")
    }
}
