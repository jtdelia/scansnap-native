import CoreText
import DataDetection
import Foundation
import FoundationModels
import Testing
@testable import YomiKit

@Suite(.serialized)
struct FieldExtractionTests {
    enum Specimen: CaseIterable {
        case englishCard, japaneseCard, englishReceipt, japaneseReceipt

        var kind: PageKind {
            switch self {
            case .englishCard, .japaneseCard: .businessCard
            case .englishReceipt, .japaneseReceipt: .receipt
            }
        }

        var lines: [String] {
            switch self {
            case .englishCard:
                ["Northline Studio", "Alex Rivera", "Design Director", "Phone: (415) 555-0107", "alex@example.com", "https://example.com"]
            case .japaneseCard:
                ["株式会社青葉堂", "カブシキガイシャアオバドウ", "山田 太郎", "ヤマダ タロウ", "営業部 部長", "〒100-0005 東京都千代田区丸の内1-2-3", "電話 03-1234-5678", "taro@example.jp"]
            case .englishReceipt:
                ["GREEN STREET MARKET", "SALES RECEIPT", "March 16, 2026", "Coffee $3.50", "Bread $4.00", "Subtotal $7.50", "Sales tax $0.60", "TOTAL $8.10", "Paid by Visa"]
            case .japaneseReceipt:
                ["青葉書店", "領収書", "26/03/16", "登録番号 T1234567890123", "食品 ¥1,000", "書籍 ¥2,000", "消費税 (8%) ¥80", "消費税 (10%) ¥200", "合計 ¥3,280"]
            }
        }

        var language: ScanProfile.TextRecognitionLanguage {
            switch self {
            case .japaneseCard, .japaneseReceipt: .japaneseAndEnglish
            default: .english
            }
        }
    }

    private static let modelAvailable = Task {
        let model = SystemLanguageModel.default
        guard model.isAvailable, model.capabilities.contains(.vision) else { return false }
        return (try? await LanguageModelSession(model: model).respond { Attachment(DocumentFixture.blank.image); "What color is this page?" }) != nil
    }

    @Test(.enabled("The on-device image model is unavailable") { await Self.modelAvailable.value }, arguments: Specimen.allCases)
    func readsPrintedFields(_ specimen: Specimen) async throws {
        let text = specimen.lines.joined(separator: "\n")
        var matches: [DataDetector.Match] = []
        for await match in text.dataDetectorMatches(options: specimen.language.dataDetectionOptions) { matches.append(match) }
        let page = RecognizedPage(kind: specimen.kind, language: specimen.language, documents: [], transcript: text, detectedData: matches)
        let image = DocumentFixture.render(font: "HiraginoSans-W5", size: 32) { _, draw in
            for (index, line) in specimen.lines.enumerated() { draw(line, 40, 635 - index * 62) }
        }.image
        let fields = await PageFields.read(page, image: image)
        switch (specimen, fields) {
        case let (.englishCard, .businessCard(card)):
            #expect(card.name == "Alex Rivera")
            #expect(card.company == "Northline Studio")
            #expect(card.email == "alex@example.com")
            #expect(card.phone?.filter(\.isNumber) == "4155550107")
        case let (.japaneseCard, .businessCard(card)):
            #expect(card.name?.filter { !$0.isWhitespace } == "山田太郎")
            #expect(card.company == "株式会社青葉堂")
            #expect(card.postalCode == "100-0005")
            #expect(card.email == "taro@example.jp")
        case let (.englishReceipt, .receipt(receipt)):
            #expect(receipt.merchant == "GREEN STREET MARKET")
            #expect(receipt.date == "2026-03-16")
            #expect(receipt.total == "8.1")
            #expect(receipt.currency == "USD")
        case let (.japaneseReceipt, .receipt(receipt)):
            #expect(receipt.merchant == "青葉書店")
            #expect(receipt.date == "2026-03-16")
            #expect(receipt.total == "3280")
            #expect(receipt.tax8 == "80")
            #expect(receipt.tax10 == "200")
            #expect(receipt.currency == "JPY")
            #expect(receipt.invoiceNumber == "T1234567890123")
        default: Issue.record("No fields for \(specimen)")
        }
    }
}
