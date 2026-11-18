import Darwin
import Foundation
import Testing
@testable import YomiKit

struct RecentFileRenameTests {
    let folder = (ProcessInfo.processInfo.environment["YOMI_TEST_VOLUME"].map { URL(filePath: $0) }
        ?? FileManager.default.temporaryDirectory).appendingPathComponent("YomiRename-\(UUID())")
    let historyFolder = FileManager.default.temporaryDirectory.appendingPathComponent("YomiHistory-\(UUID())")
    var location: URL { historyFolder.appendingPathComponent("History.json") }
    let extensions = ["pdf", "csv", "json"]
    let contents = [Data("scan".utf8), Data("csv".utf8), Data("json".utf8)]

    private func urls(_ stem: String) -> [URL] {
        extensions.map { folder.appendingPathComponent("\(stem).\($0)") }
    }

    private func record(_ data: [Data]) throws -> ScanHistory {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let files = urls("Original")
        for (bytes, url) in zip(data, files) { try bytes.write(to: url) }
        let output = OCRDocumentOutput(pdf: files[0], sidecars: Array(files.dropFirst()), pages: [])
        var history = ScanHistory()
        history.record(.init(files: [output.pdf], ocrOutputs: [output], sheets: 1, pages: 1, blankPagesSkipped: 0), profileName: "Scan")
        try history.save(to: location)
        return history
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: historyFolder)
    }

    @Test(arguments: [false, true])
    func renamesGroupAndRenamesItAgainFromDisk(sidecarClash: Bool) throws {
        defer { cleanUp() }
        var history = try record(contents)
        let original = history.batches[0].files[0]
        let competing = urls("First")[2]
        if sidecarClash { try Data("other".utf8).write(to: competing) }
        try history.rename(original.id, to: "First", at: location)

        var reloaded = try ScanHistory.load(from: location)
        let first = reloaded.batches[0].files[0]
        #expect(first.urls == urls(sidecarClash ? "First (2)" : "First"))
        #expect(try first.urls.map { try Data(contentsOf: $0) } == contents)
        #expect(try first.identities == first.urls.map(SavedFileIdentity.init))
        let hardLinks = try folder.resourceValues(forKeys: [.volumeSupportsHardLinksKey]).volumeSupportsHardLinks
        #expect((first.identities == original.identities) == (hardLinks == true))
        #expect(original.urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        if sidecarClash {
            #expect(try Data(contentsOf: competing) == Data("other".utf8))
            #expect(urls("First").dropLast().allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        }
        try reloaded.rename(first.id, to: "Second", at: location)
        let second = try ScanHistory.load(from: location).batches[0].files[0]
        #expect(second.urls == urls("Second"))
        #expect(try second.urls.map { try Data(contentsOf: $0) } == contents)
        #expect(first.urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test(arguments: [false, true])
    func keepsOriginalsAndCompetingDestinationIfHistoryFails(replaceDestination: Bool) throws {
        defer { cleanUp() }
        let history = try record(contents)
        let original = history.batches[0].files[0]
        let destination = urls("New")[0]
        let other = Data("another scan".utf8)
        var called = false
        #expect(throws: (any Error).self) {
            try original.move(to: "New") { names, _ in
                called = true
                #expect(try original.urls.map { try Data(contentsOf: $0) } == contents)
                #expect(try names.map { try Data(contentsOf: $0) } == contents)
                if replaceDestination { try other.write(to: destination, options: .atomic) }
                throw POSIXError(.EACCES)
            }
        }
        #expect(called)
        #expect(try original.urls.map { try Data(contentsOf: $0) } == contents)
        #expect(try ScanHistory.load(from: location).batches[0].files[0].urls == original.urls)
        if replaceDestination { #expect(try Data(contentsOf: destination) == other) }
        else { #expect(FileManager.default.fileExists(atPath: destination.path) == false) }
        #expect(urls("New").dropFirst().allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test(arguments: [false, true])
    func preservesCompetingReplacementDuringCommit(replaceOriginal: Bool) throws {
        defer { cleanUp() }
        let original = try record(contents).batches[0].files[0]
        let replaced = urls(replaceOriginal ? "Original" : "New")[0]
        let other = Data("another scan".utf8)
        var committed = false
        #expect(throws: (any Error).self) {
            try original.move(to: "New") { _, _ in
                try other.write(to: replaced, options: .atomic)
                committed = true
            }
        }
        #expect(committed)
        #expect(try Data(contentsOf: replaced) == other)
        #expect(try urls(replaceOriginal ? "New" : "Original").map { try Data(contentsOf: $0) } == contents)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YOMI_TEST_FULL_EXFAT"] == "1"))
    func diskFullOnLaterMemberKeepsOriginalsAndHistory() throws {
        defer { cleanUp() }
        let volumeURL = folder.deletingLastPathComponent()
        var attributes = statfs()
        try #require(statfs(volumeURL.path, &attributes) == 0)
        let format = withUnsafeBytes(of: attributes.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        try #require(format == "exfat")
        let volume = try volumeURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        try #require((volume.volumeTotalCapacity ?? .max) < 128 * 1024 * 1024)
        let free = try #require(volume.volumeAvailableCapacity)
        let bytes = [contents[0], Data(repeating: 0x31, count: free * 2 / 3), contents[2]]
        var history = try record(bytes)
        let original = history.batches[0].files[0]
        let before = try Data(contentsOf: location)
        let incomplete = urls("Full")[1]
        do {
            try history.rename(original.id, to: "Full", at: location)
            Issue.record("Expected the CSV copy to run out of disk space")
        } catch {
            #expect(error.localizedDescription.contains(incomplete.path))
            #expect(error.localizedDescription.contains(POSIXError(.ENOSPC).localizedDescription))
        }
        #expect(try original.urls.map { try Data(contentsOf: $0) } == bytes)
        #expect(history.batches[0].files[0].urls == original.urls)
        #expect(try Data(contentsOf: location) == before)
        #expect(FileManager.default.fileExists(atPath: incomplete.path))
        #expect(FileManager.default.fileExists(atPath: urls("Full")[0].path) == false)
        #expect(FileManager.default.fileExists(atPath: urls("Full")[2].path) == false)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["YOMI_TEST_VOLUME"] == nil), arguments: [false, true])
    func preservesLetterCaseEditsOnAPFS(failHistory: Bool) throws {
        defer { cleanUp() }
        var history = try record(contents)
        let original = history.batches[0].files[0]
        if failHistory {
            #expect(throws: (any Error).self) {
                try history.rename(original.id, to: "ORIGINAL", at: location.appendingPathComponent("History"))
            }
        } else {
            try history.rename(original.id, to: "ORIGINAL", at: location)
        }
        let file = try ScanHistory.load(from: location).batches[0].files[0]
        #expect(file.urls == urls(failHistory ? "Original" : "ORIGINAL"))
        #expect(file.identities == original.identities)
        let entries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(Set(entries) == Set(file.urls.map(\.lastPathComponent)))
    }
}
