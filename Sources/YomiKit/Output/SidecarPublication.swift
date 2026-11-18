import Foundation

extension PDFReservation {
    func publishGroup(_ urls: [URL],
                      publish: (String, Int32, String, Int32, ((FileHandle) -> Void)?) -> Int32 = publishFile,
                      prepare: (Int, FileHandle) throws -> Void) throws -> Bool {
        try directory.verify()
        guard let markerDirectory else { throw POSIXError(.ESTALE) }
        let parent = directory.handle.fileDescriptor, staging = markerDirectory.fileDescriptor
        for url in urls {
            var entry = stat()
            if fstatat(parent, url.lastPathComponent, &entry, AT_SYMLINK_NOFOLLOW) == 0 { return false }
            guard errno == ENOENT else { throw Self.fileError() }
        }
        var temporary: [String] = []
        var published: [(String, FileHandle)] = []
        var cleanupFailures: [String] = []
        let result = Result {
            let prepared = try urls.indices.map { index in
                let name = "artifact-\(UUID())"
                let fd = openat(staging, name, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw Self.fileError() }
                temporary.append(name)
                let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                try prepare(index, file)
                try file.close()
                let held = openat(staging, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard held >= 0 else { throw Self.fileError() }
                return FileHandle(fileDescriptor: held, closeOnDealloc: true)
            }
            try directory.verify()
            for index in Array(urls.indices.dropFirst()) + [0] {
                let name = urls[index].lastPathComponent
                var copy: FileHandle?
                let code = publish(temporary[index], staging, name, parent) { copy = $0 }
                if let copy { published.append((name, copy)) }
                guard code == 0 else { throw POSIXError(.init(rawValue: code) ?? .EIO) }
                if copy == nil { published.append((name, prepared[index])) }
            }
            try directory.verify()
        }
        if case .failure = result {
            for (name, file) in published.reversed() {
                do { try withdraw(name, file: file, staging: staging) } catch { cleanupFailures.append("\(name): \(error)") }
            }
        }
        for name in temporary {
            if unlinkat(staging, name, 0) != 0, errno != ENOENT { cleanupFailures.append("\(name): \(Self.fileError())") }
        }
        if !cleanupFailures.isEmpty {
            let message = "Could not clean up \(stagingURL.path): \(cleanupFailures.joined(separator: ", "))."
            if case let .failure(cause) = result {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "\(cause.localizedDescription) \(message)"])
            }
            ScanLog.write("  \(message)")
        }
        if case let .failure(error) = result, (error as? POSIXError)?.code == .EEXIST { return false }
        try result.get()
        return true
    }

    private func withdraw(_ name: String, file: FileHandle, staging: Int32) throws {
        let parent = directory.handle.fileDescriptor
        var ours = stat(), entry = stat()
        guard fstat(file.fileDescriptor, &ours) == 0 else { throw Self.fileError() }
        if fstatat(parent, name, &entry, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw Self.fileError()
        }
        guard ours.st_dev == entry.st_dev, ours.st_ino == entry.st_ino else { return }
        let moved = "rollback-\(UUID())"
        guard renameat(parent, name, staging, moved) == 0 else {
            if errno == ENOENT { return }
            throw Self.fileError()
        }
        let held = stagingURL.appendingPathComponent(moved)
        guard fstatat(staging, moved, &entry, AT_SYMLINK_NOFOLLOW) == 0 else { throw ScanFolder.FolderError(held, errno) }
        if ours.st_dev == entry.st_dev, ours.st_ino == entry.st_ino {
            guard unlinkat(staging, moved, 0) == 0 else { throw ScanFolder.FolderError(held, errno) }
        } else {
            guard renameatx_np(staging, moved, parent, name, UInt32(RENAME_EXCL)) == 0 else { throw ScanFolder.FolderError(held, errno) }
        }
    }

    private static func fileError() -> POSIXError { POSIXError(.init(rawValue: errno) ?? .EIO) }
}
