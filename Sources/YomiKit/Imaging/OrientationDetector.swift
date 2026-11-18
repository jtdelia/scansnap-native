import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

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
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: small, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        var orientations: [CGImagePropertyOrientation?] = []
        for line in request.results ?? [] {
            guard let text = line.topCandidates(1).first, text.confidence >= 0.5,
                  text.string.filter({ $0.isLetter || $0.isNumber }).count >= 3 else { continue }
            let dx = (line.topRight.x - line.topLeft.x) * CGFloat(small.width)
            let dy = (line.topRight.y - line.topLeft.y) * CGFloat(small.height)
            orientations.append(correction(forRoll: atan2(dy, dx)))
        }
        return agreed(orientations)
    }

    /// For each confidently detected face, the orientation that shows it upright, or nil when its
    /// roll is not close to a quarter turn.
    private static func faceOrientations(_ image: CGImage) -> [CGImagePropertyOrientation?] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).filter { $0.confidence >= 0.5 }.map { face in
            face.roll.flatMap { correction(forRoll: $0.doubleValue) }
        }
    }

    private static func correction(forRoll roll: Double) -> CGImagePropertyOrientation? {
        let degrees = roll * 180 / .pi
        let quarter = (degrees / 90).rounded()
        guard abs(degrees - quarter * 90) <= 30 else { return nil }
        switch (Int(quarter) % 4 + 4) % 4 {
        case 0: return .up
        case 1: return .right
        case 2: return .down
        default: return .left
        }
    }

    private static func agreed(_ orientations: [CGImagePropertyOrientation?]) -> CGImagePropertyOrientation? {
        let votes = Dictionary(grouping: orientations.compactMap(\.self), by: \.self).mapValues(\.count)
        guard let (orientation, count) = votes.max(by: { $0.value < $1.value }),
              count * 3 >= orientations.count * 2, orientation != .up
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
