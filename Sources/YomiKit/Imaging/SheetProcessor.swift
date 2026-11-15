import CoreGraphics
import Foundation

/// Turns one scanned sheet (both raw sides) into finished pages for a profile.
public enum SheetProcessor {
    public struct Result {
        public var pages: [ProcessedPage] = []
        public var blankSides: Int = 0
        public var notes: [String] = []
    }

    /// `colorProfile` is the scanner's colour profile when the batch corrects colour.
    public static func process(front rawFront: ScannedPage, back rawBack: ScannedPage,
                               profile: ScanProfile, colorProfile: CGColorSpace? = nil) throws -> Result {
        var result = Result()
        var front = ColumnFlattener.flatten(rawFront)
        var back = ColumnFlattener.flatten(rawBack)

        let backFit = ShowThroughDetector.analyze(target: back, other: front)
        let frontFit = ShowThroughDetector.analyze(target: front, other: back)
        for (label, fit) in [("front", frontFit), ("back", backFit)] {
            if let fit {
                result.notes.append(String(format: "%@ show-through: shift %d,%d strength %.3f corr %.2f residual %.4f",
                                           label, fit.dx, fit.dy, fit.strength, fit.correlation, fit.residualInk))
            }
        }

        let keepBack = profile.sides == .duplex
            && !(profile.skipBlankPages && (backFit?.isShowThroughOnly ?? false))
        if profile.sides == .duplex, !keepBack { result.blankSides += 1 }

        if profile.reduceBleedThrough {
            let original = (front: front, back: back)
            if let frontFit { front = ShowThroughDetector.remove(from: original.front, other: original.back, fit: frontFit) }
            if keepBack, let backFit { back = ShowThroughDetector.remove(from: original.back, other: original.front, fit: backFit) }
        }

        var options = profile.processingOptions
        options.flattenColumns = false
        options.colorProfile = colorProfile
        for side in keepBack ? [front, back] : [front] {
            let page = try PageProcessor.process(side, options: options)
            if page.isBlank {
                result.blankSides += 1
            } else {
                result.pages.append(page)
            }
        }
        return result
    }
}
