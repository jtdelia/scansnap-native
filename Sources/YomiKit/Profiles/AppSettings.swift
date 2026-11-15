import Foundation

/// Everything the app saves in `Settings.json`.
public struct AppSettings: Codable, Equatable, Sendable {
    public var profiles: [ScanProfile]
    public var buttonProfileID: UUID?
    /// Set once the built-in photo scan profiles have been added to an existing install.
    public var addedPhotoProfiles: Bool

    public init(profiles: [ScanProfile] = [], buttonProfileID: UUID? = nil, addedPhotoProfiles: Bool = false) {
        self.profiles = profiles
        self.buttonProfileID = buttonProfileID
        self.addedPhotoProfiles = addedPhotoProfiles
    }

    /// Every key is optional, so settings saved by any earlier version keep loading.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        profiles = try container.decodeIfPresent([ScanProfile].self, forKey: .profiles) ?? defaults.profiles
        buttonProfileID = try container.decodeIfPresent(UUID.self, forKey: .buttonProfileID) ?? defaults.buttonProfileID
        addedPhotoProfiles = try container.decodeIfPresent(Bool.self, forKey: .addedPhotoProfiles)
            ?? defaults.addedPhotoProfiles
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
