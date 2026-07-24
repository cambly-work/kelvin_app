import CoreAudio
import CoreMediaIO

/// Live-детект «камера/микрофон используются» — БЕЗ полного доступа к диску, через публичные
/// CoreAudio / CoreMediaIO (kAudioDevicePropertyDeviceIsRunningSomewhere / kCMIODevicePropertyDeviceIsRunningSomewhere).
///
/// ЧЕСТНОСТЬ (закон продукта): мы видим, что УСТРОЙСТВО активно (какой-то процесс его открыл), но НЕ какое
/// именно приложение — публичного API имени тут нет, поэтому имя НЕ выдумываем. Ноль сети, ноль телеметрии.
enum MediaSensors {
    struct State { let camera: Bool; let mic: Bool; var any: Bool { camera || mic } }

    static func read() -> State { State(camera: cameraRunning(), mic: micRunning()) }

    /// Асинхронно (перечисление устройств — на фон, не блокируем main), результат — на main.
    static func read(completion: @escaping (State) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let s = read()
            DispatchQueue.main.async { completion(s) }
        }
    }

    /// Активен ли хоть один аудио-ВХОД (микрофон).
    ///
    /// ЧЕСТНОСТЬ: `...DeviceIsRunningSomewhere` — свойство ВСЕГО устройства, оно не различает вход и выход
    /// (проверено live: input-scope возвращает то же, что global). На дуплексном/агрегатном устройстве
    /// (USB-гарнитура, аудиоинтерфейс, агрегат) воспроизведение БЕЗ записи включает всё устройство и дало бы
    /// ложный «микрофон используется». Поэтому на macOS 14+ спрашиваем per-process «пишет ли кто-то вход»
    /// (точно), а на старых ОС — только про input-ONLY устройства, чтобы не кричать во время playback.
    static func micRunning() -> Bool {
        if #available(macOS 14.0, *) {
            if let byProc = micRunningByProcess() { return byProc }   // nil → не смогли спросить, падаем на устройственный путь
        }
        return micRunningByDevice()
    }

    /// macOS 14+: точный путь. true, если хоть один процесс реально держит аудио-вход открытым.
    @available(macOS 14.0, *)
    private static func micRunningByProcess() -> Bool? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz) == noErr, sz > 0 else { return nil }
        let n = Int(sz) / MemoryLayout<AudioObjectID>.size
        var procs = [AudioObjectID](repeating: 0, count: n)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &procs) == noErr else { return nil }
        for p in procs {
            var ra = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var run: UInt32 = 0; var rs = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(p, &ra, 0, nil, &rs, &run) == noErr, run != 0 { return true }
        }
        return false
    }

    /// legacy (< macOS 14): устройственный путь. Считаем микрофон активным ТОЛЬКО для устройств с входными
    /// каналами и БЕЗ выходных — иначе дуплекс/агрегат даст ложный «микрофон используется» во время playback.
    private static func micRunningByDevice() -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz) == noErr, sz > 0 else { return false }
        let n = Int(sz) / MemoryLayout<AudioDeviceID>.size
        var devs = [AudioDeviceID](repeating: 0, count: n)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &devs) == noErr else { return false }
        for d in devs {
            guard channelCount(d, scope: kAudioObjectPropertyScopeInput) > 0,
                  channelCount(d, scope: kAudioObjectPropertyScopeOutput) == 0 else { continue }   // только чистый вход
            var ra = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var run: UInt32 = 0; var rs = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(d, &ra, 0, nil, &rs, &run) == noErr, run != 0 { return true }
        }
        return false
    }

    /// Число каналов устройства в указанном scope (вход/выход). 0, если нет или не удалось прочитать.
    private static func channelCount(_ dev: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var ia = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                            mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var cs: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &ia, 0, nil, &cs) == noErr, cs > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(cs), alignment: 16); defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &ia, 0, nil, &cs, raw) == noErr else { return 0 }
        let bufs = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return bufs.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Активна ли хоть одна камера (CoreMediaIO video-устройства).
    static func cameraRunning() -> Bool {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var sz: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &sz) == noErr, sz > 0 else { return false }
        let n = Int(sz) / MemoryLayout<CMIOObjectID>.size
        var devs = [CMIOObjectID](repeating: 0, count: n)
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, sz, &sz, &devs) == noErr else { return false }
        for d in devs {
            var ra = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                               mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                               mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var run: UInt32 = 0; var rs = UInt32(MemoryLayout<UInt32>.size)
            if CMIOObjectGetPropertyData(d, &ra, 0, nil, rs, &rs, &run) == noErr, run != 0 { return true }
        }
        return false
    }
}
