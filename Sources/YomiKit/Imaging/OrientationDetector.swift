import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

/// Detects pages fed upside down or sideways by comparing text recognition in each orientation,
/// and prints fed that way by the roll of the faces in them.
public enum OrientationDetector {
    private static let context = CIContext()

    /// Returns a rotated copy when another orientation reads clearly better, otherwise nil.
    public static func upright(_ image: CGImage) -> CGImage? {
        guard let small = downscaled(image, maxDimension: 1400) else { return nil }
        return textOrientation(small).flatMap { rotated(image, $0) }
    }

    /// Returns a rotated copy when the faces agree on another orientation, or, when there are no
    /// faces, when text reads clearly better in one; otherwise nil.
    public static func uprightPhoto(_ image: CGImage) -> CGImage? {
        guard let small = downscaled(image, maxDimension: 1400) else { return nil }
        let faces = faceOrientations(small)
        let orientation = faces.isEmpty ? textOrientation(small) : agreed(faces)
        return orientation.flatMap { rotated(image, $0) }
    }

    private static func textOrientation(_ small: CGImage) -> CGImagePropertyOrientation? {
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
        return best.0 == .up ? nil : best.0
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

    /// For each confidently detected face, the orientation that shows it upright, or nil when its
    /// roll is not close to a quarter turn.
    private static func faceOrientations(_ image: CGImage) -> [CGImagePropertyOrientation?] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).filter { $0.confidence >= 0.5 }.map { face in
            guard let roll = face.roll?.doubleValue else { return nil }
            let degrees = roll * 180 / .pi
            let quarter = (degrees / 90).rounded()
            guard abs(degrees - quarter * 90) <= 30 else { return nil }
            // A face with a roll of +90° reads upright when the image is shown as `.right`.
            switch (Int(quarter) % 4 + 4) % 4 {
            case 0: return .up
            case 1: return .right
            case 2: return .down
            default: return .left
            }
        }
    }

    /// The orientation at least two thirds of the faces agree on, unless that is upright.
    private static func agreed(_ faces: [CGImagePropertyOrientation?]) -> CGImagePropertyOrientation? {
        let votes = Dictionary(grouping: faces.compactMap(\.self), by: \.self).mapValues(\.count)
        guard let (orientation, count) = votes.max(by: { $0.value < $1.value }),
              count * 3 >= faces.count * 2, orientation != .up
        else { return nil }
        return orientation
    }

    private static func rotated(_ image: CGImage, _ orientation: CGImagePropertyOrientation) -> CGImage? {
        let rotated = CIImage(cgImage: image).oriented(orientation)
        return ImageRendering.render(rotated, from: rotated.extent, like: image, in: context)
    }

    private static func downscaled(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let scale = min(1, maxDimension / max(input.extent.width, input.extent.height))
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(small, from: small.extent)
    }
}
