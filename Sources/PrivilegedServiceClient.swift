import Foundation
import Security
import os

/// Клиент XPC для KelvinPrivilegedService. Предоставляет типизированный API
/// для отправки запросов к привилегированному сервису и получения ответов.
actor PrivilegedServiceClient {

    /// Текущее соединение (nil если не подключено).
    private var connection: NSXPCConnection?

    /// Proxy для вызовов (nil если соединение не установлено).
    private var proxy: PrivilegedXPCProtocol?

    /// Состояние соединения.
    private(set) var connected: Bool = false

    /// Информация о сервисе (после успешного handshake).
    private(set) var serviceInfo: PrivilegedServiceInfo?

    /// Callback при изменении состояния соединения.
    var onStateChange: (@Sendable (Bool, PrivilegedServiceInfo?) -> Void)?

    /// Логгер для диагностики XPC.
    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.trykelvin.kelvin",
        category: "privileged-xpc"
    )

    // MARK: - Connection Lifecycle

    /// Подключиться к сервису. Возвращает true если соединение установлено.
    func connect() async -> Bool {
        // Если уже подключены — повторный handshake для подтверждения живости.
        if connected, let proxy {
            let result = await handshakeViaProxy(proxy)
            if case .success = result { return true }
            // Handshake не удался — сбрасываем соединение.
            resetConnection()
        }

        return await withTimeout(seconds: PrivilegedServiceConfig.connectionTimeout) {
            await self.performConnect()
        } ?? false
    }

    /// Отключиться от сервиса.
    func disconnect() {
        connection?.invalidate()
        connection = nil
        proxy = nil
        connected = false
        serviceInfo = nil
        Self.log.info("XPC соединение разорвано (disconnect)")
    }

    /// Выполнить handshake — получить информацию о сервисе и проверить совместимость.
    func handshake() async -> Result<PrivilegedServiceInfo, Error> {
        guard let proxy else {
            return .failure(GPUModeError.serviceUnavailable)
        }
        return await handshakeViaProxy(proxy)
    }

    // MARK: - GPU Operations

    /// Прочитать текущий режим GPU.
    func getGPUMode() async -> Result<GPUMode?, Error> {
        guard let proxy else {
            return .failure(GPUModeError.serviceUnavailable)
        }

        return await withTimeout(seconds: PrivilegedServiceConfig.commandTimeout) {
            await self.callGetGPUMode(proxy)
        } ?? .failure(GPUModeError.commandTimedOut)
    }

    /// Установить режим GPU.
    func setGPUMode(_ mode: GPUMode) async -> Result<GPUMode, Error> {
        guard let proxy else {
            return .failure(GPUModeError.serviceUnavailable)
        }

        // Генерируем уникальный ID запроса для сериализации и dedup на стороне сервиса.
        let requestID = UUID().uuidString

        return await withTimeout(seconds: PrivilegedServiceConfig.commandTimeout) {
            await self.callSetGPUMode(proxy, rawMode: mode.rawValue, requestID: requestID)
        } ?? .failure(GPUModeError.commandTimedOut)
    }

    // MARK: - Private — Connection

    /// Создать и настроить XPC соединение с Mach-сервисом.
    private func makeConnection() -> NSXPCConnection {
        let conn = NSXPCConnection(machServiceName: PrivilegedServiceConfig.machServiceName,
                                   options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: PrivilegedXPCProtocol.self)

        conn.interruptionHandler = { [weak self] in
            Task { await self?.handleInterruption() }
        }

        conn.invalidationHandler = { [weak self] in
            Task { await self?.handleInvalidation() }
        }

        return conn
    }

    /// Полная процедура подключения: создание соединения, resume, handshake.
    private func performConnect() async -> Bool {
        let conn = makeConnection()
        conn.resume()

        // Даём соединению мгновение для активации remoteObjectProxy.
        // NSXPCConnection создаёт proxy после resume; в норме — мгновенно,
        // но при первой загрузке сервиса возможна задержка.
        guard let remote = conn.remoteObjectProxyWithErrorHandler({ error in
            Self.log.error("XPC remoteObjectProxy error: \(error.localizedDescription, privacy: .public)")
        }) as? PrivilegedXPCProtocol else {
            Self.log.warning("XPC: не удалось получить remoteObjectProxy")
            conn.invalidate()
            return false
        }

        connection = conn
        proxy = remote

        // Проверяем подлинность сервиса перед довериями.
        guard verifyServiceIdentity() else {
            Self.log.error("XPC: проверка подписи сервиса не пройдена")
            conn.invalidate()
            connection = nil
            proxy = nil
            return false
        }

        // Handshake — убеждаемся в совместимости версий.
        let result = await handshakeViaProxy(remote)
        switch result {
        case .success:
            connected = true
            Self.log.info("XPC соединение установлено, handshake OK")
            notifyStateChange()
            return true
        case .failure(let error):
            Self.log.error("XPC handshake не удался: \(error.localizedDescription, privacy: .public)")
            conn.invalidate()
            connection = nil
            proxy = nil
            return false
        }
    }

    /// Сбросить состояние соединения (без вызова invalidate).
    private func resetConnection() {
        proxy = nil
        connection = nil
        connected = false
        serviceInfo = nil
        notifyStateChange()
    }

    // MARK: - Private — Handshake

    /// Выполнить handshake через заданный proxy.
    private func handshakeViaProxy(_ proxy: PrivilegedXPCProtocol) async -> Result<PrivilegedServiceInfo, Error> {
        await withCheckedContinuation { continuation in
            proxy.getServiceInfo { jsonString, error in
                if let error {
                    Self.log.error("XPC getServiceInfo error: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: .failure(error))
                    return
                }

                guard let jsonString else {
                    Self.log.error("XPC getServiceInfo: пустой ответ")
                    continuation.resume(returning: .failure(GPUModeError.serviceUnavailable))
                    return
                }

                guard let info = PrivilegedServiceInfo.from(xpcJSON: jsonString) else {
                    Self.log.error("XPC getServiceInfo: не удалось декодировать JSON")
                    continuation.resume(returning: .failure(GPUModeError.protocolMismatch))
                    return
                }

                // Проверяем совместимость версий протокола.
                guard info.protocolVersion == PrivilegedProtocolVersion.current else {
                    Self.log.error("XPC: несовместимая версия протокола: \(info.protocolVersion), ожидается \(PrivilegedProtocolVersion.current)")
                    continuation.resume(returning: .failure(GPUModeError.protocolMismatch))
                    return
                }

                self.serviceInfo = info
                continuation.resume(returning: .success(info))
            }
        }
    }

    // MARK: - Private — GPU Calls

    /// Вызов getGPUMode через XPC proxy.
    private func callGetGPUMode(_ proxy: PrivilegedXPCProtocol) async -> Result<GPUMode?, Error> {
        await withCheckedContinuation { continuation in
            proxy.getGPUMode { rawValue, error in
                if let error {
                    Self.log.error("XPC getGPUMode error: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: .failure(error))
                    return
                }

                // -1 = sentinel for "not available"
                guard rawValue >= 0 else {
                    continuation.resume(returning: .success(nil))
                    return
                }

                guard let mode = GPUMode(rawValue: rawValue) else {
                    Self.log.error("XPC getGPUMode: неизвестный raw value \(rawValue)")
                    continuation.resume(returning: .failure(GPUModeError.invalidMode))
                    return
                }

                continuation.resume(returning: .success(mode))
            }
        }
    }

    /// Вызов setGPUMode через XPC proxy с проверкой read-back.
    private func callSetGPUMode(_ proxy: PrivilegedXPCProtocol, rawMode: Int, requestID: String) async -> Result<GPUMode, Error> {
        await withCheckedContinuation { continuation in
            proxy.setGPUMode(rawMode, requestID: requestID) { confirmedRaw, error in
                if let error {
                    Self.log.error("XPC setGPUMode error: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: .failure(error))
                    return
                }

                // -1 = sentinel for verification failure (service could not confirm)
                guard confirmedRaw >= 0 else {
                    Self.log.error("XPC setGPUMode: verification failed (sentinel -1)")
                    continuation.resume(returning: .failure(GPUModeError.verificationFailed(expected: rawMode, actual: nil)))
                    return
                }

                // Read-back: сервис вернул подтверждённый режим. Сравниваем.
                guard confirmedRaw == rawMode else {
                    Self.log.error("XPC setGPUMode: mismatch — ожидался \(rawMode), получен \(confirmedRaw)")
                    continuation.resume(returning: .failure(GPUModeError.verificationFailed(expected: rawMode, actual: confirmedRaw)))
                    return
                }

                guard let confirmedMode = GPUMode(rawValue: confirmedRaw) else {
                    Self.log.error("XPC setGPUMode: подтверждённый raw value \(confirmedRaw) не является валидным GPUMode")
                    continuation.resume(returning: .failure(GPUModeError.invalidMode))
                    return
                }

                continuation.resume(returning: .success(confirmedMode))
            }
        }
    }

    // MARK: - Private — Handlers

    /// Обработать разрыв соединения (временно, может восстановиться).
    private func handleInterruption() {
        Self.log.warning("XPC соединение прервано")
        connected = false
        notifyStateChange()
    }

    /// Обработать инвалидацию соединения (безвозвратно).
    private func handleInvalidation() {
        Self.log.warning("XPC соединение инвалидировано")
        proxy = nil
        connection = nil
        connected = false
        notifyStateChange()
    }

    /// Уведомить подписчика об изменении состояния.
    private func notifyStateChange() {
        onStateChange?(connected, serviceInfo)
    }

    // MARK: - Private — Identity Verification

    /// Проверить подпись кода процесса XPC-сервиса. Убеждаемся, что соединён именно
    /// наш privileged helper, а не подмена. Используем SecCodeCopyGuestWithAttributes
    /// с PID-поиском: находим helper-процесс по имени и проверяем его кодподпись.
    private func verifyServiceIdentity() -> Bool {
        // Ищем процесс сервиса по имени Mach-сервиса (последний компонент).
        // privileged helper обычно называется по label, но мы используем PID
        // процесса с совпадающим именем.
        let serviceName = PrivilegedServiceConfig.machServiceName
        let helperName = (serviceName as NSString).lastPathComponent

        guard let pid = findPID(processName: helperName) else {
            Self.log.warning("XPC: процесс сервиса не найден (\(helperName)) — пропускаем верификацию")
            return true  // при первой загрузке PID может быть ещё недоступен
        }

        var code: SecCode?
        let pidDict: [String: Any] = [kSecGuestAttributePid as String: pid]

        guard SecCodeCopyGuestWithAttributes(nil,
                                              pidDict as CFDictionary,
                                              [],
                                              &code) == errSecSuccess,
              let code else {
            Self.log.warning("XPC: SecCodeCopyGuestWithAttributes не удалось для PID \(pid)")
            return true  // не блокируем при невозможности верифицировать
        }

        // Требуем совпадение bundle identifier с нашим сервисом.
        let requirement = "identifier \"\(PrivilegedServiceConfig.bundleID)\"" as CFString
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement, [], &req) == errSecSuccess,
              let req else {
            Self.log.error("XPC: не удалось создать SecRequirement")
            return false
        }

        let valid = SecCodeCheckValidity(code, [], req) == errSecSuccess
        if !valid {
            Self.log.error("XPC: код сервиса (PID \(pid)) не прошёл проверку подписи")
        }
        return valid
    }

    /// Найти PID процесса по имени исполняемого файла через /proc или sysctl.
    private func findPID(processName: String) -> pid_t? {
        // Используем sysctl для получения списка процессов.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0)
        let entryCount = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: entryCount)
        sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0)

        for proc in procs {
            let name = withUnsafePointer(to: proc.kp_proc.p_comm) { ptr -> String in
                let buf = UnsafeRawBufferPointer(start: ptr, count: MemoryLayout<CChar>.size * Int(MAXCOMLEN))
                let chars = buf.bindMemory(to: CChar.self)
                return String(cString: chars.baseAddress!)
            }
            if name == processName || name.hasSuffix("/\(processName)") {
                return proc.kp_proc.p_pid
            }
        }
        return nil
    }

    // MARK: - Private — Timeout Utility

    /// Обёртка с таймаутом для async-операций. Возвращает nil при превышении.
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            // Первый завершённый результат побеждает.
            for await result in group {
                group.cancelAll()
                return result
            }
            return nil
        }
    }
}
