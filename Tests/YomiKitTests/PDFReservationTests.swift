import CoreGraphics
import Foundation
import Testing
@testable import YomiKit

func filesAfterReleasingReservations(in folder: URL, format: ScanProfile.FileFormat = .pdf) throws -> [String] {
    let fm = FileManager.default
    let entries = try fm.contentsOfDirectory(atPath: folder.path)
    guard format == .pdf else { return entries.sorted() }
    for name in entries where name.hasPrefix(".Yomi-PDF-") {
        #expect(try fm.contentsOfDirectory(atPath: folder.appendingPathComponent(name).path).isEmpty)
    }
    return entries.filter { !$0.hasPrefix(".Yomi-PDF-") }.sorted()
}

struct PDFReservationTests {
    private let fm = FileManager.default
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YomiReservationTests-\(UUID())")
    private let name = DocumentWriter.FileName(stem: "Scan")

    private static func openDirectory(_ root: URL) throws -> PDFDirectory {
        try PDFDirectory(ScanFolder(root: root, subfolders: []))
    }

    private var scanMarker: URL {
        folder.appendingPathComponent(".Yomi-PDF-900db3ec3bae665c4655646b584de4b76db637cb94a959a2ebb7a5fa5534aae6")
    }

    private func pdf(width: CGFloat) throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var page = CGRect(x: 0, y: 0, width: width, height: 72)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &page, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    @Test func releasingAnAdoptedDirectoryPreservesItAndMakesTheNameAvailable() throws {
        defer { try? fm.removeItem(at: folder) }
        let directory = try Self.openDirectory(folder)
        try fm.createDirectory(at: scanMarker, withIntermediateDirectories: false)
        let first = try #require(try PDFReservation.claim(name, in: directory))
        #expect(try PDFReservation.claim(name, in: Self.openDirectory(folder)) == nil)
        first.release()
        #expect(fm.fileExists(atPath: scanMarker.path))
        let second = try #require(try PDFReservation.claim(name, in: directory))
        first.release()
        #expect(try PDFReservation.claim(name, in: directory) == nil)
        second.release()
        #expect(try fm.contentsOfDirectory(atPath: scanMarker.path).isEmpty)
    }

    @Test func legacyMarkerKeepsItsOriginalDocument() throws {
        defer { try? fm.removeItem(at: folder) }
        let directory = try Self.openDirectory(folder)
        try fm.createDirectory(at: scanMarker, withIntermediateDirectories: false)
        let document = scanMarker.appendingPathComponent("document.pdf")
        let original = try pdf(width: 72)
        try original.write(to: document, options: .withoutOverwriting)
        let next = try #require(try PDFReservation.claim(name, in: directory))
        let replacement = try pdf(width: 144)
        _ = try next.publish(pages: 1) { try $0.write(contentsOf: replacement) }
        next.release()
        #expect(try Data(contentsOf: folder.appendingPathComponent("Scan.pdf")) == replacement)
        #expect(try Data(contentsOf: document) == original)
        #expect(try fm.contentsOfDirectory(atPath: scanMarker.path) == ["document.pdf"])
    }

    @Test func releasingAMovedMarkerLeavesItsReplacementLocked() throws {
        defer { try? fm.removeItem(at: folder) }
        let directory = try Self.openDirectory(folder)
        let first = try #require(try PDFReservation.claim(name, in: directory))
        try fm.moveItem(at: scanMarker, to: folder.appendingPathComponent("moved"))
        let second = try #require(try PDFReservation.claim(name, in: directory))
        defer { second.release() }
        first.release()
        #expect(try PDFReservation.claim(name, in: directory) == nil)
    }

    @Test(arguments: [0o000, 0o555])
    func anInaccessibleMarkerLeavesTheNextNameAvailable(permissions: Int) throws {
        defer { try? fm.removeItem(at: folder) }
        let directory = try Self.openDirectory(folder)
        try fm.createDirectory(at: scanMarker, withIntermediateDirectories: false)
        try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: scanMarker.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scanMarker.path) }
        let next = try DocumentWriter.reservePDF(in: directory, name)
        #expect(next.output.lastPathComponent == "Scan (2).pdf")
        next.release()
        #expect(fm.fileExists(atPath: scanMarker.path))
    }

    @Test(arguments: [true, false])
    func aForeignMarkerFileOrSymlinkKeepsItsContents(isSymlink: Bool) throws {
        defer { try? fm.removeItem(at: folder) }
        let directory = try Self.openDirectory(folder)
        let target = folder.appendingPathComponent("target")
        let data = Data("another job".utf8)
        if isSymlink {
            try fm.createDirectory(at: target, withIntermediateDirectories: false)
            try fm.createSymbolicLink(at: scanMarker, withDestinationURL: target)
        } else {
            try data.write(to: scanMarker, options: .withoutOverwriting)
        }
        let next = try DocumentWriter.reservePDF(in: directory, name)
        #expect(next.output.lastPathComponent == "Scan (2).pdf")
        next.release()
        if isSymlink {
            #expect(try fm.destinationOfSymbolicLink(atPath: scanMarker.path) == target.path)
            #expect(try fm.contentsOfDirectory(atPath: target.path).isEmpty)
        } else {
            #expect(try Data(contentsOf: scanMarker) == data)
        }
    }

    @Test func killedWriterFreesOnlyItsNameAndPreservesItsStagedScan() async throws {
        defer { try? fm.removeItem(at: folder) }
        let directory = try Self.openDirectory(folder)
        let other = DocumentWriter.FileName(stem: "Other")
        let live = try #require(try PDFReservation.claim(other, in: directory))
        defer { live.release() }
        let staged = try pdf(width: 72)
        try await #require(processExitsWith: .signal(SIGKILL)) { [folder = folder as URL, staged = staged as Data] in
            let directory = try Self.openDirectory(folder)
            guard try PDFReservation.claim(.init(stem: "Other"), in: directory) == nil,
                  let writer = try PDFReservation.claim(.init(stem: "Scan"), in: directory) else { return }
            _ = try writer.publish(pages: 1) { file in
                try file.write(contentsOf: staged)
                raise(SIGKILL)
            }
        }

        let files = try fm.subpathsOfDirectory(atPath: folder.path)
        let stagedPath = try #require(files.first { $0.hasSuffix(".pdf") })
        let abandoned = folder.appendingPathComponent(stagedPath)
        #expect(CGPDFDocument(abandoned as CFURL)?.numberOfPages == 1)
        let foreign = abandoned.deletingLastPathComponent().appendingPathComponent("notes")
        try Data([1, 2, 3]).write(to: foreign, options: .withoutOverwriting)
        let next = try DocumentWriter.reservePDF(in: directory, name)
        #expect(next.output.lastPathComponent == "Scan.pdf")
        let replacement = try pdf(width: 144)
        _ = try next.publish(pages: 1) { try $0.write(contentsOf: replacement) }
        next.release()
        #expect(try Data(contentsOf: next.output) == replacement)
        #expect(try Data(contentsOf: abandoned) == staged)
        #expect(try Data(contentsOf: foreign) == Data([1, 2, 3]))
        #expect(try PDFReservation.claim(other, in: directory) == nil)
    }
}
