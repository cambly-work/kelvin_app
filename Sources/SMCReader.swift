import Foundation
import IOKit

// Чтение Apple SMC напрямую (без sudo). Структура повторяет SMCKeyData_t (80 байт).

private struct SMCVers { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0; var reserved: UInt8 = 0; var release: UInt16 = 0 }
private struct SMCPLimit { var version: UInt16 = 0; var length: UInt16 = 0; var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
private struct SMCKeyInfo { var dataSize: UInt32 = 0; var dataType: UInt32 = 0; var dataAttributes: UInt8 = 0
    var _p0: UInt8 = 0; var _p1: UInt8 = 0; var _p2: UInt8 = 0 }   // паддинг до 12 байт (иначе Swift ужмёт до 76)
private typealias SMCBytes = (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                              UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                              UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                              UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8)
private struct SMCParam {
    var key: UInt32 = 0
    var vers = SMCVers()
    var pLimit = SMCPLimit()
    var keyInfo = SMCKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)
}

final class SMC {
    private let lock = NSRecursiveLock()
    private var conn: io_connect_t = 0
    private var ok = false

    // keyInfo (размер/тип) ключа статичен на машине — кэшируем, чтобы не делать лишний
    // READ_KEYINFO-syscall на каждом чтении (это половина всех SMC-вызовов в горячем tick).
    private var infoCache: [UInt32: (size: UInt32, type: String, rawType: UInt32)] = [:]
    // короткоживущий кэш значений: дедупит ключи, читаемые дважды за тик (Energy+Sensors: TC0P/TG0P/F0Ac…).
    private var valueCache: [UInt32: (deadline: UInt64, value: Double?)] = [:]
    private let valueTTLns: UInt64 = 200_000_000        // 200 мс — короче такта (1 с), но покрывает один кадр
    // Каталог всех ключей SMC этой машины статичен (железо не меняется в рантайме) — строим ОДИН раз
    // через перечисление по индексу и кэшируем. НЕ дёргать в горячем 1Гц-тике: ~200 syscall'ов.
    private var keyCatalog: [String]?

    init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        ok = IOServiceOpen(svc, mach_task_self_, 0, &conn) == kIOReturnSuccess
    }
    deinit { if conn != 0 { IOServiceClose(conn) } }
    var available: Bool { ok }

    private func fourCC(_ s: String) -> UInt32 {
        var r: UInt32 = 0; for c in s.utf8 { r = (r << 8) | UInt32(c) }; return r
    }
    private func typeStr(_ v: UInt32) -> String {
        let b = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return (String(bytes: b, encoding: .ascii) ?? "").trimmingCharacters(in: .whitespaces)
    }
    private func call(_ input: inout SMCParam) -> SMCParam? {
        guard ok else { return nil }
        var out = SMCParam()
        var outSize = MemoryLayout<SMCParam>.stride
        let kr = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCParam>.stride, &out, &outSize)
        return (kr == kIOReturnSuccess && out.result == 0) ? out : nil
    }

    /// keyInfo (размер/тип) ключа — из кэша, иначе один READ_KEYINFO-syscall и запоминаем (статичен).
    private func keyInfo(_ key: UInt32) -> (size: UInt32, type: String, rawType: UInt32)? {
        if let c = infoCache[key] { return c }
        var ki = SMCParam(); ki.key = key; ki.data8 = 9                   // READ_KEYINFO
        guard let info = call(&ki) else { return nil }
        let v = (info.keyInfo.dataSize, typeStr(info.keyInfo.dataType), info.keyInfo.dataType)
        infoCache[key] = v
        return v
    }

    /// Публичный тонкий shim над приватным keyInfo: тип/размер ключа (FourCC-строка → (size,type)).
    /// Каталогу сенсоров нужен тип КАЖДОГО ключа без доступа к приватному кэшу. infoCache гасит стоимость.
    func typeInfo(_ key: String) -> (size: Int, type: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let i = keyInfo(fourCC(key)) else { return nil }
        return (Int(i.size), i.type)
    }

    // MARK: — энумерация всех ключей SMC (механизм READ_INDEX)

    /// Число ключей: '#KEY' — обычный ui32-ключ, текущий read его осиливает.
    func keyCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return Int(read("#KEY") ?? 0)
    }

    /// FourCC ключа по индексу: data8=8 (READ_INDEX), data32=index. Прошивка кладёт FourCC ключа
    /// в поле `key` ответа (big-endian, как dataType) — переиспользуем typeStr-декодер. Если на машине
    /// прошивка вернёт FourCC в первых 4 байтах bytes (а key=0) — честный фолбэк на bytes[0..3].
    func keyByIndex(_ i: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        var p = SMCParam(); p.data8 = 8; p.data32 = UInt32(i)   // data32 ВПЕРВЫЕ пишется этим путём
        guard let o = call(&p) else { return nil }
        if o.key != 0 {
            let s = typeStr(o.key)
            if !s.isEmpty { return s }
        }
        // фолбэк: FourCC в первых 4 байтах bytes
        var t = o.bytes
        let b = withUnsafeBytes(of: &t) { Array($0.prefix(4)) }
        let s = (String(bytes: b, encoding: .ascii) ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    /// Полный каталог FourCC всех ключей машины. Строится ОДИН раз (перечисление по индексу),
    /// дальше — из кэша. Статичен на железо. НЕ звать в тике (только при первом построении каталога).
    func enumerateKeys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        if let c = keyCatalog { return c }
        let n = keyCount()
        var out: [String] = []; out.reserveCapacity(n)
        for i in 0..<n { if let k = keyByIndex(i) { out.append(k) } }
        keyCatalog = out
        return out
    }

    /// Читает ключ и декодирует значение по его SMC-типу. keyInfo кэшируется, значение — на 200 мс.
    func read(_ key: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        let k = fourCC(key)
        let now = DispatchTime.now().uptimeNanoseconds
        if let c = valueCache[k], c.deadline > now { return c.value }     // уже читали в этом кадре
        let v = readUncached(k)
        valueCache[k] = (now &+ valueTTLns, v)
        return v
    }
    private func readUncached(_ k: UInt32) -> Double? {
        guard let info = keyInfo(k) else { return nil }
        var rb = SMCParam(); rb.key = k; rb.keyInfo.dataSize = info.size; rb.data8 = 5  // READ_BYTES
        guard let o = call(&rb) else { return nil }
        var t = o.bytes
        let b = withUnsafeBytes(of: &t) { Array($0.prefix(Int(info.size))) }
        return decode(info.type, b)
    }

    /// Зонд: тип, размер и декодированное значение ключа (для отладки подбора ключей).
    func probe(_ key: String) -> (type: String, size: Int, value: Double?)? {
        lock.lock(); defer { lock.unlock() }
        var ki = SMCParam(); ki.key = fourCC(key); ki.data8 = 9
        guard let info = call(&ki) else { return nil }
        return (typeStr(info.keyInfo.dataType), Int(info.keyInfo.dataSize), read(key))
    }

    /// Запись значения в SMC (нужен root). Поддержка ui8 / ui16 / fpe2.
    @discardableResult
    func write(_ key: String, _ value: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let k = fourCC(key)
        valueCache[k] = nil                                              // запись инвалидирует кэш значения
        guard let info = keyInfo(k) else { return false }
        let size = info.size
        let type = info.type
        guard size >= 1, size <= 32 else { return false }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard value.isFinite else { return false }                        // NaN/Inf → Int() трапнул бы до клампы
        switch type {
        case "ui8":
            bytes[0] = UInt8(max(0, min(255, Int(value))))
        case "ui16":
            let raw = UInt16(max(0, min(65535, Int(value))))
            bytes[0] = UInt8(raw >> 8); bytes[1] = UInt8(raw & 0xff)
        case "fpe2":
            let raw = UInt16(max(0, min(65535, Int(value * 4))))          // fpe2: value = raw/4
            bytes[0] = UInt8(raw >> 8); bytes[1] = UInt8(raw & 0xff)
        default:
            return false
        }

        var wr = SMCParam()
        wr.key = k
        wr.keyInfo.dataSize = size
        wr.keyInfo.dataType = info.rawType
        wr.data8 = 6                                                       // WRITE_BYTES
        withUnsafeMutableBytes(of: &wr.bytes) { ptr in
            for i in 0..<Int(size) { ptr[i] = bytes[i] }
        }
        return call(&wr) != nil
    }

    private func decode(_ type: String, _ b: [UInt8]) -> Double? {
        switch type {
        case "flt":  guard b.count >= 4 else { return nil }
            let bits = UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
            let f = Float(bitPattern: bits)
            return f.isFinite ? Double(f) : nil          // битый сенсор → NaN/Inf, иначе «nan Вт» в UI
        case "ui8":  return b.count >= 1 ? Double(b[0]) : nil
        case "ui16": return b.count >= 2 ? Double((UInt16(b[0]) << 8) | UInt16(b[1])) : nil
        case "ui32": return b.count >= 4 ? Double((UInt32(b[0]) << 24)|(UInt32(b[1]) << 16)|(UInt32(b[2]) << 8)|UInt32(b[3])) : nil
        case "si8":  return b.count >= 1 ? Double(Int8(bitPattern: b[0])) : nil
        case "si16": return b.count >= 2 ? Double(Int16(bitPattern: (UInt16(b[0]) << 8)|UInt16(b[1]))) : nil
        default: break
        }
        // Обобщённый fixed-point: spXY (знаковый) / fpXY (беззнаковый), big-endian,
        // где вторая hex-цифра Y — число дробных бит. Покрывает sp78/sp87/sp96/sp5a/spa5/fpe2/fp2e…
        if (type.hasPrefix("sp") || type.hasPrefix("fp")), type.count == 4, b.count >= 2,
           let frac = Int(String(Array(type)[3]), radix: 16) {
            let raw = (UInt16(b[0]) << 8) | UInt16(b[1])
            let div = Double(1 << frac)
            return type.hasPrefix("sp") ? Double(Int16(bitPattern: raw)) / div : Double(raw) / div
        }
        return nil
    }
}
