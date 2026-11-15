import CoreGraphics
import CoreImage
import Foundation

public struct ProcessingOptions: Sendable, Codable, Equatable {
    public var flattenColumns = true
    public var cropAndStraighten = true
    public var whiteBalance = true
    public var reduceBleedThrough = false
    /// Resample pages within a small tolerance of a standard paper size to exactly that size.
    public var snapToStandardSize = true
    /// Deepen text blacks and whiten paper (off for photos).
    public var documentTone = true
    public var autoRotate = true
    public var colorMode: ScanProfile.ColorMode = .auto
    /// Decides the saved resolution (Automatic and Better scan at 300 dpi and downsample).
    public var quality: ScanProfile.Quality = .fine
    public var skipBlankPages = true
    /// Fraction of the page area that must contain ink for a page to count as non-blank.
    public var blankInkFraction = 0.0015

    public init() {}
}

public struct ProcessedPage: @unchecked Sendable {
    public let image: CGImage
    public let resolution: Int
    public let isBlank: Bool
    public let source: ScannedPage.Side
    public let isColor: Bool
}

public enum PageProcessor {
    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    public static func process(_ page: ScannedPage, options: ProcessingOptions) throws -> ProcessedPage {
        let corrected = options.flattenColumns ? ColumnFlattener.flatten(page) : page
        return try process(try corrected.cgImage(), resolution: page.resolution, side: page.side, options: options)
    }

    public static func process(_ source: CGImage, resolution: Int, side: ScannedPage.Side,
                               options: ProcessingOptions) throws -> ProcessedPage {
        var image = CIImage(cgImage: source)

        if options.cropAndStraighten {
            image = cropToPaper(image, resolution: resolution, snap: options.snapToStandardSize)
        }
        // Page length is measured in the feed direction, as ScanSnap Manager does.
        let outputResolution = options.quality.outputDPI(pageLengthInches: image.extent.height / CGFloat(resolution))
        if outputResolution < resolution {
            image = resample(image, scale: CGFloat(outputResolution) / CGFloat(resolution))
        }
        let resolution = outputResolution
        if options.whiteBalance {
            image = balanceWhite(image)
        }
        // Document tone curve: the scanner's black is only ~40/255, so deepen shadows for crisp
        // text, and lift near-white paper texture and faint remaining show-through to white.
        let knee: CGFloat = options.reduceBleedThrough ? 0.92 : 0.95
        if options.documentTone { image = image.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: 0.2, y: 0.08),
            "inputPoint2": CIVector(x: 0.5, y: 0.44),
            "inputPoint3": CIVector(x: knee - 0.12, y: knee - 0.1),
            "inputPoint4": CIVector(x: knee, y: 1.0),
        ]) }

        let isColor: Bool
        switch options.colorMode {
        case .color: isColor = true
        case .gray, .blackAndWhite: isColor = false
        case .auto: isColor = hasColor(image)
        }
        if !isColor {
            image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        }
        if options.colorMode == .blackAndWhite {
            image = image.applyingFilter("CIColorThresholdOtsu")
        }

        let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        guard var output = isColor
            ? context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: rgb)
            : context.createCGImage(image, from: image.extent.integral, format: .L8, colorSpace: gray)
        else { throw ImageWriterError.cannotCreateImage }

        if options.cropAndStraighten {
            output = cleanEdges(output, resolution: resolution)
        }
        let blank = options.skipBlankPages && inkFraction(output) < options.blankInkFraction
        if options.autoRotate, !blank, let rotated = OrientationDetector.upright(output) {
            output = rotated
        }
        return ProcessedPage(image: output, resolution: resolution, isBlank: blank, source: side, isColor: isColor)
    }

    // MARK: Crop and deskew

    /// Straightens the sheet using its left/right edges against the darker backing, crops to the
    /// paper edges and, when close to a standard size, resamples to exactly that size.
    static func cropToPaper(_ image: CIImage, resolution: Int, snap: Bool) -> CIImage {
        var upright = image
        if let angle = skewAngle(image), abs(angle) > 0.0015, abs(angle) < 0.15 {
            let center = CGPoint(x: image.extent.midX, y: image.extent.midY)
            let rotation = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: angle)
                .translatedBy(x: -center.x, y: -center.y)
            let backing = CIImage(color: .black).cropped(to: image.extent.insetBy(dx: -200, dy: -200))
            upright = image.transformed(by: rotation).composited(over: backing).cropped(to: image.extent)
        }
        let cropped = cropToPaperEdges(upright)
        return snap ? snapToStandardSize(cropped, resolution: resolution) : cropped
    }

    /// Standard sheet sizes in inches (portrait).
    static let standardSizes: [(name: String, width: Double, height: Double)] = [
        ("Letter", 8.5, 11), ("Legal", 8.5, 14), ("A4", 8.268, 11.693), ("A5", 5.827, 8.268),
        ("Executive", 7.25, 10.5), ("B5", 7.165, 10.118), ("Statement", 5.5, 8.5),
    ]

    /// Resamples to the nearest standard size if within feed tolerance (paper can scan slightly
    /// long because of feed slip), otherwise returns the image unchanged.
    static func snapToStandardSize(_ image: CIImage, resolution: Int) -> CIImage {
        let dpi = Double(resolution)
        let width = image.extent.width / dpi, height = image.extent.height / dpi
        let match = standardSizes.first { size in
            abs(width - size.width) <= 0.15 && abs(height - size.height) <= 0.25
        } ?? standardSizes.first { size in
            abs(width - size.height) <= 0.25 && abs(height - size.width) <= 0.15
        }
        guard let size = match else { return image }
        let landscape = abs(width - size.width) > 0.15
        let target = CGSize(width: (landscape ? size.height : size.width) * dpi,
                            height: (landscape ? size.width : size.height) * dpi)
        let sx = target.width.rounded() / image.extent.width
        let sy = target.height.rounded() / image.extent.height
        let scaled = image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: sy,
            kCIInputAspectRatioKey: sx / sy,
        ])
        let rect = CGRect(origin: scaled.extent.origin, size: CGSize(width: target.width.rounded(), height: target.height.rounded()))
        let result = scaled.cropped(to: rect)
        return result.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// Skew in radians (counter-clockwise positive, Core Image convention) from a line fit of the
    /// paper's left and right edges; nil when the edges cannot be measured.
    static func skewAngle(_ image: CIImage) -> CGFloat? {
        guard let gray = renderGray(image, maxDimension: 1200) else { return nil }
        guard let threshold = paperThreshold(gray) else { return nil }
        var left: [(Double, Double)] = [], right: [(Double, Double)] = []
        let rows = stride(from: gray.height / 10, to: gray.height * 9 / 10, by: max(1, gray.height / 200))
        for y in rows {
            let row = y * gray.width
            if let x = (0..<gray.width / 3).first(where: { Int(gray.pixels[row + $0]) > threshold }), x > 0 {
                left.append((Double(y), Double(x)))
            }
            if let x = stride(from: gray.width - 1, to: gray.width * 2 / 3, by: -1)
                .first(where: { Int(gray.pixels[row + $0]) > threshold }), x < gray.width - 1 {
                right.append((Double(y), Double(x)))
            }
        }
        let slopes = [left, right].compactMap(robustSlope)
        guard !slopes.isEmpty else { return nil }
        // x grows rightwards per row going down; in Core Image (y up) that is a clockwise tilt.
        return CGFloat(atan(slopes.reduce(0, +) / Double(slopes.count)))
    }

    /// Least-squares slope dx/dy after discarding points far from the median edge position.
    private static func robustSlope(_ points: [(Double, Double)]) -> Double? {
        guard points.count >= 20 else { return nil }
        let median = points.map(\.1).sorted()[points.count / 2]
        let kept = points.filter { abs($0.1 - median) < 25 }
        guard kept.count >= 20 else { return nil }
        let n = Double(kept.count)
        let meanY = kept.map(\.0).reduce(0, +) / n, meanX = kept.map(\.1).reduce(0, +) / n
        let covariance = kept.reduce(0) { $0 + ($1.0 - meanY) * ($1.1 - meanX) }
        let variance = kept.reduce(0) { $0 + ($1.0 - meanY) * ($1.0 - meanY) }
        return variance > 0 ? covariance / variance : nil
    }

    /// Crops to the paper using each edge's median position across all scan lines, so page
    /// content near an edge cannot pull the crop inwards; trims a hair to remove any backing.
    static func cropToPaperEdges(_ image: CIImage) -> CIImage {
        guard let gray = renderGray(image, maxDimension: 1800), let threshold = paperThreshold(gray, position: 0.75) else { return image }
        let w = gray.width, h = gray.height
        func bright(_ x: Int, _ y: Int) -> Bool { Int(gray.pixels[y * w + x]) > threshold }
        func paperRun(_ positions: StrideTo<Int>, _ at: (Int) -> Bool) -> Int? {
            // First position that starts three consecutive paper pixels.
            var run = 0
            var start: Int?
            for p in positions {
                if at(p) {
                    if run == 0 { start = p }
                    run += 1
                    if run == 3 { return start }
                } else {
                    run = 0
                }
            }
            return nil
        }
        func median(_ values: [Int]) -> Int? { values.isEmpty ? nil : values.sorted()[values.count / 2] }

        let rows = stride(from: h / 10, to: h * 9 / 10, by: max(1, h / 300))
        let cols = stride(from: w / 10, to: w * 9 / 10, by: max(1, w / 300))
        let left = median(rows.compactMap { y in paperRun(stride(from: 0, to: w / 3, by: 1)) { bright($0, y) } })
        let right = median(rows.compactMap { y in paperRun(stride(from: w - 1, to: w * 2 / 3, by: -1)) { bright($0, y) } })
        let top = median(cols.compactMap { x in paperRun(stride(from: 0, to: h / 3, by: 1)) { bright(x, $0) } })
        let bottom = median(cols.compactMap { x in paperRun(stride(from: h - 1, to: h * 2 / 3, by: -1)) { bright(x, $0) } })

        let scale = image.extent.width / CGFloat(w)
        let trim = 1.0 + 8.0 / scale
        let minX = CGFloat(left ?? 0) + trim, maxX = CGFloat(right ?? (w - 1)) + 1 - trim
        let minY = CGFloat(top ?? 0) + trim, maxY = CGFloat(bottom ?? (h - 1)) + 1 - trim
        guard maxX - minX > CGFloat(w) / 4, maxY - minY > CGFloat(h) / 4 else { return image }
        // Gray rows run top-down; Core Image's origin is bottom-left.
        let rect = CGRect(x: image.extent.minX + minX * scale,
                          y: image.extent.minY + (CGFloat(h) - maxY) * scale,
                          width: (maxX - minX) * scale,
                          height: (maxY - minY) * scale).integral
        let cropped = image.cropped(to: rect)
        return cropped.transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// Lanczos resample to an exact pixel size, keeping the origin at zero.
    static func resample(_ image: CIImage, scale: CGFloat) -> CIImage {
        let target = CGSize(width: (image.extent.width * scale).rounded(), height: (image.extent.height * scale).rounded())
        let scaled = image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: target.height / image.extent.height,
            kCIInputAspectRatioKey: (target.width / image.extent.width) / (target.height / image.extent.height),
        ])
        let rect = CGRect(origin: scaled.extent.origin, size: target)
        return scaled.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    // MARK: Edge cleanup

    /// Whitens shadows and backing slivers that touch the page border (curled corners, edge shadow).
    /// Walking in from each border stops at the first white pixel, or gives up after 0.12" so real
    /// content near an edge is never touched.
    static func cleanEdges(_ image: CGImage, resolution: Int) -> CGImage {
        let width = image.width, height = image.height
        let gray = image.colorSpace?.model == .monochrome
        let channels = gray ? 1 : 4
        let space = gray ? CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)! : CGColorSpace(name: CGColorSpace.sRGB)!
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * channels, space: space, bitmapInfo: info),
              let data = context.data else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * channels)

        let maxDepth = max(4, resolution * 12 / 100)
        let white: Int = 232
        func luminance(_ x: Int, _ y: Int) -> Int {
            let p = (y * width + x) * channels
            return gray ? Int(pixels[p]) : (Int(pixels[p]) * 2 + Int(pixels[p + 1]) * 5 + Int(pixels[p + 2])) / 8
        }
        func whiten(_ x: Int, _ y: Int) {
            let p = (y * width + x) * channels
            for c in 0..<min(3, channels) { pixels[p + c] = 255 }
        }
        func sweep(count: Int, depth: Int, point: (Int, Int) -> (Int, Int)) {
            for i in 0..<count {
                var d = 0
                while d < depth {
                    let (x, y) = point(i, d)
                    if luminance(x, y) >= white { break }
                    d += 1
                }
                guard d < depth else { continue }
                for k in 0..<d { let (x, y) = point(i, k); whiten(x, y) }
            }
        }
        sweep(count: width, depth: min(maxDepth, height / 4)) { ($0, $1) }
        sweep(count: width, depth: min(maxDepth, height / 4)) { ($0, height - 1 - $1) }
        sweep(count: height, depth: min(maxDepth, width / 4)) { ($1, $0) }
        sweep(count: height, depth: min(maxDepth, width / 4)) { (width - 1 - $1, $0) }
        return context.makeImage() ?? image
    }

    // MARK: White balance

    /// Maps the paper colour (bright percentile per channel) to near-white.
    static func balanceWhite(_ image: CIImage) -> CIImage {
        guard let sample = renderRGB(image, maxDimension: 600) else { return image }
        var gains: [CGFloat] = []
        for channel in 0..<3 {
            var histogram = [Int](repeating: 0, count: 256)
            for i in stride(from: channel, to: sample.count, by: 4) { histogram[Int(sample[i])] += 1 }
            let target = sample.count / 4 * 80 / 100
            var cumulative = 0, level = 255
            for value in 0..<256 {
                cumulative += histogram[value]
                if cumulative >= target { level = value; break }
            }
            gains.append(min(1.25, max(1.0, 250.0 / CGFloat(max(level, 1)))))
        }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gains[0], y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gains[1], z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gains[2], w: 0),
        ]).cropped(to: image.extent)
    }

    // MARK: Colour detection

    /// True when more than 0.3% of sampled pixels are clearly chromatic.
    static func hasColor(_ image: CIImage) -> Bool {
        guard let sample = renderRGB(image, maxDimension: 500) else { return true }
        var chromatic = 0
        for i in stride(from: 0, to: sample.count, by: 4) {
            let r = Int(sample[i]), g = Int(sample[i + 1]), b = Int(sample[i + 2])
            if max(r, g, b) - min(r, g, b) > 40 { chromatic += 1 }
        }
        return Double(chromatic) / Double(sample.count / 4) > 0.003
    }

    // MARK: Blank detection

    /// Share of pixels clearly darker than the paper, ignoring a 4% border.
    public static func inkFraction(_ image: CGImage) -> Double {
        guard let gray = renderGray(CIImage(cgImage: image), maxDimension: 700) else { return 1 }
        let histogram = gray.pixels.reduce(into: [Int](repeating: 0, count: 256)) { $0[Int($1)] += 1 }
        var cumulative = 0, paper = 255
        for value in 0..<256 {
            cumulative += histogram[value]
            if cumulative >= gray.pixels.count / 2 { paper = value; break }
        }
        let inkLevel = paper - 60
        let marginX = gray.width * 4 / 100, marginY = gray.height * 4 / 100
        var ink = 0, total = 0
        for y in marginY..<(gray.height - marginY) {
            for x in marginX..<(gray.width - marginX) {
                total += 1
                if Int(gray.pixels[y * gray.width + x]) < inkLevel { ink += 1 }
            }
        }
        return total == 0 ? 0 : Double(ink) / Double(total)
    }

    // MARK: Helpers

    private struct GrayBitmap { let width: Int; let height: Int; let pixels: [UInt8] }

    private static func scaled(_ image: CIImage, maxDimension: CGFloat) -> CIImage {
        let scale = min(1, maxDimension / max(image.extent.width, image.extent.height))
        return image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private static func renderGray(_ image: CIImage, maxDimension: CGFloat) -> GrayBitmap? {
        let small = scaled(image, maxDimension: maxDimension)
        let width = Int(small.extent.width), height = Int(small.extent.height)
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        context.render(small, toBitmap: &pixels, rowBytes: width, bounds: small.extent,
                       format: .L8, colorSpace: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        return GrayBitmap(width: width, height: height, pixels: pixels)
    }

    private static func renderRGB(_ image: CIImage, maxDimension: CGFloat) -> [UInt8]? {
        let small = scaled(image, maxDimension: maxDimension)
        let width = Int(small.extent.width), height = Int(small.extent.height)
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(small, toBitmap: &pixels, rowBytes: width * 4, bounds: small.extent,
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return pixels
    }

    /// Midpoint between the scanner backing (outer frame) and the paper (centre), or nil if they
    /// are too similar to separate.
    /// `position` picks the threshold between backing (0) and paper (1).
    private static func paperThreshold(_ gray: GrayBitmap, position: Double = 0.5) -> Int? {
        func median(_ values: [UInt8]) -> Int { Int(values.sorted()[values.count / 2]) }
        let frame = 4
        var border: [UInt8] = []
        for y in 0..<gray.height {
            for x in 0..<gray.width where x < frame || x >= gray.width - frame || y < frame || y >= gray.height - frame {
                border.append(gray.pixels[y * gray.width + x])
            }
        }
        var centre: [UInt8] = []
        for y in (gray.height / 4)..<(gray.height * 3 / 4) {
            for x in (gray.width / 4)..<(gray.width * 3 / 4) { centre.append(gray.pixels[y * gray.width + x]) }
        }
        let backing = median(border), paper = median(centre)
        return paper - backing >= 25 ? backing + Int(Double(paper - backing) * position) : nil
    }
}
