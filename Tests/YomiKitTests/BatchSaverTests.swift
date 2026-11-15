import CoreGraphics
import Foundation
import Testing
@testable import YomiKit

/// Where `BatchSaver.save` puts a batch, with a fake Photos library standing in for PhotoKit.
struct BatchSaverTests {
    private static let date = Calendar.current.date(
        from: DateComponents(year: 2026, month: 11, day: 14, hour: 21, minute: 42, second: 5))!

    /// One photo as Photos was given it, read while the files still existed.
    private struct AddedPhoto {
        let name: String
        let original: String
        let originalData: Data?
        let edited: String?
        let editedData: Data?
    }

    /// Records what it was asked to add, or fails with `error`.
    private final class FakePhotoLibrary: PhotoLibrary, @unchecked Sendable {
        let error: PhotoLibraryError?
        let unenhanced: Int
        private(set) var added: [(photos: [AddedPhoto], album: String)] = []
        private(set) var filesExisted = true

        init(failingWith error: PhotoLibraryError? = nil, unenhanced: Int = 0) {
            self.error = error
            self.unenhanced = unenhanced
        }

        func add(_ photos: [PhotoImport], album: String) throws -> Int {
            let files = photos.flatMap { [$0.original] + ($0.edited.map { [$0] } ?? []) }
            filesExisted = files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
            if let error { throw error }
            added.append((photos.map { photo in
                AddedPhoto(name: photo.name, original: photo.original.lastPathComponent,
                           originalData: try? Data(contentsOf: photo.original),
                           edited: photo.edited?.lastPathComponent,
                           editedData: photo.edited.flatMap { try? Data(contentsOf: $0) })
            }, album))
            return unenhanced
        }

        /// Names of the photos added in each call.
        var names: [[String]] { added.map { $0.photos.map(\.name) } }
    }

    /// A dull, low-contrast photo that auto-adjust brightens.
    private static func page() -> ProcessedPage {
        let width = 40, height = 30
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for x in 0..<width {
            let shade = 0.25 + 0.2 * Double(x) / Double(width)
            context.setFillColor(red: shade, green: shade * 0.9, blue: shade * 0.8, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        return ProcessedPage(image: context.makeImage()!, resolution: 300, isBlank: false, source: .front, isColor: true)
    }

    private static func profile(_ saveTo: ScanProfile.SaveDestination, album: String = "",
                                autoEnhance: Bool = false) throws -> ScanProfile {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YomiBatchSaverTests-\(UUID())")
        var profile = ScanProfile(name: "Prints", folderPath: folder.path, saveTo: saveTo, photosAlbum: album,
                                  fileFormat: .jpeg, namePattern: .dateTimeAndPage)
        profile.autoEnhance = autoEnhance
        return profile
    }

    /// Bytes of each file a folder save without auto-enhance writes for the test batch.
    private static func unenhancedData() throws -> [Data] {
        let profile = try profile(.folder)
        return try save(profile, library: nil).files.map { try Data(contentsOf: $0) }
    }

    private static func save(_ profile: ScanProfile, library: FakePhotoLibrary?) throws -> SavedBatch {
        try BatchSaver.save([page(), page()], profile: profile, photoLibrary: library, date: date)
    }

    /// `save` for scan profiles with auto-enhance on, whose Core Image auto-adjustments call Vision.
    private static func saveEnhanced(_ profile: ScanProfile, library: FakePhotoLibrary) async throws -> SavedBatch {
        try await offTheTaskPool { try save(profile, library: library) }
    }

    private static func folderContents(_ profile: ScanProfile) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: profile.folderPath)) ?? []).sorted()
    }

    private static let names = ["2026-11-14 21.42.05_001.jpg", "2026-11-14 21.42.05_002.jpg"]

    @Test func photosOnlyAddsTheBatchToTheAlbumAndLeavesTheFolderEmpty() throws {
        let profile = try Self.profile(.photos, album: "Family")
        let library = FakePhotoLibrary()
        let saved = try Self.save(profile, library: library)
        #expect(library.names == [Self.names])
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

    @Test func photosOnlyWhenTheFolderCannotBeWrittenEitherSaysWhereTheBatchIs() throws {
        var profile = try Self.profile(.photos)
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("YomiBatchSaverTests-\(UUID())")
        try Data().write(to: blocker)
        profile.folderPath = blocker.appendingPathComponent("Scans").path
        let saved = try Self.save(profile, library: FakePhotoLibrary(failingWith: .accessDenied))
        let staging = try #require(saved.files.first?.deletingLastPathComponent())
        #expect(saved.files.map(\.lastPathComponent) == Self.names)
        #expect(saved.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(staging.standardizedFileURL.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path))
        #expect(saved.place == staging.path)
        #expect(saved.warning?.contains("Couldn't save to Scans either") == true, "\(saved.warning ?? "")")
        #expect(saved.warning?.contains(staging.path) == true, "\(saved.warning ?? "")")
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
        #expect(library.names == [Self.names])
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

    @Test func photosOnlyWithAutoEnhanceAddsEachUntouchedScanWithTheEnhancementAsItsEdit() async throws {
        let profile = try Self.profile(.photos, autoEnhance: true)
        let library = FakePhotoLibrary()
        let saved = try await Self.saveEnhanced(profile, library: library)
        let photos = try #require(library.added.first?.photos)
        #expect(library.added.count == 1)
        #expect(photos.map(\.name) == Self.names)
        #expect(try photos.map(\.originalData) == Self.unenhancedData())
        #expect(photos.allSatisfy { $0.editedData != nil && $0.editedData != $0.originalData })
        #expect(library.filesExisted)
        #expect(saved.files.isEmpty)
        #expect(Self.folderContents(profile).isEmpty)
    }

    @Test func photosOnlyWithAutoEnhanceWhenPhotosFailsKeepsEachEnhancedPhotoAndItsOriginalInTheFolder() async throws {
        let profile = try Self.profile(.photos, autoEnhance: true)
        let saved = try await Self.saveEnhanced(profile, library: FakePhotoLibrary(failingWith: .accessDenied))
        #expect(Self.folderContents(profile) == [
            "2026-11-14 21.42.05_001.jpg", "2026-11-14 21.42.05_001_original.jpg",
            "2026-11-14 21.42.05_002.jpg", "2026-11-14 21.42.05_002_original.jpg",
        ])
        #expect(saved.files.map(\.lastPathComponent) == Self.names)
        let originals = try ["001", "002"].map {
            try Data(contentsOf: profile.folderURL.appendingPathComponent("2026-11-14 21.42.05_\($0)_original.jpg"))
        }
        #expect(try originals == Self.unenhancedData())
    }

    @Test func folderAndPhotosWithAutoEnhanceKeepsBothFilesAndAddsOnePhotoPerPrint() async throws {
        let profile = try Self.profile(.folderAndPhotos, autoEnhance: true)
        let library = FakePhotoLibrary()
        let saved = try await Self.saveEnhanced(profile, library: library)
        let photos = try #require(library.added.first?.photos)
        #expect(library.added.count == 1)
        #expect(photos.map(\.name) == Self.names)
        #expect(photos.map(\.original) == [
            "2026-11-14 21.42.05_001_original.jpg", "2026-11-14 21.42.05_002_original.jpg",
        ])
        #expect(photos.map(\.edited) == Self.names)
        #expect(Self.folderContents(profile).count == 4)
        #expect(saved.files.map(\.lastPathComponent) == Self.names)
        #expect(saved.warning == nil)
    }

    @Test(arguments: [(ScanProfile.SaveDestination.photos, 0), (.folderAndPhotos, 4)])
    func photosAddedWithoutTheirEnhancementCountAsSaved(saveTo: ScanProfile.SaveDestination, files: Int) async throws {
        let profile = try Self.profile(saveTo, autoEnhance: true)
        let library = FakePhotoLibrary(unenhanced: 2)
        let saved = try await Self.saveEnhanced(profile, library: library)
        #expect(library.added.count == 1)
        #expect(Self.folderContents(profile).count == files)
        #expect(saved.warning == nil)
        #expect(saved.notice == "Saved to Photos without enhancement for 2 photos.")
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
