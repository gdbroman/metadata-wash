#!/usr/bin/env swift
// Renders the 🧼 app icon into Metadata Wash/Assets.xcassets/AppIcon.appiconset.
//
// Each size is drawn natively (not downscaled from 1024) so small sizes stay sharp.
// Usage: swift scripts/make-app-icon.swift
import AppKit

let emoji = "🧼"
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("Metadata Wash/Assets.xcassets/AppIcon.appiconset")

// The emoji drawn at its largest native bitmap size (160px), cropped to its visible pixels
// so it can be optically centred — glyph metrics include uneven padding.
let trimmedEmoji: CGImage = {
    let canvas = 256
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSAttributedString(string: emoji, attributes: [.font: NSFont(name: "Apple Color Emoji", size: 160)!])
        .draw(at: CGPoint(x: 32, y: 32))
    NSGraphicsContext.restoreGraphicsState()

    var minX = canvas, minY = canvas, maxX = -1, maxY = -1
    for y in 0..<canvas {
        for x in 0..<canvas where rep.colorAt(x: x, y: y)!.alphaComponent > 0.02 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    return rep.cgImage!.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!
}()

func render(pixels: Int) -> Data {
    let s = CGFloat(pixels)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.interpolationQuality = .high

    // macOS icon grid: 824/1024 body, ~185/1024 corner radius.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: body, cornerWidth: s * 185 / 1024, cornerHeight: s * 185 / 1024, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 20 / 1024,
                  color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.78, green: 0.93, blue: 1.00, alpha: 1).cgColor,
        NSColor(red: 0.42, green: 0.74, blue: 0.98, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    ctx.restoreGState()

    let glyph = trimmedEmoji
    let side = body.width * 0.68
    let scale = side / CGFloat(max(glyph.width, glyph.height))
    let size = CGSize(width: CGFloat(glyph.width) * scale, height: CGFloat(glyph.height) * scale)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 12 / 1024), blur: s * 24 / 1024,
                  color: NSColor(red: 0.05, green: 0.25, blue: 0.5, alpha: 0.35).cgColor)
    ctx.draw(glyph, in: CGRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2,
                               width: size.width, height: size.height))
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! render(pixels: points * scale).write(to: iconset.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: iconset.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(iconset.path)")
