import CoreGraphics
import CoreImage
import Foundation

/// Core Image rendering shared by the imaging steps.
enum ImageRendering {
    /// Works in extended linear sRGB at half-float precision, so colours outside sRGB survive until the page is
    /// rendered in its own colour space.
    static let wideGamutContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
    ])

    /// Renders `rect` of `image` in the colour space of `page`, as 8-bit gray for a gray page and RGBA otherwise.
    static func render(_ image: CIImage, from rect: CGRect, like page: CGImage, in context: CIContext) -> CGImage? {
        let space = page.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let format: CIFormat = space.model == .monochrome ? .L8 : .RGBA8
        return context.createCGImage(image, from: rect, format: format, colorSpace: space)
    }
}
