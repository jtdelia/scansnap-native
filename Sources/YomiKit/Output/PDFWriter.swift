import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PDFWriter {
    /// Writes pages as JPEG-compressed images, one PDF page per image, sized from the scan
    /// resolution. With `searchable`, recognized text is drawn invisibly over each page.
    public static func write(_ pages: [ProcessedPage], to url: URL, jpegQuality: Double = 0.75,
                             searchable: Bool = false, progress: ((Int) -> Void)? = nil) throws {
        guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw ImageWriterError.cannotWrite(url)
        }
        try write(pages, in: context, jpegQuality: jpegQuality, searchable: searchable, progress: progress)
    }

    static func write(_ pages: [ProcessedPage], in context: CGContext, jpegQuality: Double,
                      searchable: Bool, progress: ((Int) -> Void)?) throws {
        try write(pages: pages.count, in: context, jpegQuality: jpegQuality, progress: progress,
                  textLayer: searchable ? { try? PDFTextLayer.draw($0, in: $1, context: $2) } : nil) { index in
            (pages[index].image, pages[index].resolution)
        }
    }

    static func write(pages count: Int, in context: CGContext, jpegQuality: Double, progress: ((Int) -> Void)? = nil,
                      textLayer: ((CGImage, CGRect, CGContext) throws -> Void)?,
                      pageAt: (Int) throws -> (image: CGImage, resolution: Int)) throws {
        defer { context.closePDF() }
        for index in 0..<count {
            try autoreleasepool {
                progress?(index)
                let page = try pageAt(index)
                let image = try jpegBacked(page.image, quality: jpegQuality)
                let points = 72.0 / Double(page.resolution)
                var box = CGRect(x: 0, y: 0, width: Double(image.width) * points, height: Double(image.height) * points)
                context.beginPage(mediaBox: &box)
                defer { context.endPage() }
                context.draw(image, in: box)
                try textLayer?(page.image, box, context)
            }
        }
    }

    /// Re-decodes through JPEG so Core Graphics embeds compact DCT data instead of raw pixels.
    static func jpegBacked(_ image: CGImage, quality: Double) throws -> CGImage {
        let data = try jpegData(image, quality: quality)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw ImageWriterError.cannotCreateImage }
        return decoded
    }

    static func jpegData(_ image: CGImage, quality: Double) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageWriterError.cannotCreateImage
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageWriterError.cannotCreateImage }
        return data as Data
    }
}
