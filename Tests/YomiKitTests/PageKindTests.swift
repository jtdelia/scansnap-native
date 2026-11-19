import CoreGraphics
import CoreText
import Foundation
import FoundationModels
import ImageIO
import PDFKit
import Testing
@testable import YomiKit

@Suite(.serialized)
struct PageKindTests {
    private static let modelAvailable = Task {
        let model = SystemLanguageModel.default
        guard model.isAvailable, model.capabilities.contains(.vision) else { return false }
        do {
            _ = try await LanguageModelSession(model: model).respond {
                Attachment(DocumentFixture.blank.image)
                "What color is this page?"
            }
            return true
        } catch {
            print("On-device image model probe failed: \(error)")
            return false
        }
    }

    private func page(_ kind: PageKind) throws -> ProcessedPage {
        let size: CGSize
        let lines: [String]
        switch kind {
        case .receipt:
            size = CGSize(width: 480, height: 960)
            lines = ["Green Street Market", "Nov 12, 2026   10:24 AM", "Coffee       $3.50", "Bread        $4.00",
                     "Subtotal     $7.50", "Tax          $0.60", "TOTAL        $8.10", "Paid by Visa", "Thank you!"]
        case .businessCard:
            size = CGSize(width: 546, height: 330)
            lines = ["Northline Studio", "Alex Rivera", "Design Director", "alex@example.com", "(415) 555-0107"]
        case .document:
            size = CGSize(width: 1295, height: 1676)
            lines = ["November 12, 2026", "Dear Alex,", "Thank you for visiting the studio last week.",
                     "We look forward to working with you in December.", "Sincerely,", "Morgan Lee"]
        case .print:
            let url = try #require(Bundle.module.url(forResource: "family-print", withExtension: "jpg", subdirectory: "Fixtures"))
            let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            return ProcessedPage(image: try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)),
                                 resolution: 120, isBlank: false, source: .front, isColor: true)
        }
        let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        for (index, line) in lines.enumerated() {
            context.textPosition = CGPoint(x: 32, y: size.height - CGFloat(55 + index * 42))
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
            ])), context)
        }
        return ProcessedPage(image: try #require(context.makeImage()), resolution: 152, isBlank: false, source: .front, isColor: false)
    }

    @Test(arguments: [PageKind.receipt, .businessCard, .document, .print])
    func unavailableOrThrowingModelUsesOnlySheetSize(_ kind: PageKind) async throws {
        let page = try page(kind)
        let expected: PageKind = kind == .businessCard ? .businessCard : .document
        let unavailable = await PageKind.classify(page.image, resolution: page.resolution, foundPrint: true) { _, _, _ in nil }
        let failed = await PageKind.classify(page.image, resolution: page.resolution, foundPrint: true) { _, _, _ in
            throw SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "Missing test model"))
        }
        #expect(unavailable == expected)
        #expect(failed == expected)
    }

    @Test(arguments: [false, true])
    func forwardsPrintEvidenceToPredictor(_ foundPrint: Bool) async throws {
        let page = try page(.document)
        let kind = await PageKind.classify(page.image, resolution: page.resolution, foundPrint: foundPrint) { _, _, received in
            #expect(received == foundPrint)
            return .receipt
        }
        #expect(kind == .receipt)
    }

    @Test func portraitCardUsesTheStagedResolution() async throws {
        let image = try #require(CGContext(data: nil, width: 600, height: 1050, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage())
        let card = await PageKind.classify(image, resolution: 300, foundPrint: false) { _, _, _ in nil }
        let largerSheet = await PageKind.classify(image, resolution: 150, foundPrint: false) { _, _, _ in nil }
        #expect(card == .businessCard)
        #expect(largerSheet == .document)
    }

    @Test(.enabled("On-device image model unavailable") { await Self.modelAvailable.value },
          arguments: [PageKind.receipt, .businessCard, .document, .print])
    func onDeviceModelReadsPageImage(_ kind: PageKind) async throws {
        let page = try page(kind)
        var prediction: PageKind?
        let result = await PageKind.classify(page.image, resolution: page.resolution, foundPrint: false) { image, size, foundPrint in
            prediction = try await PageKind.predict(image, size: size, foundPrint: foundPrint)
            return prediction
        }
        #expect(prediction != nil)
        #expect(result == kind)
    }

    @Test(arguments: [nil, 2] as [Int?])
    func pageResultsFollowTheFirstPageOfEachPDF(pagesPerFile: Int?) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YomiPageKinds-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = ScanProfile(name: "Mail", folderPath: folder.path, textRecognitionLanguage: .english,
                                  pagesPerFile: pagesPerFile, namePattern: [.profileName])
        let (batch, staged) = try OCRBatch.stage([page(.businessCard), page(.document), page(.document)], profile: profile, date: Date())
        defer { try? FileManager.default.removeItem(at: staged) }
        let recognized: [String: RecognizedPage]
        do {
            recognized = try await batch.recognizePages(in: staged)
        } catch where isVisionComputeFailure(String(describing: error)) {
            try reportVisionUnavailable("Vision could not recognize the staged pages: \(error)")
        }
        let kinds = try batch.documents.map { document in
            try document.pages.map { page in try #require(recognized[page.file]).kind }
        }
        let expected: [[PageKind]] = pagesPerFile == nil ? [[.businessCard, .businessCard, .businessCard]] : [[.businessCard, .businessCard], [.document]]
        #expect(kinds == expected)
        try batch.writePDFs(in: staged, recognizedPages: recognized)
        try batch.publish(in: staged)
        let files = batch.documents.map(\.outputURL)
        #expect(files.map(\.lastPathComponent) == (pagesPerFile == nil ? ["Mail.pdf"] : ["Mail_001.pdf", "Mail_003.pdf"]))
        #expect(files.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL.path == folder.standardizedFileURL.path })
        #expect(try files.map { try #require(PDFDocument(url: $0)).pageCount } == kinds.map(\.count))
    }

    @Test func stagedPagesCarryPrintEvidenceAndOlderPagesDecodeWithoutIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YomiPrintEvidence-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = try PhotoCropTests.scan(width: 4, height: 6, tone: .dark)
        let print = try PageProcessor.process(image, resolution: 150, side: .front, options: PhotoCropTests.photoOptions())
        let profile = ScanProfile(name: "Mail", folderPath: folder.path)
        let (_, staged) = try OCRBatch.stage([print, page(.document)], profile: profile, date: Date())
        defer { try? FileManager.default.removeItem(at: staged) }
        let data = try Data(contentsOf: staged.appendingPathComponent("manifest.json"))
        let batch = try JSONDecoder().decode(OCRBatch.self, from: data)
        #expect(batch.documents.flatMap(\.pages).map(\.foundPrint) == [true, false])
        let old = try JSONDecoder().decode(OCRBatch.Page.self, from: Data(#"{"file":"page-1.png","resolution":300}"#.utf8))
        #expect(old.foundPrint == nil)
    }
}
