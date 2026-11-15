import Foundation
import Testing
@testable import YomiKit

/// macOS system colour profiles stand in for Fujitsu's `ScanSnap S1300.icm`, which is never committed.
struct ColorProfileTests {
    private static let systemProfiles = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles")
    private static let adobeRGB = systemProfiles.appendingPathComponent("AdobeRGB1998.icc")
    private static let gray = systemProfiles.appendingPathComponent("Generic Gray Gamma 2.2 Profile.icc")
    private static let displayP3 = systemProfiles.appendingPathComponent("Display P3.icc")

    private func temporaryFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func locateFindsAnRGBProfileInAFolder() throws {
        let dir = try temporaryFolder()
        try FileManager.default.copyItem(at: Self.adobeRGB, to: dir.appendingPathComponent("Scanner.icm"))
        let found = try #require(ColorProfile.locate(in: [dir]))
        #expect(found.url.lastPathComponent == "Scanner.icm")
        #expect(found.colorSpace.model == .rgb)
    }

    @Test func locateIgnoresNonRGBAndBrokenFiles() throws {
        let dir = try temporaryFolder()
        try FileManager.default.copyItem(at: Self.gray, to: dir.appendingPathComponent("Gray.icc"))
        try Data("not a colour profile".utf8).write(to: dir.appendingPathComponent("Broken.icm"))
        #expect(ColorProfile.locate(in: [dir]) == nil)
    }

    @Test func locateTriesLocationsInOrder() throws {
        let first = try temporaryFolder().appendingPathComponent("ScanSnap S1300.icm")
        try FileManager.default.copyItem(at: Self.adobeRGB, to: first)
        let second = try temporaryFolder()
        try FileManager.default.copyItem(at: Self.displayP3, to: second.appendingPathComponent("Chosen.icc"))
        #expect(ColorProfile.locate(in: [first, second])?.url == first)
        #expect(ColorProfile.locate(in: [first.appendingPathExtension("missing"), second])?.url.lastPathComponent == "Chosen.icc")
    }

    @Test func installReplacesTheChosenProfile() throws {
        let folder = try temporaryFolder().appendingPathComponent("ColorProfiles")
        _ = try ColorProfile.install(from: Self.displayP3, into: folder)
        let installed = try ColorProfile.install(from: Self.adobeRGB, into: folder)
        #expect(installed.url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(ColorProfile.locate(in: [folder])?.url.lastPathComponent == "AdobeRGB1998.icc")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["AdobeRGB1998.icc"])
    }

    @Test func reinstallingTheInstalledProfileKeepsIt() throws {
        let folder = try temporaryFolder()
        let installed = try ColorProfile.install(from: Self.adobeRGB, into: folder)
        try ColorProfile.install(from: installed.url, into: folder)
        #expect(ColorProfile.locate(in: [folder])?.url.lastPathComponent == "AdobeRGB1998.icc")
    }

    @Test func installRejectsANonRGBProfile() throws {
        let folder = try temporaryFolder()
        #expect(throws: ColorProfileError.self) { try ColorProfile.install(from: Self.gray, into: folder) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}
