import CoreGraphics
import Foundation
import Testing
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

        func recognized() throws -> Bool {
            if visionUnavailable {
                print("\(Test.current?.name ?? "OCR test") used image-only PDFs after \(stderr)", terminator: "")
                return false
            }
            try #require(status == 0 && stderr.isEmpty, "Helper exit \(status), stderr: \(stderr)")
            return true
        }
    }
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
