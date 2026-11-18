import AppKit
import CoreText
import ImageIO
import PDFKit
import Testing
import Vision
@testable import YomiKit

@Suite(.serialized)
struct OCRBatchTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YomiOCRTests-\(UUID())")

    private func page(_ text: String, dpi: Int = 150) -> ProcessedPage {
        let context = CGContext(data: nil, width: 960, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 480))
        context.setFillColor(gray: 0, alpha: 1)
        context.textPosition = CGPoint(x: 60, y: 220)
        let font = CTFontCreateWithName("Helvetica" as CFString, 56, nil)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ])), context)
        return ProcessedPage(image: context.makeImage()!, resolution: dpi, isBlank: false, source: .front, isColor: true)
    }

    @Test func missingHelperSavesAnImageOnlyPDF() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = ScanProfile(name: "Receipts", folderPath: folder.path, namePattern: [.profileName])
        let (batch, pending) = try await offTheTaskPool {
            try BatchSaver.start([page("Invoice number twelve")], profile: profile, photoLibrary: nil,
                                 helper: folder.appendingPathComponent("missing"))
        }
        try pending?.wait()
        #expect(batch.files.map(\.lastPathComponent) == ["Receipts.pdf"])
        let document = try #require(PDFDocument(url: batch.files[0]))
        #expect(document.pageCount == 1)
        #expect(document.findString("Invoice", withOptions: []).isEmpty)
    }

    private var helper: URL {
        Bundle(for: TestBundle.self).bundleURL.deletingLastPathComponent().appendingPathComponent("yomi-ocr")
    }

    private final class TestBundle: NSObject {}

    private func helperRecordingErrors() throws -> URL {
        let fm = FileManager.default
        try fm.createSymbolicLink(at: folder.appendingPathComponent("yomi-ocr"), withDestinationURL: helper)
        let script = folder.appendingPathComponent("run-helper")
        try """
        #!/bin/zsh
        exec "${0:h}/yomi-ocr" "$@" 2> "${0:h}/helper-errors"
        """.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    private func helperReportedVisionFailure() throws -> Bool {
        let errors = try String(contentsOf: folder.appendingPathComponent("helper-errors"), encoding: .utf8)
        if !errors.isEmpty { print(errors) }
        return errors.contains("e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed")
            || errors.contains("Domain=TextRecognition.CRImageReaderError Code=9") || errors.contains("Domain=com.apple.Vision Code=9")
    }

    @Test func helperIsBesideTheRunningExecutable() throws {
        let executable = try #require(Bundle.main.executableURL)
        #expect(OCRBatch.helperURL == executable.deletingLastPathComponent().appendingPathComponent("yomi-ocr"))
    }

    @Test func recognitionErrorOnTheSecondPageFailsThePDF() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = ScanProfile(name: "Bills", folderPath: folder.path)
        let (batch, staged) = try OCRBatch.stage([page("First"), page("Second")], profile: profile, date: Date())
        defer { try? FileManager.default.removeItem(at: staged) }
        var recognized = 0
        #expect(throws: CocoaError(.featureUnsupported)) {
            try batch.writePDFs(in: staged) { _, _, _ in
                recognized += 1
                if recognized == 2 { throw CocoaError(.featureUnsupported) }
            }
        }
        #expect(recognized == 2)
    }

    private func pixels(_ image: CGImage) -> Data {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.height * context.bytesPerRow)
    }

    private func expectJPEGRaster(_ page: ProcessedPage, quality: Double, in pdf: URL) throws {
        let jpeg = try PDFWriter.jpegData(page.image, quality: quality)
        let startOfScan = try #require(jpeg.range(of: Data([0xff, 0xda])))
        let document = try Data(contentsOf: pdf)
        #expect(document.range(of: jpeg[startOfScan.lowerBound...]) != nil)
    }

    @Test(.enabled("Vision text recognition is unavailable") { await BackCaptionTests.textRecognition.value })
    func highCompressionRecognizesTheOriginalInvoice() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let context = try #require(CGContext(data: nil, width: 620, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 620, height: 120))
        let font = try #require(NSFont(name: "HelveticaNeue-Light", size: 12))
        for (gray, y) in [(0.15, 85), (0.55, 49), (0.76, 13)] {
            let text = NSAttributedString(string: "Invoice B762194  Total 18.95  Ref 8217", attributes: [
                .font: font, .foregroundColor: NSColor(deviceWhite: gray, alpha: 1),
            ])
            context.textPosition = CGPoint(x: 11, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        let page = ProcessedPage(image: try #require(context.makeImage()), resolution: 150, isBlank: false,
                                 source: .front, isColor: true)
        let profile = ScanProfile(name: "Invoice", folderPath: folder.path, compression: .high)
        let (original, output) = try await offTheTaskPool {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: page.image).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let (saved, pending) = try BatchSaver.start([page], profile: profile, photoLibrary: nil, helper: helperRecordingErrors())
            let recognition = try #require(pending)
            try recognition.wait()
            return (lines, saved.files[0])
        }
        #expect(original.count == 3)
        let text = try #require(PDFDocument(url: output)?.string)
        let expected = try helperReportedVisionFailure() ? [] : original
        #expect(text.split(whereSeparator: \.isNewline).map(String.init) == expected)
        try expectJPEGRaster(page, quality: profile.compression.jpegQuality, in: output)
    }

    @Test func manifestKeepsOriginalPixelsAndMixedResolutionsAtHighCompression() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let pages = [page("Invoice number twelve"), page("Delivery date", dpi: 300), page("Final balance", dpi: 600)]
        let profile = ScanProfile(name: "Invoices", folderPath: folder.path, saveTo: .photos, compression: .high,
                                  pagesPerFile: 2, namePattern: [.profileName])
        let (assigned, staged) = try OCRBatch.stage(pages, profile: profile, date: Date())
        let files = assigned.documents.map(\.outputURL)
        defer { try? FileManager.default.removeItem(at: staged) }
        let batch = try JSONDecoder().decode(OCRBatch.self, from: Data(contentsOf: staged.appendingPathComponent("manifest.json")))
        #expect(batch.documents.map(\.outputURL) == files)
        #expect(batch.documents.map { $0.pages.map(\.resolution) } == [[150, 300], [600]])
        #expect(batch.jpegQuality == 0.55)
        for (stagedPage, original) in zip(batch.documents.flatMap(\.pages), pages) {
            let source = try #require(CGImageSourceCreateWithURL(staged.appendingPathComponent(stagedPage.file) as CFURL, nil))
            let saved = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(pixels(saved) == pixels(original.image))
            let compressed = try PDFWriter.jpegBacked(original.image, quality: batch.jpegQuality)
            #expect(pixels(saved) != pixels(compressed))
        }
        #expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent("page-1.png").path))
        try await offTheTaskPool { try OCRJob(batch: assigned, folder: staged, helper: helperRecordingErrors()).wait() }
        #expect(files.map(\.lastPathComponent) == ["Invoices_001.pdf", "Invoices_003.pdf"])
        let pdfs = try files.map { try #require(PDFDocument(url: $0)) }
        #expect(pdfs.map(\.pageCount) == [2, 1])
        let pdfPages = try pdfs.flatMap { pdf in try (0..<pdf.pageCount).map { try #require(pdf.page(at: $0)) } }
        #expect(pdfPages.map { $0.bounds(for: .mediaBox).width } == [460.8, 230.4, 115.2])
        let expected = try helperReportedVisionFailure() ? ["", "", ""] : ["Invoice number twelve", "Delivery date", "Final balance"]
        #expect(pdfPages.map { ($0.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) } == expected)
        for (document, originals) in zip(files, [Array(pages.prefix(2)), Array(pages.suffix(1))]) {
            for original in originals {
                try expectJPEGRaster(original, quality: batch.jpegQuality, in: document)
            }
        }
    }

    @Test func scannerCanSaveAnotherBatchBeforeReportingTheSearchableFile() async throws {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: folder) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let gate = folder.appendingPathComponent("gate")
        let descriptor = open(gate.path, O_CREAT | O_RDWR | O_EXLOCK | O_CLOEXEC, 0o600)
        try #require(descriptor >= 0)
        let lock = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let prepared = folder.appendingPathComponent("prepared.pdf")
        let context = try #require(CGContext(prepared as CFURL, mediaBox: nil, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 72, y: 72)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "First invoice")), context)
        context.endPDFPage()
        context.closePDF()
        let preparedBytes = try Data(contentsOf: prepared)
        let script = folder.appendingPathComponent("gated-helper")
        try """
        #!/bin/zsh
        exec /usr/bin/lockf -k "${0:h}/gate" /bin/cp "${0:h}/prepared.pdf" "$1/result-0.pdf"
        """.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let profile = ScanProfile(name: "Bills", folderPath: folder.path, saveTo: .photos, namePattern: [.profileName])
        let queue = DispatchQueue(label: "test.scanner")
        let (batch, pending) = try queue.sync {
            try BatchSaver.start([page("First invoice")], profile: profile, photoLibrary: nil, helper: script)
        }
        let recognition = try #require(pending)
        defer {
            try? lock.close()
            try? recognition.wait()
        }
        let first = try #require(batch.files.first)
        let outcome = ScanOutcome(files: batch.files, sheets: 1, pages: 1, blankPagesSkipped: 0)
        let completed = DispatchSemaphore(value: 0)
        let scannerReady = DispatchSemaphore(value: 0)
        queue.async {
            outcome.report(after: recognition, on: queue, onPagesReady: { count, recognizing in
                #expect(count == 1 && recognizing)
            }) { result in
                #expect((try? result.get().files) == [first])
                #expect((try? Data(contentsOf: first)) == preparedBytes)
                completed.signal()
            }
            queue.async { scannerReady.signal() }
        }
        let ready = try await offTheTaskPool { scannerReady.wait(timeout: .now() + 180) }
        try #require(ready == .success)
        let secondPage = page("Second invoice", dpi: 300)
        let second = try queue.sync {
            let (batch, pending) = try BatchSaver.start([secondPage], profile: profile, photoLibrary: nil,
                                                       helper: folder.appendingPathComponent("missing"))
            try pending?.wait()
            return try #require(batch.files.first)
        }
        #expect(first.lastPathComponent == "Bills.pdf")
        #expect(second.lastPathComponent == "Bills (2).pdf")
        try expectJPEGRaster(secondPage, quality: profile.compression.jpegQuality, in: second)
        let before = try Data(contentsOf: second)
        let waiting = try await offTheTaskPool { completed.wait(timeout: .now()) }
        try #require(waiting == .timedOut)
        try lock.close()
        let finished = try await offTheTaskPool { completed.wait(timeout: .now() + 180) }
        try #require(finished == .success)
        let pdf = try #require(PDFDocument(url: first))
        #expect(pdf.pageCount == 1)
        #expect(pdf.findString("First invoice", withOptions: []).count == 1)
        #expect(try Data(contentsOf: second) == before)
    }

    @Test func unwritableDestinationFailsTheSave() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder)
        let profile = ScanProfile(name: "Bills", folderPath: folder.path)
        #expect(throws: (any Error).self) {
            try BatchSaver.start([page("First")], profile: profile, photoLibrary: nil, helper: helper)
        }
    }

    @Test func fallbackKeepsTheOriginalPagesIfAnotherFileTakesTheReservedName() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = ScanProfile(name: "Bills", folderPath: folder.path, namePattern: [.profileName])
        let (batch, staged) = try OCRBatch.stage([page("First")], profile: profile, date: Date())
        defer { try? FileManager.default.removeItem(at: staged) }
        let output = try #require(batch.documents.first?.outputURL)
        let replacement = Data("Already saved".utf8)
        try replacement.write(to: output, options: .atomic)
        let job = OCRJob(batch: batch, folder: staged, helper: URL(fileURLWithPath: "/usr/bin/false"))
        #expect(throws: (any Error).self) { try job.wait() }
        #expect(try Data(contentsOf: output) == replacement)
        let source = CGImageSourceCreateWithURL(staged.appendingPathComponent("page-1.png") as CFURL, nil)
        #expect(source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil)
    }

    @Test(arguments: ["exit 42", "kill -TERM $$", "exit 0"])
    func helperFailureKeepsTheSplitBatch(command: String) throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("yomi-ocr")
        try "#!/bin/sh\n\(command)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let profile = ScanProfile(name: "Bills", folderPath: folder.path, saveTo: .photos, pagesPerFile: 1,
                                  namePattern: [.profileName])
        let pages = [page("First"), page("Second", dpi: 300)]
        let (saved, pending) = try BatchSaver.start(pages, profile: profile, photoLibrary: nil, helper: script)
        let done = try #require(pending)
        try done.wait()
        #expect(saved.files.map(\.lastPathComponent) == ["Bills_001.pdf", "Bills_002.pdf"])
        for (file, page) in zip(saved.files, pages) {
            let pdf = try #require(PDFDocument(url: file))
            #expect(pdf.pageCount == 1)
            #expect((pdf.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            try expectJPEGRaster(page, quality: profile.compression.jpegQuality, in: file)
        }
    }
}
