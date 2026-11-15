import CoreGraphics
import Foundation

public enum ColorProfileError: Error, CustomStringConvertible {
    case unreadable(String)
    case notRGB(String)

    public var description: String {
        switch self {
        case let .unreadable(name): "\(name) is not a color profile."
        case let .notRGB(name): "\(name) is not an RGB color profile."
        }
    }
}

/// The scanner maker's colour profile (Fujitsu's `ScanSnap S1300.icm`, also used for the S1300i).
/// It is never bundled: Yomi finds it in ScanSnap Manager or where Settings installed it.
public struct ColorProfile: @unchecked Sendable {
    public let url: URL
    public let colorSpace: CGColorSpace

    public init(url: URL) throws {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url), let colorSpace = CGColorSpace(iccData: data as CFData) else {
            throw ColorProfileError.unreadable(name)
        }
        guard colorSpace.model == .rgb else { throw ColorProfileError.notRGB(name) }
        self.url = url
        self.colorSpace = colorSpace
    }

    public static let installFolder = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Yomi/ColorProfiles", isDirectory: true)

    /// Files are tried as they are; folders are searched for `.icc` and `.icm` files.
    public static let searchLocations: [URL] = [
        URL(fileURLWithPath: "/Applications/ScanSnap/ScanSnap Manager.app/Contents/Resources/ScanSnap S1300.icm"),
        installFolder,
    ]

    /// The first usable colour profile in `locations`, in order.
    public static func locate(in locations: [URL] = searchLocations) -> ColorProfile? {
        let fm = FileManager.default
        let candidates = locations.flatMap { location -> [URL] in
            var isFolder: ObjCBool = false
            guard fm.fileExists(atPath: location.path, isDirectory: &isFolder) else { return [] }
            guard isFolder.boolValue else { return [location] }
            return ((try? fm.contentsOfDirectory(at: location, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["icc", "icm"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return candidates.lazy.compactMap { try? ColorProfile(url: $0) }.first
    }

    /// Copies a chosen colour profile into `folder`, replacing any colour profile chosen before.
    @discardableResult
    public static func install(from url: URL, into folder: URL = installFolder) throws -> ColorProfile {
        _ = try ColorProfile(url: url)
        let data = try Data(contentsOf: url)
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for old in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try fm.removeItem(at: old)
        }
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        try data.write(to: destination)
        return try ColorProfile(url: destination)
    }
}

/// What one batch does about colour correction, decided before it starts.
public enum ColorCorrection: @unchecked Sendable {
    case off
    case on(ColorProfile)
    /// Colour correction is on but no colour profile was found, so the batch is saved in sRGB.
    case skipped

    public static func forBatch(_ profile: ScanProfile,
                                searching locations: [URL] = ColorProfile.searchLocations) -> ColorCorrection {
        guard profile.correctColor else { return .off }
        return ColorProfile.locate(in: locations).map(ColorCorrection.on) ?? .skipped
    }

    public var colorSpace: CGColorSpace? {
        if case let .on(profile) = self { return profile.colorSpace }
        return nil
    }

    public var logLine: String? {
        switch self {
        case .off: nil
        case let .on(profile): "color correction: \(profile.url.path)"
        case .skipped: "color correction skipped: color profile not found"
        }
    }

    /// Shown in the progress panel beside a finished batch.
    public var notice: String? {
        if case .skipped = self { return "Color correction was skipped: the scanner's color profile was not found." }
        return nil
    }
}
