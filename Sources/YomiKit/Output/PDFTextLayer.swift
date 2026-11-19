import CoreGraphics
import CoreText
import Foundation
import Vision

enum PDFTextLayer {
    static func draw(_ image: CGImage, in box: CGRect, context: CGContext) throws {
        drawInvisibleText(try recognizeText(in: image), in: box, context: context)
    }

    static func draw(_ page: RecognizedPage, in box: CGRect, context: CGContext) {
        for document in page.documents {
            let lines = document.text.lines.map { line in
                let start = line.topLeft.cgPoint
                let end = line.topRight.cgPoint
                let runsDown = (start.y - end.y) * box.height > abs(end.x - start.x) * box.width
                return RecognizedLine(text: line.transcript, box: line.boundingBox.cgRect,
                                      direction: runsDown ? .topToBottom : line.textDirection)
            }
            drawInvisibleText(lines, in: box, context: context)
        }
    }

    struct RecognizedLine {
        let text: String
        let box: CGRect
        var direction: RecognizedTextObservation.Direction? = .leftToRight
    }

    private struct RecognitionFailure: Error, CustomStringConvertible {
        let cause: Error

        var description: String { "Vision text recognition: \(String(reflecting: cause))" }
    }

    private static func recognizeText(in image: CGImage) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw RecognitionFailure(cause: error)
        }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedLine(text: candidate.string, box: observation.boundingBox)
        }
    }

    static func drawInvisibleText(_ lines: [RecognizedLine], in page: CGRect, context: CGContext) {
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in lines where !line.text.isEmpty {
            let rect = CGRect(x: page.minX + line.box.minX * page.width,
                              y: page.minY + line.box.minY * page.height,
                              width: line.box.width * page.width,
                              height: line.box.height * page.height)
            let vertical = line.direction.map { $0 == .topToBottom } ?? (rect.height > 2 * rect.width)
            let length = vertical ? rect.height : rect.width
            let thickness = vertical ? rect.width : rect.height
            let font = CTFontCreateWithName("Helvetica" as CFString, max(thickness * 0.85, 1), nil)
            let attributed = NSAttributedString(string: line.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let naturalWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard naturalWidth > 0 else { continue }
            context.saveGState()
            if vertical {
                context.translateBy(x: rect.minX + thickness * 0.15, y: rect.maxY)
                context.rotate(by: -.pi / 2)
            } else {
                context.translateBy(x: rect.minX, y: rect.minY + thickness * 0.15)
            }
            context.scaleBy(x: length / naturalWidth, y: 1)
            context.textPosition = .zero
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
        context.restoreGState()
    }
}
