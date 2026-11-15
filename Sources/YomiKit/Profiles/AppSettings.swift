import AppKit
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

        /// The AppKit appearance to force, or `nil` to follow macOS.
        public var appKitName: NSAppearance.Name? {
            switch self {
            case .system: nil
            case .light: .aqua
            case .dark: .darkAqua
            }
        }
    }

    public var profiles: [ScanProfile]
    public var buttonProfileID: UUID?
    /// Set once the built-in photo scan profiles have been added to an existing install.
    public var addedPhotoProfiles: Bool
    public var appearance: Appearance

    public init(profiles: [ScanProfile] = [], buttonProfileID: UUID? = nil, addedPhotoProfiles: Bool = false,
                appearance: Appearance = .system) {
        self.profiles = profiles
        self.buttonProfileID = buttonProfileID
        self.addedPhotoProfiles = addedPhotoProfiles
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
        appearance = try container.decodeIfPresent(Appearance.self, forKey: .appearance) ?? defaults.appearance
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
