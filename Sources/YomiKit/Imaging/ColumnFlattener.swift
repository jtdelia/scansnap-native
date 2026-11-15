import Foundation

/// Host-side shading correction in sensor-column space.
///
/// The scanner's own calibration flattens its internal reference, but real paper still shows
/// low-frequency gradients, colour bands and dust lines along the feed direction (measured
/// ±10–20 levels on this S1300). Every pixel in a column comes from the same sensor element, so
/// scaling each column so its paper-white matches a common target removes those artefacts.
/// ScanSnap Manager performs a comparable host-side pass using PRNU data from the scanner EEPROM.
public enum ColumnFlattener {
    public static func flatten(_ page: ScannedPage, target: Double = 248, percentile: Double = 0.92) -> ScannedPage {
        let width = page.width, height = page.height
        guard width > 64, height > 64 else { return page }

        var whites = [[Double]](repeating: [Double](repeating: 0, count: width), count: 3)
        page.rgb.withUnsafeBufferPointer { rgb in
            var histogram = [Int](repeating: 0, count: width * 3 * 256)
            var samples = 0
            for y in stride(from: 0, to: height, by: 3) {
                samples += 1
                let row = y * width * 3
                for x in 0..<width {
                    for c in 0..<3 {
                        histogram[(x * 3 + c) * 256 + Int(rgb[row + x * 3 + c])] += 1
                    }
                }
            }
            let rank = Int(Double(samples) * percentile)
            for x in 0..<width {
                for c in 0..<3 {
                    var cumulative = 0
                    let base = (x * 3 + c) * 256
                    for level in 0..<256 {
                        cumulative += histogram[base + level]
                        if cumulative > rank { whites[c][x] = Double(level); break }
                    }
                }
            }
        }

        // Columns outside the sheet see the darker backing; give them their nearest paper column's
        // gain so the backing stays distinguishable for cropping.
        let luminance = (0..<width).map { (whites[0][$0] + whites[1][$0] + whites[2][$0]) / 3 }
        let paperLevel = luminance.sorted()[width / 2]
        let isPaper = luminance.map { $0 > paperLevel * 0.88 }
        guard let first = isPaper.firstIndex(of: true), let last = isPaper.lastIndex(of: true), last - first > width / 4
        else { return page }

        var lut = [[UInt8]](repeating: [], count: width * 3)
        for c in 0..<3 {
            let smoothed = medianFilter(whites[c], radius: 2)
            for x in 0..<width {
                let source = min(max(x, first), last)
                let white = isPaper[source] ? smoothed[source] : paperLevel
                let gain = min(1.35, max(0.9, target / max(white, 1)))
                lut[x * 3 + c] = (0..<256).map { UInt8(min(255, (Double($0) * gain).rounded())) }
            }
        }

        var output = page.rgb
        output.withUnsafeMutableBufferPointer { pixels in
            for y in 0..<height {
                let row = y * width * 3
                for i in 0..<(width * 3) {
                    pixels[row + i] = lut[i][Int(pixels[row + i])]
                }
            }
        }
        return ScannedPage(side: page.side, sheetIndex: page.sheetIndex, width: width, height: height,
                           resolution: page.resolution, rgb: output)
    }

    private static func medianFilter(_ values: [Double], radius: Int) -> [Double] {
        values.indices.map { i in
            let window = values[max(0, i - radius)...min(values.count - 1, i + radius)].sorted()
            return window[window.count / 2]
        }
    }
}
