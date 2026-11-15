import SwiftUI

/// The ScanSnap S1300 with its paper chute open, seen from the front right and slightly above.
/// Drawn in the current foreground style, with a gap around each part as SF Symbols do.
struct ScannerGlyph: View {
    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / Self.gridWidth, y: size.height / Self.gridHeight)
            var gap = context
            gap.blendMode = .destinationOut
            for part in Self.parts {
                gap.stroke(part.path, with: .foreground, style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
                var fill = context
                fill.opacity = part.opacity
                fill.fill(part.path, with: .foreground)
            }
            gap.fill(Self.scanButton, with: .foreground)
        }
        .aspectRatio(Self.gridWidth / Self.gridHeight, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private struct Part {
        var path: Path
        var opacity = 1.0
    }

    private static let gridWidth = 32.0
    private static let gridHeight = 20.0

    // Scanner dimensions in grid units: width, height, depth, and where the end cap with the Scan button starts.
    private static let width = 26.0
    private static let height = 5.0
    private static let depth = 7.0
    private static let capStart = 21.5
    private static let lidFront = 2.2

    /// Oblique projection with x across the scanner, y up, and z into its depth, from its front bottom left corner.
    private static func point(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
        CGPoint(x: 0.5 + x + 0.45 * z, y: gridHeight - 0.5 - y - 0.4 * z)
    }

    private static func polygon(_ corners: [(Double, Double, Double)]) -> Path {
        var path = Path()
        path.addLines(corners.map { point($0.0, $0.1, $0.2) })
        path.closeSubpath()
        return path
    }

    /// Back to front, so each part's gap cuts into the parts behind it.
    private static let parts: [Part] = [
        Part(path: polygon([(1.5, height, 4.5), (20, height, 4.5), (20, height + 9.5, depth + 3), (1.5, height + 9.5, depth + 3)]),
             opacity: 0.5),
        Part(path: polygon([(width, 0, 0), (width, 0, depth), (width, height, depth), (width, height, 2)]), opacity: 0.55),
        Part(path: polygon([(0, 0, 0), (capStart, 0, 0), (capStart, lidFront, 0), (0, lidFront, 0)])),
        Part(path: polygon([(0, lidFront, 0), (capStart, lidFront, 0), (capStart, height, 2), (0, height, 2)])),
        Part(path: polygon([(0, height, 2), (capStart, height, 2), (capStart, height, depth), (0, height, depth)])),
        Part(path: polygon([(capStart, 0, 0), (width, 0, 0), (width, height, 2), (width, height, depth),
                            (capStart, height, depth), (capStart, height, 2), (capStart, lidFront, 0)])),
    ]

    private static let scanButton = Path(ellipseIn: CGRect(origin: point(23, 2.2, 0.9), size: CGSize(width: 1.6, height: 1.6))
        .offsetBy(dx: 0, dy: -0.8))
}
