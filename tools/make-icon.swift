// Draws Lockbox's icon, the system folder with a lock etched into it the way macOS marks Downloads
// or Applications, into an .iconset folder for iconutil. Pass --open for the unlocked variant shown
// on an open vault, and --preview to write one big PNG instead.
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let symbol = CommandLine.arguments.contains("--open") ? "lock.open.fill" : "lock.fill"
let folder = NSWorkspace.shared.icon(for: .folder)

func render(_ pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    folder.draw(in: NSRect(x: 0, y: 0, width: size, height: size))

    // Etch the lock in a deeper shade of the folder's own color, sampled from the middle of its front.
    let body = rep.colorAt(x: pixels / 2, y: Int(size * 0.55))?.usingColorSpace(.deviceRGB) ?? .systemBlue
    let etch = body.blended(withFraction: 0.2, of: NSColor(red: 0.1, green: 0.3, blue: 0.45, alpha: 1))!
    let highlight = body.blended(withFraction: 0.45, of: .white)!.withAlphaComponent(0.8)

    let glyphHeight = size * 0.32
    let center = NSPoint(x: size * 0.5, y: size * 0.435)
    func drawLock(_ color: NSColor, offsetY: CGFloat) {
        let config = NSImage.SymbolConfiguration(pointSize: glyphHeight, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        let lock = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
        let scale = glyphHeight / lock.size.height
        let lockSize = NSSize(width: lock.size.width * scale, height: glyphHeight)
        lock.draw(in: NSRect(x: center.x - lockSize.width / 2, y: center.y - lockSize.height / 2 + offsetY,
                             width: lockSize.width, height: lockSize.height))
    }
    if pixels >= 64 { drawLock(highlight, offsetY: -max(1, size / 256)) }
    drawLock(etch, offsetY: 0)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

if CommandLine.arguments.contains("--preview") {
    try png(render(512)).write(to: output)
} else {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        try png(render(points)).write(to: output.appendingPathComponent("icon_\(points)x\(points).png"))
        try png(render(points * 2)).write(to: output.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
    }
}
