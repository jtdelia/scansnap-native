import AppKit
import Observation
import YomiKit
import ServiceManagement

@MainActor
@Observable
final class AppModel {
    enum JobState: Equatable {
        case idle
        case running
        case finished(String)
        case failed(String)
    }

    var profiles: [ScanProfile] = [] { didSet { save() } }
    var buttonProfileID: UUID? { didSet { save() } }
    var connection: ScannerConnection = .disconnected
    var progress: ScanProgress?
    var jobState: JobState = .idle
    var activeProfile: ScanProfile?
    var launchAtLogin = SMAppService.mainApp.status == .enabled

    let service = ScannerService()
    private var loaded = false
    private var addedPhotoProfiles = false

    static let supportFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Yomi", isDirectory: true)
    private static let settingsURL = supportFolder.appendingPathComponent("Settings.json")

    var buttonProfile: ScanProfile? {
        profiles.first { $0.id == buttonProfileID } ?? profiles.first
    }

    init() {
        load()
        service.onConnectionChange = { connection in
            Task { @MainActor in self.connection = connection }
        }
        service.onButtonPress = {
            Task { @MainActor in self.scanWithButtonProfile() }
        }
        service.onProgress = { progress in
            Task { @MainActor in self.progress = progress }
        }
        service.start()
    }

    // MARK: Scanning

    func scanWithButtonProfile() {
        guard let profile = buttonProfile else { return }
        scan(with: profile)
    }

    func scan(with profile: ScanProfile) {
        guard jobState != .running, connection.isReady else {
            if !connection.isReady { NSSound.beep() }
            return
        }
        activeProfile = profile
        progress = ScanProgress(phase: "Preparing…", sheets: 0, pages: 0, blankPagesSkipped: 0, thumbnail: nil)
        jobState = .running
        ProgressPanelController.shared.show(model: self)

        service.scan(profile: profile) { result in
            Task { @MainActor in self.finish(profile: profile, result: result) }
        }
    }

    func cancelScan() {
        service.cancelScan()
    }

    private func finish(profile: ScanProfile, result: Result<ScanOutcome, Error>) {
        switch result {
        case let .success(outcome):
            let numbersUsed = DocumentWriter.numbersUsed(pages: outcome.pages, profile: profile)
            if let index = profiles.firstIndex(where: { $0.id == profile.id }), numbersUsed > 0 {
                profiles[index].nextNumber += numbersUsed
            }
            let skipped = outcome.blankPagesSkipped > 0 ? ", \(outcome.blankPagesSkipped) blank skipped" : ""
            if let warning = outcome.warning {
                jobState = .failed("Saved \(outcome.pages) page\(outcome.pages == 1 ? "" : "s"). \(warning)")
                ProgressPanelController.shared.hide(after: 4)
            } else {
                jobState = .finished(outcome.files.isEmpty
                    ? "No pages saved\(skipped)."
                    : "Saved \(outcome.pages) page\(outcome.pages == 1 ? "" : "s") to \(profile.folderURL.lastPathComponent)\(skipped).")
                ProgressPanelController.shared.hide(after: 1.6)
            }
            switch profile.afterScan {
            case .nothing: break
            case .openFile: outcome.files.forEach { NSWorkspace.shared.open($0) }
            case .revealInFinder: NSWorkspace.shared.activateFileViewerSelecting(outcome.files)
            }
        case let .failure(error):
            jobState = .failed("\(error)")
            ProgressPanelController.shared.hide(after: 3.5)
        }
    }

    // MARK: Profiles

    func addProfile() -> ScanProfile {
        var profile = ScanProfile(name: "New Profile")
        var counter = 2
        while profiles.contains(where: { $0.name == profile.name }) {
            profile.name = "New Profile \(counter)"
            counter += 1
        }
        profiles.append(profile)
        return profile
    }

    func duplicate(_ profile: ScanProfile) -> ScanProfile {
        var copy = profile
        copy.id = UUID()
        copy.name = "\(profile.name) Copy"
        profiles.append(copy)
        return copy
    }

    func delete(_ profile: ScanProfile) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == profile.id }
        if buttonProfileID == profile.id { buttonProfileID = profiles.first?.id }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Launch at login failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func installFirmware(from url: URL) throws {
        let folder = Self.supportFolder.appendingPathComponent("Firmware", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: url, to: destination)
    }

    // MARK: Persistence

    private func load() {
        defer { loaded = true }
        if let data = try? Data(contentsOf: Self.settingsURL),
           let settings = try? AppSettings(json: data), !settings.profiles.isEmpty {
            profiles = settings.profiles
            buttonProfileID = settings.buttonProfileID ?? settings.profiles.first?.id
            addedPhotoProfiles = settings.addedPhotoProfiles
        } else {
            profiles = ScanProfile.defaults
            buttonProfileID = profiles.first?.id
        }
    }

    private func save() {
        guard loaded else { return }
        let settings = AppSettings(profiles: profiles, buttonProfileID: buttonProfileID,
                                   addedPhotoProfiles: addedPhotoProfiles)
        do {
            try FileManager.default.createDirectory(at: Self.supportFolder, withIntermediateDirectories: true)
            try settings.json().write(to: Self.settingsURL, options: .atomic)
        } catch {
            NSLog("Saving settings failed: \(error)")
        }
    }
}
