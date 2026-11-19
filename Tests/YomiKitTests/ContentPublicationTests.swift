import PDFKit
import Testing
@testable import YomiKit

struct ContentPublicationTests {
    let folder = (ProcessInfo.processInfo.environment["YOMI_TEST_VOLUME"].map { URL(filePath: $0) }
        ?? FileManager.default.temporaryDirectory).appendingPathComponent("YomiContent-\(UUID())")
    let fm = FileManager.default

    @Test(arguments: [true, false])
    func splitContentNamesRespectReservationsAndGroupClashes(export: Bool) throws {
        defer { try? fm.removeItem(at: folder) }
        let profile = ScanProfile(name: "Receipts", folderPath: folder.path, exportFields: export, pagesPerFile: 1,
                                  namePattern: .init(editorText: "{merchant}"))
        let pages = [DocumentFixture.blank, DocumentFixture.blank]
        let (batch, staged) = try OCRBatch.stage(pages, profile: profile, date: .now)
        defer { try? fm.removeItem(at: staged) }
        let (other, pending) = try OCRBatch.stage(pages, profile: profile, date: .now)
        defer { try? fm.removeItem(at: pending) }
        #expect(Set(batch.documents.map(\.outputURL)).isDisjoint(with: other.documents.map(\.outputURL)))
        let competing = folder.appendingPathComponent(export ? "Corner Shop_002.json" : "Corner Shop_002.pdf")
        try Data([42]).write(to: competing, options: .withoutOverwriting)
        let fields = Dictionary(uniqueKeysWithValues: batch.documents.map { ($0.pages[0].file, PageFields.receipt(.init(merchant: "Corner Shop"))) })
        try batch.writePDFs(in: staged, fields: fields)
        let outputs = try batch.publish(in: staged)
        #expect(outputs.map(\.pdf.lastPathComponent) == ["Corner Shop_001.pdf", "Corner Shop_002 (2).pdf"])
        for output in outputs {
            #expect(output.sidecars.map(\.pathExtension) == (export ? ["csv", "json"] : []))
            #expect(output.sidecars.allSatisfy { $0.deletingPathExtension() == output.pdf.deletingPathExtension() })
            #expect(PDFDocument(url: output.pdf)?.pageCount == 1)
        }
        #expect(try Data(contentsOf: competing) == Data([42]))
    }

    @Test func learnedNameKeepsItsPageSuffixWhenItAlsoMatchesTheProvisionalStem() throws {
        defer { try? fm.removeItem(at: folder) }
        let profile = ScanProfile(name: "Bills", folderPath: folder.path, exportFields: true, pagesPerFile: 1,
                                  namePattern: .init(editorText: "Bill {number}"))
        let (batch, staged) = try OCRBatch.stage([DocumentFixture.order, DocumentFixture.order], profile: profile, date: .now)
        defer { try? fm.removeItem(at: staged) }
        let receipt = PageFields.receipt(.init(merchant: "Market"))
        let signature = try PageSignature(image: DocumentFixture.order.image, fields: receipt)
        let rule = UUID()
        let naming = PageNaming(signature: signature, matchedRule: rule, preferredStem: "Bill 001")
        let keys = batch.documents.map { $0.pages[0].file }
        try batch.writePDFs(in: staged, fields: Dictionary(uniqueKeysWithValues: keys.map { ($0, receipt) }))
        try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: keys.map { ($0, naming) })).write(to: staged.appendingPathComponent("naming.json"))
        let outputs = try batch.publish(in: staged)
        #expect(outputs.map(\.pdf.lastPathComponent) == ["Bill 001_001.pdf", "Bill 001_002.pdf"])
        #expect(outputs.allSatisfy { $0.usedRules == [rule] })
    }

    @Test func contentNameCannotFollowAReplacedSubfolder() throws {
        defer { try? fm.removeItem(at: folder) }
        let profile = ScanProfile(name: "Receipts", folderPath: folder.path, exportFields: true,
                                  namePattern: .init(editorText: "{merchant}"), subfolderPattern: [.profileName])
        let (batch, staged) = try OCRBatch.stage([DocumentFixture.order], profile: profile, date: .now)
        defer { try? fm.removeItem(at: staged) }
        try batch.writePDFs(in: staged, fields: ["page-1.png": .receipt(.init(merchant: "Market"))])
        let result = staged.appendingPathComponent("result-0.pdf")
        let prepared = try Data(contentsOf: result)
        let destination = DocumentWriter.saveFolder(for: profile)
        let moved = folder.appendingPathComponent("Moved")
        try fm.moveItem(at: destination, to: moved)
        try fm.createSymbolicLink(at: destination, withDestinationURL: moved)
        let error = try #require(throws: OCRRecoveryError.self) {
            try OCRJob(batch: batch, folder: staged, helper: URL(filePath: "/usr/bin/true")).wait()
        }
        #expect(error.folder == staged)
        #expect(try Data(contentsOf: result) == prepared)
        #expect(fm.fileExists(atPath: staged.appendingPathComponent("page-1.png").path))
        #expect(try filesAfterReleasingReservations(in: moved).isEmpty)
    }

    @Test func unavailableNamingManifestKeepsExtractedFields() async throws {
        defer { try? fm.removeItem(at: folder) }
        let receipt = PageFields.receipt(.init(merchant: "Market"))
        let signature = try PageSignature(image: DocumentFixture.order.image, fields: receipt)
        let rule = LearnedName(signature: signature, matchedText: "Market", replacement: "Market's", changesMerchant: true,
                               edited: .now, lastUsed: .distantPast)
        let profile = ScanProfile(name: "Receipts", folderPath: folder.path, exportFields: true, namePattern: .init(editorText: "{merchant}"))
        let (batch, staged) = try OCRBatch.stage([DocumentFixture.order], profile: profile, date: .now, learnedNames: [rule])
        defer { try? fm.removeItem(at: staged) }
        let manifest = staged.appendingPathComponent("naming.json")
        try fm.createDirectory(at: manifest, withIntermediateDirectories: false)
        try Data([1]).write(to: manifest.appendingPathComponent("existing"))
        let script = staged.appendingPathComponent("worker")
        try JSONEncoder().encode(receipt).write(to: staged.appendingPathComponent("proposal"))
        try """
        #!/bin/sh
        cp "$2" "${2%/*}/request"
        cp "${2%/*}/proposal" "$4"
        """.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let page = RecognizedPage(kind: .receipt, language: .english, documents: [], transcript: "Market", detectedData: [])
        let recognized = ["page-1.png": page]
        let fields = try await batch.readFields(in: staged, recognizedPages: recognized, worker: FieldWorker(executable: script))
        let request = try JSONDecoder().decode(FieldWorker.Request.self, from: Data(contentsOf: staged.appendingPathComponent("request")))
        #expect(request.examples == LearnedName.examples([rule]))
        try batch.writePDFs(in: staged, recognizedPages: recognized, fields: fields)
        let output = try #require(batch.publish(in: staged).first)
        #expect(output.pdf.lastPathComponent == "Market's.pdf")
        #expect(output.pages == [.receipt(.init(merchant: "Market's"))])
        #expect(output.naming == nil && output.usedRules.isEmpty)
        #expect(output.sidecars.count == 2)
    }

    @Test func unavailableFieldManifestKeepsTheFinishedPDF() throws {
        defer { try? fm.removeItem(at: folder) }
        let profile = ScanProfile(name: "Bills", folderPath: folder.path, exportFields: true,
                                  namePattern: .init(editorText: "{profile} - {title}"))
        let (batch, staged) = try OCRBatch.stage([DocumentFixture.order], profile: profile, date: .now)
        defer { try? fm.removeItem(at: staged) }
        let manifest = staged.appendingPathComponent("fields.json")
        try fm.createDirectory(at: manifest, withIntermediateDirectories: false)
        try Data([1]).write(to: manifest.appendingPathComponent("existing"))
        let key = batch.documents[0].pages[0].file
        try batch.writePDFs(in: staged, fields: [key: .document(.init(title: "Order"))])
        let completed = try Data(contentsOf: staged.appendingPathComponent("result-0.pdf"))
        let output = try #require(batch.publish(in: staged).first)
        #expect(output.pdf.lastPathComponent == "Bills.pdf")
        #expect(output.sidecars.isEmpty)
        #expect(try Data(contentsOf: output.pdf) == completed)
        #expect(PDFDocument(url: output.pdf)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Order")
    }
}
