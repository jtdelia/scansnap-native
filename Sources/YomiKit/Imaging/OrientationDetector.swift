import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

/// Detects pages fed upside down or sideways by comparing text recognition in each orientation.
public enum OrientationDetector {
    private static let context = CIContext()

    /// Returns a rotated copy when another orientation reads clearly better, otherwise nil.
    public static func upright(_ image: CGImage) -> CGImage? {
        guard let small = downscaled(image, maxDimension: 1400) else { return nil }
        let upScore = score(small, .up)
        let downScore = score(small, .down)
        var best: (CGImagePropertyOrientation, Double) = (.up, upScore)
        if downScore > best.1 * 1.5 + 2 { best = (.down, downScore) }
        if max(upScore, downScore) < 8 {
            for orientation in [CGImagePropertyOrientation.left, .right] {
                let value = score(small, orientation)
                if value > best.1 * 1.5 + 2 { best = (orientation, value) }
            }
        }
        guard best.0 != .up else { return nil }
        let rotated = CIImage(cgImage: image).oriented(best.0)
        let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let format: CIFormat = space.model == .monochrome ? .L8 : .RGBA8
        return context.createCGImage(rotated, from: rotated.extent, format: format, colorSpace: space)
    }

    /// Sum of confidences of recognized lines with at least three characters.
    private static func score(_ image: CGImage, _ orientation: CGImagePropertyOrientation) -> Double {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        guard (try? handler.perform([request])) != nil else { return 0 }
        return (request.results ?? []).reduce(0) { total, observation in
            guard let candidate = observation.topCandidates(1).first, candidate.string.count >= 3 else { return total }
            return total + Double(candidate.confidence)
        }
    }

    private static func downscaled(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let scale = min(1, maxDimension / max(input.extent.width, input.extent.height))
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(small, from: small.extent)
    }
}
