import Foundation
import YomiKit

let arguments = CommandLine.arguments
if arguments.count == 5, arguments[1] == "--predict" {
    do {
        try await FieldWorker.respond(input: URL(fileURLWithPath: arguments[2]), imageURL: URL(fileURLWithPath: arguments[3]),
                                      output: URL(fileURLWithPath: arguments[4]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("yomi-ocr: \(error)\n".utf8))
        exit(1)
    }
}
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: yomi-ocr <batch folder>\n".utf8))
    exit(2)
}
do {
    let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let batch = try JSONDecoder().decode(OCRBatch.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    let pages = try await batch.recognizePages(in: folder)
    let fields = try await batch.readFields(in: folder, recognizedPages: pages)
    try batch.writePDFs(in: folder, recognizedPages: pages, fields: fields)
} catch {
    ScanLog.write("  yomi-ocr: \(error)")
    FileHandle.standardError.write(Data("yomi-ocr: \(error)\n".utf8))
    exit(1)
}
