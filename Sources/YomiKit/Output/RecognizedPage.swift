import DataDetection
import Foundation
import Vision

package struct RecognizedPage {
    package let documents: [DocumentObservation.Container]
    package let transcript: String
    package let detectedData: [DataDetector.Match]

    static func read(_ url: URL, language: ScanProfile.TextRecognitionLanguage) async throws -> Self {
        let documents = try await language.documentRequest.perform(on: url).map(\.document)
        let transcript = documents.map(\.text.transcript).joined(separator: "\n")
        var matches: [DataDetector.Match] = []
        for await match in transcript.dataDetectorMatches(options: language.dataDetectionOptions) {
            matches.append(match)
        }
        return Self(documents: documents, transcript: transcript, detectedData: matches)
    }
}

extension ScanProfile.TextRecognitionLanguage {
    var documentRequest: RecognizeDocumentsRequest {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = self == .automatic
        switch self {
        case .automatic: break
        case .english:
            request.textRecognitionOptions.recognitionLanguages = [.init(identifier: "en-US")]
        case .japaneseAndEnglish:
            request.textRecognitionOptions.recognitionLanguages = [.init(identifier: "ja-JP"), .init(identifier: "en-US")]
        }
        return request
    }

    var dataDetectionOptions: DataDetector.Options {
        var options = DataDetector.Options()
        switch self {
        case .automatic: break
        case .english: options.documentLanguageCode = .english
        case .japaneseAndEnglish:
            options.documentLanguageCode = .japanese
            options.documentRegion = .japan
        }
        return options
    }
}
