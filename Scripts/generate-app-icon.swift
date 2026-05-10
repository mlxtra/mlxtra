import AppKit
import CoreGraphics
import Foundation

let outputPath = CommandLine.arguments.dropFirst().first ?? "MLXHub/Resources/Assets.xcassets/AppIcon.appiconset"
let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

struct RGBA {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    var color: CGColor {
        CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }
}

func drawRoundedRect(
    in context: CGContext,
    rect: CGRect,
    radius: CGFloat,
    fill: CGColor,
    stroke: CGColor? = nil,
    lineWidth: CGFloat = 1
) {
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.addPath(path)
    context.setFillColor(fill)
    context.fillPath()

    if let stroke {
        context.addPath(path)
        context.setStrokeColor(stroke)
        context.setLineWidth(lineWidth)
        context.strokePath()
    }
}

func drawNode(in context: CGContext, center: CGPoint, radius: CGFloat, fill: CGColor, stroke: CGColor) {
    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    context.setShadow(offset: CGSize(width: 0, height: -radius * 0.18), blur: radius * 0.35, color: RGBA(red: 0, green: 42, blue: 120, alpha: 0.22).color)
    context.setFillColor(fill)
    context.fillEllipse(in: rect)
    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.setStrokeColor(stroke)
    context.setLineWidth(max(1, radius * 0.22))
    context.strokeEllipse(in: rect.insetBy(dx: radius * 0.08, dy: radius * 0.08))
}

func drawSpark(in context: CGContext, center: CGPoint, size: CGFloat) {
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    let path = CGMutablePath()
    let points: [CGPoint] = [
        CGPoint(x: 0, y: size),
        CGPoint(x: size * 0.18, y: size * 0.18),
        CGPoint(x: size, y: 0),
        CGPoint(x: size * 0.18, y: -size * 0.18),
        CGPoint(x: 0, y: -size),
        CGPoint(x: -size * 0.18, y: -size * 0.18),
        CGPoint(x: -size, y: 0),
        CGPoint(x: -size * 0.18, y: size * 0.18)
    ]
    path.addLines(between: points)
    path.closeSubpath()
    context.setFillColor(RGBA(red: 245, green: 252, blue: 255, alpha: 0.96).color)
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.08), blur: size * 0.28, color: RGBA(red: 35, green: 150, blue: 255, alpha: 0.45).color)
    context.addPath(path)
    context.fillPath()
    context.restoreGState()
}

func renderIcon(pixelSize: Int) -> NSBitmapImageRep {
    let size = CGFloat(pixelSize)
    let rep = NSBitmapImageRep(
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
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let context = NSGraphicsContext.current?.cgContext else {
        fatalError("Unable to create CGContext")
    }

    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    let iconInset = size * 0.035
    let iconRect = canvas.insetBy(dx: iconInset, dy: iconInset)
    let iconRadius = size * 0.225
    let iconPath = CGPath(roundedRect: iconRect, cornerWidth: iconRadius, cornerHeight: iconRadius, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.018), blur: size * 0.035, color: RGBA(red: 0, green: 0, blue: 0, alpha: 0.22).color)
    context.addPath(iconPath)
    context.setFillColor(RGBA(red: 32, green: 90, blue: 255, alpha: 1).color)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(iconPath)
    context.clip()

    let baseGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            RGBA(red: 139, green: 231, blue: 255, alpha: 1).color,
            RGBA(red: 29, green: 129, blue: 255, alpha: 1).color,
            RGBA(red: 61, green: 63, blue: 219, alpha: 1).color,
            RGBA(red: 17, green: 20, blue: 77, alpha: 1).color
        ] as CFArray,
        locations: [0, 0.36, 0.69, 1]
    )!
    context.drawLinearGradient(
        baseGradient,
        start: CGPoint(x: iconRect.minX, y: iconRect.maxY),
        end: CGPoint(x: iconRect.maxX, y: iconRect.minY),
        options: []
    )

    let glowGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            RGBA(red: 255, green: 255, blue: 255, alpha: 0.26).color,
            RGBA(red: 255, green: 255, blue: 255, alpha: 0).color
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        glowGradient,
        startCenter: CGPoint(x: size * 0.20, y: size * 0.83),
        startRadius: 0,
        endCenter: CGPoint(x: size * 0.20, y: size * 0.83),
        endRadius: size * 0.68,
        options: .drawsAfterEndLocation
    )

    let lowerGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            RGBA(red: 11, green: 21, blue: 77, alpha: 0).color,
            RGBA(red: 7, green: 12, blue: 48, alpha: 0.34).color
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        lowerGradient,
        start: CGPoint(x: size * 0.5, y: size * 0.58),
        end: CGPoint(x: size * 0.5, y: iconRect.minY),
        options: []
    )

    let plate = CGRect(x: size * 0.205, y: size * 0.235, width: size * 0.59, height: size * 0.54)
    drawRoundedRect(
        in: context,
        rect: plate,
        radius: size * 0.12,
        fill: RGBA(red: 255, green: 255, blue: 255, alpha: 0.16).color,
        stroke: RGBA(red: 255, green: 255, blue: 255, alpha: 0.36).color,
        lineWidth: max(1, size * 0.012)
    )

    let innerPlate = plate.insetBy(dx: size * 0.028, dy: size * 0.028)
    drawRoundedRect(
        in: context,
        rect: innerPlate,
        radius: size * 0.09,
        fill: RGBA(red: 255, green: 255, blue: 255, alpha: 0.055).color
    )

    let path = CGMutablePath()
    let points = [
        CGPoint(x: size * 0.31, y: size * 0.36),
        CGPoint(x: size * 0.31, y: size * 0.64),
        CGPoint(x: size * 0.50, y: size * 0.43),
        CGPoint(x: size * 0.69, y: size * 0.64),
        CGPoint(x: size * 0.69, y: size * 0.36)
    ]
    path.move(to: points[0])
    points.dropFirst().forEach { path.addLine(to: $0) }

    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setShadow(offset: CGSize(width: 0, height: -size * 0.006), blur: size * 0.018, color: RGBA(red: 0, green: 17, blue: 82, alpha: 0.35).color)
    context.setStrokeColor(RGBA(red: 3, green: 35, blue: 115, alpha: 0.26).color)
    context.setLineWidth(size * 0.082)
    context.addPath(path)
    context.strokePath()
    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.setStrokeColor(RGBA(red: 250, green: 254, blue: 255, alpha: 0.96).color)
    context.setLineWidth(size * 0.052)
    context.addPath(path)
    context.strokePath()

    let nodeRadius = size * 0.041
    let nodeFill = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            RGBA(red: 255, green: 255, blue: 255, alpha: 1).color,
            RGBA(red: 185, green: 236, blue: 255, alpha: 1).color
        ] as CFArray,
        locations: [0, 1]
    )!
    for point in points {
        context.saveGState()
        context.addEllipse(in: CGRect(x: point.x - nodeRadius, y: point.y - nodeRadius, width: nodeRadius * 2, height: nodeRadius * 2))
        context.clip()
        context.drawLinearGradient(
            nodeFill,
            start: CGPoint(x: point.x - nodeRadius, y: point.y + nodeRadius),
            end: CGPoint(x: point.x + nodeRadius, y: point.y - nodeRadius),
            options: []
        )
        context.restoreGState()
        context.setStrokeColor(RGBA(red: 255, green: 255, blue: 255, alpha: 0.78).color)
        context.setLineWidth(max(1, size * 0.006))
        context.strokeEllipse(in: CGRect(x: point.x - nodeRadius, y: point.y - nodeRadius, width: nodeRadius * 2, height: nodeRadius * 2))
    }

    drawSpark(in: context, center: CGPoint(x: size * 0.735, y: size * 0.735), size: size * 0.043)

    context.restoreGState()

    context.addPath(iconPath)
    context.setStrokeColor(RGBA(red: 255, green: 255, blue: 255, alpha: 0.38).color)
    context.setLineWidth(max(1, size * 0.01))
    context.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for size in sizes {
    let rep = renderIcon(pixelSize: size)
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode \(size)px icon")
    }
    try pngData.write(to: outputURL.appendingPathComponent("Icon-\(size).png"))
}
