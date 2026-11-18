import Foundation
import Testing
@testable import YomiKit

struct PublishFileTests {
    @Test(arguments: [false, true])
    func failedExclusiveCopyKeepsTheFileAtTheDestination(replaced: Bool) throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        let directory = open(folder.path, O_SEARCH | O_CLOEXEC)
        try #require(directory >= 0)
        defer { close(directory) }
        let partial = Data("partial scan".utf8)
        let competing = Data("another file".utf8)
        try competing.write(to: folder.appendingPathComponent("other.pdf"))

        let code = writeExclusiveCopy(as: "scan.pdf", in: directory) { output in
            #expect(partial.withUnsafeBytes { write(output, $0.baseAddress, $0.count) } == partial.count)
            if replaced {
                #expect(renameat(directory, "other.pdf", directory, "scan.pdf") == 0)
            }
            return ENOSPC
        }

        #expect(code == ENOSPC)
        #expect(try Data(contentsOf: folder.appendingPathComponent("scan.pdf")) == (replaced ? competing : partial))
    }

    @Test func publishesFromAStagingSubfolderWithoutOverwritingAFileOrDanglingLink() throws {
        let fm = FileManager.default
        let volume = ProcessInfo.processInfo.environment["YOMI_TEST_VOLUME"].map { URL(filePath: $0) } ?? fm.temporaryDirectory
        let folder = volume.appendingPathComponent(UUID().uuidString)
        let staging = folder.appendingPathComponent("staging")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let source = open(staging.path, O_SEARCH | O_CLOEXEC)
        try #require(source >= 0)
        defer { close(source) }
        let destination = open(folder.path, O_SEARCH | O_CLOEXEC)
        try #require(destination >= 0)
        defer { close(destination) }

        let prepared = Data("completed scan".utf8)
        let existing = Data("existing file".utf8)
        let temp = staging.appendingPathComponent("scan.tmp")
        try prepared.write(to: temp)
        try existing.write(to: folder.appendingPathComponent("scan.pdf"))
        try fm.createSymbolicLink(atPath: folder.appendingPathComponent("scan (2).pdf").path, withDestinationPath: "missing")

        for name in ["scan.pdf", "scan (2).pdf"] {
            #expect(publishFile("scan.tmp", from: source, as: name, in: destination) == EEXIST)
        }
        #expect(try Data(contentsOf: folder.appendingPathComponent("scan.pdf")) == existing)
        #expect(try fm.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("scan (2).pdf").path) == "missing")
        #expect(!fm.fileExists(atPath: folder.appendingPathComponent("missing").path))
        try #require(publishFile("scan.tmp", from: source, as: "scan (3).pdf", in: destination) == 0)
        #expect(try Data(contentsOf: folder.appendingPathComponent("scan (3).pdf")) == prepared)
        #expect(!fm.fileExists(atPath: temp.path))
    }
}
