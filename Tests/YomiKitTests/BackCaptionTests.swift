import CoreGraphics
import CoreML
import CoreText
import Foundation
import ImageIO
import Testing
import Vision
@testable import YomiKit

/// Writing on the back of a print becomes the photo's caption, and the back is never saved.
struct BackCaptionTests {
    /// What is printed or written on one side of a 4 × 6 inch print.
    struct Side: Sendable {
        var paper: (UInt8, UInt8, UInt8) = (240, 236, 226)
        var picture: Picture?
        var text: [Text] = []
        var scribbles = false

        enum Picture: Sendable { case colorful, pale }

        struct Text: Sendable {
            var string: String
            var font: String
            var size: CGFloat
            var ink: (CGFloat, CGFloat, CGFloat)
            /// Baseline position on the print, in pixels from the top-left corner.
            var x: CGFloat, y: CGFloat
            var angle: CGFloat = 0
        }
    }

    private static let printWidth = 600, printHeight = 900, margin = 30

    /// The side scanned at 150 dpi, on the scanner's dark backing.
    private static func scan(_ side: Side, as scannedSide: ScannedPage.Side) -> ScannedPage {
        let width = printWidth + 2 * margin, height = printHeight + 2 * margin
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        func fill(_ rect: CGRect, _ color: (UInt8, UInt8, UInt8)) {
            context.setFillColor(red: CGFloat(color.0) / 255, green: CGFloat(color.1) / 255,
                                 blue: CGFloat(color.2) / 255, alpha: 1)
            context.fill(rect)
        }
        /// A rectangle given from the print's top-left corner, in Core Graphics' bottom-up coordinates.
        func onPrint(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CGRect {
            CGRect(x: margin + x, y: height - margin - y - h, width: w, height: h)
        }
        fill(CGRect(x: 0, y: 0, width: width, height: height), (38, 38, 40))
        fill(onPrint(0, 0, printWidth, printHeight), side.paper)
        switch side.picture {
        case .colorful:
            fill(onPrint(0, 0, printWidth, 450), (110, 160, 215))
            fill(onPrint(0, 450, printWidth, 450), (70, 130, 60))
            fill(onPrint(220, 300, 160, 200), (214, 168, 140))
            fill(onPrint(220, 500, 160, 200), (45, 40, 60))
        case .pale:
            fill(onPrint(0, 0, printWidth, 450), (226, 232, 238))
            fill(onPrint(0, 450, printWidth, 450), (232, 230, 220))
            fill(onPrint(220, 300, 160, 200), (238, 224, 214))
        case nil:
            break
        }
        for text in side.text {
            let font = CTFontCreateWithName(text.font as CFString, text.size, nil)
            let color = CGColor(srgbRed: text.ink.0 / 255, green: text.ink.1 / 255, blue: text.ink.2 / 255, alpha: 1)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text.string, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]))
            context.saveGState()
            context.translateBy(x: CGFloat(margin) + text.x, y: CGFloat(height - margin) - text.y)
            context.rotate(by: text.angle)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
        if side.scribbles {
            context.setStrokeColor(CGColor(srgbRed: 0.15, green: 0.17, blue: 0.4, alpha: 1))
            context.setLineWidth(3)
            for row in 0..<5 {
                let top = CGFloat(height - margin - 150 - row * 55)
                context.move(to: CGPoint(x: CGFloat(margin + 75), y: top))
                for step in 1...40 {
                    let x = CGFloat(margin + 75 + step * 11)
                    let wobble = CGFloat((step * 37 + row * 11) % 9) * 3 - 12
                    context.addLine(to: CGPoint(x: x, y: top + wobble))
                }
                context.strokePath()
            }
        }

        let data = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            rgb[pixel * 3] = data[pixel * 4]
            rgb[pixel * 3 + 1] = data[pixel * 4 + 1]
            rgb[pixel * 3 + 2] = data[pixel * 4 + 2]
        }
        return ScannedPage(side: scannedSide, sheetIndex: 0, width: width, height: height, resolution: 150, rgb: rgb)
    }

    private static let picture = Side(picture: .colorful)
    private static let blank = Side()

    private static func handwriting(_ string: String, y: CGFloat) -> Side.Text {
        Side.Text(string: string, font: "Bradley Hand Bold", size: 32, ink: (35, 45, 120), x: 60, y: y)
    }

    private static let textRecognition: (available: Bool, comment: Comment) = {
        do {
            let word = Side.Text(string: "Recognition", font: "Helvetica", size: 48, ink: (0, 0, 0), x: 60, y: 210)
            let image = try scan(Side(text: [word]), as: .back).cgImage()
            let reading = BackCaptionReader.read(image)
            if case let .caption(text) = reading, text.localizedCaseInsensitiveCompare(word.string) == .orderedSame {
                return (true, "Vision can read rendered text")
            }
            return (false, Comment(rawValue: "Vision cannot read rendered text: \(reading)"))
        } catch {
            return (false, Comment(rawValue: "Vision capability probe failed: \(error as NSError)"))
        }
    }()

    private static let handwrittenNote = [
        handwriting("Grandma and Joe", y: 210),
        handwriting("at Lake Tahoe", y: 260),
        handwriting("Summer 1962", y: 310),
    ]

    /// A maker's name printed in faint rows across the whole back of the paper.
    private static let brandPrinting = stride(from: 80, to: 900, by: 110).map { y in
        Side.Text(string: "KODAK ROYAL PAPER     KODAK ROYAL PAPER", font: "Helvetica", size: 16,
                  ink: (165, 160, 155), x: CGFloat(y % 220 == 80 ? 20 : 70), y: CGFloat(y))
    }

    /// Order, frame and correction numbers a photo lab prints along the edge.
    private static let labPrinting = [
        Side.Text(string: "N 0423 17  +2 -1  C41", font: "Courier New Bold", size: 18, ink: (60, 60, 70), x: 40, y: 820),
        Side.Text(string: "#2847-11  >12<  0008", font: "Courier New Bold", size: 18, ink: (60, 60, 70), x: 40, y: 850),
    ]

    private static func process(front: Side, back: Side,
                                profile: ScanProfile = ScanProfile.builtInPhotoProfiles[0]) async throws -> SheetProcessor.Result {
        try await offTheTaskPool {
            try SheetProcessor.process(front: scan(front, as: .front), back: scan(back, as: .back), profile: profile)
        }
    }

    @Test(.enabled(if: textRecognition.available, textRecognition.comment))
    func handwrittenBackBecomesTheCaptionAndIsNotSaved() async throws {
        let sheet = try await Self.process(front: Self.picture, back: Side(text: Self.handwrittenNote))
        #expect(sheet.pages.map(\.source) == [.front])
        let caption = try #require(sheet.pages.first?.caption, "\(sheet.notes)")
        #expect(caption.localizedCaseInsensitiveContains("Lake Tahoe"))
        #expect(caption.contains("1962"))
    }

    @Test(.enabled(if: textRecognition.available, textRecognition.comment))
    func handwrittenNoteIsReadOnCPU() async throws {
        let reading = try await offTheTaskPool {
            let back = try Self.scan(Side(text: Self.handwrittenNote), as: .back).cgImage()
            return BackCaptionReader.read(back, useCPU: true)
        }
        guard case let .caption(caption) = reading else {
            Issue.record("Expected a handwritten caption, got \(reading)")
            return
        }
        #expect(caption.localizedCaseInsensitiveContains("Grandma and Joe"))
        #expect(caption.localizedCaseInsensitiveContains("Lake Tahoe"))
        #expect(caption.contains("1962"))
    }

    // TEMPORARY: Remove after diagnosing text recognition on the GitHub runner.
    @Test func visionConfigurationDiagnostic() async {
        do {
            try await offTheTaskPool {
                let image = try Self.scan(Side(text: [Self.handwriting("Grandma and Joe", y: 210)]), as: .back).cgImage()
                for level in [VNRequestTextRecognitionLevel.accurate, .fast] {
                    for automaticLanguage in [true, false] {
                        for useCPU in [false, true] {
                            let request = VNRecognizeTextRequest()
                            request.recognitionLevel = level
                            request.automaticallyDetectsLanguage = automaticLanguage
                            if !automaticLanguage { request.recognitionLanguages = ["en-US"] }
                            let configuration = "level=\(level == .accurate ? "accurate" : "fast")"
                                + " language=\(automaticLanguage ? "automatic" : "en-US")"
                                + " device=\(useCPU ? "CPU" : "default") revision=\(request.revision)"
                            do {
                                print("VISION-DIAG \(configuration) supportedLanguages=\(try request.supportedRecognitionLanguages())")
                            } catch {
                                let error = error as NSError
                                print("VISION-DIAG \(configuration) supportedLanguages error domain=\(error.domain) code=\(error.code)")
                            }
                            do {
                                if useCPU {
                                    guard let cpu = try request.supportedComputeStageDevices[.main]?.first(where: {
                                        if case .cpu = $0 { return true }
                                        return false
                                    }) else { throw NSError(domain: VNErrorDomain, code: VNErrorCode.unsupportedComputeDevice.rawValue) }
                                    request.setComputeDevice(cpu, for: .main)
                                }
                                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                                print("VISION-DIAG \(configuration) text=\(text.debugDescription)")
                            } catch {
                                let error = error as NSError
                                print("VISION-DIAG \(configuration) error domain=\(error.domain) code=\(error.code)")
                            }
                        }
                    }
                }
            }
        } catch {
            let error = error as NSError
            print("VISION-DIAG image preparation error domain=\(error.domain) code=\(error.code)")
        }
    }

    /// Lines turned by `angle` (anticlockwise) around the print's centre.
    private static func turned(_ lines: [Side.Text], by angle: CGFloat) -> [Side.Text] {
        let cx = CGFloat(printWidth) / 2, cy = CGFloat(printHeight) / 2
        return lines.map { text in
            var text = text
            let dx = text.x - cx, dy = text.y - cy
            text.angle = angle
            text.x = cx + dx * cos(angle) + dy * sin(angle)
            text.y = cy - dx * sin(angle) + dy * cos(angle)
            return text
        }
    }

    @Test(.enabled(if: textRecognition.available, textRecognition.comment),
          arguments: [("upside down", CGFloat.pi), ("sideways", .pi / 2), ("sideways the other way", -.pi / 2)])
    func writingInAnyDirectionIsRead(_ name: String, angle: CGFloat) async throws {
        let back = Side(text: Self.turned(Self.handwrittenNote, by: angle))
        let sheet = try await Self.process(front: Self.picture, back: back)
        #expect(sheet.pages.first?.caption?.localizedCaseInsensitiveContains("Lake Tahoe") == true, "\(sheet.notes)")
    }

    @Test(.enabled(if: textRecognition.available, textRecognition.comment))
    func onlyHandwritingFromABackWithPrintingBecomesTheCaption() async throws {
        let back = Side(text: Self.brandPrinting + Self.labPrinting + Self.handwrittenNote)
        let sheet = try await Self.process(front: Self.picture, back: back)
        let caption = try #require(sheet.pages.first?.caption, "\(sheet.notes)")
        #expect(caption.localizedCaseInsensitiveContains("Lake Tahoe"))
        #expect(!caption.localizedCaseInsensitiveContains("KODAK"), "\(caption)")
        #expect(!caption.contains("0423"))
        #expect(!caption.contains("2847"))
    }

    @Test(.enabled(if: textRecognition.available, textRecognition.comment))
    func printFedBackSideFirstGetsTheCaptionFromItsFront() async throws {
        let sheet = try await Self.process(front: Side(text: Self.handwrittenNote), back: Self.picture)
        #expect(sheet.pages.map(\.source) == [.back])
        #expect(sheet.pages.first?.caption?.localizedCaseInsensitiveContains("Lake Tahoe") == true, "\(sheet.notes)")
    }

    @Test(.enabled(if: textRecognition.available, textRecognition.comment), arguments: ["1962", "7/4/62"])
    func handwrittenDateOnItsOwnBecomesTheCaption(date: String) async throws {
        let back = Side(text: [Self.handwriting(date, y: 260)] + Self.labPrinting)
        let sheet = try await Self.process(front: Self.picture, back: back)
        #expect(sheet.pages.first?.caption == date, "\(sheet.notes)")
    }

    @Test(arguments: [("photo cropping", true, false), ("back captions", false, true), ("both", true, true)])
    func palePictureIsNeverDroppedAsBlank(_ name: String, cropToPrint: Bool, backCaptions: Bool) async throws {
        var profile = ScanProfile.builtInPhotoProfiles[0]
        profile.cropToPrint = cropToPrint
        profile.backCaptions = backCaptions
        let sheet = try await Self.process(front: Side(picture: .pale), back: Self.blank, profile: profile)
        #expect(sheet.pages.map(\.source) == [.front])
        #expect(sheet.blankSides == 1)
    }

    @Test(arguments: [true, false])
    func backThatLooksLikeAPictureIsSavedAsAPhoto(findPictureSide: Bool) async throws {
        var profile = ScanProfile.builtInPhotoProfiles[0]
        profile.findPictureSide = findPictureSide
        let sheet = try await Self.process(front: Self.picture, back: Self.picture, profile: profile)
        #expect(sheet.pages.map(\.source) == [.front, .back])
        #expect(sheet.pages.allSatisfy { $0.caption == nil })
        #expect(sheet.blankSides == 0)
    }

    // MARK: Saved files

    private static func savedCaptions(format: ScanProfile.FileFormat, caption: String?) async throws -> [String: [String?]] {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YomiBackCaptionTests-\(UUID())")
        var profile = ScanProfile.builtInPhotoProfiles[0]
        profile.saveTo = .folder
        profile.folderPath = folder.path
        profile.fileFormat = format
        profile.namePattern = [.profileName]
        let context = CGContext(data: nil, width: 120, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 0.4, green: 0.35, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
        let page = ProcessedPage(image: context.makeImage()!, resolution: 300, isBlank: false, source: .front,
                                 isColor: true, caption: caption)
        _ = try await offTheTaskPool { [profile] in try DocumentWriter.save([page], profile: profile) }
        return try FileManager.default.contentsOfDirectory(atPath: folder.path).reduce(into: [:]) { result, name in
            let source = try #require(CGImageSourceCreateWithURL(folder.appendingPathComponent(name) as CFURL, nil))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let iptc = properties?[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
            let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
                .flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, "dc:description" as CFString) }
            result[name] = [iptc?[kCGImagePropertyIPTCCaptionAbstract] as? String, xmp as String?]
        }
    }

    @Test(arguments: [ScanProfile.FileFormat.heic, .jpeg, .tiff, .png])
    func captionIsSavedInTheEnhancedFileAndItsOriginal(format: ScanProfile.FileFormat) async throws {
        let caption = "Grandma and Joe\nat Lake Tahoe"
        let ext = format.fileExtension
        #expect(try await Self.savedCaptions(format: format, caption: caption) == [
            "Photos – Quick.\(ext)": [caption, caption],
            "Photos – Quick_original.\(ext)": [caption, caption],
        ])
    }

    @Test func photoWithoutACaptionSavesNoCaption() async throws {
        #expect(try await Self.savedCaptions(format: .heic, caption: nil) == [
            "Photos – Quick.heic": [nil, nil],
            "Photos – Quick_original.heic": [nil, nil],
        ])
    }

    @Test func unreadableWritingGivesNoCaptionButIsNotBlank() async throws {
        let sheet = try await Self.process(front: Self.picture, back: Side(scribbles: true))
        #expect(sheet.pages.map(\.source) == [.front])
        #expect(sheet.pages.first?.caption == nil)
        #expect(sheet.blankSides == 0)
    }

    @Test func textRecognitionFailureIsDistinctFromUnreadableWriting() async throws {
        let reading = try await offTheTaskPool {
            let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            let image = try #require(context.makeImage())
            return BackCaptionReader.read(image)
        }
        guard case let .recognitionFailed(error) = reading else {
            Issue.record("Expected a text recognition failure, got \(reading)")
            return
        }
        #expect(error.contains("com.apple.Vision"))
        #expect(error.contains("code="))
        #expect(error.contains("userInfo="))
    }

    // MARK: Recognized lines

    @Test(arguments: [
        ["ORDER 0423 FRAME 17"], ["NNN 12 +1"], ["ROLL 4 NEG 12"], ["Lab 2 PRINT 3"], ["PROCESS C41 KX"], ["NNN"],
    ])
    func labPrintingIsNotACaption(lines: [String]) {
        #expect(BackCaptionReader.handwrittenLines(lines) == [])
    }

    @Test func handwritingNextToLabPrintingIsKept() {
        let lines = ["MOM AND DAD", "Max the lab puppy", "JULY 4, 1962", "ORDER 0423 FRAME 17"]
        #expect(BackCaptionReader.handwrittenLines(lines) == ["MOM AND DAD", "Max the lab puppy", "JULY 4, 1962"])
    }

    @Test func labPrintingIsTakenOutOfHandwritingOnTheSameLine() {
        #expect(BackCaptionReader.handwrittenLines(["Grandma at Tahoe ORDER 0423 FRAME 17"]) == ["Grandma at Tahoe"])
    }

    @Test(arguments: [["KODAK ROYAL PAPER"], ["FUJICOLOR CRYSTAL ARCHIVE PAPER"], ["Kodak Royal Paper", "Kodak"]])
    func brandPhrasePrintedOnceIsNotACaption(lines: [String]) {
        #expect(BackCaptionReader.handwrittenLines(lines) == [])
    }

    @Test func handwrittenWordsThatPaperMakersAlsoUseAreKept() {
        let lines = ["Crystal", "Royal Albert Hall", "our archive paper", "KODAK ROYAL PAPER"]
        #expect(BackCaptionReader.handwrittenLines(lines) == ["Crystal", "Royal Albert Hall", "our archive paper"])
    }

    @Test func brandPhraseIsTakenOutOfHandwritingItCrosses() {
        #expect(BackCaptionReader.handwrittenLines(["at Lake Tahoe KODAK ROYAL PAPER"]) == ["at Lake Tahoe"])
    }

    @Test func blankBackCountsAsBlank() async throws {
        let sheet = try await Self.process(front: Self.picture, back: Self.blank)
        #expect(sheet.pages.map(\.source) == [.front])
        #expect(sheet.pages.first?.caption == nil)
        #expect(sheet.blankSides == 1, "\(sheet.notes)")
    }

    @Test(.enabled(if: textRecognition.available, textRecognition.comment),
          arguments: [("brand printing", brandPrinting), ("lab printing", labPrinting)])
    func printingCountsAsBlank(_ name: String, printing: [Side.Text]) async throws {
        let sheet = try await Self.process(front: Self.picture, back: Side(text: printing))
        #expect(sheet.pages.map(\.source) == [.front])
        #expect(sheet.pages.first?.caption == nil)
        #expect(sheet.blankSides == 1, "\(sheet.notes)")
    }
}
