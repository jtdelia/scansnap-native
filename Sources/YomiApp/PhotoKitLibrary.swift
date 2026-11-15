import Foundation
import Photos
import YomiKit

/// Apple Photos through PhotoKit. Finding and creating albums needs full library access, not add-only.
struct PhotoKitLibrary: PhotoLibrary {
    private final class StatusBox: @unchecked Sendable {
        var status = PHAuthorizationStatus.notDetermined
    }

    func add(_ files: [URL], album: String) throws {
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
        do {
            try library.performChangesAndWait {
                let assets = files.compactMap { file in
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = file.lastPathComponent
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, fileURL: file, options: options)
                    return request.placeholderForCreatedAsset
                }
                if let collection, let change = PHAssetCollectionChangeRequest(for: collection) {
                    change.addAssets(assets as NSArray)
                }
            }
        } catch {
            throw Self.libraryError(error, otherwise: .failed("Photos couldn't add the photos (\(error.localizedDescription))."))
        }
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
