import Foundation
import CoreGraphics

// Управление подсветкой клавиатуры (CoreBrightness) и яркостью экрана (DisplayServices).
// Приватные фреймворки, но стабильные; без root. Значения 0…1.

@objc private protocol KBClientProto {
    func brightnessForKeyboard(_ k: UInt64) -> Float
    func setBrightness(_ b: Float, forKeyboard k: UInt64)
}

enum KeyboardBacklight {
    private static let client: KBClientProto? = {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        guard let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let obj = cls.init()
        guard obj.responds(to: NSSelectorFromString("brightnessForKeyboard:")) else { return nil }
        return unsafeBitCast(obj, to: KBClientProto.self)
    }()
    static var available: Bool { client != nil }
    static func get() -> Float { client?.brightnessForKeyboard(1) ?? -1 }
    static func set(_ v: Float) { client?.setBrightness(max(0, min(1, v)), forKeyboard: 1) }
}

enum ScreenBrightness {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)

    static var available: Bool { handle != nil && dlsym(handle, "DisplayServicesGetBrightness") != nil }
    static func get() -> Float {
        guard let h = handle, let s = dlsym(h, "DisplayServicesGetBrightness") else { return -1 }
        var b: Float = 0
        _ = unsafeBitCast(s, to: GetFn.self)(CGMainDisplayID(), &b)
        return b
    }
    static func set(_ v: Float) {
        guard let h = handle, let s = dlsym(h, "DisplayServicesSetBrightness") else { return }
        _ = unsafeBitCast(s, to: SetFn.self)(CGMainDisplayID(), max(0, min(1, v)))
    }
}
