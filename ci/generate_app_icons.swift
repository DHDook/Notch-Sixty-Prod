#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Shipping icon generation is intentionally raster-preserving. The approved
// light/dark transparent PNG artwork is the source of truth; this tool only
// resamples those exact rasters into the macOS asset-catalog slots. It does
// not alter source geometry and does not redraw, mask, crop, or reinterpret
// the meter artwork.

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let artwork = root.appendingPathComponent("artwork", isDirectory: true)
let out = root.appendingPathComponent("NotchSixty/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let lightMasterURL = artwork.appendingPathComponent("AppIcon-light-master.png")
let darkMasterURL = artwork.appendingPathComponent("AppIcon-dark-master.png")

try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)

func loadPNG(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("Missing or unreadable approved app-icon master: \(url.path)")
    }
    return image
}

let lightMaster = loadPNG(lightMasterURL)
let darkMaster = loadPNG(darkMasterURL)

func render(_ source: CGImage, pixels: Int) -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
    ) else {
        fatalError("Unable to create \(pixels)×\(pixels) Core Graphics context")
    }

    context.interpolationQuality = .high
    context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    context.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))

    guard let image = context.makeImage() else {
        fatalError("Unable to render \(pixels)×\(pixels) app icon")
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fatalError("Unable to create PNG destination at \(pixels)×\(pixels)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("PNG encoding failed at \(pixels)×\(pixels)")
    }
    return data as Data
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

print("Generated Notch Sixty app icons from approved transparent PNG masters")
