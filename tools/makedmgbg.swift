import AppKit

// Фон окна DMG (660×400 @ scale). Лёгкий брендовый градиент + подсказка-стрелка
// «перетащите в Программы». Сами иконки (Kelvin.app слева, alias Программы справа)
// раскладывает Finder поверх — здесь только подложка.
// Аргументы: <выходной путь> [scale=1]

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-bg.png"
let scale: CGFloat = CommandLine.arguments.count > 2 ? (CGFloat(Double(CommandLine.arguments[2]) ?? 1) ) : 1
let W: CGFloat = 660, H: CGFloat = 400

let img = NSImage(size: NSSize(width: W * scale, height: H * scale))
img.lockFocus()
let ctx = NSGraphicsContext.current!
ctx.cgContext.scaleBy(x: scale, y: scale)

let teal = NSColor(srgbRed: 0.24, green: 0.84, blue: 0.82, alpha: 1)
let blue = NSColor(srgbRed: 0.10, green: 0.46, blue: 0.95, alpha: 1)

// — мягкая светлая подложка (чтобы цветные иконки читались) —
NSGradient(colors: [NSColor(white: 0.99, alpha: 1), NSColor(srgbRed: 0.92, green: 0.96, blue: 0.99, alpha: 1)])?
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)
// тонкая брендовая полоса сверху
NSGradient(colors: [teal, blue])?.draw(in: NSRect(x: 0, y: H - 4, width: W, height: 4), angle: 0)

// — заголовок —
let title = NSAttributedString(string: "Kelvin", attributes: [
    .font: NSFont.systemFont(ofSize: 30, weight: .bold),
    .foregroundColor: blue.blended(withFraction: 0.15, of: .black) ?? blue,
])
title.draw(at: NSPoint(x: 48, y: H - 64))
let sub = NSAttributedString(string: "Перетащите Kelvin в папку «Программы»", attributes: [
    .font: NSFont.systemFont(ofSize: 14, weight: .medium),
    .foregroundColor: NSColor(white: 0.35, alpha: 1),
])
sub.draw(at: NSPoint(x: 48, y: H - 90))

// — стрелка между местами иконок (Finder ставит иконки ~165 и ~495 по x, ~y центр) —
// в координатах окна Finder y растёт вниз; иконки на «середине». Здесь y-вверх: центр ≈ H*0.46.
let ay = H * 0.46
let arrow = NSBezierPath()
arrow.lineWidth = 6
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
arrow.move(to: NSPoint(x: 250, y: ay))
arrow.line(to: NSPoint(x: 405, y: ay))
let tealBlue = teal.blended(withFraction: 0.5, of: blue) ?? blue
tealBlue.withAlphaComponent(0.85).setStroke()
arrow.stroke()
// наконечник
let head = NSBezierPath()
head.move(to: NSPoint(x: 405, y: ay))
head.line(to: NSPoint(x: 386, y: ay + 12))
head.move(to: NSPoint(x: 405, y: ay))
head.line(to: NSPoint(x: 386, y: ay - 12))
head.lineWidth = 6; head.lineCapStyle = .round
tealBlue.withAlphaComponent(0.85).setStroke()
head.stroke()

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Не удалось отрендерить фон DMG\n".data(using: .utf8)!); exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("✓ \(outPath)")
