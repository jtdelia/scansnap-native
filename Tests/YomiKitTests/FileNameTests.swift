import CoreGraphics
import Foundation
import Testing
@testable import YomiKit

/// File names written by `DocumentWriter.save`, checked against literal names.
struct FileNameTests {
    /// 14 Nov 2026, 21:42:05 in the local time zone, which today's names use.
    private static let date = Calendar.current.date(
        from: DateComponents(year: 2026, month: 11, day: 14, hour: 21, minute: 42, second: 5))!

    private static func page() -> ProcessedPage {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ProcessedPage(image: context.makeImage()!, resolution: 300, isBlank: false, source: .front, isColor: true)
    }

    private static func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("YomiFileNameTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Saves `pages` blank pages with `profile` into a fresh folder and returns the file names.
    private static func save(_ pages: Int, _ profile: ScanProfile, into folder: URL? = nil) throws -> [String] {
        var profile = profile
        profile.folderPath = try (folder ?? temporaryFolder()).path
        profile.searchablePDF = false
        let urls = try DocumentWriter.save(Array(repeating: page(), count: pages), profile: profile, date: date)
        return urls.map(\.lastPathComponent)
    }

    /// The version 1 fixture's scan profiles, with `changes` applied to each saved profile first.
    private static func v1Profile(named name: String, _ changes: [String: Any] = [:]) throws -> ScanProfile {
        let url = try #require(Bundle.module.url(forResource: "settings-v1", withExtension: "json",
                                                 subdirectory: "Fixtures"))
        var settings = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var profiles = try #require(settings["profiles"] as? [[String: Any]])
        let index = try #require(profiles.firstIndex { $0["name"] as? String == name })
        profiles[index].merge(changes) { $1 }
        settings["profiles"] = profiles
        let decoded = try AppSettings(json: JSONSerialization.data(withJSONObject: settings))
        return try #require(decoded.profiles.first { $0.name == name })
    }

    private static let nameAndNumber: [String: Any] = [
        "fileNaming": "prefixAndNumber", "filePrefix": " Invoice ", "nextNumber": 41, "numberDigits": 4,
    ]

    // MARK: Upgraded scan profiles name files exactly as before

    @Test func dateAndTimePDF() throws {
        let profile = try Self.v1Profile(named: "Scan to Yomi Folder")
        #expect(try Self.save(1, profile) == ["2026-11-14 21.42.05.pdf"])
        #expect(try Self.save(3, profile) == ["2026-11-14 21.42.05.pdf"])
    }

    @Test func dateAndTimeJPEG() throws {
        let profile = try Self.v1Profile(named: "Photos")
        #expect(try Self.save(1, profile) == ["2026-11-14 21.42.05_001.jpg"])
        #expect(try Self.save(3, profile) == [
            "2026-11-14 21.42.05_001.jpg", "2026-11-14 21.42.05_002.jpg", "2026-11-14 21.42.05_003.jpg",
        ])
    }

    @Test func nameAndNumberPDF() throws {
        let profile = try Self.v1Profile(named: "Scan to Yomi Folder", Self.nameAndNumber)
        #expect(try Self.save(1, profile) == ["Invoice 0041.pdf"])
        #expect(try Self.save(3, profile) == ["Invoice 0041.pdf"])
        #expect(DocumentWriter.numbersUsed(pages: 3, profile: profile) == 1)
    }

    @Test func nameAndNumberJPEG() throws {
        let profile = try Self.v1Profile(named: "Photos", Self.nameAndNumber)
        #expect(try Self.save(1, profile) == ["Invoice 0041.jpg"])
        #expect(try Self.save(3, profile) == ["Invoice 0041.jpg", "Invoice 0042.jpg", "Invoice 0043.jpg"])
        #expect(DocumentWriter.numbersUsed(pages: 3, profile: profile) == 3)
    }

    @Test func nameAndNumberWithoutPrefix() throws {
        let profile = try Self.v1Profile(named: "Scan to Yomi Folder", ["fileNaming": "prefixAndNumber",
                                                                       "filePrefix": "  ", "nextNumber": 7])
        #expect(try Self.save(1, profile) == ["007.pdf"])
    }

    @Test func clashesGetANumber() throws {
        let profile = try Self.v1Profile(named: "Scan to Yomi Folder")
        let folder = try Self.temporaryFolder()
        #expect(try Self.save(1, profile, into: folder) == ["2026-11-14 21.42.05.pdf"])
        #expect(try Self.save(1, profile, into: folder) == ["2026-11-14 21.42.05 (2).pdf"])
        #expect(try Self.save(1, profile, into: folder) == ["2026-11-14 21.42.05 (3).pdf"])
    }
}
