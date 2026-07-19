#!/bin/sh
# Regenerates config/AppIcon.icns from assets/icon.svg.
#
# Uses AppKit's native SVG rendering (macOS 11+) so no third-party
# rasterizer is required. Run after editing assets/icon.svg and commit the
# resulting .icns; the app build copies it verbatim.
set -eu

cd "$(dirname "$0")/.."

iconset="$(/usr/bin/mktemp -d)/AppIcon.iconset"
/bin/mkdir -p "$iconset"

/usr/bin/swift - "$PWD/assets/icon.svg" "$iconset" <<'SWIFT'
import AppKit

let svgURL = URL(fileURLWithPath: CommandLine.arguments[1])
let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let source = NSImage(contentsOf: svgURL) else {
    FileHandle.standardError.write(Data("error: cannot read \(svgURL.path)\n".utf8))
    exit(1)
}
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for variant in variants {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: variant.pixels,
        pixelsHigh: variant.pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        exit(1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(
        in: NSRect(x: 0, y: 0, width: variant.pixels, height: variant.pixels),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
    try! png.write(to: iconsetURL.appendingPathComponent("\(variant.name).png"))
}
SWIFT

/usr/bin/iconutil -c icns "$iconset" -o config/AppIcon.icns
/bin/rm -rf "$(dirname "$iconset")"
/usr/bin/printf 'Wrote config/AppIcon.icns\n'
