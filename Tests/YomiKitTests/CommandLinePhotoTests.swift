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
        #expect(profile == expected)
        #expect(profile.correctColor)
    }

    @Test(arguments: [(150, ScanProfile.Quality.normal), (200, .better), (300, .fine), (600, .excellent)])
    func resolutionComesFromTheDPIArgument(dpi: Int, quality: ScanProfile.Quality) throws {
        let profile = try #require(ScanProfile.commandLinePhoto(dpi: dpi, folder: Self.folder))
        #expect(profile.quality == quality)
        #expect(profile.quality.outputDPI(pageLengthInches: 6) == dpi)
    }

    @Test func unsupportedResolutionGivesNoSettings() {
        #expect(ScanProfile.commandLinePhoto(dpi: 450, folder: Self.folder) == nil)
    }
}
