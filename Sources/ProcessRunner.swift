import Foundation
import Darwin

/// Bounded subprocess runner used by monitoring modules.
/// It always drains captured output, never leaves an unread stderr pipe, and
/// terminates commands that would otherwise keep a refresh queue stuck forever.
enum ProcessRunner {
    static func output(
        _ path: String,
        _ arguments: [String],
        timeout: TimeInterval = 8,
        mergeError: Bool = false
    ) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = mergeError ? output : FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ""
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func succeeds(
        _ path: String,
        _ arguments: [String],
        timeout: TimeInterval = 8
    ) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }
}
