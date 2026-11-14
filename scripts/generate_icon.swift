#!/usr/bin/env swift
import AppKit
import Foundation

struct IconSpec {
    let size: Int
    let scale: Int
    var pixelSize: Int { size * scale }
    var filename: String {
        scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
    }
}

let specs: [IconSpec] = [
    IconSpec(size: 16, scale: 1),
    IconSpec(size: 16, scale: 2),
    IconSpec(size: 32, scale: 1),
    IconSpec(size: 32, scale: 2),
    IconSpec(size: 128, scale: 1),
    IconSpec(size: 128, scale: 2),
    IconSpec(size: 256, scale: 1),
    IconSpec(size: 256, scale: 2),
    IconSpec(size: 512, scale: 1),
    IconSpec(size: 512, scale: 2),
]

func renderIcon(pixelSize: Int) -> Data? {
    let s = CGFloat(pixelSize)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context
    let cg = context.cgContext

    // Transparent canvas
    cg.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // macOS Big Sur+ squircle pad (inset ~9.7% each side)
    let inset = s * 0.09765625
    let cardRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = cardRect.width * 0.2237

    // Drop shadow
    cg.saveGState()
    cg.setShadow(
        offset: CGSize(width: 0, height: -s * 0.015),
        blur: s * 0.03,
        color: NSColor.black.withAlphaComponent(0.32).cgColor
    )
    let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor.black.setFill()
    cardPath.fill()
    cg.restoreGState()

    // Clip to squircle for gradient fill
    cg.saveGState()
    cardPath.addClip()

    // Deep teal-to-indigo gradient
    let colors = [
        NSColor(calibratedRed: 0.05, green: 0.14, blue: 0.28, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.07, green: 0.36, blue: 0.56, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.14, green: 0.68, blue: 0.78, alpha: 1.0).cgColor,
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 0.55, 1.0]) {
        cg.drawLinearGradient(
            gradient,
            start: CGPoint(x: cardRect.minX, y: cardRect.minY),
            end: CGPoint(x: cardRect.maxX, y: cardRect.maxY),
            options: []
        )
    }

    // Subtle radial glow at top-center
    let glowColors = [
        NSColor.white.withAlphaComponent(0.24).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor,
    ] as CFArray
    if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors, locations: [0.0, 1.0]) {
        cg.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: s * 0.5, y: s * 0.78),
            startRadius: 0,
            endCenter: CGPoint(x: s * 0.5, y: s * 0.78),
            endRadius: s * 0.55,
            options: []
        )
    }

    // Subtle inner top highlight border
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
    cg.setLineWidth(max(1.0, s * 0.012))
    cg.addPath(cardPath.cgPath)
    cg.strokePath()

    // Orbital CDN ring accent behind the arrow
    let center = CGPoint(x: s * 0.5, y: s * 0.52)
    let ringRadius = s * 0.245
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
    cg.setLineWidth(max(1.5, s * 0.022))
    cg.addArc(center: center, radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    cg.strokePath()

    // Download arrow shaft + chevron + tray (crisp white)
    let strokeWidth = max(2.0, s * 0.068)
    cg.setStrokeColor(NSColor.white.cgColor)
    cg.setLineWidth(strokeWidth)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)

    // Vertical shaft
    let topY = s * 0.69
    let tipY = s * 0.42
    cg.move(to: CGPoint(x: s * 0.5, y: topY))
    cg.addLine(to: CGPoint(x: s * 0.5, y: tipY))
    cg.strokePath()

    // Arrowhead
    let headHalfW = s * 0.145
    let headTopY = s * 0.54
    cg.move(to: CGPoint(x: s * 0.5 - headHalfW, y: headTopY))
    cg.addLine(to: CGPoint(x: s * 0.5, y: tipY))
    cg.addLine(to: CGPoint(x: s * 0.5 + headHalfW, y: headTopY))
    cg.strokePath()

    // Bottom tray bar
    let trayY = s * 0.30
    let trayHalfW = s * 0.19
    let trayRise = s * 0.055
    cg.move(to: CGPoint(x: s * 0.5 - trayHalfW, y: trayY + trayRise))
    cg.addLine(to: CGPoint(x: s * 0.5 - trayHalfW, y: trayY))
    cg.addLine(to: CGPoint(x: s * 0.5 + trayHalfW, y: trayY))
    cg.addLine(to: CGPoint(x: s * 0.5 + trayHalfW, y: trayY + trayRise))
    cg.strokePath()

    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo: path.move(to: points[0])
            case .lineTo: path.addLine(to: points[0])
            case .curveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .cubicCurveTo: path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: path.addQuadCurve(to: points[1], control: points[0])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

let outputDir = CommandLine.arguments.dropFirst().first ?? "PixeldrainDownloader/Assets.xcassets/AppIcon.appiconset"
let fm = FileManager.default
try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

var imagesJSON: [[String: Any]] = []
for spec in specs {
    guard let data = renderIcon(pixelSize: spec.pixelSize) else {
        fputs("Failed to render \(spec.filename)\n", stderr)
        exit(1)
    }
    let path = (outputDir as NSString).appendingPathComponent(spec.filename)
    try data.write(to: URL(fileURLWithPath: path))
    imagesJSON.append([
        "filename": spec.filename,
        "idiom": "mac",
        "scale": "\(spec.scale)x",
        "size": "\(spec.size)x\(spec.size)",
    ])
}

let contents: [String: Any] = [
    "images": imagesJSON,
    "info": ["author": "xcode", "version": 1],
]
let jsonData = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
let contentsPath = (outputDir as NSString).appendingPathComponent("Contents.json")
try jsonData.write(to: URL(fileURLWithPath: contentsPath))
print("Generated AppIcon.appiconset in \(outputDir)")
