import CoreGraphics
import Foundation
import Testing
@testable import YomiKit

/// Photo cropping on synthetic prints fed onto the scanner's dark backing.
struct PhotoCropTests {
    static let backing: (UInt8, UInt8, UInt8) = (38, 38, 40)
    static let frameColour: (UInt8, UInt8, UInt8) = (12, 12, 12)

    /// A print's base colour and a few patches of picture content.
    struct Tone: Sendable, CustomStringConvertible {
        let name: String
        let base: (UInt8, UInt8, UInt8)
        let patches: [(UInt8, UInt8, UInt8)]
        var description: String { name }

        static let light = Tone(name: "light", base: (240, 236, 228), patches: [(30, 30, 32), (180, 40, 45), (90, 120, 160)])
        static let dark = Tone(name: "dark", base: (16, 14, 12), patches: [(60, 42, 30), (4, 4, 4), (38, 38, 40)])
    }

    /// A print of `width` × `height` inches at `dpi`, turned by `skew` radians, on an 8.5 inch wide
    /// strip of backing with a little backing above and below, as the scanner sees it. `frame` draws
    /// a dark line of that many inches around the print's edge.
    static func scan(width: Double, height: Double, tone: Tone, skew: Double = 0, frame: Double = 0,
                     dpi: Int = 150) throws -> CGImage {
        let d = Double(dpi)
        let w = width * d, h = height * d
        let canvasWidth = Int(8.5 * d)
        let canvasHeight = Int((h * cos(abs(skew)) + w * sin(abs(skew)) + 0.6 * d).rounded())
        let context = try #require(CGContext(data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8,
                                             bytesPerRow: canvasWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        func fill(_ c: (UInt8, UInt8, UInt8)) {
            context.setFillColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1)
        }
        fill(backing)
        context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        // Slightly off centre, as the paper guides leave it.
        context.translateBy(x: Double(canvasWidth) / 2 + 0.2 * d, y: Double(canvasHeight) / 2)
        context.rotate(by: skew)
        if frame > 0 {
            fill(frameColour)
            context.fill(CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        }
        fill(tone.base)
        context.fill(CGRect(x: -w / 2, y: -h / 2, width: w, height: h).insetBy(dx: frame * d, dy: frame * d))
        let spots = [CGRect(x: -w / 2 + w * 0.1, y: -h / 2 + h * 0.6, width: w * 0.3, height: h * 0.25),
                     CGRect(x: w * 0.05, y: -h / 2 + h * 0.15, width: w * 0.35, height: h * 0.2),
                     CGRect(x: -w * 0.15, y: -h * 0.1, width: w * 0.3, height: h * 0.15)]
        for (rect, colour) in zip(spots, tone.patches) {
            fill(colour)
            context.fillEllipse(in: rect)
        }

        let data = try #require(context.data).bindMemory(to: UInt8.self, capacity: canvasWidth * canvasHeight * 4)
        var seed: UInt32 = 12345
        for i in 0..<(canvasWidth * canvasHeight * 4) where i % 4 != 3 {
            seed = seed &* 1_103_515_245 &+ 12345
            data[i] = UInt8(clamping: Int(data[i]) + Int(seed >> 16 & 7) - 3)
        }
        return try #require(context.makeImage())
    }

    static func photoOptions() -> ProcessingOptions {
        var options = ProcessingOptions()
        options.cropToPrint = true
        options.whiteBalance = false
        options.documentTone = false
        options.autoRotate = false
        options.colorMode = .color
        options.skipBlankPages = false
        return options
    }

    /// Share of pixels in the photo's outermost two-pixel ring that are not close to the print's
    /// base colour (backing left in, or edges whitened).
    static func strayBorderFraction(_ image: CGImage, tone: Tone) throws -> Double {
        try strayBorderFraction(image, colour: tone.base)
    }

    static func strayBorderFraction(_ image: CGImage, colour: (UInt8, UInt8, UInt8)) throws -> Double {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let context = try #require(CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let base = [colour.0, colour.1, colour.2].map(Int.init)
        var stray = 0, total = 0
        for y in 0..<h {
            for x in 0..<w where x < 2 || x >= w - 2 || y < 2 || y >= h - 2 {
                total += 1
                let i = (y * w + x) * 4
                if (0..<3).contains(where: { abs(Int(pixels[i + $0]) - base[$0]) > 10 }) { stray += 1 }
            }
        }
        return Double(stray) / Double(total)
    }

    /// Wallet, 3.5 × 5, 4 × 6 and 5 × 7 inch prints, each fed slightly skewed one way or the other.
    static let sizes: [(width: Double, height: Double, skew: Double)] = [
        (2.5, 3.5, 0.03), (3.5, 5, -0.03), (4, 6, 0.025), (5, 7, -0.025),
    ]

    @Test(arguments: [Tone.light, .dark], sizes.indices)
    func skewedPrintCropsToItsEdges(tone: Tone, size: Int) throws {
        let (width, height, skew) = Self.sizes[size]
        let page = try PageProcessor.process(try Self.scan(width: width, height: height, tone: tone, skew: skew),
                                             resolution: 150, side: .front, options: Self.photoOptions())
        #expect(abs(Double(page.image.width) / 150 - width) < 0.06)
        #expect(abs(Double(page.image.height) / 150 - height) < 0.06)
        #expect(try Self.strayBorderFraction(page.image, tone: tone) < 0.02)
    }

    @Test func printNearAPaperSizeKeepsItsOwnSize() throws {
        // Within the document crop's tolerance of Statement (5.5 × 8.5 inches).
        let page = try PageProcessor.process(try Self.scan(width: 5.4, height: 8.4, tone: .light), resolution: 150,
                                             side: .front, options: Self.photoOptions())
        #expect(abs(Double(page.image.width) / 150 - 5.4) < 0.06)
        #expect(abs(Double(page.image.height) / 150 - 8.4) < 0.06)
    }

    /// The scan as the raw page the scanner delivers.
    static func scannedPage(_ image: CGImage, dpi: Int) throws -> ScannedPage {
        let w = image.width, h = image.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let context = try #require(CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3] = rgba[i * 4]
            rgb[i * 3 + 1] = rgba[i * 4 + 1]
            rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return ScannedPage(side: .front, sheetIndex: 0, width: w, height: h, resolution: dpi, rgb: rgb)
    }

    @Test func builtInPhotoProfilesCropDarkPrintsAndDocumentProfilesDoNot() throws {
        let raw = try Self.scannedPage(try Self.scan(width: 3.5, height: 5, tone: .dark, skew: 0.02), dpi: 150)
        // Blank detection counts only ink darker than the print, so it drops this plain dark print.
        // Sizes are in scan pixels: no profile here resamples a 150 dpi scan.
        func firstPage(_ profile: ScanProfile) throws -> CGImage {
            var profile = profile
            profile.skipBlankPages = false
            profile.sides = .simplex
            return try #require(try SheetProcessor.process(front: raw, back: raw, profile: profile).pages.first).image
        }
        for profile in ScanProfile.builtInPhotoProfiles {
            let image = try firstPage(profile)
            #expect(abs(Double(image.width) / 150 - 3.5) < 0.06, "\(profile.name)")
            #expect(abs(Double(image.height) / 150 - 5) < 0.06, "\(profile.name)")
        }
        let document = try firstPage(try #require(ScanProfile.defaults.first { $0.name == "Scan to Yomi Folder" }))
        #expect(Double(document.width) / 150 > 8)
    }

    @Test func darkFrameLineAroundALightPrintIsKept() throws {
        let page = try PageProcessor.process(try Self.scan(width: 4, height: 6, tone: .light, frame: 0.06),
                                             resolution: 150, side: .front, options: Self.photoOptions())
        #expect(try Self.strayBorderFraction(page.image, colour: Self.frameColour) < 0.02)
    }
}
