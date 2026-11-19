import CoreGraphics
import Foundation
import Testing
import Vision
@testable import YomiKit

struct OCRTestHelper {
    private final class TestBundle: NSObject {}

    static var executable: URL {
        Bundle(for: TestBundle.self).bundleURL.deletingLastPathComponent().appendingPathComponent("yomi-ocr")
    }

    private let folder: URL
    var script: URL { folder.appendingPathComponent("run-helper") }

    init(in folder: URL) throws {
        self.folder = folder
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: folder.appendingPathComponent("yomi-ocr"), withDestinationURL: Self.executable)
        try """
        #!/bin/zsh
        "${0:h}/yomi-ocr" "$@" 2> "${0:h}/helper-errors"
        code=$?
        print -r -- "$code" > "${0:h}/helper-status"
        exit "$code"
        """.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    }

    func run(on batch: URL) throws -> Output {
        let child = Process()
        child.executableURL = script
        child.arguments = [batch.path]
        try child.run()
        child.waitUntilExit()
        let output = try output()
        try #require(child.terminationReason == .exit && child.terminationStatus == output.status)
        return output
    }

    func output() throws -> Output {
        let status = try String(contentsOf: folder.appendingPathComponent("helper-status"), encoding: .utf8)
        let stderr = try String(contentsOf: folder.appendingPathComponent("helper-errors"), encoding: .utf8)
        return Output(status: try #require(Int32(status.trimmingCharacters(in: .newlines))), stderr: stderr)
    }

    struct Output {
        let status: Int32
        let stderr: String

        var visionUnavailable: Bool {
            let prefix = "yomi-ocr: Vision text recognition: "
            guard status == 1, stderr.hasPrefix(prefix), stderr.hasSuffix("\n") else { return false }
            let diagnostic = stderr.dropFirst(prefix.count).dropLast()
            switch diagnostic {
            case "TextRecognition.CRImageReaderError.unknownError",
                 #"TextRecognition.CRImageReaderError.e5rtError("e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed", 13)"#,
                 #"TextRecognition.CRImageReaderError.e5rtError("e5rt_stream_completion_handler call failed", 10)"#:
                return true
            default:
                let codeNine = #/Error Domain=(TextRecognition\.CRImageReaderError|com\.apple\.Vision) Code=9 "[^"\n]*"(?: UserInfo=\{[^\n]*\})?/#
                return diagnostic.wholeMatch(of: codeNine) != nil
            }
        }

        func unavailableReason(on page: String? = nil) async -> String? {
            if page == nil, visionUnavailable { return String(stderr.dropLast()) }
            let prefix = "yomi-ocr: "
            guard status == 1, stderr.hasPrefix(prefix), stderr.hasSuffix("\n") else { return nil }
            return await visionUnavailableReason(String(stderr.dropFirst(prefix.count).dropLast()), on: page)
        }

        func recognized() async throws -> Bool {
            if let reason = await unavailableReason() {
                print("\(Test.current?.name ?? "OCR test") used image-only PDFs after \(reason)")
                return false
            }
            try #require(status == 0 && stderr.isEmpty, "Helper exit \(status), stderr: \(stderr)")
            return true
        }
    }
}

private let documentRequestFailure = #/RecognizeDocumentsRequest\.perform on (page-[1-9][0-9]*\.png): (.+)/#

func isVisionComputeFailure(_ diagnostic: String) -> Bool {
    let request = diagnostic.wholeMatch(of: documentRequestFailure)
    let cause = request.map { String($0.2) } ?? diagnostic
    let reader = request == nil ? "" : "TextRecognition.CRImageReaderError."
    switch cause {
    case reader + #"e5rtError("e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed", 13)"#,
         reader + #"e5rtError("e5rt_stream_completion_handler call failed", 10)"#,
         reader + #"e5rtError("e5rt_e5_compiler_compile call failed", 11)"#:
        return true
    default:
        return cause.wholeMatch(of: #/(?:Vision\.VisionError\.)?unsupportedComputeDevice\(".+"\)/#) != nil
            || cause.wholeMatch(of: #/Error Domain=TextRecognition\.CRImageReaderError Code=9 "[^\n]*"(?: UserInfo=\{[^\n]*\})?/#) != nil
    }
}

private let renderedTextReaderError = Task<NSError?, Never> {
    do {
        _ = try await ScanProfile.TextRecognitionLanguage.automatic.documentRequest.perform(on: DocumentFixture.order.image)
        return nil
    } catch {
        return error as NSError
    }
}

func visionUnavailableReason(_ diagnostic: String, on page: String? = nil,
                            control: () async -> NSError? = { await renderedTextReaderError.value }) async -> String? {
    let request = diagnostic.wholeMatch(of: documentRequestFailure)
    if let page, request?.1 != Substring(page) { return nil }
    if isVisionComputeFailure(diagnostic) { return diagnostic }
    guard request?.2 == "TextRecognition.CRImageReaderError.unknownError", let error = await control(),
          error.domain == "TextRecognition.CRImageReaderError", error.code == 9 else { return nil }
    return "\(diagnostic) (rendered order: \(error.domain) code=\(error.code))"
}

func reportVisionFailure(_ error: Error, on page: String? = nil) async throws -> Never {
    guard let reason = await visionUnavailableReason(String(describing: error), on: page) else { throw error }
    try reportVisionUnavailable(reason)
}

func reportVisionUnavailable(_ reason: String) throws -> Never {
    print("\(Test.current?.name ?? "OCR test") unavailable: \(reason)")
    try Test.cancel("\(reason)")
}

func expectJPEGRaster(_ original: ProcessedPage, quality: Double, in pdf: URL, pageNumber: Int = 1) throws {
    let document = try #require(CGPDFDocument(pdf as CFURL))
    let page = try #require(document.page(at: pageNumber))
    let box = page.getBoxRect(.mediaBox)
    #expect(box.origin == .zero)
    #expect(abs(box.width - Double(original.image.width) * 72 / Double(original.resolution)) < 0.001)
    #expect(abs(box.height - Double(original.image.height) * 72 / Double(original.resolution)) < 0.001)
    var resources: CGPDFDictionaryRef?, objects: CGPDFDictionaryRef?
    CGPDFDictionaryGetDictionary(try #require(page.dictionary), "Resources", &resources)
    CGPDFDictionaryGetDictionary(try #require(resources), "XObject", &objects)
    let images = try #require(objects)
    try #require(CGPDFDictionaryGetCount(images) == 1)
    var jpeg: Data?
    CGPDFDictionaryApplyBlock(images, { _, object, _ in
        var stream: CGPDFStreamRef?, format = CGPDFDataFormat.raw
        if CGPDFObjectGetValue(object, .stream, &stream), let stream, let data = CGPDFStreamCopyData(stream, &format), format == .jpegEncoded {
            jpeg = data as Data
        }
        return false
    }, nil)
    let expected = try PDFWriter.jpegData(original.image, quality: quality)
    let startOfFrame = try #require(expected.range(of: Data([0xff, 0xc0])))
    let frame = expected[startOfFrame.lowerBound...]
    let embedded = try #require(jpeg)
    #expect(embedded.suffix(frame.count) == frame)
}
