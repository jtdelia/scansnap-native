import CoreGraphics
import CoreImage
import Foundation

/// Crops a print to its own edges against the scanner's backing. Pixels count as print when their
/// colour differs from the backing, so prints darker than the backing crop as well as light ones.
enum PrintCropper {
    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    static func crop(_ image: CIImage) -> (image: CIImage, foundPrint: Bool) {
        guard var mask = PrintMask(image) else { return (image, false) }
        var upright = image
        if let angle = mask.skewAngle(), abs(angle) > 0.0015, abs(angle) < 0.15 {
            let center = CGPoint(x: image.extent.midX, y: image.extent.midY)
            let rotation = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: angle)
                .translatedBy(x: -center.x, y: -center.y)
            let backing = CIImage(color: mask.backing).cropped(to: image.extent.insetBy(dx: -200, dy: -200))
            upright = image.transformed(by: rotation).composited(over: backing).cropped(to: image.extent)
            guard let straightened = PrintMask(upright) else { return (image, false) }
            mask = straightened
        }
        return crop(upright, to: mask)
    }

    private static func crop(_ image: CIImage, to mask: PrintMask) -> (image: CIImage, foundPrint: Bool) {
        guard let edges = mask.edges() else { return (image, false) }
        let scale = image.extent.width / CGFloat(mask.width)
        // Trims the boundary, where straightening blends print and backing over a pixel or two.
        let trim = 2.5
        let minX = edges.left + trim, maxX = edges.right + 1 - trim
        let minY = edges.top + trim, maxY = edges.bottom + 1 - trim
        guard maxX > minX, maxY > minY else { return (image, false) }
        // Mask rows run top-down; Core Image's origin is bottom-left. Rounds inwards.
        let left = (image.extent.minX + minX * scale).rounded(.up)
        let right = (image.extent.minX + maxX * scale).rounded(.down)
        let bottom = (image.extent.minY + (CGFloat(mask.height) - maxY) * scale).rounded(.up)
        let top = (image.extent.minY + (CGFloat(mask.height) - minY) * scale).rounded(.down)
        let rect = CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
        return (image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY)), true)
    }

    /// Which pixels of a downscaled copy differ from the backing colour measured around the frame.
    private struct PrintMask {
        let width: Int
        let height: Int
        let isPrint: [Bool]
        let backing: CIColor

        init?(_ image: CIImage, maxDimension: CGFloat = 1600) {
            let scale = min(1, maxDimension / max(image.extent.width, image.extent.height))
            let small = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            width = Int(small.extent.width)
            height = Int(small.extent.height)
            guard width > 16, height > 16 else { return nil }
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            PrintCropper.context.render(small, toBitmap: &rgba, rowBytes: width * 4, bounds: small.extent,
                                        format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))

            let frame = 4
            var border: [Int] = []
            for y in 0..<height {
                for x in 0..<width where x < frame || x >= width - frame || y < frame || y >= height - frame {
                    border.append(y * width + x)
                }
            }
            let backing = (0..<3).map { c in border.map { Int(rgba[$0 * 4 + c]) }.sorted()[border.count / 2] }
            self.backing = CIColor(red: CGFloat(backing[0]) / 255, green: CGFloat(backing[1]) / 255,
                                   blue: CGFloat(backing[2]) / 255, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
            let (r, g, b) = (backing[0], backing[1], backing[2])
            func distance(_ i: Int) -> Int {
                max(abs(Int(rgba[i * 4]) - r), abs(Int(rgba[i * 4 + 1]) - g), abs(Int(rgba[i * 4 + 2]) - b))
            }
            // The backing's own variation, so a noisy backing is not mistaken for print.
            let noise = border.map(distance).sorted()[border.count * 9 / 10]
            let threshold = max(12, noise * 3)
            var isPrint = [Bool](repeating: false, count: width * height)
            for i in 0..<(width * height) where distance(i) > threshold { isPrint[i] = true }
            self.isPrint = isPrint
        }

        /// Position along a line (of `count` pixels, `step` apart in the mask from `start`) where
        /// three consecutive print pixels begin, from the start or, `reversed`, from the end.
        private func firstRun(start: Int, step: Int, count: Int, reversed: Bool) -> Int? {
            var run = 0
            var first = 0
            for n in 0..<count {
                let p = reversed ? count - 1 - n : n
                if isPrint[start + p * step] {
                    if run == 0 { first = p }
                    run += 1
                    if run == 3 { return first }
                } else {
                    run = 0
                }
            }
            return nil
        }

        /// Edge positions per scan line, measured from each side over the middle 80% of the lines
        /// the print covers, so the rounded or skewed corners do not count.
        func edgePoints() -> (left: [(Int, Int)], right: [(Int, Int)], top: [(Int, Int)], bottom: [(Int, Int)]) {
            let rowHits = (0..<height).map { y in
                (firstRun(start: y * width, step: 1, count: width, reversed: false),
                 firstRun(start: y * width, step: 1, count: width, reversed: true))
            }
            let colHits = (0..<width).map { x in
                (firstRun(start: x, step: width, count: height, reversed: false),
                 firstRun(start: x, step: width, count: height, reversed: true))
            }
            func middle(_ hits: [Int]) -> Range<Int> {
                guard hits.count >= 10 else { return 0..<0 }
                return hits[hits.count / 10]..<hits[hits.count * 9 / 10]
            }
            let rows = middle(rowHits.indices.filter { rowHits[$0].0 != nil })
            let cols = middle(colHits.indices.filter { colHits[$0].0 != nil })
            // A hit on the frame itself means the print runs off the scan there.
            return (rows.compactMap { y in rowHits[y].0.flatMap { $0 > 0 ? (y, $0) : nil } },
                    rows.compactMap { y in rowHits[y].1.flatMap { $0 < width - 1 ? (y, $0) : nil } },
                    cols.compactMap { x in colHits[x].0.flatMap { $0 > 0 ? (x, $0) : nil } },
                    cols.compactMap { x in colHits[x].1.flatMap { $0 < height - 1 ? (x, $0) : nil } })
        }

        /// The rotation in radians that straightens the print (counter-clockwise positive, Core Image
        /// convention), from line fits of all four edges; nil when no edge can be measured.
        func skewAngle() -> CGFloat? {
            let points = edgePoints()
            // Mask rows run top-down. A print turned counter-clockwise by θ has side edges with
            // dx/dy = tan θ and top and bottom edges with dy/dx = -tan θ.
            let fits = [points.left, points.right].compactMap(robustSlope)
                + [points.top, points.bottom].compactMap(robustSlope).map { (slope: -$0.slope, weight: $0.weight) }
            let weight = fits.map(\.weight).reduce(0, +)
            guard weight > 0 else { return nil }
            return -CGFloat(atan(fits.map { $0.slope * $0.weight }.reduce(0, +) / weight))
        }

        /// Least-squares slope of edge position against scan line, refitted without points far from
        /// the first fit; the weight is the number of points kept.
        private func robustSlope(_ points: [(Int, Int)]) -> (slope: Double, weight: Double)? {
            func fit(_ points: [(Int, Int)]) -> (slope: Double, intercept: Double)? {
                guard points.count >= 20 else { return nil }
                let n = Double(points.count)
                let meanT = points.map { Double($0.0) }.reduce(0, +) / n
                let meanP = points.map { Double($0.1) }.reduce(0, +) / n
                let covariance = points.reduce(0) { $0 + (Double($1.0) - meanT) * (Double($1.1) - meanP) }
                let variance = points.reduce(0) { $0 + (Double($1.0) - meanT) * (Double($1.0) - meanT) }
                guard variance > 0 else { return nil }
                let slope = covariance / variance
                return (slope, meanP - slope * meanT)
            }
            guard let first = fit(points) else { return nil }
            let kept = points.filter { abs(Double($0.1) - (first.intercept + first.slope * Double($0.0))) <= 3 }
            return fit(kept).map { ($0.slope, Double(kept.count)) }
        }

        /// The median position of each edge; an edge the print runs off falls back to the frame.
        func edges() -> (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat)? {
            let points = edgePoints()
            func median(_ edge: [(Int, Int)], or fallback: Int) -> CGFloat {
                CGFloat(edge.isEmpty ? fallback : edge.map(\.1).sorted()[edge.count / 2])
            }
            guard !points.left.isEmpty || !points.right.isEmpty, !points.top.isEmpty || !points.bottom.isEmpty
            else { return nil }
            return (median(points.left, or: 0), median(points.right, or: width - 1),
                    median(points.top, or: 0), median(points.bottom, or: height - 1))
        }
    }
}
