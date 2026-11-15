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
        switch fileFormat {
        case .pdf: "doc.richtext"
        case .jpeg: "photo"
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
}

// MARK: - Profile editor

struct ProfileEditor: View {
    @Bindable var model: AppModel
    @Binding var profile: ScanProfile

    var body: some View {
        Form {
            Section {
                TextField("Profile name", text: $profile.name)
                Toggle("Use this profile for the Scan button", isOn: Binding(
                    get: { model.buttonProfile?.id == profile.id },
                    set: { if $0 { model.buttonProfileID = profile.id } }))
            }

            Section("Save To") {
                LabeledContent("Folder") {
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
                Picker("Compression", selection: $profile.compression) {
                    ForEach(ScanProfile.Compression.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("File name", selection: $profile.fileNaming) {
                    ForEach(ScanProfile.FileNaming.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if profile.fileNaming == .prefixAndNumber {
                    TextField("Name", text: $profile.filePrefix)
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
                Toggle("Rotate pages automatically", isOn: $profile.autoRotate)
                Toggle("Remove blank pages", isOn: $profile.skipBlankPages)
                Toggle("Reduce bleed-through", isOn: $profile.reduceBleedThrough)
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
                Text("\(profile.folderURL.lastPathComponent) / \(DocumentWriter.exampleFileName(for: profile))")
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
