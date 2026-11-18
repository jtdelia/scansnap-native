import DataDetection
import Foundation

private func compact(_ text: String) -> String {
    text.folding(options: .widthInsensitive, locale: nil).filter { !$0.isWhitespace }
}

extension RecognizedPage {
    func printed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              compact(transcript).contains(compact(value)) else { return nil }
        return value
    }

    fileprivate func match(_ value: String?, candidates: (DataDetector.Match.SemanticDetails, String) -> [String]) -> String? {
        guard let value, !compact(value).isEmpty else { return nil }
        for match in detectedData {
            guard let range = match.range else { continue }
            for candidate in candidates(match.details, String(transcript[range])) where compact(value) == compact(candidate) {
                return candidate
            }
        }
        return nil
    }

    fileprivate func phone(_ value: String?) -> String? {
        guard let value else { return nil }
        let dial = compact(value)
        guard dial.range(of: #"^[+()0-9.\-]+$"#, options: .regularExpression) != nil else { return nil }
        let digits = dial.filter(\.isNumber)
        for match in detectedData {
            if case let .phoneNumber(phone) = match.details, !digits.isEmpty, digits == phone.phoneNumber.filter(\.isNumber) {
                return phone.phoneNumber
            }
        }
        return nil
    }

    func date(_ value: String?) -> String? {
        guard let value else { return nil }
        let japanese = language == .japaneseAndEnglish || (language == .automatic &&
            transcript.range(of: #"[\p{Hiragana}\p{Katakana}\p{Han}¥￥]"#, options: .regularExpression) != nil)
        for match in detectedData {
            guard case let .calendarEvent(event) = match.details, let range = match.range, let start = event.startDate else { continue }
            let printed = String(transcript[range]).folding(options: .widthInsensitive, locale: nil)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = event.startTimeZone ?? .current
            var parts = calendar.dateComponents([.year, .month, .day], from: start)
            var matchedDate = printed
            if japanese, let short = printed.range(of: #"(?<![0-9])[0-9]{2}/[0-9]{2}/[0-9]{2}(?![0-9])"#, options: .regularExpression) {
                matchedDate = String(printed[short])
                let numbers = matchedDate.split(separator: "/").compactMap { Int($0) }
                parts = DateComponents(year: 2000 + numbers[0], month: numbers[1], day: numbers[2])
                guard parts.isValidDate(in: calendar) else { continue }
            }
            guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
            let iso = String(format: "%04d-%02d-%02d", year, month, day)
            if value == iso || compact(value) == compact(matchedDate) || compact(value) == compact(printed) { return iso }
        }
        return nil
    }

    fileprivate func money(_ value: String?, taxRate: Int? = nil) -> (amount: String, currency: String)? {
        guard let value else { return nil }
        let bare = compact(value)
        let isNumber = bare.range(of: #"^-?(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]+)?$"#, options: .regularExpression) != nil
        let number = isNumber ? Decimal(string: bare.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX")) : nil
        for match in detectedData {
            guard case let .moneyAmount(money) = match.details, let range = match.range,
                  compact(value) == compact(String(transcript[range])) || money.amount == number else { continue }
            if let taxRate {
                let text = transcript as NSString
                let row = text.lineRange(for: NSRange(range, in: transcript))
                var label = compact(text.substring(with: row))
                if label == compact(String(transcript[range])) {
                    label = transcript[..<range.lowerBound].split(whereSeparator: \.isNewline)
                        .last(where: { !$0.allSatisfy(\.isWhitespace) }).map { compact(String($0)) } ?? ""
                }
                guard label.range(of: "(?<![0-9])\(taxRate)%", options: .regularExpression) != nil else { continue }
            }
            let amount = NSDecimalNumber(decimal: money.amount).stringValue
            let currency = money.currency.identifier.uppercased()
            guard currency != "JPY" || !amount.contains(".") else { continue }
            return (amount, currency)
        }
        return nil
    }
}

extension BusinessCardFields {
    func verified(in page: RecognizedPage) -> Self {
        var card = self
        card.name = page.printed(name)
        card.nameReading = page.printed(nameReading)
        card.company = page.printed(company)
        card.companyReading = page.printed(companyReading)
        card.department = page.printed(department)
        card.title = page.printed(title)
        card.region = page.printed(region)
        card.memo = page.printed(memo)
        card.phone = page.phone(phone)
        card.mobile = page.phone(mobile)
        card.fax = page.phone(fax)
        card.email = page.match(email) { details, _ in
            if case let .emailAddress(email) = details { [email.emailAddress] } else { [] }
        }
        card.website = page.match(website) { details, printed in
            if case let .link(link) = details { [printed, link.url.absoluteString] } else { [] }
        }
        let code = postalCode?.trimmingCharacters(in: CharacterSet(charactersIn: "〒").union(.whitespacesAndNewlines))
        card.postalCode = page.match(code) { details, _ in
            guard case let .postalAddress(address) = details, let code = address.postalCode else { return [] }
            return [code]
        }
        card.address = page.match(address) { details, printed in
            guard case let .postalAddress(address) = details else { return [] }
            let withoutCode = printed.replacingOccurrences(of: address.postalCode ?? "", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "〒").union(.whitespacesAndNewlines))
            return [printed, withoutCode, address.fullAddress, address.street].compactMap { $0 }
        }
        card.date = page.date(date)
        return card
    }
}

extension ReceiptFields {
    func verified(in page: RecognizedPage) -> Self {
        let amount = page.money(total)
        let reduced = page.money(tax8, taxRate: 8)
        let standard = page.money(tax10, taxRate: 10)
        let detectedCurrency = amount?.currency ?? reduced?.currency ?? standard?.currency
        let invoice = page.printed(invoiceNumber)
        let validInvoice = invoice.flatMap { number -> String? in
            guard number.range(of: #"^T[0-9]{13}$"#, options: .regularExpression) != nil,
                  page.transcript.range(of: "\(number)(?![0-9])", options: .regularExpression) != nil else { return nil }
            return number
        }
        return Self(merchant: page.printed(merchant), date: page.date(date), total: amount?.amount,
                    currency: detectedCurrency,
                    tax8: reduced?.currency == "JPY" ? reduced?.amount : nil,
                    tax10: standard?.currency == "JPY" ? standard?.amount : nil,
                    invoiceNumber: validInvoice)
    }
}
