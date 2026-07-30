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

    static let shared = GPUController()

    private init() {
        refreshSupportState()
    }

    // MARK: - Support Detection

    /// Проверить поддержку переключения GPU на текущем железе.
    func refreshSupportState() {
        // Синхронное чтение GPUInfo — не вызывает XPC, только Metal + pmset -g.
        supportState = GPUInfo.supportState()
        if supportState == .supported {
            // Загружаем текущий режим из pmset (быстрое чтение без root).
            selectedMode = GPUInfo.mode()
        }
    }

    // MARK: - Service State

    /// Проверить состояние привилегированного сервиса (not blocking, short cache).
    func refreshServiceState() {
        serviceState = PrivilegedServiceManager.cachedState()
    }

    var serviceHealthy: Bool {
        if case .healthy = serviceState { return true }
        return false
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
    func setMode(_ mode: GPUMode) {
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

            await MainActor.run {
                self.isApplying = false
                switch result {
                case .success(let confirmed):
                    self.selectedMode = confirmed
                case .failure(let error):
                    // Rollback к предыдущему значению.
                    self.selectedMode = previousMode ?? GPUInfo.mode()
                    self.lastError = error.localizedDescription
                }
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
