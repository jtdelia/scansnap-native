import Foundation

/// One photo to add to Photos: the untouched page, and the enhanced version of it when auto-enhance made one.
public struct PhotoImport: Sendable, Equatable {
    /// The page as Yomi processed it, before auto-enhance, which Photos keeps as the photo's original.
    public let original: URL
    /// The enhanced page, which Photos shows as an edit that Revert to Original undoes.
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
    /// The folder holding `files`, or `nil` when the batch went only to Photos.
    public var folder: URL? = nil
    /// Something the batch saved without, that is still worth saying, such as Photos dropping an enhancement.
    public var notice: String? = nil
}

/// Saves a finished batch to the scan profile's folder, Photos, or both.
public enum BatchSaver {
    public static func save(_ pages: [ProcessedPage], profile: ScanProfile, photoLibrary: (any PhotoLibrary)?,
                            date: Date = Date(), progress: ((String) -> Void)? = nil) throws -> SavedBatch {
        let (saved, recognition) = try start(pages, profile: profile, photoLibrary: photoLibrary, date: date,
                                             progress: progress)
        try recognition?.wait()
        return saved
    }

    static func start(_ pages: [ProcessedPage], profile: ScanProfile, photoLibrary: (any PhotoLibrary)?,
                      date: Date = Date(), helper: URL = OCRBatch.helperURL,
                      progress: ((String) -> Void)? = nil) throws -> (SavedBatch, OCRJob?) {
        guard !pages.isEmpty, profile.fileFormat == .pdf else {
            return (try saveImages(pages, profile: profile, photoLibrary: photoLibrary, date: date, progress: progress), nil)
        }
        let place = DocumentWriter.folderName(for: profile, date: date)
        let destination = DocumentWriter.saveFolder(for: profile, date: date)
        var recovery: OCRRecoveryError?
        if profile.searchablePDF {
            do {
                progress?("Preparing pages for text recognition…")
                let (batch, folder) = try OCRBatch.stage(pages, profile: profile, date: date)
                let saved = SavedBatch(files: batch.documents.map(\.outputURL), warning: nil, place: place, folder: destination)
                return (saved, OCRJob(batch: batch, folder: folder, helper: helper))
            } catch {
                ScanLog.write("  Could not stage pages for yomi-ocr: \(error). Saving image-only PDFs.")
                recovery = error as? OCRRecoveryError
            }
        }
        var imageOnly = profile
        imageOnly.searchablePDF = false
        let files = try DocumentWriter.savePDFs(pages, profile: imageOnly, date: date, progress: progress, recovery: recovery)
        return (SavedBatch(files: files.map(\.url), warning: nil, place: place, folder: destination), nil)
    }

    private static func saveImages(_ pages: [ProcessedPage], profile: ScanProfile, photoLibrary: (any PhotoLibrary)?,
                                   date: Date, progress: ((String) -> Void)?) throws -> SavedBatch {
        let folder = DocumentWriter.folderName(for: profile, date: date)
        let folderURL = DocumentWriter.saveFolder(for: profile, date: date)
        guard profile.destination.savesToPhotos else {
            let files = try DocumentWriter.save(pages, profile: profile, date: date, progress: progress)
            return SavedBatch(files: files, warning: nil, place: folder, folder: folderURL)
        }
        if profile.destination.savesToFolder {
            let saved = try DocumentWriter.saveFiles(pages, profile: profile, date: date, progress: progress)
            let files = saved.map(\.url)
            switch addToPhotos(saved, profile: profile, library: photoLibrary) {
            case let .failure(error):
                return SavedBatch(files: files, warning: "Couldn't save to Photos: \(error) Saved to \(folder) only.",
                                  place: folder, folder: folderURL)
            case let .success(unenhanced):
                return SavedBatch(files: files, warning: nil, place: "\(folder) and \(photosPlace(profile))",
                                  folder: folderURL, notice: enhancementNotice(unenhanced))
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
                return SavedBatch(files: files, warning: "\(reason) Saved to \(folder) instead.", place: folder,
                                  folder: folderURL)
            } catch {
                return SavedBatch(files: saved.map(\.url),
                                  warning: "\(reason) Couldn't save to \(folder) either (\(error.localizedDescription)). "
                                      + "The batch is in \(staging.path), which macOS empties after a few days.",
                                  place: staging.path, folder: staging)
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
        let folder = try DocumentWriter.openFolder(for: profile, date: date)
        var copied: [URL] = []
        func copy(_ source: URL, as name: DocumentWriter.FileName) throws -> (name: DocumentWriter.FileName, url: URL) {
            let result = try folder.write(name, format: profile.fileFormat) { output, _ in
                let input = try FileHandle(forReadingFrom: source)
                defer { try? input.close() }
                guard fcopyfile(input.fileDescriptor, output.fileDescriptor, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            copied.append(result.url)
            return result
        }
        do {
            return try files.map { file in
                let result = try copy(file.url, as: file.name)
                if let original = file.original {
                    _ = try copy(original, as: result.name.original)
                }
                return result.url
            }
        } catch {
            copied.forEach(folder.remove)
            throw error
        }
    }

    private static func photosPlace(_ profile: ScanProfile) -> String {
        profile.photosAlbum.isEmpty ? "Photos" : "the Photos album “\(profile.photosAlbum)”"
    }
}
