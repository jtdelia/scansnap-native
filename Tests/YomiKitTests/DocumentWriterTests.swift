import Foundation
import Testing
import YomiKit

struct DocumentWriterTests {
    private let date = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 14,
                                                                  hour: 21, minute: 42, second: 5))!

    @Test func exampleForDateAndTimePDFIsOneFile() {
        let profile = ScanProfile(name: "Docs", fileFormat: .pdf, namePattern: .dateAndTime)
        #expect(DocumentWriter.exampleFileName(for: profile, date: date) == "2026-11-14 21.42.05.pdf")
    }

    @Test func exampleForDateAndTimeJPEGShowsFirstPageNumber() {
        let profile = ScanProfile(name: "Photos", fileFormat: .jpeg, namePattern: .dateAndTime)
        #expect(DocumentWriter.exampleFileName(for: profile, date: date) == "2026-11-14 21.42.05_001.jpg")
    }

    @Test func exampleForDateAndTimeMultiPageTIFFIsOneFile() {
        let profile = ScanProfile(name: "Docs", fileFormat: .multiPageTIFF, namePattern: .dateAndTime)
        #expect(DocumentWriter.exampleFileName(for: profile, date: date) == "2026-11-14 21.42.05.tiff")
    }

    @Test func exampleForNameAndNumberUsesNextNumberAndDigits() {
        let profile = ScanProfile(name: "Receipts", fileFormat: .pdf, namePattern: .nameAndNumber("Receipt"),
                                  nextNumber: 7, numberDigits: 4)
        #expect(DocumentWriter.exampleFileName(for: profile, date: date) == "Receipt 0007.pdf")
    }

    @Test func exampleForNameAndNumberWithBlankNameIsJustTheNumber() {
        let profile = ScanProfile(name: "Photos", fileFormat: .jpeg, namePattern: .nameAndNumber("  "),
                                  nextNumber: 42, numberDigits: 3)
        #expect(DocumentWriter.exampleFileName(for: profile, date: date) == "042.jpg")
    }
}
