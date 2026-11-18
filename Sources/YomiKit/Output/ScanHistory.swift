import Foundation

struct SavedFileIdentity: Codable, Equatable {
    let device: dev_t
    let inode: ino_t
    let created: Int
    let nanoseconds: Int

    init(_ url: URL) throws {
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard attributes.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadUnsupportedScheme) }
        device = attributes.st_dev
        inode = attributes.st_ino
        created = attributes.st_birthtimespec.tv_sec
        nanoseconds = attributes.st_birthtimespec.tv_nsec
    }
}

package struct RecentFile: Codable, Identifiable {
    package let id: UUID
    var urls: [URL]
    let identities: [SavedFileIdentity?]
    let naming: PageNaming?
    var merchant: String?
    var ruleID: UUID?

    package var url: URL { urls[0] }

    init(url: URL, output: OCRDocumentOutput?) {
        id = UUID()
        urls = [url] + (output?.sidecars ?? [])
        identities = urls.map { try? SavedFileIdentity($0) }
        naming = output?.naming
        merchant = naming?.signature.merchant == nil ? nil : output?.pages.lazy.compactMap(\.merchant).first
        ruleID = naming?.matchedRule
    }

    func move(to stem: String, commit: ([URL]) throws -> Void) throws {
        let folder = url.deletingLastPathComponent()
        var moved: [(from: URL, to: URL, identity: SavedFileIdentity)] = []
        _ = try DocumentWriter.availableName(.init(stem: stem)) { candidate in
            let names = DocumentWriter.destinations(in: folder, name: candidate, extensions: urls.map(\.pathExtension))
            do {
                for (index, pair) in zip(urls, names).enumerated() {
                    let (from, to) = pair
                    guard let identity = identities[index], try SavedFileIdentity(from) == identity else {
                        throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "The saved file at \(from.path) has changed."])
                    }
                    if from == to { continue }
                    try Self.moveExclusively(from, to)
                    moved.append((from, to, identity))
                }
                try commit(names)
                return true
            } catch {
                var unrestored: [String] = []
                for file in moved.reversed() {
                    do {
                        guard try SavedFileIdentity(file.to) == file.identity else { throw CocoaError(.fileReadUnknown) }
                        try Self.moveExclusively(file.to, file.from)
                    } catch { unrestored.append(file.to.path) }
                }
                guard unrestored.isEmpty else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey:
                        "The rename stopped. Check these paths before trying again: \(unrestored.joined(separator: ", "))."])
                }
                moved.removeAll()
                if (error as? POSIXError)?.code == .EEXIST { return false }
                throw error
            }
        }
    }

    private static func moveExclusively(_ from: URL, _ to: URL) throws {
        guard renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func correction(from old: String, to stem: String, rules: [LearnedName], now: Date) -> LearnedName? {
        guard let signature = naming?.signature else { return nil }
        let id = ruleID.flatMap { id in rules.first { $0.id == id }?.id } ?? signature.closest(in: rules)?.id ?? UUID()
        if let merchant, let corrected = correctedMerchant(merchant, in: old, renamedTo: stem) {
            return LearnedName(id: id, signature: signature, matchedText: signature.merchant ?? merchant,
                               replacement: corrected, changesMerchant: true, edited: now, lastUsed: now)
        }
        return LearnedName(id: id, signature: signature, matchedText: old, replacement: stem,
                           changesMerchant: false, edited: now, lastUsed: now)
    }

    private func correctedMerchant(_ merchant: String, in old: String, renamedTo stem: String) -> String? {
        let previous = DocumentWriter.fileSafe(merchant)
        guard !previous.isEmpty else { return nil }
        let parts = naming?.merchantSeparators ?? old.components(separatedBy: previous)
        let occurrences = parts.count - 1
        guard occurrences > 0, naming?.merchantSeparators != nil || occurrences == 1 else { return nil }
        let rendered = parts.joined(separator: previous)
        guard old.hasPrefix(rendered) else { return nil }
        let suffix = old.dropFirst(rendered.count)
        let length = stem.count - parts.reduce(suffix.count) { $0 + $1.count }
        guard length > 0, length.isMultiple(of: occurrences) else { return nil }
        let candidate = String(stem.dropFirst(parts[0].count).prefix(length / occurrences))
        guard candidate != previous, parts.joined(separator: candidate) + suffix == stem else { return nil }
        return candidate
    }
}

package struct RecentBatch: Codable, Identifiable {
    package let id: UUID
    package let date: Date
    package let profileName: String
    package var files: [RecentFile]
}

package struct ScanHistory: Codable {
    package private(set) var batches: [RecentBatch] = []
    package private(set) var rules: [LearnedName] = []

    package static let supportFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Yomi", isDirectory: true)
    package static let location = supportFolder.appendingPathComponent("Scan History.json")

    package init() {}

    package static func load(from file: URL = location) throws -> Self {
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var attributes = stat()
            let fd = handle.fileDescriptor
            guard fstat(fd, &attributes) == 0, attributes.st_mode & 0o777 == 0o600 || fchmod(fd, 0o600) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return try JSONDecoder().decode(Self.self, from: handle.readToEnd() ?? Data())
        }
        catch CocoaError.fileReadNoSuchFile { return Self() }
    }

    static func savedRules() -> [LearnedName] { (try? load().rules) ?? [] }

    package func save(to file: URL = location) throws {
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = folder.appendingPathComponent(".Yomi-History-\(UUID())")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try handle.write(contentsOf: JSONEncoder().encode(self))
            try handle.close()
            guard Darwin.rename(temporary.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    @discardableResult
    package mutating func record(_ outcome: ScanOutcome, profileName: String, now: Date = .now) -> UUID? {
        guard !outcome.files.isEmpty else { return nil }
        let outputs = Dictionary(uniqueKeysWithValues: outcome.ocrOutputs.map { ($0.pdf, $0) })
        let files = outcome.files.map { RecentFile(url: $0, output: outputs[$0]) }
        let batch = RecentBatch(id: UUID(), date: now, profileName: profileName, files: files)
        batches.insert(batch, at: 0)
        batches = Array(batches.prefix(15))
        let used = Set(outcome.ocrOutputs.flatMap(\.usedRules))
        for index in rules.indices where used.contains(rules[index].id) { rules[index].lastUsed = now }
        return batch.id
    }

    package mutating func rename(_ id: UUID, to proposed: String, at location: URL = location) throws {
        guard let batch = batches.firstIndex(where: { $0.files.contains { $0.id == id } }),
              let index = batches[batch].files.firstIndex(where: { $0.id == id }) else { throw CocoaError(.fileNoSuchFile) }
        let file = batches[batch].files[index]
        let stem = DocumentWriter.fileSafe(proposed)
        guard !["", ".", ".."].contains(stem), !stem.utf8.contains(0) else { throw CocoaError(.fileWriteInvalidFileName) }
        let old = file.url.deletingPathExtension().lastPathComponent
        guard stem != old else { return }
        try file.move(to: stem) { urls in
            var next = self
            next.batches[batch].files[index].urls = urls
            if let rule = file.correction(from: old, to: stem, rules: rules, now: .now) {
                next.remember(rule)
                next.batches[batch].files[index].ruleID = rule.id
                next.batches[batch].files[index].merchant = rule.changesMerchant ? rule.replacement : nil
            }
            try next.save(to: location)
            self = next
        }
    }

    mutating func remember(_ rule: LearnedName) {
        rules.removeAll { $0.id == rule.id }
        rules.append(rule)
        if rules.count > 500, let oldest = rules.indices.min(by: { rules[$0].lastUsed < rules[$1].lastUsed }) {
            rules.remove(at: oldest)
        }
    }

    package mutating func deleteRules(_ ids: Set<UUID>, at location: URL = location) throws {
        var next = self
        next.rules.removeAll { ids.contains($0.id) }
        try next.save(to: location)
        self = next
    }
}
