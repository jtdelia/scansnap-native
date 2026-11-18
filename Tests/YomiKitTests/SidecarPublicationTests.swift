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

    @Test func collisionDuringPreparationRetriesBeforePublishingAnyFile() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        let source = folder.appendingPathComponent("completed.pdf")
        try Data("prepared PDF".utf8).write(to: source)
        let competitor = folder.appendingPathComponent("Receipt.pdf")
        let existing = Data("other PDF".utf8)
        let csv = Data("receipt".utf8)
        let urls = try DocumentWriter.publishPDF(source, sidecars: [("csv", csv)], in: folder, name: .init(stem: "Receipt")) { data, file in
            if !fm.fileExists(atPath: competitor.path) { try existing.write(to: competitor, options: .withoutOverwriting) }
            try file.write(contentsOf: data)
        }
        #expect(urls.map(\.lastPathComponent) == ["Receipt (2).pdf", "Receipt (2).csv"])
        #expect(try Data(contentsOf: urls[0]) == Data(contentsOf: source))
        #expect(try Data(contentsOf: urls[1]) == csv)
        #expect(try Data(contentsOf: competitor) == existing)
        #expect(try filesAfterReleasingReservations(in: folder) == ["Receipt (2).csv", "Receipt (2).pdf", "Receipt.pdf", "completed.pdf"])
    }

    @Test(arguments: [false, true])
    func partialExportPreservesCompetingFilesAndReportsFinalPaths(diskFull: Bool) throws {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: folder) }
        let profile = ScanProfile(name: "Scan", folderPath: folder.path, exportFields: true, namePattern: [.profileName])
        let (batch, staged) = try OCRBatch.stage([DocumentFixture.blank], profile: profile, date: Date())
        defer { try? fm.removeItem(at: staged) }
        try batch.writePDFs(in: staged)
        let pdf = staged.appendingPathComponent("result-0.pdf")
        let page = staged.appendingPathComponent(try #require(batch.documents.first?.pages.first?.file))
        let prepared = try Data(contentsOf: pdf), original = try Data(contentsOf: page)
        let directory = try PDFDirectory(ScanFolder(root: folder, subfolders: []))
        let reservation = try #require(try PDFReservation.claim(.init(stem: "Receipt"), in: directory))
        let bytes = [Data("CSV".utf8), Data("JSON".utf8)]
        let names = ["Receipt.pdf", "Receipt.csv", "Receipt.json"].map { folder.appendingPathComponent($0) }
        let competing = Data("other writer".utf8)
        let replaced = Data("replacement CSV".utf8)
        let result = Result {
            try reservation.publishGroup(names, pdf: pdf, publish: { source, staging, name, parent, owningCopy in
                if name == names[0].lastPathComponent {
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
        #expect(try Data(contentsOf: names[0]) == (diskFull ? Data("AB".utf8) : competing))
        #expect(try Data(contentsOf: names[1]) == replaced)
        #expect(try Data(contentsOf: names[2]) == bytes[1])
        #expect(try filesAfterReleasingReservations(in: folder) == names.map(\.lastPathComponent).sorted())
        let error = try #require(throws: (any Error).self) { try result.get() }
        #expect(error.localizedDescription.contains("Partial export"))
        #expect(error.localizedDescription.contains(names[0].path))
        #expect(error.localizedDescription.contains(names[1].path))
        #expect(error.localizedDescription.contains(names[2].path))
        #expect(error.localizedDescription.contains(pdf.path))
        #expect(try Data(contentsOf: pdf) == prepared)
        #expect(try Data(contentsOf: page) == original)
    }

    @Test func replacingAPublishedSidecarPreventsReportingACompleteGroup() throws {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: folder) }
        let directory = try PDFDirectory(ScanFolder(root: folder, subfolders: []))
        let reservation = try #require(try PDFReservation.claim(.init(stem: "Receipt"), in: directory))
        let names = ["Receipt.pdf", "Receipt.csv"].map { folder.appendingPathComponent($0) }
        let pdf = folder.appendingPathComponent("completed.pdf")
        try Data([42]).write(to: pdf)
        let replacement = Data("another receipt".utf8)
        let result = Result {
            try reservation.publishGroup(names, pdf: pdf, publish: { source, staging, name, parent, owningCopy in
                if name == "Receipt.pdf" {
                    do { try replacement.write(to: names[1], options: .atomic) } catch { return EIO }
                }
                return publishFile(source, from: staging, as: name, in: parent, owningCopy: owningCopy)
            }) { _, file in try file.write(contentsOf: Data([42])) }
        }
        let error = try #require(throws: (any Error).self) { try result.get() }
        #expect(error.localizedDescription.contains("Partial export"))
        #expect(error.localizedDescription.contains(names[1].path))
        #expect(error.localizedDescription.contains(names[0].path))
        #expect(try Data(contentsOf: names[1]) == replacement)
        #expect(try Data(contentsOf: names[0]) == Data([42]))
        #expect(try filesAfterReleasingReservations(in: folder) == ["Receipt.csv", "Receipt.pdf", "completed.pdf"])
    }

    @Test func movingTheFolderReportsTheSidecarInItsNewLocation() throws {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("Scans")
        let moved = folder.appendingPathComponent("Moved")
        let directory = try PDFDirectory(ScanFolder(root: destination, subfolders: []))
        let reservation = try #require(try PDFReservation.claim(.init(stem: "Receipt"), in: directory))
        let names = ["Receipt.pdf", "Receipt.csv"].map { destination.appendingPathComponent($0) }
        let pdf = folder.appendingPathComponent("completed.pdf")
        try Data([42]).write(to: pdf)
        let error = try #require(throws: CocoaError.self) {
            try reservation.publishGroup(names, pdf: pdf, publish: { source, staging, name, parent, owningCopy in
                if name == "Receipt.pdf" {
                    do {
                        try fm.moveItem(at: destination, to: moved)
                        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
                    } catch { return EIO }
                    return ENOSPC
                }
                return publishFile(source, from: staging, as: name, in: parent, owningCopy: owningCopy)
            }) { _, file in try file.write(contentsOf: Data([42])) }
        }
        let csv = moved.appendingPathComponent("Receipt.csv")
        #expect(error.localizedDescription.contains(csv.resolvingSymlinksInPath().path))
        #expect(try Data(contentsOf: csv) == Data([42]))
        #expect(try filesAfterReleasingReservations(in: moved) == ["Receipt.csv"])
        #expect(try fm.contentsOfDirectory(atPath: destination.path).isEmpty)
    }
}
