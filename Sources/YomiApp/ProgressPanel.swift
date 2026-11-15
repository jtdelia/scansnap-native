import AppKit
import YomiKit
import SwiftUI

/// Floating glass HUD shown while a scan runs; it never takes focus from the frontmost app.
@MainActor
final class ProgressPanelController {
    static let shared = ProgressPanelController()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(model: AppModel) {
        hideWork?.cancel()
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
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; panel.animator().alphaValue = 0 }) {
                Task { @MainActor in panel.orderOut(nil) }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func makePanel(model: AppModel) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 250),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: ScanProgressView(model: model))
        host.sizingOptions = [.preferredContentSize]
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

struct ScanProgressView: View {
    let model: AppModel

    var body: some View {
        GlassEffectContainer {
            HStack(alignment: .top, spacing: 18) {
                thumbnail
                VStack(alignment: .leading, spacing: 10) {
                    header
                    status
                    counters
                    Spacer(minLength: 0)
                    footer
                }
            }
            .padding(20)
            .frame(width: 440, height: 230)
            .containerShape(.rect(cornerRadius: 28))
            .glassEffect(.regular, in: .rect(cornerRadius: 28))
        }
        .padding(10)
        // The panel never becomes key, so it would otherwise always draw as inactive.
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
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.progress?.phase ?? "Preparing…").font(.callout)
            }
        case let .finished(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .lineLimit(3)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .lineLimit(3)
        case .idle:
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
            if let folder = model.activeProfile?.folderURL.lastPathComponent {
                Label(folder, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.jobState == .running {
                Button("Stop") { model.cancelScan() }
                    .buttonStyle(.glass(.regular.interactive()))            }
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
