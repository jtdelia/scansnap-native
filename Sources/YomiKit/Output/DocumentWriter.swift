import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Saves a finished batch according to a profile's file settings.
public enum DocumentWriter {
    /// Writes `pages` and returns the created files. With auto-enhance on, each returned file is the enhanced
    /// one and its untouched copy, named with `_original`, sits beside it. `profile.nextNumber` is advanced by
    /// the caller.
    public static func save(_ pages: [ProcessedPage], profile: ScanProfile, date: Date = Date(),
                            progress: ((String) -> Void)? = nil) throws -> [URL] {
        try saveFiles(pages, profile: profile, date: date, progress: progress).map(\.url)
    }

    /// A file `save` wrote, and its untouched `_original` copy when auto-enhance wrote one.
    struct SavedFile {
        let url: URL
        let original: URL?
        /// The file's name: the part from the name pattern and the page and clash numbers after it.
        let name: FileName
    }

    /// A file name before its extension. Only `stem`, the part from the name pattern, is ever shortened; the
    /// page, clash and `_original` suffixes Yomi adds are always kept whole.
    struct FileName {
        var stem: String
        var suffix = ""

        var original: FileName { FileName(stem: stem, suffix: suffix + "_original") }
    }

    /// Like `save`, also telling which `_original` copy belongs to each file.
    static func saveFiles(_ pages: [ProcessedPage], profile: ScanProfile, date: Date,
                          progress: ((String) -> Void)?) throws -> [SavedFile] {
        guard !pages.isEmpty else { return [] }
        let folder = try openFolder(for: profile, date: date)
        let starts = firstPages(pages: pages.count, profile: profile)
        let names = baseNames(profile, firstPages: starts, date: date)

        return try starts.indices.map { file in
            let end = file + 1 < starts.count ? starts[file + 1] - 1 : pages.count
            let offset = starts[file] - 1
            let filePages = Array(pages[offset..<end])
            func save(_ pagesToWrite: [ProcessedPage], as name: FileName) throws -> (name: FileName, url: URL) {
                try folder.write(name, format: profile.fileFormat) { handle, url in
                    try write(pagesToWrite, to: handle, url: url, profile: profile, offset: offset,
                              total: pages.count, progress: progress)
                }
            }
            let main = try save(profile.enhancesPhotos ? filePages.map(AutoEnhancer.enhance) : filePages, as: names[file])
            let original = profile.enhancesPhotos ? try save(filePages, as: main.name.original).url : nil
            return SavedFile(url: main.url, original: original, name: main.name)
        }
    }

    /// Writes one file holding `pages`, which start at batch page `offset + 1` of `total`.
    private static func write(_ pages: [ProcessedPage], to handle: FileHandle, url: URL, profile: ScanProfile,
                              offset: Int, total: Int, progress: ((String) -> Void)?) throws {
        try withScanFileConsumer(handle, url: url) { consumer in
            func saving(_ index: Int) {
                let recognizing = profile.fileFormat == .pdf && profile.searchablePDF
                progress?("\(recognizing ? "Recognizing text on" : "Saving") page \(offset + index + 1) of \(total)…")
            }
            switch profile.fileFormat {
            case .pdf:
                guard let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
                    throw ImageWriterError.cannotWrite(url)
                }
                try PDFWriter.write(pages, in: context, jpegQuality: profile.compression.jpegQuality,
                                    searchable: profile.searchablePDF, progress: saving)
            case .jpeg, .png, .heic, .tiff, .multiPageTIFF:
                guard let destination = CGImageDestinationCreateWithDataConsumer(
                    consumer, profile.fileFormat.imageType.identifier as CFString, pages.count, nil)
                else { throw ImageWriterError.cannotWrite(url) }
                if profile.fileFormat.imageType == .tiff {
                    TIFFWriter.add(pages, to: destination, progress: saving)
                } else {
                    let page = pages[0]
                    saving(0)
                    ImageWriter.addImage(page.image, to: destination, resolution: page.resolution,
                                         quality: profile.compression.jpegQuality, caption: page.caption)
                }
                guard CGImageDestinationFinalize(destination) else { throw ImageWriterError.cannotWrite(url) }
            }
        }
    }

    /// Files consumed by a save, used to advance `nextNumber`.
    public static func numbersUsed(pages: Int, profile: ScanProfile) -> Int {
        profile.namePattern.usesRunningNumber ? firstPages(pages: pages, profile: profile).count : 0
    }

    /// Name of the first file a two-page batch scanned at `date` would get, before clash suffixes.
    public static func exampleFileName(for profile: ScanProfile, date: Date = Date()) -> String {
        let name = baseNames(profile, firstPages: firstPages(pages: 2, profile: profile), date: date)[0]
        return fileName(name, format: profile.fileFormat)
    }

    /// The batch's page number of the first page in each file the batch writes.
    private static func firstPages(pages: Int, profile: ScanProfile) -> [Int] {
        guard pages > 0 else { return [] }
        if profile.fileFormat.savesPagesSeparately { return Array(1...pages) }
        guard let pagesPerFile = profile.pagesPerFile, pagesPerFile > 0 else { return [1] }
        return Array(stride(from: 1, through: pages, by: pagesPerFile))
    }

    /// The subfolders, separated by `/`, a batch scanned at `date` would be saved in. Empty when there are none.
    public static func exampleSubfolder(for profile: ScanProfile, date: Date = Date()) -> String {
        subfolders(profile, date: date).joined(separator: "/")
    }

    /// The folder a batch scanned at `date` is saved in.
    public static func saveFolder(for profile: ScanProfile, date: Date = Date()) -> URL {
        subfolders(profile, date: date).reduce(profile.folderURL) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    static func openFolder(for profile: ScanProfile, date: Date) throws -> ScanFolder {
        try ScanFolder(root: profile.folderURL, subfolders: subfolders(profile, date: date))
    }

    /// The scan profile's folder name and the subfolders a batch scanned at `date` goes into, such as `Yomi/2026/11`.
    public static func folderName(for profile: ScanProfile, date: Date = Date()) -> String {
        ([profile.folderURL.lastPathComponent] + subfolders(profile, date: date)).joined(separator: "/")
    }

    /// Folder levels from the subfolder pattern. Only typed `/` starts a new level, and levels that are empty,
    /// `.` or `..` are left out, so the levels always stay inside the scan profile's folder.
    private static func subfolders(_ profile: ScanProfile, date: Date) -> [String] {
        let values = FileNamePattern.Values(date: date, profileName: fileSafe(profile.name), runningNumber: 0,
                                            numberDigits: 0, pageNumber: 0)
        let pattern = FileNamePattern(profile.subfolderPattern.pieces.filter { piece in
            if case .text = piece { true } else { FileNamePattern.Piece.batchWide.contains(piece) }
        })
        return pattern.render(values).split(separator: "/")
            .map { shortened(fileSafe(String($0)), toBytes: maxNameBytes) }
            .filter { !["", ".", ".."].contains($0) }
    }

    /// Names, without extension or clash number, for files starting at `firstPages`.
    static func baseNames(_ profile: ScanProfile, firstPages: [Int], date: Date) -> [FileName] {
        firstPages.enumerated().map { index, page in
            let values = FileNamePattern.Values(date: date, profileName: profile.name,
                                                runningNumber: profile.nextNumber + index,
                                                numberDigits: profile.numberDigits, pageNumber: page)
            var pattern = profile.namePattern
            var name = fileSafe(pattern.render(values))
            if name.isEmpty {
                pattern = .dateAndTime
                name = fileSafe(pattern.render(values))
            }
            let suffix = firstPages.count > 1 && !pattern.numbersFiles ? String(format: "_%03d", page) : ""
            return FileName(stem: name, suffix: suffix)
        }
    }

    private static let maxNameBytes = 255
    private static let maxImageNameBytes = 247

    /// Replaces the characters macOS does not allow in file names.
    static func fileSafe(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-", options: .literal)
            .replacingOccurrences(of: ":", with: "-", options: .literal)
            .replacingOccurrences(of: "\0", with: "-", options: .literal)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `name` with the format's extension, its stem shortened only as far as the file system's limit needs.
    static func fileName(_ name: FileName, format: ScanProfile.FileFormat) -> String {
        let tail = "\(name.suffix).\(format.fileExtension)"
        let limit = format == .pdf ? maxNameBytes : maxImageNameBytes
        return shortened(name.stem, toBytes: limit - byteCount(tail)) + tail
    }

    private static func byteCount(_ text: String) -> Int {
        text.decomposedStringWithCanonicalMapping.utf8.count
    }

    /// `text` unchanged when it fits in `limit` bytes, otherwise cut to fit, without trailing spaces.
    private static func shortened(_ text: String, toBytes limit: Int) -> String {
        guard byteCount(text) > limit else { return text }
        var bytes = 0
        return text.prefix { character in
            bytes += byteCount(String(character))
            return bytes <= limit
        }.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension ScanProfile.FileFormat {
    var imageType: UTType {
        switch self {
        case .pdf: .pdf
        case .jpeg: .jpeg
        case .png: .png
        case .tiff, .multiPageTIFF: .tiff
        case .heic: .heic
        }
    }
}
