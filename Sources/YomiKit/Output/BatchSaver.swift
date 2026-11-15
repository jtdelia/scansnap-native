import Foundation

/// One photo to add to Photos: the untouched scan, and the enhanced version of it when auto-enhance made one.
public struct PhotoImport: Sendable, Equatable {
    /// The scan as it came from the scanner, which Photos keeps as the photo's original.
    public let original: URL
    /// The enhanced scan, which Photos shows as an edit that Revert to Original undoes.
    public let edited: URL?

    /// The file name Photos records for the photo, without `_original`.
    public var name: String { (edited ?? original).lastPathComponent }

    public init(original: URL, edited: URL? = nil) {
        self.original = original
        self.edited = edited
    }
}

/// Apple Photos, as the app reaches it through PhotoKit.
public protocol PhotoLibrary: Sendable {
    /// Adds one photo for each of `photos` to the library, and to the album named `album` unless it is empty,
    /// creating the album when there is none with that name. Returns how many photos were added without the
    /// enhancement they were given.
    func add(_ photos: [PhotoImport], album: String) throws -> Int
}

public enum PhotoLibraryError: Error, Equatable, CustomStringConvertible {
    case accessDenied
    case albumNotCreated(String)
    case failed(String)

    public var description: String {
        switch self {
        case .accessDenied: "Yomi isn't allowed to use Photos. Allow it in System Settings › Privacy & Security › Photos."
        case let .albumNotCreated(album): "The album “\(album)” couldn't be created."
        case let .failed(reason): reason
        }
    }
}

/// Where a batch ended up.
public struct SavedBatch: Sendable {
    /// Files left in the folder.
    public let files: [URL]
    /// Why the batch is not where the scan profile asked, if it isn't.
    public let warning: String?
    /// Where the batch went, for "Saved 3 pages to …".
    public let place: String
    /// Something the batch saved without, that is still worth saying, such as Photos dropping an enhancement.
    public var notice: String? = nil
}

/// Saves a finished batch to the scan profile's folder, Photos, or both.
public enum BatchSaver {
    public static func save(_ pages: [ProcessedPage], profile: ScanProfile, photoLibrary: (any PhotoLibrary)?,
                            date: Date = Date(), progress: ((String) -> Void)? = nil) throws -> SavedBatch {
        let folder = profile.folderURL.lastPathComponent
        guard profile.saveTo.savesToPhotos else {
            let files = try DocumentWriter.save(pages, profile: profile, date: date, progress: progress)
            return SavedBatch(files: files, warning: nil, place: folder)
        }
        if profile.saveTo.savesToFolder {
            let saved = try DocumentWriter.saveFiles(pages, profile: profile, date: date, progress: progress)
            let files = saved.map(\.url)
            switch addToPhotos(saved, profile: profile, library: photoLibrary) {
            case let .failure(error):
                return SavedBatch(files: files, warning: "Couldn't save to Photos: \(error) Saved to \(folder) only.",
                                  place: folder)
            case let .success(unenhanced):
                return SavedBatch(files: files, warning: nil, place: "\(folder) and \(photosPlace(profile))",
                                  notice: enhancementNotice(unenhanced))
            }
        }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("Yomi-\(UUID().uuidString)", isDirectory: true)
        var staged = profile
        staged.folderPath = staging.path
        staged.subfolderPattern = []
        let saved = try DocumentWriter.saveFiles(pages, profile: staged, date: date, progress: progress)
        let added = addToPhotos(saved, profile: profile, library: photoLibrary)
        if case let .failure(error) = added {
            let reason = "Couldn't save to Photos: \(error)"
            do {
                let files = try copy(saved, into: profile, date: date)
                try? FileManager.default.removeItem(at: staging)
                return SavedBatch(files: files, warning: "\(reason) Saved to \(folder) instead.", place: folder)
            } catch {
                return SavedBatch(files: saved.map(\.url),
                                  warning: "\(reason) Couldn't save to \(folder) either (\(error.localizedDescription)). "
                                      + "The batch is in \(staging.path), which macOS empties after a few days.",
                                  place: staging.path)
            }
        }
        try? FileManager.default.removeItem(at: staging)
        return SavedBatch(files: [], warning: nil, place: photosPlace(profile),
                          notice: enhancementNotice((try? added.get()) ?? 0))
    }

    /// Adds the saved files to Photos, one photo per file, and returns how many lost their enhancement.
    private static func addToPhotos(_ saved: [DocumentWriter.SavedFile], profile: ScanProfile,
                                    library: (any PhotoLibrary)?) -> Result<Int, Error> {
        let photos = saved.map { file in
            file.original.map { PhotoImport(original: $0, edited: file.url) } ?? PhotoImport(original: file.url)
        }
        return Result {
            guard let library else { throw PhotoLibraryError.failed("Saving to Photos needs the Yomi app.") }
            return try library.add(photos, album: profile.photosAlbum)
        }
    }

    private static func enhancementNotice(_ unenhanced: Int) -> String? {
        unenhanced == 0 ? nil : "Saved to Photos without enhancement for \(unenhanced) photo\(unenhanced == 1 ? "" : "s")."
    }

    /// Copies staged files, and their `_original` copies, into the folder the scan profile saves in, numbering any
    /// that clash. When a copy fails, the copies already made are removed and the staged files are left alone.
    private static func copy(_ files: [DocumentWriter.SavedFile], into profile: ScanProfile, date: Date) throws -> [URL] {
        let fm = FileManager.default
        let folder = DocumentWriter.saveFolder(profile, date: date)
        var copied: [URL] = []
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            return try files.map { file in
                let format = profile.fileFormat
                let name = DocumentWriter.unclashedName(in: folder, file.name, format: format)
                let url = folder.appendingPathComponent(DocumentWriter.fileName(name, format: format))
                try fm.copyItem(at: file.url, to: url)
                copied.append(url)
                if let original = file.original {
                    let originalURL = DocumentWriter.originalURL(in: folder, for: name, format: format)
                    try fm.copyItem(at: original, to: originalURL)
                    copied.append(originalURL)
                }
                return url
            }
        } catch {
            copied.forEach { try? fm.removeItem(at: $0) }
            throw error
        }
    }

    private static func photosPlace(_ profile: ScanProfile) -> String {
        profile.photosAlbum.isEmpty ? "Photos" : "the Photos album “\(profile.photosAlbum)”"
    }
}
