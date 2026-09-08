import AppKit

// Брендовый фон beta Finder-окна DMG (900×520 pt). Базовая тепловая текстура
// сгенерирована отдельно, а текст и геометрия рисуются здесь детерминированно.
// Аргументы: <выходной путь> [scale=1]

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-bg.png"
let scale = CommandLine.arguments.count > 2 ? CGFloat(Double(CommandLine.arguments[2]) ?? 1) : 1
let W: CGFloat = 900, H: CGFloat = 520

func hex(_ value: Int, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: alpha)
}

func drawCentered(_ text: String, y: CGFloat, font: NSFont, color: NSColor) {
    let value = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    value.draw(at: NSPoint(x: (W - value.size().width) / 2, y: y))
}

let image = NSImage(size: NSSize(width: W * scale, height: H * scale))
image.lockFocus()
guard let context = NSGraphicsContext.current else { exit(1) }
context.cgContext.scaleBy(x: scale, y: scale)

// Aspect-fill исходной текстуры и затемнение для читаемости Finder-иконок.
let sourcePath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/dmg-artwork.png").path
if let artwork = NSImage(contentsOfFile: sourcePath) {
    let sourceRatio = artwork.size.width / artwork.size.height
    let targetRatio = W / H
    var crop = NSRect(origin: .zero, size: artwork.size)
    if sourceRatio > targetRatio {
        crop.size.width = artwork.size.height * targetRatio
        crop.origin.x = (artwork.size.width - crop.size.width) / 2
    } else {
        crop.size.height = artwork.size.width / targetRatio
        crop.origin.y = (artwork.size.height - crop.size.height) / 2
    }
    artwork.draw(in: NSRect(x: 0, y: 0, width: W, height: H), from: crop,
                 operation: .copy, fraction: 1)
} else {
    hex(0x081426).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
}
hex(0x030B18, alpha: 0.30).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()

// Верхняя брендовая панель.
let title = NSAttributedString(string: "Kelvin", attributes: [
    .font: NSFont.systemFont(ofSize: 30, weight: .bold),
    .foregroundColor: NSColor.white
])
title.draw(at: NSPoint(x: 42, y: 458))
let tagline = NSAttributedString(string: "Температура и производительность — под контролем", attributes: [
    .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
    .foregroundColor: hex(0xAFC5DB)
])
tagline.draw(at: NSPoint(x: 42, y: 436))

let beta = NSAttributedString(string: "BETA", attributes: [
    .font: NSFont.systemFont(ofSize: 11, weight: .bold),
    .foregroundColor: hex(0x081426)
])
let betaBox = NSBezierPath(roundedRect: NSRect(x: 154, y: 459, width: 52, height: 23),
                           xRadius: 11.5, yRadius: 11.5)
hex(0x45C9DA).setFill(); betaBox.fill()
beta.draw(at: NSPoint(x: 165, y: 464))

// Три разнесённых шага beta-установки.
drawCentered("Установка бета-версии — три простых шага", y: 385,
             font: .systemFont(ofSize: 17, weight: .semibold), color: .white)
let stepColor = hex(0xB6CADC)
for (text, x) in [("1. Подготовьте Mac", 150.0), ("2. Установите Kelvin", 450.0),
                  ("3. Перетащите в Программы", 750.0)] {
    let value = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: stepColor
    ])
    value.draw(at: NSPoint(x: CGFloat(x) - value.size().width / 2, y: 346))
}
let cyan = hex(0x45C9DA)
for (x0, x1) in [(235.0, 365.0), (535.0, 665.0)] {
    let line = NSBezierPath()
    line.move(to: NSPoint(x: CGFloat(x0), y: 245))
    line.line(to: NSPoint(x: CGFloat(x1), y: 245))
    line.lineWidth = 3; line.lineCapStyle = .round
    cyan.withAlphaComponent(0.72).setStroke(); line.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: CGFloat(x1), y: 245))
    head.line(to: NSPoint(x: CGFloat(x1 - 13), y: 254))
    head.move(to: NSPoint(x: CGFloat(x1), y: 245))
    head.line(to: NSPoint(x: CGFloat(x1 - 13), y: 236))
    head.lineWidth = 3; head.lineCapStyle = .round; cyan.setStroke(); head.stroke()
}

drawCentered("Шаг 1 удаляет только старую beta-установку; ваши настройки сохраняются", y: 58,
             font: .systemFont(ofSize: 11.5, weight: .regular), color: hex(0x8FA9C0))

// Ненавязчивый брендовый акцент.
NSGradient(colors: [hex(0x33C7D1), hex(0x2A86F0), hex(0xFF8E42)])?
    .draw(in: NSRect(x: 0, y: H - 3, width: W, height: 3), angle: 0)

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Не удалось отрендерить фон DMG\n".utf8)); exit(1)
}
try png.write(to: URL(fileURLWithPath: outPath))
print("✓ \(outPath)")
