import Foundation

private struct RenameError: LocalizedError {
    let message: String
    var errorDescription: String? { message }

    init(_ message: String) { self.message = message }
}

private enum RenameCollision: Error { case occupied }

private struct RenameFile {
    let url: URL
    let handle: FileHandle
    var changedCase = false

    func verify() throws {
        guard let entry = try? SavedFileIdentity(url), entry == (try SavedFileIdentity(descriptor: handle.fileDescriptor)) else {
            throw RenameError("The file at \(url.path) has changed.")
        }
    }

    func publish(at destination: URL) throws -> Self {
        if link(url.path, destination.path) == 0 {
            let linked = Self(url: destination, handle: handle)
            try linked.verify()
            return linked
        }
        if errno == EEXIST {
            if url.lastPathComponent.caseInsensitiveCompare(destination.lastPathComponent) == .orderedSame,
               (try? SavedFileIdentity(destination)) == (try SavedFileIdentity(descriptor: handle.fileDescriptor)) {
                if renamex_np(url.path, destination.path, UInt32(RENAME_EXCL)) == 0 {
                    return Self(url: destination, handle: handle, changedCase: true)
                }
                guard errno == EEXIST || errno == ENOTSUP else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            }
            throw RenameCollision.occupied
        }
        guard errno == ENOTSUP else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var copy: FileHandle?
        var created = false
        let code = writeExclusiveCopy(as: destination.path, in: AT_FDCWD) { output in
            created = true
            guard lseek(handle.fileDescriptor, 0, SEEK_SET) >= 0,
                  fcopyfile(handle.fileDescriptor, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0,
                  fsync(output) == 0 else { return errno }
            let fd = fcntl(output, F_DUPFD_CLOEXEC, 0)
            guard fd >= 0 else { return errno }
            copy = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            return 0
        }
        if code == EEXIST, !created { throw RenameCollision.occupied }
        guard code == 0, let copy else {
            let reason = POSIXError(.init(rawValue: code) ?? .EIO).localizedDescription
            throw RenameError("Couldn't finish \(destination.path). An incomplete copy may remain there. \(reason)")
        }
        let copied = Self(url: destination, handle: copy)
        try copied.verify()
        return copied
    }

    func restoreCase(at original: URL) throws {
        try verify()
        guard renamex_np(url.path, original.path, UInt32(RENAME_EXCL)) == 0 else {
            throw RenameError("Couldn't restore \(original.path). Check \(url.path).")
        }
    }
}

private struct RenameCleanup {
    let folder: URL
    let directory: Int32

    init(in parent: URL) throws {
        folder = parent.appendingPathComponent(".Yomi-rename-\(UUID())", isDirectory: true)
        guard mkdir(folder.path, 0o700) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        directory = open(folder.path, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    func discard(_ file: RenameFile, keeping other: RenameFile) throws {
        do { try other.verify() } catch {
            throw RenameError("\(error.localizedDescription) The copy at \(file.url.path) remains.")
        }
        try file.verify()
        let name = "\(UUID()).\(file.url.pathExtension)"
        let held = folder.appendingPathComponent(name)
        if renameatx_np(AT_FDCWD, file.url.path, directory, name, UInt32(RENAME_EXCL)) != 0 {
            guard errno == ENOTSUP, renameat(AT_FDCWD, file.url.path, directory, name) == 0 else {
                let reason = String(cString: strerror(errno))
                throw RenameError("Couldn't remove \(file.url.path). \(reason)")
            }
        }
        var attributes = stat()
        guard fstatat(directory, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0,
              let captured = try? SavedFileIdentity(attributes),
              captured == (try? SavedFileIdentity(descriptor: file.handle.fileDescriptor)),
              (try? other.verify()) != nil else {
            throw RenameError("The files changed during cleanup. Check \(other.url.path). Recover \(file.url.lastPathComponent) at \(held.path).")
        }
        guard unlinkat(directory, name, 0) == 0 else { throw RenameError("A copy remains at \(held.path).") }
    }
}

extension RecentFile {
    func move(to stem: String, commit: ([URL], [SavedFileIdentity]) throws -> Void) throws {
        guard urls.count == identities.count else { throw CocoaError(.fileReadCorruptFile) }
        let originals = try zip(urls, identities).map { url, identity in
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            guard try SavedFileIdentity(descriptor: fd) == identity else {
                throw RenameError("The saved file at \(url.path) has changed.")
            }
            return RenameFile(url: url, handle: handle)
        }
        let folder = url.deletingLastPathComponent()
        let cleanup = try RenameCleanup(in: folder)
        defer {
            rmdir(cleanup.folder.path)
            close(cleanup.directory)
        }
        _ = try DocumentWriter.availableName(.init(stem: stem)) { candidate in
            let names = DocumentWriter.destinations(in: folder, name: candidate, extensions: urls.map(\.pathExtension))
            var published: [RenameFile] = []
            do {
                for (original, name) in zip(originals, names) {
                    let file = original.url == name ? original : try original.publish(at: name)
                    published.append(file)
                }
                for original in originals { try original.verify() }
                for file in published { try file.verify() }
                try commit(names, published.map { try SavedFileIdentity(descriptor: $0.handle.fileDescriptor) })
            } catch {
                var failures: [String] = []
                for (original, file) in zip(originals, published).reversed() where original.url != file.url {
                    do {
                        if file.changedCase { try file.restoreCase(at: original.url) }
                        else { try cleanup.discard(file, keeping: original) }
                    } catch { failures.append(error.localizedDescription) }
                }
                if !failures.isEmpty {
                    throw RenameError(([error.localizedDescription] + failures).joined(separator: " "))
                }
                if error is RenameCollision { return false }
                throw error
            }
            do {
                for file in published { try file.verify() }
                for (original, file) in zip(originals, published) where original.url != file.url && !file.changedCase {
                    try cleanup.discard(original, keeping: file)
                }
            } catch {
                throw RenameError("History has been saved. Check the old and new files before retrying. \(error.localizedDescription)")
            }
            return true
        }
    }
}
