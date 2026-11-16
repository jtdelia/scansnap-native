import Foundation
import Testing
@testable import YomiKit

/// The settings `yomi scan --photo` scans with.
struct CommandLinePhotoTests {
    private static let folder = URL(fileURLWithPath: "/tmp/yomi-photos", isDirectory: true)

    private static var keepers: ScanProfile {
        ScanProfile.builtInPhotoProfiles.first { $0.name == "Photos – Keepers" }!
    }

    @Test func usesKeepersSettingsWithTheGivenFolder() throws {
        let profile = try #require(ScanProfile.commandLinePhoto(dpi: 600, folder: Self.folder))
        var expected = Self.keepers
        expected.folderPath = "/tmp/yomi-photos"
        expected.saveTo = .folder
        #expect(profile == expected)
        #expect(profile.correctColor)
    }

    @Test func neverSavesToPhotos() throws {
        #expect(try #require(ScanProfile.commandLinePhoto(dpi: 300, folder: Self.folder)).saveTo == .folder)
    }

    @Test(arguments: [(300, ScanProfile.Quality.fine), (600, .excellent)])
    func resolutionComesFromTheDPIArgument(dpi: Int, quality: ScanProfile.Quality) throws {
        let profile = try #require(ScanProfile.commandLinePhoto(dpi: dpi, folder: Self.folder))
        #expect(profile.quality == quality)
        #expect(profile.quality.outputDPI(pageLengthInches: 6) == dpi)
    }

    @Test(arguments: [150, 200, 450])
    func unsupportedResolutionGivesNoSettings(dpi: Int) {
        #expect(ScanProfile.commandLinePhoto(dpi: dpi, folder: Self.folder) == nil)
    }

    @Test func unsupportedResolutionMessageNamesThePhotoResolutions() {
        #expect(ScanProfile.commandLinePhotoResolutionMessage == "--photo scans at 300 or 600 dpi")
        let accepted = (1...1200).filter { ScanProfile.commandLinePhoto(dpi: $0, folder: Self.folder) != nil }
        #expect(accepted == [300, 600])
    }
}
