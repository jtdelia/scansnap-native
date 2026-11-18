import AppKit
import CoreText
import PDFKit
import Testing
import Vision
@testable import YomiKit

enum DocumentFixture {
    static let recognitionAvailable = Task<Bool, Never> {
        do {
            _ = try await RecognizeDocumentsRequest().perform(on: order.image)
            return true
        } catch {
            print("Vision document recognition probe failed: \(error)")
            return false
        }
    }

    static var order: ProcessedPage {
        render(font: "Helvetica", size: 36) { context, draw in
            draw("Order confirmation", 110, 580)
            let rows = [["Item", "Quantity", "Price"], ["Pencils", "12", "$6.50"], ["Notebooks", "5", "$10.00"]]
            for (row, cells) in rows.enumerated() {
                for (column, text) in cells.enumerated() {
                    let x = 100 + column * 260
                    let y = 400 - row * 90
                    context.stroke(CGRect(x: x, y: y, width: 260, height: 90))
                    draw(text, x + 12, y + 23)
                }
            }
        }
    }

    static var japanese: ProcessedPage {
        render(font: "HiraginoSans-W5", size: 46) { _, draw in
            draw("請求書", 100, 550)
            draw("Delivery receipt", 100, 450)
            draw("2026年11月18日", 100, 350)
            for (index, character) in "東京支店".enumerated() {
                draw(String(character), 820, 555 - index * 53)
            }
        }
    }

    static var blank: ProcessedPage {
        render(font: "Helvetica", size: 36) { _, _ in }
    }

    private static func render(font: String, size: CGFloat, content: (CGContext, (String, Int, Int) -> Void) -> Void) -> ProcessedPage {
        let context = CGContext(data: nil, width: 1000, height: 700, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1000, height: 700))
        context.setFillColor(gray: 0, alpha: 1)
        let font = CTFontCreateWithName(font as CFString, size, nil)
        content(context) { text, x, y in
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ])), context)
        }
        return ProcessedPage(image: context.makeImage()!, resolution: 144, isBlank: false, source: .front, isColor: true)
    }
}

struct DocumentRecognitionTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YomiDocumentTests-\(UUID())")

    private var helper: URL {
        Bundle(for: TestBundle.self).bundleURL.deletingLastPathComponent().appendingPathComponent("yomi-ocr")
    }

    private final class TestBundle: NSObject {}

    @Test(.enabled("Vision document recognition is unavailable") { await DocumentFixture.recognitionAvailable.value })
    func splitPDFsFindTextAtItsPrintedPosition() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = ScanProfile(name: "Invoices", folderPath: folder.path, textRecognitionLanguage: .japaneseAndEnglish,
                                  pagesPerFile: 1, namePattern: [.profileName])
        let files = try await offTheTaskPool {
            let (saved, pending) = try BatchSaver.start([DocumentFixture.order, DocumentFixture.japanese, DocumentFixture.blank], profile: profile,
                                                       photoLibrary: nil, helper: helper)
            try #require(pending).wait()
            return saved.files
        }
        #expect(files.map(\.lastPathComponent) == ["Invoices_001.pdf", "Invoices_002.pdf", "Invoices_003.pdf"])
        let english = try #require(PDFDocument(url: files[0]))
        let japanese = try #require(PDFDocument(url: files[1]))
        let blank = try #require(PDFDocument(url: files[2]))
        #expect(blank.pageCount == 1)
        #expect((blank.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        try expectSelection("Order confirmation", in: english, within: CGRect(x: 48, y: 280, width: 200, height: 40))
        try expectJapaneseSelections(in: japanese)
    }

    @Test(.enabled("Vision document recognition is unavailable") { await DocumentFixture.recognitionAvailable.value })
    func pageResultsKeepParagraphsTablesAndDetectedDatesWithTheirPage() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = ScanProfile(name: "Invoices", folderPath: folder.path, textRecognitionLanguage: .japaneseAndEnglish,
                                  pagesPerFile: 1)
        let (batch, staged) = try OCRBatch.stage([DocumentFixture.order, DocumentFixture.japanese], profile: profile, date: Date())
        defer { try? FileManager.default.removeItem(at: staged) }
        let results = try await batch.recognizePages(in: staged)
        let order = try #require(results[batch.documents[0].pages[0].file])
        let table = try #require(order.documents.flatMap(\.tables).first)
        #expect(table.cell(row: 1, col: 0)?.content.text.transcript == "Pencils")
        let japanese = try #require(results[batch.documents[1].pages[0].file])
        #expect(japanese.documents.flatMap(\.paragraphs).contains { $0.transcript == "請求書" })
        let dates = japanese.detectedData.compactMap { match -> String? in
            guard case .calendarEvent = match.details, let range = match.range else { return nil }
            return String(japanese.transcript[range])
        }
        #expect(dates.contains("2026年11月18日"))
    }

    @Test func unreadablePageFailsRecognitionAndTheHelper() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = ScanProfile(name: "Invoices", folderPath: folder.path, pagesPerFile: 1)
        let (batch, staged) = try OCRBatch.stage([DocumentFixture.blank, DocumentFixture.order], profile: profile, date: Date())
        defer { try? FileManager.default.removeItem(at: staged) }
        try Data().write(to: staged.appendingPathComponent(batch.documents[1].pages[0].file))
        await #expect(throws: (any Error).self) { try await batch.recognizePages(in: staged) }
        let status = try await offTheTaskPool {
            let child = Process()
            child.executableURL = helper
            child.arguments = [staged.path]
            try child.run()
            child.waitUntilExit()
            return child.terminationStatus
        }
        #expect(status != 0)
    }

    private func expectSelection(_ text: String, in document: PDFDocument, within area: CGRect) throws {
        let page = try #require(document.page(at: 0))
        let selection = try #require(document.findString(text, withOptions: []).first, "\(text)")
        let bounds = selection.bounds(for: page)
        #expect(area.contains(CGPoint(x: bounds.midX, y: bounds.midY)))
        #expect(page.selection(for: area)?.string?.contains(text) == true)
    }

    private func expectJapaneseSelections(in document: PDFDocument) throws {
        try expectSelection("請求書", in: document, within: CGRect(x: 45, y: 266, width: 85, height: 37))
        try expectSelection("Delivery receipt", in: document, within: CGRect(x: 45, y: 210, width: 212, height: 43))
        let page = try #require(document.page(at: 0))
        let selection = try #require(document.findString("東京支店", withOptions: []).first)
        let column = selection.bounds(for: page)
        #expect(column.height > 3 * column.width)
        #expect(column.contains(CGPoint(x: 422, y: 286)))
        #expect(column.contains(CGPoint(x: 422, y: 209)))
        for (y, character) in [(286, "東"), (209, "店")] {
            let area = CGRect(x: 417, y: y - 5, width: 10, height: 10)
            #expect(page.selection(for: area)?.string == character)
        }
    }

    @Test func pdfSelectionFollowsHorizontalLinesAndVerticalGlyphs() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Invoice.pdf")
        let fixture = DocumentFixture.japanese
        let lines = [
            PDFTextLayer.RecognizedLine(text: "請求書", box: CGRect(x: 0.10, y: 0.78, width: 0.14, height: 0.065)),
            PDFTextLayer.RecognizedLine(text: "Delivery receipt", box: CGRect(x: 0.10, y: 0.62, width: 0.39, height: 0.082)),
            PDFTextLayer.RecognizedLine(text: "東京支店", box: CGRect(x: 0.82, y: 0.557, width: 0.046, height: 0.291)),
        ]
        let context = try #require(CGContext(file as CFURL, mediaBox: nil, nil))
        try PDFWriter.write(pages: 1, in: context, jpegQuality: 0.75, textLayer: { _, box, context in
            PDFTextLayer.drawInvisibleText(lines, in: box, context: context)
        }) { _ in (fixture.image, fixture.resolution) }
        let document = try #require(PDFDocument(url: file))
        try expectJapaneseSelections(in: document)
    }

    @Test func languageChoicesConfigureVisionAndDataDetection() {
        let automatic = ScanProfile.TextRecognitionLanguage.automatic
        #expect(automatic.documentRequest.textRecognitionOptions.automaticallyDetectLanguage)
        #expect(automatic.dataDetectionOptions.documentLanguageCode == nil)
        #expect(automatic.dataDetectionOptions.documentRegion == nil)
        let english = ScanProfile.TextRecognitionLanguage.english
        let englishOptions = english.documentRequest.textRecognitionOptions
        #expect(!englishOptions.automaticallyDetectLanguage)
        #expect(englishOptions.recognitionLanguages == [.init(identifier: "en-US")])
        #expect(english.dataDetectionOptions.documentLanguageCode == .english)
        #expect(english.dataDetectionOptions.documentRegion == nil)
        let japanese = ScanProfile.TextRecognitionLanguage.japaneseAndEnglish
        let bilingual = japanese.documentRequest.textRecognitionOptions
        #expect(!bilingual.automaticallyDetectLanguage)
        #expect(bilingual.recognitionLanguages == [.init(identifier: "ja-JP"), .init(identifier: "en-US")])
        #expect(japanese.dataDetectionOptions.documentLanguageCode == .japanese)
        #expect(japanese.dataDetectionOptions.documentRegion == .japan)
    }
}
