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

    /// Everything saved in `Settings.json`, kept whole so every field, including the upgrade markers, is saved.
    private var settings = AppSettings() { didSet { save() } }

    var profiles: [ScanProfile] {
        get { settings.profiles }
        set { settings.profiles = newValue }
    }

    var buttonProfileID: UUID? {
        get { settings.buttonProfileID }
        set { settings.buttonProfileID = newValue }
    }

    var appearance: AppSettings.Appearance {
        get { settings.appearance }
        set {
            settings.appearance = newValue
            applyAppearance()
        }
    }
    var connection: ScannerConnection = .disconnected
    var progress: ScanProgress?
    var jobState: JobState = .idle
    var activeProfile: ScanProfile?
    /// The folder the running batch saves in, or the last batch went to, as the progress panel names it.
    var batchFolder: String?
    var launchAtLogin = SMAppService.mainApp.status == .enabled

    let service = ScannerService()
    /// Where each scan profile's last batch was saved, while the app runs.
    private var lastFolders: [UUID: URL] = [:]
    private var loaded = false

    static let supportFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Yomi", isDirectory: true)
    private static let settingsURL = supportFolder.appendingPathComponent("Settings.json")

    var buttonProfile: ScanProfile? {
        profiles.first { $0.id == buttonProfileID } ?? profiles.first
    }

    init() {
        load()
        service.photoLibrary = PhotoKitLibrary()
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
        batchFolder = profile.destination.savesToFolder ? DocumentWriter.folderName(for: profile) : nil
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

    /// `folder` as the scan profile's folder name and the subfolders under it, or its full path when it is elsewhere.
    private static func name(of folder: URL, in profile: ScanProfile) -> String {
        let top = profile.folderURL.standardizedFileURL.pathComponents
        let parts = folder.standardizedFileURL.pathComponents
        guard parts.starts(with: top) else { return folder.path(percentEncoded: false) }
        return ([profile.folderURL.lastPathComponent] + parts.dropFirst(top.count)).joined(separator: "/")
    }

    /// Opens the folder the scan profile's last batch went to, else the subfolder a batch scanned now goes into,
    /// else the scan profile's folder.
    func openFolder(of profile: ScanProfile) {
        let fm = FileManager.default
        try? fm.createDirectory(at: profile.folderURL, withIntermediateDirectories: true)
        let folder = [lastFolders[profile.id], DocumentWriter.saveFolder(for: profile)].compactMap(\.self)
            .first { fm.fileExists(atPath: $0.path) }
        NSWorkspace.shared.open(folder ?? profile.folderURL)
    }

    private func finish(profile: ScanProfile, result: Result<ScanOutcome, Error>) {
        switch result {
        case let .success(outcome):
            let numbersUsed = DocumentWriter.numbersUsed(pages: outcome.pages, profile: profile)
            if let index = profiles.firstIndex(where: { $0.id == profile.id }), numbersUsed > 0 {
                profiles[index].nextNumber += numbersUsed
            }
            if let folder = outcome.folder {
                batchFolder = Self.name(of: folder, in: profile)
                lastFolders[profile.id] = folder
            }
            let summary = outcome.summary(defaultPlace: profile.folderURL.lastPathComponent)
            if summary.isProblem {
                jobState = .failed(summary.message)
                ProgressPanelController.shared.hide(after: 4)
            } else {
                jobState = .finished(summary.message)
                ProgressPanelController.shared.hide(after: outcome.notice == nil ? 1.6 : 4)
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

    func installColorProfile(from url: URL) throws {
        try ColorProfile.install(from: url)
    }

    // MARK: Persistence

    private func load() {
        if let data = try? Data(contentsOf: Self.settingsURL),
           let saved = try? AppSettings(json: data), !saved.profiles.isEmpty {
            var upgraded = saved.upgraded()
            upgraded.buttonProfileID = upgraded.buttonProfileID ?? upgraded.profiles.first?.id
            settings = upgraded
            loaded = true
            if upgraded != saved { save() }
        } else {
            settings = .newInstall
            loaded = true
        }
        applyAppearance()
    }

    private func applyAppearance() {
        NSApp.appearance = appearance.appKitName.flatMap(NSAppearance.init(named:))
    }

    private func save() {
        guard loaded else { return }
        do {
            try FileManager.default.createDirectory(at: Self.supportFolder, withIntermediateDirectories: true)
            try settings.json().write(to: Self.settingsURL, options: .atomic)
        } catch {
            NSLog("Saving settings failed: \(error)")
        }
    }
}

private extension AppSettings.Appearance {
    /// The AppKit appearance to force, or `nil` to follow macOS.
    var appKitName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }
}
