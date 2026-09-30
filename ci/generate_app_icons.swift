#!/usr/bin/env swift
import AppKit
import Foundation

// Shipping icon generation is intentionally raster-preserving. The approved
// light/dark transparent artwork is the source of truth; this tool only
// resamples those exact rasters into the macOS asset-catalog slots. It does
// not redraw, mask, crop, or reinterpret the meter.

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let artwork = root.appendingPathComponent("artwork", isDirectory: true)
let out = root.appendingPathComponent("NotchSixty/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let lightMasterURL = artwork.appendingPathComponent("AppIcon-light-master.webp")
let darkMasterURL = artwork.appendingPathComponent("AppIcon-dark-master.webp")

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)

guard let lightMaster = NSImage(contentsOf: lightMasterURL),
      let darkMaster = NSImage(contentsOf: darkMasterURL) else {
    fatalError("Missing or unreadable approved app-icon masters under artwork/")
}

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

    source.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high]
    )

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

print("Generated Notch Sixty app icons from approved transparent raster masters")
