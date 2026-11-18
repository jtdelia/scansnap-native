import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum TIFFWriter {
    /// TIFF tag value for LZW, which is lossless for colour, grey and black-and-white pages.
    private static let lzwCompression = 5

    /// Writes every page into one TIFF file, in order, each at its own scan resolution.
    public static func write(_ pages: [ProcessedPage], to url: URL, progress: ((Int) -> Void)? = nil) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.tiff.identifier as CFString, pages.count, nil)
        else { throw ImageWriterError.cannotWrite(url) }
        add(pages, to: destination, progress: progress)
        guard CGImageDestinationFinalize(destination) else { throw ImageWriterError.cannotWrite(url) }
    }

    static func add(_ pages: [ProcessedPage], to destination: CGImageDestination, progress: ((Int) -> Void)?) {
        for (index, page) in pages.enumerated() {
            progress?(index)
            let properties: [CFString: Any] = [
                kCGImagePropertyDPIWidth: page.resolution,
                kCGImagePropertyDPIHeight: page.resolution,
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: lzwCompression],
            ]
            ImageWriter.addImage(page.image, to: destination, properties: properties, caption: page.caption)
        }
    }
}
