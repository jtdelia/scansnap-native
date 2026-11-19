import Darwin
import Foundation
import Testing
@testable import YomiKit

private let renameVolume = ProcessInfo.processInfo.environment["YOMI_TEST_VOLUME"].map { URL(filePath: $0) }
    ?? FileManager.default.temporaryDirectory
private let caseSensitive = pathconf(renameVolume.path, _PC_CASE_SENSITIVE) == 1

struct RecentFileRenameTests {
    let folder = renameVolume.appendingPathComponent("YomiRename-\(UUID())")
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

    private func scanNames() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { !$0.hasPrefix(".") })
    }

    @Test(arguments: [false, true])
    func savesExactLetterCaseWithTheOriginalIdentities(failHistory: Bool) throws {
        defer { cleanUp() }
        var history = try record(contents)
        try history.rename(history.batches[0].files[0].id, to: "First", at: location)
        let original = history.batches[0].files[0]
        let before = try Data(contentsOf: location)
        if failHistory {
            #expect(throws: (any Error).self) {
                try history.rename(original.id, to: "FIRST", at: location.appendingPathComponent("History"))
            }
            #expect(try Data(contentsOf: location) == before)
        } else {
            try history.rename(original.id, to: "FIRST", at: location)
        }
        let file = try ScanHistory.load(from: location).batches[0].files[0]
        #expect(file.urls == urls(failHistory ? "First" : "FIRST"))
        #expect(file.identities == original.identities)
        #expect(try file.urls.map(SavedFileIdentity.init) == file.identities)
        #expect(try file.urls.map { try Data(contentsOf: $0) } == contents)
        #expect(try scanNames() == Set(file.urls.map(\.lastPathComponent)))
    }

    @Test(.enabled(if: !caseSensitive))
    func keepsOriginalDirectoryEntriesAtTheCaseRenameCommit() throws {
        defer { cleanUp() }
        let original = try record(contents).batches[0].files[0]
        var called = false
        #expect(throws: POSIXError(.EACCES)) {
            try original.move(to: "ORIGINAL") { names, identities in
                called = true
                #expect(try scanNames() == Set(original.urls.map(\.lastPathComponent)))
                #expect(names == urls("ORIGINAL"))
                #expect(try names.map(SavedFileIdentity.init) == identities)
                #expect(identities == original.identities)
                #expect(try names.map { try Data(contentsOf: $0) } == contents)
                throw POSIXError(.EACCES)
            }
        }
        #expect(called)
        #expect(try scanNames() == Set(original.urls.map(\.lastPathComponent)))
    }

    @Test(.enabled(if: !caseSensitive), arguments: [0, 1, 3])
    func savingTheCommittedNameFinishesAnInterruptedCaseRename(finished: Int) throws {
        defer { cleanUp() }
        var history = try record(contents)
        let original = history.batches[0].files[0]
        try history.rename(original.id, to: "ORIGINAL", at: location)
        let saved = try Data(contentsOf: location)
        let names = urls("ORIGINAL")
        for index in finished..<names.count {
            try #require(Darwin.rename(names[index].path, original.urls[index].path) == 0)
        }
        var reloaded = try ScanHistory.load(from: location)
        let file = reloaded.batches[0].files[0]
        #expect(try file.urls.map(SavedFileIdentity.init) == file.identities)
        try reloaded.rename(file.id, to: "ORIGINAL", at: location)
        #expect(try scanNames() == Set(names.map(\.lastPathComponent)))
        #expect(try Data(contentsOf: location) == saved)
        #expect(try names.map { try Data(contentsOf: $0) } == contents)
    }

    @Test(.enabled(if: caseSensitive), arguments: [false, true])
    func caseSensitiveSidecarCollisionKeepsTheOtherEntry(hardLink: Bool) throws {
        defer { cleanUp() }
        var history = try record(contents)
        let original = history.batches[0].files[0]
        let competitor = urls("ORIGINAL")[2]
        if hardLink { try FileManager.default.linkItem(at: original.urls[2], to: competitor) }
        else { try Data("other".utf8).write(to: competitor) }
        let identity = try SavedFileIdentity(competitor)
        try history.rename(original.id, to: "ORIGINAL", at: location)
        let file = try ScanHistory.load(from: location).batches[0].files[0]
        #expect(file.urls == urls("ORIGINAL (2)"))
        #expect(try file.urls.map { try Data(contentsOf: $0) } == contents)
        #expect(try SavedFileIdentity(competitor) == identity)
        #expect(try Data(contentsOf: competitor) == (hardLink ? contents[2] : Data("other".utf8)))
        #expect(try scanNames() == Set(file.urls.map(\.lastPathComponent) + [competitor.lastPathComponent]))
    }

    @Test(.enabled(if: !caseSensitive))
    func keepsTheReplacementWhenACaseAliasChangesDuringCommit() throws {
        defer { cleanUp() }
        let original = try record(contents).batches[0].files[0]
        let moved = folder.appendingPathComponent("Moved.json")
        let other = Data("other".utf8)
        var committed = false
        do {
            try original.move(to: "ORIGINAL") { _, _ in
                try FileManager.default.moveItem(at: original.urls[2], to: moved)
                try other.write(to: original.urls[2])
                committed = true
            }
            Issue.record("Expected the replacement to stop the case rename")
        } catch {
            #expect(error.localizedDescription.contains(urls("ORIGINAL")[2].path))
        }
        #expect(committed)
        #expect(try Data(contentsOf: original.urls[2]) == other)
        #expect(try scanNames().contains("Original.json"))
        #expect(try SavedFileIdentity(moved) == original.identities[2])
        #expect(try Data(contentsOf: moved) == contents[2])
    }

    @Test func caseAliasUsesTheVolumesOwnSpellingRules() throws {
        defer { cleanUp() }
        var history = try record(contents)
        let id = history.batches[0].files[0].id
        try history.rename(id, to: "Maße", at: location)
        let other = urls("Masse")[0]
        if FileManager.default.fileExists(atPath: other.path) { return }
        try Data("other".utf8).write(to: other)
        try history.rename(id, to: "MAßE", at: location)
        let file = try ScanHistory.load(from: location).batches[0].files[0]
        #expect(file.urls == urls("MAßE"))
        #expect(try scanNames() == Set(file.urls.map(\.lastPathComponent) + [other.lastPathComponent]))
        #expect(try Data(contentsOf: other) == Data("other".utf8))
    }

    @Test func emptySidecarKeepsAUsableHistoryIdentity() throws {
        defer { cleanUp() }
        let bytes = [contents[0], contents[1], Data()]
        var history = try record(bytes)
        let original = history.batches[0].files[0]
        let before = try Data(contentsOf: location)
        var volume = statfs()
        try #require(statfs(folder.path, &volume) == 0)
        if withUnsafeBytes(of: volume.f_fstypename, { $0.starts(with: "exfat\0".utf8) }) {
            do {
                try history.rename(original.id, to: "ORIGINAL", at: location)
                Issue.record("Expected an empty exFAT file to keep its original identity")
            } catch {
                #expect(error.localizedDescription.contains(original.urls[2].path))
            }
            #expect(try Data(contentsOf: location) == before)
            #expect(try scanNames() == Set(original.urls.map(\.lastPathComponent)))
            #expect(try original.urls.map(SavedFileIdentity.init) == original.identities)
            try history.rename(original.id, to: "Temporary", at: location)
            history = try ScanHistory.load(from: location)
        }
        try history.rename(original.id, to: "ORIGINAL", at: location)
        let file = try ScanHistory.load(from: location).batches[0].files[0]
        #expect(try scanNames() == Set(urls("ORIGINAL").map(\.lastPathComponent)))
        #expect(try file.urls.map(SavedFileIdentity.init) == file.identities)
        #expect(try file.urls.map { try Data(contentsOf: $0) } == bytes)
    }
}
