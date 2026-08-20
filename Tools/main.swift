import AppKit

// Generates Resources/AppIcon.icns (must be named main.swift: swiftc only allows
// top-level code in a file with that name) from the same paw geometry the menu bar uses.
// Run via ./make-icon.sh; the result is committed, so a normal build needs no
// Swift compilation beyond the app itself.

/// A rounded tile rather than a bare paw: in the Dock and in Finder an icon is
/// expected to be a shape, and a floating silhouette reads as a broken asset.
/// Dark ground with a pale paw, which is roughly a honey badger's own colouring
/// and holds contrast down to 16 points.
enum AppIconArt {
    static let ground = (top: NSColor(srgbRed: 0.24, green: 0.26, blue: 0.29, alpha: 1),
                         bottom: NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1))
    static let paw = NSColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1)

    static func draw(size: CGFloat) {
        // macOS icons leave a margin around the tile for its shadow.
        let inset = size * 0.085
        let tile = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        // Apple's grid uses a corner radius near a fifth of the tile.
        let path = NSBezierPath(roundedRect: tile,
                               xRadius: tile.width * 0.2237, yRadius: tile.width * 0.2237)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(starting: ground.top, ending: ground.bottom)?.draw(in: tile, angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // The paw sits a little high: the pad is the visual weight, so centring
        // the bounding box makes it look like it is sagging.
        let pawSize = tile.width * 0.66
        let pawRect = NSRect(x: tile.midX - pawSize / 2,
                             y: tile.midY - pawSize / 2 + tile.height * 0.02,
                             width: pawSize, height: pawSize)
        PawIcon.draw(in: pawRect, colour: paw)
    }

    static func png(size: Int) -> Data {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            draw(size: CGFloat(size))
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }
}

// iconutil expects exactly these names.
let variants: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
for v in variants {
    try AppIconArt.png(size: v.px).write(to: outDir.appendingPathComponent("\(v.name).png"))
}
print("wrote \(variants.count) sizes to \(outDir.path)")
