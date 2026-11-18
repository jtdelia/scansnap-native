import Foundation

/// The pieces and typed text a scan profile uses to name its files.
public struct FileNamePattern: Codable, Hashable, Sendable, ExpressibleByArrayLiteral {
    public enum Piece: Codable, Hashable, Sendable {
        case text(String)
        /// `2026-11-14`
        case date
        /// `21.42.05`
        case time
        case year, month, day
        case profileName
        /// The scan profile's counter, which advances by one per file written.
        case runningNumber
        /// The number, within the batch, of the first page in the file.
        case pageNumber
        case titleText, merchant, pageDate, pageKind

        /// Pieces other than typed text, in the order the editor offers them.
        public static let all: [Piece] = [.date, .time, .year, .month, .day, .profileName, .runningNumber, .pageNumber,
                                          .titleText, .merchant, .pageDate, .pageKind]

        /// Pieces a subfolder pattern offers: the same for every file in a batch, so a batch never spreads
        /// across folders.
        public static let batchWide: [Piece] = [.date, .year, .month, .day, .profileName]

        public var title: String {
            switch self {
            case let .text(text): text
            case .date: "Date"
            case .time: "Time"
            case .year: "Year"
            case .month: "Month"
            case .day: "Day"
            case .profileName: "Scan profile name"
            case .runningNumber: "Running number"
            case .pageNumber: "Page number"
            case .titleText: "Title"
            case .merchant: "Merchant or company"
            case .pageDate: "Page date"
            case .pageKind: "Page kind"
            }
        }

        /// Name used in saved settings and in the editor's `{token}` syntax.
        var token: String? {
            switch self {
            case .text: nil
            case .date: "date"
            case .time: "time"
            case .year: "year"
            case .month: "month"
            case .day: "day"
            case .profileName: "profile"
            case .runningNumber: "number"
            case .pageNumber: "page"
            case .titleText: "title"
            case .merchant: "merchant"
            case .pageDate: "pageDate"
            case .pageKind: "kind"
            }
        }

        private enum CodingKeys: String, CodingKey { case text }

        public init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self) {
                self = try .text(container.decode(String.self, forKey: .text))
                return
            }
            let token = try decoder.singleValueContainer().decode(String.self)
            guard let piece = Piece.all.first(where: { $0.token == token }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Unknown name pattern piece \(token)"))
            }
            self = piece
        }

        public func encode(to encoder: Encoder) throws {
            if case let .text(text) = self {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(text, forKey: .text)
            } else {
                var container = encoder.singleValueContainer()
                try container.encode(token)
            }
        }
    }

    public var pieces: [Piece]

    public init(_ pieces: [Piece]) {
        self.pieces = pieces
    }

    public init(arrayLiteral pieces: Piece...) {
        self.pieces = pieces
    }

    public init(from decoder: Decoder) throws {
        pieces = try decoder.singleValueContainer().decode([Piece].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(pieces)
    }

    /// The ready-made "Date and time" pattern: `2026-11-14 21.42.05`.
    public static let dateAndTime: FileNamePattern = [.date, .text(" "), .time]

    /// The ready-made "Name and number" pattern: `Scan 001`.
    public static func nameAndNumber(_ name: String) -> FileNamePattern {
        let name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? [.runningNumber] : [.text("\(name) "), .runningNumber]
    }

    /// What earlier versions' "Date and time" choice became for JPEG, which always added a page number.
    static let dateTimeAndPage: FileNamePattern = [.date, .text(" "), .time, .text("_"), .pageNumber]

    /// The pattern as the editor shows it, with pieces written as `{token}`.
    public var editorText: String {
        pieces.map { piece in piece.token.map { "{\($0)}" } ?? piece.title }.joined()
    }

    /// Reads the editor's text. Braces that do not name a piece stay typed text.
    public init(editorText: String) {
        var pieces: [Piece] = []
        func append(_ text: Substring) {
            guard !text.isEmpty else { return }
            if case let .text(previous) = pieces.last {
                pieces[pieces.count - 1] = .text(previous + text)
            } else {
                pieces.append(.text(String(text)))
            }
        }
        var rest = editorText[...]
        while let open = rest.firstIndex(of: "{") {
            append(rest[..<open])
            let afterOpen = rest.index(after: open)
            if let close = rest[afterOpen...].firstIndex(of: "}"),
               let piece = Piece.all.first(where: { $0.token == String(rest[afterOpen..<close]) }) {
                pieces.append(piece)
                rest = rest[rest.index(after: close)...]
            } else {
                append(rest[open..<afterOpen])
                rest = rest[afterOpen...]
            }
        }
        append(rest)
        self.pieces = pieces
    }

    public var usesRunningNumber: Bool { pieces.contains(.runningNumber) }

    /// Whether every file in a batch gets its own number from the pattern itself.
    var numbersFiles: Bool { usesRunningNumber || pieces.contains(.pageNumber) }

    /// The values that fill a pattern's pieces for one file.
    struct Values: Codable {
        var date: Date
        var profileName: String
        var runningNumber: Int
        var numberDigits: Int
        var pageNumber: Int
    }

    var usesPageFields: Bool {
        pieces.contains { [.titleText, .merchant, .pageDate, .pageKind].contains($0) }
    }

    func render(_ values: Values, fields: [PageFields] = []) -> String {
        let formatter = DateFormatter()
        func format(_ dateFormat: String) -> String {
            formatter.dateFormat = dateFormat
            return formatter.string(from: values.date)
        }
        func value(_ piece: Piece) -> String? {
            switch piece {
            case let .text(text): text
            case .date: format("yyyy-MM-dd")
            case .time: format("HH.mm.ss")
            case .year: format("yyyy")
            case .month: format("MM")
            case .day: format("dd")
            case .profileName: values.profileName
            case .runningNumber: String(format: "%0\(max(1, values.numberDigits))d", values.runningNumber)
            case .pageNumber: String(format: "%03d", values.pageNumber)
            case .titleText: fields.lazy.compactMap(\.nameTitle).first
            case .merchant: fields.lazy.compactMap(\.merchant).first
            case .pageDate: fields.lazy.compactMap(\.pageDate).first
            case .pageKind: fields.first?.kindName
            }
        }
        var result = ""
        var separator = ""
        var omitted = false
        for piece in pieces {
            if case let .text(text) = piece, text.allSatisfy({ $0.isWhitespace || $0.isPunctuation }) {
                if !omitted { separator += text }
            } else if let text = value(piece) {
                result += separator + text
                separator = ""
                omitted = false
            } else {
                omitted = true
            }
        }
        return result + (omitted ? "" : separator)
    }
}
