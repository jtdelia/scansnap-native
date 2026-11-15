// Renders the 1024×1024 app icon: usage `swift make-icon.swift <out.png>`
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset = size * 0.1
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.shadowBlurRadius = size * 0.03
    shadow.set()
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.0, alpha: 1),
                        NSColor(calibratedRed: 0.05, green: 0.24, blue: 0.75, alpha: 1)])!
        .draw(in: path, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // Glass highlight across the top half.
    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    let highlight = NSBezierPath(ovalIn: NSRect(x: tile.minX - tile.width * 0.2, y: tile.midY,
                                                width: tile.width * 1.4, height: tile.height * 0.9))
    NSColor.white.withAlphaComponent(0.14).setFill()
    highlight.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "scanner.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 - size * 0.01,
                               width: s.width, height: s.height))
    }
    return true
}

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
