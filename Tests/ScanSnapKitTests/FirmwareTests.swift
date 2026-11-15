import Foundation
import Testing
@testable import ScanSnapKit

struct FirmwareTests {
    private func writeFile(named name: String, contents: Data) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    private func validImage() -> Data {
        var data = Data(count: Firmware.fileSize)
        data.replaceSubrange(0..<4, with: Data("NDL1".utf8))
        return data
    }

    @Test func parsesVersionAndImage() throws {
        let url = try writeFile(named: "1300_0C26.nal", contents: validImage())
        let firmware = try Firmware(url: url)
        #expect(firmware.version == "0C26")
        #expect(firmware.image.count == 0x10000)
    }

    @Test func rejectsWrongSize() throws {
        let url = try writeFile(named: "1300_0C26.nal", contents: Data(count: 1024))
        #expect(throws: ScannerError.self) { try Firmware(url: url) }
    }

    @Test func rejectsMissingHeader() throws {
        let url = try writeFile(named: "1300_0C26.nal", contents: Data(count: Firmware.fileSize))
        #expect(throws: ScannerError.self) { try Firmware(url: url) }
    }

    @Test func locatePicksNewestVersion() throws {
        let older = try writeFile(named: "1300_0C25.nal", contents: validImage())
        let dir = older.deletingLastPathComponent()
        try validImage().write(to: dir.appendingPathComponent("1300_0C26.nal"))
        let found = try #require(Firmware.locate(for: .s1300, in: [dir]))
        #expect(found.version == "0C26")
    }
}
