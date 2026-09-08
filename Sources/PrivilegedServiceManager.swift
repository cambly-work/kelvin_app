import Foundation
import ServiceManagement
#if canImport(Security)
import Security
#endif

/// Управление жизненным циклом KelvinPrivilegedService.
/// Единая точка установки, обновления, проверки состояния и удаления GPU-сервиса.
enum PrivilegedServiceManager {

    // MARK: - State cache

    private static var cachedResult: (checkedAt: Date, state: PrivilegedServiceState)?

    // MARK: - State

    /// Текущее состояние сервиса.
    static func state() -> PrivilegedServiceState {
        cachedResult = nil
        return resolveState()
    }

    /// Текущее состояние (кэшированное на короткий интервал).
    static func cachedState() -> PrivilegedServiceState {
        if let cached = cachedResult,
           Date().timeIntervalSince(cached.checkedAt) < 2 {
            return cached.state
        }
        let s = resolveState()
        cachedResult = (Date(), s)
        return s
    }

    /// Проверить состояние с учётом версии macOS.
    private static func resolveState() -> PrivilegedServiceState {
        // Визуальный regression hook: позволяет BM_SNAP проверить именно установленный
        // GPU-selector, не регистрируя root-сервис на машине сборки. В обычном запуске
        // переменная BM_SNAP отсутствует, поэтому production-state не подменяется.
        // DEBUG-only: иначе любой, кто может задать
        // переменные окружения запуска, заставит UI показывать сервис «здоровым».
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["BM_SNAP"] != nil, environment["BM_GPU_READY"] != nil {
            return .healthy(PrivilegedServiceInfo(
                serviceVersion: "snapshot",
                protocolVersion: PrivilegedProtocolVersion.current,
                capabilities: [.gpuSwitching],
                health: .healthy
            ))
        }
        #endif
        if #available(macOS 13.0, *) {
            return smAppBasedState()
        } else {
            return legacyState()
        }
    }

    // MARK: - Install

    /// Установить сервис (системный approval flow).
    /// Возвращает true если установка прошла успешно.
    /// На macOS 13+: использует SMAppService, может вернуть approvalRequired.
    /// На macOS 11-12: использует SMJobBless с авторизацией.
    static func install() async -> InstallResult {
        guard isAppInApplications() else {
            return .failed(L("Kelvin должен находиться в папке /Applications для установки системного компонента"))
        }

        cachedResult = nil

        if #available(macOS 13.0, *) {
            return await smAppInstall()
        } else {
            return legacyInstall()
        }
    }

    /// Обновить сервис до текущей версии.
    static func update() async -> InstallResult {
        // На macOS 13+ — unregister + register.
        // На macOS 11-12 — повторный SMJobBless заменяет бинарник.
        if #available(macOS 13.0, *) {
            let service = SMAppService.daemon(plistName: PrivilegedServiceConfig.plistName)
            // Попытка unregister: игнорируем ошибку (сервис может быть не зарегистрирован)
            try? await service.unregister()
            cachedResult = nil
            return await registerSMAppService(service)
        } else {
            return legacyInstall()
        }
    }

    // MARK: - Uninstall

    /// Удалить сервис.
    static func uninstall() -> Bool {
        cachedResult = nil

        if #available(macOS 13.0, *) {
            let service = SMAppService.daemon(plistName: PrivilegedServiceConfig.plistName)
            do {
                try service.unregister()
                return true
            } catch {
                return false
            }
        } else {
            return legacyUninstall()
        }
    }

    // MARK: - Diagnostics

    /// Подробная диагностика для отладки.
    static func diagnosticInfo() -> String {
        var lines: [String] = []
        let os = ProcessInfo.processInfo.operatingSystemVersion
        lines.append("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        lines.append("Service: \(PrivilegedServiceConfig.serviceName)")
        lines.append("Plist name: \(PrivilegedServiceConfig.plistName)")
        lines.append("Bless label: \(PrivilegedServiceConfig.blessHelperLabel)")
        lines.append("Bundled plist: \(blessPlistPath ?? "nil")")
        lines.append("Bundled binary: \(bundledBinaryPath)")
        lines.append("Bundled binary exists: \(bundledBinaryExists())")
        lines.append("Installed binary: \(installedBinaryPath)")
        lines.append("Binary exists: \(installedBinaryExists())")
        lines.append("Version current: \(isVersionCurrent())")
        lines.append("App in /Applications: \(isAppInApplications())")

        if #available(macOS 13.0, *) {
            let status = smAppServiceState()
            lines.append("SMAppService status: \(smStatusString(status))")
        } else {
            let ld = legacyDaemonState()
            lines.append("Legacy daemon: \(legacyStateString(ld))")
        }

        // launchctl output
        let launchctlOut = ProcessRunner.output(
            "/bin/launchctl", ["print", "system/\(PrivilegedServiceConfig.serviceName)"],
            timeout: 2
        )
        lines.append("launchctl: \(launchctlOut.trimmingCharacters(in: .whitespacesAndNewlines))")

        return lines.joined(separator: "\n")
    }

    // MARK: - Install Result

    enum InstallResult: Equatable {
        case success
        case approvalRequired        // User needs to approve in System Settings
        case failed(String)          // Error description
        case cancelled               // User cancelled
    }

    // MARK: - Internal

    /// Проверить что приложение находится в /Applications (требование для установки).
    static func isAppInApplications() -> Bool {
        let bundlePath = Bundle.main.bundlePath.lowercased()
        return bundlePath.hasPrefix("/applications/")
    }

    /// Проверить состояние через SMAppService (macOS 13+).
    @available(macOS 13.0, *)
    static func smAppServiceState() -> SMAppService.Status {
        let service = SMAppService.daemon(plistName: PrivilegedServiceConfig.plistName)
        return service.status
    }

    /// Проверить состояние через launchctl (macOS 11-12).
    static func legacyDaemonState() -> LegacyDaemonState {
        let fm = FileManager.default
        let plistPath = "/Library/LaunchDaemons/\(PrivilegedServiceConfig.plistName)"
        let binaryPath = installedBinaryPath

        let hasPlist = fm.fileExists(atPath: plistPath)
        let hasBinary = fm.fileExists(atPath: binaryPath)

        if !hasPlist && !hasBinary { return .missing }

        let output = ProcessRunner.output(
            "/bin/launchctl", ["print", "system/\(PrivilegedServiceConfig.serviceName)"],
            timeout: 2
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        if output.isEmpty {
            return hasPlist ? .error("plist существует, но сервис не загружен") : .missing
        }
        if output.contains("state = running") {
            return .running
        }
        // Загружен, но ещё не running (starting)
        return .loaded
    }

    enum LegacyDaemonState {
        case missing
        case loaded
        case running
        case error(String)
    }

    /// Проверить установленный бинарный файл.
    static func installedBinaryExists() -> Bool {
        FileManager.default.fileExists(atPath: installedBinaryPath)
    }

    /// Сравнить версию установленного сервиса с ожидаемой.
    static func isVersionCurrent() -> Bool {
        // Читаем version file рядом с бинарником. Если файла нет — считаем неактуальным.
        let versionFile = installedBinaryPath + ".version"
        guard let installed = try? String(contentsOfFile: versionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !installed.isEmpty
        else { return false }
        return installed == "\(PrivilegedProtocolVersion.current)"
    }

    /// Путь к plist в Contents/Library/LaunchDaemons/ (для SMAppService / SMJobBless).
    static var blessPlistPath: String? {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons/\(PrivilegedServiceConfig.plistName)")
            .path
    }

    /// Путь к установочному бинарнику.
    static var installedBinaryPath: String {
        "/Library/PrivilegedHelperTools/\(PrivilegedServiceConfig.serviceName)"
    }

    /// SMAppService (macOS 13+) does not copy the daemon to
    /// /Library/PrivilegedHelperTools. It launches the signed executable that
    /// remains inside Kelvin.app.
    static var bundledBinaryPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons/\(PrivilegedServiceConfig.serviceName)")
            .path
    }

    static func bundledBinaryExists() -> Bool {
        FileManager.default.isExecutableFile(atPath: bundledBinaryPath)
    }

    // MARK: - macOS 13+ (SMAppService)

    @available(macOS 13.0, *)
    private static func smAppBasedState() -> PrivilegedServiceState {
        let status = smAppServiceState()
        switch status {
        case .notRegistered:
            return .notInstalled
        case .enabled:
            // SMAppService keeps the executable in the signed app bundle.
            guard bundledBinaryExists() else { return .repairNeeded }
            // НЕ считаем сервис здоровым только по SMAppService.status == .enabled:
            // это подтверждает регистрацию/разрешение, но не то, что процесс стартовал
            // и отвечает по XPC. Возвращаем .starting — GPUController подтвердит
            // живость через bounded XPC-handshake и выставит .healthy.
            return .starting
        case .requiresApproval:
            return .approvalRequired
        case .notFound:
            return .notInstalled
        @unknown default:
            return .notInstalled
        }
    }

    @available(macOS 13.0, *)
    private static func smAppInstall() async -> InstallResult {
        let service = SMAppService.daemon(plistName: PrivilegedServiceConfig.plistName)
        return await registerSMAppService(service)
    }

    /// Регистрация SMAppService с разбором ошибок.
    /// requiresApproval → нужно открыть системные настройки; -128 → отмена.
    @available(macOS 13.0, *)
    private static func registerSMAppService(_ service: SMAppService) async -> InstallResult {
        do {
            try service.register()
            // Registration and administrator approval are separate for a
            // LaunchDaemon. Never tell the UI it is connected while approval
            // is still pending.
            switch service.status {
            case .enabled: return .success
            case .requiresApproval: return .approvalRequired
            case .notFound, .notRegistered: return .failed(L("Системный компонент недоступен"))
            @unknown default: return .failed(L("Системный компонент недоступен"))
            }
        } catch {
            let nsError = error as NSError
            // -128 = пользователь отменил авторизацию
            if nsError.code == -128 { return .cancelled }
            // requiresApproval: сервис зарегистрирован, но требует одобрения в Login Items
            // Код 1 в домене SMAppServiceErrorDomain
            if nsError.domain == "com.apple.ServiceManagement.SMAppService" && nsError.code == 1 {
                return .approvalRequired
            }
            // Дополнительная эвристика: проверяем статус после ошибки
            if service.status == .requiresApproval {
                return .approvalRequired
            }
            return .failed(nsError.localizedDescription)
        }
    }

    // MARK: - macOS 11-12 (SMJobBless)

    private static func legacyState() -> PrivilegedServiceState {
        let fm = FileManager.default
        let plistPath = "/Library/LaunchDaemons/\(PrivilegedServiceConfig.plistName)"
        let binaryPath = installedBinaryPath

        let hasPlist = fm.fileExists(atPath: plistPath)
        let hasBinary = fm.fileExists(atPath: binaryPath)

        if !hasPlist && !hasBinary { return .notInstalled }
        guard hasPlist && hasBinary else { return .repairNeeded }

        switch legacyDaemonState() {
        case .running:
            return .healthy(PrivilegedServiceInfo(
                serviceVersion: readInstalledVersion(),
                protocolVersion: PrivilegedProtocolVersion.current,
                capabilities: [.gpuSwitching],
                health: isVersionCurrent() ? .healthy : .degraded
            ))
        case .loaded:
            return .installing
        case .missing:
            return .repairNeeded
        case .error:
            return .repairNeeded // plist есть, но сервис не загружен
        }
    }

    private static func legacyInstall() -> InstallResult {
        // SMJobBless — triggers Authorization Services dialog.
        // Не поддерживает async, но вызов быстрый (системный диалог).
        var cfError: Unmanaged<CFError>?
        let success = SMJobBless(
            kSMDomainSystemLaunchd,
            PrivilegedServiceConfig.blessHelperLabel as CFString,
            nil,
            &cfError
        )
        if success {
            cachedResult = nil
            return .success
        }
        let error = cfError?.takeRetainedValue()
        let desc = error.flatMap { ($0 as Error).localizedDescription }
            ?? L("Не удалось установить системный компонент")
        // -128 = пользователь отменил авторизацию
        if let cfErr = error as? NSError, cfErr.code == -128 {
            return .cancelled
        }
        return .failed(desc)
    }

    private static func legacyUninstall() -> Bool {
        let fm = FileManager.default
        let label = PrivilegedServiceConfig.serviceName
        let plistPath = "/Library/LaunchDaemons/\(PrivilegedServiceConfig.plistName)"

        // Выгрузить через launchctl (ignore errors — может быть не загружен)
        _ = ProcessRunner.output("/bin/launchctl", ["bootout", "system/\(label)"], timeout: 5)

        // Удалить plist
        try? fm.removeItem(atPath: plistPath)

        // Удалить бинарник
        try? fm.removeItem(atPath: installedBinaryPath)

        cachedResult = nil
        return true
    }

    // MARK: - Helpers

    /// Прочитать версию установленного сервиса (из sidecar-файла).
    private static func readInstalledVersion() -> String {
        let versionFile = installedBinaryPath + ".version"
        return (try? String(contentsOfFile: versionFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "0"
    }

    private static var bundledVersionPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/kelvin-privileged.version")
            .path
    }

    private static func readBundledVersion() -> String {
        (try? String(contentsOfFile: bundledVersionPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? "0"
    }

    private static func isBundledVersionCurrent() -> Bool {
        readBundledVersion() == "\(PrivilegedProtocolVersion.current)"
    }

    /// Человекочитаемое описание SMAppService.Status.
    @available(macOS 13.0, *)
    private static func smStatusString(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    /// Человекочитаемое описание LegacyDaemonState.
    private static func legacyStateString(_ state: LegacyDaemonState) -> String {
        switch state {
        case .missing: return "missing"
        case .loaded: return "loaded"
        case .running: return "running"
        case .error(let msg): return "error: \(msg)"
        }
    }
}
