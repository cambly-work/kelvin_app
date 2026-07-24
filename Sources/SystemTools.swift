import AppKit
import IOKit.pwr_mgt
import CoreWLAN

// Быстрые системные переключатели для мультитула.

/// Caffeine — не давать системе засыпать (IOKit power assertion).
/// Бессрочно (пока Kelvin запущен) или на срок: для срока ставим OS-таймаут
/// (kIOPMAssertionTimeoutKey) как страховку — даже если Kelvin рухнет, ассерция
/// сама снимется и Mac не останется навечно без сна.
enum Caffeine {
    private static var id: IOPMAssertionID = 0
    private(set) static var active = false
    /// Момент авто-выключения (для срочного режима). nil = бессрочно.
    private(set) static var deadline: Date?

    static func toggle() { active ? stop() : start() }

    /// Включить бессрочно (пока Kelvin запущен).
    static func start() { start(seconds: 0) }

    /// Включить на `seconds` секунд (0 = бессрочно). Заменяет любую активную ассерцию.
    static func start(seconds: TimeInterval) {
        stop()
        var a: IOPMAssertionID = 0
        var props: [String: Any] = [
            kIOPMAssertionTypeKey as String: kIOPMAssertionTypePreventUserIdleSystemSleep as String,
            kIOPMAssertionLevelKey as String: Int(kIOPMAssertionLevelOn),
            kIOPMAssertionNameKey as String: "Kelvin Caffeine",
        ]
        if seconds > 0 {
            // OS снимет ассерцию по истечении срока, даже если наш таймер/приложение умерли.
            props[kIOPMAssertionTimeoutKey as String] = seconds
            props[kIOPMAssertionTimeoutActionKey as String] = kIOPMAssertionTimeoutActionRelease as String
        }
        let r = IOPMAssertionCreateWithProperties(props as CFDictionary, &a)
        if r == kIOReturnSuccess {
            id = a; active = true
            deadline = seconds > 0 ? Date().addingTimeInterval(seconds) : nil
        }
    }

    static func stop() {
        if active { IOPMAssertionRelease(id); active = false }
        deadline = nil
    }

    /// Срок истёк? (для UI-тика, чтобы синхронизировать `active` с OS-таймаутом).
    static func expireIfDue() {
        if let d = deadline, Date() >= d { stop() }
    }

    /// Осталось секунд (nil = бессрочно или выключено).
    static var remaining: TimeInterval? {
        guard active, let d = deadline else { return nil }
        return max(0, d.timeIntervalSinceNow)
    }
}

/// Таймер сна: «уснуть через N минут» (in-app таймер → `pmset sleepnow`) и
/// «погасить экран сейчас» (`pmset displaysleepnow`). Без root.
/// Честно: срабатывает, только пока Kelvin запущен.
enum SleepTimer {
    private static var timer: Timer?
    private(set) static var fireDate: Date?

    static var isArmed: Bool { fireDate != nil }

    /// Уснуть через `minutes` минут. Перезаписывает активный таймер.
    static func arm(minutes: Int) {
        cancel()
        let m = max(1, minutes)
        let d = Date().addingTimeInterval(TimeInterval(m) * 60)
        fireDate = d
        let t = Timer(fire: d, interval: 0, repeats: false) { _ in
            fireDate = nil; timer = nil
            sleepNow()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static func cancel() {
        timer?.invalidate(); timer = nil; fireDate = nil
    }

    /// Осталось секунд до сна (nil = таймер не взведён).
    static var remaining: TimeInterval? {
        guard let d = fireDate else { return nil }
        return max(0, d.timeIntervalSinceNow)
    }

    /// Уснуть прямо сейчас (без root).
    static func sleepNow() { run("/usr/bin/pmset", ["sleepnow"]) }

    /// Погасить экран прямо сейчас (без root).
    static func displaySleepNow() { run("/usr/bin/pmset", ["displaysleepnow"]) }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

/// Night Shift (CoreBrightness, приватный, но стабильный).
@objc private protocol BlueLightProto {
    func setEnabled(_ e: Bool) -> Bool
    func setStrength(_ s: Float, commit: Bool) -> Bool
    func setMode(_ m: Int32) -> Bool
    func getBlueLightStatus(_ status: UnsafeMutableRawPointer) -> Bool
}
enum NightShift {
    private static let client: NSObject? = {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        guard let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        let o = cls.init()
        return o.responds(to: NSSelectorFromString("setEnabled:")) ? o : nil
    }()
    static var available: Bool { client != nil }
    private static var enabled = false
    private static var proto: BlueLightProto? { client.map { unsafeBitCast($0, to: BlueLightProto.self) } }

    static func toggle() { isOn ? disable() : enableNow() }   // от РЕАЛЬНОГО состояния, не от кэша — иначе тап под расписанием «ничего не делал»

    /// Включить сейчас с заданной теплотой (0…1). Идемпотентно — годится для «удержания».
    static func enableNow(strength: Float = SettingsStore.nightStrength) {
        guard let c = client, let p = proto else { return }
        if c.responds(to: NSSelectorFromString("setMode:")) { _ = p.setMode(0) }   // ручной режим
        _ = p.setStrength(max(0, min(1, strength)), commit: true)
        _ = p.setEnabled(true)
        enabled = true
    }
    static func disable() {
        guard let p = proto else { return }
        _ = p.setEnabled(false)
        enabled = false
    }
    /// Сменить теплоту, не меняя вкл/выкл.
    static func setStrength(_ s: Float) {
        guard let p = proto else { return }
        _ = p.setStrength(max(0, min(1, s)), commit: true)
    }
    /// РЕАЛЬНОЕ состояние из системы (не кэш последней нашей команды): иначе при включённом
    /// расписании Night Shift (закат→рассвет) или переключении через Пункт управления тумблер врал.
    /// Приватная CBBlueLightStatus начинается с двух BOOL: active@0, enabled@1 — читаем enabled как
    /// байт по смещению 1. Буфер С БОЛЬШИМ ЗАПАСОМ (256 Б): точный размер структуры недокументирован
    /// и БОЛЬШЕ наивного зеркала — недобор приводил к записи за границу → __stack_chk_fail (краш loadView).
    static var isOn: Bool {
        guard let c = client, let p = proto,
              c.responds(to: NSSelectorFromString("getBlueLightStatus:")) else { return enabled }
        var buf = [UInt8](repeating: 0, count: 256)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return p.getBlueLightStatus(base)
        }
        return ok ? (buf[1] != 0) : enabled
    }
}

/// Тёмная/светлая тема (через System Events; запросит автоматизацию).
enum DarkModeToggle {
    static func toggle() {
        let s = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
        NSAppleScript(source: s)?.executeAndReturnError(nil)
    }
}

/// Wi-Fi (CoreWLAN).
enum WiFiToggle {
    static var available: Bool { CWWiFiClient.shared().interface() != nil }
    static var isOn: Bool { CWWiFiClient.shared().interface()?.powerOn() ?? false }
    static func toggle() {
        guard let i = CWWiFiClient.shared().interface() else { return }
        try? i.setPower(!i.powerOn())
    }
}

/// Bluetooth (приватные функции IOBluetooth).
enum BluetoothToggle {
    private typealias GetFn = @convention(c) () -> Int32
    private typealias SetFn = @convention(c) (Int32) -> Void
    private static let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW)
    static var available: Bool { handle != nil && dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState") != nil }
    static var isOn: Bool {
        // снапшот-рендер: НЕ дёргаем IOBluetooth — TCC-промпт заблокировал бы офскрин-рендер (стаб-состояние)
        if ProcessInfo.processInfo.environment["BM_SNAP"] != nil { return true }
        guard let h = handle, let s = dlsym(h, "IOBluetoothPreferenceGetControllerPowerState") else { return false }
        return unsafeBitCast(s, to: GetFn.self)() != 0
    }
    static func toggle() {
        guard let h = handle, let s = dlsym(h, "IOBluetoothPreferenceSetControllerPowerState") else { return }
        unsafeBitCast(s, to: SetFn.self)(isOn ? 0 : 1)
    }
}

/// История буфера обмена (последние строки).
final class ClipboardHistory {
    static let shared = ClipboardHistory()
    private(set) var items: [String] = []
    private var lastChange = NSPasteboard.general.changeCount

    /// Типы, которыми менеджеры паролей (1Password и пр.) помечают секреты — такое не сохраняем.
    private static let secretTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
    ]

    func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        // не захватываем пароли: пропускаем concealed/transient/auto-generated
        if let types = pb.types, types.contains(where: { Self.secretTypes.contains($0.rawValue) }) { return }
        guard let s = pb.string(forType: .string), !s.isEmpty else { return }
        items.removeAll { $0 == s }
        items.insert(s, at: 0)
        if items.count > 20 { items.removeLast() }
    }
    func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents(); pb.setString(s, forType: .string)
        lastChange = pb.changeCount        // не перезахватывать только что вставленное
    }
}

/// Время бездействия (сек) — для авто-гашения подсветки.
enum IdleTime {
    static func seconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
