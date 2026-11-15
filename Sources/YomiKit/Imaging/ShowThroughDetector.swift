import Foundation

/// Models and removes ink from one side of a sheet showing through on the other side.
///
/// Both sides are captured in one pass and aligned row-for-row, so show-through on a side is a
/// faded, slightly blurred horizontal mirror of the opposite side. We find the alignment (coarse at
/// 1/8 scale, refined at 1/2 scale), fit how strongly the other side shows through, and then either
/// decide the side is blank (nothing left after removing the fit) or add the predicted show-through
/// back so the paper becomes clean while real ink stays.
public enum ShowThroughDetector {
    public struct Fit: Sendable {
        /// Offset into the mirrored other side, in full-resolution pixels.
        public let dx: Int
        public let dy: Int
        /// Fraction of the other side's ink that shows through.
        public let strength: Double
        public let correlation: Double
        /// Share of the target that is darker than explained by show-through.
        public let residualInk: Double

        public var isShowThroughOnly: Bool { residualInk < 0.002 }
    }

    public static func isShowThroughOnly(back: ScannedPage, front: ScannedPage) -> Bool {
        analyze(target: back, other: front)?.isShowThroughOnly ?? false
    }

    /// Fits `target ≈ paper − strength × mirrored(other ink)`.
    public static func analyze(target: ScannedPage, other: ScannedPage) -> Fit? {
        guard let coarseTarget = InkMap(target, factor: 8), let coarseOther = InkMap(other, factor: 8),
              coarseTarget.width == coarseOther.width else { return nil }
        let coarse = bestShift(coarseTarget, coarseOther, center: (0, 0), radius: 4, step: 1)

        guard let fineTarget = InkMap(target, factor: 2), let fineOther = InkMap(other, factor: 2) else { return nil }
        let fine = bestShift(fineTarget, fineOther, center: (coarse.dx * 4, coarse.dy * 4), radius: 6, step: 3)

        // Strength = median ratio where the other side has strong ink and the target does not have
        // its own content. Weak other-side ink is skipped: it is mostly the target's own content
        // showing back through, which would inflate the estimate.
        var ratios: [Double] = []
        fineTarget.forEachPair(with: fineOther, dx: fine.dx, dy: fine.dy, step: 2) { t, o in
            guard o > 80, t < 60 else { return }
            ratios.append(t / o)
        }
        let strength = ratios.count >= 200 ? min(0.3, ratios.sorted()[ratios.count / 2]) : 0

        var residual = 0, total = 0
        fineTarget.forEachPair(with: fineOther, dx: fine.dx, dy: fine.dy, step: 2) { t, o in
            total += 1
            if t - strength * o > 45 { residual += 1 }
        }
        return Fit(dx: fine.dx * 2, dy: fine.dy * 2, strength: strength, correlation: fine.correlation,
                   residualInk: total > 0 ? Double(residual) / Double(total) : 1)
    }

    /// Returns `target` with the predicted show-through of `other` added back (per channel).
    public static func remove(from target: ScannedPage, other: ScannedPage, fit: Fit) -> ScannedPage {
        guard fit.strength > 0.01, fit.correlation > 0.2 else { return target }
        let factor = 2
        let ow = other.width / factor, oh = other.height / factor
        guard ow > 8, oh > 8 else { return target }

        // Per-channel ink of the other side at half resolution (box filter doubles as blur).
        let paper = paperLevels(other)
        var ink = [[Float]](repeating: [Float](repeating: 0, count: ow * oh), count: 3)
        other.rgb.withUnsafeBufferPointer { rgb in
            for y in 0..<oh {
                for x in 0..<ow {
                    for c in 0..<3 {
                        var sum = 0
                        for sy in 0..<factor {
                            let row = ((y * factor + sy) * other.width + x * factor) * 3
                            for sx in 0..<factor { sum += Int(rgb[row + sx * 3 + c]) }
                        }
                        ink[c][y * ow + x] = max(0, Float(paper[c]) - Float(sum) / Float(factor * factor))
                    }
                }
            }
        }
        let blurred = ink.map { boxBlur($0, width: ow, height: oh, radius: 1) }

        let strength = Float(fit.strength)
        let targetPaper = paperLevels(target).map(Float.init)
        var output = target.rgb
        let width = target.width
        output.withUnsafeMutableBufferPointer { pixels in
            for y in 0..<target.height {
                let oy = (y + fit.dy) / factor
                guard oy >= 0, oy < oh else { continue }
                for x in 0..<width {
                    let ox = (other.width - 1 - x + fit.dx) / factor
                    guard ox >= 0, ox < ow else { continue }
                    let source = oy * ow + ox
                    let p = (y * width + x) * 3
                    for c in 0..<3 {
                        let lift = min(70, strength * blurred[c][source])
                        guard lift >= 1 else { continue }
                        // Pixels much darker than the predicted show-through are real ink: leave them.
                        let ownInk = targetPaper[c] - Float(pixels[p + c])
                        let weight = min(1, max(0, (lift * 1.6 + 30 - ownInk) / 20))
                        if weight > 0 {
                            pixels[p + c] = UInt8(min(255, Float(pixels[p + c]) + lift * weight))
                        }
                    }
                }
            }
        }
        return ScannedPage(side: target.side, sheetIndex: target.sheetIndex, width: width,
                           height: target.height, resolution: target.resolution, rgb: output)
    }

    // MARK: Internals

    private static func bestShift(_ target: InkMap, _ other: InkMap, center: (Int, Int), radius: Int, step: Int)
        -> (dx: Int, dy: Int, correlation: Double) {
        var best = (dx: center.0, dy: center.1, correlation: -1.0)
        for dy in (center.1 - radius)...(center.1 + radius) {
            for dx in (center.0 - radius)...(center.0 + radius) {
                var sumT = 0.0, sumO = 0.0, sumTT = 0.0, sumOO = 0.0, sumTO = 0.0, n = 0.0
                target.forEachPair(with: other, dx: dx, dy: dy, step: step) { t, o in
                    sumT += t; sumO += o; sumTT += t * t; sumOO += o * o; sumTO += t * o; n += 1
                }
                guard n > 0 else { continue }
                let covariance = sumTO - sumT * sumO / n
                let variance = (sumTT - sumT * sumT / n) * (sumOO - sumO * sumO / n)
                let correlation = variance > 0 ? covariance / variance.squareRoot() : 0
                if correlation > best.correlation { best = (dx, dy, correlation) }
            }
        }
        return best
    }

    private static func paperLevels(_ page: ScannedPage) -> [Int] {
        var histograms = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
        page.rgb.withUnsafeBufferPointer { rgb in
            for i in stride(from: 0, to: rgb.count, by: 3 * 7) {
                for c in 0..<3 { histograms[c][Int(rgb[i + c])] += 1 }
            }
        }
        return histograms.map { histogram in
            let total = histogram.reduce(0, +)
            var cumulative = 0
            for level in 0..<256 {
                cumulative += histogram[level]
                if cumulative >= total * 9 / 10 { return level }
            }
            return 255
        }
    }

    private static func boxBlur(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var horizontal = [Float](repeating: 0, count: values.count)
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0, count: Float = 0
                for k in max(0, x - radius)...min(width - 1, x + radius) { sum += values[y * width + k]; count += 1 }
                horizontal[y * width + x] = sum / count
            }
        }
        var output = [Float](repeating: 0, count: values.count)
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0, count: Float = 0
                for k in max(0, y - radius)...min(height - 1, y + radius) { sum += horizontal[k * width + x]; count += 1 }
                output[y * width + x] = sum / count
            }
        }
        return output
    }

    /// Box-downsampled luminance converted to darkness below the page's paper level.
    private struct InkMap {
        let width: Int
        let height: Int
        let values: [Double]

        init?(_ page: ScannedPage, factor: Int) {
            width = page.width / factor
            height = page.height / factor
            guard width > 32, height > 32 else { return nil }
            var luminance = [Double](repeating: 0, count: width * height)
            let (w, h, pageWidth) = (width, height, page.width)
            page.rgb.withUnsafeBufferPointer { rgb in
                for y in 0..<h {
                    for x in 0..<w {
                        var total = 0
                        for sy in 0..<factor {
                            let row = ((y * factor + sy) * pageWidth + x * factor) * 3
                            for sx in 0..<factor {
                                let p = row + sx * 3
                                total += Int(rgb[p]) * 2 + Int(rgb[p + 1]) * 5 + Int(rgb[p + 2])
                            }
                        }
                        luminance[y * w + x] = Double(total) / Double(8 * factor * factor)
                    }
                }
            }
            let paper = luminance.sorted()[luminance.count * 9 / 10]
            values = luminance.map { max(0, paper - $0) }
        }

        /// Visits (target, mirrored-other) pairs inside a 2% margin.
        func forEachPair(with other: InkMap, dx: Int, dy: Int, step: Int, _ body: (Double, Double) -> Void) {
            let marginX = width / 50 + abs(dx), marginY = height / 50 + abs(dy)
            guard width - 2 * marginX > 0, min(height, other.height) - 2 * marginY > 0 else { return }
            for y in stride(from: marginY, to: min(height, other.height) - marginY, by: step) {
                let oy = y + dy
                guard oy >= 0, oy < other.height else { continue }
                for x in stride(from: marginX, to: width - marginX, by: step) {
                    let ox = other.width - 1 - x + dx
                    guard ox >= 0, ox < other.width else { continue }
                    body(values[y * width + x], other.values[oy * other.width + ox])
                }
            }
        }
    }
}
