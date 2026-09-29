#!/usr/bin/env swift
import AppKit
import Foundation

// Shipping icon generation is intentionally raster-preserving. The approved
// light/dark artwork is the source of truth; this tool only removes the studio
// background with the agreed body mask and resamples that artwork into the
// macOS asset-catalog slots. It does not redraw or reinterpret the meter.

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let artwork = root.appendingPathComponent("artwork", isDirectory: true)
let out = root.appendingPathComponent("NotchSixty/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let lightMasterURL = artwork.appendingPathComponent("AppIcon-light-master.png")
let darkMasterURL = artwork.appendingPathComponent("AppIcon-dark-master.png")

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)

guard let lightMaster = NSImage(contentsOf: lightMasterURL),
      let darkMaster = NSImage(contentsOf: darkMasterURL) else {
    fatalError("Missing approved app-icon masters under artwork/")
}

// The approved 512×512 source artwork has a photographed/rendered studio
// surround. The enamel body itself occupies this normalized rounded rectangle.
// Clipping here preserves every pixel inside the approved icon while making the
// surrounding studio floor/background transparent for native macOS icon use.
let sourceCanvas: CGFloat = 512
let bodyX: CGFloat = 36
let bodyYFromBottom: CGFloat = 44
let bodyWidth: CGFloat = 440
let bodyHeight: CGFloat = 433
let bodyRadius: CGFloat = 73

func render(_ source: NSImage, pixels: Int) -> Data {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: .alphaNonpremultiplied,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("Unable to create \(pixels)×\(pixels) bitmap context")
    }

    rep.size = NSSize(width: size, height: size)
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.current = previous }

    context.imageInterpolation = .high
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: size, height: size).fill()

    let scale = size / sourceCanvas
    let bodyRect = NSRect(
        x: bodyX * scale,
        y: bodyYFromBottom * scale,
        width: bodyWidth * scale,
        height: bodyHeight * scale
    )

    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(
        roundedRect: bodyRect,
        xRadius: bodyRadius * scale,
        yRadius: bodyRadius * scale
    ).addClip()
    source.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed at \(pixels)×\(pixels)")
    }
    return png
}

let slots: [(name: String, pixels: Int, dark: Bool)] = [
    ("icon_16x16.png", 16, false),
    ("icon_16x16@2x.png", 32, false),
    ("icon_32x32.png", 32, false),
    ("icon_32x32@2x.png", 64, false),
    ("icon_128x128.png", 128, false),
    ("icon_128x128@2x.png", 256, false),
    ("icon_256x256.png", 256, false),
    ("icon_256x256@2x.png", 512, false),
    ("icon_512x512.png", 512, false),
    ("icon_512x512@2x.png", 1024, false),
    ("icon_dark_16x16.png", 16, true),
    ("icon_dark_16x16@2x.png", 32, true),
    ("icon_dark_32x32.png", 32, true),
    ("icon_dark_32x32@2x.png", 64, true),
    ("icon_dark_128x128.png", 128, true),
    ("icon_dark_128x128@2x.png", 256, true),
    ("icon_dark_256x256.png", 256, true),
    ("icon_dark_256x256@2x.png", 512, true),
    ("icon_dark_512x512.png", 512, true),
    ("icon_dark_512x512@2x.png", 1024, true),
]

for slot in slots {
    let master = slot.dark ? darkMaster : lightMaster
    try render(master, pixels: slot.pixels)
        .write(to: out.appendingPathComponent(slot.name), options: .atomic)
}

try render(lightMaster, pixels: 1024)
    .write(to: artwork.appendingPathComponent("AppIcon-light-final.png"), options: .atomic)
try render(darkMaster, pixels: 1024)
    .write(to: artwork.appendingPathComponent("AppIcon-dark-final.png"), options: .atomic)

print("Generated Notch Sixty app icons from approved raster masters")
