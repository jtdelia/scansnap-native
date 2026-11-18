import CoreGraphics
import Foundation

package struct OCRDocumentOutput: Sendable {
    package let pdf: URL
    package let sidecars: [URL]
    package let pages: [PageFields]
}

extension PageFields {
    package var kind: PageKind {
        switch self {
        case .businessCard: .businessCard
        case .receipt: .receipt
        case .document: .document
        case .print: .print
        }
    }

    private var metadata: (title: String?, subject: String?, keywords: [String]) {
        switch self {
        case let .document(doc): (doc.title, doc.summary, ["Document"])
        case let .businessCard(card):
            (card.name ?? card.company, [card.company, card.department, card.title].compactMap { $0 }.joined(separator: ", "),
             ["Business card", card.name, card.company, card.email, card.date].compactMap { $0 })
        case let .receipt(receipt):
            (receipt.merchant, [receipt.date, receipt.total, receipt.currency].compactMap { $0 }.joined(separator: " "),
             ["Receipt", receipt.merchant, receipt.date, receipt.invoiceNumber].compactMap { $0 })
        case .print: (nil, nil, ["Print"])
        }
    }

    static func pdfInfo(_ pages: [Self]) -> [CFString: Any] {
        let metadata = pages.map(\.metadata)
        var info: [CFString: Any] = [:]
        info[kCGPDFContextTitle] = metadata.compactMap(\.title).first
        info[kCGPDFContextSubject] = metadata.compactMap(\.subject).filter { !$0.isEmpty }.first
        var seen = Set<String>()
        let keywords = metadata.flatMap(\.keywords).filter { seen.insert($0).inserted }
        if !keywords.isEmpty { info[kCGPDFContextKeywords] = keywords }
        return info
    }

    static func sidecars(_ pages: [Self]) throws -> [(ext: String, data: Data)] {
        let cards = pages.compactMap { page -> String? in
            guard case let .businessCard(card) = page, card != BusinessCardFields() else { return nil }
            return card.vCard
        }
        if !cards.isEmpty { return [("vcf", Data(cards.joined().utf8))] }
        let receipts = pages.compactMap { page -> ReceiptFields? in
            guard case let .receipt(receipt) = page, receipt != ReceiptFields() else { return nil }
            return receipt
        }
        guard !receipts.isEmpty else { return [] }
        var csv = "merchant,date,total,currency,tax8,tax10,invoiceNumber\r\n"
        for receipt in receipts {
            var merchant = receipt.merchant ?? ""
            let leadingSpace = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
            if let first = merchant.trimmingCharacters(in: leadingSpace).first, "=+-@".contains(first) {
                merchant = "'" + merchant
            }
            let row = [merchant, receipt.date, receipt.total, receipt.currency, receipt.tax8, receipt.tax10, receipt.invoiceNumber]
            csv += row.map { value in
                "\"" + (value ?? "").replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: ",") + "\r\n"
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return [("csv", Data(csv.utf8)), ("json", try encoder.encode(receipts))]
    }
}

private extension BusinessCardFields {
    var vCard: String {
        func escape(_ text: String?) -> String {
            (text ?? "").replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,")
                .components(separatedBy: .newlines).joined(separator: "\\n")
        }
        var lines = ["BEGIN:VCARD", "VERSION:3.0", "FN:" + escape(name ?? company ?? email), "N:" + escape(name) + ";;;;"]
        if company != nil || department != nil { lines.append("ORG:" + escape(company) + ";" + escape(department)) }
        if address != nil || postalCode != nil || region != nil {
            lines.append("ADR;TYPE=WORK:;;" + escape(address) + ";;;" + escape(postalCode) + ";" + escape(region))
        }
        let properties = [("TITLE", title), ("TEL;TYPE=WORK", phone), ("TEL;TYPE=CELL", mobile), ("TEL;TYPE=FAX", fax),
                          ("EMAIL", email), ("URL", website), ("NOTE", memo), ("X-PHONETIC-FIRST-NAME", nameReading),
                          ("X-PHONETIC-ORG", companyReading), ("X-BUSINESS-CARD-DATE", date)]
        for (key, value) in properties where value != nil { lines.append(key + ":" + escape(value)) }
        lines.append("END:VCARD")
        var text = ""
        for line in lines {
            var bytes = 0
            for scalar in line.unicodeScalars {
                if bytes + scalar.utf8.count > 75 {
                    text += "\r\n "
                    bytes = 1
                }
                text.unicodeScalars.append(scalar)
                bytes += scalar.utf8.count
            }
            text += "\r\n"
        }
        return text
    }
}
