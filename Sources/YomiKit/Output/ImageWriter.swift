import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageWriterError: Error {
    case cannotCreateImage
    case cannotWrite(URL)
}

extension ScannedPage {
    public func cgImage(colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!) throws -> CGImage {
        guard width > 0, height > 0,
              let provider = CGDataProvider(data: Data(rgb) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                  bytesPerRow: width * 3, space: colorSpace,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw ImageWriterError.cannotCreateImage }
        return image
    }
}

public enum ImageWriter {
    public static func write(_ image: CGImage, to url: URL, type: UTType = .png, resolution: Int,
                             quality: Double = 0.85, caption: String? = nil) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImageWriterError.cannotWrite(url)
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: resolution,
            kCGImagePropertyDPIHeight: resolution,
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        addImage(image, to: destination, properties: properties, caption: caption)
        guard CGImageDestinationFinalize(destination) else { throw ImageWriterError.cannotWrite(url) }
    }

    /// Adds `image`, with `caption` in the fields Photos reads as the caption on import and Spotlight indexes
    /// for Finder search: IPTC Caption-Abstract, XMP dc:description and TIFF ImageDescription.
    static func addImage(_ image: CGImage, to destination: CGImageDestination, properties: [CFString: Any],
                         caption: String?) {
        guard let caption else {
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            return
        }
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyIPTCDictionary,
                                                     kCGImagePropertyIPTCCaptionAbstract, caption as CFString)
        CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                     kCGImagePropertyTIFFImageDescription, caption as CFString)
        CGImageDestinationAddImageAndMetadata(destination, image, metadata, properties as CFDictionary)
    }
}
