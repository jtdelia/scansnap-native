import AppKit
import Foundation
import Testing
@testable import YomiKit

struct AppSettingsTests {
    private static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// The built-in scan profiles as version 1 saved them.
    private static let v1Profiles: [ScanProfile] = [
        ScanProfile(id: UUID(uuidString: "0A9CA2A9-EEB9-4098-A191-1A0CA292BF17")!, name: "Scan to Yomi Folder",
                    folderPath: "/Users/owner/Documents/Yomi"),
        ScanProfile(id: UUID(uuidString: "69E7C53B-F23C-4BFD-981B-17361D1485BC")!, name: "Receipts",
                    folderPath: "/Users/owner/Documents/Yomi", sides: .simplex),
        ScanProfile(id: UUID(uuidString: "9EBC7318-4319-4F8D-AF94-FB8D73341AB4")!, name: "Photos",
                    folderPath: "/Users/owner/Documents/Yomi", quality: .excellent, colorMode: .color,
                    sides: .simplex, skipBlankPages: false, reduceBleedThrough: false, autoRotate: false,
                    fileFormat: .jpeg, searchablePDF: false, compression: .low, namePattern: .dateTimeAndPage),
    ]

    @Test func decodesVersion1Settings() throws {
        let settings = try AppSettings(json: Self.fixture("settings-v1"))
        #expect(settings.profiles == Self.v1Profiles)
        #expect(settings.buttonProfileID == UUID(uuidString: "0A9CA2A9-EEB9-4098-A191-1A0CA292BF17"))
        #expect(settings.addedPhotoProfiles == false)
        #expect(settings.appearance == .system)
    }

    @Test func reencodedSettingsRoundTrip() throws {
        let settings = try AppSettings(json: Self.fixture("settings-v1"))
        #expect(try AppSettings(json: settings.json()) == settings)
    }

    @Test func missingKeysDecodeToDefaults() throws {
        let json = #"{"profiles": [{"id": "0A9CA2A9-EEB9-4098-A191-1A0CA292BF17", "name": "Bare"}]}"#
        let settings = try AppSettings(json: Data(json.utf8))
        let id = try #require(UUID(uuidString: "0A9CA2A9-EEB9-4098-A191-1A0CA292BF17"))
        #expect(settings.profiles == [ScanProfile(id: id, name: "Bare")])
        #expect(settings.buttonProfileID == nil)
        #expect(settings.addedPhotoProfiles == false)
    }

    /// Stands in for a scan profile with a photo setting added after it was saved.
    private struct PhotoSettingProfile: Decodable {
        enum CodingKeys: String, CodingKey { case id, photoSetting }
        let photoSetting: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let id = try container.decode(UUID.self, forKey: .id)
            photoSetting = try container.decodePhotoSetting(forKey: .photoSetting, profileID: id)
        }
    }

    private func decodePhotoSetting(_ json: String) throws -> Bool {
        try JSONDecoder().decode(PhotoSettingProfile.self, from: Data(json.utf8)).photoSetting
    }

    @Test func missingPhotoSettingIsOnForBuiltInPhotoProfiles() throws {
        #expect(ScanProfile.builtInPhotoIDs.count == 2)
        for id in ScanProfile.builtInPhotoIDs {
            #expect(try decodePhotoSetting(#"{"id": "\#(id.uuidString)"}"#) == true)
            #expect(try decodePhotoSetting(#"{"id": "\#(id.uuidString)", "photoSetting": false}"#) == false)
        }
    }

    @Test func missingPhotoSettingIsOffForOtherProfiles() throws {
        let id = "9EBC7318-4319-4F8D-AF94-FB8D73341AB4"
        #expect(try decodePhotoSetting(#"{"id": "\#(id)"}"#) == false)
        #expect(try decodePhotoSetting(#"{"id": "\#(id)", "photoSetting": true}"#) == true)
    }

    @Test func correctColorFollowsTheFixedIDRule() throws {
        let settings = try AppSettings(json: Self.fixture("settings-v1"))
        #expect(settings.profiles.allSatisfy { !$0.correctColor })
        for id in ScanProfile.builtInPhotoIDs {
            let json = #"{"profiles": [{"id": "\#(id.uuidString)", "name": "Photos – Keepers"}]}"#
            #expect(try AppSettings(json: Data(json.utf8)).profiles.first?.correctColor == true)
        }
        var profile = ScanProfile(name: "Prints")
        profile.correctColor = true
        let saved = AppSettings(profiles: [profile], buttonProfileID: nil, addedPhotoProfiles: false)
        #expect(try AppSettings(json: saved.json()).profiles.first?.correctColor == true)
    }

    @Test func autoEnhanceFollowsTheFixedIDRule() throws {
        let settings = try AppSettings(json: Self.fixture("settings-v1"))
        #expect(settings.profiles.allSatisfy { !$0.autoEnhance })
        for id in ScanProfile.builtInPhotoIDs {
            let json = #"{"profiles": [{"id": "\#(id.uuidString)", "name": "Photos – Quick"}]}"#
            #expect(try AppSettings(json: Data(json.utf8)).profiles.first?.autoEnhance == true)
        }
        let saved = AppSettings(profiles: [ScanProfile(name: "Prints", autoEnhance: true)], buttonProfileID: nil,
                                addedPhotoProfiles: false)
        #expect(try AppSettings(json: saved.json()).profiles.first?.autoEnhance == true)
        #expect(ScanProfile.builtInPhotoProfiles.allSatisfy { $0.autoEnhance })
        #expect(ScanProfile.defaults.filter { !ScanProfile.builtInPhotoIDs.contains($0.id) }.allSatisfy { !$0.autoEnhance })
    }

    @Test(arguments: [(AppSettings.Appearance.system, "system"), (.light, "light"), (.dark, "dark")])
    func appearanceIsSavedAndLoaded(appearance: AppSettings.Appearance, saved: String) throws {
        let json = try AppSettings(appearance: appearance).json()
        #expect(String(decoding: json, as: UTF8.self).contains(#""appearance" : "\#(saved)""#))
        #expect(try AppSettings(json: Data(#"{"appearance": "\#(saved)"}"#.utf8)).appearance == appearance)
    }

    @Test func appearanceMapsToAppKitAppearance() {
        #expect(AppSettings.Appearance.system.appKitName == nil)
        #expect(AppSettings.Appearance.light.appKitName == .aqua)
        #expect(AppSettings.Appearance.dark.appKitName == .darkAqua)
    }

    // MARK: Photo scan profiles

    @Test func newInstallHasBothPhotoProfilesAndNoPhotos() {
        let settings = AppSettings.newInstall
        let names = settings.profiles.map(\.name)
        #expect(names.contains("Photos – Quick"))
        #expect(names.contains("Photos – Keepers"))
        #expect(!names.contains("Photos"))
        #expect(Set(settings.profiles.map(\.id)).isSuperset(of: ScanProfile.builtInPhotoIDs))
        #expect(settings.buttonProfileID == settings.profiles.first?.id)
    }

    @Test func upgradeKeepsSavedProfilesAndAddsPhotoProfilesOnce() throws {
        let saved = try AppSettings(json: Self.fixture("settings-v1"))
        let upgraded = saved.upgraded()
        #expect(Array(upgraded.profiles.prefix(3)) == Self.v1Profiles)
        #expect(upgraded.profiles.dropFirst(3).map(\.name) == ["Photos – Quick", "Photos – Keepers"])
        #expect(Set(upgraded.profiles.dropFirst(3).map(\.id)) == ScanProfile.builtInPhotoIDs)
        #expect(upgraded.buttonProfileID == saved.buttonProfileID)
        #expect(upgraded.addedPhotoProfiles)
        #expect(upgraded.upgraded() == upgraded)
    }

    @Test func deletedPhotoProfileIsNotAddedAgain() throws {
        var settings = try AppSettings(json: Self.fixture("settings-v1")).upgraded()
        settings.profiles.removeAll { $0.name == "Photos – Keepers" }
        let reloaded = try AppSettings(json: settings.json()).upgraded()
        #expect(reloaded.profiles == settings.profiles)
    }

    @Test func emptySettingsDecode() throws {
        let settings = try AppSettings(json: Data("{}".utf8))
        #expect(settings.profiles.isEmpty)
    }
}
