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
enum GPUMode: Int {
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
}

/// Информация о видеокартах + переключение режима (как gfxCardStatus).
/// Адаптивно: на dual-GPU Mac с mux — полный контроль; на M-серии/одной карте — только показ.
enum GPUInfo {
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

    /// Переключение доступно только на dual-GPU Mac с mux (есть pmset gpuswitch + ≥2 карт).
    static var switchable: Bool { currentModeRaw() != nil && all().count >= 2 }

    /// Текущий режим (pmset gpuswitch).
    static func mode() -> GPUMode? { currentModeRaw().flatMap { GPUMode(rawValue: $0) } }

    private static func currentModeRaw() -> Int? {
        let out = shell("/usr/bin/pmset", ["-g"])
        for line in out.split(separator: "\n") where line.contains("gpuswitch") {
            return line.split(separator: " ").compactMap { Int($0) }.last
        }
        return nil
    }

    /// Применить режим: pmset -a gpuswitch N (root, через admin-промпт). Возвращает успех.
    @discardableResult
    static func setMode(_ m: GPUMode) -> Bool {
        let script = "do shell script \"/usr/bin/pmset -a gpuswitch \(m.rawValue)\" with administrator privileges"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        do { try task.run(); task.waitUntilExit(); return task.terminationStatus == 0 }
        catch { return false }
    }

    private static func shell(_ path: String, _ args: [String]) -> String {
        ProcessRunner.output(path, args, timeout: 8)
    }
}
