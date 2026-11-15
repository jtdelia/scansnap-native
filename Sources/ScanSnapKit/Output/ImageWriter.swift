import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageWriterError: Error {
    case cannotCreateImage
    case cannotWrite(URL)
}

extension ScannedPage {
    public func cgImage() throws -> CGImage {
        guard width > 0, height > 0,
              let provider = CGDataProvider(data: Data(rgb) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                  bytesPerRow: width * 3, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw ImageWriterError.cannotCreateImage }
        return image
    }
}

public enum ImageWriter {
    public static func write(_ image: CGImage, to url: URL, type: UTType = .png, resolution: Int,
                             quality: Double = 0.85) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImageWriterError.cannotWrite(url)
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: resolution,
            kCGImagePropertyDPIHeight: resolution,
            kCGImageDestinationLossyCompressionQuality: quality,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageWriterError.cannotWrite(url) }
    }
}
