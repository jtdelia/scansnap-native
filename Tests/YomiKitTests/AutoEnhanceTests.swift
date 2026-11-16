import CoreGraphics
import Foundation
import Testing
@testable import YomiKit

/// Folder saves for scan profiles with auto-enhance on.
struct AutoEnhanceTests {
    private static let date = Calendar.current.date(
        from: DateComponents(year: 2026, month: 11, day: 14, hour: 21, minute: 42, second: 5))!

    /// A dull, low-contrast Display P3 photo that auto-adjust brightens.
    private static func dullPhoto() -> ProcessedPage {
        let width = 120, height = 90
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for x in 0..<width {
            let shade = 0.25 + 0.2 * Double(x) / Double(width)
            context.setFillColor(red: shade, green: shade * 0.9, blue: shade * 0.8, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return ProcessedPage(image: context.makeImage()!, resolution: 300, isBlank: false, source: .front, isColor: true)
    }

    private static func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("YomiAutoEnhanceTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func profile(autoEnhance: Bool, folder: URL, namePattern: FileNamePattern = .dateTimeAndPage,
                                fileFormat: ScanProfile.FileFormat = .jpeg) -> ScanProfile {
        var profile = ScanProfile(name: "Prints", folderPath: folder.path, colorMode: .color, fileFormat: fileFormat,
                                  searchablePDF: false, namePattern: namePattern)
        profile.autoEnhance = autoEnhance
        return profile
    }

    /// `DocumentWriter.save`, off the task pool because Core Image's auto-adjustments call Vision.
    @discardableResult
    private static func save(_ pages: [ProcessedPage], _ profile: ScanProfile) async throws -> [URL] {
        try await offTheTaskPool { try DocumentWriter.save(pages, profile: profile, date: date) }
    }

    private static func folderContents(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    @Test func folderSaveWritesEnhancedAndOriginalWithTheSameName() async throws {
        let folder = try Self.temporaryFolder()
        let profile = Self.profile(autoEnhance: true, folder: folder, namePattern: [.profileName])
        try await Self.save([Self.dullPhoto()], profile)
        #expect(try Self.folderContents(folder) == ["Prints.jpg", "Prints_original.jpg"])
    }

    @Test func runningNumberAdvancesOncePerPhoto() async throws {
        let folder = try Self.temporaryFolder()
        var profile = Self.profile(autoEnhance: true, folder: folder, namePattern: .nameAndNumber("Print"))
        profile.nextNumber = 7
        let urls = try await Self.save([Self.dullPhoto(), Self.dullPhoto()], profile)
        #expect(urls.map(\.lastPathComponent) == ["Print 007.jpg", "Print 008.jpg"])
        #expect(try Self.folderContents(folder) == [
            "Print 007.jpg", "Print 007_original.jpg", "Print 008.jpg", "Print 008_original.jpg",
        ])
        #expect(DocumentWriter.numbersUsed(pages: 2, profile: profile) == 2)
    }

    @Test func clashNumberIsPartOfTheOriginalName() async throws {
        let folder = try Self.temporaryFolder()
        let profile = Self.profile(autoEnhance: true, folder: folder, namePattern: [.profileName])
        try await Self.save([Self.dullPhoto()], profile)
        try await Self.save([Self.dullPhoto()], profile)
        #expect(try Self.folderContents(folder) == [
            "Prints (2).jpg", "Prints (2)_original.jpg", "Prints.jpg", "Prints_original.jpg",
        ])
    }

    @Test(arguments: [ScanProfile.FileFormat.pdf, .multiPageTIFF])
    func formatsHoldingSeveralPagesAreNotEnhanced(format: ScanProfile.FileFormat) async throws {
        let folder = try Self.temporaryFolder()
        let profile = Self.profile(autoEnhance: true, folder: folder, namePattern: [.profileName], fileFormat: format)
        try await Self.save([Self.dullPhoto(), Self.dullPhoto()], profile)
        #expect(try Self.folderContents(folder) == ["Prints.\(format.fileExtension)"])
    }

    @Test(arguments: [ScanProfile.FileFormat.jpeg, .tiff])
    func originalIsByteForByteTheUnenhancedSave(format: ScanProfile.FileFormat) async throws {
        let plainFolder = try Self.temporaryFolder(), enhancedFolder = try Self.temporaryFolder()
        let plain = Self.profile(autoEnhance: false, folder: plainFolder, namePattern: [.profileName], fileFormat: format)
        let enhanced = Self.profile(autoEnhance: true, folder: enhancedFolder, namePattern: [.profileName],
                                    fileFormat: format)
        let plainURL = try #require(try await Self.save([Self.dullPhoto()], plain).first)
        let enhancedURL = try #require(try await Self.save([Self.dullPhoto()], enhanced).first)
        let originalURL = enhancedFolder.appendingPathComponent("Prints_original.\(format.fileExtension)")

        #expect(try Data(contentsOf: originalURL) == Data(contentsOf: plainURL))
        #expect(try Data(contentsOf: enhancedURL) != Data(contentsOf: plainURL))
    }
}
