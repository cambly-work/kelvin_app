import Foundation

private var checks = 0

private func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if condition() {
        print("  ✓ \(name)")
    } else {
        fputs("  ✗ \(name)\n", stderr)
        exit(1)
    }
}

let configuration = CrashReportUploader.makeSessionConfiguration(for: .default)
expect(configuration.identifier == nil, "session is not background")
expect(configuration.urlCache == nil, "response cache is disabled")

// На background-конфигурации именно этот вызов бросает необрабатываемый
// NSGenericException. Сам запрос не запускаем: тест проверяет совместимость API.
let session = URLSession(configuration: configuration)
let task = session.dataTask(with: URL(string: "https://example.invalid/crash")!) { _, _, _ in }
expect(task.state == .suspended, "completion-handler dataTask is created safely")
task.cancel()
session.invalidateAndCancel()

print("✓ CrashReportUploader URLSession (\(checks) checks)")
