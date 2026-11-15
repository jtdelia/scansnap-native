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

    // MARK: Name patterns

    @Test func patternPiecesAndText() throws {
        var profile = ScanProfile(name: "Bank")
        profile.namePattern = [.profileName, .text(" "), .day, .text("."), .month, .text("."), .year,
                               .text(" at "), .time, .text(" ("), .date, .text(")")]
        #expect(try Self.save(1, profile) == ["Bank 14.11.2026 at 21.42.05 (2026-11-14).pdf"])
    }

    @Test func disallowedCharactersAreReplaced() throws {
        let profile = ScanProfile(name: "Bills 1/2: Gas", namePattern: [.profileName, .text(" a/b:c")])
        #expect(try Self.save(1, profile) == ["Bills 1-2- Gas a-b-c.pdf"])
    }

    @Test func emptyNameFallsBackToDateAndTime() throws {
        #expect(try Self.save(1, ScanProfile(name: "Empty", namePattern: [])) == ["2026-11-14 21.42.05.pdf"])
        let blank = ScanProfile(name: " ", fileFormat: .jpeg, namePattern: [.profileName, .text("  ")])
        #expect(try Self.save(2, blank) == ["2026-11-14 21.42.05_001.jpg", "2026-11-14 21.42.05_002.jpg"])
    }

    @Test func longNamesAreShortened() throws {
        let ascii = ScanProfile(name: "Long", namePattern: [.text(String(repeating: "a", count: 300))])
        #expect(try Self.save(1, ascii) == [String(repeating: "a", count: 200) + ".pdf"])
        let accented = ScanProfile(name: "Long", namePattern: [.text(String(repeating: "é", count: 300))])
        let name = try #require(try Self.save(1, accented).first)
        #expect(name.precomposedStringWithCanonicalMapping == String(repeating: "é", count: 66) + ".pdf")
    }

    @Test func pageSuffixOnlyWhenSeveralFilesAndNoNumber() throws {
        let jpeg = ScanProfile(name: "Bank", fileFormat: .jpeg, namePattern: [.profileName])
        #expect(try Self.save(1, jpeg) == ["Bank.jpg"])
        #expect(try Self.save(2, jpeg) == ["Bank_001.jpg", "Bank_002.jpg"])

        let pdf = ScanProfile(name: "Bank", namePattern: [.profileName])
        #expect(try Self.save(3, pdf) == ["Bank.pdf"])

        var numbered = jpeg
        numbered.namePattern = [.profileName, .text(" "), .runningNumber]
        numbered.nextNumber = 9
        numbered.numberDigits = 2
        #expect(try Self.save(2, numbered) == ["Bank 09.jpg", "Bank 10.jpg"])

        var paged = jpeg
        paged.namePattern = [.profileName, .text(" p"), .pageNumber]
        #expect(try Self.save(2, paged) == ["Bank p001.jpg", "Bank p002.jpg"])
    }

    @Test func runningNumberAdvancesOnlyWhenUsed() {
        let numbered = ScanProfile(name: "A", fileFormat: .jpeg, namePattern: .nameAndNumber("Scan"))
        #expect(DocumentWriter.numbersUsed(pages: 3, profile: numbered) == 3)
        #expect(DocumentWriter.numbersUsed(pages: 0, profile: numbered) == 0)
        let dated = ScanProfile(name: "A", fileFormat: .jpeg)
        #expect(DocumentWriter.numbersUsed(pages: 3, profile: dated) == 0)
    }

    @Test func exampleFileName() throws {
        let profile = ScanProfile(name: "Bank", fileFormat: .jpeg, namePattern: [.profileName, .text(" "), .date])
        #expect(DocumentWriter.exampleFileName(for: profile, date: Self.date) == "Bank 2026-11-14_001.jpg")
        let upgraded = try Self.v1Profile(named: "Scan to Yomi Folder", Self.nameAndNumber)
        #expect(DocumentWriter.exampleFileName(for: upgraded, date: Self.date) == "Invoice 0041.pdf")
    }

    @Test func savedPatternsRoundTrip() throws {
        let pattern: FileNamePattern = [.text("Scan {x} "), .profileName, .runningNumber, .pageNumber, .date, .time,
                                        .year, .month, .day]
        let settings = AppSettings(profiles: [ScanProfile(name: "A", namePattern: pattern)])
        #expect(try AppSettings(json: settings.json()).profiles.first?.namePattern == pattern)
    }

    // MARK: Subfolders

    /// Saves `pages` blank pages into a fresh scan profile folder and returns each file's path inside it.
    private static func savedPaths(_ pages: Int, _ profile: ScanProfile) throws -> [String] {
        let folder = try temporaryFolder().resolvingSymlinksInPath()
        var profile = profile
        profile.folderPath = folder.path
        profile.searchablePDF = false
        let urls = try DocumentWriter.save(Array(repeating: page(), count: pages), profile: profile, date: date)
        return urls.map { url in
            let path = url.resolvingSymlinksInPath().path
            return path.hasPrefix(folder.path + "/") ? String(path.dropFirst(folder.path.count + 1)) : path
        }
    }

    @Test func subfoldersNestAndAreCreated() throws {
        let pdf = ScanProfile(name: "Bank", subfolderPattern: [.year, .text("/"), .month])
        #expect(try Self.savedPaths(2, pdf) == ["2026/11/2026-11-14 21.42.05.pdf"])
        var jpeg = pdf
        jpeg.fileFormat = .jpeg
        #expect(try Self.savedPaths(2, jpeg) == ["2026/11/2026-11-14 21.42.05_001.jpg",
                                                 "2026/11/2026-11-14 21.42.05_002.jpg"])
    }

    @Test(arguments: [
        ([.text("..")], "2026-11-14 21.42.05.pdf"),
        ([.text("../../escape")], "escape/2026-11-14 21.42.05.pdf"),
        ([.text("/tmp/"), .year], "tmp/2026/2026-11-14 21.42.05.pdf"),
        ([.text("a/./../b/..")], "a/b/2026-11-14 21.42.05.pdf"),
        ([.text(" .. / . /")], "2026-11-14 21.42.05.pdf"),
        ([.year, .text("//"), .profileName, .text("/ /"), .month], "2026/11/2026-11-14 21.42.05.pdf"),
    ] as [(FileNamePattern, String)])
    func subfoldersStayInsideTheFolder(pattern: FileNamePattern, path: String) throws {
        #expect(try Self.savedPaths(1, ScanProfile(name: "  ", subfolderPattern: pattern)) == [path])
    }

    @Test func profileNameIsOneFolderLevel() throws {
        let profile = ScanProfile(name: "../Bills 1/2: Gas", namePattern: .dateAndTime, subfolderPattern: [.profileName])
        #expect(try Self.savedPaths(1, profile) == ["..-Bills 1-2- Gas/2026-11-14 21.42.05.pdf"])
    }

    @Test func subfoldersUseOnlyBatchWidePieces() throws {
        #expect(FileNamePattern.Piece.batchWide == [.date, .year, .month, .day, .profileName])
        let profile = ScanProfile(name: "Bank", fileFormat: .jpeg, namePattern: [.runningNumber],
                                  subfolderPattern: [.text("n"), .runningNumber, .text("/p"), .pageNumber, .time,
                                                     .text("/"), .date])
        #expect(try Self.savedPaths(2, profile) == ["n/p/2026-11-14/001.jpg", "n/p/2026-11-14/002.jpg"])
    }

    @Test func subfoldersAreOffByDefault() throws {
        #expect(ScanProfile(name: "A").subfolderPattern == [])
        let upgraded = try Self.v1Profile(named: "Scan to Yomi Folder")
        #expect(upgraded.subfolderPattern == [])
        #expect(try Self.savedPaths(1, upgraded) == ["2026-11-14 21.42.05.pdf"])
        let pattern: FileNamePattern = [.text("Scans/"), .year, .text("/"), .profileName]
        let settings = AppSettings(profiles: [ScanProfile(name: "A", subfolderPattern: pattern)])
        #expect(try AppSettings(json: settings.json()).profiles.first?.subfolderPattern == pattern)
    }

    @Test func exampleSubfolder() {
        let profile = ScanProfile(name: "Bank", subfolderPattern: [.text("../"), .profileName, .text("/"), .year])
        #expect(DocumentWriter.exampleSubfolder(for: profile, date: Self.date) == "Bank/2026")
        #expect(DocumentWriter.exampleSubfolder(for: ScanProfile(name: "Bank"), date: Self.date) == "")
    }

    @Test func editorText() {
        let pattern: FileNamePattern = [.text("Scan "), .profileName, .text(" "), .runningNumber]
        #expect(pattern.editorText == "Scan {profile} {number}")
        #expect(FileNamePattern(editorText: "Scan {profile} {number}") == pattern)
        #expect(FileNamePattern(editorText: "{year}-{month} {nope}{") == [.year, .text("-"), .month, .text(" {nope}{")])
    }
}
