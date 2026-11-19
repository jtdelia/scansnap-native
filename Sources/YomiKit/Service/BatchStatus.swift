import Foundation

package struct BatchStatus {
    package struct Failure: Equatable {
        package let profile: String
        package let message: String
        package let folder: URL?
        package var sheets: Int? = nil
        package var pages: Int? = nil
        package var blankPagesSkipped: Int? = nil
    }

    package enum State: Equatable {
        case idle, running, recognizing
        case finished(String)
        case failed(Failure)
    }

    package private(set) var latest = 0
    private var current = State.idle
    private var failures: [Failure] = []

    package init() {}

    package var state: State {
        if current == .running || current == .recognizing { return current }
        return failures.first.map(State.failed) ?? current
    }

    package mutating func beginScan() -> Int {
        latest += 1
        current = .running
        return latest
    }

    package mutating func recognize(batch: Int) {
        if batch == latest { current = .recognizing }
    }

    package mutating func finish(batch: Int, profile: ScanProfile, result: Result<ScanOutcome, Error>) {
        if batch == latest { current = .idle }
        switch result {
        case let .success(outcome):
            let summary = outcome.summary(defaultPlace: profile.folderURL.lastPathComponent)
            if summary.isProblem {
                failures.append(Failure(
                    profile: profile.name, message: summary.message, folder: outcome.folder,
                    sheets: outcome.sheets, pages: outcome.pages, blankPagesSkipped: outcome.blankPagesSkipped
                ))
            } else if batch == latest {
                current = .finished(summary.message)
            }
        case let .failure(error):
            let recovery = error as? OCRRecoveryError
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            failures.append(Failure(profile: profile.name, message: message, folder: recovery?.folder))
        }
    }

    package mutating func dismissFailure() {
        if case .failed = state { failures.removeFirst() }
    }
}
