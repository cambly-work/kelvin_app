import AppKit
import Metal

/// Одна видеокарта (через Metal).
struct GPU {
    let name: String
    let integrated: Bool      // isLowPower → встроенная
    let external: Bool        // isRemovable → eGPU
    let vramMB: Int           // recommendedMaxWorkingSetSize
    let registryID: UInt64
    var kind: String { external ? L("Внешняя (eGPU)") : (integrated ? L("Встроенная") : L("Дискретная")) }
    var vramText: String { vramMB >= 1024 ? String(format: "%.0f %@", (Double(vramMB) / 1024).rounded(), L("ГБ")) : "\(vramMB) \(L("МБ"))" }
}

/// Режим переключения графики (pmset gpuswitch).
enum GPUMode: Int, CaseIterable {
    case integratedOnly = 0
    case discreteOnly = 1
    case automatic = 2
    var title: String {
        switch self {
        case .integratedOnly: return L("Только встроенная")
        case .discreteOnly:   return L("Только дискретная")
        case .automatic:      return L("Автоматически")
        }
    }
    var shortTitle: String {
        switch self {
        case .integratedOnly: return L("Встроенная")
        case .discreteOnly:   return L("Дискретная")
        case .automatic:      return L("Авто")
        }
    }
}

/// Уровень поддержки переключения GPU.
enum GPUSupportState: Equatable {
    case supported                    // Intel, dual internal GPU, pmset работает
    case appleSilicon                  // M-серия SoC — единый GPU
    case singleGPU                    // Найдена только одна видеокарта
    case externalGPUOnly             // Только eGPU, нет внутренней пары
    case pmsetUnsupported             // pmset gpuswitch недоступен
    case unknown                      // Не удалось определить

    var explanation: String {
        switch self {
        case .supported:       return L("Переключение GPU доступно")
        case .appleSilicon:    return L("Apple Silicon — единый GPU в SoC, переключение недоступно")
        case .singleGPU:       return L("Обнаружена только одна видеокарта")
        case .externalGPUOnly: return L("Подключён только внешний GPU, переключение недоступно")
        case .pmsetUnsupported: return L("Система не поддерживает переключение GPU (pmset gpuswitch)")
        case .unknown:         return L("Не удалось определить поддержку переключения GPU")
        }
    }
}

/// Информация о видеокартах (как gfxCardStatus).
/// Адаптивно: на dual-GPU Mac с mux — полный контроль; на M-серии/одной карте — только показ.
enum GPUInfo {
    /// Замкаемый вызов shell — для тестов можно подставить фейковый вывод.
    static var shell: (_ path: String, _ args: [String]) -> String = { path, args in
        ProcessRunner.output(path, args, timeout: 8)
    }

    /// Все GPU.
    static func all() -> [GPU] {
        MTLCopyAllDevices().map { d in
            GPU(name: d.name,
                integrated: d.isLowPower,
                external: d.isRemovable,
                vramMB: Int(d.recommendedMaxWorkingSetSize / (1024 * 1024)),
                registryID: d.registryID)
        }
    }

    /// GPU, который сейчас рисует главный дисплей (живой индикатор).
    static func active() -> GPU? {
        guard let dev = CGDirectDisplayCopyCurrentMetalDevice(CGMainDisplayID()) else { return nil }
        let id = dev.registryID
        return all().first { $0.registryID == id }
            ?? GPU(name: dev.name, integrated: dev.isLowPower, external: dev.isRemovable,
                   vramMB: Int(dev.recommendedMaxWorkingSetSize / (1024 * 1024)), registryID: id)
    }

    /// Apple Silicon? (единый GPU в SoC — переключать нечего).
    static var isAppleSilicon: Bool {
        var v: Int32 = 0; var sz = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &v, &sz, nil, 0) == 0 && v == 1
    }

    /// Есть ли встроенная (integrated) видеокарта.
    static var hasIntegratedGPU: Bool { all().contains { $0.integrated } }

    /// Есть ли внутренняя дискретная (discrete) видеокарта (не eGPU).
    static var hasInternalDiscreteGPU: Bool {
        all().contains { !$0.integrated && !$0.external }
    }

    /// Переключение доступно только на dual-GPU Mac с mux.
    static var switchable: Bool { supportState() == .supported }

    /// Текущий режим (pmset gpuswitch).
    static func mode() -> GPUMode? { currentModeRaw().flatMap { GPUMode(rawValue: $0) } }

    /// Расширенная проверка поддержки переключения GPU.
    static func supportState() -> GPUSupportState {
        if isAppleSilicon { return .appleSilicon }
        let gpus = all()
        guard gpus.count >= 2 else { return gpus.isEmpty ? .unknown : .singleGPU }
        let internals = gpus.filter { !$0.external }
        guard internals.contains(where: { $0.integrated }) else { return .externalGPUOnly }
        guard internals.contains(where: { !$0.integrated }) else { return .externalGPUOnly }
        guard currentModeRaw() != nil else { return .pmsetUnsupported }
        return .supported
    }

    /// Асинхронные варианты, выполняющие синхронный shell-вызов `pmset` на фоновой
    /// очереди. Синхронные `supportState()`/`mode()` читают `pmset -g` (fork+exec с
    /// watchdog 8с) — на главном потоке это фриз UI до 8с. Async-обёртки делегируют
    /// тяжёлый вызов в `Task.detached`, оставляя main-поток свободным.
    static func supportStateAsync() async -> GPUSupportState {
        await Task.detached(priority: .userInitiated) { supportState() }.value
    }

    static func modeAsync() async -> GPUMode? {
        await Task.detached(priority: .userInitiated) { mode() }.value
    }

    static func currentModeRaw() -> Int? {
        let out = shell("/usr/bin/pmset", ["-g"])
        for line in out.split(separator: "\n") where line.contains("gpuswitch") {
            return line.split(separator: " ").compactMap { Int($0) }.last
        }
        return nil
    }
}
