import Foundation
import ImageIO

package struct FieldWorker {
    let executable: URL
    var timeout: Duration = .seconds(30)

    struct Request: Codable {
        let kind: PageKind
        let transcript: String
        let examples: String
    }

    func predict(_ page: RecognizedPage, imageURL: URL, in folder: URL, examples: String = "") async throws -> PageFields? {
        guard page.kind != .print, !page.transcript.isEmpty else { return nil }
        let input = folder.appendingPathComponent("field-request.json")
        let output = folder.appendingPathComponent("field-response.json")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        try JSONEncoder().encode(Request(kind: page.kind, transcript: page.transcript, examples: examples)).write(to: input)
        let arguments = [executable.path, "--predict", input.path, imageURL.path, output.path].map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        var pid: pid_t = 0
        try Task.checkCancellation()
        let error = posix_spawn(&pid, executable.path, nil, nil, arguments, environ)
        guard error == 0 else { throw POSIXError(.init(rawValue: error) ?? .EIO) }
        var status: Int32 = 0
        let deadline = ContinuousClock.now + timeout
        do {
            while true {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { break }
                if result == -1, errno != EINTR { throw POSIXError(.init(rawValue: errno) ?? .ECHILD) }
                guard ContinuousClock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            if (error as? POSIXError)?.code != .ECHILD {
                kill(pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            }
            throw error
        }
        guard status == 0 else { throw POSIXError(.ECANCELED) }
        return try JSONDecoder().decode(PageFields?.self, from: Data(contentsOf: output))
    }

    package static func respond(input: URL, imageURL: URL, output: URL) async throws {
        let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: input))
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ImageWriterError.cannotCreateImage }
        let page = RecognizedPage(kind: request.kind, language: .automatic, documents: [], transcript: request.transcript, detectedData: [])
        let fields = try await PageFields.predict(page, image: image, examples: request.examples)
        try JSONEncoder().encode(fields).write(to: output, options: .atomic)
    }
}
