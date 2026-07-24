import Foundation

/// Аптайм системы (время с момента загрузки). Root-free через sysctl kern.boottime — тривиально и
/// дёшево, поэтому НЕ кэшируем (читаем лениво раз в тик при открытом поповере).
enum SystemUptime {
    /// Секунды с момента загрузки (Date() − boottime). nil при сбое sysctl — не выдумываем значение.
    static func seconds() -> Double? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0, tv.tv_sec != 0 else { return nil }
        let boot = Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
        return max(0, Date().timeIntervalSince(boot))
    }
}
