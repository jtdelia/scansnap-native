import Foundation
import UniformTypeIdentifiers

/// Saves a finished batch according to a profile's file settings.
public enum DocumentWriter {
    /// Writes `pages` and returns the created files. `profile.nextNumber` is advanced by the caller.
    public static func save(_ pages: [ProcessedPage], profile: ScanProfile, date: Date = Date(),
                            progress: ((String) -> Void)? = nil) throws -> [URL] {
        guard !pages.isEmpty else { return [] }
        let folder = saveFolder(profile, date: date)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = baseNames(profile, firstPages: firstPages(pages: pages.count, profile: profile), date: date)

        switch profile.fileFormat {
        case .pdf:
            let url = uniqueURL(in: folder, base: names[0], ext: "pdf")
            try PDFWriter.write(pages, to: url, jpegQuality: profile.compression.jpegQuality,
                                searchable: profile.searchablePDF) { index in
                progress?(profile.searchablePDF
                    ? "Recognizing text on page \(index + 1) of \(pages.count)…"
                    : "Saving page \(index + 1) of \(pages.count)…")
            }
            return [url]
        case .jpeg:
            var urls: [URL] = []
            for (index, page) in pages.enumerated() {
                progress?("Saving page \(index + 1) of \(pages.count)…")
                let url = uniqueURL(in: folder, base: names[index], ext: "jpg")
                try ImageWriter.write(page.image, to: url, type: .jpeg, resolution: page.resolution,
                                      quality: profile.compression.jpegQuality)
                urls.append(url)
            }
            return urls
        case .multiPageTIFF:
            let url = uniqueURL(in: folder, base: names[0], ext: profile.fileFormat.fileExtension)
            try TIFFWriter.write(pages, to: url) { index in
                progress?("Saving page \(index + 1) of \(pages.count)…")
            }
            return [url]
        }
    }

    /// Files consumed by a save, used to advance `nextNumber`.
    public static func numbersUsed(pages: Int, profile: ScanProfile) -> Int {
        profile.namePattern.usesRunningNumber ? firstPages(pages: pages, profile: profile).count : 0
    }

    /// Name of the first file a two-page batch scanned at `date` would get, before clash suffixes.
    public static func exampleFileName(for profile: ScanProfile, date: Date = Date()) -> String {
        let name = baseNames(profile, firstPages: firstPages(pages: 2, profile: profile), date: date)[0]
        return "\(name).\(profile.fileFormat.fileExtension)"
    }

    /// The batch's page number of the first page in each file the batch writes.
    private static func firstPages(pages: Int, profile: ScanProfile) -> [Int] {
        guard pages > 0 else { return [] }
        return profile.fileFormat == .jpeg ? Array(1...pages) : [1]
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
            .map { fileSafe(String($0)) }
            .filter { !["", ".", ".."].contains($0) }
    }

    /// Names, without extension or clash number, for files starting at `firstPages`.
    static func baseNames(_ profile: ScanProfile, firstPages: [Int], date: Date) -> [String] {
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
            if firstPages.count > 1, !pattern.numbersFiles {
                name += String(format: "_%03d", page)
            }
            return name
        }
    }

    /// Longest name, in bytes as the file system stores it, leaving room under macOS's 255-byte limit
    /// for a page number, clash number and extension.
    private static let maxNameBytes = 200

    /// Replaces the characters macOS does not allow in file names and shortens names that are too long.
    static func fileSafe(_ name: String) -> String {
        let name = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var bytes = 0
        let kept = name.prefix { character in
            bytes += String(character).decomposedStringWithCanonicalMapping.utf8.count
            return bytes <= maxNameBytes
        }
        return kept.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func uniqueURL(in folder: URL, base: String, ext: String) -> URL {
        var url = folder.appendingPathComponent(base).appendingPathExtension(ext)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(counter))").appendingPathExtension(ext)
            counter += 1
        }
        return url
    }
}
