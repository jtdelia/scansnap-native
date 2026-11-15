import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import YomiKit

struct MultiPageTIFFTests {
    /// A page of the given size whose pixels depend on their position and on `seed`, so a
    /// lossy or reordered page cannot match.
    private static func page(width: Int, height: Int, seed: Int, color: Bool, resolution: Int) throws -> ProcessedPage {
        let components = color ? 3 : 1
        var bytes = [UInt8](repeating: 0, count: width * height * components)
        for i in bytes.indices {
            bytes[i] = UInt8((i * 7 + seed * 31 + (i / width) * 13) % 256)
        }
        let space = color ? CGColorSpace(name: CGColorSpace.sRGB)! : CGColorSpaceCreateDeviceGray()
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * components,
            bytesPerRow: width * components, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return ProcessedPage(image: image, resolution: resolution, isBlank: false, source: .front, isColor: color)
    }

    /// Pixels drawn into one shared RGBA buffer, so pages compare independently of how they are stored.
    private static func pixels(_ image: CGImage) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    private static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func batchSavesAsOneTIFFWithPagesInOrder() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pages = [
            try Self.page(width: 40, height: 60, seed: 1, color: true, resolution: 300),
            try Self.page(width: 50, height: 30, seed: 2, color: false, resolution: 200),
            try Self.page(width: 20, height: 70, seed: 3, color: true, resolution: 600),
        ]
        let profile = ScanProfile(name: "Test", folderPath: folder.path, fileFormat: .multiPageTIFF)

        let urls = try DocumentWriter.save(pages, profile: profile)

        #expect(urls.count == 1)
        let url = try #require(urls.first)
        #expect(url.pathExtension == "tiff")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == pages.count)
        for (index, page) in pages.enumerated() {
            let saved = try #require(CGImageSourceCreateImageAtIndex(source, index, nil))
            #expect(saved.width == page.image.width && saved.height == page.image.height, "page \(index + 1)")
            #expect(try Self.pixels(saved) == Self.pixels(page.image), "page \(index + 1) is not lossless")
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            #expect(properties[kCGImagePropertyDPIWidth] as? Int == page.resolution, "page \(index + 1)")
        }
    }

    @Test func batchUsesOneRunningNumber() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pages = [
            try Self.page(width: 10, height: 10, seed: 1, color: true, resolution: 300),
            try Self.page(width: 10, height: 10, seed: 2, color: true, resolution: 300),
        ]
        let profile = ScanProfile(name: "Test", folderPath: folder.path, fileFormat: .multiPageTIFF,
                                  namePattern: .nameAndNumber("Scan"), nextNumber: 7)

        let urls = try DocumentWriter.save(pages, profile: profile)

        #expect(urls.map(\.lastPathComponent) == ["Scan 007.tiff"])
        #expect(DocumentWriter.numbersUsed(pages: pages.count, profile: profile) == 1)
    }

    @Test func colourPagesKeepTheDocumentToneCurve() {
        let profile = ScanProfile(name: "Test", colorMode: .color, fileFormat: .multiPageTIFF)
        #expect(profile.processingOptions.documentTone)
    }
}
