// Kullanım: swift Scripts/make-icon.swift <çizim.png> <çıktı.png>
// 1024x1024 uygulama simgesi: çizimdeki (açık renk zemin üzerindeki) simge
// karesini kendi kenarı boyunca keser, macOS simge ızgarasına yerleştirir
// ve gölgesini ekler. Çizim: Resources/IconArtwork.png
import AppKit

let args = CommandLine.arguments
guard args.count > 2, let art = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: args[1]))) else {
    print("Kullanım: swift Scripts/make-icon.swift <çizim.png> <çıktı.png>")
    exit(1)
}
let out = args[2]
let w = art.pixelsWide, h = art.pixelsHigh

func rgb(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat) {
    let c = art.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    return (c.redComponent, c.greenComponent, c.blueComponent)
}

// Zemin rengi köşeden alınır; kareye ait pikseller ondan belirgin biçimde ayrılır.
// Gölge zemine yakın kaldığı için kesimin dışında kalır.
let background = rgb(2, 2)
func distance(_ x: Int, _ y: Int) -> CGFloat {
    let (r, g, b) = rgb(x, y)
    return sqrt(pow(r - background.0, 2) + pow(g - background.1, 2) + pow(b - background.2, 2))
}
let threshold: CGFloat = 0.5

/// The tile's edge in row y, scanning from x in direction step, to a fraction of a pixel.
func edge(row y: Int, from start: Int, step: Int) -> CGFloat? {
    var x = start, previous = distance(x, y)
    while x + step >= 0 && x + step < w {
        x += step
        let d = distance(x, y)
        if d >= threshold {
            let t = (threshold - previous) / max(d - previous, 0.001)
            return CGFloat(x - step) + CGFloat(step) * t + 0.5
        }
        previous = d
    }
    return nil
}

var rows: [(y: Int, left: CGFloat, right: CGFloat)] = []
for y in 0..<h {
    if let l = edge(row: y, from: 0, step: 1), let r = edge(row: y, from: w - 1, step: -1), r > l {
        rows.append((y, l, r))
    }
}
guard rows.count > 100 else { print("Çizimde simge karesi bulunamadı"); exit(1) }

// Kenardaki yumuşatma piksellerinde zemin rengi karıştığı için kesim biraz içeriden yapılır.
let inset: CGFloat = 2
let edgeRows = rows.dropFirst(Int(inset)).dropLast(Int(inset))
let top = CGFloat(edgeRows.first!.y), bottom = CGFloat(edgeRows.last!.y + 1)
let left = edgeRows.map(\.left).min()! + inset, right = edgeRows.map(\.right).max()! - inset

// Kare, macOS ızgarasındaki 824 piksellik alana ortalanarak oturur (100 piksel
// kenar boşluğu); çizimin en-boy oranı korunur.
let size: CGFloat = 1024, margin: CGFloat = 100, tileSize = size - 2 * margin
let scale = tileSize / max(right - left, bottom - top)
let offsetX = margin + (tileSize - (right - left) * scale) / 2
let offsetY = margin + (tileSize - (bottom - top) * scale) / 2
func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: offsetX + (x - left) * scale, y: size - offsetY - (y - top) * scale)
}

let tile = CGMutablePath()
tile.move(to: point(edgeRows.first!.left + inset, top))
for row in edgeRows { tile.addLine(to: point(row.left + inset, CGFloat(row.y) + 0.5)) }
tile.addLine(to: point(edgeRows.last!.left + inset, bottom))
tile.addLine(to: point(edgeRows.last!.right - inset, bottom))
for row in edgeRows.reversed() { tile.addLine(to: point(row.right - inset, CGFloat(row.y) + 0.5)) }
tile.addLine(to: point(edgeRows.first!.right - inset, top))
tile.closeSubpath()

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
ctx.interpolationQuality = .high

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(tile)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

ctx.addPath(tile)
ctx.clip()
let origin = point(0, CGFloat(h))
ctx.draw(art.cgImage!, in: CGRect(x: origin.x, y: origin.y, width: CGFloat(w) * scale, height: CGFloat(h) * scale))

try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
