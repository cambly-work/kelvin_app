import Foundation
import Darwin

/// Скорость сети ↓/↑ (байт/с) и локальный IPv4 — ПОЛНОСТЬЮ ЛОКАЛЬНО (getifaddrs / if_data),
/// без root и без единого запроса наружу. Закрывает мониторинговый гэп против iStat/Stats,
/// не нарушая позиционирование «локально, без телеметрии». Публичный IP сознательно НЕ тянем.
final class NetUsage {
    static let shared = NetUsage()

    private var prev: (rx: UInt64, tx: UInt64, t: Date)?
    private(set) var down: Double = 0   // байт/с
    private(set) var up: Double = 0

    /// Суммарные счётчики байт по физическим интерфейсам (en* Wi-Fi/Ethernet, pdp_ip* сотовая).
    private func counters() -> (rx: UInt64, tx: UInt64) {
        var rx: UInt64 = 0, tx: UInt64 = 0
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return (0, 0) }
        defer { freeifaddrs(addrs) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            let name = String(cString: ifa.ifa_name)
            if let sa = ifa.ifa_addr, Int32(sa.pointee.sa_family) == AF_LINK,
               (name.hasPrefix("en") || name.hasPrefix("pdp_ip")), let raw = ifa.ifa_data {
                let d = raw.assumingMemoryBound(to: if_data.self).pointee
                rx &+= UInt64(d.ifi_ibytes); tx &+= UInt64(d.ifi_obytes)
            }
            ptr = ifa.ifa_next
        }
        return (rx, tx)
    }

    /// Пересчитать скорость по дельте с прошлого вызова (зовётся из tick()).
    @discardableResult
    func sample(now: Date = Date()) -> (down: Double, up: Double) {
        let c = counters()
        defer { prev = (c.rx, c.tx, now) }
        guard let p = prev else { return (0, 0) }
        let dt = now.timeIntervalSince(p.t)
        guard dt > 0.05 else { return (down, up) }                 // дребезг/двойной вызов за тик → кэш
        // счётчики ifi_*bytes 32-битные и переполняются — на wrap/reset просто обнуляем дельту
        down = c.rx >= p.rx ? Double(c.rx - p.rx) / dt : 0
        up   = c.tx >= p.tx ? Double(c.tx - p.tx) / dt : 0
        return (down, up)
    }

    /// Локальный IPv4 первого активного en*-интерфейса (без сети наружу).
    func localIP() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            let name = String(cString: ifa.ifa_name)
            if let sa = ifa.ifa_addr, Int32(sa.pointee.sa_family) == AF_INET, name.hasPrefix("en") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: host)
                }
            }
            ptr = ifa.ifa_next
        }
        return nil
    }

    /// Компактный формат скорости: 1.2M / 850K / 0 (значение в байт/с → байт-за-секунду).
    static func fmtRate(_ bps: Double) -> String {
        if bps >= 1_000_000 { return String(format: "%.1fM", bps / 1_000_000) }
        if bps >= 1_000 { return String(format: "%.0fK", bps / 1_000) }
        return String(format: "%.0f", bps)
    }
}