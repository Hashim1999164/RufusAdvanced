// Renders the app icon (Packaging/AppIcon.icns) and the Windows autorun icon
// (Resources/BootKit/icons/autorun.ico). Run: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS style squircle with a margin.
    let inset = s * 0.09
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(calibratedRed: 0.13, green: 0.36, blue: 0.95, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.05, green: 0.70, blue: 0.80, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    // Soft highlight
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.fillEllipse(in: CGRect(x: rect.minX - rect.width * 0.2, y: rect.midY, width: rect.width * 1.4, height: rect.height))
    ctx.restoreGState()

    // USB stick glyph
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .semibold)
    if let sym = NSImage(systemSymbolName: "mediastick", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: sym.size, flipped: false) { r in
            sym.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let w = sym.size.width, h = sym.size.height
        tinted.draw(in: CGRect(x: (s - w) / 2, y: (s - h) / 2 - s * 0.01, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = root.appendingPathComponent("Packaging/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Packaging/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
try? fm.removeItem(at: iconset)

// Windows .ico (PNG-compressed entries, supported since Vista)
let sizes = [16, 32, 48, 256]
let pngs = sizes.map { render(size: $0) }
var ico = Data([0, 0, 1, 0, UInt8(sizes.count), 0])
var offset = 6 + 16 * sizes.count
for (i, size) in sizes.enumerated() {
    var e = Data()
    e.append(UInt8(size == 256 ? 0 : size)); e.append(UInt8(size == 256 ? 0 : size)); e.append(0); e.append(0)
    e.append(contentsOf: [1, 0, 32, 0])
    let len = UInt32(pngs[i].count), off = UInt32(offset)
    e.append(contentsOf: withUnsafeBytes(of: len.littleEndian, Array.init))
    e.append(contentsOf: withUnsafeBytes(of: off.littleEndian, Array.init))
    ico.append(e)
    offset += pngs[i].count
}
for d in pngs { ico.append(d) }
let icoURL = root.appendingPathComponent("Resources/BootKit/icons/autorun.ico")
try! fm.createDirectory(at: icoURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try! ico.write(to: icoURL)
try! render(size: 512).write(to: root.appendingPathComponent("docs/icon.png"))
print("Wrote Packaging/AppIcon.icns, Resources/BootKit/icons/autorun.ico and docs/icon.png")
