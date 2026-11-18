import AppKit
import CoreText
import PDFKit
import Testing
import Vision
@testable import YomiKit

enum DocumentFixture {
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
            draw("大", 700, 590)
            draw("阪", 700, 547)
            for (index, character) in "東京支店".enumerated() {
                draw(String(character), 820, 555 - index * 53)
            }
        }
    }

    static var blank: ProcessedPage {
        render(font: "Helvetica", size: 36) { _, _ in }
    }

    static func render(font: String, size: CGFloat, content: (CGContext, (String, Int, Int) -> Void) -> Void) -> ProcessedPage {
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

    @Test func splitPDFsFindTextAtItsPrintedPosition() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = ScanProfile(name: "Invoices", folderPath: folder.path, textRecognitionLanguage: .japaneseAndEnglish,
                                  pagesPerFile: 1, namePattern: [.profileName])
        let pages = [DocumentFixture.order, DocumentFixture.japanese, DocumentFixture.blank]
        let helper = try OCRTestHelper(in: folder)
        let files = try await offTheTaskPool {
            let (saved, pending) = try BatchSaver.start(pages, profile: profile, photoLibrary: nil, helper: helper.script)
            try #require(pending).wait()
            return saved.files
        }
        try #require(files.map(\.lastPathComponent) == ["Invoices_001.pdf", "Invoices_002.pdf", "Invoices_003.pdf"])
        let recognized = try await helper.output().recognized()
        let documents = try files.map { try #require(PDFDocument(url: $0)) }
        for (index, document) in documents.enumerated() {
            try #require(document.pageCount == 1)
            try expectJPEGRaster(pages[index], quality: profile.compression.jpegQuality, in: files[index])
            if !recognized || index == 2 {
                #expect((document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        if recognized {
            try expectSelection("Order confirmation", in: documents[0], within: CGRect(x: 48, y: 280, width: 200, height: 40))
            try expectJapaneseSelections(in: documents[1])
        }
    }

    @Test func pageResultsKeepParagraphsTablesAndDetectedDatesWithTheirPage() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = ScanProfile(name: "Invoices", folderPath: folder.path, textRecognitionLanguage: .japaneseAndEnglish,
                                  pagesPerFile: 1)
        let (batch, staged) = try OCRBatch.stage([DocumentFixture.order, DocumentFixture.japanese], profile: profile, date: Date())
        defer { try? FileManager.default.removeItem(at: staged) }
        let results: [String: RecognizedPage]
        do {
            results = try await batch.recognizePages(in: staged)
        } catch {
            try await reportVisionFailure(error)
        }
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

    @Test(arguments: [false, true])
    func validBlankPageSucceedsWithEmptyText(inHelper: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = ScanProfile(name: "Invoices", folderPath: folder.path)
        let page = DocumentFixture.blank
        let (batch, staged) = try OCRBatch.stage([page], profile: profile, date: Date())
        defer { try? FileManager.default.removeItem(at: staged) }
        if inHelper {
            let output = try await offTheTaskPool { try OCRTestHelper(in: folder).run(on: staged) }
            if let reason = await output.unavailableReason() { try reportVisionUnavailable(reason) }
            try #require(output.status == 0 && output.stderr.isEmpty, "\(output)")
            let file = staged.appendingPathComponent("result-0.pdf")
            let pdf = try #require(PDFDocument(url: file))
            try #require(pdf.pageCount == 1)
            #expect((pdf.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            try expectJPEGRaster(page, quality: batch.jpegQuality, in: file)
        } else {
            do {
                let recognized = try await batch.recognizePages(in: staged)
                let blank = try #require(recognized[batch.documents[0].pages[0].file])
                #expect(blank.transcript.isEmpty)
            } catch {
                try await reportVisionFailure(error)
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func unreadablePageFailsRecognitionAndTheHelper(afterBlank: Bool, inHelper: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = ScanProfile(name: "Invoices", folderPath: folder.path, pagesPerFile: 1)
        let pages = afterBlank ? [DocumentFixture.blank, DocumentFixture.order] : [DocumentFixture.order]
        let (batch, staged) = try OCRBatch.stage(pages, profile: profile, date: Date())
        defer { try? FileManager.default.removeItem(at: staged) }
        let damaged = try #require(batch.documents.last?.pages.first)
        try Data().write(to: staged.appendingPathComponent(damaged.file))
        if inHelper {
            let output = try await offTheTaskPool { try OCRTestHelper(in: folder).run(on: staged) }
            #expect(output.status == 1)
            for index in batch.documents.indices {
                #expect(!FileManager.default.fileExists(atPath: staged.appendingPathComponent("result-\(index).pdf").path))
            }
            if afterBlank, let reason = await output.unavailableReason(on: batch.documents[0].pages[0].file) {
                try reportVisionUnavailable(reason)
            }
            let diagnostic = try #require(output.stderr.wholeMatch(of: #/yomi-ocr: invalidImage\("([^":\n]+): [^"\n]+"\)\n/#), "\(output.stderr)")
            #expect(diagnostic.1 == damaged.file)
        } else {
            do {
                _ = try await batch.recognizePages(in: staged)
                Issue.record("Recognition accepted the damaged page")
            } catch VisionError.invalidImage(let reason) {
                #expect(reason.hasPrefix("\(damaged.file): "))
            } catch where afterBlank {
                try await reportVisionFailure(error, on: batch.documents[0].pages[0].file)
            }
        }
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
        #expect(!document.findString("大阪", withOptions: []).isEmpty)
        for (x, y, character) in [(422, 286, "東"), (422, 209, "店"), (361, 302, "大"), (361, 281, "阪")] {
            let area = CGRect(x: x - 5, y: y - 5, width: 10, height: 10)
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
            PDFTextLayer.RecognizedLine(text: "東京支店", box: CGRect(x: 0.82, y: 0.557, width: 0.046, height: 0.291),
                                        direction: nil),
            PDFTextLayer.RecognizedLine(text: "大阪", box: CGRect(x: 0.70, y: 542.0 / 700, width: 0.046, height: 86.0 / 700),
                                        direction: .topToBottom),
            PDFTextLayer.RecognizedLine(text: "Ij", box: CGRect(x: 0.45, y: 0.10, width: 0.035, height: 0.16)),
        ]
        let context = try #require(CGContext(file as CFURL, mediaBox: nil, nil))
        try PDFWriter.write(pages: 1, in: context, jpegQuality: 0.75, textLayer: { _, box, context in
            PDFTextLayer.drawInvisibleText(lines, in: box, context: context)
        }) { _ in (fixture.image, fixture.resolution) }
        let document = try #require(PDFDocument(url: file))
        try expectJapaneseSelections(in: document)
        let page = try #require(document.page(at: 0))
        let text = try #require(page.string as NSString?)
        let narrow = text.range(of: "Ij")
        try #require(narrow.location != NSNotFound)
        let first = page.characterBounds(at: narrow.location), last = page.characterBounds(at: narrow.location + 1)
        #expect(last.midX > first.midX)
        #expect(abs(last.midY - first.midY) < 1)
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
