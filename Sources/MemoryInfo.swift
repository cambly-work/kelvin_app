import Foundation

/// Давление памяти — ЧЕСТНАЯ метрика macOS. Мы НАМЕРЕННО не показываем «% занято»: macOS держит почти всю
/// RAM под кэш, поэтому высокий «used» — норма, а не тревога (наивный % напугал бы без причины). Ядро само
/// сообщает уровень давления (kern.memorystatus_vm_pressure_level: 1 норма / 2 повышенное / 4 критическое) —
/// вот честный сигнал «реально ли не хватает памяти». Своп в работе — дополнительный честный признак нехватки.
/// Всё через sysctl: без root, без сети, мгновенно.
enum MemoryInfo {
    enum Pressure { case normal, warning, critical, unknown }
    struct State { let pressure: Pressure; let totalRAM: UInt64; let swapUsed: UInt64 }

    static func read() -> State {
        State(pressure: pressureLevel(),
              totalRAM: ProcessInfo.processInfo.physicalMemory,
              swapUsed: swapUsed())
    }

    /// Уровень давления памяти из ядра. Недокументированное значение → .unknown (не выдумываем смысл).
    private static func pressureLevel() -> Pressure {
        var lvl: Int32 = 0; var sz = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &lvl, &sz, nil, 0) == 0 else { return .unknown }
        switch lvl {
        case 1: return .normal
        case 2: return .warning
        case 4: return .critical
        default: return .unknown
        }
    }

    /// Использованный своп (байт). Своп > 0 = система вытесняла страницы на диск — честный признак нехватки RAM.
    private static func swapUsed() -> UInt64 {
        var xsw = xsw_usage(); var sz = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &xsw, &sz, nil, 0) == 0 else { return 0 }
        return xsw.xsu_used
    }
}
