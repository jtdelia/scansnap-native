import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import YomiKit

/// PNG, TIFF and HEIC, which save each page as its own file.
struct ImageFormatTests {
    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    /// A page whose pixels depend on their position and on `seed`, so a lossy or reordered page cannot match.
    private static func page(width: Int, height: Int, seed: Int, resolution: Int,
                             space: CGColorSpace = displayP3) throws -> ProcessedPage {
        let components = space.numberOfComponents
        var bytes = [UInt8](repeating: 0, count: width * height * components)
        for i in bytes.indices {
            bytes[i] = UInt8((i * 7 + seed * 31 + (i / width) * 13) % 256)
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * components,
            bytesPerRow: width * components, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return ProcessedPage(image: image, resolution: resolution, isBlank: false, source: .front,
                             isColor: components == 3)
    }

    /// Pixels drawn into one shared Display P3 buffer, so pages compare independently of how they are stored.
    private static func pixels(_ image: CGImage) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: displayP3,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    private static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private struct SavedImage {
        let image: CGImage
        let count: Int
        let resolution: Int?
        let typeIdentifier: String?
    }

    private static func read(_ url: URL) throws -> SavedImage {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return SavedImage(image: image, count: CGImageSourceGetCount(source),
                          resolution: properties[kCGImagePropertyDPIWidth] as? Int,
                          typeIdentifier: CGImageSourceGetType(source) as String?)
    }

    @Test(arguments: [ScanProfile.FileFormat.jpeg, .png, .heic, .tiff, .multiPageTIFF])
    func publishesTheCompletedImageEvenWhenItsNameIsTakenDuringEncoding(format: ScanProfile.FileFormat) throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = try Self.page(width: 64, height: 96, seed: 1, resolution: 300)
        let profile = ScanProfile(name: "Print", folderPath: folder.path, fileFormat: format, namePattern: [.profileName])
        let first = folder.appendingPathComponent("Print.\(format.fileExtension)")
        let existing = Data("existing file".utf8)
        var calls = 0
        let files = try DocumentWriter.save([page], profile: profile) { _ in
            calls += 1
            #expect(throws: Never.self) { try existing.write(to: first, options: .withoutOverwriting) }
        }
        #expect(calls == 1)
        #expect(try Data(contentsOf: first) == existing)
        let result = try #require(files.first)
        #expect(result.lastPathComponent == "Print (2).\(format.fileExtension)")
        let saved = try Self.read(result)
        #expect(saved.count == 1 && saved.image.width == 64 && saved.image.height == 96)
    }

    @Test(arguments: [(ScanProfile.FileFormat.png, "png", "public.png"), (.tiff, "tiff", "public.tiff")])
    func losslessFormatSavesEachPageExactly(format: ScanProfile.FileFormat, ext: String, type: String) throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pages = [
            try Self.page(width: 40, height: 60, seed: 1, resolution: 300),
            try Self.page(width: 50, height: 30, seed: 2, resolution: 600),
        ]
        let profile = ScanProfile(name: "Test", folderPath: folder.path, fileFormat: format,
                                  namePattern: .nameAndNumber("Scan"), nextNumber: 4)

        let urls = try DocumentWriter.save(pages, profile: profile)

        #expect(urls.map(\.lastPathComponent) == ["Scan 004.\(ext)", "Scan 005.\(ext)"])
        #expect(DocumentWriter.numbersUsed(pages: pages.count, profile: profile) == 2)
        for (url, page) in zip(urls, pages) {
            let saved = try Self.read(url)
            #expect(saved.typeIdentifier == type)
            #expect(saved.count == 1)
            #expect(saved.image.width == page.image.width && saved.image.height == page.image.height)
            #expect(saved.resolution == page.resolution, "\(url.lastPathComponent)")
            #expect(saved.image.colorSpace?.name == CGColorSpace.displayP3, "\(url.lastPathComponent)")
            #expect(try Self.pixels(saved.image) == Self.pixels(page.image), "\(url.lastPathComponent) is not lossless")
        }
    }

    @Test func heicSavesEachPageInDisplayP3() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pages = [
            try Self.page(width: 64, height: 96, seed: 1, resolution: 300),
            try Self.page(width: 96, height: 64, seed: 2, resolution: 600),
        ]
        let profile = ScanProfile(name: "Test", folderPath: folder.path, fileFormat: .heic,
                                  namePattern: .nameAndNumber("Photo"), nextNumber: 1)

        let urls = try DocumentWriter.save(pages, profile: profile)

        #expect(urls.map(\.lastPathComponent) == ["Photo 001.heic", "Photo 002.heic"])
        for (url, page) in zip(urls, pages) {
            let saved = try Self.read(url)
            #expect(saved.typeIdentifier == "public.heic")
            #expect(saved.image.width == page.image.width && saved.image.height == page.image.height)
            #expect(saved.resolution == page.resolution, "\(url.lastPathComponent)")
            #expect(saved.image.colorSpace?.name == CGColorSpace.displayP3, "\(url.lastPathComponent)")
        }
    }

    @Test(arguments: [ScanProfile.FileFormat.png, .tiff, .heic])
    func grayPageSavesInGray(format: ScanProfile.FileFormat) throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gray = try #require(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        let page = try Self.page(width: 64, height: 48, seed: 3, resolution: 200, space: gray)
        let profile = ScanProfile(name: "Test", folderPath: folder.path, fileFormat: format)

        let url = try #require(try DocumentWriter.save([page], profile: profile).first)

        let saved = try Self.read(url)
        #expect(saved.image.width == 64 && saved.image.height == 48)
        #expect(saved.resolution == 200)
        #expect(saved.image.colorSpace?.model == .monochrome)
    }

    @Test(arguments: [(ScanProfile.FileFormat.pdf, true), (.jpeg, false), (.png, false), (.tiff, false),
                      (.multiPageTIFF, true), (.heic, false)])
    func documentToneCurveFollowsTheFormatForColourPages(format: ScanProfile.FileFormat, documentTone: Bool) {
        let profile = ScanProfile(name: "Test", colorMode: .color, fileFormat: format)
        #expect(profile.processingOptions.documentTone == documentTone)
    }

    @Test func compressionAppliesOnlyToLossyFormats() {
        let lossy = ScanProfile.FileFormat.allCases.filter(\.usesCompression)
        #expect(lossy == [.pdf, .jpeg, .heic])
    }

    @Test func heicFollowsTheCompressionSetting() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let page = try Self.page(width: 256, height: 256, seed: 5, resolution: 300)
        func size(_ compression: ScanProfile.Compression) throws -> Int {
            let profile = ScanProfile(name: compression.rawValue, folderPath: folder.path, fileFormat: .heic,
                                      compression: compression, namePattern: [.profileName])
            let url = try #require(try DocumentWriter.save([page], profile: profile).first)
            return try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        }
        #expect(try size(.high) < size(.low))
    }
}
