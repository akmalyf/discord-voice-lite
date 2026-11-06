// Generate AppIcon.iconset dari logo (brand/icon.svg): swift make-icon.swift <output-dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = CGFloat(px) / 1024
    // Koordinat sama dengan brand/icon.svg (viewBox 1024, origin kiri atas) → balik sumbu y.
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: NSRect(x: x * k, y: (1024 - y - h) * k, width: w * k, height: h * k), xRadius: r * k, yRadius: r * k)
    }
    // Grid ikon macOS: konten 824/1024 dengan sudut ~185/1024.
    NSGradient(starting: color(0x6A76F5), ending: color(0x4752C4))!.draw(in: rect(100, 100, 824, 824, 185), angle: -90)

    color(0xFFFFFF).setFill()
    for (x, h) in [(272, 124), (376, 264), (584, 264), (688, 124)] as [(CGFloat, CGFloat)] { rect(x, 352, 64, h, 32).fill() }
    rect(232, 276, 560, 48, 24).fill()  // garis menu bar
    color(0x57F287).setFill()
    rect(480, 352, 64, 408, 32).fill()  // bar tengah = indikator bicara
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
