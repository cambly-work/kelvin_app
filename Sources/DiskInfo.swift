import Foundation
import IOKit

/// Скорость диска R/W (байт/с) — ПОЛНОСТЬЮ ЛОКАЛЬНО, без root. Дельты кумулятивных счётчиков
/// IOKit `IOBlockStorageDriver`→`Statistics` за тик (тот же приём, что NetUsage с if_data).
/// Заметка: IOKit-константы `kIOBlockStorageDriverStatistics*Key` — это C #define string-макросы,
/// которые НЕ импортируются в Swift, поэтому используем строковые литералы напрямую.
final class DiskUsage {
    static let shared = DiskUsage()

    private var prev: (r: UInt64, w: UInt64, t: Date)?
    private(set) var read: Double = 0    // байт/с
    private(set) var write: Double = 0

    /// Сумма кумулятивных байт по всем блочным драйверам (64-бит — переполнение нереально).
    private func counters() -> (r: UInt64, w: UInt64) {
        var r: UInt64 = 0, w: UInt64 = 0
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(it) }
        var svc = IOIteratorNext(it)
        while svc != 0 {
            defer { IOObjectRelease(svc); svc = IOIteratorNext(it) }   // релизим каждый io_object + двигаем итератор
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(svc, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = unmanaged?.takeRetainedValue() as? [String: Any],
                  let stats = props["Statistics"] as? [String: Any] else { continue }
            r &+= (stats["Bytes (Read)"]  as? NSNumber)?.uint64Value ?? 0
            w &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (r, w)
    }

    /// Пересчитать скорость по дельте с прошлого вызова (зовётся из tick(), как NetUsage).
    @discardableResult
    func sample(now: Date = Date()) -> (read: Double, write: Double) {
        let c = counters()
        defer { prev = (c.r, c.w, now) }
        guard let p = prev else { return (0, 0) }
        let dt = now.timeIntervalSince(p.t)
        guard dt > 0.05 else { return (read, write) }                  // дребезг/двойной вызов за тик → кэш
        read  = c.r >= p.r ? Double(c.r - p.r) / dt : 0                // eject/hot-plug → обнуляем дельту
        write = c.w >= p.w ? Double(c.w - p.w) / dt : 0
        return (read, write)
    }
}

/// Ёмкость загрузочного тома — мгновенно, без root и без скана (URLResourceValues).
enum DiskInfo {
    /// (total, free, purgeable) в байтах.
    /// ЧЕСТНОСТЬ: `free` = .forImportantUsage — число как в Finder, но оно ОПТИМИСТИЧНО: включает purgeable
    /// (кэш, локальные снимки Time Machine, «оптимизированные» файлы), которые система освободит ТОЛЬКО когда
    /// реально прижмёт. `purgeable` ≈ Finder-«свободно» минус истинно свободное сейчас — раскрываем эту разницу,
    /// чтобы «свободно» не выглядело больше, чем есть на самом деле прямо сейчас.
    static func capacity() -> (total: Int64, free: Int64, purgeable: Int64)? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        // ForImportantUsage ОБЯЗАТЕЛЕН: если ключ отсутствует — это «неизвестно», НЕ 0 (иначе ложное «0 ГБ свободно»).
        guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                         .volumeAvailableCapacityKey,
                                                         .volumeAvailableCapacityForImportantUsageKey]),
              let total = v.volumeTotalCapacity,
              let important = v.volumeAvailableCapacityForImportantUsage else { return nil }
        // без истинно-свободного (rawFree) purgeable не выдумываем — иначе всё «свободное» ошибочно станет очищаемым.
        let rawFree = v.volumeAvailableCapacity.map(Int64.init)         // истинно свободно ПРЯМО СЕЙЧАС (nil = недоступно)
        let purgeable = rawFree.map { max(0, Int64(important) - $0) } ?? 0
        return (Int64(total), Int64(important), purgeable)
    }
}
