import Foundation
import ImageIO
import Vision

package struct OCRBatch: Codable {
    package struct Page: Codable {
        package let file: String
        package let resolution: Int
        let foundPrint: Bool?

        fileprivate func url(in folder: URL) throws -> URL {
            guard file == URL(fileURLWithPath: file).lastPathComponent, resolution > 0 else {
                throw ImageWriterError.cannotCreateImage
            }
            return folder.appendingPathComponent(file)
        }

        fileprivate func image(in folder: URL) throws -> CGImage? {
            guard let source = CGImageSourceCreateWithURL(try url(in: folder) as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
    }

    package struct Document: Codable {
        package let outputURL: URL
        let exportName: DocumentWriter.FileName?
        package let pages: [Page]
        fileprivate var reservation: PDFReservation?

        private enum CodingKeys: CodingKey { case outputURL, exportName, pages }
    }

    package let jpegQuality: Double
    let textRecognitionLanguage: ScanProfile.TextRecognitionLanguage?
    package let documents: [Document]

    static var helperURL: URL {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable.deletingLastPathComponent().appendingPathComponent("yomi-ocr")
    }

    static func stage(_ pages: [ProcessedPage], profile: ScanProfile, date: Date) throws -> (Self, URL) {
        let folder = try temporaryFolder()
        let staged = try stageOriginals(pages, in: folder)
        var directory: PDFDirectory?
        do {
            let destination = try PDFDirectory(DocumentWriter.openFolder(for: profile, date: date))
            directory = destination
            let documents = try DocumentWriter.fileGroups(pages: pages.count, profile: profile, date: date).map { group in
                let reservation = try DocumentWriter.reservePDF(in: destination, group.name)
                return Document(outputURL: reservation.output, exportName: profile.exportFields ? group.name : nil,
                                pages: Array(staged[group.range]), reservation: reservation)
            }
            let batch = OCRBatch(jpegQuality: profile.compression.jpegQuality, textRecognitionLanguage: profile.textRecognitionLanguage,
                                 documents: documents)
            try JSONEncoder().encode(batch).write(to: folder.appendingPathComponent("manifest.json"))
            return (batch, folder)
        } catch {
            throw OCRRecoveryError(folder: folder, saved: pages.count, total: pages.count, cause: error, directory: directory)
        }
    }

    static func temporaryFolder() throws -> URL {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("Yomi-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }

    static func stageOriginals(_ pages: [ProcessedPage], in folder: URL, alreadySaved: Int = 0) throws -> [Page] {
        var staged: [Page] = []
        do {
            for (index, page) in pages.enumerated() {
                let file = "page-\(index + 1).png"
                if index >= alreadySaved {
                    try autoreleasepool {
                        try ImageWriter.write(page.image, to: folder.appendingPathComponent(file), resolution: page.resolution)
                    }
                }
                staged.append(Page(file: file, resolution: page.resolution, foundPrint: page.foundPrint))
            }
            return staged
        } catch {
            throw OCRRecoveryError(folder: folder, saved: staged.count, total: pages.count, cause: error)
        }
    }

    private func resultURL(in folder: URL, index: Int) -> URL { folder.appendingPathComponent("result-\(index).pdf") }

    package func recognizePages(in folder: URL) async throws -> [String: RecognizedPage] {
        var recognized: [String: RecognizedPage] = [:]
        for document in documents {
            guard let first = document.pages.first else { continue }
            guard let image = try first.image(in: folder) else {
                throw VisionError.invalidImage("\(first.file): Could not decode the staged page")
            }
            let kind = await PageKind.classify(image, resolution: first.resolution, foundPrint: first.foundPrint == true)
            for page in document.pages {
                let url = try page.url(in: folder)
                recognized[page.file] = try await RecognizedPage.read(url, language: textRecognitionLanguage ?? .automatic, kind: kind)
            }
        }
        return recognized
    }

    package func readFields(in folder: URL, recognizedPages: [String: RecognizedPage]) async throws -> [String: PageFields] {
        try await readFields(in: folder, recognizedPages: recognizedPages, worker: FieldWorker(executable: Self.helperURL))
    }

    func readFields(in folder: URL, recognizedPages: [String: RecognizedPage], worker: FieldWorker,
                    examples: String = "") async throws -> [String: PageFields] {
        var fields: [String: PageFields] = [:]
        var available = true
        for page in documents.flatMap(\.pages) {
            guard let recognized = recognizedPages[page.file] else { continue }
            let url = try page.url(in: folder)
            var proposed: PageFields?
            if available {
                do {
                    proposed = try await worker.predict(recognized, imageURL: url, in: folder, examples: examples)
                } catch {
                    ScanLog.write("  Field worker for \(page.file): \(error). Saving the searchable PDF.")
                    available = false
                }
            }
            fields[page.file] = PageFields.verified(proposed, in: recognized)
        }
        return fields
    }

    package func writePDFs(in folder: URL, recognizedPages: [String: RecognizedPage] = [:], fields: [String: PageFields] = [:]) throws {
        for (index, document) in documents.enumerated() {
            let result = resultURL(in: folder, index: index)
            let metadata = PageFields.pdfInfo(document.pages.compactMap { fields[$0.file] })
            guard let context = CGContext(result as CFURL, mediaBox: nil, metadata as CFDictionary) else { throw ImageWriterError.cannotWrite(result) }
            try PDFWriter.write(pages: document.pages.count, in: context, jpegQuality: jpegQuality,
                                textLayer: { index, box, context in
                guard let page = recognizedPages[document.pages[index].file] else { return }
                PDFTextLayer.draw(page, in: box, context: context)
            }) { index in
                let page = document.pages[index]
                guard let image = try page.image(in: folder) else { throw ImageWriterError.cannotCreateImage }
                return (image, page.resolution)
            }
        }
        do {
            try JSONEncoder().encode(fields).write(to: folder.appendingPathComponent("fields.json"), options: .atomic)
        } catch {
            ScanLog.write("  Could not save fields.json for \(folder.path): \(error.localizedDescription).")
        }
    }

    fileprivate func validatePDFs(in folder: URL) throws {
        for (index, document) in documents.enumerated() {
            let pdf = resultURL(in: folder, index: index)
            guard CGPDFDocument(pdf as CFURL)?.numberOfPages == document.pages.count else { throw ImageWriterError.cannotWrite(pdf) }
        }
    }

    @discardableResult
    func publish(in folder: URL, includeFields: Bool = true) throws -> [OCRDocumentOutput] {
        defer { documents.forEach { $0.reservation?.release() } }
        try validatePDFs(in: folder)
        let file = folder.appendingPathComponent("fields.json")
        var fields: [String: PageFields] = [:]
        if includeFields {
            fields = (try? JSONDecoder().decode([String: PageFields].self, from: Data(contentsOf: file))) ?? [:]
        }
        return try documents.enumerated().map { index, document in
            let pdf = resultURL(in: folder, index: index)
            let pages = document.pages.compactMap { fields[$0.file] }
            guard let reservation = document.reservation else { throw ImageWriterError.cannotWrite(document.outputURL) }
            if let name = document.exportName {
                let urls = try DocumentWriter.publishPDF(pdf, sidecars: PageFields.sidecars(pages),
                                                         in: reservation.directory, name: name, reservation: reservation)
                return OCRDocumentOutput(pdf: urls[0], sidecars: Array(urls.dropFirst()), pages: pages)
            }
            try reservation.publish(pdf, pages: document.pages.count)
            return OCRDocumentOutput(pdf: reservation.output, sidecars: [], pages: pages)
        }
    }
}

struct OCRRecoveryError: LocalizedError, CustomStringConvertible {
    let folder: URL
    let saved: Int
    let total: Int
    let cause: Error
    var directory: PDFDirectory? = nil

    var description: String {
        if saved == 0 {
            return "Could not save the PDFs (\(cause.localizedDescription)). Check \(folder.path) for recoverable files."
        }
        let pages = saved == total ? "The original pages are" : "\(saved) of \(total) original pages are"
        return "Could not save the PDFs (\(cause.localizedDescription)). \(pages) in \(folder.path)."
    }

    var errorDescription: String? { description }
}

final class OCRJob: @unchecked Sendable {
    private let finished = DispatchGroup()
    private var outputs: Result<[OCRDocumentOutput], Error> = .success([])

    init(batch: OCRBatch, folder: URL, helper: URL) {
        DispatchQueue.global(qos: .userInitiated).async(group: finished) { [self] in
            let child = Process()
            child.executableURL = helper
            child.arguments = [folder.path]
            var reason: String?
            do {
                try child.run()
                child.waitUntilExit()
                if child.terminationReason != .exit || child.terminationStatus != 0 {
                    reason = "\(child.terminationReason == .exit ? "exit" : "signal") \(child.terminationStatus)"
                } else {
                    do { try batch.validatePDFs(in: folder) } catch { reason = "incomplete output: \(error)" }
                }
            } catch {
                reason = "could not launch \(helper.path): \(error)"
            }
            finish(batch, in: folder, fallbackReason: reason)
        }
    }

    private func finish(_ batch: OCRBatch, in folder: URL, fallbackReason: String?) {
        do {
            if let fallbackReason {
                ScanLog.write("  yomi-ocr \(fallbackReason). Saving image-only PDFs.")
                try batch.writePDFs(in: folder)
            }
            outputs = .success(try batch.publish(in: folder, includeFields: fallbackReason == nil))
            try? FileManager.default.removeItem(at: folder)
        } catch {
            let count = batch.documents.reduce(0) { $0 + $1.pages.count }
            let recovery = OCRRecoveryError(folder: folder, saved: count, total: count, cause: error)
            outputs = .failure(recovery)
            ScanLog.write("  \(recovery)")
        }
    }

    @discardableResult
    func wait() throws -> [OCRDocumentOutput] {
        finished.wait()
        return try outputs.get()
    }

    func notify(on queue: DispatchQueue, _ completion: @escaping @Sendable (Result<[OCRDocumentOutput], Error>) -> Void) {
        finished.notify(queue: queue) { completion(Result { try self.wait() }) }
    }
}
