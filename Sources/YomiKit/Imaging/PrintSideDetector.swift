import Foundation

/// Tells whether a print went through the feeder back-side-first: plain paper on the front and a
/// picture on the back. Anything less clear-cut counts as fed picture-side-first.
enum PrintSideDetector {
    /// Shares of the print covered by plain paper, measured on both sides.
    struct Measurement {
        var frontPaper: Double
        var backPaper: Double
        var frontArea: Int
        var backArea: Int

        /// The front is nearly all plain paper (writing and lab printing are thin), the back is
        /// mostly not, and the back's picture covers enough of the print to be more than shadows.
        var isFedBackSideFirst: Bool {
            frontPaper >= 0.85 && backLooksLikePicture && Double(backArea) >= 0.5 * Double(frontArea)
        }

        /// The back is mostly not plain paper, so it may carry a picture rather than writing.
        var backLooksLikePicture: Bool { backPaper <= 0.5 }
    }

    static func measure(front: ScannedPage, back: ScannedPage) -> Measurement {
        let front = paperShare(front), back = paperShare(back)
        return Measurement(frontPaper: front.share, backPaper: back.share, frontArea: front.area, backArea: back.area)
    }

    /// The share of sampled pixels off the dark backing that look like plain paper: light and
    /// close to neutral, which allows for paper that has yellowed.
    private static func paperShare(_ page: ScannedPage) -> (share: Double, area: Int) {
        let step = max(1, page.resolution / 50)
        var area = 0, paper = 0
        for y in stride(from: 0, to: page.height, by: step) {
            for x in stride(from: 0, to: page.width, by: step) {
                let i = (y * page.width + x) * 3
                let r = Int(page.rgb[i]), g = Int(page.rgb[i + 1]), b = Int(page.rgb[i + 2])
                let luma = (r * 299 + g * 587 + b * 114) / 1000
                let chroma = max(r, g, b) - min(r, g, b)
                if luma < 70, chroma < 20 { continue }
                area += 1
                if luma >= 150, chroma <= 50 { paper += 1 }
            }
        }
        return (area == 0 ? 0 : Double(paper) / Double(area), area)
    }
}
