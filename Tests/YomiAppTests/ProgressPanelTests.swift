import AppKit
import Testing
@testable import YomiKit
@testable import YomiApp

@MainActor
struct ProgressPanelTests {
    @Test(.enabled("Requires a display") { await MainActor.run { NSScreen.main != nil } }, arguments: [false, true])
    func panelFitsItsContentOnScreen(showsWarning: Bool) throws {
        let app = NSApplication.shared
        let visible = try #require(NSScreen.main?.visibleFrame)
        var status = BatchStatus()
        let batch = status.beginScan()
        if showsWarning {
            let outcome = ScanOutcome(
                files: [], sheets: 1, pages: 1, blankPagesSkipped: 0,
                folder: URL(fileURLWithPath: "/Scans/Prints"),
                warning: "Photos access was denied. Allow access in System Settings, or find the photos in Scans/Prints."
            )
            status.finish(batch: batch, profile: ScanProfile(name: "Prints"), result: .success(outcome))
        }
        let model = AppModel(status: status)
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
