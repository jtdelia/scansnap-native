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
        package let pages: [Page]
        fileprivate var reservation: PDFReservation?

        private enum CodingKeys: CodingKey { case outputURL, pages }
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
                return Document(outputURL: reservation.output, pages: Array(staged[group.range]), reservation: reservation)
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

    package func writePDFs(in folder: URL, recognizedPages: [String: RecognizedPage] = [:]) throws {
        for (index, document) in documents.enumerated() {
            let result = resultURL(in: folder, index: index)
            guard let context = CGContext(result as CFURL, mediaBox: nil, nil) else { throw ImageWriterError.cannotWrite(result) }
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
    }

    fileprivate func validatePDFs(in folder: URL) throws {
        for (index, document) in documents.enumerated() {
            let pdf = resultURL(in: folder, index: index)
            guard CGPDFDocument(pdf as CFURL)?.numberOfPages == document.pages.count else { throw ImageWriterError.cannotWrite(pdf) }
        }
    }

    func publish(in folder: URL) throws {
        defer { documents.forEach { $0.reservation?.release() } }
        try validatePDFs(in: folder)
        for (index, document) in documents.enumerated() {
            guard let reservation = document.reservation else { throw ImageWriterError.cannotWrite(document.outputURL) }
            try reservation.publish(resultURL(in: folder, index: index), pages: document.pages.count)
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
    private var failure: Error?

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
            try batch.publish(in: folder)
            try? FileManager.default.removeItem(at: folder)
        } catch {
            let count = batch.documents.reduce(0) { $0 + $1.pages.count }
            let recovery = OCRRecoveryError(folder: folder, saved: count, total: count, cause: error)
            failure = recovery
            ScanLog.write("  \(recovery)")
        }
    }

    func wait() throws {
        finished.wait()
        if let failure { throw failure }
    }

    func notify(on queue: DispatchQueue, _ completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        finished.notify(queue: queue) { completion(Result { try self.wait() }) }
    }
}
