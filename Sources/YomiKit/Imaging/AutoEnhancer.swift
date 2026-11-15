import CoreGraphics
import CoreImage
import Foundation

/// Core Image's auto-adjustments, the same ones as the magic-wand button in Photos.
public enum AutoEnhancer {
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
    ])

    /// `page` with the auto-adjustments applied, in the page's own colour space.
    static func enhance(_ page: ProcessedPage) throws -> ProcessedPage {
        let source = CIImage(cgImage: page.image)
        let image = source.autoAdjustmentFilters(options: [.redEye: false]).reduce(source) { image, filter in
            filter.setValue(image, forKey: kCIInputImageKey)
            return filter.outputImage ?? image
        }
        let space = page.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let format: CIFormat = space.model == .monochrome ? .L8 : .RGBA8
        guard let output = context.createCGImage(image, from: source.extent, format: format, colorSpace: space)
        else { throw ImageWriterError.cannotCreateImage }
        return ProcessedPage(image: output, resolution: page.resolution, isBlank: page.isBlank, source: page.source,
                             isColor: page.isColor, caption: page.caption)
    }
}
