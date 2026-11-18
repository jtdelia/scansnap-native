import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import Testing
@testable import YomiKit

/// Photo scan profiles rotate prints upright by faces first, then text, and otherwise leave them as fed.
@Suite(.serialized)
struct PhotoRotationTests {
    /// An upright snapshot of three people, AI-generated so it shows no real person.
    private static func familyPrint() throws -> CGImage {
        let url = try #require(Bundle.module.url(forResource: "family-print", withExtension: "jpg", subdirectory: "Fixtures"))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private static func oriented(_ image: CGImage, _ orientation: CGImagePropertyOrientation) throws -> CGImage {
        let rotated = CIImage(cgImage: image).oriented(orientation)
        return try #require(CIContext().createCGImage(rotated, from: rotated.extent))
    }

    private static func photoOptions() -> ProcessingOptions {
        var options = ProcessingOptions()
        options.cropAndStraighten = false
        options.whiteBalance = false
        options.documentTone = false
        options.colorMode = .color
        options.skipBlankPages = false
        options.autoRotate = false
        options.rotateByFaces = true
        return options
    }

    /// 16 × 12 grey thumbnail, for comparing images that should show the same picture.
    private static func thumbnail(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 16 * 12)
        let context = try #require(CGContext(data: &pixels, width: 16, height: 12, bitsPerComponent: 8, bytesPerRow: 16,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 12))
        return pixels
    }

    private static func looksLike(_ image: CGImage, _ reference: CGImage) throws -> Bool {
        guard image.width == reference.width, image.height == reference.height else { return false }
        let difference = zip(try thumbnail(image), try thumbnail(reference)).map { abs(Int($0) - Int($1)) }
        return Double(difference.reduce(0, +)) / Double(difference.count) < 8
    }

    private static func processedPhoto(_ image: CGImage) async throws -> CGImage {
        try await offTheTaskPool {
            try PageProcessor.process(image, resolution: 300, side: .front, options: photoOptions()).image
        }
    }

    @Test(arguments: [CGImagePropertyOrientation.up, .down, .left, .right])
    func printWithFacesComesOutUpright(fed: CGImagePropertyOrientation) async throws {
        let upright = try Self.familyPrint()
        let image = try await Self.processedPhoto(try Self.oriented(upright, fed))
        #expect(try Self.looksLike(image, upright))
    }

    /// A landscape print with no faces and no writing: sky over a field, darker towards the top.
    private static func landscapePrint() throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 900, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for row in 0..<600 {
            let t = CGFloat(row) / 600
            context.setFillColor(row < 220 ? CGColor(red: 0.3, green: 0.55 + 0.2 * t, blue: 0.25, alpha: 1)
                : CGColor(red: 0.85 - 0.4 * t, green: 0.9 - 0.3 * t, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: row, width: 900, height: 1))
        }
        return try #require(context.makeImage())
    }

    @Test(arguments: [CGImagePropertyOrientation.down, .left])
    func printWithNeitherFacesNorTextIsLeftAsFed(fed: CGImagePropertyOrientation) async throws {
        let asFed = try Self.oriented(try Self.landscapePrint(), fed)
        let image = try await Self.processedPhoto(asFed)
        #expect(try Self.looksLike(image, asFed))
    }

    /// A print of a handwritten-style note: dark lines of text on cream paper, no faces.
    private static func notePrint(lineCount: Int = 6) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 1200, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(frame)
        context.setFillColor(CGColor(red: 0.95, green: 0.92, blue: 0.85, alpha: 1))
        context.fill(frame.insetBy(dx: 30, dy: 30))
        let font = CTFontCreateWithName("Helvetica" as CFString, 56, nil)
        let lines = ["Grandma's birthday party", "at the lake house, June", "with everyone from town",
                     "and the dog, who ate", "most of the cake before", "anyone else had a slice"]
        for (index, text) in lines.prefix(lineCount).enumerated() {
            let string = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
            ])
            context.textPosition = CGPoint(x: 80, y: 760 - index * 130)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        return try #require(context.makeImage())
    }

    @Test func printWithTextButNoFacesIsRotatedByText() async throws {
        let upright = try Self.notePrint()
        let image = try await Self.processedPhoto(try Self.oriented(upright, .right))
        #expect(try Self.looksLike(image, upright))
    }

    @Test(arguments: [(CGImagePropertyOrientation.up, CGImagePropertyOrientation.up),
                      (.down, .down), (.left, .right), (.right, .left)])
    func fastRecognitionOrientsShortNotes(fed: CGImagePropertyOrientation, expected: CGImagePropertyOrientation) async throws {
        let asFed = try Self.oriented(try Self.notePrint(lineCount: 2), fed)
        let correction = try await offTheTaskPool { try OrientationDetector.fastTextOrientation(asFed) }
        #expect((correction ?? .up) == expected)
    }

    @Test func uprightFacesTakePriorityOverSidewaysText() async throws {
        let note = CIImage(cgImage: try Self.notePrint(lineCount: 2))
        let faces = CIImage(cgImage: try Self.familyPrint()).oriented(.left)
            .transformed(by: CGAffineTransform(translationX: 710, y: 100))
        let print = faces.composited(over: note)
        let composite = try #require(CIContext().createCGImage(print, from: note.extent))
        let asFed = try Self.oriented(composite, .right)
        let image = try await Self.processedPhoto(asFed)
        #expect(try Self.looksLike(image, asFed))
    }

    @Test(arguments: [CGImagePropertyOrientation.up, .down, .left, .right], [false, true])
    func shortNoteComesOutUpright(fed: CGImagePropertyOrientation, photo: Bool) async throws {
        let upright = try Self.notePrint(lineCount: 2)
        let asFed = try Self.oriented(upright, fed)
        let image = try await offTheTaskPool {
            let profile = photo ? ScanProfile.builtInPhotoProfiles[0] : ScanProfile(name: "Document")
            return try PageProcessor.process(asFed, resolution: 300, side: .front, options: profile.processingOptions).image
        }
        #expect(image.width > image.height)
        let pixels = try Self.thumbnail(image).map(Int.init)
        let half = pixels.count / 2
        let top = pixels.prefix(half).reduce(0, +)
        let bottom = pixels.suffix(half).reduce(0, +)
        #expect(top < bottom)
    }
}
