import Foundation
import ImageIO

enum PhotoMetadataExtractor {
    static func extract(from data: Data) -> [String: String] {
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return [:] }
        return extract(from: source)
    }

    private static var sourceOptions: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }

    private static func extract(from source: CGImageSource) -> [String: String] {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        var result: [String: String] = [:]
        func add(_ label: String, _ value: Any?) {
            guard let value else { return }
            let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result[label] = text }
        }
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        add("Dimensions", dimensions(width: properties[kCGImagePropertyPixelWidth], height: properties[kCGImagePropertyPixelHeight]))
        add("Camera make", tiff[kCGImagePropertyTIFFMake])
        add("Camera model", tiff[kCGImagePropertyTIFFModel])
        add("Captured", exif[kCGImagePropertyExifDateTimeOriginal] ?? tiff[kCGImagePropertyTIFFDateTime])
        add("Lens", exif[kCGImagePropertyExifLensModel])
        add("Focal length", exif[kCGImagePropertyExifFocalLength].map { "\($0) mm" })
        add("Exposure", exif[kCGImagePropertyExifExposureTime].map { "\($0) s" })
        add("Aperture", exif[kCGImagePropertyExifFNumber].map { "f/\($0)" })
        add("ISO", exif[kCGImagePropertyExifISOSpeedRatings])
        return result
    }

    private static func dimensions(width: Any?, height: Any?) -> String? {
        guard let width, let height else { return nil }
        return "\(width) × \(height)"
    }
}
