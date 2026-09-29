#!/usr/bin/env swift
import AppKit
import Foundation

struct Theme {
    let bodyTop: NSColor
    let bodyBottom: NSColor
    let needle: NSColor
    let labelFill: NSColor
}

let light = Theme(
    bodyTop: NSColor(calibratedRed: 0.97, green: 0.94, blue: 0.86, alpha: 1),
    bodyBottom: NSColor(calibratedRed: 0.89, green: 0.82, blue: 0.68, alpha: 1),
    needle: NSColor(calibratedRed: 0.36, green: 0.16, blue: 0.05, alpha: 1),
    labelFill: NSColor(calibratedRed: 0.36, green: 0.16, blue: 0.05, alpha: 1)
)
let dark = Theme(
    bodyTop: NSColor(calibratedRed: 0.22, green: 0.14, blue: 0.10, alpha: 1),
    bodyBottom: NSColor(calibratedRed: 0.11, green: 0.065, blue: 0.045, alpha: 1),
    needle: NSColor(calibratedRed: 0.95, green: 0.86, blue: 0.68, alpha: 1),
    labelFill: NSColor(calibratedRed: 0.95, green: 0.86, blue: 0.68, alpha: 1)
)

let out = URL(fileURLWithPath: "NotchSixty/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
let artwork = URL(fileURLWithPath: "artwork", isDirectory: true)
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)

func rounded(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

func drawDebossed(_ text: String, rect: NSRect, fill: NSColor, size: CGFloat) {
    let font = NSFont(name: "Futura", size: size) ?? NSFont(name: "Futura-Medium", size: size) ?? NSFont.systemFont(ofSize: size, weight: .regular)
    let p = NSMutableParagraphStyle(); p.alignment = .center
    func attrs(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, .paragraphStyle: p, .kern: size * 0.10]
    }
    let s = text as NSString
    s.draw(in: rect.offsetBy(dx: -1.8, dy: 2.2), withAttributes: attrs(NSColor.black.withAlphaComponent(0.35)))
    s.draw(in: rect.offsetBy(dx: 1.4, dy: -1.4), withAttributes: attrs(NSColor.white.withAlphaComponent(0.28)))
    s.draw(in: rect, withAttributes: attrs(fill))
}

func render(size: CGFloat, theme: Theme) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }
    NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: size, height: size).fill()

    let s = size / 1024
    func R(_ x: CGFloat,_ y: CGFloat,_ w: CGFloat,_ h: CGFloat) -> NSRect { NSRect(x: x*s, y: y*s, width: w*s, height: h*s) }

    let bodyRect = R(72, 72, 880, 880)
    let body = rounded(bodyRect, 145*s)
    NSGradient(starting: theme.bodyTop, ending: theme.bodyBottom)!.draw(in: body, angle: -90)

    // Soft enamel depth without an outline frame.
    let topGloss = rounded(R(94, 560, 836, 350), 120*s)
    NSColor.white.withAlphaComponent(theme === light ? 0.08 : 0.035).setFill(); topGloss.fill()

    let meterRect = R(126, 488, 772, 280)
    let meter = rounded(meterRect, 42*s)
    let amberTop = NSColor(calibratedRed: 1.0, green: 0.74, blue: 0.20, alpha: 1)
    let amberBottom = NSColor(calibratedRed: 1.0, green: 0.52, blue: 0.06, alpha: 1)
    NSGradient(starting: amberBottom, ending: amberTop)!.draw(in: meter, angle: 90)

    NSGraphicsContext.saveGraphicsState()
    meter.addClip()

    // Meter scale first: one shared geometry for light/dark.
    let xs: [CGFloat] = [0.12,0.17,0.22,0.27,0.32,0.37,0.42,0.47,0.52,0.57,0.62,0.67,0.72,0.77,0.82,0.87,0.92]
    let major: Set<Int> = [0,5,11,16]
    let redStart = 13
    for (i, u) in xs.enumerated() {
        let x = meterRect.minX + meterRect.width*u
        let t = (u - 0.52) / 0.52
        let y = meterRect.minY + meterRect.height*(0.54 + 0.12*(1 - t*t))
        let len = (major.contains(i) ? 54 : 34) * s
        let p = NSBezierPath(); p.move(to: NSPoint(x: x, y: y)); p.line(to: NSPoint(x: x, y: y-len));
        p.lineWidth = (major.contains(i) ? 8 : 5) * s
        p.lineCapStyle = .butt
        (i >= redStart ? NSColor(calibratedRed: 0.87, green: 0.12, blue: 0.04, alpha: 1) : NSColor.black).setStroke(); p.stroke()
    }

    let labelFont = NSFont(name: "Futura", size: 42*s) ?? NSFont(name: "Futura-Medium", size: 42*s) ?? NSFont.systemFont(ofSize: 42*s)
    let para = NSMutableParagraphStyle(); para.alignment = .center
    func scaleLabel(_ text: String, x: CGFloat, color: NSColor) {
        let rr = NSRect(x: x-70*s, y: meterRect.minY + meterRect.height*0.69, width: 140*s, height: 56*s)
        (text as NSString).draw(in: rr, withAttributes: [.font: labelFont, .foregroundColor: color, .paragraphStyle: para])
    }
    scaleLabel("-20", x: meterRect.minX + meterRect.width*xs[0], color: .black)
    scaleLabel("-10", x: meterRect.minX + meterRect.width*xs[5], color: .black)
    scaleLabel("0", x: meterRect.minX + meterRect.width*xs[11], color: .black)
    scaleLabel("+3", x: meterRect.minX + meterRect.width*xs[16], color: NSColor(calibratedRed: 0.87, green: 0.12, blue: 0.04, alpha: 1))

    // Needle second, precisely between two neighboring ticks, with pivot hidden below the meter opening.
    let topX = meterRect.minX + meterRect.width*((xs[6] + xs[7]) * 0.5)
    let needle = NSBezierPath(); needle.move(to: NSPoint(x: meterRect.midX+8*s, y: meterRect.minY-18*s)); needle.line(to: NSPoint(x: topX, y: meterRect.minY + meterRect.height*0.77));
    needle.lineWidth = 8*s; needle.lineCapStyle = .butt; theme.needle.setStroke(); needle.stroke()

    // Clear glass on top: no separate frame, strong top reflection, side refraction/distortion where glass meets enamel.
    let glassTop = NSGradient(colors: [NSColor.white.withAlphaComponent(0.40), NSColor.white.withAlphaComponent(0.08), NSColor.clear], atLocations: [0,0.36,1], colorSpace: .deviceRGB)!
    glassTop.draw(in: NSRect(x: meterRect.minX, y: meterRect.minY + meterRect.height*0.42, width: meterRect.width, height: meterRect.height*0.58), angle: -90)
    NSColor.white.withAlphaComponent(0.33).setFill()
    rounded(NSRect(x: meterRect.minX+14*s, y: meterRect.maxY-38*s, width: meterRect.width*0.26, height: 18*s), 9*s).fill()
    rounded(NSRect(x: meterRect.maxX-meterRect.width*0.26-14*s, y: meterRect.maxY-38*s, width: meterRect.width*0.26, height: 18*s), 9*s).fill()
    let leftRefract = NSGradient(colors: [NSColor.white.withAlphaComponent(0.42), NSColor.white.withAlphaComponent(0.10), NSColor.black.withAlphaComponent(0.10), NSColor.clear], atLocations: [0,0.24,0.64,1], colorSpace: .deviceRGB)!
    leftRefract.draw(in: NSRect(x: meterRect.minX, y: meterRect.minY, width: 46*s, height: meterRect.height), angle: 0)
    let rightRefract = NSGradient(colors: [NSColor.clear, NSColor.black.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0.42)], atLocations: [0,0.36,0.76,1], colorSpace: .deviceRGB)!
    rightRefract.draw(in: NSRect(x: meterRect.maxX-46*s, y: meterRect.minY, width: 46*s, height: meterRect.height), angle: 0)
    NSGraphicsContext.restoreGraphicsState()

    drawDebossed("NOTCH SIXTY", rect: R(190, 240, 644, 120), fill: theme.labelFill, size: 72*s)

    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
    return png
}

let slots: [(String, Int, Bool)] = [
    ("icon_16x16.png",16,false),("icon_16x16@2x.png",32,false),("icon_32x32.png",32,false),("icon_32x32@2x.png",64,false),("icon_128x128.png",128,false),("icon_128x128@2x.png",256,false),("icon_256x256.png",256,false),("icon_256x256@2x.png",512,false),("icon_512x512.png",512,false),("icon_512x512@2x.png",1024,false),
    ("icon_dark_16x16.png",16,true),("icon_dark_16x16@2x.png",32,true),("icon_dark_32x32.png",32,true),("icon_dark_32x32@2x.png",64,true),("icon_dark_128x128.png",128,true),("icon_dark_128x128@2x.png",256,true),("icon_dark_256x256.png",256,true),("icon_dark_256x256@2x.png",512,true),("icon_dark_512x512.png",512,true),("icon_dark_512x512@2x.png",1024,true)
]

for (name, px, isDark) in slots {
    try render(size: CGFloat(px), theme: isDark ? dark : light).write(to: out.appendingPathComponent(name), options: .atomic)
}
try render(size: 1024, theme: light).write(to: artwork.appendingPathComponent("AppIcon-light-final.png"), options: .atomic)
try render(size: 1024, theme: dark).write(to: artwork.appendingPathComponent("AppIcon-dark-final.png"), options: .atomic)
print("Generated final Notch Sixty light/dark app icons")
