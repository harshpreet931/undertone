// Renders Resources/logo.svg into Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift   (run from the repo root)
// NSImage decodes SVG natively on macOS 13+, so no external tools needed.
import AppKit

let svgURL = URL(fileURLWithPath: "Resources/logo.svg")
let iconsetURL = URL(fileURLWithPath: ".build/AppIcon.iconset")
let icnsURL = URL(fileURLWithPath: "Resources/AppIcon.icns")

guard let svgData = try? Data(contentsOf: svgURL),
      let image = NSImage(data: svgData) else {
    fputs("error: could not load \(svgURL.path)\n", stderr)
    exit(1)
}

let fileManager = FileManager.default
try? fileManager.removeItem(at: iconsetURL)
try! fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func renderPNG(pixels: Int, to url: URL) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
               from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

for points in [16, 32, 128, 256, 512] {
    renderPNG(pixels: points, to: iconsetURL.appendingPathComponent("icon_\(points)x\(points).png"))
    renderPNG(pixels: points * 2, to: iconsetURL.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try! iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fputs("error: iconutil failed\n", stderr)
    exit(1)
}
print("Wrote \(icnsURL.path)")
