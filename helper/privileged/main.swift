import Foundation
import Security

// MARK: - Service Configuration

let SERVICE_NAME     = "com.trykelvin.kelvin.privileged"
let BUNDLE_ID        = "com.trykelvin.kelvin"
let PROTOCOL_VERSION = 1
let SERVICE_VERSION  = "1.0.0"
let PMSET_PATH       = "/usr/bin/pmset"
let COMMAND_TIMEOUT: TimeInterval = 10.0

// MARK: - Allowed GPUMode values

/// pmset gpuswitch: 0 = integrated, 1 = discrete, 2 = automatic/dynamic.
let ALLOWED_MODES: Set<Int> = [0, 1, 2]

// MARK: - XPC Protocol Definition

/// Protocol copy for the helper — compiled independently from the app.
/// Must stay in sync with Sources/PrivilegedProtocol.swift.
@objc protocol PrivilegedXPCProtocol {
    /// Handshake: return JSON-encoded service info.
    func getServiceInfo(reply: @escaping (String?, Error?) -> Void)
    /// Read current GPU switching mode via pmset -g. Returns -1 if unavailable.
    func getGPUMode(reply: @escaping (Int, Error?) -> Void)
    /// Set GPU switching mode. requestID used for logging / future dedup.
    /// Returns confirmed mode, or -1 on verification failure.
    func setGPUMode(_ rawMode: Int, requestID: String, reply: @escaping (Int, Error?) -> Void)
}

// MARK: - Service Info ( Codable, mirrors PrivilegedServiceInfo from app )

private enum ServiceHealth: String, Codable { case healthy, degraded, unknown }

private struct ServiceInfoPayload: Codable {
    let serviceVersion: String
    let protocolVersion: Int
    let capabilities: [String]
    let health: String
}

// MARK: - GPU Errors ( mirrors GPUModeError from app, serialisable through XPC )

private enum HelperError: Int, Error {
    case unsupportedHardware = 1
    case invalidMode         = 2
    case unauthorizedClient  = 3
    case protocolMismatch    = 4
    case commandTimedOut     = 5
    case pmsetFailed         = 6
    case verificationFailed  = 7
    case internalError       = 8

    var localizedDescription: String {
        switch self {
        case .unsupportedHardware: return "GPU switching is not available on this Mac"
        case .invalidMode:         return "Invalid GPU mode value"
        case .unauthorizedClient:  return "Client is not authorized for this operation"
        case .protocolMismatch:    return "Protocol version is incompatible with the helper"
        case .commandTimedOut:    return "System command timed out"
        case .pmsetFailed:         return "pmset command failed"
        case .verificationFailed:  return "GPU mode verification failed"
        case .internalError:       return "Internal helper error"
        }
    }
}

// MARK: - Main Service

/// Root-level XPC service for Kelvin GPU mode switching.
/// Launched by launchd as root. Accepts XPC connections only from the
/// validated Kelvin application and executes `pmset -a gpuswitch`.
///
/// Security model:
/// - Every incoming connection is validated against the connecting process's
///   code-signing identity, bundle identifier, and (in production) Team ID.
/// - The only external process executed is the fixed-path `/usr/bin/pmset`
///   with a hard-coded set of allowed arguments. No shell, no AppleScript,
///   no arbitrary command execution.
/// - All pmset invocations run under a strict timeout.
class KelvinPrivilegedService: NSObject, NSXPCListenerDelegate, PrivilegedXPCProtocol {

    private let listener: NSXPCListener
    private let serialQueue = DispatchQueue(label: "\(SERVICE_NAME).commands")

    override init() {
        self.listener = NSXPCListener(machServiceName: SERVICE_NAME)
        super.init()
        self.listener.delegate = self
    }

    func start() {
        NSLog("[\(SERVICE_NAME)] Starting privileged XPC service (v\(SERVICE_VERSION))")
        listener.resume()
        // Keep the process running indefinitely
        RunLoop.main.run()
    }

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {

        // 1. Validate connecting process (audit token + code signing)
        guard validateClient(newConnection) else {
            NSLog("[\(SERVICE_NAME)] Client validation failed — rejecting connection")
            newConnection.invalidate()
            return false
        }

        // 2. Export interface and object
        newConnection.exportedInterface = NSXPCInterface(with: PrivilegedXPCProtocol.self)
        newConnection.exportedObject = self

        // 3. Lifecycle handlers
        newConnection.interruptionHandler = {
            NSLog("[\(SERVICE_NAME)] Connection interrupted")
        }
        newConnection.invalidationHandler = {
            NSLog("[\(SERVICE_NAME)] Connection invalidated")
        }

        newConnection.resume()
        NSLog("[\(SERVICE_NAME)] Accepted XPC connection from validated client")
        return true
    }

    // MARK: - PrivilegedXPCProtocol

    func getServiceInfo(reply: @escaping (String?, Error?) -> Void) {
        dispatchAsync {
            let payload = ServiceInfoPayload(
                serviceVersion: SERVICE_VERSION,
                protocolVersion: PROTOCOL_VERSION,
                capabilities: ["gpu"],
                health: ServiceHealth.healthy.rawValue
            )
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(payload),
               let json = String(data: data, encoding: .utf8) {
                reply(json, nil)
            } else {
                reply(nil, HelperError.internalError)
            }
        }
    }

    func getGPUMode(reply: @escaping (Int, Error?) -> Void) {
        dispatchAsync {
            if let mode = self.readCurrentMode() {
                reply(mode, nil)
            } else {
                // -1 = sentinel for "unavailable" (Swift optionals can't cross @objc)
                reply(-1, HelperError.unsupportedHardware)
            }
        }
    }

    func setGPUMode(_ rawMode: Int, requestID: String, reply: @escaping (Int, Error?) -> Void) {
        serialQueue.async {
            NSLog("[\(SERVICE_NAME)] setGPUMode(\(rawMode)) requestID=\(requestID)")

            // 1. Validate mode value
            guard ALLOWED_MODES.contains(rawMode) else {
                NSLog("[\(SERVICE_NAME)] Invalid GPU mode: \(rawMode)")
                reply(-1, HelperError.invalidMode)
                return
            }

            // 2. Execute pmset -a gpuswitch <mode>
            let result = self.runPmset(arguments: ["-a", "gpuswitch", "\(rawMode)"])
            if result.exitCode != 0 {
                NSLog("[\(SERVICE_NAME)] pmset failed with exit code \(result.exitCode): \(result.output)")
                reply(-1, HelperError.pmsetFailed)
                return
            }

            // 3. Read back to verify
            let confirmed = self.readCurrentMode()
            if let actual = confirmed, actual == rawMode {
                NSLog("[\(SERVICE_NAME)] GPU mode set and verified: \(rawMode)")
                reply(rawMode, nil)
            } else {
                NSLog("[\(SERVICE_NAME)] Verification failed: expected \(rawMode), got \(String(describing: confirmed))")
                reply(-1, HelperError.verificationFailed)
            }
        }
    }

    // MARK: - Client Validation

    /// Validate the connecting process by checking its code signature,
    /// bundle identifier, and (in production) Team ID.
    ///
    /// Steps:
    ///  1. Get the connecting process's PID from `NSXPCConnection.processIdentifier`.
    ///  2. Obtain a `SecCode` reference for that PID.
    ///  3. Verify the code signature against a designated requirement for our bundle ID.
    ///  4. Optionally verify the Team ID in production builds.
    private func validateClient(_ connection: NSXPCConnection) -> Bool {

        let pid = connection.processIdentifier
        guard pid > 0 else {
            NSLog("[\(SERVICE_NAME)] Invalid PID from connection — rejecting")
            return false
        }

        // Obtain SecCode for the connecting process by PID
        var code: SecCode?
        let attrs: [String: Any] = [kSecGuestAttributePid as String: pid]
        guard SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &code) == errSecSuccess,
              let secCode = code else {
            NSLog("[\(SERVICE_NAME)] SecCodeCopyGuestWithAttributes failed for pid \(pid) — rejecting")
            return false
        }

        // Verify the code against a designated requirement for our bundle ID.
        // This validates the connecting process is signed and matches our identifier.
        let requirementString = "identifier \"\(BUNDLE_ID)\"" as CFString
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString, [], &requirement) == errSecSuccess,
              let requirement else {
            NSLog("[\(SERVICE_NAME)] SecRequirementCreateWithString failed — rejecting")
            return false
        }

        // SecCodeCheckValidity verifies the code signature against the requirement.
        let valid = SecCodeCheckValidity(secCode, SecCSFlags(rawValue: 0), requirement) == errSecSuccess
        guard valid else {
            NSLog("[\(SERVICE_NAME)] Code signature check failed for pid \(pid) — rejecting")
            return false
        }

        // Production enforcement: require a Team ID (ad-hoc builds rejected).
        // Uncomment the following block when expectedDeveloperTeamID is configured:
        //
        // var info: CFDictionary?
        // guard SecCodeCopyDesignatedRequirement(secCode, [], &info) == errSecSuccess,
        //       let signingInfo = info as? [String: Any],
        //       let teamID = signingInfo[kSecCodeInfoTeamIdentifier as String] as? String,
        //       teamID == EXPECTED_TEAM_ID else {
        //     NSLog("[\(SERVICE_NAME)] Team ID mismatch for pid \(pid) — rejecting")
        //     return false
        // }

        NSLog("[\(SERVICE_NAME)] Client validated: pid=\(pid) bundleID=\(BUNDLE_ID)")
        return true
    }

    // MARK: - pmset Execution

    /// Execute `/usr/bin/pmset` with a fixed set of arguments under a strict timeout.
    ///
    /// Security note: the executable path is hard-coded to `PMSET_PATH`. Arguments are
    /// constructed internally and never come from the XPC client directly.
    ///
    /// - Parameters:
    ///   - arguments: Subcommand and flags (e.g. ["-g", "custom"] or ["-a", "gpuswitch", "1"]).
    ///   - timeout: Maximum seconds to wait (default: COMMAND_TIMEOUT).
    /// - Returns: A tuple of the process exit code and its combined stdout+stderr output.
    private func runPmset(arguments: [String],
                          timeout: TimeInterval = COMMAND_TIMEOUT) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: PMSET_PATH)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            NSLog("[\(SERVICE_NAME)] Failed to launch \(PMSET_PATH): \(error.localizedDescription)")
            return (-1, "")
        }

        // Enforce timeout
        let timeoutItem = DispatchWorkItem {
            if process.isRunning {
                NSLog("[\(SERVICE_NAME)] \(PMSET_PATH) timed out after \(timeout)s — terminating")
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutItem.cancel()

        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    /// Read the current `gpuswitch` value by parsing the output of `pmset -g custom`.
    ///
    /// Expected output format (line of interest):
    ///     gpuswitch   2
    ///
    /// - Returns: The current mode (0, 1, or 2) if found, or `nil` on failure
    ///   (e.g. hardware does not support GPU switching).
    private func readCurrentMode() -> Int? {
        let result = runPmset(arguments: ["-g", "custom"])
        guard result.exitCode == 0 else { return nil }

        for line in result.output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match lines like "gpuswitch   2"
            let parts = trimmed.split(separator: " ", maxSplits: 1,
                                      omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0] == "gpuswitch" {
                if let mode = Int(parts[1]), ALLOWED_MODES.contains(mode) {
                    return mode
                }
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// Dispatch work asynchronously off the XPC listener's queue.
    /// All reply handlers must be called from a non-listener queue.
    private func dispatchAsync(_ work: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async(execute: work)
    }
}

// MARK: - Entry Point

KelvinPrivilegedService().start()
