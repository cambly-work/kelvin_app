import Foundation
import Combine
import AppKit

/// Координатор GPU switching: связывает UI с PrivilegedServiceClient и
/// PrivilegedServiceManager. Управляет состоянием (idle/busy/error),
/// сериализует запросы и обеспечивает rollback при ошибке.
///
/// UI (Settings, popover) observes `@Published` свойства и не делает
/// прямых XPC-вызовов.
@MainActor
final class GPUController: ObservableObject {

    // MARK: - Published state for UI

    /// Текущий выбранный режим (policy из pmset). UI показывает это значение.
    @Published private(set) var selectedMode: GPUMode?

    /// Режим применяется — selector disabled.
    @Published private(set) var isApplying: Bool = false

    /// Последняя ошибка (nil = нет ошибки).
    @Published var lastError: String?

    /// Состояние привилегированного сервиса.
    @Published private(set) var serviceState: PrivilegedServiceState = .notInstalled

    /// Поддержка переключения на этом Mac.
    @Published private(set) var supportState: GPUSupportState = .unknown

    // MARK: - Internal

    private let client = PrivilegedServiceClient()
    private var refreshTask: Task<Void, Never>?
    private var healthVerifyTask: Task<Void, Never>?

    static let shared = GPUController()

    private init() {
        // НЕ вызываем синхронный refreshSupportState() здесь: он fork+exec'ит
        // `pmset` (до 8с watchdog) на main, а init срабатывает при первом доступе
        // к .shared (lazy). Вместо этого — фоновой загрузкой через Task: main
        // остаётся свободным, UI подхватит @Published когда данные придут.
        Task { @MainActor in
            await self.refreshSupportStateAsync()
        }
    }

    // MARK: - Support Detection

    /// Проверить поддержку переключения GPU на текущем железе.
    /// ВНИМАНИЕ: синхронный вариант блокирует main на fork+exec `pmset` (до 8с).
    /// С偏好 prefer `refreshSupportStateAsync()` из UI-контекста. Синхронный
    /// оставлён только для путей, где блокировка на main допустима.
    func refreshSupportState() {
        supportState = GPUInfo.supportState()
        if supportState == .supported {
            // Загружаем текущий режим из pmset.
            selectedMode = GPUInfo.mode()
        }
    }

    /// Асинхронная версия: выполняет `pmset -g` (и Metal-перечисление GPU) на фоновой
    /// очереди, результат применяет на main. Не блокирует UI. Prefer для popover/settings.
    func refreshSupportStateAsync() async {
        let state = await GPUInfo.supportStateAsync()
        supportState = state
        if state == .supported {
            // Загружаем текущий режим из pmset.
            selectedMode = await GPUInfo.modeAsync()
        }
    }

    /// Асинхронное обновление selectedMode из pmset без блокировки main.
    func refreshModeFromSystemAsync() async {
        guard supportState == .supported, !isApplying else { return }
        if let systemMode = await GPUInfo.modeAsync() {
            selectedMode = systemMode
        }
    }

    // MARK: - Service State

    /// Проверить состояние привилегированного сервиса (not blocking, short cache).
    /// Если SMAppService сообщил .enabled, состояние — .starting, и живость ещё не
    /// подтверждена. В этом случае запускаем bounded XPC-handshake и по успеху
    /// переводим в .healthy.
    func refreshServiceState() {
        serviceState = PrivilegedServiceManager.cachedState()
        if case .starting = serviceState {
            verifyServiceHealth()
        }
    }

    var serviceHealthy: Bool {
        if case .healthy = serviceState { return true }
        return false
    }

    /// Подтвердить живость сервиса через bounded XPC-handshake.
    /// Вызывается когда PrivilegedServiceManager вернул .starting (SMAppService .enabled,
    /// но XPC не проверен). После register()/возврата из System Settings даём демону
    /// до ~15 секунд подняться; на успех — .healthy, иначе — .unavailable.
    private func verifyServiceHealth() {
        healthVerifyTask?.cancel()
        healthVerifyTask = Task { [weak self] in
            guard let self else { return }
            // bounded retry: до 15 попыток × ~1с = 15с.
            for _ in 0..<15 {
                if Task.isCancelled { return }
                let connected = await self.client.connect()
                if connected {
                    let handshake = await self.client.handshake()
                    await MainActor.run {
                        switch handshake {
                        case .success(let info):
                            self.serviceState = .healthy(info)
                        case .failure:
                            // Зарегистрирован, но не отвечает → не healthy.
                            self.serviceState = .unavailable
                        }
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            // Ни одна попытка не удалась — сервис не отвечает.
            await MainActor.run { self.serviceState = .unavailable }
        }
    }

    /// Доступно ли переключение прямо сейчас: железо поддерживается И сервис здоров.
    var canSwitch: Bool {
        supportState == .supported && serviceHealthy
    }

    // MARK: - Switch

    /// Установить режим GPU через XPC.
    /// - Не запускает запрос, если режим уже активен.
    /// - Сериализует запросы (isApplying блокирует selector).
    /// - При ошибке возвращает selectedMode к фактическому значению.
    func setMode(_ mode: GPUMode, completion: ((Result<GPUMode, Error>) -> Void)? = nil) {
        // Не запускаем запрос если:
        // - уже применяем что-то
        // - выбранный режим уже активен
        guard !isApplying else { return }
        guard mode != selectedMode else { return }

        let previousMode = selectedMode
        selectedMode = mode
        isApplying = true
        lastError = nil

        Task { [weak self] in
            guard let self else { return }
            let result = await self.performSetMode(mode)

            // При ошибке: если previousMode неизвестен, читаем актуальный режим из
            // pmset async — не блокируя main (sync GPUInfo.mode() = fork+exec).
            var resolvedMode = previousMode
            if case .failure = result, resolvedMode == nil {
                resolvedMode = await GPUInfo.modeAsync()
            }

            await MainActor.run {
                self.isApplying = false
                switch result {
                case .success(let confirmed):
                    self.selectedMode = confirmed
                case .failure(let error):
                    // Rollback к предыдущему значению (или актуальному из системы).
                    self.selectedMode = resolvedMode
                    self.lastError = error.localizedDescription
                }
                completion?(result)
            }
        }
    }

    /// Выполнить setMode через XPC клиент.
    private func performSetMode(_ mode: GPUMode) async -> Result<GPUMode, Error> {
        // Убеждаемся что соединение установлено.
        let connected = await client.connect()
        guard connected else {
            return .failure(GPUModeError.serviceUnavailable)
        }
        return await client.setGPUMode(mode)
    }

    // MARK: - Read-back refresh

    /// Обновить selectedMode из pmset (без XPC, быстрое чтение).
    /// Вызывается периодически или после переключения.
    func refreshModeFromSystem() {
        guard supportState == .supported else { return }
        let systemMode = GPUInfo.mode()
        if let systemMode, !isApplying {
            selectedMode = systemMode
        }
    }

    // MARK: - Install / Uninstall

    /// Установить/обновить привилегированный сервис. Показывает явный setup flow.
    func installService() async -> PrivilegedServiceManager.InstallResult {
        let result = await PrivilegedServiceManager.install()
        refreshServiceState()
        if case .success = result {
            // Повторяем исходный intent один раз.
            // Если был выбран режим до установки — применяем его.
        }
        return result
    }

    /// Удалить привилегированный сервис.
    func uninstallService() -> Bool {
        let ok = PrivilegedServiceManager.uninstall()
        refreshServiceState()
        return ok
    }

    // MARK: - Diagnostics

    /// Подробная диагностика для UI / debugging.
    var diagnosticText: String {
        PrivilegedServiceManager.diagnosticInfo()
    }

    /// Сбросить ошибку (вызывается из UI при retry/dismiss).
    func clearError() {
        lastError = nil
    }
}
