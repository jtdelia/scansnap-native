import Foundation

/// Everything the app saves in `Settings.json`.
public struct AppSettings: Codable, Equatable, Sendable {
    /// Whether the app's windows follow macOS or are always light or dark.
    public enum Appearance: String, Codable, CaseIterable, Sendable {
        case system, light, dark

        public var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    public var profiles: [ScanProfile]
    public var buttonProfileID: UUID?
    /// Set once the built-in photo scan profiles have been added to an existing install.
    public var addedPhotoProfiles: Bool
    /// Set once the built-in photo scan profiles have been switched from JPEG to HEIC.
    public var switchedPhotoProfilesToHEIC: Bool
    public var appearance: Appearance

    public init(profiles: [ScanProfile] = [], buttonProfileID: UUID? = nil, addedPhotoProfiles: Bool = false,
                switchedPhotoProfilesToHEIC: Bool = false, appearance: Appearance = .system) {
        self.profiles = profiles
        self.buttonProfileID = buttonProfileID
        self.addedPhotoProfiles = addedPhotoProfiles
        self.switchedPhotoProfilesToHEIC = switchedPhotoProfilesToHEIC
        self.appearance = appearance
    }

    /// Every key is optional, so settings saved by any earlier version keep loading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        profiles = try container.decodeIfPresent([ScanProfile].self, forKey: .profiles) ?? defaults.profiles
        buttonProfileID = try container.decodeIfPresent(UUID.self, forKey: .buttonProfileID) ?? defaults.buttonProfileID
        addedPhotoProfiles = try container.decodeIfPresent(Bool.self, forKey: .addedPhotoProfiles)
            ?? defaults.addedPhotoProfiles
        switchedPhotoProfilesToHEIC = try container.decodeIfPresent(Bool.self, forKey: .switchedPhotoProfilesToHEIC)
            ?? defaults.switchedPhotoProfilesToHEIC
        appearance = try container.decodeIfPresent(Appearance.self, forKey: .appearance) ?? defaults.appearance
    }

    /// Settings for an install with nothing saved yet.
    public static var newInstall: AppSettings {
        AppSettings(profiles: ScanProfile.defaults, buttonProfileID: ScanProfile.defaults.first?.id,
                    addedPhotoProfiles: true, switchedPhotoProfilesToHEIC: true)
    }

    /// Brings settings saved by an earlier version up to date. Each step runs once per install, so a
    /// photo scan profile the user deletes stays deleted and a format the user picks again is kept.
    public func upgraded() -> AppSettings {
        var settings = self
        if !addedPhotoProfiles {
            let saved = Set(profiles.map(\.id))
            settings.profiles += ScanProfile.builtInPhotoProfiles.filter { !saved.contains($0.id) }
            settings.addedPhotoProfiles = true
        }
        if !switchedPhotoProfilesToHEIC {
            for index in settings.profiles.indices
            where ScanProfile.builtInPhotoIDs.contains(settings.profiles[index].id)
                && settings.profiles[index].fileFormat == .jpeg {
                settings.profiles[index].fileFormat = .heic
            }
            settings.switchedPhotoProfilesToHEIC = true
        }
        return settings
    }

    public init(json: Data) throws {
        self = try JSONDecoder().decode(AppSettings.self, from: json)
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
