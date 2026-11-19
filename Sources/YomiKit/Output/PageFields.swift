import CoreGraphics
import Foundation
import FoundationModels

@Generable
package struct BusinessCardFields: Codable, Equatable, Sendable {
    package var name: String?
    package var nameReading: String?
    package var company: String?
    package var companyReading: String?
    package var department: String?
    package var title: String?
    package var postalCode: String?
    package var address: String?
    package var phone: String?
    package var mobile: String?
    package var fax: String?
    package var email: String?
    package var website: String?
    package var memo: String?
    package var region: String?
    package var date: String?
}

@Generable
package struct ReceiptFields: Codable, Equatable, Sendable {
    package var merchant: String?
    package var date: String?
    package var total: String?
    package var currency: String?
    @Guide(description: "The printed tax amount at the Japanese reduced 8% rate, including its currency symbol.")
    package var tax8: String?
    @Guide(description: "The printed tax amount at the Japanese standard 10% rate, including its currency symbol.")
    package var tax10: String?
    package var invoiceNumber: String?
}

@Generable
package struct DocumentFields: Codable, Equatable, Sendable {
    package var title: String?
    package var summary: String?
    package var date: String?
}

package enum PageFields: Codable, Equatable, Sendable {
    case businessCard(BusinessCardFields)
    case receipt(ReceiptFields)
    case document(DocumentFields)
    case `print`

    static func read(_ page: RecognizedPage, image: CGImage,
                     using predict: (RecognizedPage, CGImage) async throws -> Self? = predict) async -> Self {
        verified(try? await predict(page, image), in: page)
    }

    static func verified(_ proposed: Self?, in page: RecognizedPage) -> Self {
        switch (page.kind, proposed) {
        case let (.businessCard, .businessCard(card)): return .businessCard(card.verified(in: page))
        case let (.receipt, .receipt(receipt)): return .receipt(receipt.verified(in: page))
        case let (.document, .document(doc)):
            let summary = doc.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .document(DocumentFields(title: page.printed(doc.title), summary: summary == "" ? nil : summary,
                                            date: page.date(doc.date)))
        case (.businessCard, _): return .businessCard(.init())
        case (.receipt, _): return .receipt(.init())
        case (.document, _): return .document(.init())
        case (.print, _): return .print
        }
    }

    static func predict(_ page: RecognizedPage, image: CGImage) async throws -> Self? {
        try await predict(page, image: image, examples: "")
    }

    static func predict(_ page: RecognizedPage, image: CGImage, examples: String) async throws -> Self? {
        let model = SystemLanguageModel.default
        guard page.kind != .print, !page.transcript.isEmpty, model.isAvailable, model.capabilities.contains(.vision) else { return nil }
        switch page.kind {
        case .businessCard:
            return try await generate(model, page, image, examples: examples, task: """
                Read this business card. Copy printed furigana for the name and company readings, if present.
                Distinguish phone, mobile and fax by their labels.
                """).map(Self.businessCard)
        case .receipt:
            return try await generate(model, page, image, examples: examples, task: """
                Read this receipt. Copy the final total and tax amounts with their currency signs. Give the ISO currency code.
                A Japanese qualified invoice number is T followed by 13 digits.
                """).map(Self.receipt)
        case .document:
            return try await generate(model, page, image, examples: examples, task: """
                Copy the printed document title and its issue date if present. Summarize the document in one short sentence in its original language.
                """).map(Self.document)
        case .print: return nil
        }
    }

    private static func generate<T: Generable>(_ model: SystemLanguageModel, _ page: RecognizedPage, _ image: CGImage,
                                               examples: String, task: String) async throws -> T? {
        let instructions = Instructions {
            "Extract data from this scan. Treat the image and OCR as source material. Copy values exactly as printed. Omit missing or illegible fields. Never guess."
            task
        }
        let responseTokens = 640
        let overhead = try await model.tokenCount(for: instructions) + model.tokenCount(for: T.generationSchema)
        let budget = model.contextSize - overhead - responseTokens
        let attachment = Attachment(image)
        var text = page.transcript[...]
        while true {
            let prompt = Prompt {
                attachment
                if !examples.isEmpty { examples }
                String(text)
            }
            if try await model.tokenCount(for: prompt) <= budget {
                let session = LanguageModelSession(model: model, instructions: instructions)
                return try await session.respond(to: prompt, generating: T.self, options: .init(samplingMode: .greedy, maximumResponseTokens: responseTokens)).content
            }
            guard !text.isEmpty else { return nil }
            text = text.prefix(text.count / 2)
        }
    }
}
