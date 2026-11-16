import Foundation
import Testing
@testable import YomiKit

/// What the progress panel says once a batch is saved.
struct ScanOutcomeTests {
    private static let colorNotice = "Color correction was skipped: the scanner's color profile was not found."

    @Test func batchSavedWithOnlyANoticeIsFinished() {
        let outcome = ScanOutcome(files: [], sheets: 2, pages: 2, blankPagesSkipped: 0, place: "Prints",
                                  notice: Self.colorNotice)
        let summary = outcome.summary(defaultPlace: "Yomi")
        #expect(summary.message == "Saved 2 pages to Prints. \(Self.colorNotice)")
        #expect(!summary.isProblem)
    }

    @Test func batchWithAWarningIsAProblemAndKeepsItsNotice() {
        let outcome = ScanOutcome(files: [], sheets: 1, pages: 1, blankPagesSkipped: 0, place: "Prints",
                                  warning: "Stopped. Pages scanned so far were saved.", notice: Self.colorNotice)
        let summary = outcome.summary(defaultPlace: "Yomi")
        #expect(summary.message == "Saved 1 page. Stopped. Pages scanned so far were saved. \(Self.colorNotice)")
        #expect(summary.isProblem)
    }

    @Test func batchWithNothingToSayNamesWhereItWent() {
        let outcome = ScanOutcome(files: [], sheets: 2, pages: 3, blankPagesSkipped: 1)
        #expect(outcome.summary(defaultPlace: "Yomi").message == "Saved 3 pages to Yomi, 1 blank skipped.")
        let empty = ScanOutcome(files: [], sheets: 1, pages: 0, blankPagesSkipped: 2)
        #expect(empty.summary(defaultPlace: "Yomi").message == "No pages saved, 2 blank skipped.")
    }
}
