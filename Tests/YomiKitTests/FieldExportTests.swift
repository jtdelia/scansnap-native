import Contacts
import Foundation
import PDFKit
import Testing
@testable import YomiKit

struct FieldExportTests {
    let folder = (ProcessInfo.processInfo.environment["YOMI_TEST_VOLUME"].map { URL(filePath: $0) } ?? FileManager.default.temporaryDirectory)
        .appendingPathComponent("YomiExports-\(UUID())")

    @Test(arguments: ["=Market", "+Market", "-Market", "@Market", " \t@Market", "\u{0001}=Market"])
    func exportsFormulaLikeMerchantNamesAsText(_ merchant: String) throws {
        let receipt = ReceiptFields(merchant: merchant, total: "-12", currency: "USD")
        let pages = [PageFields.receipt(receipt)]
        let sidecars = try PageFields.sidecars(pages)
        let csv = try #require(sidecars.first { $0.ext == "csv" })
        #expect(String(decoding: csv.data, as: UTF8.self).contains("\"'\(merchant)\",\"\",\"-12\""))
        let json = try #require(sidecars.first { $0.ext == "json" })
        #expect(try JSONDecoder().decode([ReceiptFields].self, from: json.data) == [receipt])
        #expect(PageFields.pdfInfo(pages)[kCGPDFContextTitle] as? String == merchant)
    }

    @Test(arguments: [false, true])
    func publishesMetadataAndOnlyEnabledSidecars(export: Bool) throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = ScanProfile(name: "Receipt", folderPath: folder.path, exportFields: export, namePattern: [.profileName])
        let (batch, staged) = try OCRBatch.stage([DocumentFixture.blank, DocumentFixture.blank], profile: profile, date: Date())
        defer { try? FileManager.default.removeItem(at: staged) }
        let existing = folder.appendingPathComponent("Receipt.json")
        let original = Data("Previously saved".utf8)
        try original.write(to: existing)
        let pages = batch.documents[0].pages
        let receipt = ReceiptFields(merchant: "Green, \"West\"", date: "2026-03-16", total: "1280", currency: "JPY")
        let second = ReceiptFields(merchant: "青葉書店", total: "500", currency: "JPY")
        let fields: [String: PageFields] = [pages[0].file: .receipt(receipt), pages[1].file: .receipt(second)]
        try batch.writePDFs(in: staged, fields: fields)
        let output = try #require(batch.publish(in: staged).first)
        #expect(output.pdf.lastPathComponent == (export ? "Receipt (2).pdf" : "Receipt.pdf"))
        #expect(output.pages == [.receipt(receipt), .receipt(second)])
        #expect(try Data(contentsOf: existing) == original)
        let pdf = try #require(PDFDocument(url: output.pdf))
        #expect(pdf.pageCount == 2)
        #expect(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == receipt.merchant)
        #expect(pdf.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String == "2026-03-16 1280 JPY")
        let keywords = try #require(pdf.documentAttributes?[PDFDocumentAttribute.keywordsAttribute] as? [String])
        #expect(keywords.contains("Receipt"))
        #expect(keywords.contains("青葉書店"))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Receipt.csv").path))
        if export {
            #expect(output.sidecars.map(\.lastPathComponent) == ["Receipt (2).csv", "Receipt (2).json"])
            let csv = try String(contentsOf: output.sidecars[0], encoding: .utf8)
            #expect(csv.contains("\"Green, \"\"West\"\"\",\"2026-03-16\",\"1280\",\"JPY\""))
            #expect(try JSONDecoder().decode([ReceiptFields].self, from: Data(contentsOf: output.sidecars[1])) == [receipt, second])
        } else {
            #expect(output.sidecars.isEmpty)
        }
        #expect(try JSONDecoder().decode(ScanProfile.self, from: JSONEncoder().encode(profile)).exportFields == export)
    }

    @Test func laterBatchKeepsItsReservationWhenAnEarlierGroupChangesStem() throws {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: folder) }
        let profile = ScanProfile(name: "Receipt", folderPath: folder.path, exportFields: true, namePattern: [.profileName])
        let (first, firstFolder) = try OCRBatch.stage([DocumentFixture.blank], profile: profile, date: Date())
        defer { try? fm.removeItem(at: firstFolder) }
        let (second, secondFolder) = try OCRBatch.stage([DocumentFixture.blank], profile: profile, date: Date())
        defer { try? fm.removeItem(at: secondFolder) }
        let prior = folder.appendingPathComponent("Receipt.json")
        try Data([42]).write(to: prior)
        try first.writePDFs(in: firstFolder, fields: ["page-1.png": .receipt(.init(merchant: "A Market"))])
        try second.writePDFs(in: secondFolder)
        #expect(try first.publish(in: firstFolder).first?.pdf.lastPathComponent == "Receipt (3).pdf")
        #expect(try second.publish(in: secondFolder).first?.pdf.lastPathComponent == "Receipt (2).pdf")
        #expect(try Data(contentsOf: prior) == Data([42]))
    }

    @Test func exportsImportableJapaneseContactAndOmitsEmptyRecords() throws {
        let card = BusinessCardFields(name: "山田 太郎", nameReading: "ヤマダ タロウ", company: "株式会社青葉堂", companyReading: "アオバドウ",
                                      department: "営業部", title: "部長", postalCode: "100-0005", address: "東京都千代田区丸の内1-2-3",
                                      phone: "03-1234-5678", mobile: "090-1234-5678", fax: "03-9876-5432", email: "taro@example.jp",
                                      website: "https://example.jp", memo: "Notes, line one\nline two", region: "日本", date: "2026-03-16")
        let sidecars = try PageFields.sidecars([.businessCard(card), .businessCard(.init())])
        #expect(sidecars.map(\.ext) == ["vcf"])
        let contacts = try CNContactVCardSerialization.contacts(with: sidecars[0].data)
        let contact = try #require(contacts.first)
        #expect(contacts.count == 1)
        #expect(contact.organizationName == "株式会社青葉堂")
        #expect(contact.emailAddresses.first?.value as String? == "taro@example.jp")
        #expect(contact.postalAddresses.first?.value.postalCode == "100-0005")
        #expect(contact.phoneNumbers.count == 3)
        let text = try #require(String(data: sidecars[0].data, encoding: .utf8))
        #expect(text.contains("X-BUSINESS-CARD-DATE:2026-03-16\r\n"))
        #expect(text.contains("NOTE:Notes\\, line one\\nline two\r\n"))
        #expect(try PageFields.sidecars([.receipt(.init()), .document(.init()), .print]).isEmpty)
    }

    @Test func concurrentSavesKeepLongStemsAndClashNumbersTogether() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pdf = folder.appendingPathComponent("source.pdf")
        try Data("pdf".utf8).write(to: pdf)
        let outputs = try await withThrowingTaskGroup(of: [URL].self) { group in
            for index in 0..<4 {
                group.addTask {
                    try DocumentWriter.publishPDF(pdf, sidecars: [("json", Data("\(index)".utf8))], in: folder,
                                                  name: .init(stem: String(repeating: "領", count: 100), suffix: "_001"))
                }
            }
            var outputs: [[URL]] = []
            for try await result in group { outputs.append(result) }
            return outputs
        }
        #expect(Set(outputs.map { $0[0] }).count == 4)
        for pair in outputs {
            #expect(pair[0].deletingPathExtension() == pair[1].deletingPathExtension())
            #expect(try Data(contentsOf: pair[0]) == Data("pdf".utf8))
        }
        #expect(try Set(outputs.map { try String(contentsOf: $0[1], encoding: .utf8) }) == ["0", "1", "2", "3"])
    }
}
