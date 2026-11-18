import Foundation
import Testing
@testable import YomiKit

struct ContentNameTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YomiNames-\(UUID())")

    @Test func receiptPatternUsesThePrintedDateAndSkipsMissingTitle() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = ScanProfile(name: "Receipts", folderPath: folder.path, exportFields: true,
                                  namePattern: .init(editorText: "{title} - {merchant} - {pageDate} - {kind} {number}"))
        let (batch, staged) = try OCRBatch.stage([DocumentFixture.blank], profile: profile, date: .distantPast)
        defer { try? FileManager.default.removeItem(at: staged) }
        let key = batch.documents[0].pages[0].file
        try batch.writePDFs(in: staged, fields: [key: .receipt(.init(merchant: "Corner Shop", date: "2001-03-14"))])
        let output = try #require(batch.publish(in: staged).first)
        #expect(output.pdf.lastPathComponent == "Corner Shop - 2001-03-14 - Receipt 001.pdf")
        #expect(output.sidecars.allSatisfy { $0.deletingPathExtension() == output.pdf.deletingPathExtension() })
    }
}

extension ContentNameTests {
    private static let receiptSignature = Task {
        try await offTheTaskPool {
            try PageSignature(image: DocumentFixture.order.image, fields: .receipt(.init(merchant: "Green Market")))
        }
    }

    private var location: URL { folder.appendingPathComponent("History.json") }

    private func receipt(_ merchant: String = "Green Market", signature: PageSignature? = nil,
                         pattern: String = "{merchant} {number}", pageCount: Int = 1) throws -> ScanOutcome {
        let profile = ScanProfile(name: "Receipts", folderPath: folder.path, exportFields: true,
                                  pagesPerFile: 1, namePattern: .init(editorText: pattern))
        let pages = Array(repeating: DocumentFixture.order, count: pageCount)
        let (batch, staged) = try OCRBatch.stage(pages, profile: profile, date: .now, learnedNames: [])
        defer { try? FileManager.default.removeItem(at: staged) }
        let keys = batch.documents.map { $0.pages[0].file }
        try batch.writePDFs(in: staged, fields: Dictionary(uniqueKeysWithValues: keys.map { ($0, .receipt(.init(merchant: merchant))) }))
        if let signature {
            let evidence = PageNaming(signature: signature, matchedRule: nil, preferredStem: nil)
            let naming = Dictionary(uniqueKeysWithValues: keys.map { ($0, evidence) })
            try JSONEncoder().encode(naming).write(to: staged.appendingPathComponent("naming.json"))
        }
        let outputs = try batch.publish(in: staged)
        return ScanOutcome(files: outputs.map(\.pdf), ocrOutputs: outputs, sheets: pageCount, pages: pageCount, blankPagesSkipped: 0, folder: folder)
    }

    @Test func renameRetriesTheWholeGroupWhenOnlyJSONClashes() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let outcome = try receipt()
        let existing = folder.appendingPathComponent("Receipt.json")
        try Data("Keep this".utf8).write(to: existing)
        let original = [outcome.files[0]] + outcome.ocrOutputs[0].sidecars
        let contents = try original.map { try Data(contentsOf: $0) }
        var history = ScanHistory()
        history.record(outcome, profileName: "Receipts")
        try history.rename(history.batches[0].files[0].id, to: "Receipt", at: location)
        let file = try ScanHistory.load(from: location).batches[0].files[0]
        #expect(file.urls.map(\.lastPathComponent) == ["Receipt (2).pdf", "Receipt (2).csv", "Receipt (2).json"])
        #expect(try file.urls.map { try Data(contentsOf: $0) } == contents)
        #expect(original.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(try String(contentsOf: existing, encoding: .utf8) == "Keep this")
    }

    @Test(arguments: [false, true])
    func partialRenameRestoresOriginals(replaceSidecar: Bool) throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let outcome = try receipt()
        var history = ScanHistory()
        history.record(outcome, profileName: "Receipts")
        let file = history.batches[0].files[0]
        if replaceSidecar { try Data("Another file".utf8).write(to: file.urls[2], options: .atomic) }
        if !replaceSidecar { try Data().write(to: location) }
        let originals = try file.urls.map { try Data(contentsOf: $0) }
        #expect(throws: (any Error).self) {
            try history.rename(file.id, to: "New", at: replaceSidecar ? location : location.appendingPathComponent("history"))
        }
        #expect(try file.urls.map { try Data(contentsOf: $0) } == originals)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("New") }.isEmpty)
        #expect(history.batches[0].files[0].url == file.url)
        #expect(history.rules.isEmpty)
    }

    @Test func learnsNormalizedMerchantWithTheClosestLayoutAndKeepsRecentExamples() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        func signature(_ page: ProcessedPage, _ merchant: String) throws -> PageSignature {
            try PageSignature(image: page.image, fields: .receipt(.init(merchant: merchant)))
        }
        let signatureA = try signature(DocumentFixture.order, "GRÉEN Market")
        let signatureB = try signature(DocumentFixture.japanese, "Green Market")
        let next = try signature(DocumentFixture.order, "ｇｒｅｅｎ market")
        var history = ScanHistory()
        history.record(try receipt("GRÉEN Market", signature: signatureA), profileName: "Receipt")
        try history.rename(history.batches[0].files[0].id, to: "Green Grocer 001", at: location)
        history.record(try receipt(signature: signatureB), profileName: "Receipt")
        try history.rename(history.batches[0].files[0].id, to: "Produce", at: location)
        let reloaded = try ScanHistory.load(from: location)
        let rule = try #require(next.closest(in: reloaded.rules))
        #expect(rule.changesMerchant)
        #expect(rule.replacement == "Green Grocer")
        #expect(signatureB.closest(in: reloaded.rules)?.replacement == "Produce")
        #expect(try signature(DocumentFixture.order, "Different vendor").closest(in: reloaded.rules) == nil)
        #expect(LearnedName.examples(reloaded.rules).contains("Green Grocer"))
        try history.deleteRules([rule.id], at: location)
        #expect(try ScanHistory.load(from: location).rules.map(\.replacement) == ["Produce"])
        try history.deleteRules(Set(history.rules.map(\.id)), at: location)
        #expect(try ScanHistory.load(from: location).rules.isEmpty)
    }

    @Test(arguments: [
        ("Green Market - {merchant} {number}", "Green Market - Green Grocer 001", true),
        ("Green Market - {merchant} {number}", "Green Grocer - Green Market 001", false),
        ("{merchant} - {merchant} {number}", "Green Grocer - Green Grocer 001", true),
        ("{merchant} - {merchant} {number}", "Green Grocer - Green Market 001", false),
        ("Green Market {number}", "Green Grocer 001", false),
        ("{merchant} - {pageDate}", "Green Grocer", true),
        ("{merchant}", "Green Market (Green Market)", false),
    ])
    func correctionsFollowTheMerchantTokenAfterReload(pattern: String, proposed: String, merchantOnly: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let signature = try await Self.receiptSignature.value
        var history = ScanHistory()
        history.record(try receipt(signature: signature, pattern: pattern), profileName: "Receipts")
        try history.save(to: location)
        history = try ScanHistory.load(from: location)
        try history.rename(history.batches[0].files[0].id, to: proposed, at: location)
        let rule = try #require(history.rules.first)
        #expect(rule.changesMerchant == merchantOnly)
        #expect(rule.replacement == (merchantOnly ? "Green Grocer" : proposed))
    }

    @Test func merchantEditAfterAddingFilenameTextAndReloading() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let signature = try await Self.receiptSignature.value
        var history = ScanHistory()
        history.record(try receipt(signature: signature, pattern: "{merchant}"), profileName: "Receipts")
        let id = history.batches[0].files[0].id
        try history.rename(id, to: "Green Market invoice", at: location)
        history = try ScanHistory.load(from: location)
        #expect(history.rules.first?.changesMerchant == false)
        #expect(history.rules.first?.replacement == "Green Market invoice")
        try history.rename(id, to: "Green Grocer invoice", at: location)
        let rule = try #require(history.rules.first)
        #expect(rule.changesMerchant)
        #expect(rule.replacement == "Green Grocer")
    }

    @Test func wrappedMerchantKeepsItsPositionThroughPageAndClashSuffixes() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let signature = try await Self.receiptSignature.value
        let original = "Green Market - Green Market_001"
        let wrapped = "Copy [\(original) (2)]"
        for stem in [original, wrapped] {
            try Data("Existing".utf8).write(to: folder.appendingPathComponent("\(stem).json"))
        }
        let outcome = try receipt(signature: signature, pattern: "Green Market - {merchant}", pageCount: 2)
        #expect(outcome.files.first?.lastPathComponent == "\(original) (2).pdf")
        var history = ScanHistory()
        history.record(outcome, profileName: "Receipts")
        let id = history.batches[0].files[0].id
        try history.rename(id, to: wrapped, at: location)
        history = try ScanHistory.load(from: location)
        #expect(history.rules.first?.changesMerchant == false)
        #expect(history.rules.first?.replacement == wrapped)
        #expect(history.batches[0].files[0].urls.map(\.lastPathComponent) == ["pdf", "csv", "json"].map { "\(wrapped) (2).\($0)" })
        try history.rename(id, to: "Copy [Green Market - Green Grocer_001 (2)] (2)", at: location)
        #expect(history.rules.first?.changesMerchant == true)
        #expect(history.rules.first?.replacement == "Green Grocer")
    }

    @Test func bareMerchantCanCorrectTheSpellingOfItsLastWord() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        var history = ScanHistory()
        let signature = try await Self.receiptSignature.value
        history.record(try receipt(signature: signature, pattern: "{merchant}"), profileName: "Receipts")
        try history.rename(history.batches[0].files[0].id, to: "Green Markets", at: location)
        #expect(history.rules.first?.changesMerchant == true)
        #expect(history.rules.first?.replacement == "Green Markets")
    }

    @Test(arguments: ["'", "’"])
    func learnsApostrophesInMerchantNamesAcrossReloads(apostrophe: String) throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let signature = try PageSignature(image: DocumentFixture.order.image, fields: .receipt(.init(merchant: "Trader Joe")))
        var history = ScanHistory()
        history.record(try receipt("Trader Joe", signature: signature, pattern: "{merchant}"), profileName: "Receipts")
        let id = history.batches[0].files[0].id
        for merchant in ["Trader Joe\(apostrophe)s", "Trader Joseph\(apostrophe)s"] {
            try history.rename(id, to: merchant, at: location)
            history = try ScanHistory.load(from: location)
            let rule = try #require(signature.closest(in: history.rules))
            #expect(rule.changesMerchant)
            #expect(rule.replacement == merchant)
        }
    }

    @Test func unverifiedTrailingTextKeepsTheWholeFilenameCorrection() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let signature = try await Self.receiptSignature.value
        var outcome = try receipt(signature: signature, pattern: "{merchant} invoice")
        outcome.ocrOutputs[0].naming?.merchantSeparators = ["", ""]
        var history = ScanHistory()
        history.record(outcome, profileName: "Receipts")
        try history.rename(history.batches[0].files[0].id, to: "Green Grocer invoice", at: location)
        #expect(history.rules.first?.changesMerchant == false)
        #expect(history.rules.first?.replacement == "Green Grocer invoice")
    }

    @Test func merchantCorrectionKeepsTheClashSuffix() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = folder.appendingPathComponent("Green Market - Green Market 001.json")
        try Data("Existing".utf8).write(to: existing)
        let signature = try await Self.receiptSignature.value
        let outcome = try receipt(signature: signature, pattern: "Green Market - {merchant} {number}")
        #expect(outcome.files.first?.lastPathComponent == "Green Market - Green Market 001 (2).pdf")
        var history = ScanHistory()
        history.record(outcome, profileName: "Receipts")
        try history.rename(history.batches[0].files[0].id, to: "Green Market - Green Grocer 001 (2)", at: location)
        #expect(history.rules.first?.replacement == "Green Grocer")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "Existing")
    }

    @Test(arguments: [false, true])
    func olderHistoryLearnsAMerchantOnlyWhenItsPositionIsUnambiguous(repeated: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let signature = try await Self.receiptSignature.value
        var outcome = try receipt(signature: signature, pattern: repeated ? "Green Market - {merchant} {number}" : "{merchant} {number}")
        outcome.ocrOutputs[0].naming?.merchantSeparators = nil
        var history = ScanHistory()
        history.record(outcome, profileName: "Receipts")
        try history.save(to: location)
        history = try ScanHistory.load(from: location)
        let newName = repeated ? "Green Grocer - Green Market 001" : "Green Grocer 001"
        try history.rename(history.batches[0].files[0].id, to: newName, at: location)
        #expect(history.rules.first?.changesMerchant == !repeated)
        #expect(history.rules.first?.replacement == (repeated ? newName : "Green Grocer"))
    }

    @Test func latestCorrectionWinsForReceiptsRecordedBeforeEitherWasEdited() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let signature = try await Self.receiptSignature.value
        var history = ScanHistory()
        history.record(try receipt(signature: signature), profileName: "Receipts")
        let first = history.batches[0].files[0].id
        history.record(try receipt(signature: signature), profileName: "Receipts")
        let second = history.batches[0].files[0].id
        try history.rename(first, to: "First correction", at: location)
        history = try ScanHistory.load(from: location)
        let firstRule = try #require(history.rules.first)
        try history.rename(second, to: "Latest correction", at: location)
        let saved = try ScanHistory.load(from: location)
        #expect(saved.rules.map(\.id) == [firstRule.id])
        #expect(signature.closest(in: saved.rules)?.replacement == "Latest correction")
        let latest = try #require(saved.rules.last)
        #expect(signature.closest(in: [firstRule, latest])?.replacement == "Latest correction")
        #expect(signature.closest(in: [latest, firstRule])?.replacement == "Latest correction")
    }

    @Test func scanHistoryIsPrivateOnSaveAndWhenReopeningAnOlderFile() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = ScanHistory()
        func permissions() throws -> Int {
            try #require(FileManager.default.attributesOfItem(atPath: location.path)[.posixPermissions] as? Int)
        }
        try history.save(to: location)
        #expect(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
        #expect(try permissions() == 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: location.path)
        _ = try ScanHistory.load(from: location)
        #expect(try permissions() == 0o600)
        try history.save(to: location)
        #expect(try permissions() == 0o600)
    }

    @Test(arguments: [
        ("{title} ({kind})", "(Receipt)"),
        ("{kind} ({title})", "Receipt"),
        ("{kind} ({title}) - {number}", "Receipt - 001"),
        ("{title} - [{kind}]", "[Receipt]"),
        ("{kind} [{number}]", "Receipt [001]"),
        ("{kind} ([{title} - {number}])", "Receipt ([001])"),
        ("{kind} ({title} - {pageDate})", "Receipt"),
    ])
    func omittedFieldsKeepDelimitersAroundPresentFields(pattern: String, expected: String) {
        let values = FileNamePattern.Values(date: .now, profileName: "Receipts", runningNumber: 1, numberDigits: 3, pageNumber: 1)
        #expect(FileNamePattern(editorText: pattern).render(values, fields: [.receipt(.init())]) == expected)
    }

    @Test func retainsFifteenDiskBatchesAndEvictsLeastRecentlyUsedRule() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        var history = ScanHistory()
        let outcome = try receipt()
        let signature = try PageSignature(image: DocumentFixture.order.image, fields: .document(.init(title: "Order")))
        var first = UUID(), second = UUID()
        for index in 0..<500 {
            let timestamp = Date(timeIntervalSince1970: Double(index))
            let rule = LearnedName(signature: signature, matchedText: "Order", replacement: "Order \(index)", changesMerchant: false,
                                   edited: timestamp, lastUsed: timestamp)
            history.remember(rule)
            if index == 0 { first = rule.id }
            if index == 1 { second = rule.id }
        }
        var matched = outcome
        matched.ocrOutputs[0].usedRules = [first]
        for index in 1...16 { history.record(matched, profileName: "Batch \(index)") }
        history.remember(LearnedName(signature: signature, matchedText: "Order", replacement: "Latest", changesMerchant: false,
                                     edited: .now, lastUsed: .now))
        let photos = ScanOutcome(files: [], sheets: 1, pages: 1, blankPagesSkipped: 0, place: "Photos")
        #expect(history.record(photos, profileName: "Photos") == nil)
        try history.save(to: location)
        let reloaded = try ScanHistory.load(from: location)
        #expect(reloaded.batches.map(\.profileName) == (2...16).reversed().map { "Batch \($0)" })
        #expect(reloaded.rules.count == 500)
        #expect(reloaded.rules.contains { $0.id == first })
        #expect(!reloaded.rules.contains { $0.id == second })
    }

    @Test func missingFieldsUseTheExistingFallbackWithoutDanglingSeparators() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = ScanProfile(name: "Missing fields", folderPath: folder.path, namePattern: .init(editorText: "{title} - {pageDate}"))
        let scanDate = Calendar.current.date(from: DateComponents(year: 2024, month: 7, day: 1, hour: 14))!
        let (batch, staged) = try OCRBatch.stage([DocumentFixture.blank], profile: profile, date: scanDate, learnedNames: [])
        defer { try? FileManager.default.removeItem(at: staged) }
        try batch.writePDFs(in: staged, fields: [batch.documents[0].pages[0].file: .document(.init())])
        let output = try #require(batch.publish(in: staged).first)
        #expect(output.pdf.lastPathComponent == "2024-07-01 14.00.00.pdf")
        #expect(output.naming == nil)
    }
}

extension ContentNameTests {
    @Test func firstLaunchReadsAnEmptyHistory() throws {
        let history = try ScanHistory.load(from: location)
        #expect(history.batches.isEmpty && history.rules.isEmpty)
    }
}
