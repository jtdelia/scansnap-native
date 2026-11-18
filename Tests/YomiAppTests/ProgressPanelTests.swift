import AppKit
import Testing
@testable import YomiApp

@MainActor
struct ProgressPanelTests {
    @Test(.enabled("Requires a display") { await MainActor.run { NSScreen.main != nil } }, arguments: [
        AppModel.JobState.running,
        .failed("Photos access was denied. Allow access in System Settings, or find the photos in Scans/Prints.")
    ])
    func panelFitsItsContentOnScreen(state: AppModel.JobState) throws {
        let app = NSApplication.shared
        let visible = try #require(NSScreen.main?.visibleFrame)
        let model = AppModel()
        model.jobState = state
        model.batchFolder = "Scans/Prints"
        let controller = ProgressPanelController()
        controller.show(model: model)
        let panel = try #require(app.windows.compactMap { $0 as? NSPanel }.first { $0.isFloatingPanel && $0.isVisible })
        defer { panel.orderOut(nil) }

        let host = try #require(panel.contentView)
        host.layoutSubtreeIfNeeded()
        for size in [panel.frame.size, host.bounds.size] {
            #expect(abs(size.width - 460) <= 0.5)
            #expect(abs(size.height - 250) <= 0.5)
        }
        #expect(visible.contains(panel.frame))
        #expect(abs(panel.frame.midX - visible.midX) <= 0.5)
        #expect(abs(panel.frame.maxY - (visible.maxY - 40)) <= 0.5)
    }
}
