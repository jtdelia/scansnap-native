import AppKit
import Testing
@testable import YomiApp

@MainActor
struct ProgressPanelTests {
    @Test func panelFitsItsContentOnScreen() throws {
        let app = NSApplication.shared
        let visible = try #require(NSScreen.main?.visibleFrame)
        let model = AppModel()
        let controller = ProgressPanelController()
        controller.show(model: model)
        let panel = try #require(app.windows.compactMap { $0 as? NSPanel }.first { $0.isFloatingPanel && $0.isVisible })
        defer { panel.orderOut(nil) }

        let host = try #require(panel.contentView)
        host.layoutSubtreeIfNeeded()
        #expect(!host.bounds.isEmpty)
        #expect(panel.frame.size == host.fittingSize)
        #expect(host.bounds.size == panel.frame.size)
        #expect(visible.contains(panel.frame))
        #expect(abs(panel.frame.midX - visible.midX) <= 0.5)
        #expect(abs(panel.frame.maxY - (visible.maxY - 40)) <= 0.5)
    }
}
