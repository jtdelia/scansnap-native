import CoreGraphics
import CryptoKit
import Foundation

final class PDFDirectory {
    private let folder: ScanFolder
    private let identity: stat

    var url: URL { folder.url }
    fileprivate var handle: FileHandle { folder.directory }

    init(_ folder: ScanFolder) throws {
        self.folder = folder
        var info = stat()
        guard fstat(folder.directory.fileDescriptor, &info) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        identity = info
    }

    fileprivate func contains(_ child: FileHandle, named name: String) throws -> Bool {
        var held = stat()
        var entry = stat()
        guard fstat(child.fileDescriptor, &held) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard fstatat(handle.fileDescriptor, name, &entry, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return entry.st_dev == held.st_dev && entry.st_ino == held.st_ino
    }

    fileprivate func verify() throws {
        var current = stat()
        guard let reopened = try? folder.reopen(),
              withExtendedLifetime(reopened, { fstat(reopened.fileDescriptor, &current) }) == 0,
              current.st_dev == identity.st_dev, current.st_ino == identity.st_ino else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ESTALE), userInfo: [
                NSLocalizedDescriptionKey: "The scan folder at \(url.path) moved or changed.",
            ])
        }
    }
}

final class PDFReservation {
    let name: DocumentWriter.FileName
    let output: URL
    private let directory: PDFDirectory
    private var markerDirectory: FileHandle?

    private init(name: DocumentWriter.FileName, output: URL, directory: PDFDirectory, staging: FileHandle) {
        self.name = name
        self.output = output
        self.directory = directory
        markerDirectory = staging
    }

    static func claim(_ name: DocumentWriter.FileName, in directory: PDFDirectory) throws -> PDFReservation? {
        try directory.verify()
        let filename = DocumentWriter.fileName(name, format: .pdf)
        guard !filename.utf8.contains(0) else { throw POSIXError(.EINVAL) }
        let output = directory.url.appendingPathComponent(filename)
        let folded = filename.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        let digest = SHA256.hash(data: Data(folded.decomposedStringWithCanonicalMapping.utf8))
        let key = digest.map { String(format: "%02x", $0) }.joined()
        let marker = ".Yomi-PDF-\(key)"
        guard let staging = try lockMarker(marker, in: directory) else { return nil }
        var entry = stat()
        if fstatat(directory.handle.fileDescriptor, filename, &entry, AT_SYMLINK_NOFOLLOW) == 0 { return nil }
        guard errno == ENOENT else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return PDFReservation(name: name, output: output, directory: directory, staging: staging)
    }

    private static func lockMarker(_ marker: String, in directory: PDFDirectory) throws -> FileHandle? {
        let parent = directory.handle.fileDescriptor
        while true {
            if mkdirat(parent, marker, 0o700) != 0 {
                guard errno == EEXIST else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                if faccessat(parent, marker, W_OK | X_OK, AT_SYMLINK_NOFOLLOW) != 0, errno == EACCES { return nil }
            }
            let fd = openat(parent, marker, O_SEARCH | O_EXLOCK | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            if fd < 0 {
                switch errno {
                case ENOENT: continue
                case EWOULDBLOCK, ELOOP, ENOTDIR: return nil
                default: throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
            }
            let staging = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            if try directory.contains(staging, named: marker) { return staging }
        }
    }

    func release() {
        markerDirectory = nil
    }

    func publish(_ source: URL, pages: Int) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        _ = try publish(pages: pages) { try input.copyPDF(to: $0.fileDescriptor) }
    }

    func publish(pages: Int, retrying baseName: DocumentWriter.FileName? = nil,
                 prepare: (FileHandle) throws -> Void) throws -> PDFReservation {
        try directory.verify()
        guard let markerDirectory else { throw POSIXError(.ESTALE) }
        let staging = markerDirectory.fileDescriptor
        let fd = directory.handle.fileDescriptor
        let temporary = "document-\(UUID()).pdf"
        let descriptor = openat(staging, temporary, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o666)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var published = false
        defer { if !published { unlinkat(markerDirectory.fileDescriptor, temporary, 0) } }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try prepare(file)
        guard CGPDFDocument(file.pdfURL as CFURL)?.numberOfPages == pages else { throw ImageWriterError.cannotWrite(output) }
        try file.close()
        var claim = self
        while true {
            try directory.verify()
            let code = publishFile(temporary, from: staging, as: claim.output.lastPathComponent, in: fd)
            if code == 0 {
                published = true
                try directory.verify()
                return claim
            }
            guard code == EEXIST, let baseName else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: claim.output.path])
            }
            claim = try DocumentWriter.reservePDF(in: directory, baseName)
        }
    }
}

extension FileHandle {
    var pdfURL: URL { URL(fileURLWithPath: "/dev/fd/\(fileDescriptor)") }

    fileprivate func copyPDF(to descriptor: Int32) throws {
        try seek(toOffset: 0)
        guard fcopyfile(fileDescriptor, descriptor, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_STAT)) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }

    func recoverPDF(to url: URL) {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        do { try copyPDF(to: descriptor) } catch { unlink(url.path) }
    }
}
