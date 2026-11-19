import Foundation
import YomiKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: yomi-ocr <batch folder>\n".utf8))
    exit(2)
}
do {
    let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let batch = try JSONDecoder().decode(OCRBatch.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    try batch.writePDFs(in: folder, textLayer: PDFTextLayer.draw)
} catch {
    ScanLog.write("  yomi-ocr: \(error)")
    FileHandle.standardError.write(Data("yomi-ocr: \(error)\n".utf8))
    exit(1)
}
