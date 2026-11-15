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

    /// The lines left after dropping brand and lab printing. Brand printing is a paper maker's name, a whole
    /// brand phrase such as "Kodak Royal Paper", or a word that repeats across the back, as a maker's name
    /// printed all over the paper does. Lab printing is upper-case codes, digits and symbols (order, frame and
    /// correction numbers, lab codes) and words labs print, such as "order" and "frame". A line is kept when
    /// it is a date on its own or has a word that is neither. Where handwriting crosses brand printing and
    /// both are read as one line, the brand printing is taken out of it.
    static func handwrittenLines(_ lines: [String]) -> [String] {
        let counts = lines.flatMap(words).reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let brand = paperMakerNames.union(counts.filter { $0.value >= 3 }.keys)
        return lines.compactMap { line in
            guard !isDate(line) else { return line }
            let tokens = line.split(separator: " ").map(String.init)
            let kept = zip(tokens, brandPrinting(tokens, brand: brand)).filter { !$0.1 }.map(\.0)
            guard kept.contains(where: { !isCode($0) && !isLabWord($0) }) else { return nil }
            return withoutLabNumbers(kept).joined(separator: " ")
        }
    }

    /// Drops a lab word together with the codes printed after it, such as "ORDER 0423" or "FRAME 17".
    private static func withoutLabNumbers(_ tokens: [String]) -> [String] {
        var kept: [String] = []
        var i = tokens.startIndex
        while i < tokens.endIndex {
            let codes = tokens[(i + 1)...].prefix(while: isCode).count
            if isLabWord(tokens[i]), codes > 0 {
                i += 1 + codes
            } else {
                kept.append(tokens[i])
                i += 1
            }
        }
        return kept
    }

    /// For each token, whether it is a paper maker's name, a word repeated across the back, or part of a
    /// brand phrase.
    private static func brandPrinting(_ tokens: [String], brand: Set<String>) -> [Bool] {
        let tokenWords = tokens.map { words($0).joined() }
        var marked = tokenWords.map { !$0.isEmpty && matches($0, brand) }
        for phrase in brandPhrases where phrase.count <= tokenWords.count {
            for start in 0...(tokenWords.count - phrase.count)
            where zip(tokenWords[start...], phrase).allSatisfy({ matches($0, [$1]) }) {
                marked.replaceSubrange(start..<(start + phrase.count), with: repeatElement(true, count: phrase.count))
            }
        }
        return marked
    }

    /// A token that cannot be a handwritten word: it has digits or symbols, fewer than three letters, or, in
    /// Latin letters, no vowel or one letter repeated, as lab codes such as `NNN` and `KX` do.
    private static func isCode(_ token: String) -> Bool {
        let core = token.trimmingCharacters(in: .punctuationCharacters)
        guard core.allSatisfy({ $0.isLetter || "'’-".contains($0) }) else { return true }
        let letters = core.filter(\.isLetter).lowercased()
        guard letters.count >= 3 else { return true }
        guard letters.allSatisfy(\.isASCII) else { return false }
        return !letters.contains(where: "aeiouy".contains) || Set(letters).count == 1
    }

    private static func isLabWord(_ token: String) -> Bool {
        let word = words(token).joined()
        return labWords.contains(word) || word.hasSuffix("s") && labWords.contains(String(word.dropLast()))
    }

    /// A year from 1850 to 2099, or a day, month and year written with `/`, `.` or `-`.
    private static func isDate(_ line: String) -> Bool {
        let line = line.trimmingCharacters(in: .whitespaces)
        return line.wholeMatch(of: #/(18[5-9]\d|19\d\d|20\d\d)/#) != nil
            || line.wholeMatch(of: #/\d{1,2}[\/.\-]\d{1,2}[\/.\-](\d{2}|\d{4})/#) != nil
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

    /// Names that only paper makers print. Ordinary words they also print count only inside `brandPhrases`.
    private static let paperMakerNames: Set<String> = [
        "kodak", "kodacolor", "ektacolor", "fuji", "fujifilm", "fujicolor", "agfa", "agfacolor", "konica", "ilford",
        "polaroid",
    ]

    private static let brandPhrases: [[String]] = [
        ["royal", "paper"], ["crystal", "archive", "paper"], ["crystal", "archive"], ["kodak", "paper"], ["fuji", "paper"],
        ["fujicolor", "paper"], ["agfa", "paper"], ["konica", "paper"], ["ilford", "paper"],
    ]

    private static let labWords: Set<String> = ["order", "frame", "neg", "roll", "lab", "print", "process"]

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
