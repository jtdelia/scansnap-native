import Foundation
import UniformTypeIdentifiers

/// Saves a finished batch according to a profile's file settings.
public enum DocumentWriter {
    /// Writes `pages` and returns the created files. `profile.nextNumber` is advanced by the caller.
    public static func save(_ pages: [ProcessedPage], profile: ScanProfile, date: Date = Date(),
                            progress: ((String) -> Void)? = nil) throws -> [URL] {
        guard !pages.isEmpty else { return [] }
        let folder = profile.folderURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        switch profile.fileFormat {
        case .pdf:
            let url = uniqueURL(in: folder, base: baseName(profile, date: date, number: profile.nextNumber), ext: "pdf")
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
                let base = profile.fileNaming == .dateTime
                    ? baseName(profile, date: date, number: 0) + String(format: "_%03d", index + 1)
                    : baseName(profile, date: date, number: profile.nextNumber + index)
                let url = uniqueURL(in: folder, base: base, ext: "jpg")
                try ImageWriter.write(page.image, to: url, type: .jpeg, resolution: page.resolution,
                                      quality: profile.compression.jpegQuality)
                urls.append(url)
            }
            return urls
        case .multiPageTIFF:
            let url = uniqueURL(in: folder, base: baseName(profile, date: date, number: profile.nextNumber),
                                ext: profile.fileFormat.fileExtension)
            try TIFFWriter.write(pages, to: url) { index in
                progress?("Saving page \(index + 1) of \(pages.count)…")
            }
            return [url]
        }
    }

    /// Files consumed by a save, used to advance `nextNumber`.
    public static func numbersUsed(pages: Int, profile: ScanProfile) -> Int {
        profile.fileFormat == .jpeg ? pages : 1
    }

    static func baseName(_ profile: ScanProfile, date: Date, number: Int) -> String {
        switch profile.fileNaming {
        case .dateTime:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            return formatter.string(from: date)
        case .prefixAndNumber:
            let digits = String(format: "%0\(max(1, profile.numberDigits))d", number)
            let prefix = profile.filePrefix.trimmingCharacters(in: .whitespaces)
            return prefix.isEmpty ? digits : "\(prefix) \(digits)"
        }
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
