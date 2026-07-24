import Foundation
import Darwin

/// Загрузка CPU и памяти (Mach, без root). Хранит историю для мини-графика в строке меню.
final class SystemUsage {
    static let shared = SystemUsage()

    private var prevTicks: (user: Double, sys: Double, idle: Double, nice: Double)?
    private(set) var cpuHistory: [Double] = []
    private(set) var ramHistory: [Double] = []

    // Кэш последнего реального сэмпла: второй вызов за тик (Δt < 0.05с) вернёт его,
    // не пересчитывая на мусорной дельте и не засоряя историю (зеркалит NetUsage.sample).
    private var lastCPU: Double = 0
    private var lastRAM: Double = 0
    private var lastCPUAt: Date?
    private var lastRAMAt: Date?

    /// Текущая загрузка CPU 0…1 (по дельте тиков между вызовами).
    @discardableResult
    func cpu() -> Double {
        // дребезг/двойной вызов за тик → отдать последний реальный сэмпл (prevTicks НЕ трогаем)
        if let t = lastCPUAt, Date().timeIntervalSince(t) < 0.05 { return lastCPU }
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return cpuHistory.last ?? 0 }
        let u = Double(info.cpu_ticks.0), s = Double(info.cpu_ticks.1), i = Double(info.cpu_ticks.2), n = Double(info.cpu_ticks.3)
        defer { prevTicks = (u, s, i, n) }
        guard let p = prevTicks else { return 0 }
        let du = u - p.user, ds = s - p.sys, di = i - p.idle, dn = n - p.nice
        let total = du + ds + di + dn
        let load = total > 0 ? (du + ds + dn) / total : 0
        let v = max(0, min(1, load))
        push(&cpuHistory, v)
        lastCPU = v; lastCPUAt = Date()
        return v
    }

    /// Использование памяти 0…1 (≈ как «Память использована» в Мониторинге: active+wired+compressed).
    @discardableResult
    func ram() -> Double {
        // дребезг/двойной вызов за тик → отдать последний реальный сэмпл
        if let t = lastRAMAt, Date().timeIntervalSince(t) < 0.05 { return lastRAM }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return ramHistory.last ?? 0 }
        let page = Double(vm_kernel_page_size)
        let used = (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        let v = total > 0 ? max(0, min(1, used / total)) : 0
        push(&ramHistory, v)
        lastRAM = v; lastRAMAt = Date()
        return v
    }

    private func push(_ arr: inout [Double], _ v: Double, keep: Int = 24) {
        arr.append(v)
        if arr.count > keep { arr.removeFirst(arr.count - keep) }
    }
}
