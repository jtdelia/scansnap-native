import CoreGraphics
import Foundation
import Vision

/// Reads the writing on the back of a print, for the photo's caption.
enum BackCaptionReader {
    enum Reading: Equatable {
        /// Nothing on the back, or only brand and lab printing.
        case blank
        /// Writing that could not be read.
        case unreadable
        /// The handwritten lines, top to bottom.
        case caption(String)
    }

    /// Reads a back that the blank and show-through checks found ink on.
    static func read(_ back: CGImage) -> Reading {
        let recognized = recognizedLines(back)
        guard !recognized.isEmpty else { return .unreadable }
        let lines = handwrittenLines(recognized)
        return lines.isEmpty ? .blank : .caption(lines.joined(separator: "\n"))
    }

    /// The lines left after dropping brand and lab printing. A line is kept when it is a date on its own or
    /// has a word of three or more letters that is not brand printing: brand printing repeats across the
    /// back, as a maker's name printed all over the paper does, or is a word photo paper makers print. Lab
    /// printing (order, frame and correction numbers, lab codes) has no such word. Where handwriting
    /// crosses brand printing and both are read as one line, the brand words are taken out of it.
    static func handwrittenLines(_ lines: [String]) -> [String] {
        let counts = lines.flatMap(words).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let brand = paperMakerWords.union(counts.filter { $0.value >= 3 }.keys)
        let isPrinting = { (line: String) in
            !isDate(line) && !words(line).contains { isWord($0) && !matches($0, brand) }
        }
        let printedWords = paperMakerWords.union(lines.filter(isPrinting).flatMap(words).filter(isWord))
        return lines.filter { !isPrinting($0) }.compactMap { line in
            let kept = line.split(separator: " ").filter { token in
                let word = words(String(token)).joined()
                return !(isWord(word) && matches(word, printedWords))
            }
            return kept.isEmpty ? nil : kept.joined(separator: " ")
        }
    }

    /// A year from 1850 to 2099, or a day, month and year written with `/`, `.` or `-`.
    private static func isDate(_ line: String) -> Bool {
        let line = line.trimmingCharacters(in: .whitespaces)
        return line.wholeMatch(of: #/(18[5-9]\d|19\d\d|20\d\d)/#) != nil
            || line.wholeMatch(of: #/\d{1,2}[\/.\-]\d{1,2}[\/.\-](\d{2}|\d{4})/#) != nil
    }

    private static func isWord(_ word: String) -> Bool {
        word.count >= 3 && word.allSatisfy(\.isLetter)
    }

    /// Whether `word` is one of `vocabulary`, allowing one misread letter in longer words.
    private static func matches(_ word: String, _ vocabulary: Set<String>) -> Bool {
        vocabulary.contains(word) || word.count >= 5 && vocabulary.contains { $0.count >= 5 && differsByOne($0, word) }
    }

    /// Whether one letter changed, added or left out turns `a` into `b`.
    private static func differsByOne(_ a: String, _ b: String) -> Bool {
        let a = Array(a), b = Array(b)
        guard abs(a.count - b.count) <= 1 else { return false }
        guard let first = zip(a, b).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset
        else { return true }
        if a.count == b.count { return a[(first + 1)...] == b[(first + 1)...] }
        return a.count > b.count ? a[(first + 1)...] == b[first...] : a[first...] == b[(first + 1)...]
    }

    private static let paperMakerWords: Set<String> = [
        "kodak", "kodacolor", "ektacolor", "royal", "fuji", "fujifilm", "fujicolor", "crystal", "archive", "agfa",
        "agfacolor", "konica", "ilford", "polaroid", "paper",
    ]

    private static func words(_ line: String) -> [String] {
        line.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func recognizedLines(_ image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? [])
            .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            .compactMap { $0.topCandidates(1).first?.string }
    }
}
