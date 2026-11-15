import Foundation
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
    }

    /// Like `save`, also telling which `_original` copy belongs to each file.
    static func saveFiles(_ pages: [ProcessedPage], profile: ScanProfile, date: Date,
                          progress: ((String) -> Void)?) throws -> [SavedFile] {
        guard !pages.isEmpty else { return [] }
        let folder = saveFolder(profile, date: date)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let starts = firstPages(pages: pages.count, profile: profile)
        let names = baseNames(profile, firstPages: starts, date: date)

        return try starts.indices.map { file in
            let end = file + 1 < starts.count ? starts[file + 1] - 1 : pages.count
            let offset = starts[file] - 1
            let filePages = Array(pages[offset..<end])
            let name = unclashedName(in: folder, names[file], format: profile.fileFormat)
            let url = folder.appendingPathComponent(fileName(name, format: profile.fileFormat))
            guard profile.enhancesPhotos else {
                try write(filePages, to: url, profile: profile, offset: offset, total: pages.count, progress: progress)
                return SavedFile(url: url, original: nil, name: name)
            }
            try write(filePages.map(AutoEnhancer.enhance), to: url, profile: profile, offset: offset,
                      total: pages.count, progress: progress)
            let original = originalURL(in: folder, for: name, format: profile.fileFormat)
            try write(filePages, to: original, profile: profile, offset: offset, total: pages.count, progress: progress)
            return SavedFile(url: url, original: original, name: name)
        }
    }

    /// Writes one file holding `pages`, which start at batch page `offset + 1` of `total`.
    private static func write(_ pages: [ProcessedPage], to url: URL, profile: ScanProfile, offset: Int, total: Int,
                              progress: ((String) -> Void)?) throws {
        switch profile.fileFormat {
        case .pdf:
            try PDFWriter.write(pages, to: url, jpegQuality: profile.compression.jpegQuality,
                                searchable: profile.searchablePDF) { index in
                let page = offset + index + 1
                progress?(profile.searchablePDF
                    ? "Recognizing text on page \(page) of \(total)…"
                    : "Saving page \(page) of \(total)…")
            }
        case .jpeg, .png, .heic:
            for (index, page) in pages.enumerated() {
                progress?("Saving page \(offset + index + 1) of \(total)…")
                try ImageWriter.write(page.image, to: url, type: profile.fileFormat.imageType,
                                      resolution: page.resolution, quality: profile.compression.jpegQuality,
                                      caption: page.caption)
            }
        case .tiff, .multiPageTIFF:
            try TIFFWriter.write(pages, to: url) { index in
                progress?("Saving page \(offset + index + 1) of \(total)…")
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
    static func saveFolder(_ profile: ScanProfile, date: Date) -> URL {
        subfolders(profile, date: date).reduce(profile.folderURL) { $0.appendingPathComponent($1, isDirectory: true) }
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

    /// macOS's limit for a file or folder name, in bytes as the file system stores it. PDFs are written straight to
    /// their file; ImageIO writes images through a temporary file whose name is 8 bytes longer, so image file
    /// names stop at 247 bytes.
    private static let maxNameBytes = 255
    private static let imageIOHeadroom = 8

    /// Replaces the characters macOS does not allow in file names.
    static func fileSafe(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `name` with the format's extension, its stem shortened only as far as the file system's limit needs.
    static func fileName(_ name: FileName, format: ScanProfile.FileFormat) -> String {
        let tail = "\(name.suffix).\(format.fileExtension)"
        let limit = format == .pdf ? maxNameBytes : maxNameBytes - imageIOHeadroom
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

    /// `name`, with ` (2)`, ` (3)`… added to its suffix until no file in `folder` has it.
    static func unclashedName(in folder: URL, _ name: FileName, format: ScanProfile.FileFormat) -> FileName {
        var candidate = name
        var counter = 2
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent(fileName(candidate, format: format)).path) {
            candidate.suffix = "\(name.suffix) (\(counter))"
            counter += 1
        }
        return candidate
    }

    /// Where the untouched copy of the file called `name` goes: the same name with `_original` added.
    static func originalURL(in folder: URL, for name: FileName, format: ScanProfile.FileFormat) -> URL {
        let original = FileName(stem: name.stem, suffix: name.suffix + "_original")
        return folder.appendingPathComponent(fileName(unclashedName(in: folder, original, format: format), format: format))
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
