import AppKit
import YomiKit
import SwiftUI

@MainActor
final class ProgressPanelController {
    static let shared = ProgressPanelController()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(model: AppModel) {
        hideWork?.cancel()
        hideWork = nil
        let panel = panel ?? makePanel(model: model)
        self.panel = panel
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
    }

    func hide(after delay: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; panel.animator().alphaValue = 0 }) {
                Task { @MainActor in
                    if self.hideWork != nil { panel.orderOut(nil) }
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func dismiss() {
        hideWork?.cancel()
        panel?.orderOut(nil)
    }

    private func makePanel(model: AppModel) -> NSPanel {
        let panel = EditableProgressPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 250),
                                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: ScanProgressView(model: model))
        host.sizingOptions = [.preferredContentSize, .intrinsicContentSize]
        panel.contentView = host
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 40,
                              width: size.width, height: size.height), display: true)
    }
}

private final class EditableProgressPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct ScanProgressView: View {
    let model: AppModel

    var body: some View {
        GlassEffectContainer {
            Group {
                if case let .failed(failure) = model.jobState {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(failure.profile, systemImage: "exclamationmark.triangle.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.orange)
                        ScrollView {
                            Text(failure.message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if let sheets = failure.sheets, let pages = failure.pages {
                            HStack(spacing: 16) {
                                counter("Sheets", sheets)
                                counter("Pages", pages)
                                if let skipped = failure.blankPagesSkipped, skipped > 0 {
                                    counter("Blank skipped", skipped)
                                }
                            }
                        }
                        HStack {
                            if let folder = failure.folder {
                                Label(folder.lastPathComponent, systemImage: "folder")
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Button("Open Folder") { NSWorkspace.shared.open(folder) }
                            }
                            Spacer()
                            Button("Dismiss") { model.dismissFailure() }
                        }
                    }
                } else {
                    HStack(alignment: .top, spacing: 18) {
                        thumbnail
                        VStack(alignment: .leading, spacing: 10) {
                            header
                            status
                            if let batch = model.finishedBatch {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(batch.files) { file in
                                            SavedFileRow(file: file, model: model)
                                        }
                                    }
                                }
                            } else {
                                counters
                            }
                            footer
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                }
            }
            .padding(20)
            .frame(width: 440, height: 230)
            .containerShape(.rect(cornerRadius: 28))
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
        }
        .padding(10)
        .environment(\.appearsActive, true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.activeProfile?.name ?? "Scanning")
                .font(.title3.weight(.semibold))
            Text(model.activeProfile?.summary ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    @ViewBuilder private var status: some View {
        switch model.jobState {
        case .running, .recognizing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.jobState == .recognizing ? "Making PDF searchable…" : model.progress?.phase ?? "Preparing…")
                    .font(.callout)
            }
        case let .finished(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .lineLimit(3)
        case .failed, .idle:
            EmptyView()
        }
    }

    private var counters: some View {
        HStack(spacing: 16) {
            counter("Sheets", model.progress?.sheets ?? 0)
            counter("Pages", model.progress?.pages ?? 0)
            if let skipped = model.progress?.blankPagesSkipped, skipped > 0 {
                counter("Blank skipped", skipped)
            }
        }
    }

    private func counter(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)").font(.title2.monospacedDigit().weight(.semibold)).contentTransition(.numericText())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if let folder = model.batchFolder {
                Label(folder, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if model.finishedBatch != nil {
                Button("Done") { ProgressPanelController.shared.dismiss() }
            } else if model.jobState == .running {
                Button("Stop") { model.cancelScan() }
                    .buttonStyle(.glass(.regular.interactive()))
            }
        }
    }

    private var thumbnail: some View {
        ZStack {
            ConcentricRectangle(corners: .concentric(minimum: 10), isUniform: true).fill(.background.secondary)
            if let image = model.progress?.thumbnail {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 6))
                    .padding(6)
                    .transition(.opacity)
            } else {
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 130, height: 180)
        .animation(.smooth, value: model.progress?.pages)
    }
}
