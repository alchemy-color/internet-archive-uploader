#!/usr/bin/env swift
// Generates the AppIcon asset for the macOS app.
// Usage: swift Scripts/make_icon.swift <output-directory>

import AppKit
import CoreGraphics

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "IAUploader/Resources/Assets.xcassets/AppIcon.appiconset"

let fileManager = FileManager.default
try? fileManager.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

func render(size: Int, to path: String) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return }

    guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let cg = graphics.cgContext
    cg.setAllowsAntialiasing(true)
    cg.interpolationQuality = .high

    let s = CGFloat(size)
    let inset = s * 0.055
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225

    // Background.
    let rounded = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    cg.saveGState()
    cg.addPath(rounded)
    cg.clip()

    let colors = [
        CGColor(red: 0.24, green: 0.46, blue: 0.78, alpha: 1.0),
        CGColor(red: 0.10, green: 0.27, blue: 0.55, alpha: 1.0),
        CGColor(red: 0.035, green: 0.12, blue: 0.27, alpha: 1.0)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1]) {
        cg.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.minX, y: rect.maxY),
            end: CGPoint(x: rect.maxX, y: rect.minY),
            options: []
        )
    }

    // Soft top highlight.
    let highlight = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.20),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
        ] as CFArray,
        locations: [0, 1]
    )
    if let highlight {
        cg.drawRadialGradient(
            highlight,
            startCenter: CGPoint(x: rect.midX, y: rect.maxY * 0.92),
            startRadius: 0,
            endCenter: CGPoint(x: rect.midX, y: rect.maxY * 0.92),
            endRadius: rect.width * 0.72,
            options: []
        )
    }
    cg.restoreGState()

    // Temple of the archive.
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    cg.setFillColor(white)
    cg.setStrokeColor(white)

    let cx = rect.midX
    let baseY = rect.minY + rect.height * 0.245
    let bodyWidth = rect.width * 0.56
    let columnTop = rect.minY + rect.height * 0.545

    let baseHeight = rect.height * 0.038
    let base = CGPath(
        roundedRect: CGRect(x: cx - bodyWidth * 0.62, y: baseY, width: bodyWidth * 1.24, height: baseHeight),
        cornerWidth: baseHeight * 0.4,
        cornerHeight: baseHeight * 0.4,
        transform: nil
    )
    cg.addPath(base)
    cg.fillPath()

    let columnWidth = bodyWidth * 0.145
    let columnHeight = columnTop - (baseY + baseHeight)
    let offsets: [CGFloat] = [-0.34, 0, 0.34]
    for offset in offsets {
        let columnRect = CGRect(
            x: cx + bodyWidth * offset - columnWidth / 2,
            y: baseY + baseHeight + rect.height * 0.008,
            width: columnWidth,
            height: columnHeight
        )
        let column = CGPath(roundedRect: columnRect, cornerWidth: columnWidth * 0.42, cornerHeight: columnWidth * 0.42, transform: nil)
        cg.addPath(column)
        cg.fillPath()
    }

    // Architrave.
    let lintelHeight = rect.height * 0.035
    let lintel = CGPath(
        roundedRect: CGRect(
            x: cx - bodyWidth * 0.58,
            y: columnTop,
            width: bodyWidth * 1.16,
            height: lintelHeight
        ),
        cornerWidth: lintelHeight * 0.35,
        cornerHeight: lintelHeight * 0.35,
        transform: nil
    )
    cg.addPath(lintel)
    cg.fillPath()

    // Pediment.
    let roofY = columnTop + lintelHeight
    cg.beginPath()
    cg.move(to: CGPoint(x: cx, y: roofY + rect.height * 0.175))
    cg.addLine(to: CGPoint(x: cx + bodyWidth * 0.66, y: roofY + rect.height * 0.005))
    cg.addLine(to: CGPoint(x: cx - bodyWidth * 0.66, y: roofY + rect.height * 0.005))
    cg.closePath()
    cg.fillPath()

    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for entry in sizes {
    render(size: entry.pixels, to: "\(outputDirectory)/\(entry.name)")
}

print("Wrote \(sizes.count) icon files to \(outputDirectory)")
