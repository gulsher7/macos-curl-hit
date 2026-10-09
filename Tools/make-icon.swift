// Renders the app icon from code, so the repo needs no hand-drawn artwork.
// Writes both build/AppIcon.iconset (for the plain swiftc build) and
// Resources/Assets.xcassets/AppIcon.appiconset (for the Xcode / App Store build).
//
//   swift Tools/make-icon.swift
import AppKit

/// Canonical macOS icon slots: (pixel size, file name).
let canonical: [(px: Int, name: String)] = [
    (16,   "icon_16x16.png"),    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),  (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),  (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),  (1024, "icon_512x512@2x.png")
]

/// Draws at exactly `px` × `px` pixels. Going through an explicitly sized
/// bitmap rep matters: `NSImage.lockFocus` would silently render at the
/// display's backing scale and produce double-size PNGs.
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)   // one point == one pixel

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext
    let size = CGFloat(px)

    // Rounded-square base with a blue → indigo gradient.
    let inset = size * 0.055
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let corner = size * 0.225
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor(srgbRed: 0.18, green: 0.47, blue: 0.98, alpha: 1).cgColor,
                                       NSColor(srgbRed: 0.36, green: 0.22, blue: 0.86, alpha: 1).cgColor] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY),
                           options: [])
    ctx.restoreGState()

    // Lightning bolt, described in a 0…1 space and scaled up.
    let bolt = CGMutablePath()
    let points: [CGPoint] = [
        CGPoint(x: 0.58, y: 0.92), CGPoint(x: 0.27, y: 0.50), CGPoint(x: 0.46, y: 0.50),
        CGPoint(x: 0.40, y: 0.08), CGPoint(x: 0.73, y: 0.52), CGPoint(x: 0.53, y: 0.52)
    ]
    for (i, p) in points.enumerated() {
        let q = CGPoint(x: p.x * size, y: p.y * size)
        i == 0 ? bolt.move(to: q) : bolt.addLine(to: q)
    }
    bolt.closeSubpath()
    ctx.addPath(bolt)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()

    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
let catalog = URL(fileURLWithPath: "Resources/Assets.xcassets/AppIcon.appiconset")
for dir in [iconset, catalog] {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}

for slot in canonical {
    let data = render(slot.px)
    try data.write(to: iconset.appendingPathComponent(slot.name))
    try data.write(to: catalog.appendingPathComponent(slot.name))
}

let entries = canonical.map { slot -> String in
    let scale = slot.name.contains("@2x") ? 2 : 1
    let pt = slot.px / scale
    return """
        {
          "filename" : "\(slot.name)",
          "idiom" : "mac",
          "scale" : "\(scale)x",
          "size" : "\(pt)x\(pt)"
        }
    """
}
let contents = """
{
  "images" : [
\(entries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "curl-hit",
    "version" : 1
  }
}

"""
try Data(contents.utf8).write(to: catalog.appendingPathComponent("Contents.json"))
print("icons written: \(iconset.path) and \(catalog.path)")
