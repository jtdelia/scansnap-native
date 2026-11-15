import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import YomiKit

/// Apple Photos through PhotoKit. Finding and creating albums needs full library access, not add-only.
struct PhotoKitLibrary: PhotoLibrary {
    private final class StatusBox: @unchecked Sendable {
        var status = PHAuthorizationStatus.notDetermined
    }

    func add(_ photos: [PhotoImport], album: String) throws {
        guard Self.requestAccess() else { throw PhotoLibraryError.accessDenied }
        let library = PHPhotoLibrary.shared()
        var collection: PHAssetCollection?
        if !album.isEmpty {
            collection = Self.album(named: album)
            if collection == nil {
                var identifier: String?
                do {
                    try library.performChangesAndWait {
                        identifier = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: album)
                            .placeholderForCreatedAssetCollection.localIdentifier
                    }
                } catch {
                    throw Self.libraryError(error, otherwise: .albumNotCreated(album))
                }
                collection = identifier.flatMap {
                    PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [$0], options: nil).firstObject
                }
                guard collection != nil else { throw PhotoLibraryError.albumNotCreated(album) }
            }
        }
        let editError = ErrorBox()
        do {
            try library.performChangesAndWait {
                let assets = photos.compactMap { photo -> PHObjectPlaceholder? in
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = photo.name
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, fileURL: photo.original, options: options)
                    guard let placeholder = request.placeholderForCreatedAsset else { return nil }
                    if let edited = photo.edited {
                        do {
                            request.contentEditingOutput = try Self.enhancement(edited, for: placeholder)
                        } catch {
                            editError.error = error
                        }
                    }
                    return placeholder
                }
                if let collection, let change = PHAssetCollectionChangeRequest(for: collection) {
                    change.addAssets(assets as NSArray)
                }
            }
        } catch {
            throw Self.libraryError(error, otherwise: .failed("Photos couldn't add the photos (\(error.localizedDescription))."))
        }
        if let error = editError.error {
            throw PhotoLibraryError.failed("Photos added the photos without auto-enhance (\(error.localizedDescription)).")
        }
    }

    private final class ErrorBox: @unchecked Sendable {
        var error: Error?
    }

    /// Identifies Yomi's edits in Photos, which shows them as adjustments that Revert to Original removes.
    private static let adjustmentFormat = "io.github.jtdelia.Yomi.auto-enhance"

    /// A Photos edit for a newly created asset whose rendered image is the file at `edited`.
    private static func enhancement(_ edited: URL, for placeholder: PHObjectPlaceholder) throws -> PHContentEditingOutput {
        let output = PHContentEditingOutput(placeholderForCreatedAsset: placeholder)
        output.adjustmentData = PHAdjustmentData(formatIdentifier: adjustmentFormat, formatVersion: "1",
                                                 data: Data("CIImage.autoAdjustmentFilters".utf8))
        let type = UTType(filenameExtension: edited.pathExtension)
        if let type, output.supportedRenderedContentTypes.contains(type) {
            try FileManager.default.copyItem(at: edited, to: output.renderedContentURL(for: type))
            return output
        }
        guard let rendered = output.defaultRenderedContentType,
              let source = CGImageSourceCreateWithURL(edited as CFURL, nil),
              let destination = CGImageDestinationCreateWithURL(try output.renderedContentURL(for: rendered) as CFURL,
                                                                rendered.identifier as CFString, 1, nil)
        else { throw PhotoLibraryError.failed("Photos can't store the enhanced photo.") }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoLibraryError.failed("Photos can't store the enhanced photo.")
        }
        return output
    }

    /// Names of the user's albums, or none until Yomi has full access to Photos.
    static func albumNames() -> [String] {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return [] }
        var names: [String] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { collection, _, _ in
                if let title = collection.localizedTitle { names.append(title) }
            }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Asks for full access if Yomi hasn't asked yet, then lists the albums.
    static func requestAccessAndListAlbums() async -> [String] {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return albumNames()
    }

    /// Asks for full access the first time and waits for the answer.
    static func requestAccess() -> Bool {
        let box = StatusBox()
        box.status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if box.status == .notDetermined {
            let answered = DispatchSemaphore(value: 0)
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                box.status = status
                answered.signal()
            }
            answered.wait()
        }
        return box.status == .authorized
    }

    private static func album(named name: String) -> PHAssetCollection? {
        var match: PHAssetCollection?
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { collection, _, stop in
                if collection.localizedTitle == name {
                    match = collection
                    stop.pointee = true
                }
            }
        return match
    }

    private static func libraryError(_ error: Error, otherwise fallback: PhotoLibraryError) -> PhotoLibraryError {
        if let error = error as? PHPhotosError, [.accessUserDenied, .accessRestricted].contains(error.code) {
            return .accessDenied
        }
        return fallback
    }
}
