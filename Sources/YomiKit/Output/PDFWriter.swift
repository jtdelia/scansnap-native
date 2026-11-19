import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

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
        for (index, page) in pages.enumerated() {
            progress?(index)
            let image = try jpegBacked(page.image, quality: jpegQuality)
            let points = 72.0 / Double(page.resolution)
            var box = CGRect(x: 0, y: 0, width: Double(image.width) * points, height: Double(image.height) * points)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            if searchable {
                drawInvisibleText(recognizeText(in: page.image), in: box, context: context)
            }
            context.endPage()
        }
        context.closePDF()
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

    // MARK: Text layer

    private struct RecognizedLine {
        let text: String
        /// Normalized, bottom-left origin.
        let box: CGRect
    }

    private static func recognizeText(in image: CGImage) -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedLine(text: candidate.string, box: observation.boundingBox)
        }
    }

    private static func drawInvisibleText(_ lines: [RecognizedLine], in page: CGRect, context: CGContext) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in lines where !line.text.isEmpty {
            let rect = CGRect(x: page.minX + line.box.minX * page.width,
                              y: page.minY + line.box.minY * page.height,
                              width: line.box.width * page.width,
                              height: line.box.height * page.height)
            let font = CTFontCreateWithName("Helvetica" as CFString, max(rect.height * 0.85, 1), nil)
            let attributed = NSAttributedString(string: line.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let naturalWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard naturalWidth > 0 else { continue }
            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY + rect.height * 0.15)
            context.scaleBy(x: rect.width / naturalWidth, y: 1)
            context.textPosition = .zero
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
        context.restoreGState()
    }
}
