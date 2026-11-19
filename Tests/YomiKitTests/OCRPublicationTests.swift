import Foundation
import ImageIO
import Testing
@testable import YomiKit

struct OCRPublicationTests {
    private let fm = FileManager.default
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YomiPublicationTests-\(UUID())")

    private func page(width: Int) throws -> ProcessedPage {
        let context = try #require(CGContext(data: nil, width: width, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        return ProcessedPage(image: try #require(context.makeImage()), resolution: 300, isBlank: false, source: .front, isColor: false)
    }

    private func expectOriginals(in recovery: URL, widths: [Int] = [12, 24]) throws {
        for (index, width) in widths.enumerated() {
            let file = recovery.appendingPathComponent("page-\(index + 1).png")
            let source = try #require(CGImageSourceCreateWithURL(file as CFURL, nil))
            #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == width)
        }
    }

    @Test(arguments: [true, false])
    func destinationFailureReportsWhereBothPagesCanBeRecovered(readOnly: Bool) throws {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let destination = readOnly ? folder : folder.appendingPathComponent("missing/Scans")
        if readOnly {
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        } else {
            try Data().write(to: folder.appendingPathComponent("missing"))
        }
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let profile = ScanProfile(name: "Bills", folderPath: destination.path)
        let error = try #require(throws: (any Error).self) {
            let (_, job) = try BatchSaver.start([page(width: 12), page(width: 24)], profile: profile, photoLibrary: nil,
                                                helper: URL(fileURLWithPath: "/usr/bin/false"))
            try job?.wait()
        }
        let recovery = try #require((error as? OCRRecoveryError)?.folder)
        #expect(error.localizedDescription.contains(recovery.path))
        defer { try? fm.removeItem(at: recovery) }
        try expectOriginals(in: recovery)
    }

    @Test(arguments: [true, false], [0, 1])
    func linkedGeneratedFolderKeepsTheOriginalPages(searchable: Bool, linkedLevel: Int) throws {
        defer { try? fm.removeItem(at: folder) }
        let root = folder.appendingPathComponent("Scans")
        let outside = folder.appendingPathComponent("Outside")
        let date = Date()
        let profile = ScanProfile(name: "Bills", folderPath: root.path, searchablePDF: searchable,
                                  subfolderPattern: [.year, .text("/"), .month])
        let month = DocumentWriter.saveFolder(for: profile, date: date)
        let link = linkedLevel == 0 ? month.deletingLastPathComponent() : month
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let error = try #require(throws: OCRRecoveryError.self) {
            try BatchSaver.save([page(width: 12), page(width: 24)], profile: profile, photoLibrary: nil, date: date)
        }
        defer { try? fm.removeItem(at: error.folder) }
        #expect(error.localizedDescription.contains(link.path))
        #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
        try expectOriginals(in: error.folder)
    }

    @Test func stagedBatchRejectsAGeneratedLinkEvenWhenItStillNamesTheReservedDirectory() throws {
        defer { try? fm.removeItem(at: folder) }
        let root = folder.appendingPathComponent("Scans")
        let outside = folder.appendingPathComponent("Moved")
        let profile = ScanProfile(name: "Bills", folderPath: root.path, subfolderPattern: [.year, .text("/"), .month])
        let date = Date()
        let (batch, staged) = try OCRBatch.stage([page(width: 12), page(width: 24)], profile: profile, date: date)
        defer { try? fm.removeItem(at: staged) }
        try batch.writePDFs(in: staged)
        let month = DocumentWriter.saveFolder(for: profile, date: date)
        try fm.moveItem(at: month, to: outside)
        try fm.createSymbolicLink(at: month, withDestinationURL: outside)
        let job = OCRJob(batch: batch, folder: staged, helper: URL(fileURLWithPath: "/usr/bin/true"))
        let error = try #require(throws: OCRRecoveryError.self) { try job.wait() }
        #expect(error.folder == staged)
        try expectOriginals(in: staged)
        #expect(try filesAfterReleasingReservations(in: outside).isEmpty)
    }

    @Test func readersOnlySeeCompletedPDFsAndACompetingFileSurvives() throws {
        defer { try? fm.removeItem(at: folder) }
        let profile = ScanProfile(name: "Bills", folderPath: folder.path, pagesPerFile: 1, namePattern: [.profileName])
        let (batch, staged) = try OCRBatch.stage([page(width: 12), page(width: 24)], profile: profile, date: Date())
        defer { try? fm.removeItem(at: staged) }
        let outputs = batch.documents.map(\.outputURL)
        #expect(outputs.map { fm.fileExists(atPath: $0.path) } == [false, false])
        try batch.writePDFs(in: staged)
        let foreign = Data("another scan".utf8)
        try foreign.write(to: outputs[1], options: .atomic)
        let job = OCRJob(batch: batch, folder: staged, helper: URL(fileURLWithPath: "/usr/bin/true"))
        let error = try #require(throws: (any Error).self) { try job.wait() }
        #expect(error.localizedDescription.contains(staged.path))
        #expect(error.localizedDescription.contains(outputs[1].path))
        #expect(CGPDFDocument(outputs[0] as CFURL)?.numberOfPages == 1)
        #expect(try Data(contentsOf: outputs[1]) == foreign)
        #expect(try filesAfterReleasingReservations(in: folder) == outputs.map(\.lastPathComponent))
        try expectOriginals(in: staged)
    }

    @Test func failedBatchReleasesItsUnusedNames() throws {
        defer { try? fm.removeItem(at: folder) }
        let pages = try [page(width: 12), page(width: 24)]
        let profile = ScanProfile(name: "Bills", folderPath: folder.path, pagesPerFile: 1, namePattern: [.profileName])
        let first = folder.appendingPathComponent("Bills_001.pdf")
        do {
            let (batch, staged) = try OCRBatch.stage(pages, profile: profile, date: Date())
            defer { try? fm.removeItem(at: staged) }
            try Data([1]).write(to: first)
            let job = OCRJob(batch: batch, folder: staged, helper: URL(fileURLWithPath: "/usr/bin/false"))
            #expect(throws: OCRRecoveryError.self) { try job.wait() }
        }
        let (saved, job) = try BatchSaver.start(pages, profile: profile, photoLibrary: nil, helper: URL(fileURLWithPath: "/usr/bin/false"))
        try job?.wait()
        #expect(saved.files.map(\.lastPathComponent) == ["Bills_001 (2).pdf", "Bills_002.pdf"])
        #expect(try Data(contentsOf: first) == Data([1]))
    }

    @Test func imageOnlyPublishesTheFileItEncodedInTheScanFolder() throws {
        defer { try? fm.removeItem(at: folder) }
        let profile = ScanProfile(name: "Bills", folderPath: folder.path, searchablePDF: false, namePattern: [.profileName])
        var inodes: [NSNumber] = []
        let saved = try BatchSaver.save([page(width: 12)], profile: profile, photoLibrary: nil) { _ in
            do {
                let entries = try fm.subpathsOfDirectory(atPath: folder.path)
                #expect(!entries.contains("Bills.pdf"))
                inodes = try entries.compactMap { entry in
                    let attributes = try fm.attributesOfItem(atPath: folder.appendingPathComponent(entry).path)
                    return attributes[.systemFileNumber] as? NSNumber
                }
            } catch { Issue.record(error) }
        }
        let pdf = try #require(saved.files.first)
        let inode = try #require(try fm.attributesOfItem(atPath: pdf.path)[.systemFileNumber] as? NSNumber)
        #expect(inodes.contains(inode))
    }

    @Test func aPreparedPDFRemainsRecoverableWhenAnOriginalCannotBeWritten() throws {
        defer { try? fm.removeItem(at: folder) }
        let selected = folder.appendingPathComponent("selected")
        let staged = folder.appendingPathComponent("recovery")
        try fm.createDirectory(at: staged.appendingPathComponent("page-2.png"), withIntermediateDirectories: true)
        let profile = ScanProfile(name: "Bills", folderPath: selected.path, searchablePDF: false)
        let recovery = OCRRecoveryError(folder: staged, saved: 0, total: 2, cause: POSIXError(.ENOSPC))
        let error = try #require(throws: OCRRecoveryError.self) {
            try DocumentWriter.savePDFs([page(width: 12), page(width: 24)], profile: profile, date: Date(), progress: { message in
                if message == "Saving page 2 of 2…" {
                    do { try fm.moveItem(at: selected, to: folder.appendingPathComponent("moved")) }
                    catch { Issue.record(error) }
                }
            }, recovery: recovery)
        }
        #expect(error.folder == staged)
        #expect(error.saved == 1)
        try expectOriginals(in: staged, widths: [12])
        let prepared = staged.appendingPathComponent("pages-1.pdf")
        #expect(CGPDFDocument(prepared as CFURL)?.numberOfPages == 2)
    }

    @Test func imageOnlySplitRetriesANameTakenWhileWritingTheSecondPage() throws {
        defer { try? fm.removeItem(at: folder) }
        let profile = ScanProfile(name: "Bills", folderPath: folder.path, searchablePDF: false,
                                  pagesPerFile: 1, namePattern: [.profileName])
        let second = folder.appendingPathComponent("Bills_002.pdf")
        let foreign = Data("another scan".utf8)
        let pages = try [page(width: 12), page(width: 24), page(width: 36)]
        var updates: [String] = []
        let saved = try BatchSaver.save(pages, profile: profile, photoLibrary: nil) { message in
            updates.append(message)
            if message == "Saving page 2 of 3…" {
                #expect(fm.fileExists(atPath: second.path) == false)
                do { try foreign.write(to: second, options: .withoutOverwriting) } catch { Issue.record(error) }
            }
        }
        #expect(updates == ["Saving page 1 of 3…", "Saving page 2 of 3…", "Saving page 3 of 3…"])
        #expect(saved.files.map(\.lastPathComponent) == ["Bills_001.pdf", "Bills_002 (2).pdf", "Bills_003.pdf"])
        for (output, page) in zip(saved.files, pages) {
            let pdf = try #require(CGPDFDocument(output as CFURL))
            #expect(pdf.numberOfPages == 1)
            let width = try #require(pdf.page(at: 1)).getBoxRect(.mediaBox).width
            #expect(abs(width - Double(page.image.width) * 72 / 300) < 0.001)
        }
        #expect(try Data(contentsOf: second) == foreign)
        #expect(try filesAfterReleasingReservations(in: folder) == (saved.files + [second]).map(\.lastPathComponent).sorted())
    }

    @Test(arguments: [true, false])
    func stagedBatchRecoversWhenItsDestinationChanges(isAlias: Bool) throws {
        defer { try? fm.removeItem(at: folder) }
        let selected = folder.appendingPathComponent("selected", isDirectory: true)
        let original = folder.appendingPathComponent("original", isDirectory: true)
        let replacement = folder.appendingPathComponent("replacement", isDirectory: true)
        try fm.createDirectory(at: replacement, withIntermediateDirectories: true)
        if isAlias {
            try fm.createDirectory(at: original, withIntermediateDirectories: false)
            try fm.createSymbolicLink(at: selected, withDestinationURL: original)
        } else {
            try fm.createDirectory(at: selected, withIntermediateDirectories: false)
        }
        let profile = ScanProfile(name: "Bills", folderPath: selected.path, namePattern: [.profileName])
        let (batch, staged) = try OCRBatch.stage([page(width: 12), page(width: 24)], profile: profile, date: Date())
        defer { try? fm.removeItem(at: staged) }
        try batch.writePDFs(in: staged)
        if isAlias {
            try fm.removeItem(at: selected)
            try fm.createSymbolicLink(at: selected, withDestinationURL: replacement)
        } else {
            try fm.moveItem(at: selected, to: original)
            try fm.moveItem(at: replacement, to: selected)
        }
        let job = OCRJob(batch: batch, folder: staged, helper: URL(fileURLWithPath: "/usr/bin/true"))
        let error = try #require(throws: OCRRecoveryError.self) { try job.wait() }
        #expect(error.folder == staged)
        try expectOriginals(in: staged)
        #expect(try fm.contentsOfDirectory(atPath: selected.path).isEmpty)
        #expect(try filesAfterReleasingReservations(in: original).isEmpty)
    }

    @Test func aSelectedSymlinkSharesClaimsWithItsTargetAndPublishesThere() throws {
        defer { try? fm.removeItem(at: folder) }
        let target = folder.appendingPathComponent("target", isDirectory: true)
        let selected = folder.appendingPathComponent("alias", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: selected, withDestinationURL: target)
        var profile = ScanProfile(name: "Bills", folderPath: selected.path, namePattern: [.profileName])
        let (batch, staged) = try OCRBatch.stage([page(width: 12)], profile: profile, date: Date())
        defer { try? fm.removeItem(at: staged) }
        profile.folderPath = target.path
        profile.searchablePDF = false
        let second = try DocumentWriter.save([page(width: 24)], profile: profile)
        #expect(second.map(\.lastPathComponent) == ["Bills (2).pdf"])
        try batch.writePDFs(in: staged)
        try batch.publish(in: staged)
        let first = try #require(batch.documents.first?.outputURL)
        #expect(first.path == selected.appendingPathComponent("Bills.pdf").path)
        #expect(CGPDFDocument(first as CFURL)?.numberOfPages == 1)
        #expect(try filesAfterReleasingReservations(in: target) == ["Bills (2).pdf", "Bills.pdf"])
    }

    @Test func movingTheFolderDuringAnImageOnlySplitKeepsTheFirstPDFAndAllOriginals() throws {
        defer { try? fm.removeItem(at: folder) }
        let selected = folder.appendingPathComponent("selected", isDirectory: true)
        let moved = folder.appendingPathComponent("moved", isDirectory: true)
        let profile = ScanProfile(name: "Bills", folderPath: selected.path, searchablePDF: false,
                                  pagesPerFile: 1, namePattern: [.profileName])
        let error = try #require(throws: OCRRecoveryError.self) {
            try BatchSaver.save([page(width: 12), page(width: 24), page(width: 36)], profile: profile, photoLibrary: nil) { message in
                if message == "Saving page 2 of 3…" {
                    do {
                        try fm.moveItem(at: selected, to: moved)
                        try fm.createDirectory(at: selected, withIntermediateDirectories: false)
                    } catch { Issue.record(error) }
                }
            }
        }
        defer { try? fm.removeItem(at: error.folder) }
        try expectOriginals(in: error.folder, widths: [12, 24, 36])
        let prepared = error.folder.appendingPathComponent("pages-2.pdf")
        let pdf = try #require(CGPDFDocument(prepared as CFURL))
        #expect(pdf.numberOfPages == 1)
        #expect(abs(try #require(pdf.page(at: 1)).getBoxRect(.mediaBox).width - 5.76) < 0.001)
        #expect(try fm.contentsOfDirectory(atPath: selected.path).isEmpty)
        #expect(try filesAfterReleasingReservations(in: moved) == ["Bills_001.pdf"])
        #expect(CGPDFDocument(moved.appendingPathComponent("Bills_001.pdf") as CFURL)?.numberOfPages == 1)
    }
}
