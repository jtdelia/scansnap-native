import PDFKit
import Testing
@testable import YomiKit

struct FieldWorkerTests {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YomiFieldWorker-\(UUID())")

    private func writeWorker() throws -> URL {
        let script = folder.appendingPathComponent("yomi-ocr")
        try """
        #!/bin/zsh
        [[ $1 == --predict ]] || exit 2
        trap '' TERM
        print $$ > "${0:h}/pid"
        exec /bin/sleep 3600
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    private func workerPID() throws -> pid_t {
        let text = try String(contentsOf: folder.appendingPathComponent("pid"), encoding: .utf8)
        return try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @Test func cancelledPredictionReapsTheWorker() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        let worker = FieldWorker(executable: try writeWorker())
        let page = RecognizedPage(kind: .receipt, language: .english, documents: [], transcript: "Receipt", detectedData: [])
        let prediction = Task { try await worker.predict(page, imageURL: folder.appendingPathComponent("unused"), in: folder) }
        defer { prediction.cancel() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !fm.fileExists(atPath: folder.appendingPathComponent("pid").path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = try workerPID()
        prediction.cancel()
        await #expect(throws: CancellationError.self) { try await prediction.value }
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        #expect(try Set(fm.contentsOfDirectory(atPath: folder.path)) == ["pid", "yomi-ocr"])
    }

    @Test func earlierPredictionKeepsItsMetadataAndSidecarsAfterADeadline() async throws {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: folder) }
        let profile = ScanProfile(name: "Bills", folderPath: folder.path, exportFields: true, namePattern: [.profileName])
        let (batch, staged) = try OCRBatch.stage(Array(repeating: DocumentFixture.blank, count: 3), profile: profile, date: Date())
        defer { try? fm.removeItem(at: staged) }
        let receipt = ReceiptFields(merchant: "GREEN STREET MARKET")
        try JSONEncoder().encode(PageFields.receipt(receipt)).write(to: folder.appendingPathComponent("proposal"))
        let worker = folder.appendingPathComponent("predict")
        try """
        #!/bin/zsh
        print "${3:t}" >> "${0:h}/requests"
        if [[ ${3:t} == page-1.png ]]; then exec /bin/cp "${0:h}/proposal" "$4"; fi
        exec /bin/sleep 3600
        """.write(to: worker, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        let page = RecognizedPage(kind: .receipt, language: .english, documents: [], transcript: "GREEN STREET MARKET", detectedData: [])
        let recognized = Dictionary(uniqueKeysWithValues: batch.documents[0].pages.map { ($0.file, page) })
        let fields = try await batch.readFields(in: staged, recognizedPages: recognized, worker: FieldWorker(executable: worker, timeout: .seconds(1)))
        try batch.writePDFs(in: staged, recognizedPages: recognized, fields: fields)
        let output = try #require(batch.publish(in: staged).first)
        #expect(try String(contentsOf: folder.appendingPathComponent("requests"), encoding: .utf8) == "page-1.png\npage-2.png\n")
        #expect(output.pages == [.receipt(receipt), .receipt(.init()), .receipt(.init())])
        let document = try #require(PDFDocument(url: output.pdf))
        #expect(document.pageCount == 3)
        #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == receipt.merchant)
        #expect(output.sidecars.map(\.pathExtension) == ["csv", "json"])
        #expect(try JSONDecoder().decode([ReceiptFields].self, from: Data(contentsOf: output.sidecars[1])) == [receipt])
    }

    @Test
    func stalledFieldWorkerCompletesBothScanReports() async throws {
        let output = try await offTheTaskPool { try checkScanReports() }
        if let reason = await output.unavailableReason() { try reportVisionUnavailable(reason) }
        try #require(output.status == 0 && output.stderr.isEmpty, "\(output)")
    }

    private func checkScanReports() throws -> OCRTestHelper.Output {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        try fm.copyItem(at: OCRTestHelper.executable, to: folder.appendingPathComponent("recognize"))
        _ = try writeWorker()
        let script = folder.appendingPathComponent("first-batch")
        try """
        #!/bin/zsh
        /usr/bin/perl -e 'alarm 480; exec @ARGV' "${0:h}/recognize" "$@" 2> "${0:h}/errors"
        code=$?
        print "$code" > "${0:h}/status"
        exit "$code"
        """.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let profile = ScanProfile(name: "Bills", folderPath: folder.path, exportFields: true, namePattern: [.profileName])
        let original = DocumentFixture.render(font: "Helvetica", size: 40) { _, draw in
            draw("First invoice", 100, 520)
            draw("Last recognized line", 100, 120)
        }
        let queue = DispatchQueue(label: "scan-reports")
        let first = try queue.sync { try BatchSaver.start([original], profile: profile, photoLibrary: nil, helper: script) }
        let job = try #require(first.1)
        let firstDone = DispatchSemaphore(value: 0)
        let ready = DispatchSemaphore(value: 0)
        queue.async {
            ScanOutcome(files: first.0.files, sheets: 1, pages: 1, blankPagesSkipped: 0).report(after: job, on: queue, onPagesReady: { count, recognizing in
                #expect(count == 1 && recognizing)
                ready.signal()
            }) { result in
                #expect((try? result.get().files) == first.0.files)
                firstDone.signal()
            }
        }
        try #require(ready.wait(timeout: .now() + 5) == .success)
        let entered = folder.appendingPathComponent("pid")
        let status = folder.appendingPathComponent("status")
        let upstreamDeadline = ContinuousClock.now + .seconds(490)
        while !fm.fileExists(atPath: entered.path), ContinuousClock.now < upstreamDeadline {
            if fm.fileExists(atPath: status.path) {
                let output = try helperOutput()
                try #require(output.status != 0, "The OCR helper exited without starting the field worker")
                try #require(firstDone.wait(timeout: .now() + 45) == .success)
                return output
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let pid = try workerPID()
        try #require(kill(pid, 0) == 0)
        let workerDeadline = DispatchTime.now() + 45
        let secondDone = DispatchSemaphore(value: 0)
        let second = try queue.sync {
            let (batch, pending) = try BatchSaver.start([DocumentFixture.blank], profile: profile, photoLibrary: nil,
                                                       helper: folder.appendingPathComponent("missing"))
            ScanOutcome(files: batch.files, sheets: 1, pages: 1, blankPagesSkipped: 0).report(after: pending, on: queue, onPagesReady: nil) { result in
                #expect((try? result.get().files.first?.lastPathComponent) == "Bills (2).pdf")
                secondDone.signal()
            }
            return try #require(batch.files.first)
        }
        try #require(secondDone.wait(timeout: .now() + 10) == .success)
        let bytes = try Data(contentsOf: second)
        try #require(PDFDocument(data: bytes)?.pageCount == 1)
        try #require(firstDone.wait(timeout: .now()) == .timedOut)
        try #require(firstDone.wait(timeout: workerDeadline) == .success)
        let document = try #require(PDFDocument(url: first.0.files[0]))
        #expect(document.findString("First invoice", withOptions: []).count == 1)
        #expect(document.findString("Last recognized line", withOptions: []).count == 1)
        #expect(try Data(contentsOf: second) == bytes)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)
        return try helperOutput()
    }

    private func helperOutput() throws -> OCRTestHelper.Output {
        let status = try String(contentsOf: folder.appendingPathComponent("status"), encoding: .utf8)
        let stderr = try String(contentsOf: folder.appendingPathComponent("errors"), encoding: .utf8)
        return try OCRTestHelper.Output(status: #require(Int32(status.trimmingCharacters(in: .newlines))), stderr: stderr)
    }
}
