import AppKit

// Превью бренд-глифов: верхний ряд — бирюза на светлом, нижний — белый на тёмном.
let ids = ["battery", "watts", "cputemp", "gputemp", "fan", "cpu", "ram", "net", "diskio", "diskfree", "btbatt", "clock", "date"]
let tile: CGFloat = 64, glyph: CGFloat = 40
let cols = ids.count
let stripH: CGFloat = 30
let W = Int(tile * CGFloat(cols)), H = Int(tile * 2 + stripH)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W*2, pixelsHigh: H*2,
                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let teal = NSColor(srgbRed: 0/255, green: 140/255, blue: 153/255, alpha: 1)
for (i, id) in ids.enumerated() {
    let x = CGFloat(i) * tile
    // светлая карточка (верх)
    NSColor(white: 0.96, alpha: 1).setFill(); NSRect(x: x, y: stripH + tile, width: tile, height: tile).fill()
    teal.set()
    KelvinGlyph.draw(id, in: NSRect(x: x + (tile-glyph)/2, y: stripH + tile + (tile-glyph)/2, width: glyph, height: glyph))
    // тёмная карточка (низ)
    NSColor(white: 0.12, alpha: 1).setFill(); NSRect(x: x, y: stripH, width: tile, height: tile).fill()
    NSColor.white.set()
    KelvinGlyph.draw(id, in: NSRect(x: x + (tile-glyph)/2, y: stripH + (tile-glyph)/2, width: glyph, height: glyph))
}

// мок объединённого вида строки меню: [глиф + значение] через тонкие разделители, белым на тёмном
NSColor(white: 0.16, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: CGFloat(W), height: stripH).fill()
let mock: [(String, String)] = [("battery", "67%"), ("cputemp", "54°"), ("fan", "2.1k"),
                                ("net", "↓2M ↑1M"), ("diskio", "↓0 ↑0"), ("clock", "09:13")]
let gpx: CGFloat = 18, vfont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
var mx: CGFloat = 10
let cy = stripH/2
for (id, val) in mock {
    NSColor.white.set()
    KelvinGlyph.draw(id, in: NSRect(x: mx, y: cy - gpx/2, width: gpx, height: gpx))
    mx += gpx + 3
    let s = val as NSString
    let sz = s.size(withAttributes: [.font: vfont, .foregroundColor: NSColor.white])
    s.draw(at: NSPoint(x: mx, y: cy - sz.height/2), withAttributes: [.font: vfont, .foregroundColor: NSColor.white])
    mx += sz.width + 11
    NSColor(white: 1, alpha: 0.3).setStroke()
    let sep = NSBezierPath(); sep.lineWidth = 1
    sep.move(to: NSPoint(x: mx - 5.5, y: 6)); sep.line(to: NSPoint(x: mx - 5.5, y: stripH - 6)); sep.stroke()
}
NSGraphicsContext.restoreGraphicsState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "glyphs.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out) — \(ids.count) глифов")
