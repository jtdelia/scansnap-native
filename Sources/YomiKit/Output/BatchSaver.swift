import Foundation

/// Apple Photos, as the app reaches it through PhotoKit.
public protocol PhotoLibrary: Sendable {
    /// Adds the photo files to the library, and to the album named `album` unless it is empty, creating the
    /// album when there is none with that name.
    func add(_ files: [URL], album: String) throws
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
            let files = try DocumentWriter.save(pages, profile: profile, date: date, progress: progress)
            if let error = addToPhotos(files, profile: profile, library: photoLibrary) {
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
        let files = try DocumentWriter.save(pages, profile: staged, date: date, progress: progress)
        if let error = addToPhotos(files, profile: profile, library: photoLibrary) {
            return try SavedBatch(files: move(files, from: staging, into: profile, date: date),
                                  warning: "Couldn't save to Photos: \(error) Saved to \(folder) instead.",
                                  place: folder)
        }
        try? FileManager.default.removeItem(at: staging)
        return SavedBatch(files: [], warning: nil, place: photosPlace(profile))
    }

    /// Adds `files` to Photos and returns why that failed, or `nil` when it worked.
    private static func addToPhotos(_ files: [URL], profile: ScanProfile, library: (any PhotoLibrary)?) -> Error? {
        do {
            guard let library else { throw PhotoLibraryError.failed("Saving to Photos needs the Yomi app.") }
            try library.add(files, album: profile.photosAlbum)
            return nil
        } catch {
            return error
        }
    }

    /// Moves staged files into the folder the scan profile saves in, numbering any that clash.
    private static func move(_ files: [URL], from staging: URL, into profile: ScanProfile, date: Date) throws -> [URL] {
        let folder = DocumentWriter.saveFolder(profile, date: date)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let moved = try files.map { file in
            let url = DocumentWriter.uniqueURL(in: folder, base: file.deletingPathExtension().lastPathComponent,
                                               ext: file.pathExtension)
            try FileManager.default.moveItem(at: file, to: url)
            return url
        }
        try? FileManager.default.removeItem(at: staging)
        return moved
    }

    private static func photosPlace(_ profile: ScanProfile) -> String {
        profile.photosAlbum.isEmpty ? "Photos" : "the Photos album “\(profile.photosAlbum)”"
    }
}
