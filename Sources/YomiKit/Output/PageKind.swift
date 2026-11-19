import CoreGraphics
import FoundationModels

@Generable
package enum PageKind: Codable {
    case document
    case businessCard
    case receipt
    case print

    static func classify(_ image: CGImage, resolution: Int, foundPrint: Bool,
                         using predict: (CGImage, CGSize, Bool) async throws -> Self? = predict) async -> Self {
        let mmPerPixel = 25.4 / Double(resolution)
        let size = CGSize(width: Double(image.width) * mmPerPixel, height: Double(image.height) * mmPerPixel)
        if let kind = try? await predict(image, size, foundPrint) { return kind }
        let shortEdge = min(size.width, size.height), longEdge = max(size.width, size.height)
        return abs(shortEdge - 55) <= 6 && abs(longEdge - 91) <= 6 ? .businessCard : .document
    }

    static func predict(_ image: CGImage, size: CGSize, foundPrint: Bool) async throws -> Self? {
        let model = SystemLanguageModel.default
        guard model.isAvailable, model.capabilities.contains(.vision) else { return nil }
        let session = LanguageModelSession(model: model)
        return try await session.respond(generating: Self.self, options: .init(samplingMode: .greedy)) {
            Attachment(image)
            "The scanned sheet measures \(Int(size.width.rounded())) by \(Int(size.height.rounded())) mm."
            if foundPrint { "The photo pipeline detected a print." }
            """
            What is shown in this image? Choose print for a photograph of a person or scene, \
            receipt for proof of purchase, businessCard for a contact card (about 91 by 55 mm), \
            or document for other written material such as a letter.
            """
        }.content
    }
}
