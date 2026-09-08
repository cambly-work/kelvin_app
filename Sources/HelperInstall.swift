import Foundation
import AppKit

/// Цивильная установка root-хелперов: запускает бандловый скрипт как root
/// через нативный диалог пароля (osascript admin) — без Терминала и copy-paste.
enum HelperInstall {
    private static var telemetryStaleSince: Date?
    private static var jobStateCache: [Kind: (checkedAt: Date, state: JobState)] = [:]
    private static var jobStartingSince: [Kind: Date] = [:]

    private enum JobState {
        case missing
        case starting
        case running
    }

    /// Системные компоненты Kelvin. Они намеренно разделены по назначению:
    /// telemetry только читает powermetrics, control применяет fan/charge policy.
    enum Kind: Hashable {
        case telemetry
        case control

        fileprivate var label: String {
            switch self {
            case .telemetry: return "com.trykelvin.kelvin.powerd"
            case .control: return "com.trykelvin.kelvin.fand"
            }
        }

        fileprivate var bundledPayload: String {
            switch self {
            case .telemetry: return "kelvin-powerd.sh"
            case .control: return "kelvin-fand"
            }
        }

        fileprivate var installedPayload: String {
            "/Library/Application Support/Kelvin/\(bundledPayload)"
        }

        /// Версия протокола/конфигурации, а не хэш конкретной сборки. Её нужно
        /// повышать только при несовместимом изменении helper, а не при каждом build.
        fileprivate var protocolVersion: String {
            switch self {
            case .telemetry: return "1"
            case .control: return "2"
            }
        }

        fileprivate var installedVersionFile: String {
            installedPayload + ".version"
        }
    }

    /// Состояние установки, не смешанное с runtime-health. Наличие одного plist больше
    /// не считается доказательством исправной установки.
    enum InstallState: Equatable {
        case notInstalled
        case starting
        case installed
        case updateAvailable
        case repairNeeded
    }

    /// Состояние телеметрии для popover. Краткая пауза после wake/нагрузки не должна
    /// превращаться в навязчивое «переустановите helper».
    enum TelemetryState: Equatable {
        case notInstalled
        case starting
        case ready
        case temporarilyUnavailable
        case repairNeeded
    }

    static func scriptPath(_ file: String) -> String? {
        let base = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        return Bundle.main.path(forResource: base, ofType: ext.isEmpty ? nil : ext)
    }

    /// Бандл безопасен для запуска root-скрипта? Отказываем, если .app или его Resources доступны на запись
    /// группе/другим — иначе атакующий подменил бы скрипт/бинарь в Resources и, когда пользователь введёт
    /// пароль, выполнил бы свой код как root (эскалация через записываемый бандл).
    private static func bundleSafeForPrivileged() -> Bool {
        let fm = FileManager.default
        let paths = [Bundle.main.bundlePath,
                     (Bundle.main.bundlePath as NSString).appendingPathComponent("Contents/Resources")]
        for p in paths {
            guard let attrs = try? fm.attributesOfItem(atPath: p),
                  let perm = (attrs[.posixPermissions] as? NSNumber)?.uint16Value else { return false }
            if perm & 0o022 != 0 { return false }          // group- или other-writable → небезопасно
        }
        return true
    }

    /// Не передаём root выполнение из изменённого после сборки bundle. Это не заменяет
    /// будущую проверку клиента в XPC service, но закрывает главный риск legacy installer.
    ///
    /// В production (когда `expectedDeveloperTeamID` настроен) дополнительно проверяем,
    /// что подпись выдана нашим Team ID — иначе атакующий мог переподписать ad-hoc
    /// изменённый bundle, и `codesign --verify` подтвердил бы лишь внутреннюю
    /// целостность, а не авторство. При настроенном Team ID_DR-проверка отвергает
    /// ad-hoc/переподписанные копии (fail-closed).
    private static func bundleSignatureValid() -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        var ok = ProcessRunner.succeeds(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", Bundle.main.bundlePath],
            timeout: 12
        )
        // В production: дополнительно проверяем DR с привязкой к Team ID.
        // ВАЖНО: для верификации нужен заглавный -R (--test-requirement), НЕ строчный -r
        // (--requirements используется при подписи; при verify он тихо игнорируется).
        if ok, let team = AppConfig.expectedDeveloperTeamID, !team.isEmpty {
            let req = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
            ok = ProcessRunner.succeeds(
                "/usr/bin/codesign",
                ["--verify", "--strict", "-R=\(req)", Bundle.main.bundlePath],
                timeout: 12
            )
        }
        return ok
    }

    /// Выполнить бандловый скрипт как root. Различает отмену пароля и реальный сбой.
    @discardableResult
    static func runPrivileged(_ file: String, prompt: String? = nil) -> (ok: Bool, canceled: Bool, output: String) {
        guard let path = scriptPath(file) else { return (false, false, "скрипт \(file) не найден в бандле") }
        guard bundleSafeForPrivileged() else {
            return (false, false, "бандл доступен на запись — переместите Kelvin в /Applications и повторите")
        }
        guard bundleSignatureValid() else {
            return (false, false, "Подпись Kelvin повреждена. Установите чистую копию приложения и повторите.")
        }
        let promptClause = prompt.map { " with prompt \"\($0.replacingOccurrences(of: "\"", with: ""))\"" } ?? ""
        // Закрываем root-инъекцию через путь .app (…/o'brien/…, …/Tim's Apps/…): тот же приём, что в Firewall/HostBlock —
        // shell-квотируем путь (' → '\''), затем экранируем строку для литерала AppleScript (\ → \\, " → \").
        let cmd = SecurityTools.quote(path)
        let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let src = "do shell script \"\(esc)\"\(promptClause) with administrator privileges"
        var err: NSDictionary?
        let out = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err {
            let canceled = (err[NSAppleScript.errorNumber] as? Int) == -128   // пользователь сам отменил пароль
            return (false, canceled, (err[NSAppleScript.errorMessage] as? String) ?? "ошибка")
        }
        invalidateStatus()
        return (true, false, out?.stringValue ?? "")
    }

    /// Человеческое сообщение при сбое (не отмене) привилегированной операции.
    static let friendlyFailure = "Не удалось получить права администратора. Попробуйте ещё раз и введите пароль администратора вашего Mac."

    /// Дружелюбно показывает сбой; на отмену пользователем — молчит. Возвращает true при успехе.
    @discardableResult
    static func presentFailureIfNeeded(_ r: (ok: Bool, canceled: Bool, output: String), title: String = L("Не удалось")) -> Bool {
        if r.ok { return true }
        if r.canceled { return false }                 // отмена — без пугающего алерта
        let a = NSAlert(); a.alertStyle = .warning
        a.messageText = title
        a.informativeText = r.output.isEmpty ? L(friendlyFailure) : r.output
        a.runModal()
        return false
    }

    private static func daemonPlist(_ kind: Kind) -> String {
        "/Library/LaunchDaemons/\(kind.label).plist"
    }

    private static func bundledPayloadPath(_ kind: Kind) -> String? {
        Bundle.main.path(forResource: kind.bundledPayload, ofType: nil)
    }

    private static func samePayload(_ kind: Kind) -> Bool {
        guard let bundled = bundledPayloadPath(kind),
              let expected = try? Data(contentsOf: URL(fileURLWithPath: bundled), options: .mappedIfSafe),
              let installed = try? Data(contentsOf: URL(fileURLWithPath: kind.installedPayload), options: .mappedIfSafe)
        else { return false }
        return expected == installed
    }

    private static func installedProtocolVersion(_ kind: Kind) -> String? {
        guard let value = try? String(contentsOfFile: kind.installedVersionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private static func launchdState(_ kind: Kind) -> JobState {
        if let cached = jobStateCache[kind],
           Date().timeIntervalSince(cached.checkedAt) < 2 {
            return cached.state
        }
        let output = ProcessRunner.output(
            "/bin/launchctl",
            ["print", "system/\(kind.label)"],
            timeout: 2
        )
        let state: JobState
        if output.contains("state = running") {
            state = .running
            jobStartingSince[kind] = nil
        } else if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state = .starting
            if jobStartingSince[kind] == nil { jobStartingSince[kind] = Date() }
        } else {
            state = .missing
            jobStartingSince[kind] = nil
        }
        jobStateCache[kind] = (Date(), state)
        return state
    }

    static func invalidateStatus() {
        jobStateCache.removeAll()
        jobStartingSince.removeAll()
        telemetryStaleSince = nil
    }

    static func installState(_ kind: Kind) -> InstallState {
        let fm = FileManager.default
        let hasPlist = fm.fileExists(atPath: daemonPlist(kind))
        let hasPayload = fm.fileExists(atPath: kind.installedPayload)
        if !hasPlist && !hasPayload { return .notInstalled }
        guard hasPlist && hasPayload else { return .repairNeeded }
        switch launchdState(kind) {
        case .missing:
            return .repairNeeded
        case .starting:
            if let since = jobStartingSince[kind],
               Date().timeIntervalSince(since) < 20 {
                return .starting
            }
            return .repairNeeded
        case .running:
            break
        }

        // Старые установки не имели version sidecar: для них один раз используем
        // сравнение payload. Новые сравниваются по версии протокола, поэтому обычная
        // пересборка Mach-O не превращается в ненужный admin prompt.
        if let installedVersion = installedProtocolVersion(kind) {
            return installedVersion == kind.protocolVersion ? .installed : .updateAvailable
        }
        return samePayload(kind) ? .installed : .updateAvailable
    }

    /// Для штатных операций установленная, но более старая версия остаётся рабочей.
    /// Обновление предлагается только в явном setup UI, а не во время переключения.
    static func isInstalled(_ kind: Kind) -> Bool {
        switch installState(kind) {
        case .installed, .updateAvailable: return true
        case .notInstalled, .starting, .repairNeeded: return false
        }
    }

    static var powerdInstalled: Bool { isInstalled(.telemetry) }
    static var fandInstalled: Bool { isInstalled(.control) }

    static func telemetryState(_ components: ComponentPower) -> TelemetryState {
        switch installState(.telemetry) {
        case .notInstalled:
            telemetryStaleSince = nil
            return .notInstalled
        case .repairNeeded:
            telemetryStaleSince = nil
            return .repairNeeded
        case .starting:
            return .starting
        case .installed, .updateAvailable:
            break
        }
        if components.fresh {
            telemetryStaleSince = nil
            return .ready
        }

        // После установки, перезапуска launchd или пробуждения первый powermetrics-снимок
        // закономерно появляется не мгновенно. Даём спокойное окно запуска без CTA ремонта.
        let fm = FileManager.default
        let plist = daemonPlist(.telemetry)
        let now = Date()
        if telemetryStaleSince == nil { telemetryStaleSince = now }
        if let staleSince = telemetryStaleSince, now.timeIntervalSince(staleSince) < 20 {
            return .starting
        }
        let dates = [plist, Kind.telemetry.installedPayload].compactMap {
            (try? fm.attributesOfItem(atPath: $0)[.modificationDate]) as? Date
        }
        if let newest = dates.max(), now.timeIntervalSince(newest) < 30 {
            return .starting
        }
        return .temporarilyUnavailable
    }
}
