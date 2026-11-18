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
