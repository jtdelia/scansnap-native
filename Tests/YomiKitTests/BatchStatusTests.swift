import Foundation
import Testing
@testable import YomiKit

struct BatchStatusTests {
    @Test func olderFailuresStayQueuedThroughRecognitionAndTheNextSuccess() {
        var status = BatchStatus()
        let first = status.beginScan()
        let second = status.beginScan()
        let third = status.beginScan()
        let profile = ScanProfile(name: "Bills")
        let folder = URL(fileURLWithPath: "/saved pages")
        let recovery = OCRRecoveryError(folder: folder, saved: 2, total: 2, cause: CocoaError(.fileWriteNoPermission))
        let warning = ScanOutcome(files: [], sheets: 1, pages: 1, blankPagesSkipped: 0, warning: "The feeder jammed.")
        status.finish(batch: first, profile: profile, result: .failure(recovery))
        #expect(status.state == .running)
        status.recognize(batch: third)
        status.finish(batch: second, profile: profile, result: .success(warning))
        #expect(status.state == .recognizing)
        let success = ScanOutcome(files: [], sheets: 1, pages: 1, blankPagesSkipped: 0, place: "Receipts")
        status.finish(batch: third, profile: profile, result: .success(success))
        let firstFailure = BatchStatus.Failure(profile: "Bills", message: recovery.description, folder: folder)
        #expect(status.state == .failed(firstFailure))
        let fourth = status.beginScan()
        #expect(status.state == .running)
        status.finish(batch: fourth, profile: profile, result: .success(success))
        #expect(status.state == .failed(firstFailure))
        status.dismissFailure()
        #expect(status.state == .failed(.init(profile: "Bills", message: "Saved 1 page. The feeder jammed.", folder: nil)))
        status.dismissFailure()
        #expect(status.state == .finished("Saved 1 page to Receipts."))
    }

    @Test func earlierFailureArrivingAfterLatestSuccessIsVisibleUntilAcknowledged() {
        var status = BatchStatus()
        let first = status.beginScan()
        let second = status.beginScan()
        let profile = ScanProfile(name: "Bills")
        let success = ScanOutcome(files: [], sheets: 1, pages: 1, blankPagesSkipped: 0, place: "Receipts")
        status.finish(batch: second, profile: profile, result: .success(success))
        status.finish(batch: first, profile: profile, result: .failure(ScanError.noPaper))
        #expect(status.state == .failed(.init(profile: "Bills", message: ScanError.noPaper.description, folder: nil)))
        status.dismissFailure()
        #expect(status.state == .finished("Saved 1 page to Receipts."))
    }
}
