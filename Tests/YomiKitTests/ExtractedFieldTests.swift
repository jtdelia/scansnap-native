import DataDetection
import Foundation
import FoundationModels
import Testing
@testable import YomiKit

struct ExtractedFieldTests {
    private func page(_ transcript: String, kind: PageKind, language: ScanProfile.TextRecognitionLanguage = .japaneseAndEnglish) async -> RecognizedPage {
        var matches: [DataDetector.Match] = []
        for await match in transcript.dataDetectorMatches(options: language.dataDetectionOptions) {
            matches.append(match)
        }
        return RecognizedPage(kind: kind, language: language, documents: [], transcript: transcript, detectedData: matches)
    }

    @Test func receiptRejectsDisagreementsAndValidatesShortJapaneseDates() async throws {
        let recognized = await page("領収書\n青葉書店\n26/03/16\n合計 ¥1,280\n登録番号 T1234567890123", kind: .receipt)
        let fields = ReceiptFields(merchant: "青葉書店", date: "26/03/16", total: "¥1,280", currency: "JPY",
                                   tax8: "¥250", invoiceNumber: "T9999999999999").verified(in: recognized)
        #expect(fields.merchant == "青葉書店")
        #expect(fields.date == "2026-03-16")
        #expect(fields.total == "1280")
        #expect(fields.currency == "JPY")
        #expect(fields.tax8 == nil)
        #expect(fields.invoiceNumber == nil)
        #expect(ReceiptFields(date: "2016-03-26").verified(in: recognized).date == nil)
    }

    @Test func exportDefaultsOffWhenDecodingOldProfiles() throws {
        let profile = try JSONDecoder().decode(ScanProfile.self, from: Data(#"{"name":"Old"}"#.utf8))
        #expect(!profile.exportFields)
    }

    @Test func japaneseProfileReadsYearFirstOnLatinReceipts() async {
        let recognized = await page("SHOP\n03/04/05", kind: .receipt)
        #expect(ReceiptFields(date: "03/04/05").verified(in: recognized).date == "2003-04-05")
        #expect(ReceiptFields(date: "2005-03-04").verified(in: recognized).date == nil)
    }

    @Test func onlyMatchingContactDetailsSurvive() async {
        let recognized = await page("〒100-0005 東京都千代田区丸の内1-2-3\n電話 03-1234-5678\ninfo@example.jp\nhttps://example.jp", kind: .businessCard)
        let card = BusinessCardFields(postalCode: "〒100-0005", address: "東京都千代田区丸の内1-2-3", phone: "0312345678",
                                      mobile: "090-5555-5555", email: "other@example.jp", website: "https://example.jp/wrong")
            .verified(in: recognized)
        #expect(card.postalCode == "100-0005")
        #expect(card.address == "東京都千代田区丸の内1-2-3")
        #expect(card.phone == "03-1234-5678")
        #expect(card.mobile == nil)
        #expect(card.email == nil)
        #expect(card.website == nil)
        #expect(BusinessCardFields(address: "東京都新宿区").verified(in: recognized).address == nil)
    }

    @Test func absentAndOverContextModelsReturnTheClassifiedKind() async {
        let text = String(repeating: "Receipt for the garden harvest.\n", count: 2500)
        let page = RecognizedPage(kind: .receipt, language: .automatic, documents: [], transcript: text, detectedData: [])
        let image = DocumentFixture.blank.image
        let unavailable = await PageFields.read(page, image: image) { _, _ in nil }
        let overContext = await PageFields.read(page, image: image) { _, _ in
            throw LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 4200, debugDescription: "Long receipt"))
        }
        #expect(unavailable == .receipt(.init()))
        #expect(overContext == unavailable)
    }
}
