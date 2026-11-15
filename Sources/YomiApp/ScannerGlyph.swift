import SwiftUI

/// The ScanSnap S1300 with its paper chute open, seen from the front right and slightly above.
/// Drawn in the current foreground style, with a gap around each part as SF Symbols do.
struct ScannerGlyph: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / Self.bounds.width, size.height / Self.bounds.height)
            context.translateBy(x: (size.width - Self.bounds.width * scale) / 2, y: (size.height - Self.bounds.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -Self.bounds.minX, y: -Self.bounds.minY)
            var gap = context
            gap.blendMode = .destinationOut
            for part in Self.parts {
                if part.separated {
                    gap.stroke(part.path, with: .foreground, style: StrokeStyle(lineWidth: Self.gapWidth, lineJoin: .round))
                }
                var fill = context
                fill.opacity = part.opacity
                fill.fill(part.path, with: .foreground)
            }
            gap.fill(Self.paperExit, with: .foreground)
            gap.fill(Self.scanButton, with: .foreground)
        }
        .aspectRatio(Self.bounds.width / Self.bounds.height, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private struct Part {
        var path: Path
        var opacity = 1.0
        var separated = true
    }

    // Model units, in proportion to the real scanner (284 × 77 × 99 mm). x runs across it, y up, and z back from its front.
    private static let width = 22.5
    private static let depth = 7.5
    /// Where the right end, which holds the Scan button, starts.
    private static let podStart = 19.6
    /// The front is a dark base holding the paper exit, under a light lip.
    private static let lipBottom = 2.0
    private static let frontTop = 3.9
    /// The cover slopes gently back from the top of the front to the chute's hinge at the back.
    private static let backHeight = 5.9
    /// The right end's top runs parallel to the cover, a little above it.
    private static let podFrontHeight = 4.4
    private static let podBackHeight = 6.4
    /// The chute sits inside the cover, inset by this on each side.
    private static let chuteInset = 1.2
    private static let chuteRise = 5.9
    private static let chuteLean = 2.3
    /// Each part's fill covers the inner half of its own gap stroke, so the visible gap is half this.
    private static let gapWidth = 1.3

    /// How far a point moves right and up on screen per unit of depth.
    private static let recedeX = 0.34
    private static let recedeY = 0.27

    private static func point(_ x: Double, _ y: Double, _ z: Double) -> CGPoint {
        CGPoint(x: x + recedeX * z, y: -y - recedeY * z)
    }

    private static func polygon(_ corners: [(Double, Double, Double)]) -> Path {
        var path = Path()
        path.addLines(corners.map { point($0.0, $0.1, $0.2) })
        path.closeSubpath()
        return path
    }

    /// Maps a shape drawn in the x–z plane onto a top surface that rises from `frontHeight` at z = 0 by `slope` per unit of depth.
    private static func onTop(frontHeight: Double, slope: Double) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: recedeX, d: -recedeY - slope, tx: 0, ty: -frontHeight)
    }

    private static let chute: Path = {
        let left = chuteInset
        let right = podStart - chuteInset
        let bottomLeft = point(left, backHeight, depth)
        let bottomRight = point(right, backHeight, depth)
        let topRight = point(right, backHeight + chuteRise, depth + chuteLean)
        let topLeft = point(left, backHeight + chuteRise, depth + chuteLean)
        var path = Path()
        path.move(to: bottomLeft)
        path.addLine(to: bottomRight)
        path.addArc(tangent1End: topRight, tangent2End: topLeft, radius: 0.35)
        path.addArc(tangent1End: topLeft, tangent2End: bottomLeft, radius: 0.35)
        path.closeSubpath()
        return path
    }()

    /// Back to front, so each part's gap cuts into the parts behind it.
    private static let parts: [Part] = [
        Part(path: chute, opacity: 0.45),
        // Right side.
        Part(path: polygon([(width, 0, 0), (width, 0, depth), (width, podBackHeight, depth), (width, podFrontHeight, 0)]), opacity: 0.55),
        // Cover.
        Part(path: polygon([(0, frontTop, 0), (podStart, frontTop, 0), (podStart, backHeight, depth), (0, backHeight, depth)]),
             opacity: 0.78),
        // Front: base, then lip.
        Part(path: polygon([(0, 0, 0), (podStart, 0, 0), (podStart, lipBottom, 0), (0, lipBottom, 0)]), opacity: 0.55),
        Part(path: polygon([(0, lipBottom, 0), (podStart, lipBottom, 0), (podStart, frontTop, 0), (0, frontTop, 0)]), separated: false),
        // Right end: a gap around the whole end, then its top and front told apart by shade alone.
        Part(path: polygon([(podStart, 0, 0), (width, 0, 0), (width, podFrontHeight, 0), (width, podBackHeight, depth),
                            (podStart, podBackHeight, depth), (podStart, podFrontHeight, 0)]),
             opacity: 0),
        Part(path: polygon([(podStart, podFrontHeight, 0), (width, podFrontHeight, 0), (width, podBackHeight, depth), (podStart, podBackHeight, depth)]),
             opacity: 0.78, separated: false),
        Part(path: polygon([(podStart, 0, 0), (width, 0, 0), (width, podFrontHeight, 0), (podStart, podFrontHeight, 0)]),
             opacity: 0.55, separated: false),
    ]

    private static let paperExit = Path(roundedRect: CGRect(x: 1.4, y: -1.6, width: podStart - gapWidth / 2 - 2.8, height: 1.1), cornerRadius: 0.2)

    /// A strip in the middle of the right end's top, running front to back.
    private static let scanButton = Path(roundedRect: CGRect(x: podStart + 0.85, y: 2.5, width: 1.2, height: 3.3), cornerRadius: 0.3)
        .applying(onTop(frontHeight: podFrontHeight, slope: (podBackHeight - podFrontHeight) / depth))

    private static let bounds = parts.reduce(CGRect.null) { $0.union($1.path.boundingRect) }
}
