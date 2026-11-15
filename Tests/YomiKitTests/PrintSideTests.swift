import Foundation
import Testing
@testable import YomiKit

/// Which side of a print Yomi saves as the photo.
struct PrintSideTests {
    /// Side content inside a 4 × 6 inch print at 150 dpi, on the scanner's dark backing.
    private static func side(_ side: ScannedPage.Side, _ content: (Int, Int) -> (UInt8, UInt8, UInt8)) -> ScannedPage {
        let width = 1275, height = 960, printWidth = 600, printHeight = 900
        let left = (width - printWidth) / 2, top = 30
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let px = x - left, py = y - top
                let onPrint = px >= 0 && px < printWidth && py >= 0 && py < printHeight
                let pixel = onPrint ? content(px, py) : (38, 38, 40)
                let i = (y * width + x) * 3
                rgb[i] = pixel.0
                rgb[i + 1] = pixel.1
                rgb[i + 2] = pixel.2
            }
        }
        return ScannedPage(side: side, sheetIndex: 0, width: width, height: height, resolution: 150, rgb: rgb)
    }

    /// A colour photograph: sky over grass with a figure in skin tones and dark clothes.
    private static func picture(_ px: Int, _ py: Int) -> (UInt8, UInt8, UInt8) {
        if abs(px - 300) < 80, abs(py - 400) < 100 { return (214, 168, 140) }
        if abs(px - 300) < 80, abs(py - 600) < 100 { return (45, 40, 60) }
        return py < 450 ? (110, 160, 215) : (70, 130, 60)
    }

    /// Plain photo paper with a few lines of handwriting.
    private static func writing(_ px: Int, _ py: Int) -> (UInt8, UInt8, UInt8) {
        let onLine = px >= 60 && px < 520 && py >= 80 && py < 400 && (py - 80) % 60 < 6 && (px / 23) % 4 != 3
        return onLine ? (40, 45, 90) : (238, 234, 222)
    }

    /// An overexposed snow scene: nearly all light, nearly neutral, with a dark tree.
    private static func snow(_ px: Int, _ py: Int) -> (UInt8, UInt8, UInt8) {
        abs(px - 200) < 30 && py > 300 && py < 700 ? (50, 45, 40) : (232, 236, 240)
    }

    /// A night photo: mostly as dark as the scanner's backing, with a few lit windows.
    private static func night(_ px: Int, _ py: Int) -> (UInt8, UInt8, UInt8) {
        px > 200 && px < 400 && py > 300 && py < 400 ? (230, 190, 90) : (30, 30, 34)
    }

    private static func photoProfile() -> ScanProfile {
        ScanProfile.builtInPhotoProfiles[0]
    }

    @Test func printFedBackSideFirstIsSwapped() throws {
        let sheet = try SheetProcessor.process(front: Self.side(.front, Self.writing),
                                               back: Self.side(.back, Self.picture), profile: Self.photoProfile())
        #expect(sheet.pages.map(\.source) == [.back, .front])
    }

    @Test(arguments: DocumentOutputTests.profiles.map(\.name))
    func documentProfileNeverSwapsSides(name: String) throws {
        let profile = try #require(DocumentOutputTests.profiles.first { $0.name == name })
        #expect(!profile.findPictureSide)
        let sheet = try SheetProcessor.process(front: Self.side(.front, Self.writing),
                                               back: Self.side(.back, Self.picture), profile: profile)
        #expect(sheet.pages.first?.source == .front)
        #expect(!sheet.notes.contains { $0.contains("back-side-first") })
    }

    typealias Content = @Sendable (Int, Int) -> (UInt8, UInt8, UInt8)

    @Test(arguments: [
        ("picture both sides", picture, picture),
        ("writing both sides", writing, writing),
        ("picture fed picture-side-first", picture, writing),
        ("pale picture on the back", writing, snow),
        ("dark picture on the back", writing, night),
    ] as [(String, Content, Content)])
    func unclearSheetKeepsTheFeedDirection(_ name: String, front: Content, back: Content) throws {
        let sheet = try SheetProcessor.process(front: Self.side(.front, front), back: Self.side(.back, back),
                                               profile: Self.photoProfile())
        #expect(sheet.pages.first?.source == .front)
        #expect(!sheet.notes.contains { $0.contains("back-side-first") })
    }
}
