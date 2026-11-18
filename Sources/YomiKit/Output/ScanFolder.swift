import CoreGraphics
import Foundation
import System

struct ScanFolder {
    private let url: URL
    private let directory: FileHandle

    init(root: URL, subfolders: [String]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let flags = O_SEARCH | O_CLOEXEC
        let rootFD = open(root.path, flags)
        guard rootFD >= 0 else { throw FolderError(root, errno) }
        var parent = FileHandle(fileDescriptor: rootFD, closeOnDealloc: true)
        var folder = root
        for level in subfolders {
            folder.appendPathComponent(level, isDirectory: true)
            var fd = openat(parent.fileDescriptor, level, flags | O_NOFOLLOW)
            if fd < 0, errno == ENOENT {
                guard mkdirat(parent.fileDescriptor, level, 0o777) == 0 || errno == EEXIST else {
                    throw FolderError(folder, errno)
                }
                fd = openat(parent.fileDescriptor, level, flags | O_NOFOLLOW)
            }
            guard fd >= 0 else { throw FolderError(folder, errno) }
            parent = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        url = folder
        directory = parent
    }

    func write(_ name: DocumentWriter.FileName, format: ScanProfile.FileFormat,
               _ body: (FileHandle, URL) throws -> Void) throws -> (name: DocumentWriter.FileName, url: URL) {
        let temporary = ".Yomi-\(UUID()).tmp"
        let parent = directory.fileDescriptor
        let requested = url.appendingPathComponent(DocumentWriter.fileName(name, format: format))
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard fd >= 0 else { throw FolderError(requested, errno) }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try body(handle, requested)
            try handle.close()
            var candidate = name
            var counter = 2
            while true {
                let filename = DocumentWriter.fileName(candidate, format: format)
                let file = url.appendingPathComponent(filename)
                if renameatx_np(parent, temporary, parent, filename, UInt32(RENAME_EXCL)) == 0 {
                    return (candidate, file)
                }
                guard errno == EEXIST else { throw FolderError(file, errno) }
                candidate.suffix = "\(name.suffix) (\(counter))"
                counter += 1
            }
        } catch {
            unlinkat(parent, temporary, 0)
            throw error
        }
    }

    func remove(_ file: URL) {
        unlinkat(directory.fileDescriptor, file.lastPathComponent, 0)
    }

    private struct FolderError: LocalizedError, CustomStringConvertible {
        let description: String
        var errorDescription: String? { description }

        init(_ url: URL, _ code: Int32) {
            let reason = code == ENOTDIR || code == ELOOP
                ? "Use a folder here. Generated subfolders cannot be symbolic links."
                : Errno(rawValue: code).description
            description = "Couldn't save to \(url.path). \(reason)"
        }
    }
}

private final class ScanFileConsumer {
    let handle: FileHandle
    var error: Error?

    init(_ handle: FileHandle) { self.handle = handle }

    func write(_ bytes: UnsafeRawBufferPointer) -> Int {
        guard error == nil else { return 0 }
        do {
            try handle.write(contentsOf: bytes)
            return bytes.count
        } catch {
            self.error = error
            return 0
        }
    }
}

func withScanFileConsumer(_ handle: FileHandle, url: URL, _ write: (CGDataConsumer) throws -> Void) throws {
    let output = ScanFileConsumer(handle)
    let info = Unmanaged.passRetained(output).toOpaque()
    var callbacks = CGDataConsumerCallbacks(putBytes: { info, buffer, count in
        Unmanaged<ScanFileConsumer>.fromOpaque(info!).takeUnretainedValue()
            .write(UnsafeRawBufferPointer(start: buffer, count: count))
    }, releaseConsumer: { info in
        Unmanaged<ScanFileConsumer>.fromOpaque(info!).release()
    })
    let result = Result {
        guard let consumer = CGDataConsumer(info: info, cbks: &callbacks) else {
            Unmanaged<ScanFileConsumer>.fromOpaque(info).release()
            throw ImageWriterError.cannotWrite(url)
        }
        try write(consumer)
    }
    if let error = output.error { throw error }
    try result.get()
}
