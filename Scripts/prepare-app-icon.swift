import CoreGraphics
import Foundation
import ImageIO

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2, arguments.count.isMultiple(of: 2) else {
    fatalError("Usage: prepare-app-icon.swift input.png output.png [input.png output.png ...]")
}

for index in stride(from: 0, to: arguments.count, by: 2) {
    let inputURL = URL(fileURLWithPath: arguments[index])
    let outputURL = URL(fileURLWithPath: arguments[index + 1])
    guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width == image.height else {
        fatalError("Could not read square app icon at \(inputURL.path)")
    }

    let size = image.width
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create icon drawing context")
    }

    let canvasBounds = CGRect(x: 0, y: 0, width: size, height: size)
    let tileScale = 840.0 / 1024.0
    let tileInset = CGFloat(size) * (1 - tileScale) / 2
    let tileBounds = canvasBounds.insetBy(dx: tileInset, dy: tileInset)
    let radius = tileBounds.width * 0.205
    let roundedShape = CGPath(roundedRect: tileBounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.addPath(roundedShape)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillPath()
    context.saveGState()
    context.addPath(roundedShape)
    context.clip()
    let artworkScale = 0.86
    // The supplied artwork already reaches the left and bottom edges of its
    // canvas. Keep those edges against the tile wall rather than introducing
    // extra horizontal or bottom margins by centering the scaled artwork.
    let artworkBounds = CGRect(
        x: tileBounds.minX,
        y: tileBounds.minY,
        width: tileBounds.width * artworkScale,
        height: tileBounds.height * artworkScale
    )
    context.draw(image, in: artworkBounds)
    context.restoreGState()

    guard let roundedImage = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("Could not create rounded app icon at \(outputURL.path)")
    }
    CGImageDestinationAddImage(destination, roundedImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Could not write rounded app icon to \(outputURL.path)")
    }
}
