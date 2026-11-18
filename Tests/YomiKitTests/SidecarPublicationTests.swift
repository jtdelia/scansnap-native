import Foundation
import Testing
@testable import YomiKit

struct SidecarPublicationTests {
    let folder = (ProcessInfo.processInfo.environment["YOMI_TEST_VOLUME"].map { URL(filePath: $0) } ?? FileManager.default.temporaryDirectory)
        .appendingPathComponent("YomiSidecars-\(UUID())")

    @Test func partialSidecarWriteLeavesOnlyPriorFiles() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        let source = folder.appendingPathComponent("completed.pdf")
        let original = Data("completed scan".utf8)
        try original.write(to: source)
        let competitor = folder.appendingPathComponent("Prior.json")
        let existing = Data("previous receipt".utf8)
        try existing.write(to: competitor)
        let sidecars = [("csv", Data("complete".utf8)), ("json", Data("interrupted".utf8))]
        #expect(throws: POSIXError(.ENOSPC)) {
            try DocumentWriter.publishPDF(source, sidecars: sidecars, in: folder, name: .init(stem: "Receipt")) { data, file in
                if data == sidecars[1].1 {
                    try file.write(contentsOf: data.prefix(3))
                    throw POSIXError(.ENOSPC)
                }
                try file.write(contentsOf: data)
            }
        }
        let contents = try fm.contentsOfDirectory(atPath: folder.path)
        #expect(Set(contents.filter { !$0.hasPrefix(".Yomi-PDF-") }) == ["completed.pdf", "Prior.json"])
        for marker in contents where marker.hasPrefix(".Yomi-PDF-") {
            #expect(try fm.contentsOfDirectory(atPath: folder.appendingPathComponent(marker).path).isEmpty)
        }
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: competitor) == existing)
    }
    @Test func rollbackContinuesWhenOneOwnedSidecarCannotBeRemoved() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("YomiRollback-\(UUID())")
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        let directory = try PDFDirectory(ScanFolder(root: folder, subfolders: []))
        let reservation = try #require(try PDFReservation.claim(.init(stem: "Receipt"), in: directory))
        let names = ["Receipt.pdf", "Receipt.csv", "Receipt.json"].map { folder.appendingPathComponent($0) }
        defer { chflags(names[2].path, 0) }
        let error = try #require(throws: CocoaError.self) {
            try reservation.publishGroup(names, publish: { source, staging, name, parent, owningCopy in
                if name == "Receipt.pdf" {
                    #expect(chflags(names[2].path, UInt32(UF_IMMUTABLE)) == 0)
                    return ENOSPC
                }
                return publishFile(source, from: staging, as: name, in: parent, owningCopy: owningCopy)
            }) { _, file in try file.write(contentsOf: Data([42])) }
        }
        #expect(error.localizedDescription.contains("Receipt.json"))
        #expect(!fm.fileExists(atPath: names[0].path))
        #expect(!fm.fileExists(atPath: names[1].path))
        #expect(try Data(contentsOf: names[2]) == Data([42]))
    }

    @Test(arguments: [false, true])
    func midPublicationFailurePreservesCompetingFiles(diskFull: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        let directory = try PDFDirectory(ScanFolder(root: folder, subfolders: []))
        let reservation = try #require(try PDFReservation.claim(.init(stem: "Receipt"), in: directory))
        let bytes = [Data("PDF".utf8), Data("CSV".utf8), Data("JSON".utf8)]
        let names = ["Receipt.pdf", "Receipt.csv", "Receipt.json"].map { folder.appendingPathComponent($0) }
        let competing = Data("other writer".utf8)
        let replaced = Data("replacement CSV".utf8)
        let result = Result {
            try reservation.publishGroup(names, publish: { source, staging, name, parent, owningCopy in
                if name == "Receipt.pdf" {
                    do {
                        try replaced.write(to: names[1], options: .atomic)
                        if !diskFull { try competing.write(to: names[0], options: .withoutOverwriting) }
                    } catch { return EIO }
                    if diskFull {
                        return writeExclusiveCopy(as: name, in: parent, owningCopy: owningCopy) { fd in
                            #expect(write(fd, "AB", 2) == 2)
                            return ENOSPC
                        }
                    }
                }
                return publishFile(source, from: staging, as: name, in: parent, owningCopy: owningCopy)
            }) { index, file in try file.write(contentsOf: bytes[index]) }
        }
        if diskFull {
            #expect(throws: POSIXError(.ENOSPC)) { try result.get() }
            #expect(!fm.fileExists(atPath: names[0].path))
        } else {
            #expect(try !result.get())
            #expect(try Data(contentsOf: names[0]) == competing)
        }
        #expect(try Data(contentsOf: names[1]) == replaced)
        #expect(!fm.fileExists(atPath: names[2].path))
        for marker in try fm.contentsOfDirectory(atPath: folder.path) where marker.hasPrefix(".Yomi-PDF-") {
            #expect(try fm.contentsOfDirectory(atPath: folder.appendingPathComponent(marker).path).isEmpty)
        }
    }
}
