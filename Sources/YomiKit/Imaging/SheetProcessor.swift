import CoreGraphics
import Foundation

/// Turns one scanned sheet (both raw sides) into finished pages for a profile.
public enum SheetProcessor {
    public struct Result: Sendable {
        public var pages: [ProcessedPage] = []
        public var blankSides: Int = 0
        public var notes: [String] = []
    }

    /// `colorProfile` is the scanner's colour profile when the batch corrects colour.
    public static func process(front rawFront: ScannedPage, back rawBack: ScannedPage,
                               profile: ScanProfile, colorProfile: CGColorSpace? = nil) throws -> Result {
        var result = Result()
        // Column flattening scales each column to a paper-white taken from its content, which shifts a photo's colours.
        var front = colorProfile == nil ? ColumnFlattener.flatten(rawFront) : rawFront
        var back = colorProfile == nil ? ColumnFlattener.flatten(rawBack) : rawBack

        var backLooksLikePictureSide = false
        var detectedPictureSide: ScannedPage.Side?
        if profile.findPictureSide || profile.backCaptions, profile.sides == .duplex {
            let sides = PrintSideDetector.measure(front: front, back: back)
            if sides.backLooksLikePictureSide { detectedPictureSide = back.side }
            result.notes.append(String(format: "plain paper: front %.2f back %.2f", sides.frontPaper, sides.backPaper))
            if profile.findPictureSide, sides.isFedBackSideFirst {
                swap(&front, &back)
                result.notes.append("print fed back-side-first: saving the back as the picture side")
            } else {
                backLooksLikePictureSide = sides.backLooksLikePictureSide
            }
        }

        let backFit = ShowThroughDetector.analyze(target: back, other: front)
        let frontFit = ShowThroughDetector.analyze(target: front, other: back)
        for (label, fit) in [("front", frontFit), ("back", backFit)] {
            if let fit {
                result.notes.append(String(format: "%@ show-through: shift %d,%d strength %.3f corr %.2f residual %.4f",
                                           label, fit.dx, fit.dy, fit.strength, fit.correlation, fit.residualInk))
            }
        }

        // Only a back that is mostly plain paper is read for a caption and never saved.
        let readsBack = profile.backCaptions && profile.sides == .duplex && !backLooksLikePictureSide
        if backLooksLikePictureSide { result.notes.append("back looks like a picture side: saving it as a photo") }
        let keepBack = profile.sides == .duplex && !readsBack
            && !(profile.skipBlankPages && (backFit?.isShowThroughOnly ?? false))
        if profile.sides == .duplex, !keepBack, !readsBack { result.blankSides += 1 }

        if profile.reduceBleedThrough {
            let original = (front: front, back: back)
            if let frontFit { front = ShowThroughDetector.remove(from: original.front, other: original.back, fit: frontFit) }
            if keepBack, let backFit { back = ShowThroughDetector.remove(from: original.back, other: original.front, fit: backFit) }
        }

        var options = profile.processingOptions
        options.flattenColumns = false
        options.colorProfile = colorProfile
        var caption: String?
        if readsBack {
            switch try readBack(back, options: options, isShowThroughOnly: backFit?.isShowThroughOnly ?? false) {
            case .blank:
                result.blankSides += 1
                result.notes.append("back blank or only printing")
            case .unreadable:
                result.notes.append("back has writing that could not be read")
            case let .recognitionFailed(error):
                result.notes.append("text recognition failed: \(error)")
            case let .caption(text):
                caption = text
                result.notes.append("back read as a caption of \(text.count) characters")
            }
        }
        // A very pale or very dark print has too little ink for the blank check, so a photo scan profile
        // never checks the picture side.
        var pictureOptions = options
        if profile.cropToPrint || profile.backCaptions { pictureOptions.skipBlankPages = false }
        let backOptions = backLooksLikePictureSide ? pictureOptions : options
        for (side, options) in [(front, pictureOptions)] + (keepBack ? [(back, backOptions)] : []) {
            var page = try PageProcessor.process(side, options: options)
            if page.isBlank {
                result.blankSides += 1
            } else {
                page.caption = caption
                page.foundPrint = page.foundPrint || page.source == detectedPictureSide || caption != nil
                result.pages.append(page)
            }
        }
        return result
    }

    /// Reads a print's back for its caption. The back is checked with the same blank and show-through
    /// detection documents use, whatever the scan profile's blank setting, since it is never saved.
    private static func readBack(_ back: ScannedPage, options: ProcessingOptions,
                                 isShowThroughOnly: Bool) throws -> BackCaptionReader.Reading {
        guard !isShowThroughOnly else { return .blank }
        var options = options
        options.skipBlankPages = true
        let page = try PageProcessor.process(back, options: options)
        return page.isBlank ? .blank : BackCaptionReader.read(page.image)
    }
}
