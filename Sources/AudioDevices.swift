import CoreAudio
import Foundation

/// Переключение системного устройства ВЫВОДА по умолчанию — публичный CoreAudio, без root и без entitlement
/// (проверено live: AudioObjectSetPropertyData вернул noErr на этой машине).
///
/// ЧЕСТНОСТЬ (закон продукта): мы меняем устройство вывода ПО УМОЛЧАНИЮ, а НЕ «маршрутизируем весь звук».
/// Приложение, которое ЯВНО выбрало своё устройство вывода, это переключение не трогает. Ноль сети.
enum AudioDevices {
    struct Device: Equatable { let id: AudioDeviceID; let name: String; let isCurrent: Bool }

    /// Список устройств ВЫВОДА (с выходными каналами) + отметка текущего дефолта. Перечисление — на фон.
    static func outputs(completion: @escaping ([Device]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let d = outputs()
            DispatchQueue.main.async { completion(d) }
        }
    }

    static func outputs() -> [Device] {
        let cur = currentDefaultOutput()
        let list = allDeviceIDs().compactMap { id -> Device? in
            guard channelCount(id, scope: kAudioObjectPropertyScopeOutput) > 0 else { return nil }   // только с выходом
            return Device(id: id, name: name(id) ?? "—", isCurrent: id == cur)
        }
        // ЧЕСТНОСТЬ: держим текущий дефолт ПЕРВЫМ (в видимом слоте с галкой), остальные — в исходном
        // порядке. Иначе при >6 устройствах активное могло уехать в overflow «+N ещё» без отметки.
        // Стабильно (filter, не sort) — чтобы не мигало при обновлении каждую секунду.
        return list.filter { $0.isCurrent } + list.filter { !$0.isCurrent }
    }

    /// Установить устройство ВЫВОДА по умолчанию. true при успехе (иначе честно false — не притворяемся).
    @discardableResult
    static func setDefaultOutput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &dev) == noErr
    }

    // MARK: - private
    private static func currentDefaultOutput() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev: AudioDeviceID = 0; var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &dev) == noErr else { return 0 }
        return dev
    }
    private static func allDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz) == noErr, sz > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(sz) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &ids) == noErr else { return [] }
        return ids
    }
    private static func name(_ id: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?; var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &cf) == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }
    private static func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &sz) == noErr, sz > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: 16); defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, raw) == noErr else { return 0 }
        let bufs = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return bufs.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
