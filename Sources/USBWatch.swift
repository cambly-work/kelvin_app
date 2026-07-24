import Foundation
import IOKit
import IOKit.usb

/// Живой ридер подключения/отключения USB-периферии (IOKit matching-нотификации).
/// ЧЕСТНОСТЬ: модель структурно НЕ несёт ватт/тока — Apple Silicon не отдаёт live
/// per-USB-device мощность, поэтому фейк невозможен. Только факт подключения + имя/счётчик.
/// Номинал адаптера остаётся честно в AdapterInfo (E2) — USB-устройства ватт не получают.

/// Одно USB-устройство: registry-id + locationID (физический порт; ключ дедупа legacy/modern-пары) + имя.
/// БЕЗ amps/watts/power — намеренно.
struct USBPeripheral { let id: UInt64; let locationID: UInt32; let name: String }

/// Событие шины: подключение/отключение (с именем) либо стартовый засев (счётчик, без пульса).
enum USBEvent { case connected(String); case disconnected(String); case initialSync(Int) }

/// Зеркалит стиль BTPeripherals: синхронный кэш `devices` + lifetime-инстанс.
/// IOKit lifecycle: ОДИН IONotificationPortRef на жизнь приложения, источник в main run loop.
final class USBWatch {

    private(set) var devices: [USBPeripheral] = []     // мутируется только на main
    var count: Int { devices.count }
    var onChange: ((USBEvent) -> Void)?                // всегда вызывается на main

    private var port: IONotificationPortRef?
    private var runLoopSource: CFRunLoopSource?
    private var iterators: [io_iterator_t] = []        // для teardown (matched + terminated × классы)
    private var armed = false                          // false до конца стартового дренажа → засев без пульсов
    private var started = false

    // дебаунс-коалесценция: док/хаб даёт шквал 5-15 событий <100мс → один onChange/один пульс
    private var pendingConnects: [String] = []
    private var pendingDisconnects: [String] = []
    private var debounceTimer: Timer?

    func start() {
        guard !started else { return }
        started = true
        // ОДИН порт на жизнь приложения; источник в main run loop в .commonModes —
        // без .commonModes события встанут, пока поповер (tracking-контекст) открыт, ровно когда они виднее.
        guard let p = IONotificationPortCreate(kIOMainPortDefault) else { return }
        port = p
        let src = IONotificationPortGetRunLoopSource(p).takeUnretainedValue()
        runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)

        // self как контекст для C-колбэка (Unmanaged, без retain — инстанс живёт всё приложение)
        let ctx = Unmanaged.passUnretained(self).toOpaque()

        // Два класса ради портативности: IOUSBHostDevice (Apple Silicon) + IOUSBDevice (legacy/Intel).
        // Класс, которого нет на этой машине, просто никогда не стрельнёт.
        for cls in ["IOUSBHostDevice", "IOUSBDevice"] {
            // matched (подключение)
            addNotification(class: cls, type: kIOMatchedNotification, ctx: ctx) { watch, it in
                watch.handleMatched(it)
            }
            // terminated (отключение) — detach нельзя вывести из matched-потока, нужна своя нотификация
            addNotification(class: cls, type: kIOTerminatedNotification, ctx: ctx) { watch, it in
                watch.handleTerminated(it)
            }
        }
        armed = true
        // стартовый засев завершён (matched-дренаж ниже шёл при armed=false) → сурфейс без пульса
        onChange?(.initialSync(count))
    }

    func stop() {
        debounceTimer?.invalidate(); debounceTimer = nil
        for it in iterators where it != 0 { IOObjectRelease(it) }
        iterators.removeAll()
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        if let p = port { IONotificationPortDestroy(p); port = nil }
        started = false
    }

    // MARK: регистрация одной нотификации (+ ПЕРВЫЙ дренаж итератора вооружает её)
    private func addNotification(class cls: String, type: String, ctx: UnsafeMutableRawPointer,
                                 handler: @escaping (USBWatch, io_iterator_t) -> Void) {
        guard let p = port, let matching = IOServiceMatching(cls) else { return }
        // храним замыкание-«мост» в боксе, чтобы C-колбэк нашёл нужный обработчик
        let box = CallbackBox(watch: self, handler: handler)
        let boxPtr = Unmanaged.passRetained(box).toOpaque()
        boxes.append(box)
        var it: io_iterator_t = 0
        let kr = IOServiceAddMatchingNotification(p, type, matching,
            { (refcon, iterator) in
                guard let refcon else { return }
                let b = Unmanaged<CallbackBox>.fromOpaque(refcon).takeUnretainedValue()
                b.handler(b.watch, iterator)
            }, boxPtr, &it)
        guard kr == KERN_SUCCESS else {
            // деградируем мягко (будущий sandbox/отказ) — без падения, скрытый сурфейс
            _ = Unmanaged<CallbackBox>.fromOpaque(boxPtr).takeRetainedValue()
            return
        }
        iterators.append(it)
        // ПЕРВЫЙ дренаж ОБЯЗАТЕЛЕН: (а) вооружает нотификацию на будущие события, (б) для matched
        // засевает уже-подключённые устройства. armed=false на этом проходе → без тиков/onChange-пульсов.
        handler(self, it)
    }

    // боксы держим живыми весь lifetime (passRetained без баланса — намеренно, инстанс вечен)
    private final class CallbackBox {
        let watch: USBWatch
        let handler: (USBWatch, io_iterator_t) -> Void
        init(watch: USBWatch, handler: @escaping (USBWatch, io_iterator_t) -> Void) {
            self.watch = watch; self.handler = handler
        }
    }
    private var boxes: [CallbackBox] = []

    // MARK: дренаж итераторов (приём DiskInfo.swift: пройти до конца, релизить каждый io_object)
    // ЧЕСТНЫЙ СЧЁТ (владелец: «9 устройств при одном воткнутом»): (1) на современных macOS ОБА класса
    // IOUSBHostDevice + legacy AppleUSBDevice живут одновременно → одно железо = два объекта с разными
    // registry-id — дедуп по locationID (физический порт совпадает у пары); (2) встроенные (клавиатура/
    // трекпад/BT-контроллер/хабы: non-removable=yes / Built-In) — НЕ периферия, скипаем.
    private func handleMatched(_ it: io_iterator_t) {
        var svc = IOIteratorNext(it)
        while svc != 0 {
            defer { IOObjectRelease(svc); svc = IOIteratorNext(it) }   // ДРЕНАЖ обязателен (вооружение + no-leak)
            let info = deviceInfo(svc)
            if info.builtIn { continue }                                // встроенное — не считаем
            // дедуп: по locationID (ловит legacy/modern-пару), fallback на registry-id при loc==0
            if info.locationID != 0, devices.contains(where: { $0.locationID == info.locationID }) { continue }
            if devices.contains(where: { $0.id == info.id }) { continue }
            devices.append(USBPeripheral(id: info.id, locationID: info.locationID, name: info.name))
            if armed { pendingConnects.append(info.name); scheduleFlush() }  // стартовый засев (armed=false) — без пульса
        }
    }

    private func handleTerminated(_ it: io_iterator_t) {
        var svc = IOIteratorNext(it)
        while svc != 0 {
            defer { IOObjectRelease(svc); svc = IOIteratorNext(it) }
            let info = deviceInfo(svc)
            let existing = devices.first { $0.id == info.id || (info.locationID != 0 && $0.locationID == info.locationID) }
            guard let dev = existing else { continue }   // фильтрованное/дедупнутое — нечего удалять, БЕЗ фантомного пульса
            devices.removeAll { $0.id == dev.id }
            if armed { pendingDisconnects.append(dev.name); scheduleFlush() }
        }
    }

    // MARK: коалесценция (trailing-таймер ~120мс на main) — шквал схлопывается в ОДИН onChange/пульс
    private func scheduleFlush() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            self?.flush()
        }
    }

    private func flush() {
        let connects = pendingConnects, disconnects = pendingDisconnects
        pendingConnects.removeAll(); pendingDisconnects.removeAll()
        // одно событие на доминирующее направление (нетто прихода/ухода в окне)
        if connects.count >= disconnects.count, let name = connects.last {
            onChange?(.connected(name))
        } else if let name = disconnects.last {
            onChange?(.disconnected(name))
        } else if let name = connects.last {
            onChange?(.connected(name))
        }
    }

    // MARK: чтение свойств (крошечные property-reads, путь DiskInfo.swift:26)
    private func registryID(_ svc: io_service_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(svc, &id)
        return id
    }

    /// Один проход по свойствам: имя + locationID + признак «встроенное».
    /// non-removable — строка "yes"/"no" ИЛИ Bool (формат гуляет по версиям macOS — принимаем оба);
    /// Built-In — Bool/NSNumber. Root-hub-симуляции тоже отсекаются (non-removable=yes).
    private func deviceInfo(_ svc: io_service_t) -> (id: UInt64, locationID: UInt32, name: String, builtIn: Bool) {
        let id = registryID(svc)
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(svc, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return (id, 0, L("USB-устройство"), false)
        }
        var name = L("USB-устройство")
        for key in ["kUSBProductString", "USB Product Name", "kUSBVendorString", "USB Vendor Name"] {
            if let s = props[key] as? String, !s.isEmpty { name = s; break }
        }
        let loc = (props["locationID"] as? NSNumber)?.uint32Value ?? 0
        var builtIn = false
        if let s = props["non-removable"] as? String, s.lowercased() == "yes" { builtIn = true }
        if let b = props["non-removable"] as? Bool, b { builtIn = true }
        if let b = props["Built-In"] as? Bool, b { builtIn = true }
        if let n = props["Built-In"] as? NSNumber, n.boolValue { builtIn = true }
        return (id, loc, name, builtIn)
    }
}
