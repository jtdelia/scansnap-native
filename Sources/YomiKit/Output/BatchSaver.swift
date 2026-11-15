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
    /// creating the album when there is none with that name.
    func add(_ photos: [PhotoImport], album: String) throws
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
            if let error = addToPhotos(saved, profile: profile, library: photoLibrary) {
                return SavedBatch(files: files, warning: "Couldn't save to Photos: \(error) Saved to \(folder) only.",
                                  place: folder)
            }
            return SavedBatch(files: files, warning: nil, place: "\(folder) and \(photosPlace(profile))")
        }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("Yomi-\(UUID().uuidString)", isDirectory: true)
        var staged = profile
        staged.folderPath = staging.path
        staged.subfolderPattern = []
        let saved = try DocumentWriter.saveFiles(pages, profile: staged, date: date, progress: progress)
        if let error = addToPhotos(saved, profile: profile, library: photoLibrary) {
            return try SavedBatch(files: move(saved, from: staging, into: profile, date: date),
                                  warning: "Couldn't save to Photos: \(error) Saved to \(folder) instead.",
                                  place: folder)
        }
        try? FileManager.default.removeItem(at: staging)
        return SavedBatch(files: [], warning: nil, place: photosPlace(profile))
    }

    /// Adds the saved files to Photos, one photo per file, and returns why that failed, or `nil` when it worked.
    private static func addToPhotos(_ saved: [DocumentWriter.SavedFile], profile: ScanProfile,
                                    library: (any PhotoLibrary)?) -> Error? {
        let photos = saved.map { file in
            file.original.map { PhotoImport(original: $0, edited: file.url) } ?? PhotoImport(original: file.url)
        }
        do {
            guard let library else { throw PhotoLibraryError.failed("Saving to Photos needs the Yomi app.") }
            try library.add(photos, album: profile.photosAlbum)
            return nil
        } catch {
            return error
        }
    }

    /// Moves staged files, and their `_original` copies, into the folder the scan profile saves in, numbering any
    /// that clash.
    private static func move(_ files: [DocumentWriter.SavedFile], from staging: URL, into profile: ScanProfile,
                             date: Date) throws -> [URL] {
        let folder = DocumentWriter.saveFolder(profile, date: date)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let moved = try files.map { file in
            let url = DocumentWriter.uniqueURL(in: folder, base: file.url.deletingPathExtension().lastPathComponent,
                                               ext: file.url.pathExtension)
            try FileManager.default.moveItem(at: file.url, to: url)
            if let original = file.original {
                let base = url.deletingPathExtension().lastPathComponent + "_original"
                try FileManager.default.moveItem(at: original,
                                                 to: DocumentWriter.uniqueURL(in: folder, base: base,
                                                                              ext: original.pathExtension))
            }
            return url
        }
        try? FileManager.default.removeItem(at: staging)
        return moved
    }

    private static func photosPlace(_ profile: ScanProfile) -> String {
        profile.photosAlbum.isEmpty ? "Photos" : "the Photos album “\(profile.photosAlbum)”"
    }
}
