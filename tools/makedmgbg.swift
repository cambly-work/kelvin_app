import AppKit

// Фон окна DMG (660×400 @ scale) — тёмная «тепловизорная» сцена в брендовых цветах
// (#33C7D1 бирюза / #2A86F0 синий / #FF8E42 оранжевый / #F5463D красный).
// Иконки (Kelvin.app слева, alias Программы справа) раскладывает Finder поверх —
// здесь только подложка: свечение-платформы под иконками центрируем на тех же x
// (~165 и ~495), что и в make-dmg.sh. Подсказка — пунктирная стрелка «перетащите».
// Аргументы: <выходной путь> [scale=1]

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-bg.png"
let scale: CGFloat = CommandLine.arguments.count > 2 ? (CGFloat(Double(CommandLine.arguments[2]) ?? 1)) : 1
let W: CGFloat = 660, H: CGFloat = 480

let img = NSImage(size: NSSize(width: W * scale, height: H * scale))
img.lockFocus()
let ctx = NSGraphicsContext.current!
ctx.cgContext.scaleBy(x: scale, y: scale)

// — палитра (та же, что у иконки приложения) —
func hex(_ v: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v>>16)&0xFF)/255, green: CGFloat((v>>8)&0xFF)/255,
            blue: CGFloat(v&0xFF)/255, alpha: a)
}
let teal  = hex(0x33C7D1)
let blue  = hex(0x2A86F0)
let orange = hex(0xFF8E42)
let red   = hex(0xF5463D)

// радиальное свечение color→прозрачный (мягкое, без внешних зависимостей)
func glow(_ color: NSColor, _ center: NSPoint, _ r: CGFloat) {
    NSGradient(colors: [color, color.withAlphaComponent(0)])?
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: r, options: [])
}
// то же, но сплюснутое в эллипс (sx,sy — множители относительно центра)
func glowEllipse(_ color: NSColor, _ center: NSPoint, _ r: CGFloat, _ sx: CGFloat, _ sy: CGFloat) {
    ctx.saveGraphicsState()
    let cg = ctx.cgContext
    cg.translateBy(x: center.x, y: center.y)
    cg.scaleBy(x: sx, y: sy)
    NSGradient(colors: [color, color.withAlphaComponent(0)])?
        .draw(fromCenter: .zero, radius: 0, toCenter: .zero, radius: r, options: [])
    ctx.restoreGraphicsState()
}

// 1 — базовый тёмный фон (синева, не чистый чёрный — сохраняет «температуру»)
NSGradient(colors: [hex(0x0A1428), hex(0x0E2A4A)])?
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

// 2 — инфракрасные блобы: тёплый «раскалённый металл» снизу-слева, холодный бирюзовый сверху-справа
glow(red,    NSPoint(x: 40,  y: 60),  280)
glow(orange, NSPoint(x: 90,  y: 30),  200)
glow(teal,   NSPoint(x: 610, y: 360), 250)
glow(blue,   NSPoint(x: 560, y: 390), 180)

// 3 — светящиеся платформы под иконками (Finder ставит их на x≈165 и x≈495, центр по y≈ay)
let ay = H * 0.46
let platformL = NSPoint(x: 165, y: ay)
let platformR = NSPoint(x: 495, y: ay)
for p in [platformL, platformR] {
    glowEllipse(blend(teal, blue, 0.5).withAlphaComponent(0.28), p, 135, 1.30, 0.62) // широкая мягкая
    glowEllipse(teal.withAlphaComponent(0.42),                   p, 78,  1.30, 0.62) // яркое ядро
}

// 3b — приглушённая платформа под деинсталлятором (Finder ставит .command на x≈330, y≈390 → y-up ≈ H-390)
let cmdY = H - 390
let platformCmd = NSPoint(x: 330, y: cmdY)
glowEllipse(blend(teal, blue, 0.5).withAlphaComponent(0.14), platformCmd, 90, 1.45, 0.70)

// 4 — стрелка-трек: широкое свечение снизу, затем чёткий пунктир точками + наконечник
let tealBlue = blend(teal, blue, 0.5)
let x0: CGFloat = 250, x1: CGFloat = 405

// подложка-свечение (сплошная, широкая, полупрозрачная)
let glowLine = NSBezierPath()
glowLine.move(to: NSPoint(x: x0, y: ay))
glowLine.line(to: NSPoint(x: x1, y: ay))
glowLine.lineWidth = 12
glowLine.lineCapStyle = .round
tealBlue.withAlphaComponent(0.16).setStroke()
glowLine.stroke()

// чёткий пунктир-точки
let dots = NSBezierPath()
dots.move(to: NSPoint(x: x0, y: ay))
dots.line(to: NSPoint(x: x1, y: ay))
dots.lineWidth = 5
dots.lineCapStyle = .round
dots.lineJoinStyle = .round
dots.setLineDash([0, 11], count: 2, phase: 0)
tealBlue.withAlphaComponent(0.90).setStroke()
dots.stroke()

// наконечник (шеврон)
let head = NSBezierPath()
head.move(to: NSPoint(x: x1, y: ay))
head.line(to: NSPoint(x: x1 - 18, y: ay + 12))
head.move(to: NSPoint(x: x1, y: ay))
head.line(to: NSPoint(x: x1 - 18, y: ay - 12))
head.lineWidth = 5
head.lineCapStyle = .round
tealBlue.withAlphaComponent(0.90).setStroke()
head.stroke()

// 5 — типографика
let title = NSAttributedString(string: "Kelvin", attributes: [
    .font: NSFont.systemFont(ofSize: 30, weight: .bold),
    .foregroundColor: NSColor.white,
])
title.draw(at: NSPoint(x: 48, y: H - 64))
let sub = NSAttributedString(string: "Drag Kelvin to your Applications folder", attributes: [
    .font: NSFont.systemFont(ofSize: 14, weight: .medium),
    .foregroundColor: hex(0xB8C5D6),
])
sub.draw(at: NSPoint(x: 48, y: H - 90))
// подсказка над деинсталлятором — в зазоре между рядами (по центру, приглушённо)
let cmdHint = NSAttributedString(string: "Trouble updating? Run this first", attributes: [
    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
    .foregroundColor: hex(0x7A8AA0),
])
let cmdHintW = cmdHint.size().width
cmdHint.draw(at: NSPoint(x: 330 - cmdHintW / 2, y: cmdY + 75))
let foot = NSAttributedString(string: "trykelvin.com", attributes: [
    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
    .foregroundColor: hex(0x5A6B80),
])
foot.draw(at: NSPoint(x: 48, y: 22))

// тонкая брендовая полоса teal→blue сверху (хорошо читается на тёмном)
NSGradient(colors: [teal, blue])?.draw(in: NSRect(x: 0, y: H - 4, width: W, height: 4), angle: 0)

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Не удалось отрендерить фон DMG\n".data(using: .utf8)!); exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("✓ \(outPath)")

// — утилиты —
func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor { a.blended(withFraction: t, of: b) ?? a }
