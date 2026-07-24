import AppKit

/// Заряд Bluetooth-периферии Apple (AirPods L/R/кейс, Magic Mouse/Keyboard/Trackpad).
/// Бесплатно, только чтение. Источник — `system_profiler SPBluetoothDataType` (ключи
/// device_batteryLevel*), батарея отдаётся ТОЛЬКО для подключённых Apple-устройств.
struct BTPeripheral {
    let name: String
    let kind: String          // device_minorType: Headphones/Mouse/Keyboard/Trackpad/…
    let address: String
    let main: Int?            // одно-батарейные (Magic Mouse/Keyboard/Trackpad)
    let left: Int?           // AirPods: левый/правый/кейс
    let right: Int?
    let caseLvl: Int?

    /// Худший (минимальный) из присутствующих уровней — для токена строки меню.
    var worst: Int? { [main, left, right, caseLvl].compactMap { $0 }.min() }

    /// SF Symbol по типу устройства.
    var icon: String {
        switch kind {
        case "Headphones", "Headset": return "airpods"
        case "Mouse":                 return "magicmouse"
        case "Keyboard":              return "keyboard"
        case "Trackpad":              return "rectangle.and.hand.point.up.left"
        default:                      return "dot.radiowaves.left.and.right"
        }
    }
}

/// Кэширующий слой над тяжёлым (~150–400 мс) подпроцессом system_profiler.
/// Кэш живёт ~30 с; обновление идёт ВНЕ главного потока и публикуется на main.
/// UI/токен читают кэш синхронно (мгновенно) и лишь подкидывают refreshIfStale.
enum BTPeripherals {
    private static let cacheTTL: TimeInterval = 30
    private static var cache: (val: [BTPeripheral], at: Date)?
    private static var refreshing = false

    /// Мгновенно: последний кэш (на первом вызове пуст).
    static func cached() -> [BTPeripheral] { cache?.val ?? [] }
    /// Минимальный заряд среди всех устройств — для токена строки меню.
    static func cachedWorst() -> Int? { cached().compactMap { $0.worst }.min() }

    /// Неблокирующе: если кэш протух, обновляет вне main и зовёт onDone на main по готовности.
    static func refreshIfStale(onDone: (() -> Void)? = nil) {
        if let c = cache, Date().timeIntervalSince(c.at) < cacheTTL { return }
        if refreshing { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async {
            let v = parse()
            DispatchQueue.main.async {
                cache = (v, Date()); refreshing = false; onDone?()
            }
        }
    }

    private static func parse() -> [BTPeripheral] {
        let out = shell("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json", "-detailLevel", "mini"])
        guard let data = out.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = root["SPBluetoothDataType"] as? [[String: Any]],
              let top = arr.first else { return [] }
        // device_connected: массив одно-ключевых словарей [имяУстройства: словарьСвойств]
        let connected = (top["device_connected"] as? [[String: Any]]) ?? []
        var result: [BTPeripheral] = []
        for entry in connected {
            guard let (name, raw) = entry.first, let p = raw as? [String: Any] else { continue }
            func pct(_ k: String) -> Int? {
                guard let s = p[k] as? String else { return nil }
                let digits = s.filter { $0.isNumber }
                return Int(digits)
            }
            let main = pct("device_batteryLevelMain")
            let l = pct("device_batteryLevelLeft")
            let r = pct("device_batteryLevelRight")
            let c = pct("device_batteryLevelCase")
            // отбрасываем устройства без единого ключа батареи (колонки, iPhone, JBL…)
            if main == nil && l == nil && r == nil && c == nil { continue }
            result.append(BTPeripheral(
                name: name,
                kind: (p["device_minorType"] as? String) ?? "",
                address: (p["device_address"] as? String) ?? "",
                main: main, left: l, right: r, caseLvl: c))
        }
        return result
    }

    // идентично GPUInfo.swift / Connections.swift shell()
    private static func shell(_ path: String, _ args: [String]) -> String {
        ProcessRunner.output(path, args, timeout: 8)
    }
}
