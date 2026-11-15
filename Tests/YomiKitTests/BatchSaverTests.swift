import CoreGraphics
import Foundation
import Testing
@testable import YomiKit

/// Where `BatchSaver.save` puts a batch, with a fake Photos library standing in for PhotoKit.
struct BatchSaverTests {
    private static let date = Calendar.current.date(
        from: DateComponents(year: 2026, month: 11, day: 14, hour: 21, minute: 42, second: 5))!

    /// Records what it was asked to add, or fails with `error`.
    private final class FakePhotoLibrary: PhotoLibrary, @unchecked Sendable {
        let error: PhotoLibraryError?
        private(set) var added: [(names: [String], album: String)] = []
        private(set) var filesExisted = true

        init(failingWith error: PhotoLibraryError? = nil) { self.error = error }

        func add(_ files: [URL], album: String) throws {
            filesExisted = files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
            if let error { throw error }
            added.append((files.map(\.lastPathComponent), album))
        }
    }

    private static func page() -> ProcessedPage {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ProcessedPage(image: context.makeImage()!, resolution: 300, isBlank: false, source: .front, isColor: true)
    }

    private static func profile(_ saveTo: ScanProfile.SaveDestination, album: String = "") throws -> ScanProfile {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YomiBatchSaverTests-\(UUID())")
        return ScanProfile(name: "Prints", folderPath: folder.path, saveTo: saveTo, photosAlbum: album,
                           fileFormat: .jpeg, namePattern: .dateTimeAndPage)
    }

    private static func save(_ profile: ScanProfile, library: FakePhotoLibrary?) throws -> SavedBatch {
        try BatchSaver.save([page(), page()], profile: profile, photoLibrary: library, date: date)
    }

    private static func folderContents(_ profile: ScanProfile) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: profile.folderPath)) ?? []).sorted()
    }

    private static let names = ["2026-11-14 21.42.05_001.jpg", "2026-11-14 21.42.05_002.jpg"]

    @Test func photosOnlyAddsTheBatchToTheAlbumAndLeavesTheFolderEmpty() throws {
        let profile = try Self.profile(.photos, album: "Family")
        let library = FakePhotoLibrary()
        let saved = try Self.save(profile, library: library)
        #expect(library.added.map(\.names) == [Self.names])
        #expect(library.added.map(\.album) == ["Family"])
        #expect(library.filesExisted)
        #expect(saved.files.isEmpty)
        #expect(saved.warning == nil)
        #expect(saved.place == "the Photos album “Family”")
        #expect(Self.folderContents(profile).isEmpty)
    }

    @Test func photosOnlyWithAccessDeniedSavesTheBatchToTheFolderAndSaysWhy() throws {
        let profile = try Self.profile(.photos, album: "Family")
        let saved = try Self.save(profile, library: FakePhotoLibrary(failingWith: .accessDenied))
        #expect(Self.folderContents(profile) == Self.names)
        #expect(saved.files.map(\.lastPathComponent) == Self.names)
        #expect(saved.files.allSatisfy { $0.deletingLastPathComponent().path == profile.folderURL.path })
        #expect(saved.place == profile.folderURL.lastPathComponent)
        #expect(saved.warning == "Couldn't save to Photos: Yomi isn't allowed to use Photos. Allow it in "
            + "System Settings › Privacy & Security › Photos. Saved to \(profile.folderURL.lastPathComponent) instead.")
    }

    @Test func photosOnlyWhenTheAlbumCannotBeCreatedSavesTheBatchToTheFolder() throws {
        var profile = try Self.profile(.photos, album: "Family")
        profile.subfolderPattern = [.year]
        let saved = try Self.save(profile, library: FakePhotoLibrary(failingWith: .albumNotCreated("Family")))
        let folder = profile.folderURL.appendingPathComponent("2026")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == Self.names)
        #expect(saved.files == Self.names.map { folder.appendingPathComponent($0) })
        #expect(saved.warning?.contains("The album “Family” couldn't be created.") == true)
    }

    @Test func folderOnlyNeverUsesPhotos() throws {
        let profile = try Self.profile(.folder, album: "Family")
        let library = FakePhotoLibrary()
        let saved = try Self.save(profile, library: library)
        #expect(library.added.isEmpty)
        #expect(Self.folderContents(profile) == Self.names)
        #expect(saved.files.map(\.lastPathComponent) == Self.names)
        #expect(saved.warning == nil)
        #expect(saved.place == profile.folderURL.lastPathComponent)
    }

    @Test func folderAndPhotosKeepsTheFilesAndAddsThemToPhotos() throws {
        let profile = try Self.profile(.folderAndPhotos)
        let library = FakePhotoLibrary()
        let saved = try Self.save(profile, library: library)
        #expect(library.added.map(\.names) == [Self.names])
        #expect(library.added.map(\.album) == [""])
        #expect(Self.folderContents(profile) == Self.names)
        #expect(saved.files.map(\.lastPathComponent) == Self.names)
        #expect(saved.warning == nil)
        #expect(saved.place == "\(profile.folderURL.lastPathComponent) and Photos")
    }

    @Test func folderAndPhotosWithAccessDeniedKeepsTheFilesAndSaysWhy() throws {
        let profile = try Self.profile(.folderAndPhotos)
        let saved = try Self.save(profile, library: FakePhotoLibrary(failingWith: .failed("Photos isn't available.")))
        #expect(Self.folderContents(profile) == Self.names)
        #expect(saved.files.map(\.lastPathComponent) == Self.names)
        #expect(saved.place == profile.folderURL.lastPathComponent)
        #expect(saved.warning == "Couldn't save to Photos: Photos isn't available. "
            + "Saved to \(profile.folderURL.lastPathComponent) only.")
    }

    @Test func withoutAPhotoLibraryTheBatchGoesToTheFolder() throws {
        let profile = try Self.profile(.photos)
        let saved = try Self.save(profile, library: nil)
        #expect(Self.folderContents(profile) == Self.names)
        #expect(saved.files.map(\.lastPathComponent) == Self.names)
        #expect(saved.warning == "Couldn't save to Photos: Saving to Photos needs the Yomi app. "
            + "Saved to \(profile.folderURL.lastPathComponent) instead.")
    }
}
