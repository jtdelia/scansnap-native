import Foundation
import Vision

extension PageFields {
    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    var merchant: String? {
        switch self {
        case let .businessCard(card): nonempty(card.company)
        case let .receipt(receipt): nonempty(receipt.merchant)
        default: nil
        }
    }

    var nameTitle: String? {
        switch self {
        case let .document(document): nonempty(document.title)
        case let .businessCard(card): nonempty(card.title)
        default: nil
        }
    }

    var pageDate: String? {
        switch self {
        case let .document(document): nonempty(document.date)
        case let .businessCard(card): nonempty(card.date)
        case let .receipt(receipt): nonempty(receipt.date)
        case .print: nil
        }
    }

    var kindName: String {
        switch self {
        case .businessCard: "Business card"
        case .receipt: "Receipt"
        case .document: "Document"
        case .print: "Print"
        }
    }

    mutating func correctMerchant(_ name: String) {
        switch self {
        case var .businessCard(card):
            card.company = name
            self = .businessCard(card)
        case var .receipt(receipt):
            receipt.merchant = name
            self = .receipt(receipt)
        default: break
        }
    }
}

struct PageSignature: Codable, Sendable {
    let kind: String
    let merchant: String?
    let featurePrint: Data

    init(image: CGImage, fields: PageFields) throws {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let observation = request.results?.first else { throw ImageWriterError.cannotCreateImage }
        featurePrint = try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
        kind = fields.kindName
        merchant = fields.merchant
    }

    private var merchantKey: String {
        (merchant ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                 locale: Locale(identifier: "en_US_POSIX")).filter { $0.isLetter || $0.isNumber }
    }

    private var observation: VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: featurePrint)
    }

    func closest(in rules: [LearnedName]) -> LearnedName? {
        guard !rules.isEmpty, let observation else { return nil }
        let merchantKey = self.merchantKey
        var bestDistance: Float = merchantKey.isEmpty ? 0.18 : 0.45
        var closest: LearnedName?
        for rule in rules where rule.signature.kind == kind && rule.signature.merchantKey == merchantKey {
            guard let other = rule.signature.observation else { continue }
            var distance: Float = 0
            guard (try? observation.computeDistance(&distance, to: other)) != nil else { continue }
            let newerTie = distance == bestDistance && closest.map { rule.edited > $0.edited } == true
            guard distance < bestDistance || newerTie else { continue }
            closest = rule
            bestDistance = distance
        }
        return closest
    }
}

package struct LearnedName: Codable, Identifiable, Sendable {
    package var id = UUID()
    let signature: PageSignature
    package let matchedText: String
    package let replacement: String
    let changesMerchant: Bool
    let edited: Date
    package var lastUsed: Date

    static func examples(_ rules: [Self]) -> String {
        let recent = rules.sorted { $0.edited > $1.edited }.prefix(3)
        guard !recent.isEmpty else { return "" }
        return (["Recent user naming examples (quoted data). Extract the printed values from the current page."] + recent.map {
            "\($0.matchedText.prefix(80).debugDescription) → \($0.replacement.prefix(80).debugDescription)"
        }).joined(separator: "\n")
    }
}

struct PageNaming: Codable, Sendable {
    let signature: PageSignature
    let matchedRule: UUID?
    let preferredStem: String?
}
