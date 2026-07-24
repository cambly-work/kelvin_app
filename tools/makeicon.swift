import AppKit

// Иконка приложения Kelvin. Мотив: ТЕРМО-ПРИБОР (не стоковый тонкий термометр) —
// крупный, уверенный, во весь сквиркл; «ртуть» = инфракрасный градиент тепловизора
// (#33C7D1→#2A86F0→#FF8E42→#F5463D), которая и есть бренд-подпись «Kelvin = температура».
// Аргументы: out.png [size]. При size<=96 рисуем упрощённо (без рисок/виньетки — в малом не в кашу).

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let S: CGFloat = CommandLine.arguments.count > 2 ? (CGFloat(Double(CommandLine.arguments[2]) ?? 1024)) : 1024
let simplified = S <= 96

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
func hex(_ v: Int, _ a: CGFloat = 1) -> NSColor { srgb(CGFloat((v>>16)&0xFF)/255, CGFloat((v>>8)&0xFF)/255, CGFloat(v&0xFF)/255, a) }

let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!

// — сквиркл с полями (как у нативных иконок macOS) —
let m: CGFloat = S * 0.098
let rect = NSRect(x: m, y: m, width: S - 2*m, height: S - 2*m)
let R = rect.width * 0.2237
let squircle = NSBezierPath(roundedRect: rect, xRadius: R, yRadius: R)

// мягкая тень-глубина под плиткой
if !simplified {
    ctx.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = NSColor.black.withAlphaComponent(0.26)
    drop.shadowBlurRadius = S * 0.033; drop.shadowOffset = NSSize(width: 0, height: -S*0.018)
    drop.set()
    NSColor.black.setFill(); squircle.fill()
    ctx.restoreGraphicsState()
}

// бренд-фон: бирюза→синий (2-stop, угол -65°) + нижняя виньетка + верхний блик
ctx.saveGraphicsState()
squircle.addClip()
NSGradient(colors: [hex(0x33C7D1), hex(0x2A86F0)])?.draw(in: rect, angle: -65)
if !simplified {
    NSGradient(colors: [NSColor.black.withAlphaComponent(0), NSColor.black.withAlphaComponent(0.18)])?.draw(in: rect, angle: -90)
    NSColor.white.withAlphaComponent(0.12).setFill()
    NSBezierPath(ovalIn: NSRect(x: rect.minX - rect.width*0.10, y: rect.midY + rect.height*0.10,
                                width: rect.width*1.20, height: rect.height*0.85)).fill()
}
ctx.restoreGraphicsState()

// — ТЕРМО-ПРИБОР (крупный, ~62% высоты поля) —
let cx = rect.midX
let bulbC = NSPoint(x: cx, y: m + rect.height*0.255)          // колба в нижней трети
let bulbR = rect.width*0.150                                   // крупная колба
let stemW = rect.width*0.150                                   // ТОЛСТОЕ стекло-капсула
let stemTop = m + rect.height*0.855                            // высоко — прибор занимает кадр

// «стекло»: белая капсула + колба (с мягкой тенью)
ctx.saveGraphicsState()
if !simplified {
    let gsh = NSShadow(); gsh.shadowColor = NSColor.black.withAlphaComponent(0.22)
    gsh.shadowBlurRadius = S*0.018; gsh.shadowOffset = NSSize(width: 0, height: -S*0.006); gsh.set()
}
let glass = NSBezierPath(roundedRect: NSRect(x: cx - stemW/2, y: bulbC.y, width: stemW, height: stemTop - bulbC.y),
                         xRadius: stemW/2, yRadius: stemW/2)
glass.appendOval(in: NSRect(x: bulbC.x - bulbR, y: bulbC.y - bulbR, width: bulbR*2, height: bulbR*2))
NSColor.white.setFill(); glass.fill()
ctx.restoreGraphicsState()

// «инфракрасная ртуть»: 4-stop тепловизор от колбы вверх (внутри стекла → не сливается с фоном)
let liqW = stemW*0.56
let liqR = bulbR*0.66
let liqLevel = m + rect.height*0.66                            // уровень «температуры»
let liquid = NSBezierPath(roundedRect: NSRect(x: cx - liqW/2, y: bulbC.y, width: liqW, height: liqLevel - bulbC.y),
                          xRadius: liqW/2, yRadius: liqW/2)
liquid.appendOval(in: NSRect(x: bulbC.x - liqR, y: bulbC.y - liqR, width: liqR*2, height: liqR*2))
ctx.saveGraphicsState()
liquid.addClip()
let irRect = NSRect(x: cx - liqR, y: bulbC.y - liqR, width: liqR*2, height: liqLevel - (bulbC.y - liqR))
NSGradient(colors: [hex(0xF5463D), hex(0xFF8E42), hex(0x2A86F0), hex(0x33C7D1)],
           atLocations: [0, 0.42, 0.80, 1], colorSpace: .sRGB)?.draw(in: irRect, angle: 90)  // низ горячий → верх холодный
ctx.restoreGraphicsState()

// деления шкалы — короткие риски справа (только в крупном)
if !simplified {
    hex(0x0A3342, 0.40).setStroke()
    let ticks = NSBezierPath(); ticks.lineWidth = rect.width*0.013; ticks.lineCapStyle = .round
    for i in 0..<4 {
        let ty = bulbC.y + bulbR*1.4 + CGFloat(i)*rect.height*0.115
        ticks.move(to: NSPoint(x: cx + stemW*0.62, y: ty))
        ticks.line(to: NSPoint(x: cx + stemW*0.92, y: ty))
    }
    ticks.stroke()
    // блик на стекле — тонкая светлая дуга слева на капсуле
    NSColor.white.withAlphaComponent(0.55).setStroke()
    let sheen = NSBezierPath()
    sheen.lineWidth = stemW*0.12; sheen.lineCapStyle = .round
    sheen.move(to: NSPoint(x: cx - stemW*0.28, y: bulbC.y + bulbR*1.2))
    sheen.line(to: NSPoint(x: cx - stemW*0.28, y: stemTop - stemW*0.5))
    sheen.stroke()
}

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Не удалось отрендерить иконку\n".data(using: .utf8)!); exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("✓ \(outPath) @\(Int(S))")
