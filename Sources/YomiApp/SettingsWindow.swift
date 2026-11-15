import AppKit
import YomiKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Yomi"
            window.isReleasedWhenClosed = false
            window.toolbarStyle = .unified
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            window.setContentSize(NSSize(width: 860, height: 620))
            window.center()
            window.setFrameAutosaveName("YomiSettings")
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private enum SidebarItem: Hashable {
    case scanner
    case profile(UUID)
}

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var selection: SidebarItem? = .scanner

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Scanner") {
                    Label("ScanSnap S1300", systemImage: "scanner").tag(SidebarItem.scanner)
                }
                Section("Profiles") {
                    ForEach(model.profiles) { profile in
                        HStack {
                            Label(profile.name, systemImage: profile.symbolName)
                            Spacer()
                            if profile.id == model.buttonProfile?.id {
                                Image(systemName: "button.programmable")
                                    .foregroundStyle(.tint)
                                    .help("Used by the Scan button")
                            }
                        }
                        .tag(SidebarItem.profile(profile.id))
                        .contextMenu {
                            Button("Use for Scan Button") { model.buttonProfileID = profile.id }
                            Button("Duplicate") { selection = .profile(model.duplicate(profile).id) }
                            Divider()
                            Button("Delete", role: .destructive) { delete(profile) }
                                .disabled(model.profiles.count <= 1)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            .safeAreaInset(edge: .bottom) { sidebarActions }
        } detail: {
            switch selection {
            case let .profile(id):
                if let index = model.profiles.firstIndex(where: { $0.id == id }) {
                    ProfileEditor(model: model, profile: $model.profiles[index])
                        .id(id)
                }
            default:
                ScannerSettingsView(model: model)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if case let .profile(id) = selection, let profile = model.profiles.first(where: { $0.id == id }) {
                        model.scan(with: profile)
                    } else {
                        model.scanWithButtonProfile()
                    }
                } label: {
                    Label("Scan Now", systemImage: "doc.viewfinder")
                }
                .buttonStyle(.glass(.regular.tint(.accentColor).interactive()))
                .disabled(!model.connection.isReady || model.jobState == .running)
                .help("Scan with the selected profile")
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private var sidebarActions: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                Button { selection = .profile(model.addProfile().id) } label: { Image(systemName: "plus") }
                    .help("New profile")
                Button {
                    if case let .profile(id) = selection, let profile = model.profiles.first(where: { $0.id == id }) {
                        delete(profile)
                    }
                } label: { Image(systemName: "minus") }
                    .help("Delete profile")
                    .disabled(selectedProfileID == nil || model.profiles.count <= 1)
                Spacer()
            }
        }
        .buttonStyle(.glass(.regular.interactive()))
        .controlSize(.small)
        .dimmedWhenInactive()
        .padding(10)
    }

    private var selectedProfileID: UUID? {
        if case let .profile(id) = selection { id } else { nil }
    }

    private func delete(_ profile: ScanProfile) {
        model.delete(profile)
        selection = .scanner
    }
}

private extension ScanProfile {
    var symbolName: String {
        if correctColor { return "photo" }
        return switch fileFormat {
        case .pdf: "doc.richtext"
        case .jpeg, .png, .tiff, .heic: "photo"
        case .multiPageTIFF: "doc.on.doc"
        }
    }
}

private struct DimmedWhenInactive: ViewModifier {
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            .opacity(appearsActive ? 1 : 0.6)
            .animation(.easeOut(duration: 0.2), value: appearsActive)
    }
}

private extension View {
    func dimmedWhenInactive() -> some View { modifier(DimmedWhenInactive()) }
}

// MARK: - Scanner

struct ScannerSettingsView: View {
    @Bindable var model: AppModel
    @State private var firmwareError: String?
    @State private var colorProfile = ColorProfile.locate()
    @State private var colorProfileError: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "scanner.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(model.connection.isReady ? Color.accentColor : .secondary)
                        .frame(width: 56, height: 56)
                        .glassEffect(.regular, in: .circle)
                        .dimmedWhenInactive()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ScanSnap S1300").font(.headline)
                        Text(model.connection.title).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Scan Button") {
                Picker("When the Scan button is pressed, use", selection: $model.buttonProfileID) {
                    ForEach(model.profiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                if let profile = model.buttonProfile {
                    LabeledContent("Saves to", value: profile.folderURL.path(percentEncoded: false))
                    LabeledContent("Settings", value: profile.summary)
                }
            }

            Section("General") {
                Picker("Appearance", selection: $model.appearance) {
                    ForEach(AppSettings.Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Open Yomi at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                LabeledContent("Firmware") {
                    HStack {
                        Text(firmwareStatus).foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFirmware)
                    }
                }
                if let firmwareError {
                    Text(firmwareError).foregroundStyle(.red).font(.caption)
                }
                LabeledContent("Color profile") {
                    HStack {
                        Text(colorProfile?.url.lastPathComponent ?? "Not found")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(colorProfile?.url.path(percentEncoded: false) ?? "")
                        Button("Choose…", action: chooseColorProfile)
                    }
                }
                if let colorProfileError {
                    Text(colorProfileError).foregroundStyle(.red).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Scanner")
    }

    private var firmwareStatus: String {
        if let firmware = Firmware.locate(for: .s1300) { return "\(firmware.url.lastPathComponent) installed" }
        return "Not installed"
    }

    private func chooseFirmware() {
        let panel = NSOpenPanel()
        panel.message = "Choose the ScanSnap firmware file (1300_XXXX.nal) from the original ScanSnap Manager."
        panel.allowedContentTypes = [UTType(filenameExtension: "nal") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try Firmware(url: url)
            try model.installFirmware(from: url)
            firmwareError = nil
        } catch {
            firmwareError = "\(error)"
        }
    }

    private func chooseColorProfile() {
        let panel = NSOpenPanel()
        panel.message = "Choose the scanner's color profile (ScanSnap S1300.icm) from the original ScanSnap Manager."
        panel.allowedContentTypes = ["icm", "icc"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.installColorProfile(from: url)
            colorProfileError = nil
        } catch {
            colorProfileError = "\(error)"
        }
        colorProfile = ColorProfile.locate()
    }
}

// MARK: - Profile editor

struct ProfileEditor: View {
    @Bindable var model: AppModel
    @Binding var profile: ScanProfile
    @State private var albums = PhotoKitLibrary.albumNames()

    var body: some View {
        Form {
            Section {
                TextField("Profile name", text: $profile.name)
                Toggle("Use this profile for the Scan button", isOn: Binding(
                    get: { model.buttonProfile?.id == profile.id },
                    set: { if $0 { model.buttonProfileID = profile.id } }))
            }

            Section("Save To") {
                Picker("Save to", selection: Binding(get: { profile.destination }, set: { profile.saveTo = $0 })) {
                    ForEach(profile.fileFormat.savesPagesSeparately ? ScanProfile.SaveDestination.allCases : [.folder],
                            id: \.self) { Text($0.title).tag($0) }
                }
                if !profile.fileFormat.savesPagesSeparately {
                    Text("Photos can't import PDF or multi-page TIFF files, so they're saved to the folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if profile.destination.savesToPhotos {
                    LabeledContent("Album") {
                        HStack {
                            TextField("Album", text: $profile.photosAlbum, prompt: Text("None (library only)"))
                                .labelsHidden()
                            Menu {
                                if albums.isEmpty {
                                    Button("Show Albums…") {
                                        Task { albums = await PhotoKitLibrary.requestAccessAndListAlbums() }
                                    }
                                }
                                ForEach(albums, id: \.self) { album in
                                    Button(album) { profile.photosAlbum = album }
                                }
                            } label: { Image(systemName: "rectangle.stack") }
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help("Choose an album, or type a new name to create it on the first scan")
                        }
                    }
                }
                LabeledContent(profile.destination.savesToFolder ? "Folder" : "Folder if Photos fails") {
                    HStack {
                        Text(profile.folderURL.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                        Button {
                            try? FileManager.default.createDirectory(at: profile.folderURL, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(profile.folderURL)
                        } label: { Image(systemName: "arrow.up.forward.app") }
                            .help("Open folder")
                    }
                }
                LabeledContent("Subfolders") {
                    HStack {
                        TextField("Subfolders", text: Binding(
                            get: { profile.subfolderPattern.editorText },
                            set: { profile.subfolderPattern = FileNamePattern(editorText: $0) }),
                        prompt: Text("None"))
                            .labelsHidden()
                        Menu {
                            Button("One folder per month") { profile.subfolderPattern = [.year, .text("/"), .month] }
                            Section("Add") {
                                ForEach(FileNamePattern.Piece.batchWide, id: \.self) { piece in
                                    Button(piece.title) { profile.subfolderPattern.pieces.append(piece) }
                                }
                            }
                        } label: { Image(systemName: "plus") }
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Add a piece; type / to start a new folder level")
                    }
                }
                Picker("After scanning", selection: $profile.afterScan) {
                    ForEach(ScanProfile.AfterScan.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }

            Section("File") {
                Picker("Format", selection: $profile.fileFormat) {
                    ForEach(ScanProfile.FileFormat.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if profile.fileFormat == .pdf {
                    Toggle("Make PDF searchable (recognize text)", isOn: $profile.searchablePDF)
                }
                if !profile.fileFormat.savesPagesSeparately {
                    Toggle("Split into several files", isOn: Binding(
                        get: { profile.pagesPerFile != nil },
                        set: { profile.pagesPerFile = $0 ? 1 : nil }))
                    if let pagesPerFile = profile.pagesPerFile {
                        Stepper("One file every \(pagesPerFile) page\(pagesPerFile == 1 ? "" : "s")",
                                value: Binding(get: { pagesPerFile }, set: { profile.pagesPerFile = $0 }),
                                in: 1...999)
                    }
                }
                if profile.fileFormat.usesCompression {
                    Picker("Compression", selection: $profile.compression) {
                        ForEach(ScanProfile.Compression.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                LabeledContent("File name") {
                    HStack {
                        TextField("File name", text: Binding(
                            get: { profile.namePattern.editorText },
                            set: { profile.namePattern = FileNamePattern(editorText: $0) }))
                            .labelsHidden()
                        Menu {
                            Section("Ready-made") {
                                Button("Date and time") { profile.namePattern = .dateAndTime }
                                Button("Name and number") { profile.namePattern = .nameAndNumber("Scan") }
                            }
                            Section("Add") {
                                ForEach(FileNamePattern.Piece.all, id: \.self) { piece in
                                    Button(piece.title) { profile.namePattern.pieces.append(piece) }
                                }
                            }
                        } label: { Image(systemName: "plus") }
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Add a piece or choose a ready-made name")
                    }
                }
                if profile.namePattern.usesRunningNumber {
                    Stepper("Next number: \(profile.nextNumber)", value: $profile.nextNumber, in: 0...999_999)
                    Stepper("Digits: \(profile.numberDigits)", value: $profile.numberDigits, in: 1...8)
                }
                LabeledContent("Example", value: DocumentWriter.exampleFileName(for: profile))
            }

            Section("Scanning") {
                Picker("Image quality", selection: $profile.quality) {
                    ForEach(ScanProfile.Quality.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Color mode", selection: $profile.colorMode) {
                    ForEach(ScanProfile.ColorMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Scanning side", selection: $profile.sides) {
                    ForEach(ScanProfile.Sides.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }

            Section("Paper and Image") {
                Toggle("Crop to paper size and straighten", isOn: $profile.cropAndStraighten)
                Toggle("Rotate pages automatically", isOn: Binding(
                    get: { profile.autoRotate && !profile.rotateByFaces },
                    set: { profile.autoRotate = $0 }))
                    .disabled(profile.rotateByFaces)
                if profile.rotateByFaces {
                    Text("“Rotate photos upright using faces” is on and rotates by text when there are no faces.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Remove blank pages", isOn: $profile.skipBlankPages)
                Toggle("Reduce bleed-through", isOn: $profile.reduceBleedThrough)
            }

            Section("Photos") {
                Toggle("Correct colors with the scanner's color profile", isOn: $profile.correctColor)
                Toggle("Crop to the print's edges instead of paper size", isOn: $profile.cropToPrint)
                Toggle("Rotate photos upright using faces", isOn: $profile.rotateByFaces)
                if profile.fileFormat.savesPagesSeparately {
                    Toggle("Auto-enhance, keeping the untouched original", isOn: $profile.autoEnhance)
                }
                Toggle("Save the picture side of prints fed in back first", isOn: $profile.findPictureSide)
                Toggle("Save writing on the back as the photo's caption, not the back itself",
                       isOn: $profile.backCaptions)
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .top) { ProfileSummaryBar(profile: profile) }
        .navigationTitle(profile.name)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = profile.folderURL
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        profile.folderPath = url.path(percentEncoded: false)
    }
}

private struct ProfileSummaryBar: View {
    let profile: ScanProfile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: profile.symbolName)
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.summary)
                    .font(.callout.weight(.medium))
                Text(([profile.folderURL.lastPathComponent]
                    + DocumentWriter.exampleSubfolder(for: profile).split(separator: "/").map(String.init)
                    + [DocumentWriter.exampleFileName(for: profile)]).joined(separator: " / "))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .dimmedWhenInactive()
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}
