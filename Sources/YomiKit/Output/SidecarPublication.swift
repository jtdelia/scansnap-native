import Foundation

extension PDFReservation {
    func publishGroup(_ urls: [URL], pdf: URL,
                      publish: (String, Int32, String, Int32, ((FileHandle) -> Void)?) -> Int32 = publishFile,
                      writeSidecar: (Int, FileHandle) throws -> Void) throws -> Bool {
        try directory.verify()
        guard let markerDirectory else { throw POSIXError(.ESTALE) }
        let parent = directory.handle.fileDescriptor, staging = markerDirectory.fileDescriptor
        func namesAvailable() throws -> Bool {
            for url in urls {
                var entry = stat()
                if fstatat(parent, url.lastPathComponent, &entry, AT_SYMLINK_NOFOLLOW) == 0 { return false }
                guard errno == ENOENT else { throw ScanFolder.FolderError(url, errno) }
            }
            return true
        }
        guard try namesAvailable() else { return false }
        var temporary: [String] = []
        var published: [(name: String, file: FileHandle)] = []
        let result = Result {
            let prepared = try urls.indices.map { index in
                let name = "artifact-\(UUID())"
                let fd = openat(staging, name, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw Self.fileError() }
                temporary.append(name)
                let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                if index == 0 {
                    let input = try FileHandle(forReadingFrom: pdf)
                    try input.copyPDF(to: fd)
                } else {
                    try writeSidecar(index - 1, file)
                }
                try file.close()
                let held = openat(staging, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard held >= 0 else { throw Self.fileError() }
                return FileHandle(fileDescriptor: held, closeOnDealloc: true)
            }
            try directory.verify()
            guard try namesAvailable() else { return false }
            for index in Array(urls.indices.dropFirst()) + [0] {
                let name = urls[index].lastPathComponent
                var copy: FileHandle?
                let code = publish(temporary[index], staging, name, parent) { copy = $0 }
                guard code == 0 else {
                    if let copy { published.append((name, copy)) }
                    if code == EEXIST, published.isEmpty { return false }
                    throw ScanFolder.FolderError(urls[index], code)
                }
                published.append((name, copy ?? prepared[index]))
            }
            try directory.verify()
            for (name, file) in published {
                guard try directory.contains(file, named: name) else {
                    let path = directory.url.appendingPathComponent(name).path
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "The file at \(path) moved or changed during export."])
                }
            }
            return true
        }
        var cleanupFailures: [String] = []
        for name in temporary {
            if unlinkat(staging, name, 0) != 0, errno != ENOENT { cleanupFailures.append("\(name): \(Self.fileError())") }
        }
        var details: [String] = []
        if case .failure = result, !published.isEmpty {
            let folder = directory.currentURL
            let paths = published.map { folder.appendingPathComponent($0.name).path }.joined(separator: "\n")
            details.append("The prepared PDF is at \(pdf.path).\nCheck these files before exporting again.\n\(paths)")
        }
        if !cleanupFailures.isEmpty {
            details.append("Could not clean up \(stagingURL.path): \(cleanupFailures.joined(separator: ", ")).")
        }
        guard !details.isEmpty else { return try result.get() }
        if case .success(true) = result {
            ScanLog.write("  \(details.joined(separator: "\n"))")
            return true
        }
        if case let .failure(error) = result {
            let prefix = published.isEmpty ? "" : "Partial export. "
            details.insert(prefix + error.localizedDescription, at: 0)
        }
        throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: details.joined(separator: "\n")])
    }

    private static func fileError() -> POSIXError { POSIXError(.init(rawValue: errno) ?? .EIO) }
}
