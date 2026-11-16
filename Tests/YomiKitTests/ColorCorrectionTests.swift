import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import YomiKit

/// Colour correction with a macOS system colour profile standing in for Fujitsu's.
struct ColorCorrectionTests {
    private static let adobeRGB = CGColorSpace(name: CGColorSpace.adobeRGB1998)!
    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    /// A 3 × 4 inch off-white print at 300 dpi on the scanner's dark backing, with a saturated
    /// green patch in the middle.
    private static func syntheticPrint() -> ScannedPage {
        let width = 1000, height = 1300, margin = 50
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let onPage = x >= margin && x < width - margin && y >= margin && y < height - margin
                let inPatch = abs(x - width / 2) < 200 && abs(y - height / 2) < 200
                let pixel: (UInt8, UInt8, UInt8) = !onPage ? (38, 38, 40) : inPatch ? (0, 255, 0) : (236, 232, 224)
                let i = (y * width + x) * 3
                rgb[i] = pixel.0
                rgb[i + 1] = pixel.1
                rgb[i + 2] = pixel.2
            }
        }
        return ScannedPage(side: .front, sheetIndex: 0, width: width, height: height, resolution: 300, rgb: rgb)
    }

    private static func photoOptions(colorProfile: CGColorSpace?) -> ProcessingOptions {
        var options = ProcessingOptions()
        options.colorMode = .color
        options.documentTone = false
        options.autoRotate = false
        options.colorProfile = colorProfile
        return options
    }

    /// The pixel at a fraction of the image's width and height, as Display P3 RGB.
    private static func p3Pixel(_ image: CGImage, x: Double, y: Double) throws -> [Int] {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: displayP3, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let px = Double(image.width) * x, py = Double(image.height) * (1 - y)
        context.draw(image, in: CGRect(x: -px, y: -py, width: Double(image.width), height: Double(image.height)))
        return pixel.prefix(3).map(Int.init)
    }

    @Test func correctedPageIsDisplayP3AndDiffersFromSRGB() throws {
        let corrected = try PageProcessor.process(Self.syntheticPrint(), options: Self.photoOptions(colorProfile: Self.adobeRGB))
        let uncorrected = try PageProcessor.process(Self.syntheticPrint(), options: Self.photoOptions(colorProfile: nil))

        #expect(corrected.image.colorSpace?.name == CGColorSpace.displayP3)
        #expect(uncorrected.image.colorSpace?.name == CGColorSpace.sRGB)
        // sRGB green is about (117, 252, 76) in Display P3; Adobe RGB green lies at P3's green edge.
        let green = try Self.p3Pixel(corrected.image, x: 0.5, y: 0.5)
        let srgbGreen = try Self.p3Pixel(uncorrected.image, x: 0.5, y: 0.5)
        #expect(srgbGreen[0] > 100)
        #expect(green[0] < 40)
        #expect(green[1] > 240)
    }

    @Test func correctionKeepsThePaperColor() throws {
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let corrected = try PageProcessor.process(Self.syntheticPrint(), options: Self.photoOptions(colorProfile: srgb))
        var document = Self.photoOptions(colorProfile: nil)
        document.flattenColumns = false
        document.documentTone = true
        let whitened = try PageProcessor.process(Self.syntheticPrint(), options: document)

        // The paper is (236, 232, 224); white balance and the tone curve push it to white.
        let paper = try Self.p3Pixel(corrected.image, x: 0.1, y: 0.1)
        #expect(try Self.p3Pixel(whitened.image, x: 0.1, y: 0.1).allSatisfy { $0 > 245 })
        #expect(paper[2] < 232)
        #expect(paper[0] > 225)
    }

    // MARK: Batches

    private static func temporaryFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A folder holding a macOS colour profile in place of Fujitsu's.
    private static func profileFolder() throws -> URL {
        let dir = try temporaryFolder()
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/AdobeRGB1998.icc"),
                                         to: dir.appendingPathComponent("ScanSnap S1300.icm"))
        return dir
    }

    private static func photoProfile(correctColor: Bool) throws -> ScanProfile {
        ScanProfile(name: "Prints", folderPath: try temporaryFolder().path, colorMode: .color, sides: .simplex,
                    skipBlankPages: false, reduceBleedThrough: false, autoRotate: false, fileFormat: .jpeg,
                    correctColor: correctColor)
    }

    /// Scans one synthetic sheet the way a batch does and returns the colour space of the saved file.
    private static func savedColorSpace(_ profile: ScanProfile, correction: ColorCorrection) throws -> String? {
        let sheet = try SheetProcessor.process(front: syntheticPrint(), back: syntheticPrint(), profile: profile,
                                               colorProfile: correction.colorSpace)
        let file = try #require(try DocumentWriter.save(sheet.pages, profile: profile).first)
        let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return image.colorSpace?.name as String?
    }

    @Test func batchWithAColorProfileSavesDisplayP3() throws {
        let profile = try Self.photoProfile(correctColor: true)
        let correction = ColorCorrection.forBatch(profile, searching: [try Self.profileFolder()])
        #expect(correction.notice == nil)
        #expect(try Self.savedColorSpace(profile, correction: correction) == CGColorSpace.displayP3 as String)
    }

    @Test func batchCorrectionKeepsThePaperColor() throws {
        let srgb = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let sheet = try SheetProcessor.process(front: Self.syntheticPrint(), back: Self.syntheticPrint(),
                                               profile: try Self.photoProfile(correctColor: true), colorProfile: srgb)
        let page = try #require(sheet.pages.first)
        let paper = try Self.p3Pixel(page.image, x: 0.1, y: 0.1)
        #expect(paper[2] < 232)
        #expect(paper[0] > 225)
    }

    @Test func batchWithoutAColorProfileSavesSRGBAndWarns() throws {
        let profile = try Self.photoProfile(correctColor: true)
        let correction = ColorCorrection.forBatch(profile, searching: [try Self.temporaryFolder()])
        #expect(correction.notice == "Color correction was skipped: the scanner's color profile was not found.")
        #expect(try Self.savedColorSpace(profile, correction: correction) == CGColorSpace.sRGB as String)
    }

    @Test func batchWithCorrectionOffIgnoresTheColorProfile() throws {
        let profile = try Self.photoProfile(correctColor: false)
        let correction = ColorCorrection.forBatch(profile, searching: [try Self.profileFolder()])
        #expect(correction.colorSpace == nil)
        #expect(correction.notice == nil)
    }
}
