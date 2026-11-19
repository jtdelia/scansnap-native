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
        if errno == EEXIST { throw RenameCollision.occupied }
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
    private func moveCase(_ originals: [RenameFile], to names: [URL], in folder: URL,
                          commit: ([URL], [SavedFileIdentity]) throws -> Void) throws -> Bool {
        let directory = open(folder.path, O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(directory) }
        guard fpathconf(directory, _PC_CASE_SENSITIVE) == 0 else { return names == urls }
        var volume = statfs()
        guard fstatfs(directory, &volume) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        let exfat = withUnsafeBytes(of: volume.f_fstypename) { $0.starts(with: "exfat\0".utf8) }
        var changes: [(from: String, to: String, identity: SavedFileIdentity)] = []
        let saved = try originals.map { try SavedFileIdentity(descriptor: $0.handle.fileDescriptor) }

        func attributes(_ name: String) throws -> stat {
            var value = stat()
            guard fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            return value
        }

        for (index, target) in names.enumerated() {
            let source = urls[index]
            let name = target.lastPathComponent
            guard source.deletingLastPathComponent() == folder,
                  source.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame else { return false }
            let identity = saved[index]
            let targetAttributes: stat
            do { targetAttributes = try attributes(name) }
            catch let error as POSIXError where error.code == .ENOENT { return false }
            guard (try? SavedFileIdentity(targetAttributes)) == identity else { return false }
            guard let spelling = try URL(filePath: source.path).resourceValues(forKeys: [.nameKey]).name,
                  spelling == (try URL(filePath: target.path).resourceValues(forKeys: [.nameKey]).name) else { return false }
            if spelling != name {
                guard !exfat || targetAttributes.st_size > 0 else {
                    throw RenameError("macOS changes the file ID of empty exFAT files such as \(source.path) when their case changes. Rename the scan to a different name first, then to the name you want.")
                }
                changes.append((spelling, name, identity))
            }
        }
        for original in originals { try original.verify() }
        if names != urls { try commit(names, saved) }
        do {
            for change in changes {
                guard try SavedFileIdentity(attributes(change.from)) == change.identity,
                      try SavedFileIdentity(attributes(change.to)) == change.identity else {
                    throw RenameError("The file at \(folder.appendingPathComponent(change.to).path) has changed.")
                }
                if renameatx_np(directory, change.from, directory, change.to, UInt32(RENAME_EXCL)) != 0 {
                    guard errno == ENOTSUP, exfat, renameat(directory, change.from, directory, change.to) == 0 else {
                        let reason = String(cString: strerror(errno))
                        throw RenameError("Couldn't rename \(folder.appendingPathComponent(change.from).path). \(reason)")
                    }
                }
            }
            let finished = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
            for (index, target) in names.enumerated() {
                try originals[index].verify()
                guard finished.contains(target.lastPathComponent), try SavedFileIdentity(target) == saved[index] else {
                    throw RenameError("Check the file at \(target.path).")
                }
            }
        } catch {
            throw RenameError("History has been saved. \(error.localizedDescription) Check the files in Finder before retrying the same name in Recent Scans.")
        }
        return true
    }

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
        let old = url.deletingPathExtension().lastPathComponent
        if stem.caseInsensitiveCompare(old) == .orderedSame {
            let names = stem == old ? urls : DocumentWriter.destinations(
                in: folder, name: .init(stem: stem), extensions: urls.map(\.pathExtension))
            if try moveCase(originals, to: names, in: folder, commit: commit) { return }
            if stem == old { throw RenameError("Couldn't verify the saved filenames in \(folder.path).") }
        }
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
                    do { try cleanup.discard(file, keeping: original) }
                    catch { failures.append(error.localizedDescription) }
                }
                if !failures.isEmpty {
                    throw RenameError(([error.localizedDescription] + failures).joined(separator: " "))
                }
                if error is RenameCollision { return false }
                throw error
            }
            do {
                for file in published { try file.verify() }
                for (original, file) in zip(originals, published) where original.url != file.url {
                    try cleanup.discard(original, keeping: file)
                }
            } catch {
                throw RenameError("History has been saved. Check the old and new files before retrying. \(error.localizedDescription)")
            }
            return true
        }
    }
}
