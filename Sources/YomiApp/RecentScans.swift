import AppKit
import SwiftUI
import YomiKit

@MainActor
final class RecentScansController {
    static let shared = RecentScansController()
    private var window: NSWindow?

    func show(model: AppModel) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: RecentScansView(model: model)))
            window.title = "Recent Scans"
            window.setContentSize(NSSize(width: 520, height: 380))
            window.center()
            window.isReleasedWhenClosed = false
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct RecentScansView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            if let error = model.historyError { Text(error).foregroundStyle(.red).padding() }
            if model.history.batches.isEmpty {
                ContentUnavailableView("No recent scans", systemImage: "doc", description: Text("Files saved to a folder appear here."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.history.batches) { batch in
                            Text("\(batch.profileName) · \(batch.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.headline).accessibilityAddTraits(.isHeader)
                            ForEach(batch.files) { file in SavedFileRow(file: file, model: model) }
                            Divider()
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 380, minHeight: 230)
    }
}

struct SavedFileRow: View {
    let file: RecentFile
    let model: AppModel
    @State private var editing = false
    @State private var stem = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                if editing {
                    TextField("File name", text: $stem)
                        .focused($focused)
                        .onSubmit(save)
                        .onExitCommand { editing = false }
                        .onAppear { focused = true }
                    Button("Save", action: save)
                        .disabled(stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { editing = false }
                } else {
                    Text(file.url.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file.url.path)
                    Spacer()
                    Button("Rename") {
                        stem = file.url.deletingPathExtension().lastPathComponent
                        error = nil
                        editing = true
                    }
                    .accessibilityLabel("Rename \(file.url.lastPathComponent)")
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func save() {
        do {
            try model.history.rename(file.id, to: stem)
            error = nil
            editing = false
        } catch { self.error = error.localizedDescription }
    }
}

struct LearnedNamesView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Learned names").font(.title2)
            if model.history.rules.isEmpty {
                ContentUnavailableView("No learned names", systemImage: "textformat", description: Text("Renaming a recognized scan can teach Yomi a name."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(model.history.rules.sorted { $0.lastUsed > $1.lastUsed }) { rule in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("\(rule.matchedText) → \(rule.replacement)")
                                    Text("Last used \(rule.lastUsed.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Delete", role: .destructive) { remove([rule.id]) }
                                    .accessibilityLabel("Delete learned name \(rule.replacement)")
                            }
                            Divider()
                        }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Clear All", role: .destructive) { remove(Set(model.history.rules.map(\.id))) }
                    .disabled(model.history.rules.isEmpty)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 330)
    }

    private func remove(_ ids: Set<UUID>) {
        do { try model.history.deleteRules(ids) } catch { self.error = error.localizedDescription }
    }
}
