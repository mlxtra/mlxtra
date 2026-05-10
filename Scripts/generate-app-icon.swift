import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let outputPath = arguments.first ?? "MLXHub/Resources/Assets.xcassets/AppIcon.appiconset"
let sourcePath = arguments.dropFirst().first ?? "Scripts/IconSources/MLXHub-AppIcon-Source.png"

let outputURL = URL(fileURLWithPath: outputPath)
let sourceURL = URL(fileURLWithPath: sourcePath)

try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    fatalError("Unable to load app icon source at \(sourcePath)")
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
    context.interpolationQuality = .high
    sourceImage.draw(
        in: CGRect(x: 0, y: 0, width: size, height: size),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = renderIcon(pixelSize: size)
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode \(size)px icon")
    }
    try pngData.write(to: outputURL.appendingPathComponent("Icon-\(size).png"))
}
