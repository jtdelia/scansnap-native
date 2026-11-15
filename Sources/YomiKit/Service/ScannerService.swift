import CoreGraphics
import Foundation

public enum ScannerConnection: Equatable, Sendable {
    case disconnected
    case connecting(String)
    case ready(model: String, firmware: String)
    case scanning
    case failed(String)

    public var title: String {
        switch self {
        case .disconnected: "Not connected. Open the scanner's lid to turn it on."
        case let .connecting(message): message
        case let .ready(model, firmware): "\(model) ready (firmware \(firmware))"
        case .scanning: "Scanning…"
        case let .failed(message): message
        }
    }

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

public struct ScanProgress: @unchecked Sendable {
    public var phase: String
    public var sheets: Int
    public var pages: Int
    public var blankPagesSkipped: Int
    public var thumbnail: CGImage?

    public init(phase: String, sheets: Int, pages: Int, blankPagesSkipped: Int, thumbnail: CGImage?) {
        self.phase = phase
        self.sheets = sheets
        self.pages = pages
        self.blankPagesSkipped = blankPagesSkipped
        self.thumbnail = thumbnail
    }
}

public struct ScanOutcome: Sendable {
    public let files: [URL]
    public let sheets: Int
    public let pages: Int
    public let blankPagesSkipped: Int
    /// Set when the batch stopped early; pages scanned before the problem are still saved.
    public var warning: String? = nil
}

/// Appends timestamped lines to ~/Library/Logs/Yomi.log.
public enum ScanLog {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Yomi.log")
    private static let lock = NSLock()
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    public static func write(_ message: String) {
        lock.withLock {
            let line = "\(formatter.string(from: Date()))  \(message)\n"
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

/// Owns the USB connection on a private queue: hot-plug, firmware, Scan button and scan jobs.
public final class ScannerService: @unchecked Sendable {
    public var onConnectionChange: (@Sendable (ScannerConnection) -> Void)?
    public var onButtonPress: (@Sendable () -> Void)?
    public var onProgress: (@Sendable (ScanProgress) -> Void)?

    private let queue = DispatchQueue(label: "Yomi.scanner", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var device: ScannerDevice?
    private var lastSensors: SensorState?
    private var sensorFailures = 0
    private var scanning = false
    private var nextConnectAttempt = Date.distantPast
    private let cancelLock = NSLock()
    private var cancelRequested = false

    public init() {}

    public func start() {
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(40))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    public func cancelScan() {
        cancelLock.withLock { cancelRequested = true }
    }

    private var isCancelRequested: Bool {
        cancelLock.withLock { cancelRequested }
    }

    // MARK: Connection and button

    private func tick() {
        guard !scanning else { return }
        guard let device else {
            connectIfPresent()
            return
        }
        do {
            let state = try device.sensors()
            sensorFailures = 0
            defer { lastSensors = state }
            guard let last = lastSensors else { return }
            // Verified on hardware: a press while asleep only wakes the scanner, so treat wake as a press.
            // Inserting paper can also wake it; that changes the paper bits at the same moment.
            let woke = last.sleeping && !state.sleeping && last.raw[0] == state.raw[0]
            let pressed = (state.scanButton && !last.scanButton) || woke
            if pressed {
                ScanLog.write("scan button (sensors \(last.raw.prefix(2).map { String(format: "%02X", $0) }.joined()) → \(state.raw.prefix(2).map { String(format: "%02X", $0) }.joined()))")
                onButtonPress?()
            }
        } catch ScannerError.shortReply(.sensorInfo, _, _) {
            // Busy (for example still ejecting); try again on the next tick.
        } catch {
            sensorFailures += 1
            if sensorFailures >= 3 { disconnect() }
        }
    }

    private func connectIfPresent() {
        guard Date() >= nextConnectAttempt else { return }
        nextConnectAttempt = Date().addingTimeInterval(1)
        guard let model = USBTransport.connectedModel() else { return }
        publish(.connecting("Connecting to \(model.displayName)…"))
        do {
            let scanner = ScannerDevice(transport: try USBTransport(model: model))
            scanner.transport.timeout = 3
            let info: HardwareInfo
            do {
                info = try scanner.hardwareInfo()
            } catch {
                // An interrupted scan (app quit mid-sheet) leaves data queued in the scanner.
                publish(.connecting("Recovering the scanner…"))
                do {
                    ScanLog.write("recovery: \(try scanner.recover())")
                    info = try scanner.hardwareInfo()
                } catch {
                    publish(.failed("The scanner is not responding. Close and reopen its lid to restart it."))
                    nextConnectAttempt = Date().addingTimeInterval(5)
                    return
                }
            }
            scanner.transport.timeout = 15
            if let firmware = Firmware.locate(for: model), info.firmwareRevision != firmware.version {
                publish(.connecting("Loading firmware \(firmware.version)…"))
                try scanner.uploadFirmware(firmware)
            } else if Firmware.locate(for: model) == nil, info.vendor != "FUJITSU" {
                publish(.failed("Firmware file \(model.firmwarePrefix)XXXX.nal not found. Choose it in Settings."))
                nextConnectAttempt = Date().addingTimeInterval(5)
                return
            }
            try scanner.setPowerLED(true)
            device = scanner
            lastSensors = nil
            sensorFailures = 0
            publish(.ready(model: model.displayName, firmware: try scanner.hardwareInfo().firmwareRevision))
        } catch {
            device = nil
            publish(.failed("Could not connect: \(error)"))
            nextConnectAttempt = Date().addingTimeInterval(3)
        }
    }

    private func disconnect() {
        device = nil
        lastSensors = nil
        publish(.disconnected)
    }

    private func publish(_ connection: ScannerConnection) {
        ScanLog.write("connection: \(connection.title)")
        onConnectionChange?(connection)
    }

    // MARK: Scanning

    /// Scans one batch with `profile`. Completion runs on the service queue.
    public func scan(profile: ScanProfile, completion: @escaping @Sendable (Result<ScanOutcome, Error>) -> Void) {
        queue.async { [self] in
            guard let device, !scanning else {
                completion(.failure(ScanError.noPaper))
                return
            }
            cancelLock.withLock { cancelRequested = false }
            scanning = true
            publish(.scanning)
            defer {
                scanning = false
                lastSensors = nil
                if let model = USBTransport.connectedModel(), self.device != nil {
                    publish(.ready(model: model.displayName, firmware: (try? device.hardwareInfo().firmwareRevision) ?? ""))
                }
            }
            ScanLog.write("scan started: \(profile.name) — \(profile.summary)")
            let result = Result { try runScan(profile: profile, device: device) }
            switch result {
            case let .success(outcome):
                ScanLog.write("scan finished: \(outcome.sheets) sheet(s), \(outcome.pages) page(s), \(outcome.blankPagesSkipped) blank skipped → \(outcome.files.map(\.lastPathComponent).joined(separator: ", "))")
            case let .failure(error):
                ScanLog.write("scan failed: \(error)")
            }
            completion(result)
        }
    }

    /// Keeps unprocessed sides for tuning (enable with `defaults write io.github.jtdelia.Yomi SaveRawScans -bool YES`).
    private func saveRaw(_ front: ScannedPage, _ back: ScannedPage, sheet: Int) {
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Yomi/Raw", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        for page in [front, back] {
            let url = folder.appendingPathComponent("\(stamp)-sheet\(sheet)-\(page.side.rawValue).png")
            if let image = try? page.cgImage() { try? ImageWriter.write(image, to: url, resolution: page.resolution) }
        }
    }

    /// Shared state between the USB reader and the processing workers.
    private final class JobState: @unchecked Sendable {
        let lock = NSLock()
        var progress = ScanProgress(phase: "Preparing…", sheets: 0, pages: 0, blankPagesSkipped: 0, thumbnail: nil)
        var results: [Int: [ProcessedPage]] = [:]
        var processingError: Error?
    }

    private func runScan(profile: ScanProfile, device: ScannerDevice) throws -> ScanOutcome {
        let state = JobState()
        let onProgress = self.onProgress
        func update(_ change: (inout ScanProgress) -> Void) {
            let snapshot: ScanProgress = state.lock.withLock {
                change(&state.progress)
                return state.progress
            }
            onProgress?(snapshot)
        }
        update { _ in }

        let colorCorrection = ColorCorrection.forBatch(profile)
        if let line = colorCorrection.logLine { ScanLog.write("  \(line)") }
        let colorProfile = colorCorrection.colorSpace

        let engine = try ScanEngine(device: device, dpi: profile.quality.dpi)
        engine.isCancelled = { [weak self] in self?.isCancelRequested ?? true }
        engine.log = { ScanLog.write("  \($0)") }
        engine.onPhase = { phase in
            ScanLog.write("  \(phase)")
            update { $0.phase = phase }
        }

        // Verified on hardware: the S1300 keeps feeding into a small internal buffer and stops the
        // paper mid-sheet when the host is slow to read. Sheets are therefore processed on a
        // separate queue so the USB reader never stalls.
        let workers = DispatchQueue(label: "Yomi.processing", qos: .utility)
        let group = DispatchGroup()
        let saveRaw = UserDefaults.standard.bool(forKey: "SaveRawScans")

        var stopReason: Error?
        var sheets = 0
        do {
            sheets = try engine.scanBatch { rawFront, rawBack in
                let index = state.lock.withLock { () -> Int in
                    state.progress.sheets += 1
                    return state.progress.sheets
                }
                update { _ in }
                group.enter()
                workers.async { [self] in
                    defer { group.leave() }
                    if saveRaw { self.saveRaw(rawFront, rawBack, sheet: index) }
                    do {
                        let sheet = try SheetProcessor.process(front: rawFront, back: rawBack, profile: profile,
                                                               colorProfile: colorProfile)
                        sheet.notes.forEach { ScanLog.write("  sheet \(index) \($0)") }
                        state.lock.withLock { state.results[index] = sheet.pages }
                        update {
                            $0.blankPagesSkipped += sheet.blankSides
                            $0.pages += sheet.pages.count
                            if let last = sheet.pages.last { $0.thumbnail = last.image }
                        }
                    } catch {
                        ScanLog.write("  sheet \(index) processing failed: \(error)")
                        state.lock.withLock { state.processingError = error }
                    }
                }
            }
        } catch {
            sheets = state.lock.withLock { state.progress.sheets }
            guard sheets > 0 else { throw error }
            stopReason = error
            ScanLog.write("  batch stopped early: \(error); saving pages already scanned")
        }

        if state.lock.withLock({ state.results.count }) < sheets {
            update { $0.phase = "Finishing pages…" }
        }
        group.wait()
        if stopReason == nil, let error = state.lock.withLock({ state.processingError }) { stopReason = error }

        let pages = state.lock.withLock { state.results.keys.sorted().flatMap { state.results[$0] ?? [] } }
        let skipped = state.lock.withLock { state.progress.blankPagesSkipped }
        guard !pages.isEmpty else {
            if let stopReason { throw stopReason }
            return ScanOutcome(files: [], sheets: sheets, pages: 0, blankPagesSkipped: skipped)
        }
        let files = try DocumentWriter.save(pages, profile: profile) { phase in
            update { $0.phase = phase }
        }
        var outcome = ScanOutcome(files: files, sheets: sheets, pages: pages.count, blankPagesSkipped: skipped)
        let stopWarning = stopReason.map { stopReason in
            (stopReason as? ScanError)?.isCancellation == true
                ? "Stopped. Pages scanned so far were saved."
                : "Stopped early (\(stopReason)). Pages scanned so far were saved."
        }
        let warnings = [stopWarning, colorCorrection.warning].compactMap { $0 }
        outcome.warning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        return outcome
    }
}
